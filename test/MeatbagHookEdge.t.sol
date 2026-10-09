// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MeatbagHook} from "../src/MeatbagHook.sol";
import {MeatbagHerald} from "../src/MeatbagHerald.sol";

/// @notice A wallet that refuses ETH, etched over the swarm's address to see what the hook does then.
contract Rejecter {
    receive() external payable {
        revert("no");
    }
}

/// @title Adversarial edges of the hook: dust, boundaries, a rejecting recipient, wrong pools, reentry
contract MeatbagHookEdgeTest is HookTestBase {
    event Message(address indexed to, string text);

    function setUp() public {
        vm.warp(1_800_000_000);
        setUpPool(true);
    }

    // ---------------------------------------------------------------- dust and rounding

    function test_dustBuyWithAZeroFeeStillSwapsAndCountsVolume() public {
        vm.warp(block.timestamp + 1 hours);
        uint256 tokensBefore = token.balanceOf(address(this));
        buyExactIn(49); // 49 wei * 2% rounds to 0
        assertGe(token.balanceOf(address(this)), tokensBefore);
        assertEq(game.pot() + SWARM.balance + address(treasury).balance, 0, "no fee on dust");
        assertEq(hook.volume(), 49);
        assertTrue(herald.sent(0), "even a dust trade is the first trade");
    }

    function test_oneWeiSellExactOutPaysOneWeiFee() public {
        vm.warp(block.timestamp + 1 hours);
        uint256 before = address(this).balance;
        sellExactOut(1);
        assertEq(address(this).balance - before, 1);
        // 1 * 10000 / 9800 - 1 = 0: the gross-up rounds down, so the fee is zero on one wei.
        assertEq(game.pot() + SWARM.balance + address(treasury).balance, 0);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_splitNeverLosesAWeiAndPotGetsTheDust(uint96 ethIn, uint32 elapsed) public {
        ethIn = uint96(bound(ethIn, 1, 30 ether));
        elapsed = uint32(bound(elapsed, 0, 2 hours));
        vm.warp(hook.launchedAt() + elapsed);
        uint256 rate = hook.buyFeeBps();
        buyExactIn(ethIn);
        uint256 fee = uint256(ethIn) * rate / 10_000;
        uint256 base = uint256(ethIn) * 200 / 10_000;
        assertEq(SWARM.balance, base * 2500 / 10_000, "swarm");
        assertEq(address(treasury).balance, base * 2000 / 10_000, "treasury");
        assertEq(game.pot(), fee - SWARM.balance - address(treasury).balance, "pot takes the rest");
        assertEq(game.pot() + SWARM.balance + address(treasury).balance, fee, "nothing lost");
        assertEq(address(hook).balance, 0);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_buyRateIsMonotoneAndBounded(uint32 t1, uint32 t2) public {
        t1 = uint32(bound(t1, 0, 1 hours));
        t2 = uint32(bound(t2, t1, 1 hours));
        vm.warp(hook.launchedAt() + t1);
        uint256 r1 = hook.buyFeeBps();
        vm.warp(hook.launchedAt() + t2);
        uint256 r2 = hook.buyFeeBps();
        assertGe(r1, r2, "the rate rose");
        assertTrue(r1 <= 2500 && r2 >= 200);
        if (t2 >= 30 minutes) assertEq(r2, 200);
        if (t1 == 0) assertEq(r1, 2500);
    }

    function test_decayBoundaryOneSecondBeforeAndAtThirtyMinutes() public {
        vm.warp(hook.launchedAt() + 30 minutes - 1);
        assertEq(hook.buyFeeBps(), 2500 - uint256(2300) * (30 minutes - 1) / 30 minutes);
        assertGt(hook.buyFeeBps(), 200);
        vm.warp(hook.launchedAt() + 30 minutes);
        assertEq(hook.buyFeeBps(), 200);
    }

    function test_rateIsTwentyFivePercentBeforeAnyPoolOpens() public {
        PoolManager fresh = new PoolManager(address(this));
        MeatbagHook h = deployHook(fresh, address(this));
        assertEq(h.launchedAt(), 0);
        assertEq(h.buyFeeBps(), 2500, "no pool yet: the launch rate");
    }

    // ---------------------------------------------------------------- a recipient that rejects ETH

    function test_aRejectingSwarmWalletNeverHaltsSwapsAndIsRetried() public {
        vm.warp(block.timestamp + 1 hours);
        vm.etch(SWARM, address(new Rejecter()).code);

        buyExactIn(1 ether);

        assertEq(game.pot(), 0.011 ether, "the pot was paid");
        assertEq(address(treasury).balance, 0.004 ether, "the treasury was paid");
        assertEq(hook.owedSwarm(), 0.005 ether, "the swarm's share stays owed");
        assertEq(address(hook).balance, 0.005 ether, "and is held by the hook");

        // Still refused: distribute() keeps it owed.
        hook.distribute();
        assertEq(hook.owedSwarm(), 0.005 ether);

        // A second swap adds to the owed share.
        buyExactIn(1 ether);
        assertEq(hook.owedSwarm(), 0.01 ether);
        assertEq(game.pot(), 0.022 ether);

        // Once the wallet accepts ETH again, anyone pushes it.
        vm.etch(SWARM, "");
        vm.prank(address(0xBEEF));
        hook.distribute();
        assertEq(hook.owedSwarm(), 0);
        assertEq(SWARM.balance, 0.01 ether);
        assertEq(address(hook).balance, 0);
    }

    // ---------------------------------------------------------------- claims and redemption failure paths

    function test_redeemClaimsRevertsWhileTheManagerCannotCoverThem() public {
        setUpPool(false);
        vm.warp(block.timestamp + 1 hours);
        buyExactIn(1 ether);
        assertEq(hook.claims(), 0.02 ether);
        // Drain the manager's ETH so the claim cannot be redeemed, then put it back.
        vm.deal(address(manager), 0);
        vm.expectRevert();
        hook.redeemClaims();
        assertEq(hook.claims(), 0.02 ether, "nothing changed");
        vm.deal(address(manager), 1 ether);
        hook.redeemClaims();
        assertEq(hook.claims(), 0);
        assertEq(game.pot(), 0.011 ether);
    }

    function test_claimsAccumulateAcrossSwapsUntilTheManagerCanPay() public {
        setUpPool(false);
        vm.warp(block.timestamp + 1 hours);
        buyExactIn(1 ether);
        // Keep the manager dry between swaps: every fee becomes a claim.
        vm.deal(address(manager), 0);
        buyExactIn(1 ether);
        assertEq(hook.claims(), 0.04 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.04 ether);
        assertEq(hook.owedPot(), 0.022 ether);
        assertEq(game.pot(), 0);
        // The manager now holds 1 ETH from the second swap: the third swap redeems everything.
        buyExactIn(1 ether);
        assertEq(hook.claims(), 0);
        assertEq(game.pot(), 0.033 ether);
        assertEq(hook.owedPot() + hook.owedSwarm() + hook.owedTreasury(), 0);
    }

    function test_distributeWithNothingOwedIsANoOp() public {
        hook.distribute();
        assertEq(address(hook).balance, 0);
    }

    function test_unlockCallbackCannotBeDrivenByAStranger() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(MeatbagHook.NotPoolManager.selector);
        hook.unlockCallback("");
    }

    // ---------------------------------------------------------------- the wrong pool

    function test_swapOnAnotherPoolThroughThisHookIsRefused() public {
        // A key with the same hook but another fee tier was never initialized, so the manager refuses it.
        PoolKey memory other =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        vm.expectRevert();
        swapRouter.swap{value: 1 ether}(
            other, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        );
        // And the hook itself refuses a swap callback for a key that is not its pool.
        vm.prank(address(manager));
        vm.expectRevert(MeatbagHook.NotThisPool.selector);
        hook.beforeSwap(address(this), other, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "");
    }

    function test_unusedCallbacksRevertEvenForTheManager() public {
        vm.startPrank(address(manager));
        vm.expectRevert(MeatbagHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(MeatbagHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(MeatbagHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- sequences

    function test_buyThenSellRoundTripPaysTwoFeesAndLeavesNothingBehind() public {
        vm.warp(block.timestamp + 1 hours);
        uint256 tokensBefore = token.balanceOf(address(this));
        buyExactIn(1 ether);
        uint256 got = token.balanceOf(address(this)) - tokensBefore;
        sellExactIn(got);
        uint256 fees = game.pot() + SWARM.balance + address(treasury).balance;
        assertGt(fees, 0.02 ether, "a buy fee and a sell fee");
        assertEq(address(hook).balance, 0);
        assertEq(hook.claims(), 0);
        assertEq(hook.owedPot() + hook.owedSwarm() + hook.owedTreasury(), 0);
        assertEq(address(game).balance, game.pot());
    }

    function test_launchSurplusOnExactOutputBuysGoesToThePot() public {
        // At t=0 the rate is 25%; an exact-output buy charges 25% of everything the buyer spends, which
        // is a third of what the pool took, and the 2% base is measured on that same spend.
        uint256 ethBefore = address(this).balance;
        buyExactOut(1 ether, 5 ether);
        uint256 paid = ethBefore - address(this).balance;
        uint256 fee = game.pot() + SWARM.balance + address(treasury).balance;
        uint256 poolTook = paid - fee;
        assertEq(fee, poolTook * 2500 / 7500);
        assertEq(fee, paid * 2500 / 10_000, "25% of the spend");
        uint256 base = paid * 200 / 10_000;
        assertEq(SWARM.balance, base * 2500 / 10_000);
        assertEq(address(treasury).balance, base * 2000 / 10_000);
        assertEq(game.pot(), fee - SWARM.balance - address(treasury).balance);
    }

    function test_volumeMilestoneLettersArePostedOnceEach() public {
        vm.warp(block.timestamp + 1 hours);
        buyExactIn(10 ether);
        assertEq(herald.count(), 4, "launch + first trade + 1 ETH + 10 ETH");
        buyExactIn(10 ether);
        assertEq(herald.count(), 4, "no repeats");
        vm.expectEmit(true, false, false, true, address(herald));
        emit Message(herald.TO(), herald.textOf(3));
        buyExactIn(80 ether);
        assertEq(herald.count(), 5);
    }

    // ---------------------------------------------------------------- the revised fee base and partial fills

    /// @notice An exact-output buy pays the buy rate on everything the buyer spends, exactly as an
    /// exact-input buy does, at every point of the decay: fee = poolEth x rate / (1e4 - rate).
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_exactOutputBuyPaysTheBuyRateOnTheWholeSpend(uint96 tokensOut, uint32 elapsed) public {
        tokensOut = uint96(bound(tokensOut, 1e12, 50 ether));
        elapsed = uint32(bound(elapsed, 0, 1 hours));
        vm.warp(hook.launchedAt() + elapsed);
        uint256 rate = hook.buyFeeBps();
        uint256 ethBefore = address(this).balance;
        buyExactOut(tokensOut, 200 ether);
        uint256 paid = ethBefore - address(this).balance;
        uint256 fee = game.pot() + SWARM.balance + address(treasury).balance;
        uint256 poolEth = paid - fee;
        assertEq(fee, poolEth * rate / (10_000 - rate), "fee is not the rate on the whole spend");
        // Within rounding, the fee over the spend is the rate: the same base as an exact-input buy.
        assertApproxEqAbs(fee * 10_000 / paid, rate, 1);
        assertEq(hook.volume(), paid, "volume is the whole spend");
    }

    /// @notice A refused partial fill leaves no trace: no fee, no volume, no letter, no claim, no owed
    /// balance, and the transient fee slot does not leak into the next swap.
    function test_refusedPartialFillLeavesNoTraceAndTheNextSwapIsClean() public {
        vm.warp(block.timestamp + 1 hours);
        uint256 ethBefore = address(this).balance;
        uint256 tokensBefore = token.balanceOf(address(this));
        // A limit a hair below the current price: a 5 ETH buy cannot be filled within it.
        uint160 limit = uint160(uint256(SQRT_PRICE_1_1) * 999 / 1000);
        vm.expectRevert();
        swapRouter.swap{value: 5 ether}(
            key, SwapParams(true, -5 ether, limit), PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(address(this).balance, ethBefore, "the refused buy kept ETH");
        assertEq(token.balanceOf(address(this)), tokensBefore);
        assertEq(hook.volume(), 0);
        assertEq(game.pot() + SWARM.balance + address(treasury).balance, 0, "a refused swap paid a fee");
        assertEq(hook.claims() + hook.owedPot() + hook.owedSwarm() + hook.owedTreasury(), 0);
        assertFalse(herald.sent(0), "a refused swap counted as the first trade");

        // The next ordinary swap is charged on its own amount only.
        buyExactIn(1 ether);
        assertEq(game.pot() + SWARM.balance + address(treasury).balance, 0.02 ether);
        assertEq(hook.volume(), 1 ether);
    }

    /// @notice An exact-output sell cut short is refused the same way, and the seller keeps their MEAT.
    function test_refusedPartialFillSellKeepsTheSellersTokens() public {
        vm.warp(block.timestamp + 1 hours);
        uint256 tokensBefore = token.balanceOf(address(this));
        uint160 limit = uint160(uint256(SQRT_PRICE_1_1) * 1001 / 1000);
        vm.expectRevert();
        swapRouter.swap(key, SwapParams(false, 5 ether, limit), PoolSwapTest.TestSettings(false, false), "");
        assertEq(token.balanceOf(address(this)), tokensBefore);
        assertEq(hook.volume(), 0);
        assertEq(game.pot() + SWARM.balance + address(treasury).balance, 0);
    }

    /// @notice ETH donated to the hook while fees sit as claims (a manager without ETH) prepays what is
    /// owed, and once the claims are redeemed every recipient has exactly its share plus the pot has the
    /// donation: nothing is lost or double-counted on the way.
    function test_donationWhileClaimsArePendingIsNeitherLostNorCountedTwice() public {
        setUpPool(false); // a fresh manager seeded with tokens only
        vm.warp(hook.launchedAt() + 1 hours);
        buyExactIn(1 ether); // 0.02 ETH fee, minted as a claim: the manager held no ETH yet
        assertEq(hook.claims(), 0.02 ether);
        assertEq(hook.owedPot(), 0.011 ether);
        assertEq(game.pot(), 0);

        (bool ok,) = address(hook).call{value: 0.005 ether}("");
        assertTrue(ok);
        hook.distribute();
        assertEq(address(hook).balance, 0, "the donation stayed in the hook");
        assertEq(game.pot(), 0.005 ether, "the donation reached the pot");
        assertEq(hook.owedPot(), 0.006 ether, "the donation prepaid part of what the pot is owed");
        assertEq(hook.claims(), 0.02 ether, "the claim is untouched");

        buyExactIn(1 ether); // the manager now holds ETH: this fee and the claim are taken as ETH
        assertEq(hook.claims(), 0);
        assertEq(hook.owedPot() + hook.owedSwarm() + hook.owedTreasury(), 0);
        assertEq(address(hook).balance, 0);
        assertEq(game.pot(), 0.022 ether + 0.005 ether, "two 55% shares plus the donation");
        assertEq(SWARM.balance, 0.01 ether, "two 25% shares");
        assertEq(address(treasury).balance, 0.008 ether, "two 20% shares");
    }
}
