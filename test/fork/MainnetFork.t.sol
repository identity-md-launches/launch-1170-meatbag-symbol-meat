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

/// @title Rehearsal against the real Ethereum PoolManager
/// @notice Forks mainnet through the `mainnet` RPC endpoint in foundry.toml. Excluded from the default
/// profile (no network there); run with `FOUNDRY_PROFILE=fork forge test`.
contract MainnetForkTest is HookTestBase {
    /// @dev Uniswap v4 PoolManager on Ethereum mainnet (chain id 1).
    address constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    /// @dev 1e8 MEAT per ETH: the 10 ETH opening cap for 1e9 tokens when MEAT is currency1.
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
        // Full range at 1e8 MEAT/ETH: liquidity 1e23 is about 10 ETH beside 1e27 MEAT minor units.
        lpRouter.modifyLiquidity{value: 20 ether}(key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, 1e23, bytes32(0)), "");
    }

    function test_forkBuyAndSellTakeTheFeeInEthOnTheRealManager() public {
        assertGt(address(manager).balance, 0);
        uint256 swarmBefore = SWARM.balance;
        uint256 potBefore = game.pot();

        buyExactIn(0.1 ether); // at launch: 25%
        uint256 fee = game.pot() - potBefore + (SWARM.balance - swarmBefore) + address(treasury).balance;
        assertEq(fee, 0.025 ether);
        assertEq(SWARM.balance - swarmBefore, 0.0005 ether);
        assertEq(hook.claims(), 0);

        vm.warp(block.timestamp + 1 hours);
        uint256 ethBefore = address(this).balance;
        uint256 potMid = game.pot();
        sellExactIn(token.balanceOf(address(this)) / 1000);
        uint256 received = address(this).balance - ethBefore;
        uint256 sellFee = game.pot() - potMid; // the pot's 55% share of the fee
        assertGt(received, 0);
        assertGt(sellFee, 0);
        assertApproxEqAbs(sellFee * 10_000 / 5500, (received + sellFee * 10_000 / 5500) * 200 / 10_000, 4);
        assertTrue(herald.sent(0), "first trade announced on the real manager");
    }

    function test_forkExactOutputBothWays() public {
        vm.warp(block.timestamp + 1 hours);
        uint256 tokensBefore = token.balanceOf(address(this));
        buyExactOut(1_000_000 ether, 1 ether);
        assertEq(token.balanceOf(address(this)) - tokensBefore, 1_000_000 ether);
        uint256 ethBefore = address(this).balance;
        sellExactOut(0.005 ether);
        assertEq(address(this).balance - ethBefore, 0.005 ether);
        assertEq(address(hook).balance, 0);
    }
}
