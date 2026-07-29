// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

interface IHD {
    function seed(uint160, int24, int24, uint128) external returns (uint256);
    function seeded() external view returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// Exercises Deploy.s.sol's new post-seed tick check (which NO test in the repo covers) against
/// (a) the seed price every fork test in this repo uses, and (b) the three sqrtPriceX96 values
/// DEPLOY.md publishes as "the exact TickMath.getSqrtPriceAtTick(tickUpper) values".
contract TickProbe is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM         = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2      = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant OWNER = address(0xB0B);
    uint256 constant FORK_BLOCK = 25604624;

    function _deploy(address at) internal returns (IHD) {
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(POOL_MANAGER, OWNER, POSM, PERMIT2, address(0), uint256(0)), at);
        return IHD(at);
    }

    function _openTick(address h) internal view returns (int24) {
        bytes32 slot0 = _extsload(keccak256(abi.encode(_poolId(h), uint256(6))));
        return int24(uint24(uint256(slot0) >> 160));   // Deploy.s.sol's exact expression
    }

    /// The historical fixture bug, kept as a regression demonstration — and the proof of its fix.
    ///
    /// `3913302148887442652215400988672` was the seed price shared by EVERY fork test in this suite. It
    /// is neither tick 76600 nor tick 78000: it is `floor(sqrt(1.0001^78000) * 2^96)`, the float formula
    /// the runbook warns is wrong by construction, landing 1.68e18 wei below the true tick-78000 price.
    /// Paired with a declared `tickUpper = 76600` it opened the pool at tick 77999 — a 1,399-tick phantom
    /// quote with no liquidity behind it, which is exactly what `Deploy.s.sol`'s post-seed tick check
    /// rejects. So the whole fork suite was validating a pool shape production forbids.
    ///
    /// The fixtures now use the exact integer-TickMath value. This pins both halves: the old constant
    /// really did miss its declared tick, and the replacement really does land on it.
    function test_FloatDerivedSeedPriceMissesItsDeclaredTick() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);

        uint160 floatDerived = 3913302148887442652215400988672;  // the old, wrong fixture
        uint160 exactAt76600 = 3648751508805509367250261525102;  // integer TickMath at 76600

        IHD bad = _deploy(address(0x2040));
        vm.prank(OWNER);
        bad.seed(floatDerived, -887200, 76600, 80e18);
        bytes32 slot0 = _extsload(keccak256(abi.encode(_poolId(address(0x2040)), uint256(6))));
        assertEq(uint160(uint256(slot0)), floatDerived,
                 "slot 6 + poolId derivation are CORRECT: sqrtPriceX96 round-trips exactly");
        int24 badTick = int24(uint24(uint256(slot0) >> 160));
        console2.log("declared SEED_TICK_UPPER          : 76600");
        console2.log("float-derived price opened at tick:", vm.toString(int256(badTick)));
        assertEq(badTick, 77999, "the float-derived constant opens 1399 ticks above its declared tick");

        // The correction: the exact value opens AT tickUpper, so there is no phantom quote at all.
        IHD good = _deploy(address(0x6040));
        vm.prank(OWNER);
        good.seed(exactAt76600, -887200, 76600, 80e18);
        int24 goodTick = _openTick(address(0x6040));
        console2.log("exact TickMath price opened at tick:", vm.toString(int256(goodTick)));
        assertEq(goodTick, 76600, "the corrected fixture price must open AT its declared tickUpper");
    }

    /// The three published table rows. If any of these is not exactly at its tick, an operator who
    /// copies the table hits `pool did not open AT SEED_TICK_UPPER` after seed() has already fired.
    function test_PublishedSqrtPriceTableAgainstRealPoolManager() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);

        address[3] memory hooks = [address(0x2040), address(0x6040), address(0xA040)];
        int24[3]   memory ticks = [int24(62000), int24(39000), int24(16000)];
        uint160[3] memory prices = [
            uint160(1758430331955991512042274893876),
            uint160(556815713337552406329560678361),
            uint160(176318465955219228901572735582)
        ];
        for (uint256 i; i < 3; ++i) {
            IHD h = _deploy(hooks[i]);
            vm.prank(OWNER);
            h.seed(prices[i], -887200, ticks[i], 1e18);
            int24 got = _openTick(hooks[i]);
            console2.log("DEPLOY.md row tickUpper =", vm.toString(int256(ticks[i])),
                         " -> pool opened at", vm.toString(int256(got)));
            assertEq(int256(got), int256(ticks[i]), "published sqrtPriceX96 is not at its tick");
        }
    }

    /// Negative and zero opening ticks read back correctly through the same expression, against the
    /// real PoolManager (not just synthetically).
    function test_NegativeAndZeroOpeningTickReadBackCorrectly() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);
        IHD a = _deploy(address(0x2040));
        vm.prank(OWNER);
        a.seed(79228162514264337593543950336, -887200, 0, 5e18);       // exactly 2^96 -> tick 0
        console2.log("sqrtPrice == 2^96      -> tick", vm.toString(int256(_openTick(address(0x2040)))));
        assertEq(int256(_openTick(address(0x2040))), 0);

        // A NEGATIVE opening tick: exact TickMath price at tick -200.
        IHD b = _deploy(address(0x6040));
        vm.prank(OWNER);
        b.seed(78440567123602892457812750159, -887200, -200, 5e18);
        int24 t = _openTick(address(0x6040));
        console2.log("negative tick read back:", vm.toString(int256(t)));
        assertEq(int256(t), -200, "negative int24 extraction from bits 160..183 is CORRECT");
    }

    function _poolId(address hookAddr) private pure returns (bytes32) {
        return keccak256(abi.encode(address(0), hookAddr, uint24(10000), int24(200), hookAddr));
    }
    function _extsload(bytes32 slot) private view returns (bytes32 v) {
        (bool ok, bytes memory ret) = POOL_MANAGER.staticcall(
            abi.encodeWithSignature("extsload(bytes32)", slot));
        require(ok && ret.length >= 32, "extsload failed");
        v = abi.decode(ret, (bytes32));
    }
}
