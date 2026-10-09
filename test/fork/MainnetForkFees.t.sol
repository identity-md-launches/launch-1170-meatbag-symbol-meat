// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "../HookTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MeatbagToken} from "../../src/MeatbagToken.sol";

/// @title Exact fee splits and the claims path against the real Ethereum PoolManager
/// @notice Forks mainnet (profile `fork`); the default profile skips `test/fork/**`. The real manager
/// already holds ETH, so every fee is taken natively: no claim is minted on mainnet.
contract MainnetForkFeesTest is HookTestBase {
    address constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    uint160 constant SQRT_PRICE_1E8 = 792281625142643375935439503360000;

    function setUp() public {
        vm.createSelectFork("mainnet");
        manager = IPoolManager(MAINNET_POOL_MANAGER);
        token = new MeatbagToken();
        hook = deployHook(manager, address(this));
        game = hook.game();
        herald = hook.herald();
        treasury = hook.treasury();
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 12500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1E8);
        vm.deal(address(this), 10_000 ether);
        token.approve(address(lpRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        lpRouter.modifyLiquidity{value: 20 ether}(key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, 1e23, bytes32(0)), "");
    }

    function test_forkExactSplitsAfterTheDecay() public {
        vm.warp(block.timestamp + 31 minutes);
        assertEq(hook.buyFeeBps(), 200);
        uint256 swarmBefore = SWARM.balance;
        uint256 treasuryBefore = address(treasury).balance;
        buyExactIn(1 ether);
        assertEq(game.pot(), 0.011 ether, "55% to the pot");
        assertEq(SWARM.balance - swarmBefore, 0.005 ether, "25% to the swarm");
        assertEq(address(treasury).balance - treasuryBefore, 0.004 ether, "20% to the treasury");
        assertEq(hook.claims(), 0, "no claim on the real manager");
        assertEq(address(hook).balance, 0);
    }

    function test_forkLaunchDecaySurplusGoesToThePot() public {
        vm.warp(hook.launchedAt() + 15 minutes); // 13.5%
        assertEq(hook.buyFeeBps(), 1350);
        uint256 swarmBefore = SWARM.balance;
        buyExactIn(1 ether);
        assertEq(SWARM.balance - swarmBefore, 0.005 ether, "the swarm still gets 25% of the 2% base");
        assertEq(address(treasury).balance, 0.004 ether);
        assertEq(game.pot(), 0.135 ether - 0.009 ether, "the surplus above 2% is all pot");
    }

    function test_forkSwapsFromAStrangerPayTheSameFee() public {
        vm.warp(block.timestamp + 1 hours);
        address stranger = address(0x5712A);
        vm.deal(stranger, 5 ether);
        vm.prank(stranger);
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParamsLib.buy(1 ether),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(game.pot(), 0.011 ether);
        assertGt(token.balanceOf(stranger), 0);
    }
}

import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

library SwapParamsLib {
    function buy(uint256 ethIn) internal pure returns (SwapParams memory) {
        return SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1);
    }
}
