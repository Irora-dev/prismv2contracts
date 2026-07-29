// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IHooks}                            from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager}                      from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks}                             from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey}                           from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta}                      from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

abstract contract BaseHook is IHooks {
    error NotPoolManager();
    error HookNotImplemented();

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure virtual returns (Hooks.Permissions memory);

    // ━━━━━━━━━━━━━━━━━━━━━━━━ external callbacks ━━━━━━━━━━━━━━━━━━━━━━━━

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external onlyPoolManager returns (bytes4)
    { return _beforeInitialize(sender, key, sqrtPriceX96); }

    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external onlyPoolManager returns (bytes4)
    { return _afterInitialize(sender, key, sqrtPriceX96, tick); }

    function beforeAddLiquidity(
        address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData
    ) external onlyPoolManager returns (bytes4)
    { return _beforeAddLiquidity(sender, key, params, hookData); }

    function afterAddLiquidity(
        address sender, PoolKey calldata key, ModifyLiquidityParams calldata params,
        BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BalanceDelta)
    { return _afterAddLiquidity(sender, key, params, delta, feesAccrued, hookData); }

    function beforeRemoveLiquidity(
        address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData
    ) external onlyPoolManager returns (bytes4)
    { return _beforeRemoveLiquidity(sender, key, params, hookData); }

    function afterRemoveLiquidity(
        address sender, PoolKey calldata key, ModifyLiquidityParams calldata params,
        BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BalanceDelta)
    { return _afterRemoveLiquidity(sender, key, params, delta, feesAccrued, hookData); }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24)
    { return _beforeSwap(sender, key, params, hookData); }

    function afterSwap(
        address sender, PoolKey calldata key, SwapParams calldata params,
        BalanceDelta delta, bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128)
    { return _afterSwap(sender, key, params, delta, hookData); }

    function beforeDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external onlyPoolManager returns (bytes4)
    { return _beforeDonate(sender, key, amount0, amount1, hookData); }

    function afterDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external onlyPoolManager returns (bytes4)
    { return _afterDonate(sender, key, amount0, amount1, hookData); }

    // ━━━━━━━━━━━━━━━━━━━━━━━━ virtual internals ━━━━━━━━━━━━━━━━━━━━━━━━

    function _beforeInitialize(address, PoolKey calldata, uint160) internal virtual returns (bytes4)             { revert HookNotImplemented(); }
    function _afterInitialize(address, PoolKey calldata, uint160, int24) internal virtual returns (bytes4)       { revert HookNotImplemented(); }
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal virtual returns (bytes4) { revert HookNotImplemented(); }
    function _afterAddLiquidity(
        address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata
    ) internal virtual returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }
    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal virtual returns (bytes4) { revert HookNotImplemented(); }
    function _afterRemoveLiquidity(
        address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata
    ) internal virtual returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal virtual returns (bytes4, BeforeSwapDelta, uint24)
    { revert HookNotImplemented(); }
    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal virtual returns (bytes4, int128) { revert HookNotImplemented(); }
    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal virtual returns (bytes4) { revert HookNotImplemented(); }
    function _afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal virtual returns (bytes4) { revert HookNotImplemented(); }
}
