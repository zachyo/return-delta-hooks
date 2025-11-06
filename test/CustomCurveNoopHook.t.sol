// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {CSMM} from ".././src/CustomCurveNoopHook.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract CSMMTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    CSMM public hook;
    MockERC20 public token0;
    MockERC20 public token1;
    PoolKey poolKey;
    uint160 initSqrtPriceX96;

    // Users
    address payable zarcc = payable(makeAddr("zarcc"));
    address payable alice = payable(makeAddr("alice"));

    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );

    event HookModifyLiquidity(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1);

    function setUp() public {
        deployFreshManagerAndRouters();

        // Deploy tokens
        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);

        // Mine a valid hook address for CSMM
        uint160 flags =
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CSMM).creationCode, abi.encode(manager));

        // Deploy CSMM hook using CREATE2 with the mined salt
        hook = new CSMM{salt: salt}(manager);
        require(address(hook) == hookAddress, "Hook address mismatch");

        // Create pool key
        (Currency currency0, Currency currency1) = SortTokens.sort(token0, token1);
        poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(hookAddress)});

        // Initialize pool at 1:1 price
        initSqrtPriceX96 = uint160(TickMath.getSqrtPriceAtTick(0));
        manager.initialize(poolKey, initSqrtPriceX96);

        // Give users some tokens
        token0.mint(zarcc, 100 ether);
        token1.mint(zarcc, 100 ether);
        token0.mint(alice, 100 ether);
        token1.mint(alice, 100 ether);

        // Users approve hook and swapRouter
        vm.startPrank(zarcc);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(alice);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function test_hookPermissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertEq(permissions.beforeInitialize, false);
        assertEq(permissions.afterInitialize, false);
        assertEq(permissions.beforeAddLiquidity, true);
        assertEq(permissions.afterAddLiquidity, false);
        assertEq(permissions.beforeRemoveLiquidity, false);
        assertEq(permissions.afterRemoveLiquidity, false);
        assertEq(permissions.beforeSwap, true);
        assertEq(permissions.afterSwap, false);
        assertEq(permissions.beforeDonate, false);
        assertEq(permissions.afterDonate, false);
        assertEq(permissions.beforeSwapReturnDelta, true);
        assertEq(permissions.afterSwapReturnDelta, false);
        assertEq(permissions.afterAddLiquidityReturnDelta, false);
        assertEq(permissions.afterRemoveLiquidityReturnDelta, false);
    }

    function test_addLiquidity() public {
        uint256 amountEach = 10 ether;

        uint256 zarccToken0Before = token0.balanceOf(zarcc);
        uint256 zarccToken1Before = token1.balanceOf(zarcc);

        vm.startPrank(zarcc);
        vm.expectEmit(true, true, true, true);
        emit HookModifyLiquidity(
            PoolId.unwrap(poolKey.toId()), address(hook), int128(uint128(amountEach)), int128(uint128(amountEach))
        );

        hook.addLiquidity(poolKey, amountEach);
        vm.stopPrank();

        uint256 zarccToken0After = token0.balanceOf(zarcc);
        uint256 zarccToken1After = token1.balanceOf(zarcc);

        assertEq(zarccToken0Before - zarccToken0After, amountEach);
        assertEq(zarccToken1Before - zarccToken1After, amountEach);

        // Verify hook received claim tokens
        uint256 hookClaim0 = manager.balanceOf(address(hook), CurrencyLibrary.toId(poolKey.currency0));
        uint256 hookClaim1 = manager.balanceOf(address(hook), CurrencyLibrary.toId(poolKey.currency1));
        assertEq(hookClaim0, amountEach);
        assertEq(hookClaim1, amountEach);
    }

    function test_addLiquidity_multipleTimes() public {
        vm.startPrank(zarcc);
        hook.addLiquidity(poolKey, 10 ether);
        hook.addLiquidity(poolKey, 5 ether);
        vm.stopPrank();

        uint256 hookClaim0 = manager.balanceOf(address(hook), CurrencyLibrary.toId(poolKey.currency0));
        uint256 hookClaim1 = manager.balanceOf(address(hook), CurrencyLibrary.toId(poolKey.currency1));
        assertEq(hookClaim0, 15 ether);
        assertEq(hookClaim1, 15 ether);
    }

    function test_swap_exactInput_token0ForToken1() public {
        // Add liquidity first
        vm.startPrank(zarcc);
        hook.addLiquidity(poolKey, 50 ether);
        vm.stopPrank();

        uint256 swapAmount = 10 ether;
        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 aliceToken1Before = token1.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit HookSwap(
            PoolId.unwrap(poolKey.toId()),
            address(swapRouter),
            -int128(uint128(swapAmount)),
            int128(uint128(swapAmount)),
            0,
            0
        );

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        uint256 aliceToken0After = token0.balanceOf(alice);
        uint256 aliceToken1After = token1.balanceOf(alice);

        // 1:1 swap
        assertEq(aliceToken0Before - aliceToken0After, swapAmount);
        assertEq(aliceToken1After - aliceToken1Before, swapAmount);
    }

    function test_swap_exactInput_token1ForToken0() public {
        vm.startPrank(zarcc);
        hook.addLiquidity(poolKey, 50 ether);
        vm.stopPrank();

        uint256 swapAmount = 10 ether;
        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 aliceToken1Before = token1.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit HookSwap(
            PoolId.unwrap(poolKey.toId()),
            address(swapRouter),
            int128(uint128(swapAmount)),
            -int128(uint128(swapAmount)),
            0,
            0
        );

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        uint256 aliceToken0After = token0.balanceOf(alice);
        uint256 aliceToken1After = token1.balanceOf(alice);

        assertEq(aliceToken1Before - aliceToken1After, swapAmount);
        assertEq(aliceToken0After - aliceToken0Before, swapAmount);
    }

    function test_swap_exactOutput_token0ForToken1() public {
        vm.startPrank(zarcc);
        hook.addLiquidity(poolKey, 50 ether);
        vm.stopPrank();

        uint256 desiredOutput = 10 ether;
        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 aliceToken1Before = token1.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit HookSwap(
            PoolId.unwrap(poolKey.toId()),
            address(swapRouter),
            -int128(uint128(desiredOutput)),
            int128(uint128(desiredOutput)),
            0,
            0
        );

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(desiredOutput),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        uint256 aliceToken0After = token0.balanceOf(alice);
        uint256 aliceToken1After = token1.balanceOf(alice);

        assertEq(aliceToken0Before - aliceToken0After, desiredOutput);
        assertEq(aliceToken1After - aliceToken1Before, desiredOutput);
    }

    function test_swap_exactOutput_token1ForToken0() public {
        vm.startPrank(zarcc);
        hook.addLiquidity(poolKey, 50 ether);
        vm.stopPrank();

        uint256 desiredOutput = 10 ether;
        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 aliceToken1Before = token1.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit HookSwap(
            PoolId.unwrap(poolKey.toId()),
            address(swapRouter),
            int128(uint128(desiredOutput)),
            -int128(uint128(desiredOutput)),
            0,
            0
        );

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: int256(desiredOutput),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        uint256 aliceToken0After = token0.balanceOf(alice);
        uint256 aliceToken1After = token1.balanceOf(alice);

        assertEq(aliceToken1Before - aliceToken1After, desiredOutput);
        assertEq(aliceToken0After - aliceToken0Before, desiredOutput);
    }

    function test_swap_insufficientLiquidity() public {
        vm.prank(zarcc);
        hook.addLiquidity(poolKey, 5 ether);

        // Try to swap more than available liquidity
        vm.expectRevert();
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_revertAddLiquidityThroughPoolManager() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(CSMM.AddLiquidityThroughHook.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1000e18, salt: bytes32(0)}),
            ""
        );
    }

    function test_roundTripSwap() public {
        vm.prank(zarcc);
        hook.addLiquidity(poolKey, 50 ether);

        uint256 aliceToken0Start = token0.balanceOf(alice);
        uint256 aliceToken1Start = token1.balanceOf(alice);

        // Swap token0 for token1
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Swap token1 back for token0
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 aliceToken0End = token0.balanceOf(alice);
        uint256 aliceToken1End = token1.balanceOf(alice);

        // After round trip, balances should be back to original
        assertEq(aliceToken0Start, aliceToken0End);
        assertEq(aliceToken1Start, aliceToken1End);
    }
}
