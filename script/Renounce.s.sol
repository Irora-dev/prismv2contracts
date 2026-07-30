// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PrismHookV2} from "../src/PrismHookV2.sol";
import {PrismMigration} from "../src/PrismMigration.sol";

/// Just the one POSM view this script needs. Declared locally rather than importing the full
/// `IPositionManager` so the renounce step stays independent of the periphery's interface surface.
interface IPosmLiquidity {
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
}

/// @title  Final step: give up ownership of PrismHookV2.
/// @notice Separate from `Deploy.s.sol` on purpose, and it is the LAST irreversible action of the
///   launch. After this the TOKEN has no admin of any kind, forever.
///
///   Read that precisely: it is true of the hook, and not of the airdrop vault. `PrismMigration`
///   keeps an immutable `deployer` who can call `setToken` until the first valid claim latches
///   `tokenFinal` — and the documented order pushes the airdrop AFTER this step. Until one claim
///   lands, whoever holds the deploy key can point the vault at a contract that mimics an ERC-20
///   well enough to satisfy every check the vault makes, and latch it there permanently, destroying
///   the entire reserve. That is deploy-key hygiene rather than a code defect, but do not read
///   "renounced" as "the key is now spent": it is not spent until the airdrop has begun. Push at
///   least one claim to close the window, and note the tradeoff — latching `tokenFinal` also gives up
///   the ability to re-point a mis-wired vault, which is the recovery path for a failed `setToken`.
///
/// @dev Why this is not part of the deploy script. A forge broadcast is one transaction per
///   state-changing call, not one transaction overall, and a reverted transaction does not stop the
///   next one from being mined. If `seed()` were included and reverted while a renounce followed it,
///   the outcome would be terminal: `seed()` is the only owner-gated function, and the hook's
///   `_beforeInitialize` rejects any pool initialization that did not originate inside it — so the
///   {ETH,PRISM} pool could never be created by anyone, the fee layer would no-op forever
///   (`if (!seeded || totalShares == 0) return`), and the whole 5,000 PRISM supply would be stranded in
///   an ownerless contract with no exit path. Splitting this out makes that state unreachable: the
///   owner key is retained until the seed is confirmed *on-chain*, and the checks below re-verify it
///   in the same transaction that renounces.
///
///   HOOK=<address> forge script script/Renounce.s.sol --rpc-url $RPC --sender <deployer> --broadcast
contract Renounce is Script {
    function run() external {
        renounce(vm.envAddress("HOOK"));
    }

    /// @dev The address is a parameter rather than being read from the environment inside the checks,
    ///   so the guards are testable without mutating process-wide state. `vm.setEnv` is global and
    ///   forge runs a contract's tests in parallel, so env-driven tests race each other.
    function renounce(address hookAddr) public {
        int256 lo = vm.envOr("SEED_TICK_LOWER", int256(0));
        int256 hi = vm.envOr("SEED_TICK_UPPER", int256(0));

        // Round-trip the narrowing instead of casting blindly. A value that does not fit `int24` is exactly
        // the silent-truncation error the deploy guards already refuse -- 16777416 arrives as 200, a
        // ~2,000,000x price error that otherwise deploys cleanly -- and this script must not become the one
        // place it slips through unchecked.
        require(int256(int24(lo)) == lo, "SEED_TICK_LOWER does not fit int24 - check the digits");
        require(int256(int24(hi)) == hi, "SEED_TICK_UPPER does not fit int24 - check the digits");

        // Zero means "not configured" for the liquidity floor, but zero is a legal tick, so the range check
        // opts in on the two ticks differing rather than on a sentinel. An operator on an older .env that
        // has neither is never blocked by a variable they do not have.
        renounce(hookAddr, vm.envOr("MIN_SEED_LIQUIDITY", uint256(0)), int24(lo), int24(hi), lo != hi);
    }

    function renounce(address hookAddr, uint256 minLiquidity) public {
        renounce(hookAddr, minLiquidity, 0, 0, false);
    }

    /// @dev `minLiquidity` is a parameter for the same reason `hookAddr` is: reading it from the
    ///   environment inside the checks makes the guards untestable in isolation, because `vm.setEnv` is
    ///   process-global and forge runs a contract's tests in PARALLEL — a test that sets it leaks into
    ///   every test that does not. That is not hypothetical; it broke this file's happy-path test once.
    function renounce(
        address hookAddr,
        uint256 minLiquidity,
        int24 expectedTickLower,
        int24 expectedTickUpper,
        bool checkRange
    ) public {
        PrismHookV2 hook = PrismHookV2(payable(hookAddr));

        require(hookAddr.code.length > 0, "HOOK has no code");
        // The whole reason this script exists: never renounce an unseeded hook.
        require(hook.seeded(), "hook is NOT seeded - renouncing now would brick it permanently");
        require(hook.owner() == msg.sender, "sender is not the current owner");

        // And never renounce over an unreachable airdrop reserve. The vault is created in the FIRST
        // broadcast transaction and consumed as a constructor argument by the SECOND, which mints the
        // whole reserve to it — so if the first transaction fails while the rest are mined, the hook
        // mints 89% of the supply to that address regardless. Every other check in the launch still
        // passes in that state: `setToken` on a codeless address is a call to an empty account, which
        // succeeds silently and returns nothing, and the three checks above only ever look at the hook.
        // `Deploy.s.sol`'s own post-conditions cannot catch it either — they run in simulation, where the
        // vault always exists. This is the last transaction that can, so it does. (Because the vault is
        // deployed via CREATE2, this state is recoverable rather than terminal: deploy the vault at the
        // predicted address, run setToken, then renounce.)
        address vault = hook.MIGRATION_VAULT();
        if (vault != address(0)) {
            // This is the check that catches the failure above: code at the vault address proves the
            // reserve landed somewhere reachable rather than on a bare address.
            require(vault.code.length > 0, "MIGRATION_VAULT has no code - the airdrop reserve is unreachable");

            // Wiring is NOT required here, and must not be. `setToken` opens the airdrop, and it is a
            // separate, deliberate step (`script/OpenAirdrop.s.sol`) run hours after launch so the float
            // can trade before 89% of the supply becomes movable. Requiring it would force the airdrop
            // open before the renounce and defeat that ordering — or, worse, tempt an operator to delay
            // renouncing, leaving a hook with a live owner for a day.
            //
            // An unwired vault is therefore a legitimate mid-launch state. What is never legitimate is a
            // vault wired to a DIFFERENT token: that pays out something no holder wants, and `tokenFinal`
            // latches on the first claim, so it cannot be undone. Check that, and only that.
            address wired = PrismMigration(vault).token();
            require(
                wired == address(0) || wired == hookAddr,
                "MIGRATION_VAULT is wired to a different token - do NOT renounce"
            );
            if (wired == address(0)) {
                console2.log("note: airdrop not yet open (vault unwired). Renouncing is safe; the vault is");
                console2.log("      deployer-gated and has no deadline. Open it later with OpenAirdrop.s.sol.");
                console2.log("      KEEP THE DEPLOY KEY until you have: nothing else can ever open it.");
            }
        }

        // And never renounce over an under-seeded pool. `Deploy.s.sol` validates the seed thoroughly, but
        // every one of those checks runs in SIMULATION — and the runbook's own recovery advice, when a
        // step reverts, is to finish by hand. The step most likely to need that is `seed()`: it is the
        // largest transaction, it carries a deadline, and it depends on live mainnet state. Its hand
        // equivalent is a `cast send` with four typed values and no validation whatsoever, so a single
        // dropped digit in the liquidity seeds a fraction of the float, strands the rest in a contract
        // that is about to become ownerless, and cannot be retried because `seed()` is one-shot.
        //
        // So re-check the outcome here, against the position itself rather than against the transaction
        // that created it — that way it holds however the seed was performed. Liquidity is the right
        // quantity to read: the hook can never rebalance (`seed()` is its only owner function and reverts
        // after use), so unlike a balance this cannot drift with accrued fees.
        //
        // MIN_SEED_LIQUIDITY is optional: zero skips this check and the vault checks above still apply,
        // so an operator on an older .env is never blocked by a variable they do not have.
        // `merkle/make-env.mjs` emits it alongside SEED_LIQUIDITY.
        if (minLiquidity > 0) {
            uint256 tokenId = hook.hookPositionTokenId();
            require(tokenId != 0, "hook holds no LP position despite reporting seeded");
            // Both read off the hook rather than hardcoded, so this works against any deployment.
            uint128 actual = IPosmLiquidity(hook.POSM()).getPositionLiquidity(tokenId);
            require(
                actual >= minLiquidity,
                "seeded liquidity is below MIN_SEED_LIQUIDITY - the pool was under-seeded, do NOT renounce"
            );
            console2.log("seeded liquidity:", actual);
        }

        // Liquidity alone does NOT pin how much PRISM the seed consumed. A mint deposits
        // `L * (sqrtUpper - sqrtLower) / 2**96`, so the amount depends on the RANGE as much as on `L` --
        // `merkle/seed-params.mjs` says as much: PRISM per unit of liquidity depends entirely on the tick.
        // So the check above is satisfied to the wei by a hand-run `seed()` that typed the right liquidity
        // over the wrong range, which strands the float exactly as a dropped digit in the liquidity would:
        // measured at 539.897 PRISM (98.99% of the float, 10.8% of supply) left in a contract one
        // transaction away from being ownerless, with the liquidity floor reporting success.
        //
        // The range is the missing input, so compare what the hook RECORDED against what was intended.
        // `seed()` stores both ticks, so this needs no TickMath (the vendored v4-core has none) and no
        // position-manager decoding. Reading the hook rather than a balance also makes it ungriefable: a
        // third party can raise the hook's PRISM balance with a one-wei transfer, and a check that refused
        // on that would hand anyone a permanent block on the renounce -- which leaves a live owner key on a
        // token documented as having none, a worse outcome than the typo.
        if (checkRange) {
            require(
                hook.globalTickLower() == expectedTickLower && hook.globalTickUpper() == expectedTickUpper,
                "seeded range does not match SEED_TICK_LOWER/SEED_TICK_UPPER - the pool was seeded over the wrong range, do NOT renounce"
            );
            console2.log("seeded range verified against the configured ticks");
        }

        // Say so when a check did NOT run. Both are opt-in so that an operator on an older .env is never
        // blocked by a variable they do not have — but "no message" then looks identical to "checked and
        // fine", and the hand-run path that most needs these checks is exactly the one likeliest to be
        // missing the environment that arms them.
        if (minLiquidity == 0) {
            console2.log("NOTE: seed-size check SKIPPED - MIN_SEED_LIQUIDITY is not set (source your .env)");
        }
        if (!checkRange) {
            console2.log("NOTE: seed-range check SKIPPED - SEED_TICK_LOWER/UPPER not set (source your .env)");
        }

        vm.startBroadcast();
        hook.renounceOwnership();
        vm.stopBroadcast();

        require(hook.owner() == address(0), "ownership not renounced");
        console2.log("Ownership renounced. PrismHookV2 is now fully immutable with no admin.");
        console2.log("hook:", address(hook));

        // Say this AFTER the renounce, not only before it. "Fully immutable with no admin" is the last
        // thing on screen otherwise, and it reads as "finished" — which is exactly when someone
        // cold-stores or discards the deploy key. The hook is done with that key; the airdrop is not.
        if (vault != address(0) && PrismMigration(vault).token() == address(0)) {
            console2.log("");
            console2.log(">>> NOT FINISHED: the airdrop is still closed, and the DEPLOY KEY IS STILL NEEDED.");
            console2.log(">>> Only that key can open it (OpenAirdrop.s.sol), there is no sweep and no");
            console2.log(">>> fallback, and the reserve is stranded permanently if the key is lost first.");
            console2.log(">>> Do not discard or cold-store it until the airdrop is open.");
        }
    }
}
