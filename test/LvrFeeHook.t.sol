// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {LvrFeeHook} from "../src/LvrFeeHook.sol";
import {SignalOracle} from "../src/SignalOracle.sol";

contract LvrFeeHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address settler = makeAddr("settler");
    address alice = makeAddr("alice");

    uint256 constant COMMIT_DURATION = 5 minutes;
    uint256 constant REVEAL_DURATION = 5 minutes;
    uint256 constant MIN_STAKE = 0.01 ether;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;

    LvrFeeHook hook;
    SignalOracle oracle;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        oracle = new SignalOracle(settler, COMMIT_DURATION, REVEAL_DURATION, MIN_STAKE);

        // mine + deploy the hook to an address with only the beforeSwap flag set
        address flags = address(uint160(Hooks.BEFORE_SWAP_FLAG) ^ (0x5555 << 144));
        bytes memory constructorArgs = abi.encode(poolManager, oracle);
        deployCodeTo("LvrFeeHook.sol:LvrFeeHook", constructorArgs, flags);
        hook = LvrFeeHook(flags);

        // dynamic-fee pool: fee slot must be LPFeeLibrary.DYNAMIC_FEE_FLAG, not a static number
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function testFeeIsBaseFeeWhenSignalIsZero() public view {
        // no round has ever settled, so getCurrentSignal() is still 0
        assertEq(hook.previewFee(), hook.BASE_FEE());
    }

    function testFeeRisesAfterHighSignalIsSettled() public {
        _runOracleRound(9000); // a large "risky" prediction

        // BASE_FEE (3000) + 9000 = 12000, which is above MAX_FEE (10000) -> clamped
        assertEq(hook.previewFee(), hook.MAX_FEE());
    }

    function testFeeStaysWithinFloorAndCeilingRegardlessOfSignal() public {
        _runOracleRound(1_000_000_000); // absurdly large signal, simulating a broken/manipulated oracle
        uint24 fee = hook.previewFee();
        assertGe(fee, hook.MIN_FEE());
        assertLe(fee, hook.MAX_FEE());
        assertEq(fee, hook.MAX_FEE()); // in this case it should hit the ceiling exactly
    }

    function testStaleSignalFallsBackToBaseFee() public {
        _runOracleRound(9000); // pushes fee to MAX_FEE right after settling
        assertEq(hook.previewFee(), hook.MAX_FEE());

        // fast-forward well past MAX_SIGNAL_AGE without any new round settling
        vm.warp(block.timestamp + hook.MAX_SIGNAL_AGE() + 1);

        // the signal value in storage hasn't changed, but the hook should refuse
        // to trust it now and fall back to the safe baseline
        assertEq(hook.previewFee(), hook.BASE_FEE());
    }
    function testSwapActuallyPaysTheHigherFee() public {
        // baseline swap at BASE_FEE
        uint256 amountIn = 1e18;
        BalanceDelta lowFeeSwap = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        _runOracleRound(9000); // pushes fee to MAX_FEE

        BalanceDelta highFeeSwap = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // same input amount, but the higher-fee swap should return strictly less output
        assertLt(int256(highFeeSwap.amount1()), int256(lowFeeSwap.amount1()));
    }

    /// @dev Drives one full commit -> reveal -> aggregate -> settle cycle so the oracle's
    ///      stored signal actually updates, exactly like a real round would.
    function _runOracleRound(uint256 predictedValue) internal {
        vm.deal(alice, 1 ether);
        bytes32 salt = "test-salt";
        bytes32 commitment = keccak256(abi.encodePacked(predictedValue, salt));

        vm.prank(alice);
        oracle.commit{value: MIN_STAKE}(commitment);

        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        oracle.reveal(predictedValue, salt);

        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        oracle.aggregateRound();

        vm.prank(settler);
        oracle.settle(predictedValue); // realized value = prediction, so alice is "accurate" here
    }
}
