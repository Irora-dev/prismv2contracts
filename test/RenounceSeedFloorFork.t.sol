// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Renounce} from "../script/Renounce.s.sol";

interface IHookSeed {
    function seed(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external returns (uint256);
    function seeded() external view returns (bool);
    function hookPositionTokenId() external view returns (uint256);
    function owner() external view returns (address);
    function pokeFees() external;
}

interface IPosm {
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
}

/// `Renounce.s.sol` refuses to give up ownership when the position holds less liquidity than
/// `MIN_SEED_LIQUIDITY`, which `merkle/make-env.mjs` emits as `SEED_LIQUIDITY * 9999 / 10000`. That guard
/// exists because every seed check in `Deploy.s.sol` runs in simulation, and the runbook's own recovery
/// advice for a reverted step is to finish `seed()` by hand — a `cast send` with four typed values and no
/// validation, where a dropped digit strands the float in a contract about to become ownerless.
///
/// The guard is only correct if the liquidity the REAL PositionManager reports for a freshly seeded
/// position is the liquidity that was asked for. Nothing else in the suite checks that: the unit tests
/// drive a stub. If v4 rounded the minted liquidity down by more than one part in ten thousand, the floor
/// would refuse a perfectly good launch — and refusing to renounce leaves a live owner key forever, which
/// is the failure direction that actually matters here. So verify it against mainnet.
contract RenounceSeedFloorFork is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM         = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2      = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address constant HOOK  = address(0x2040);   // low 14 bits = beforeInitialize | afterSwap
    uint256 constant FORK_BLOCK = 25604624;

    // The shipped launch, from DEPLOY.md section 2 / make-env.mjs.
    uint160 constant SHIP_SQRT = 744133035780855425119189031190;   // exact TickMath at tick 44800
    int24   constant TICK_LOWER = -887200;
    int24   constant TICK_UPPER = 44800;
    uint128 constant SHIP_LIQUIDITY = 58060767042176831420;
    uint256 constant SHIP_FLOOR     = 58054960965472613736;        // SEED_LIQUIDITY * 9999 / 10000

    IHookSeed hook;
    Renounce script_;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);
        // No airdrop vault: this test is about the seed floor, and a zero vault is a legitimate launch
        // shape that the vault guards deliberately skip.
        // This contract owns the hook, so the script's `owner() == msg.sender` pre-check passes on a
        // direct call.
        //
        // Note what cannot be exercised here, and why it is not a defect: the script's checks run against
        // `msg.sender`, while `hook.renounceOwnership()` runs inside `vm.startBroadcast()` as the
        // configured broadcaster. In production `--sender <deployer>` makes those the same address. In a
        // test they cannot be: pranking the call so `msg.sender` matches makes `startBroadcast` refuse
        // ("broadcasting and pranks are not compatible"), and not pranking makes the broadcast act as
        // forge's default sender, which the real hook rejects as `Unauthorized()`. So the completed
        // renounce is covered by the stub tests in RenounceGuard.t.sol, and what THIS file establishes is
        // the part a stub cannot: what the real PositionManager reports for a real seeded position, which
        // is the input the new guard actually depends on.
        deployCodeTo(
            "PrismHookV2.sol:PrismHookV2",
            abi.encode(POOL_MANAGER, address(this), POSM, PERMIT2, address(0), uint256(0)),
            HOOK
        );
        hook = IHookSeed(HOOK);
        script_ = new Renounce();
    }

    /// The real POSM reports the requested liquidity, so the shipped floor cannot block a correct launch.
    /// This is the assumption the whole guard rests on and nothing else in the suite checked it.
    function test_RealPositionMeetsTheShippedFloor() public {
        uint256 tokenId = hook.seed(SHIP_SQRT, TICK_LOWER, TICK_UPPER, SHIP_LIQUIDITY);
        assertTrue(hook.seeded(), "seeded");
        assertEq(hook.hookPositionTokenId(), tokenId, "hook recorded its position");

        uint128 actual = IPosm(POSM).getPositionLiquidity(tokenId);
        console2.log("requested liquidity :", SHIP_LIQUIDITY);
        console2.log("POSM reports        :", actual);
        console2.log("floor               :", SHIP_FLOOR);

        // Exact, not approximate: v4 mints the liquidity it is given. If this ever becomes inexact the
        // floor's one-in-ten-thousand margin is the thing protecting the launch, so assert both.
        assertEq(uint256(actual), uint256(SHIP_LIQUIDITY), "POSM did not mint the requested liquidity");
        assertGe(uint256(actual), SHIP_FLOOR, "the shipped floor would block a correct launch");
        // Margin, stated explicitly: one part in ten thousand of headroom above the floor.
        assertEq(uint256(actual) - SHIP_FLOOR, 5806076704217684, "unexpected floor margin");
    }

    /// And the floor does its job against the failure it was written for: a dropped digit in the
    /// hand-typed liquidity. `seed()` is one-shot, so this state cannot be retried — refusing to renounce
    /// is the only remaining defence, and it keeps the owner key alive to salvage the launch.
    function test_AHandTypedDroppedDigitIsRefused() public {
        uint128 fatFingered = SHIP_LIQUIDITY / 10;   // 5806076704217683142

        uint256 tokenId = hook.seed(SHIP_SQRT, TICK_LOWER, TICK_UPPER, fatFingered);
        assertTrue(hook.seeded(), "seeded (badly)");

        uint128 actual = IPosm(POSM).getPositionLiquidity(tokenId);
        assertLt(uint256(actual), SHIP_FLOOR, "precondition: the bad seed is below the floor");

        vm.expectRevert(
            bytes("seeded liquidity is below MIN_SEED_LIQUIDITY - the pool was under-seeded, do NOT renounce")
        );
        script_.renounce(HOOK, SHIP_FLOOR);
        assertEq(hook.owner(), address(this), "owner key retained so the launch can still be salvaged");
    }

    /// Fees accrue into the position as tokens owed, not as liquidity, so the floor cannot drift out from
    /// under a launch that sat unrenounced for a while. (The hook can never rebalance either: `seed()` is
    /// its only owner function and reverts after use.)
    function test_TheFloorDoesNotDriftAsFeesAccrue() public {
        uint256 tokenId = hook.seed(SHIP_SQRT, TICK_LOWER, TICK_UPPER, SHIP_LIQUIDITY);
        uint128 atSeed = IPosm(POSM).getPositionLiquidity(tokenId);

        // `seed()` arms forfeitNextCollection, so burn that collection off first, then poke again.
        hook.pokeFees();
        vm.roll(block.number + 1);
        hook.pokeFees();

        assertEq(
            uint256(IPosm(POSM).getPositionLiquidity(tokenId)), uint256(atSeed),
            "position liquidity moved after collections"
        );
        assertGe(uint256(atSeed), SHIP_FLOOR, "still above the floor after fee activity");
    }
}
