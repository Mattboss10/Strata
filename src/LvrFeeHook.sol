// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {SignalOracle} from "./SignalOracle.sol";

/// @notice Reads SignalOracle.getCurrentSignal() at swap time and converts it into a
///         per-swap LP fee override. No matter what the signal says, the fee returned
///         is always clamped between MIN_FEE and MAX_FEE, so a bad or stale signal can
///         never push the pool outside a known-safe range.
/// @dev Requires the pool to be created with LPFeeLibrary.DYNAMIC_FEE_FLAG as its fee.
contract LvrFeeHook is BaseHook {
    SignalOracle public immutable signalOracle;

    /// @dev LP fee units are hundredths of a bip: 3000 = 0.30%, matching v3's common tier.
    uint24 public constant MIN_FEE = 500; // 0.05% floor
    uint24 public constant MAX_FEE = 10000; // 1.00% ceiling
    uint24 public constant BASE_FEE = 3000; // 0.30% when the signal is 0 / unset

    /// @dev If the signal hasn't updated in longer than this, treat it as unreliable
    ///      and fall back to BASE_FEE rather than acting on stale data.
    uint256 public constant MAX_SIGNAL_AGE = 1 hours;

    constructor(IPoolManager _poolManager, SignalOracle _signalOracle) BaseHook(_poolManager) {
        signalOracle = _signalOracle;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = _computeFee();
        // OR-ing with OVERRIDE_FEE_FLAG tells the PoolManager to use this fee for THIS
        // swap only, instead of the pool's persisted (and here, unused) base fee.
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice Same calculation _beforeSwap uses, exposed so it can be checked or
    ///         displayed off-chain without needing to simulate a swap.
    function previewFee() external view returns (uint24) {
        return _computeFee();
    }

    /// @dev PLACEHOLDER formula: fee grows linearly with the raw signal, then gets
    ///      clamped. This relationship is not calibrated to anything yet — that's the
    ///      week-4 backtesting job. The floor/ceiling clamp is the part that actually
    ///      matters for safety and should stay no matter how the formula changes.
    function _computeFee() internal view returns (uint24) {
        // a stale signal is worse than no signal — fall back to the safe baseline
        // rather than act on a number that might no longer reflect reality
        if (block.timestamp > signalOracle.lastSignalUpdate() + MAX_SIGNAL_AGE) {
            return BASE_FEE;
        }

        uint256 signal = signalOracle.getCurrentSignal();
        uint256 rawFee = uint256(BASE_FEE) + signal;

        if (rawFee < MIN_FEE) return MIN_FEE;
        if (rawFee > MAX_FEE) return MAX_FEE;
        return uint24(rawFee);
    }
}
