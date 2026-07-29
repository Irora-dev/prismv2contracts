// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

interface IHookSeed {
    function seed(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external returns (uint256);
    function seeded() external view returns (bool);
    function hookPositionTokenId() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function pokeFees() external;
    function mirror() external view returns (address);
}

/// Closes the flagged gap: `seed()` (a one-shot, unrecoverable deploy step) is exercised against
/// the REAL mainnet Uniswap v4 PositionManager + PoolManager + Permit2 on a fork. If the v4 action
/// encoding (MINT_POSITION + SETTLE_PAIR) or the beforeInitialize gate were wrong, this reverts.
contract SeedFork is Test {
    // Real mainnet infra (read from the live PRISM deployment / canonical addresses).
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM         = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2       = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address constant OWNER = address(0xB0B);
    // Hook address with beforeInitialize (bit13) + afterSwap (bit6) = low-14-bits 0x2040.
    address constant HOOK = address(0x2040);

    uint256 constant FORK_BLOCK = 25604624;

    IHookSeed hook;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);
        deployCodeTo(
            "PrismHookV2.sol:PrismHookV2",
            abi.encode(POOL_MANAGER, OWNER, POSM, PERMIT2, address(0), uint256(0)),
            HOOK
        );
        hook = IHookSeed(HOOK);
    }

    function test_SeedAgainstRealPOSM() public {
        assertEq(hook.balanceOf(HOOK), 5000 ether, "hook holds full supply pre-seed");

        // Single-sided PRISM at the EXACT TickMath price for tickUpper, so the pool opens AT 76600 with
        // zero ETH owed on the other side. L=1e18 ~ 46 PRISM at this range.
        //
        // This was 3913302148887442652215400988672, which is neither tick 76600 nor tick 78000: it is
        // `floor(sqrt(1.0001^78000) * 2^96)`, the float formula the runbook warns is wrong by
        // construction, landing 1.68e18 wei below the true tick-78000 price. The pool therefore opened at
        // tick 77999 against a declared tickUpper of 76600 — a 1,399-tick phantom quote with no
        // liquidity behind it, which is exactly the state `Deploy.s.sol`'s post-seed tick check rejects.
        // Every fork test here shared the constant, so the suite was validating a shape production
        // forbids. Take these from DEPLOY.md's table or integer TickMath, never from a spreadsheet.
        uint160 sqrtPriceX96 = 3648751508805509367250261525102;
        int24   tickLower    = -887200;
        int24   tickUpper    = 76600;
        uint128 liquidity    = 1e18;

        vm.prank(OWNER);
        uint256 tokenId = hook.seed(sqrtPriceX96, tickLower, tickUpper, liquidity);

        // If the encoding/gate were wrong, seed() would have reverted above.
        assertTrue(hook.seeded(), "seeded");
        assertGt(tokenId, 0, "position minted");
        assertEq(hook.hookPositionTokenId(), tokenId, "hook records its position id");

        uint256 prismAfter = hook.balanceOf(HOOK);
        assertLt(prismAfter, 5000 ether, "PRISM was deposited as liquidity");
        console2.log("PRISM deposited into the position:", (5000 ether - prismAfter) / 1e15, "milli");
        console2.log("hook position tokenId:", tokenId);

        // The hook owns the position, so pokeFees must be able to run (collects ~0, no revert).
        hook.pokeFees();
    }
}
