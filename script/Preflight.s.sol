// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Deploy} from "./Deploy.s.sol";

/// @title  Read-only preflight for the PRISM deploy configuration.
/// @notice Runs every guard `Deploy.s.sol` can check BEFORE it touches the chain, against your `.env`,
///         without spending gas or signing anything:
///
///           forge script script/Preflight.s.sol
///
///         Prints `PREFLIGHT PASSED` and the derived values, or reverts with the named reason for the
///         first problem it finds.
///
/// @dev Why this is worth a separate script rather than "just dry-run the deploy": a dry run needs an
///      RPC endpoint and a `--sender`, mines a salt, and simulates real calls against live mainnet
///      state. This needs none of that, so it is the check you can run repeatedly while filling in the
///      configuration — and it cannot be confused for the real thing, because there is nothing here to
///      broadcast even by accident.
///
///      It shares code with the deploy rather than restating it, and it has to stay that way: a check
///      replayed here instead of called from `Deploy` can keep passing while the real guard is weakened
///      or removed. Calling `Deploy`'s own validators means this cannot drift from what actually runs.
contract Preflight is Script {
    function run() external {
        Deploy d = new Deploy();

        Deploy.RawConfig memory cfg = Deploy.RawConfig({
            merkleRoot:      vm.envBytes32("MERKLE_ROOT"),
            migrationAmount: vm.envUint("MIGRATION_AMOUNT"),
            treeTotal:       vm.envOr("MERKLE_TOTAL", uint256(0)),
            sqrtPriceX96:    vm.envUint("SEED_SQRT_PRICE_X96"),
            tickLower:       vm.envInt("SEED_TICK_LOWER"),
            tickUpper:       vm.envInt("SEED_TICK_UPPER"),
            liquidity:       vm.envUint("SEED_LIQUIDITY"),
            targetFdvWei:    vm.envUint("TARGET_FDV_WEI"),
            saltNonce:       vm.envUint("SALT_NONCE")
        });

        // Reverts by name on the first failure. That is the whole feature.
        Deploy.SeedParams memory p = d.validateConfig(cfg);

        console2.log("--- config ---");
        console2.log("launch tick (SEED_TICK_UPPER) :", vm.toString(int256(p.tickUpper)));
        console2.log("range lower                   :", vm.toString(int256(p.tickLower)));
        console2.log("implied FDV (wei of ETH)      :", d.impliedFdvWei(cfg.sqrtPriceX96));
        console2.log("declared TARGET_FDV_WEI       :", cfg.targetFdvWei);
        console2.log("airdrop reserve (wei)         :", cfg.migrationAmount);
        console2.log("float left for the seed (wei) :", 5000 ether - cfg.migrationAmount);

        // The canary is the only check that can catch a well-formed root built from the WRONG snapshot.
        // Every other check compares one environment value against another and so cannot see it, and
        // nothing on-chain can either: `PrismMigration` has no sweep, so a wrong root locks the entire
        // reserve permanently. Verify it here too, so the failure surfaces before anyone reaches a
        // broadcast rather than during one.
        if (cfg.migrationAmount > 0) {
            string memory canary = vm.readFile(vm.envString("CANARY_PATH"));
            require(vm.parseJsonBytes32(canary, ".root") == cfg.merkleRoot,
                    "MERKLE_ROOT does not match the canary file - wrong or stale root");
            require(vm.parseJsonUint(canary, ".total") == cfg.treeTotal,
                    "MERKLE_TOTAL does not match the canary file");
            address acct = vm.parseJsonAddress(canary, ".account");
            d.verifyCanaryLeaf(cfg.merkleRoot, acct, vm.parseJsonUint(canary, ".amount"),
                               vm.parseJsonBytes32Array(canary, ".proof"));
            console2.log("canary leaf verified for      :", acct);
        } else {
            console2.log("no airdrop (MIGRATION_AMOUNT == 0), canary not applicable");
        }

        // `Renounce.s.sol` enforces MIN_SEED_LIQUIDITY on-chain before it gives up ownership, and it is
        // the operator's own env value — so a floor set above the liquidity actually being seeded makes
        // the renounce refuse. That is recoverable (correct the value and re-run; the owner key still
        // exists, and refusing is the safe direction) but there is no reason to discover it after the
        // irreversible steps. Catch it here, where nothing has been broadcast.
        uint256 minLiquidity = vm.envOr("MIN_SEED_LIQUIDITY", uint256(0));
        if (minLiquidity > 0) {
            require(minLiquidity <= cfg.liquidity,
                    "MIN_SEED_LIQUIDITY exceeds SEED_LIQUIDITY - the renounce step would refuse forever");
            console2.log("min seeded liquidity floor    :", minLiquidity);
        } else {
            console2.log("MIN_SEED_LIQUIDITY unset - the renounce step will not re-check the seed");
        }

        // `MIN_SEED_PRISM` is not a field of `RawConfig`, so `validateConfig` never sees it and this script
        // could not either — it would print PREFLIGHT PASSED for a floor above the seed the configured
        // liquidity actually deposits, and the operator met the refusal at step 4 of 4 inside the
        // broadcast section instead. Nothing is lost (a revert in simulation aborts the whole run before
        // anything is signed) but catching it here is the entire purpose of this script, and the sibling
        // knob above is already covered, so the omission was asymmetric rather than deliberate.
        //
        // What this can check without state: the floor cannot exceed the float, because the float is all
        // the PRISM the hook holds and therefore a hard upper bound on any deposit. That catches a
        // wei-versus-ether slip and any grossly wrong value. It does NOT catch a floor set just above what
        // the configured liquidity happens to deposit — computing that needs `TickMath.getSqrtPriceAtTick`
        // for `SEED_TICK_LOWER`, and the vendored v4-core does not include TickMath, so an exact figure
        // here would mean either a hardcoded tick constant or a second implementation of TickMath to keep
        // in step. Both are worse than deferring to `validateSeededAmount`, which measures the real
        // deposit in the dry run. Use `merkle/make-env.mjs` and the two agree by construction.
        uint256 minSeedPrism = vm.envOr("MIN_SEED_PRISM", uint256(0));
        if (minSeedPrism > 0) {
            require(minSeedPrism <= 5000 ether - cfg.migrationAmount,
                    "MIN_SEED_PRISM exceeds the whole float - no seed could ever satisfy it");
            console2.log("min seeded PRISM floor        :", minSeedPrism);
        }

        console2.log("");
        console2.log("PREFLIGHT PASSED - the pre-chain config guards only.");
        console2.log("");
        console2.log("THIS IS NOT THE WHOLE CHECK. Two guards need state that only exists after seeding,");
        console2.log("so they can only run in the dry run, NOT here:");
        console2.log("  validatePoolTick    - catches a price that is not exactly AT SEED_TICK_UPPER,");
        console2.log("                        i.e. a phantom quote a one-wei trade erases. A price one wei");
        console2.log("                        off passes THIS script and is caught only by the dry run.");
        console2.log("  validateSeededAmount - catches an undersized seed, which bricks the fee layer. It");
        console2.log("                        also enforces MIN_SEED_PRISM against the REAL deposit, which");
        console2.log("                        only exists after seeding - this script can only bound that");
        console2.log("                        floor by the float, not compare it to the actual deposit.");
        console2.log("");
        console2.log("It also cannot tell you whether the valuation is the one you INTEND - only that the");
        console2.log("price and TARGET_FDV_WEI agree. Check the FDV above against your plan yourself.");
        console2.log("");
        console2.log("Next: the dry run in LAUNCH.md step 4. Do not skip it.");
    }
}
