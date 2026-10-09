// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MeatbagHook} from "../src/MeatbagHook.sol";
import {MeatbagHerald} from "../src/MeatbagHerald.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MeatbagHookTest is HookTestBase {
    event Message(address indexed to, string text);

    function setUp() public {
        vm.warp(1_800_000_000);
        setUpPool(true);
    }

    // ---------------------------------------------------------------- shape

    function test_permissionsMatchTheMinedAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeDonate);
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
    }

    function test_constructorDeployedTheProjectAndTheHeraldSpoke() public view {
        assertEq(herald.hook(), address(hook));
        assertEq(herald.game(), address(game));
        assertEq(address(game.herald()), address(herald));
        assertEq(game.INTAKE(), 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56);
        assertEq(game.IMD(), 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
        assertEq(game.oracleSigner(), 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982);
        assertEq(herald.count(), 1);
        assertEq(hook.token(), address(token));
        assertEq(hook.launchedAt(), block.timestamp);
    }

    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        vm.expectRevert(MeatbagHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(MeatbagHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), "");
        vm.expectRevert(MeatbagHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), BalanceDelta.wrap(0), "");
        vm.expectRevert(MeatbagHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(this), key, ModifyLiquidityParams(-60, 60, 1, 0), "");
        vm.expectRevert(MeatbagHook.NotPoolManager.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(MeatbagHook.NotPoolManager.selector);
        hook.unlockCallback("");
    }

    // ---------------------------------------------------------------- initialization

    function test_onlyTheFactoryOpensThePool() public {
        PoolManager fresh = new PoolManager(address(this));
        MeatbagHook h = deployHook(fresh, address(0xFAC));
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12500, 60, IHooks(address(h)));
        vm.expectRevert();
        fresh.initialize(k, SQRT_PRICE_1_1);
        vm.prank(address(0xFAC));
        fresh.initialize(k, SQRT_PRICE_1_1);
        assertEq(h.token(), address(token));
    }

    function test_poolOpensOnlyOnceAndOnlyAgainstEth() public {
        PoolKey memory second =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(second, SQRT_PRICE_1_1);

        PoolManager fresh = new PoolManager(address(this));
        MeatbagHook h = deployHook(fresh, address(this));
        MockERC20 other = new MockERC20("Other", "OTH", 1 ether);
        (address c0, address c1) =
            address(other) < address(token) ? (address(other), address(token)) : (address(token), address(other));
        PoolKey memory tokenPair = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12500, 60, IHooks(address(h)));
        vm.expectRevert();
        fresh.initialize(tokenPair, SQRT_PRICE_1_1);
    }

    // ---------------------------------------------------------------- the fee, after the decay

    function test_buyExactInputPaysTwoPercentSplitExactly() public {
        vm.warp(block.timestamp + 30 minutes);
        assertEq(hook.buyFeeBps(), 200);
        uint256 swarmBefore = SWARM.balance;
        uint256 tokensBefore = token.balanceOf(address(this));

        buyExactIn(1 ether);

        assertEq(game.pot(), 0.011 ether, "55% to the pot");
        assertEq(SWARM.balance - swarmBefore, 0.005 ether, "25% to the swarm");
        assertEq(address(treasury).balance, 0.004 ether, "20% to the treasury");
        assertEq(address(hook).balance, 0, "the hook keeps nothing");
        assertEq(hook.claims(), 0);
        assertGt(token.balanceOf(address(this)), tokensBefore);
        assertEq(hook.volume(), 1 ether);
    }

    function test_buyExactOutputPaysTwoPercentOfTheEthThePoolTook() public {
        vm.warp(block.timestamp + 1 hours);
        uint256 ethBefore = address(this).balance;
        uint256 tokensBefore = token.balanceOf(address(this));

        buyExactOut(1 ether, 3 ether);

        assertEq(token.balanceOf(address(this)) - tokensBefore, 1 ether, "exact output honoured");
        uint256 paid = ethBefore - address(this).balance;
        uint256 fee = game.pot() + (SWARM.balance) + address(treasury).balance;
        // fee = 2% of what the pool took, i.e. paid = poolTook + fee with fee = poolTook / 50.
        uint256 poolTook = paid - fee;
        assertApproxEqAbs(fee, poolTook * 200 / 10_000, 2);
    }

    function test_sellExactInputTakesTwoPercentOfTheEthOut() public {
        vm.warp(block.timestamp + 1 hours);
        uint256 ethBefore = address(this).balance;

        sellExactIn(1 ether);

        uint256 received = address(this).balance - ethBefore;
        uint256 fee = game.pot() + SWARM.balance + address(treasury).balance;
        uint256 gross = received + fee;
        assertApproxEqAbs(fee, gross * 200 / 10_000, 2, "2% of the ETH that left the pool");
        assertEq(SWARM.balance, fee * 2500 / 10_000);
        assertEq(address(treasury).balance, fee * 2000 / 10_000);
        assertEq(game.pot(), fee - SWARM.balance - address(treasury).balance);
        assertEq(hook.volume(), gross);
    }

    function test_sellExactOutputDeliversExactlyAndGrossesUpTheFee() public {
        vm.warp(block.timestamp + 1 hours);
        uint256 ethBefore = address(this).balance;

        sellExactOut(1 ether);

        assertEq(address(this).balance - ethBefore, 1 ether, "exact ETH output honoured");
        uint256 expectedFee = uint256(1 ether) * 10_000 / 9_800 - 1 ether;
        uint256 fee = game.pot() + SWARM.balance + address(treasury).balance;
        assertEq(fee, expectedFee);
        assertEq(SWARM.balance, expectedFee * 2500 / 10_000);
        assertEq(address(treasury).balance, expectedFee * 2000 / 10_000);
    }

    // ---------------------------------------------------------------- the decay

    function test_buyFeeDecaysLinearlyFromTwentyFiveToTwoPercent() public {
        assertEq(hook.buyFeeBps(), 2500);
        vm.warp(hook.launchedAt() + 15 minutes);
        assertEq(hook.buyFeeBps(), 1350);
        vm.warp(hook.launchedAt() + 29 minutes);
        assertEq(hook.buyFeeBps(), uint256(2500) - uint256(2300) * 29 / 30);
        vm.warp(hook.launchedAt() + 30 minutes);
        assertEq(hook.buyFeeBps(), 200);
        vm.warp(hook.launchedAt() + 300 days);
        assertEq(hook.buyFeeBps(), 200);
        assertEq(hook.sellFeeBps(), 200);
    }

    function test_launchBuySurplusGoesEntirelyToThePot() public {
        // At launch: 25% fee. The 2% base splits 55/25/20; the other 23% is all pot.
        buyExactIn(1 ether);
        assertEq(SWARM.balance, 0.005 ether);
        assertEq(address(treasury).balance, 0.004 ether);
        assertEq(game.pot(), 0.25 ether - 0.009 ether);
    }

    function test_decayAppliesToExactOutputBuysToo() public {
        vm.warp(hook.launchedAt() + 15 minutes); // 13.5%
        buyExactOut(1 ether, 3 ether);
        uint256 fee = game.pot() + SWARM.balance + address(treasury).balance;
        uint256 base = SWARM.balance * 10_000 / 2500;
        assertApproxEqRel(fee, base * 1350 / 200, 1e15);
    }

    function test_sellsNeverDecay() public {
        uint256 ethBefore = address(this).balance;
        sellExactIn(1 ether);
        uint256 fee = game.pot() + SWARM.balance + address(treasury).balance;
        uint256 gross = address(this).balance - ethBefore + fee;
        assertApproxEqAbs(fee, gross * 200 / 10_000, 2);
    }

    function testFuzz_feeIsAlwaysTwoPercentAfterDecayAndSplitsSumToIt(uint96 ethIn, bool buy) public {
        ethIn = uint96(bound(ethIn, 0.0001 ether, 50 ether));
        vm.warp(block.timestamp + 1 hours);
        uint256 ethBefore = address(this).balance;
        if (buy) buyExactIn(ethIn);
        else sellExactIn(ethIn);
        uint256 fee = game.pot() + SWARM.balance + address(treasury).balance;
        uint256 gross = buy ? ethIn : (address(this).balance - ethBefore) + fee;
        assertApproxEqAbs(fee, gross * 200 / 10_000, 2);
        assertEq(hook.owedPot() + hook.owedSwarm() + hook.owedTreasury(), 0);
        assertEq(address(hook).balance, 0);
    }

    // ---------------------------------------------------------------- claims on a manager without ETH

    function test_buyOnAFreshManagerSeededWithTokensOnlyMintsAClaimThenRedeemsIt() public {
        setUpPool(false);
        assertEq(address(manager).balance, 0, "no ETH in the manager yet");
        vm.warp(block.timestamp + 1 hours);

        buyExactIn(1 ether);

        assertEq(hook.claims(), 0.02 ether, "the fee is held as an ERC-6909 claim");
        assertEq(manager.balanceOf(address(hook), 0), 0.02 ether);
        assertEq(game.pot(), 0, "nothing distributed yet");
        assertEq(hook.owedPot(), 0.011 ether);
        assertEq(hook.owedSwarm(), 0.005 ether);
        assertEq(hook.owedTreasury(), 0.004 ether);
        assertEq(address(manager).balance, 1 ether, "the swap settled its ETH");

        // The next swap redeems the claim beside its own fee.
        uint256 swarmBefore = SWARM.balance;
        buyExactIn(1 ether);
        assertEq(hook.claims(), 0);
        assertEq(game.pot(), 0.022 ether);
        assertEq(SWARM.balance - swarmBefore, 0.01 ether);
        assertEq(address(treasury).balance, 0.008 ether);
    }

    function test_anyoneRedeemsClaimsOnceTheManagerHoldsEth() public {
        setUpPool(false);
        vm.warp(block.timestamp + 1 hours);
        buyExactIn(1 ether);
        assertEq(hook.claims(), 0.02 ether);

        vm.prank(address(0xBEEF));
        hook.redeemClaims();

        assertEq(hook.claims(), 0);
        assertEq(game.pot(), 0.011 ether);
        assertEq(address(treasury).balance, 0.004 ether);
        assertEq(hook.owedPot() + hook.owedSwarm() + hook.owedTreasury(), 0);

        vm.expectRevert(MeatbagHook.NothingToRedeem.selector);
        hook.redeemClaims();
    }

    // ---------------------------------------------------------------- the herald

    function test_firstTradeAndVolumeMilestonesAreAnnounced() public {
        vm.warp(block.timestamp + 1 hours);
        vm.expectEmit(true, false, false, true, address(herald));
        emit Message(herald.TO(), herald.textOf(0));
        vm.expectEmit(true, false, false, true, address(herald));
        emit Message(herald.TO(), herald.textOf(1));
        buyExactIn(1 ether);
        assertTrue(herald.sent(0) && herald.sent(1));
        assertFalse(herald.sent(2));

        buyExactIn(9 ether);
        assertTrue(herald.sent(2), "10 ETH");
        assertFalse(herald.sent(3));
        buyExactIn(45 ether);
        sellExactIn(token.balanceOf(address(this)) / 10);
        assertGe(hook.volume(), 55 ether);
        buyExactIn(60 ether);
        assertTrue(herald.sent(3), "100 ETH");
        assertEq(herald.count(), 5);
    }

    // ---------------------------------------------------------------- no admin

    function test_hasNoOwnerOrSetters() public {
        bytes4[5] memory sels = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("setFee(uint256)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("withdraw(uint256)")),
            bytes4(keccak256("transferOwnership(address)"))
        ];
        for (uint256 i = 0; i < sels.length; i++) {
            (bool ok,) = address(hook).call(abi.encodeWithSelector(sels[i], address(this)));
            assertFalse(ok);
        }
    }
}
