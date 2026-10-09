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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MeatbagToken} from "../../src/MeatbagToken.sol";
import {MeatbagGame} from "../../src/MeatbagGame.sol";

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

    /// @notice The game reads its price from the real Intake and `judge()` places a real request there:
    /// the action is sold, the price is 0.5 IMD, and the IMD approval the game sets is consumed.
    function test_forkJudgeReachesTheRealIntake() public {
        assertEq(game.INTAKE(), 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56);
        assertEq(game.IMD(), 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
        assertEq(game.judgePrice(), 0.5 ether, "the real Intake prices oracle.request@oracle-1 at 0.5 IMD");

        address keeper = address(0xC0FFEE);
        IERC20 imdToken = IERC20(game.IMD());
        deal(address(imdToken), keeper, 1 ether);
        vm.prank(keeper);
        imdToken.approve(address(game), type(uint256).max);
        address entrant = address(0xA005);
        vm.deal(entrant, 1 ether);
        vm.prank(entrant);
        game.enter{value: 0.001 ether}("hello, i am a person");
        vm.warp((game.today() + 1) * 1 days + 1 hours);

        vm.prank(keeper);
        bytes32 id = game.judge();
        assertTrue(id != bytes32(0), "the real Intake returned no request id");
        assertEq(imdToken.balanceOf(keeper), 0.5 ether, "the keeper paid exactly the price");
        assertEq(imdToken.allowance(address(game), game.INTAKE()), 0, "the approval was consumed");
        assertEq(game.pendingDay(id), game.roundDays(0));
        assertTrue(game.round(game.roundDays(0)).status == MeatbagGame.Status.Pending);
    }

    function test_forkSwapsFromAStrangerPayTheSameFee() public {
        vm.warp(block.timestamp + 1 hours);
        address stranger = address(0x5712A);
        vm.deal(stranger, 5 ether);
        vm.prank(stranger);
        swapRouter.swap{value: 1 ether}(key, SwapParamsLib.buy(1 ether), PoolSwapTest.TestSettings(false, false), "");
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
