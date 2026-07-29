// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}      from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency}     from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks}       from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams}   from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface IHookJ {
    function seed(uint160, int24, int24, uint128) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function nftBalanceOf(address) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function ownedTokensOf(address) external view returns (uint256[] memory);
    function pokeFees() external;
    function claimMany(uint256[] calldata) external;
    function pendingETH(address) external view returns (uint256);
    function accFeesPerShareETH() external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract Swapper {
    using BalanceDeltaLibrary for BalanceDelta;
    IPoolManager public pm;
    constructor(address _pm) { pm = IPoolManager(_pm); }
    receive() external payable {}
    function buy(PoolKey memory key, uint256 ethIn, address to) external returns (uint256) {
        return abi.decode(pm.unlock(abi.encode(uint8(1), key, ethIn, to)), (uint256));
    }
    function sell(PoolKey memory key, uint256 prismIn, address to) external returns (uint256) {
        return abi.decode(pm.unlock(abi.encode(uint8(2), key, prismIn, to)), (uint256));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm));
        (uint8 mode, PoolKey memory key, uint256 amt, address to) = abi.decode(data, (uint8, PoolKey, uint256, address));
        if (mode == 1) {
            BalanceDelta d = pm.swap(key, SwapParams(true, -int256(amt), 4295128740), "");
            uint256 out = uint256(uint128(d.amount1()));
            pm.settle{value: amt}();
            pm.take(key.currency1, to, out);
            return abi.encode(out);
        } else {
            BalanceDelta d = pm.swap(key, SwapParams(false, -int256(amt), 1461446703485210103287273052203988822378723970341), "");
            uint256 out = uint256(uint128(d.amount0()));
            pm.sync(key.currency1);
            IHookJ(Currency.unwrap(key.currency1)).transfer(address(pm), amt);
            pm.settle();
            pm.take(key.currency0, to, out);
            return abi.encode(out);
        }
    }
}

/// Quantifies the cross-tx JIT residual (the one the anti-JIT quarantine does NOT block) with real
/// swaps: an attacker who bought fresh shares in a PRIOR tx pokes+claims to skim a slice of the
/// STANDING (un-poked) fees, vs. the ~2% round-trip swap cost they pay. Measures both, in ETH.
contract JITQuantFork is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM         = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2       = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant OWNER = address(0xB0B);
    address constant HOOK  = address(0x2040);
    uint256 constant FORK_BLOCK = 25604624;

    IHookJ hook;
    Swapper sw;
    address constant ATTACKER = address(0xA77ACC);

    function _key() internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(HOOK), 10000, 200, IHooks(HOOK));
    }

    uint256 constant ATK_BUY = 0.03 ether;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);
        deployCodeTo("PrismHookV2.sol:PrismHookV2", abi.encode(POOL_MANAGER, OWNER, POSM, PERMIT2, address(0), uint256(0)), HOOK);
        hook = IHookJ(HOOK);
        vm.prank(OWNER);
        hook.seed(3648751508805509367250261525102, -887200, 76600, 80e18); // ~3680 PRISM (fits supply)
        sw = new Swapper(POOL_MANAGER);
        vm.deal(address(sw), 1000 ether);

        // Legit holders buy -> baseline shares S; poke to consume the F3 forfeit + book.
        sw.buy(_key(), 0.03 ether, address(0x5001));
        sw.buy(_key(), 0.03 ether, address(0x5002));
        hook.pokeFees();

        // Generate STANDING (un-poked) fees via volume — buys only (robust), NO poke afterward.
        sw.buy(_key(), 0.02 ether, address(0x5003));
        sw.buy(_key(), 0.02 ether, address(0x5004));

        // ATTACKER buys fresh shares HERE (setUp = a prior tx), so they are NOT same-tx quarantined
        // when claimed in the test body -> the cross-tx path.
        sw.buy(_key(), ATK_BUY, ATTACKER);
    }

    /// Measurement (no pass/fail beyond "fees existed"): how much of the STANDING fees a cross-tx
    /// fresh-share attacker skims, vs. the ~1% each-way (~2% round-trip) swap cost on their buy.
    function test_QuantifyCrossTxJIT() public {
        uint256 total = hook.totalShares();
        uint256 atkShares = hook.nftBalanceOf(ATTACKER);

        // tx2: attacker books standing fees, then claims on the fresh shares.
        hook.pokeFees();
        uint256[] memory ids = hook.ownedTokensOf(ATTACKER);
        hook.claimMany(ids);
        uint256 captured = hook.pendingETH(ATTACKER);

        // Their swap cost floor: ~1% pool fee each way ≈ 2% of the ~0.1 ETH they cycle = ~0.002 ETH,
        // plus price impact and a block of price exposure (not modeled here).
        uint256 approxRoundTripCost = (ATK_BUY * 200) / 10_000; // 2%

        console2.log("attacker fresh shares:", atkShares, "of total:", total);
        console2.log("captured standing-fee slice (wei ETH):", captured);
        console2.log("approx round-trip swap cost floor (wei ETH):", approxRoundTripCost);
        // The decision-relevant comparison, surfaced as logs:
        if (captured > approxRoundTripCost) {
            console2.log("NOTE: captured > swap-cost floor at THIS standing-fee level -> profitable pre-gas/price-risk");
        } else {
            console2.log("captured < swap-cost floor -> unprofitable even before gas/price risk");
        }
        assertGt(captured, 0, "there were standing fees to skim");
    }
}
