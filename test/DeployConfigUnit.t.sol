// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// Regression tests for `Deploy.s.sol`'s configuration guards.
///
/// Every guard here defends a mistake that deploys CLEANLY and bricks an immutable contract forever, so
/// each one needs a test that fails if the guard weakens. The critical word is *shares code*: an earlier
/// version of this coverage replayed the guard sequence inline in the test file, and mutation testing
/// showed that was worthless — reverting a real guard in the script left the entire suite green. These
/// call `Deploy`'s own `public pure` validators, so a change to the script fails here.
///
/// Not env-driven on purpose: `vm.setEnv` is process-global and forge runs a contract's tests in
/// PARALLEL, so env-driven config tests race and flake.
contract DeployConfigUnit is Test {
    Deploy d;

    // The base fixture is the tick-37600 alternative, kept deliberately: exercising a DIFFERENT valid
    // configuration from the one DEPLOY.md ships proves the guards accept a range of good configs rather
    // than one hard-coded set. `test_TheShippedConfigurationPasses` below pins the canonical §2 config.
    uint256 constant TREE_TOTAL = 4454677055887032075331;
    uint256 constant SQRT_PRICE = 519173346924859298652142127695;
    uint256 constant LIQUIDITY  = 80951486627637257491;
    uint256 constant TARGET_FDV = 116440000000000000000;

    // DEPLOY.md §2's shipped configuration, tick 44800, seeding the entire float.
    uint256 constant SHIP_SQRT_PRICE = 744133035780855425119189031190;
    uint256 constant SHIP_LIQUIDITY  = 58060767042176831420;
    uint256 constant SHIP_TARGET_FDV = 56679759771485417094;
    uint256 constant SHIP_MIN_SEED   = 545322943111967924665;

    function setUp() public { d = new Deploy(); }

    function _valid() internal pure returns (Deploy.RawConfig memory c) {
        c = Deploy.RawConfig({
            merkleRoot:      bytes32(uint256(0x2cd6)), // any nonzero root; the canary check is separate
            migrationAmount: TREE_TOTAL,
            treeTotal:       TREE_TOTAL,
            sqrtPriceX96:    SQRT_PRICE,
            tickLower:       -887200,
            tickUpper:       37600,
            liquidity:       LIQUIDITY,
            targetFdvWei:    TARGET_FDV,
            saltNonce:       1
        });
    }

    /// The exact block a reader copies out of DEPLOY.md §2 must pass every guard. Without this the docs
    /// and the suite could drift — the fixture above is a different tick, so nothing else pins the shipped
    /// numbers, and a stranger following the runbook is the person who finds out.
    function test_TheShippedConfigurationPasses() public view {
        Deploy.RawConfig memory c = Deploy.RawConfig({
            merkleRoot:      bytes32(uint256(0x2cd6)),
            migrationAmount: TREE_TOTAL,
            treeTotal:       TREE_TOTAL,
            sqrtPriceX96:    SHIP_SQRT_PRICE,
            tickLower:       -887200,
            tickUpper:       44800,
            liquidity:       SHIP_LIQUIDITY,
            targetFdvWei:    SHIP_TARGET_FDV,
            saltNonce:       1
        });
        Deploy.SeedParams memory p = d.validateConfig(c);
        assertEq(p.tickUpper, 44800, "shipped launch tick");
        assertEq(uint256(p.liquidity), SHIP_LIQUIDITY, "shipped liquidity");
        // The documented implied FDV, to the wei.
        assertEq(d.impliedFdvWei(SHIP_SQRT_PRICE), 56679759771485417094);
        // And the shipped MIN_SEED_PRISM must actually RAISE the bar. `validateSeededAmount` takes
        // max(env, 90% of float), so emitting the 90% floor itself — which the generator used to do —
        // left the knob inert and up to 10% of the float (54.53 PRISM) strandable in a hook that is
        // excluded from fee shares and, once renounced, has no path back out.
        uint256 float_ = 5000 ether - TREE_TOTAL;
        assertGt(SHIP_MIN_SEED, (float_ * 90) / 100, "MIN_SEED_PRISM must raise the bar, not restate it");

        // DERIVE it rather than trusting the constant above, with the same formula `make-env.mjs` uses:
        // ceil(L * (sqrtUpper - sqrtLower) / 2^96) - 1e12. A hand-copied constant here has gone stale
        // TWICE — once when the seed headroom changed, once when a one-wei ceiling bug was fixed in the
        // generator — and both times every guard still passed, because `validateConfig` never
        // discriminates on this value. Tying it to the arithmetic makes drift a test failure instead of a
        // silent disagreement between the repo and the config an operator actually pastes.
        uint256 sqrtLower = 4310618292;              // TickMath.getSqrtPriceAtTick(-887200)
        uint256 numerator = uint256(SHIP_LIQUIDITY) * (SHIP_SQRT_PRICE - sqrtLower);
        uint256 deposit   = numerator / (1 << 96) + (numerator % (1 << 96) == 0 ? 0 : 1);  // ceiling, as v4 charges
        assertEq(SHIP_MIN_SEED, deposit - 1e12, "MIN_SEED_PRISM is not what make-env.mjs emits");
        // And the deposit is the whole float bar the documented rounding headroom.
        assertEq(float_ - deposit, 1000000004, "seed headroom is not the documented residual");
    }

    /// The point of the raised bar: the 90%-of-float seed that used to deploy cleanly, stranding 54.53
    /// PRISM forever, is now rejected in simulation.
    function test_UnderSeedingTheFloatNowReverts() public {
        uint256 float_ = 5000 ether - TREE_TOTAL;
        uint256 ninetyPct = (float_ * 90) / 100;
        // Sanity: this is exactly what the old generator emitted, and what it used to permit.
        assertEq(ninetyPct, 490790649701671132202);
        vm.expectRevert(bytes("seeded PRISM below 90% of the float"));
        d.validateSeededAmount(float_, ninetyPct, SHIP_MIN_SEED);
        // And the shipped seed itself still passes.
        d.validateSeededAmount(float_, SHIP_MIN_SEED, SHIP_MIN_SEED);
        emit log_named_uint("PRISM no longer strandable (wei)", float_ - ninetyPct);
    }

    function test_TheRealConfigPasses() public view {
        Deploy.SeedParams memory p = d.validateConfig(_valid());
        assertEq(p.tickUpper, 37600);
        assertEq(uint256(p.liquidity), LIQUIDITY);
        assertEq(uint256(p.sqrtPriceX96), SQRT_PRICE);
    }

    /// A fair launch with no airdrop is legitimate: zero reserve AND a zero root.
    function test_FairLaunchWithNoAirdropPasses() public view {
        Deploy.RawConfig memory c = _valid();
        c.merkleRoot = bytes32(0);
        c.migrationAmount = 0;
        c.treeTotal = 0;
        d.validateConfig(c);
    }

    // ── the 495-PRISM strand: MIGRATION_AMOUNT must EQUAL the tree, not merely cover it ──────────

    function test_ReserveAboveTreeTotalIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.migrationAmount = 4940 ether;   // a slipped digit; every other guard passes
        vm.expectRevert("MIGRATION_AMOUNT != MERKLE_TOTAL");
        d.validateConfig(c);
    }

    /// The whole silent window, sampled across its width. Every wei above the tree is minted into a
    /// vault no proof can reach and comes straight out of the tradable float.
    function test_AnyReserveAboveTheTreeIsRejected(uint256 excess) public {
        excess = bound(excess, 1, 495 ether);
        Deploy.RawConfig memory c = _valid();
        c.migrationAmount = TREE_TOTAL + excess;
        vm.expectRevert("MIGRATION_AMOUNT != MERKLE_TOTAL");
        d.validateConfig(c);
    }

    function test_ReserveBelowTreeTotalIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.migrationAmount = TREE_TOTAL - 1;
        vm.expectRevert("MIGRATION_AMOUNT != MERKLE_TOTAL");
        d.validateConfig(c);
    }

    /// The wei-vs-ether slip: `4455` reads as 4,455 WEI, against which every real allocation fails.
    function test_WeiVersusEtherSlipIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.migrationAmount = 4455;
        vm.expectRevert("MIGRATION_AMOUNT != MERKLE_TOTAL");
        d.validateConfig(c);
    }

    function test_MerkleTotalUnsetIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.treeTotal = 0;
        vm.expectRevert("MERKLE_TOTAL not set");
        d.validateConfig(c);
    }

    // ── root / reserve must agree, or the reserve locks forever ──────────────────────────────────

    function test_ZeroRootWithNonzeroReserveIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.merkleRoot = bytes32(0);
        vm.expectRevert("MERKLE_ROOT/MIGRATION_AMOUNT mismatch");
        d.validateConfig(c);
    }

    function test_NonzeroRootWithZeroReserveIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.migrationAmount = 0;
        vm.expectRevert("MERKLE_ROOT/MIGRATION_AMOUNT mismatch");
        d.validateConfig(c);
    }

    function test_ReserveAboveSupplyIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.migrationAmount = 5001 ether;
        vm.expectRevert("MIGRATION_AMOUNT > SUPPLY");
        d.validateConfig(c);
    }

    // ── silent narrowing: a value one digit too long becomes a different, valid parameter ────────

    function test_TickTruncationIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.tickUpper = 16777416;   // narrows to 200 — a ~2,000,000x price error
        vm.expectRevert("SEED_TICK_UPPER truncated");
        d.validateConfig(c);
    }

    function test_LiquidityTruncationIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.liquidity = uint256(type(uint128).max) + 1 + LIQUIDITY; // wraps to a dusting
        vm.expectRevert("SEED_LIQUIDITY truncated");
        d.validateConfig(c);
    }

    function test_SqrtPriceTruncationIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.sqrtPriceX96 = (uint256(1) << 160) + SQRT_PRICE;
        vm.expectRevert("SEED_SQRT_PRICE_X96 truncated");
        d.validateConfig(c);
    }

    // ── tick hygiene ────────────────────────────────────────────────────────────────────────────

    function test_MisalignedTickIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.tickUpper = 37601;
        vm.expectRevert("ticks must be multiples of 200");
        d.validateConfig(c);
    }

    function test_InvertedRangeIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.tickLower = 37600;
        c.tickUpper = -887200;
        vm.expectRevert("SEED_TICK_LOWER >= SEED_TICK_UPPER");
        d.validateConfig(c);
    }

    function test_OutOfRangeTickIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.tickLower = -887400;
        vm.expectRevert("tick out of range");
        d.validateConfig(c);
    }

    function test_ZeroLiquidityIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.liquidity = 0;
        vm.expectRevert("SEED_LIQUIDITY == 0");
        d.validateConfig(c);
    }

    // ── the economic guard: alignment and range say nothing about price ──────────────────────────

    /// The launch this guard exists for: tick 887200 is aligned, in range, and sells all 5000 PRISM for
    /// about one gwei. Only the FDV band catches it.
    function test_ExtremeButAlignedTickIsRejectedByTheFdvBand() public {
        Deploy.RawConfig memory c = _valid();
        c.tickUpper = 887200;
        // price at that tick: astronomically many PRISM per ETH, so the implied FDV collapses.
        c.sqrtPriceX96 = 1461446703485210103287273052203988822378723970341; // MAX_SQRT_PRICE
        // Caught by the ABSOLUTE floor now, which is strictly better: the relative band could not catch
        // this at all once the implied FDV floors to zero.
        vm.expectRevert("implied FDV is essentially zero - SEED_SQRT_PRICE_X96 sells the supply for nothing");
        d.validateConfig(c);
    }

    /// The hole the relative band could never close, found by re-auditing the fix that claimed to close
    /// it. `impliedFdvWei` floors to 0 above sqrtPrice ~5.6e39, which covers 1,938 aligned in-range ticks,
    /// and `1 * 3 / 4 == 0` puts a zero FDV inside the band against TARGET_FDV_WEI = 1. Every other guard
    /// passed, including the post-seed tick check, because the price genuinely IS at tickUpper.
    function test_ZeroImpliedFdvWithTinyTargetIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.tickUpper = 887200;
        c.sqrtPriceX96 = 5602277097478613991873193822745817176232; // first value that floors FDV to 0
        c.targetFdvWei = 1;
        vm.expectRevert("TARGET_FDV_WEI implausible - state the valuation in WEI of ETH");
        d.validateConfig(c);
    }

    /// And with a plausible-looking target, the zero FDV itself is rejected.
    function test_ZeroImpliedFdvIsRejectedOnItsOwn() public {
        Deploy.RawConfig memory c = _valid();
        c.tickUpper = 887200;
        c.sqrtPriceX96 = 5602277097478613991873193822745817176232;
        vm.expectRevert("implied FDV is essentially zero - SEED_SQRT_PRICE_X96 sells the supply for nothing");
        d.validateConfig(c);
    }

    /// A units error that scales BOTH inputs passes any purely relative band to the wei: TARGET_FDV_WEI
    /// = 100 meaning "100 ETH", with a price derived from the same mistake, implies exactly 100 wei.
    /// Only an absolute floor catches it.
    function test_UnitsErrorInTargetIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.targetFdvWei = 100;                       // operator meant 100 ETH, typed 100 wei
        vm.expectRevert("TARGET_FDV_WEI implausible - state the valuation in WEI of ETH");
        d.validateConfig(c);
    }

    /// `targetFdvWei * 3 / 4` panicked unnamed above ~3.85e76.
    function test_AbsurdlyLargeTargetIsRejectedByName() public {
        Deploy.RawConfig memory c = _valid();
        c.targetFdvWei = 4e76;
        vm.expectRevert("TARGET_FDV_WEI implausible - state the valuation in WEI of ETH");
        d.validateConfig(c);
    }

    /// The ceiling said "MAX_SQRT_PRICE - 1" in its comment and admitted MAX_SQRT_PRICE itself, which v4
    /// rejects — the unnamed-failure outcome the guard exists to prevent.
    function test_ExactlyMaxSqrtPriceIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.sqrtPriceX96 = 1461446703485210103287273052203988822378723970342;
        vm.expectRevert("SEED_SQRT_PRICE_X96 outside v4's usable range");
        d.validateConfig(c);
    }

    function test_TargetFdvUnsetIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.targetFdvWei = 0;
        vm.expectRevert("TARGET_FDV_WEI not set - state the valuation you intend");
        d.validateConfig(c);
    }

    /// The band is +-25%. Just inside must pass and just outside must fail, or the band is decorative.
    function test_FdvBandBoundaries() public {
        Deploy.RawConfig memory c = _valid();
        uint256 actual = d.impliedFdvWei(SQRT_PRICE);

        c.targetFdvWei = actual * 100 / 76;   // actual is ~76% of target: inside
        d.validateConfig(c);
        c.targetFdvWei = actual * 100 / 124;  // actual is ~124% of target: inside
        d.validateConfig(c);

        c.targetFdvWei = actual * 100 / 74;   // actual is 74% of target: outside
        vm.expectRevert("SEED_SQRT_PRICE_X96 implies an FDV more than 25% from TARGET_FDV_WEI");
        d.validateConfig(c);
    }

    /// The FDV formula must be right, not merely present: the real config's implied FDV is 116.44 ETH.
    function test_ImpliedFdvMatchesTheForkVerifiedValue() public view {
        assertEq(d.impliedFdvWei(SQRT_PRICE), 116440589188638372255);
        // And the $200k option.
        assertEq(d.impliedFdvWei(744133035780855425119189031190), 56679759771485417094);
    }

    /// v4's usable price range, checked by name rather than by panic. Below sqrtPrice 272 the implied-FDV
    /// multiplication overflows into a bare arithmetic panic with no message; at the top of uint160 it
    /// truncates to 0, which then satisfies a purely relative FDV band against any small target. Both were
    /// fail-safe but produced an unexplained failure instead of a named one.
    function test_SqrtPriceBelowV4MinIsRejectedByName() public {
        Deploy.RawConfig memory c = _valid();
        c.sqrtPriceX96 = 4295128738;                 // MIN_SQRT_PRICE - 1
        vm.expectRevert("SEED_SQRT_PRICE_X96 outside v4's usable range");
        d.validateConfig(c);
    }

    function test_SqrtPriceAboveV4MaxIsRejectedByName() public {
        Deploy.RawConfig memory c = _valid();
        c.sqrtPriceX96 = 1461446703485210103287273052203988822378723970343; // MAX_SQRT_PRICE
        vm.expectRevert("SEED_SQRT_PRICE_X96 outside v4's usable range");
        d.validateConfig(c);
    }

    /// The overflow case specifically: this used to panic (0x11) with no message at all.
    function test_TinySqrtPriceNoLongerPanicsUnnamed() public {
        Deploy.RawConfig memory c = _valid();
        c.sqrtPriceX96 = 271;
        vm.expectRevert("SEED_SQRT_PRICE_X96 outside v4's usable range");
        d.validateConfig(c);
    }

    /// And a degenerate target must not be waved through by a relative-only band against a zero FDV.
    function test_MaxSqrtPriceWithTinyTargetIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.sqrtPriceX96 = type(uint160).max;
        c.targetFdvWei = 1;
        vm.expectRevert("SEED_SQRT_PRICE_X96 outside v4's usable range");
        d.validateConfig(c);
    }

    function test_ZeroSqrtPriceIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.sqrtPriceX96 = 0;
        vm.expectRevert("SEED_SQRT_PRICE_X96 == 0");
        d.validateConfig(c);
    }

    // ── CREATE2 squat defence ───────────────────────────────────────────────────────────────────

    function test_ZeroSaltNonceIsRejected() public {
        Deploy.RawConfig memory c = _valid();
        c.saltNonce = 0;
        vm.expectRevert("SALT_NONCE must be set to a random secret, not 0");
        d.validateConfig(c);
    }

    // ── post-seed: how much PRISM actually entered the pool ──────────────────────────────────────

    function test_TheRealSeedAmountPasses() public view {
        d.validateSeededAmount(545.322944112967924669 ether, 530.466098383219207988 ether, 0);
    }

    /// An undersized seed bricks the fee layer permanently. Below 90% of the float must fail even when
    /// the absolute floor is satisfied.
    function test_SeedBelowNinetyPercentOfFloatIsRejected() public {
        vm.expectRevert("seeded PRISM below 90% of the float");
        d.validateSeededAmount(545 ether, 400 ether, 0);
    }

    /// MIN_SEED_PRISM may only RAISE the bar. A downward override was worse than no check at all.
    function test_MinSeedCannotLowerTheBar() public {
        vm.expectRevert("seeded PRISM below 90% of the float");
        d.validateSeededAmount(545 ether, 400 ether, 1); // tries to lower it to 1 wei
    }

    function test_MinSeedCanRaiseTheBar() public {
        // 530 of a 545 float clears the 90% floor, but not an explicit 540 bar.
        d.validateSeededAmount(545 ether, 530 ether, 0);
        vm.expectRevert("seeded PRISM below 90% of the float");
        d.validateSeededAmount(545 ether, 530 ether, 540 ether);
    }

    /// The absolute floor must be in WHOLE tokens: a ~1-PRISM pool yields buyers zero whole tokens, so
    /// `totalShares` never leaves 0 and every fee is forfeited forever.
    function test_TinySeedIsRejectedEvenAtFullFloat() public {
        vm.expectRevert("seed too small for whole-token buys: fee layer would never start");
        d.validateSeededAmount(10 ether, 10 ether, 0);   // 100% of the float, still far too small
    }

    // ── post-seed: the pool must open AT tickUpper, not above it ─────────────────────────────────

    function test_PoolTickMustEqualTickUpper() public {
        d.validatePoolTick(37600, 37600);
        vm.expectRevert("pool did not open AT SEED_TICK_UPPER (phantom price)");
        d.validatePoolTick(37599, 37600);
    }

    /// A price ABOVE tickUpper is the dangerous direction — a phantom quote a one-wei trade erases.
    function test_PhantomPriceAboveTickUpperIsRejected() public {
        vm.expectRevert("pool did not open AT SEED_TICK_UPPER (phantom price)");
        d.validatePoolTick(77999, 76600);   // the exact fixture bug this caught in the test suite
    }

    /// Negative ticks must compare correctly, since the planned range starts at -887200.
    function test_NegativeTickComparesCorrectly() public {
        d.validatePoolTick(-887200, -887200);
        vm.expectRevert("pool did not open AT SEED_TICK_UPPER (phantom price)");
        d.validatePoolTick(-887200, -887000);
    }

    // ── the canary ──────────────────────────────────────────────────────────────────────────────

    /// A single-leaf tree: the leaf IS the root, with an empty proof.
    function test_CanaryVerifiesASingleLeafTree() public view {
        address acct = address(0xA11CE);
        uint256 amt  = 1 ether;
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(acct, amt))));
        d.verifyCanaryLeaf(leaf, acct, amt, new bytes32[](0));
    }

    function test_CanaryRejectsAWrongRoot() public {
        address acct = address(0xA11CE);
        uint256 amt  = 1 ether;
        vm.expectRevert("canary proof does NOT verify against MERKLE_ROOT");
        d.verifyCanaryLeaf(bytes32(uint256(1)), acct, amt, new bytes32[](0));
    }

    /// An attacker-chosen amount must not verify against a root built for the real one — this is what
    /// stops a doctored canary from waving through a root from the wrong snapshot.
    function test_CanaryRejectsATamperedAmount() public {
        address acct = address(0xA11CE);
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(acct, uint256(1 ether)))));
        vm.expectRevert("canary proof does NOT verify against MERKLE_ROOT");
        d.verifyCanaryLeaf(root, acct, 2 ether, new bytes32[](0));
    }

    function test_CanaryRejectsATamperedAccount() public {
        uint256 amt  = 1 ether;
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(address(0xA11CE), amt))));
        vm.expectRevert("canary proof does NOT verify against MERKLE_ROOT");
        d.verifyCanaryLeaf(root, address(0xBEEF), amt, new bytes32[](0));
    }

    /// Two-leaf tree, both directions, to pin the sorted-pair order against `PrismMigration._verify`.
    function test_CanaryVerifiesATwoLeafTreeInBothDirections() public view {
        bytes32 a = keccak256(bytes.concat(keccak256(abi.encode(address(0xA), uint256(1)))));
        bytes32 b = keccak256(bytes.concat(keccak256(abi.encode(address(0xB), uint256(2)))));
        bytes32 root = a <= b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));

        bytes32[] memory proofA = new bytes32[](1); proofA[0] = b;
        bytes32[] memory proofB = new bytes32[](1); proofB[0] = a;
        d.verifyCanaryLeaf(root, address(0xA), 1, proofA);
        d.verifyCanaryLeaf(root, address(0xB), 2, proofB);
    }
}
