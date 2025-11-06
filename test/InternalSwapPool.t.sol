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
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {InternalSwapPool} from "../src/InternalSwapPool.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract InternalSwapPoolTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    InternalSwapPool public hook;
    MockERC20 public token;
    MockERC20 public weth;
    PoolKey poolKey;
    uint160 initSqrtPriceX96;

    // Users
    address payable alice = payable(makeAddr("alice"));
    address payable bob = payable(makeAddr("bob"));
    address payable lp = payable(makeAddr("lp"));

    function setUp() public {
        deployFreshManagerAndRouters();

        // Deploy tokens - WETH must be currency0 (lower address)
        weth = new MockERC20("WETH", "WETH", 18);
        token = new MockERC20("Token", "TOK", 18);

        // Mine a valid hook address for InternalSwapPool
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this), flags, type(InternalSwapPool).creationCode, abi.encode(address(manager), address(weth))
        );

        // Deploy InternalSwapPool hook using CREATE2 with the mined salt
        hook = new InternalSwapPool{salt: salt}(address(manager), address(weth));
        require(address(hook) == hookAddress, "Hook address mismatch");

        // Ensure WETH has lower address than token for currency0
        require(address(weth) < address(token), "WETH must be currency0");

        // Create pool key (WETH/TOKEN)
        poolKey = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(token)),
            fee: 3000, // 0.3%
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });

        // Initialize pool at 1:1 price
        initSqrtPriceX96 = uint160(TickMath.getSqrtPriceAtTick(0));
        manager.initialize(poolKey, initSqrtPriceX96);

        // Register the pool with the hook
        hook.registerPool(poolKey);

        // Give users tokens
        weth.mint(alice, 100 ether);
        weth.mint(bob, 100 ether);
        weth.mint(lp, 100 ether);
        weth.mint(address(hook), 100 ether); // Hook needs WETH for operations

        token.mint(alice, 100 ether);
        token.mint(bob, 100 ether);
        token.mint(lp, 100 ether);
        token.mint(address(hook), 100 ether); // Hook needs tokens for operations

        // Approve tokens to routers
        vm.startPrank(alice);
        weth.approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        weth.approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(lp);
        weth.approve(address(modifyLiquidityRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        // Hook approves manager
        vm.startPrank(address(hook));
        weth.approve(address(manager), type(uint256).max);
        token.approve(address(manager), type(uint256).max);
        vm.stopPrank();

        // Add initial liquidity
        _addLiquidity();
    }

    function test_hookPermissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertEq(permissions.beforeInitialize, false);
        assertEq(permissions.afterInitialize, false);
        assertEq(permissions.beforeAddLiquidity, false);
        assertEq(permissions.afterAddLiquidity, false);
        assertEq(permissions.beforeRemoveLiquidity, false);
        assertEq(permissions.afterRemoveLiquidity, false);
        assertEq(permissions.beforeSwap, true);
        assertEq(permissions.afterSwap, true);
        assertEq(permissions.beforeDonate, false);
        assertEq(permissions.afterDonate, false);
        assertEq(permissions.beforeSwapReturnDelta, true);
        assertEq(permissions.afterSwapReturnDelta, true);
        assertEq(permissions.afterAddLiquidityReturnDelta, false);
        assertEq(permissions.afterRemoveLiquidityReturnDelta, false);
    }

    function test_nativeToken() public view {
        assertEq(hook.nativeToken(), address(weth));
    }

    function test_registerPool() public view {
        assertTrue(hook.supportedPools(poolKey.toId()));
    }

    function test_registerPool_invalidHook() public {
        PoolKey memory invalidKey = poolKey;
        invalidKey.hooks = IHooks(address(0));

        vm.expectRevert("Hook not set for pool");
        hook.registerPool(invalidKey);
    }

    function test_registerPool_invalidCurrency0() public {
        PoolKey memory invalidKey = poolKey;
        invalidKey.currency0 = Currency.wrap(address(token));
        invalidKey.currency1 = Currency.wrap(address(weth));

        vm.expectRevert("Pool currency0 not native");
        hook.registerPool(invalidKey);
    }

    function test_depositFees() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2 ether;

        InternalSwapPool.ClaimableFees memory feesBefore = hook.poolFees(poolKey);
        assertEq(feesBefore.amount0, 0);
        assertEq(feesBefore.amount1, 0);

        hook.depositFees(poolKey, amount0, amount1);

        InternalSwapPool.ClaimableFees memory feesAfter = hook.poolFees(poolKey);
        assertEq(feesAfter.amount0, amount0);
        assertEq(feesAfter.amount1, amount1);
    }

    function test_depositFees_unsupportedPool() public {
        PoolKey memory unsupportedKey = poolKey;
        unsupportedKey.fee = 500; // Different fee tier

        vm.expectRevert("Pool not supported");
        hook.depositFees(unsupportedKey, 1 ether, 1 ether);
    }

    function test_swap_WETHForToken_exactInput() public {
        uint256 swapAmount = 1 ether;

        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceTokenBefore = token.balanceOf(alice);

        vm.startPrank(alice);
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, // WETH for token
                amountSpecified: -int256(swapAmount), // exact input
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );
        vm.stopPrank();

        uint256 aliceWethAfter = weth.balanceOf(alice);
        uint256 aliceTokenAfter = token.balanceOf(alice);

        // Alice should have spent swapAmount WETH and received tokens (minus fees)
        assertEq(aliceWethBefore - aliceWethAfter, swapAmount);
        assertGt(aliceTokenAfter, aliceTokenBefore);
    }

    function test_swap_TokenForWETH_exactInput() public {
        uint256 swapAmount = 1 ether;

        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceTokenBefore = token.balanceOf(alice);

        vm.startPrank(alice);
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, // token for WETH
                amountSpecified: -int256(swapAmount), // exact input
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ""
        );
        vm.stopPrank();

        uint256 aliceWethAfter = weth.balanceOf(alice);
        uint256 aliceTokenAfter = token.balanceOf(alice);

        // Alice should have spent swapAmount tokens and received WETH (minus fees)
        assertEq(aliceTokenBefore - aliceTokenAfter, swapAmount);
        assertGt(aliceWethAfter, aliceWethBefore);
    }

    function test_swap_WETHForToken_exactOutput() public {
        uint256 desiredOutput = 1 ether;

        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceTokenBefore = token.balanceOf(alice);

        vm.startPrank(alice);
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, // WETH for token
                amountSpecified: int256(desiredOutput), // exact output
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );
        vm.stopPrank();

        uint256 aliceWethAfter = weth.balanceOf(alice);
        uint256 aliceTokenAfter = token.balanceOf(alice);

        // Alice should have received desiredOutput tokens
        assertEq(aliceTokenAfter - aliceTokenBefore, desiredOutput);
        assertGt(aliceWethBefore - aliceWethAfter, 0);
    }

    function test_swap_TokenForWETH_exactOutput() public {
        uint256 desiredOutput = 1 ether;

        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceTokenBefore = token.balanceOf(alice);

        vm.startPrank(alice);
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, // token for WETH
                amountSpecified: int256(desiredOutput), // exact output
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ""
        );
        vm.stopPrank();

        uint256 aliceWethAfter = weth.balanceOf(alice);
        uint256 aliceTokenAfter = token.balanceOf(alice);

        // Alice should have received desiredOutput WETH
        assertEq(aliceWethAfter - aliceWethBefore, desiredOutput);
        assertGt(aliceTokenBefore - aliceTokenAfter, 0);
    }

    function test_feeAccumulation() public {
        // Get initial fees
        InternalSwapPool.ClaimableFees memory feesBefore = hook.poolFees(poolKey);

        // Perform multiple swaps to accumulate fees
        vm.startPrank(alice);
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Swap WETH for tokens
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );

        // Swap tokens for WETH
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ""
        );
        vm.stopPrank();

        // Check that fees have been accumulated
        InternalSwapPool.ClaimableFees memory feesAfter = hook.poolFees(poolKey);
        assertGt(feesAfter.amount0, feesBefore.amount0); // WETH fees increased
        assertGt(feesAfter.amount1, feesBefore.amount1); // Token fees increased
    }

    function test_feeDistribution() public {
        // Deposit fees to exceed donation threshold
        hook.depositFees(poolKey, 1 ether, 0);

        InternalSwapPool.ClaimableFees memory feesBefore = hook.poolFees(poolKey);
        assertEq(feesBefore.amount0, 1 ether);

        // Perform a swap to trigger fee distribution
        vm.startPrank(alice);
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );
        vm.stopPrank();

        // Check that fees have been distributed (should be less now)
        InternalSwapPool.ClaimableFees memory feesAfter = hook.poolFees(poolKey);
        assertLt(feesAfter.amount0, feesBefore.amount0);
    }

    function test_swap_multipleUsers() public {
        vm.startPrank(alice);
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );
        vm.stopPrank();

        vm.startPrank(bob);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ""
        );
        vm.stopPrank();

        // Both swaps should succeed and accumulate fees
        InternalSwapPool.ClaimableFees memory fees = hook.poolFees(poolKey);
        assertGt(fees.amount0, 0);
        assertGt(fees.amount1, 0);
    }

    function test_donateThreshold() public view {
        assertEq(hook.DONATE_THRESHOLD_MIN(), 0.0001 ether);
    }

    function test_swap_withPoolFees_beforeSwap() public {
        // Deposit token1 fees to test beforeSwap orderbook logic
        hook.depositFees(poolKey, 0, 5 ether);

        uint256 swapAmount = 1 ether;

        vm.startPrank(alice);
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Swap WETH for tokens (should use pool fees first)
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, // Token for WETH triggers beforeSwap logic
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ""
        );
        vm.stopPrank();

        // Pool fees should have been partially used
        InternalSwapPool.ClaimableFees memory fees = hook.poolFees(poolKey);
        assertLt(fees.amount1, 5 ether); // Some token fees were used
        assertGt(fees.amount0, 0); // WETH fees increased
    }

    function _addLiquidity() internal {
        vm.startPrank(lp);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 10000e18, salt: bytes32(0)}),
            ""
        );
        vm.stopPrank();
    }
}
