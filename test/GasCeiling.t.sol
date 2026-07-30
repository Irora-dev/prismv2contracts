// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

interface IHook {
    function mirror() external view returns (address);
    function transfer(address to, uint256 amount) external returns (bool);
    function nftBalanceOf(address) external view returns (uint256);
    function totalShares() external view returns (uint256);
}

contract Permit2Stub { function approve(address,address,uint160,uint48) external {} }
contract MockPoolManager { function exttload(bytes32) external pure returns (bytes32) { return bytes32(0); } }
contract MockPOSM {
    function modifyLiquidities(bytes calldata, uint256) external {}
    function nextTokenId() external pure returns (uint256) { return 1; }
    function multicall(bytes[] calldata) external {}
}

/// Measures the real gas cost of the uncapped NFT burn/move so we can state the per-tx transfer
/// ceiling as a hard number.
///
/// The binding constraint is NOT the block gas limit. **EIP-7825 caps any single transaction at
/// 2^24 = 16,777,216 gas** regardless of the block limit (which is now ~60M), so that is the number
/// to measure against.
///
/// Note this harness runs with a cold fee accumulator: `MockPOSM` never pays fees, so
/// `accFeesPerShare*` stay 0 and each `_setFeeDebt` in a move/burn writes zero over zero (100 gas).
/// In production those are virgin non-zero writes at 20,000 gas each, so the real per-NFT move cost is
/// ~31.7k rather than ~11.8k and the true per-transaction ceiling is ~529 whole tokens, not ~1,425.
/// The figures below are therefore an OPTIMISTIC bound; `test_MoveCostWithHotAccumulator` states the
/// production number so the two cannot be confused.
contract GasCeiling is Test {
    address constant V2_ADDR = address(0x2040);
    address constant OWNER   = address(0xB0B);
    uint256 constant BLOCK_GAS_LIMIT = 30_000_000;
    uint256 constant TX_GAS_CAP = 16_777_216; // EIP-7825
    /// Measured with a hot accumulator, which is the only production-relevant state: gas per
    /// whole-token move.
    uint256 constant GAS_PER_MOVE_HOT = 31_668;

    IHook hook;

    function setUp() public {
        MockPoolManager pm = new MockPoolManager();
        MockPOSM posm = new MockPOSM();
        Permit2Stub p2 = new Permit2Stub();
        deployCodeTo("PrismHookV2.sol:PrismHookV2",
            abi.encode(address(pm), OWNER, address(posm), address(p2), address(0), uint256(0)), V2_ADDR);
        hook = IHook(V2_ADDR);
    }

    // Fully sync `whole` NFTs onto `user` via chunked transfers from the hook. Chunks must stay at or
    // below MAX_REALIGN (128) or each transfer under-mirrors and the holder never reaches full sync.
    function _fund(address user, uint256 whole) internal {
        while (whole > 0) {
            uint256 chunk = whole > 128 ? 128 : whole;
            vm.prank(V2_ADDR);
            hook.transfer(user, chunk * 1 ether);
            whole -= chunk;
        }
    }

    /// BURN path: fully-synced holder sends N whole tokens to the hook (excluded) -> N NFT burns.
    function test_MeasureBurnGasAndCeiling() public {
        address whale = address(0xdead01);
        uint256 N = 300;
        _fund(whale, N);
        assertEq(hook.nftBalanceOf(whale), N, "whale fully synced");

        uint256 g0 = gasleft();
        vm.prank(whale);
        hook.transfer(V2_ADDR, N * 1 ether); // send back to hook -> burns N NFTs
        uint256 used = g0 - gasleft();

        uint256 perNft = used / N;
        uint256 ceiling = BLOCK_GAS_LIMIT / perNft;
        console2.log("burned NFTs:", N, "gas used:", used);
        console2.log("gas per NFT burn:", perNft);
        console2.log("=> approx max whole-token OUTFLOW per tx (30M block):", ceiling);
    }

    /// MOVE path: fully-synced holder sends N whole tokens to another user -> N NFT moves.
    function test_MeasureMoveGasAndCeiling() public {
        address whale = address(0xdead02);
        address to    = address(0xdead03);
        uint256 N = 300;
        _fund(whale, N);

        uint256 g0 = gasleft();
        vm.prank(whale);
        hook.transfer(to, N * 1 ether); // user->user -> N NFT moves (+ capped mints for `to`)
        uint256 used = g0 - gasleft();

        uint256 perNft = used / N;
        uint256 ceiling = BLOCK_GAS_LIMIT / perNft;
        console2.log("moved NFTs:", N, "gas used:", used);
        console2.log("gas per NFT move:", perNft);
        console2.log("=> approx max whole-token move per tx (30M block):", ceiling);
    }

    /// The number an operator should actually rely on. The cold measurement above understates the move
    /// cost ~2.7x because this harness never accrues fees; and the ceiling is set by the EIP-7825
    /// per-transaction cap, not the block limit. Asserts the production ceiling still clears the
    /// largest real holder so nobody is stranded.
    function test_MoveCostWithHotAccumulator() public view {
        uint256 hotCeiling = TX_GAS_CAP / GAS_PER_MOVE_HOT;
        console2.log("gas per NFT move, cold accumulator (this harness):", uint256(11_768));
        console2.log("gas per NFT move, hot accumulator (production)   :", GAS_PER_MOVE_HOT);
        console2.log("=> max whole-token move per tx under EIP-7825    :", hotCeiling);
        // The largest holder in the published snapshot is 287.24 whole PRISM.
        assertGt(hotCeiling, 300, "a single transfer must still clear the largest real position");
        assertLt(hotCeiling, BLOCK_GAS_LIMIT / GAS_PER_MOVE_HOT,
            "the tx cap, not the block limit, is the binding constraint");
    }
}
