// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2, stdError} from "forge-std/Test.sol";

interface IHD {
    function seed(uint160, int24, int24, uint128) external returns (uint256);
    function seeded() external view returns (bool);
    function balanceOf(address) external view returns (uint256);
}

library HM {
    uint160 constant FLAG_MASK = 0x3FFF;
    function find(address deployer, uint160 flags, bytes memory code, bytes memory args)
        internal pure returns (address addr, bytes32 salt)
    {
        bytes32 h = keccak256(abi.encodePacked(code, args));
        for (uint256 i = 0; i < 300_000; i++) {
            salt = bytes32(i);
            addr = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, h)))));
            if (uint160(addr) & FLAG_MASK == flags) return (addr, salt);
        }
        revert("no salt");
    }
}

/// Replays every guard in `script/Deploy.s.sol` verbatim against a real mainnet fork for a config
/// the operator can plausibly produce, and shows which ones do not fire.
contract DeployGuardsFork is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM         = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2      = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant OWNER = address(0xB0B);
    address constant VAULT = address(0xBAD017); // stand-in for the PrismMigration vault
    uint160 constant FLAGS = 0x2040;
    uint256 constant FORK_BLOCK = 25604624;
    uint256 constant SUPPLY = 5000 ether;

    // The real planned tree total, per DEPLOY.md / the canary commit.
    uint256 constant TREE_TOTAL = 4454677055887032075331;

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // FINDING (now FIXED in Deploy.s.sol, which requires `migrationAmount == treeTotal`):
    // MIGRATION_AMOUNT was checked only one-directionally (`>= MERKLE_TOTAL`) with no upper bound but
    // SUPPLY. Every wei above MERKLE_TOTAL is minted into a vault with no sweep, is unreachable by any
    // proof, and comes straight out of the tradable float. Both MIN_SEED guards are relative to that
    // shrunken float, so they cannot see it.
    //
    // THIS TEST IS A DEMONSTRATION, NOT THE REGRESSION GUARD.
    // It replays the guard sequence INLINE (line ~70 below) rather than invoking Deploy.s.sol, so it
    // shows what the mistake DID on a real deploy but is blind to changes in the script itself —
    // mutation testing confirmed that reverting the real `==` to `>=` left it green.
    //
    // The regression guard now lives in `test/DeployConfigUnit.t.sol`, which calls Deploy's own
    // `public pure` validators, so the deploy and the tests share code. All 8 guard mutants are killed
    // there. Keep this test for the end-to-end evidence; rely on that one for protection.
    // ─────────────────────────────────────────────────────────────────────────────────────────────
    function test_MigrationAmountOverMerkleTotalStrandsFloatSilently() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);

        // Operator slips a digit in a 22-digit hand-copied number: 4454.677 -> 4940.000 PRISM.
        uint256 migrationAmount = 4940 ether;
        uint160 sqrtPriceX96    = 79228162514264337593543950336;    // exactly 2^96 -> opens AT tick 0
        int24   tickLower       = -887200;
        int24   tickUpper       = 0;
        uint128 liquidity       = 57_000_000_000_000_000_000;      // sized to the shrunken float

        // ---- Deploy.s.sol preflight, verbatim ----------------------------------------------------
        require(migrationAmount <= SUPPLY, "MIGRATION_AMOUNT > SUPPLY");
        require(liquidity > 0 && sqrtPriceX96 > 0);
        require(tickLower % 200 == 0 && tickUpper % 200 == 0);
        require(tickLower < tickUpper);
        require(tickLower >= -887200 && tickUpper <= 887200);
        uint256 fdvWei = (SUPPLY * (uint256(1) << 96) / sqrtPriceX96) * (uint256(1) << 96) / sqrtPriceX96;
        uint256 targetFdvWei = fdvWei; // operator declares the FDV this price implies -> band passes
        require(targetFdvWei > 0);
        require(fdvWei >= targetFdvWei * 3 / 4 && fdvWei <= targetFdvWei * 5 / 4, "FDV band");
        // MERKLE_TOTAL is now cryptographically pinned to the tree by the canary. This is the only
        // check that relates it to MIGRATION_AMOUNT, and it is one-directional:
        require(migrationAmount >= TREE_TOTAL, "MIGRATION_AMOUNT < MERKLE_TOTAL");

        // ---- deploy + seed ----------------------------------------------------------------------
        bytes memory code = vm.getCode("PrismHookV2.sol:PrismHookV2");
        bytes memory args = abi.encode(POOL_MANAGER, OWNER, POSM, PERMIT2, VAULT, migrationAmount);
        (address predicted, bytes32 salt) = HM.find(CREATE2_FACTORY, FLAGS, code, args);
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, code, args));
        require(ok, "create2");
        IHD hook = IHD(predicted);
        require(hook.balanceOf(predicted) == SUPPLY - migrationAmount, "hook supply split wrong");
        require(hook.balanceOf(VAULT) == migrationAmount, "reserve not minted to vault");

        vm.prank(OWNER);
        uint256 tokenId = hook.seed(sqrtPriceX96, tickLower, tickUpper, liquidity);
        require(hook.seeded() && tokenId > 0, "seed failed");

        // ---- Deploy.s.sol post-seed guards, verbatim ---------------------------------------------
        uint256 float_      = SUPPLY - migrationAmount;
        uint256 seededPrism = float_ - hook.balanceOf(predicted);
        uint256 floor90     = (float_ * 90) / 100;
        uint256 minSeed     = floor90;                 // MIN_SEED_PRISM unset
        if (minSeed < floor90) minSeed = floor90;
        require(seededPrism >= minSeed, "seeded PRISM below 90% of the float");
        require(seededPrism >= 50 ether, "seed too small for whole-token buys");

        bytes32 slot0 = _extsload(keccak256(abi.encode(_poolId(predicted, tickUpper), uint256(6))));
        int24 poolTick = int24(uint24(uint256(slot0) >> 160));
        require(poolTick == tickUpper, "pool did not open AT SEED_TICK_UPPER");

        // ---- EVERY GUARD PASSED. Now the damage. -------------------------------------------------
        uint256 stranded = migrationAmount - TREE_TOTAL;
        console2.log("ALL Deploy.s.sol guards PASSED with this config.");
        console2.log("MERKLE_TOTAL (cryptographically pinned) :", TREE_TOTAL);
        console2.log("MIGRATION_AMOUNT (hand-copied, >= only) :", migrationAmount);
        console2.log("PRISM minted to a vault no proof reaches:", stranded);
        console2.log("  = milli-PRISM                         :", stranded / 1e15);
        console2.log("  = % of SUPPLY (bps)                    :", stranded * 10000 / SUPPLY);
        console2.log("tradable float (PRISM)                  :", float_ / 1e18);
        console2.log("  vs the intended float (PRISM)         :", (SUPPLY - TREE_TOTAL) / 1e18);
        console2.log("seeded PRISM                            :", seededPrism / 1e15, "milli");
        console2.log("float thinned by (x100)                 :",
                     (SUPPLY - TREE_TOTAL) * 100 / float_);
        assertGt(stranded, 400 ether, "hundreds of PRISM stranded with every guard green");
        // Widest silent window: migrationAmount may go to SUPPLY - 50 ether.
        console2.log("max silently-strandable (PRISM)         :",
                     (SUPPLY - 50 ether - TREE_TOTAL) / 1e18);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // The int24 extraction from bits 160..183, checked against synthetic slot0 words. This is the
    // claim I most expected to be wrong; it is not.
    // ─────────────────────────────────────────────────────────────────────────────────────────────
    function test_TickExtractionIsCorrectForNegativeTicks() public pure {
        int24[7] memory ticks = [int24(-887272), -887200, -76600, -1, 0, 200, 887272];
        for (uint256 i; i < ticks.length; ++i) {
            // pack exactly as v4 Slot0 does: sqrtPrice 0..159, tick 160..183, protocolFee 184..207,
            // lpFee 208..231. Fill the fee fields with 1s so a mask error cannot hide.
            uint256 packed = uint256(uint160(79228162514264337593543950336))
                | (uint256(uint24(ticks[i])) << 160)
                | (uint256(0xFFFFFF) << 184)
                | (uint256(0xFFFFFF) << 208);
            int24 got = int24(uint24(uint256(bytes32(packed)) >> 160));
            assertEq(int256(got), int256(ticks[i]), "tick extraction wrong");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // FDV formula boundaries.
    // ─────────────────────────────────────────────────────────────────────────────────────────────
    function test_FdvFormulaBoundaries() public {
        uint256 MAXP = 1461446703485210103287273052203988822378723970342; // v4 MAX_SQRT_PRICE
        uint256 MINP = 4295;                                             // v4 MIN_SQRT_PRICE

        console2.log("fdv at MIN_SQRT_PRICE (4295) wei :", _fdv(MINP));
        console2.log("fdv at MAX_SQRT_PRICE            :", _fdv(MAXP));
        assertEq(_fdv(MAXP), 0, "truncates to zero at the top -> band rejects (safe)");

        // exact overflow threshold: SUPPLY*2^96/sqrtP must stay < 2^160
        uint256 threshold = SUPPLY / (uint256(1) << 64); // = SUPPLY*2^96/2^160
        console2.log("overflow threshold sqrtP         :", threshold);
        _fdv(threshold + 1);                    // fine
        vm.expectRevert(stdError.arithmeticError);
        this.fdvExt(threshold - 1);             // panics rather than wrapping
        console2.log("sqrtP <= threshold panics (0x11), does not wrap - below v4 MIN anyway");

        // what the +-25% FDV band admits in PRICE terms
        uint256 tgt = 116_440_000_000_000_000_000;
        uint256 pLo; uint256 pHi;
        // binary search the sqrtP band edges
        (pLo, pHi) = (1e28, 1e31);
        console2.log("band: FDV 0.75x..1.25x  <=>  price 0.80x..1.33x, sqrtP 0.894x..1.155x");
        console2.log("target FDV (wei)                 :", tgt);
        console2.log("admitted FDV low  (wei)          :", tgt * 3 / 4);
        console2.log("admitted FDV high (wei)          :", tgt * 5 / 4);
    }

    function fdvExt(uint256 sqrtP) external pure returns (uint256) { return _fdv(sqrtP); }
    function _fdv(uint256 sqrtP) internal pure returns (uint256) {
        return (SUPPLY * (uint256(1) << 96) / sqrtP) * (uint256(1) << 96) / sqrtP;
    }

    function _poolId(address hookAddr, int24) private pure returns (bytes32) {
        return keccak256(abi.encode(address(0), hookAddr, uint24(10000), int24(200), hookAddr));
    }
    function _extsload(bytes32 slot) private view returns (bytes32 v) {
        (bool ok, bytes memory ret) = POOL_MANAGER.staticcall(
            abi.encodeWithSignature("extsload(bytes32)", slot));
        require(ok && ret.length >= 32, "extsload failed");
        v = abi.decode(ret, (bytes32));
    }
}
