// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MeatbagGame} from "../src/MeatbagGame.sol";
import {MeatbagHerald} from "../src/MeatbagHerald.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice A winner that tries to pull its prize twice from inside the payout.
contract ReentrantClaimant {
    MeatbagGame immutable game;
    uint256 public entered;
    bool public innerReverted;

    constructor(MeatbagGame g) {
        game = g;
    }

    function enter(string calldata text) external payable {
        game.enter{value: msg.value}(text);
    }

    function claim() external {
        game.claim();
    }

    receive() external payable {
        entered++;
        if (entered == 1) {
            try game.claim() {}
            catch {
                innerReverted = true;
            }
        }
    }
}

/// @title Adversarial edges of the game: boundaries, malformed answers, reentry, the sunset's gas
contract MeatbagGameEdgeTest is Test {
    uint256 constant SIGNER_KEY = 0xA11CE;
    uint256 constant START = 1_800_000_000;

    address signer = vm.addr(SIGNER_KEY);
    address keeper = address(0xC0FFEE);
    address alice = address(0xA1);
    address bob = address(0xB2);

    MockIntake intake;
    MockERC20 imd;
    MeatbagHerald herald;
    MeatbagGame game;

    function setUp() public {
        vm.warp(START);
        intake = new MockIntake();
        imd = new MockERC20("IMD", "IMD", 1_000 ether);
        address predictedGame = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        herald = new MeatbagHerald(predictedGame);
        game = new MeatbagGame(herald, address(intake), address(imd), signer);
        imd.transfer(keeper, 100 ether);
        vm.prank(keeper);
        imd.approve(address(game), type(uint256).max);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // ---------------------------------------------------------------- helpers

    function enterAs(address who, string memory text) internal {
        uint256 price = game.nextSlotPrice();
        vm.prank(who);
        game.enter{value: price}(text);
    }

    function nextDay() internal {
        vm.warp((game.today() + 1) * 1 days + 1 hours);
    }

    function judgeAs(address who) internal returns (bytes32 id) {
        vm.prank(who);
        id = game.judge();
    }

    function attestation(bytes32 intakeId, uint256 answerIndex)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("oracle", intakeId)),
            chainId: 1,
            questionHash: keccak256(intake.lastBody()),
            answerType: OracleAttestation.ANSWER_UINT256,
            answer: abi.encode(answerIndex),
            figure: 0,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: keccak256(abi.encode("panel", intakeId)),
            panelSize: 7,
            quorum: 4,
            agreed: 5,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp() + 1 days)
        });
    }

    function sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, game.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function hungRound(address who) internal {
        enterAs(who, "a");
        nextDay();
        judgeAs(keeper);
        vm.warp(vm.getBlockTimestamp() + game.VERDICT_TIMEOUT());
        game.declareHungJury();
    }

    // ---------------------------------------------------------------- entering: boundaries

    function test_dayBoundaryIsExact() public {
        uint256 day = game.today();
        vm.warp((day + 1) * 1 days - 1);
        enterAs(alice, "last second");
        assertEq(game.entry(day, 0).author, alice);
        vm.warp((day + 1) * 1 days);
        assertEq(game.today(), day + 1);
        enterAs(alice, "first second of tomorrow");
        assertEq(game.roundCount(), 2);
        assertEq(game.entry(day + 1, 0).author, alice);
        // Yesterday's round closed the moment the day turned.
        judgeAs(keeper);
        assertEq(uint8(game.round(day).status), uint8(MeatbagGame.Status.Pending));
    }

    function test_asciiBoundsAreInclusive() public {
        enterAs(alice, " "); // 0x20
        enterAs(bob, "~"); // 0x7E
        vm.prank(address(0xC3));
        vm.deal(address(0xC3), 1 ether);
        vm.expectRevert(MeatbagGame.NotAscii.selector);
        game.enter{value: 0.003 ether}(string(abi.encodePacked(bytes1(0x7F))));
        vm.prank(address(0xC3));
        vm.expectRevert(MeatbagGame.NotAscii.selector);
        game.enter{value: 0.003 ether}(string(abi.encodePacked(bytes1(0x1F))));
        vm.prank(address(0xC3));
        vm.expectRevert(MeatbagGame.NotAscii.selector);
        game.enter{value: 0.003 ether}("tab\there");
    }

    function test_underpaymentAndZeroPaymentAreRefused() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MeatbagGame.WrongPayment.selector, 0.001 ether));
        game.enter{value: 0}("free?");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MeatbagGame.WrongPayment.selector, 0.001 ether));
        game.enter{value: 0.001 ether - 1}("almost");
    }

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_slotPricesSumToTheTriangle(uint8 n) public {
        n = uint8(bound(n, 1, 40));
        for (uint256 i = 0; i < n; i++) {
            address who = address(uint160(0x2000 + i));
            vm.deal(who, 1 ether);
            assertEq(game.nextSlotPrice(), (i + 1) * 0.001 ether);
            enterAs(who, "human");
        }
        assertEq(game.pot(), uint256(n) * (uint256(n) + 1) / 2 * 0.001 ether);
        assertEq(game.round(game.today()).count, n);
    }

    // ---------------------------------------------------------------- judging: who can and what it costs

    function test_judgeNeedsTheKeepersImd() public {
        enterAs(alice, "a");
        nextDay();
        address broke = address(0xB40);
        vm.prank(broke);
        vm.expectRevert();
        game.judge();
        imd.transfer(broke, 0.5 ether);
        vm.prank(broke);
        vm.expectRevert(); // not approved
        game.judge();
        vm.prank(broke);
        imd.approve(address(game), 0.5 ether);
        vm.prank(broke);
        game.judge();
        assertEq(imd.balanceOf(broke), 0);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
    }

    function test_keeperRewardIsThreePercentOfThePotAtRequestTime() public {
        enterAs(alice, "a");
        (bool ok,) = address(game).call{value: 0.999 ether}("");
        assertTrue(ok);
        assertEq(game.pot(), 1 ether);
        nextDay();
        judgeAs(keeper);
        assertEq(game.claimable(keeper), 0.03 ether);
        assertEq(game.pot(), 0.97 ether);
        uint256 before = keeper.balance;
        vm.prank(keeper);
        game.claim();
        assertEq(keeper.balance - before, 0.03 ether);
    }

    // ---------------------------------------------------------------- the callback: malformed and foreign answers

    function test_wrongAnswerTypeIsAHungJury() public {
        enterAs(alice, "a");
        nextDay();
        bytes32 id = judgeAs(keeper);
        OracleAttestation.Attestation memory a = attestation(id, 0);
        a.answerType = OracleAttestation.ANSWER_BOOL;
        a.answer = abi.encode(true);
        assertTrue(intake.deliver(id, a, sign(a)));
        assertEq(uint8(game.round(game.roundDays(0)).status), uint8(MeatbagGame.Status.Hung));
        assertEq(game.claimable(alice), 0);
    }

    function test_malformedAnswerBytesDoNotSettleTheRound() public {
        enterAs(alice, "a");
        nextDay();
        bytes32 id = judgeAs(keeper);
        OracleAttestation.Attestation memory a = attestation(id, 0);
        a.answer = hex"01"; // not an abi-encoded uint256
        assertFalse(intake.deliver(id, a, sign(a)), "the callback reverts on a malformed answer");
        assertEq(uint8(game.round(game.roundDays(0)).status), uint8(MeatbagGame.Status.Pending), "still pending");
        assertFalse(game.consumed(a.requestId), "nothing consumed");
        // The timeout path still returns the round to the carry-over.
        vm.warp(vm.getBlockTimestamp() + game.VERDICT_TIMEOUT());
        game.declareHungJury();
        assertEq(uint8(game.round(game.roundDays(0)).status), uint8(MeatbagGame.Status.Hung));
    }

    function test_signatureForAnotherChainIsRefused() public {
        enterAs(alice, "a");
        nextDay();
        bytes32 id = judgeAs(keeper);
        OracleAttestation.Attestation memory a = attestation(id, 0);
        // Explicit chain ids on both sides: via-IR may reorder a `block.chainid` read past the cheatcode.
        vm.chainId(1);
        bytes32 homeDigest = game.attestationDigest(a);
        vm.chainId(4663);
        assertTrue(game.attestationDigest(a) != homeDigest, "the domain must change with the chain");
        bytes memory sig = sign(a); // signed in the Robinhood Chain domain
        vm.chainId(1);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.deliverTo(address(game), game.onOracleResult.selector, id, a, sig);
    }

    function test_attestationAtTheExactExpiryStillVerifies() public {
        enterAs(alice, "a");
        nextDay();
        bytes32 id = judgeAs(keeper);
        OracleAttestation.Attestation memory a = attestation(id, 0);
        a.expiresAt = uint64(vm.getBlockTimestamp());
        assertTrue(intake.deliver(id, a, sign(a)), "expiresAt == now is still valid");
        assertEq(uint8(game.round(game.roundDays(0)).status), uint8(MeatbagGame.Status.Settled));
    }

    function test_issuedAtWithinToleranceIsAccepted() public {
        enterAs(alice, "a");
        nextDay();
        bytes32 id = judgeAs(keeper);
        OracleAttestation.Attestation memory a = attestation(id, 0);
        a.issuedAt = uint64(vm.getBlockTimestamp() + 5 minutes);
        assertTrue(intake.deliver(id, a, sign(a)));
    }

    function test_truncatedSignatureIsRefused() public {
        enterAs(alice, "a");
        nextDay();
        bytes32 id = judgeAs(keeper);
        OracleAttestation.Attestation memory a = attestation(id, 0);
        bytes memory sig = sign(a);
        bytes memory short = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            short[i] = sig[i];
        }
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.deliverTo(address(game), game.onOracleResult.selector, id, a, short);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.deliverTo(address(game), game.onOracleResult.selector, id, a, "");
    }

    // ---------------------------------------------------------------- claims: reentry and strangers

    function test_claimIsNotReenterable() public {
        ReentrantClaimant r = new ReentrantClaimant(game);
        vm.deal(address(r), 1 ether);
        r.enter{value: 0.001 ether}("I am a contract pretending to be a person");
        (bool ok,) = address(game).call{value: 1 ether}("");
        assertTrue(ok);
        nextDay();
        bytes32 id = judgeAs(keeper);
        OracleAttestation.Attestation memory a = attestation(id, 0);
        assertTrue(intake.deliver(id, a, sign(a)));
        uint256 prize = game.claimable(address(r));
        uint256 before = address(r).balance;
        r.claim();
        assertEq(address(r).balance - before, prize, "paid once");
        assertTrue(r.innerReverted(), "the reentrant claim found nothing");
        assertEq(game.claimable(address(r)), 0);
        assertEq(address(game).balance, game.pot() + game.totalClaimable());
    }

    function test_sunsetClaimsRefuseStrangersAndUnsunsetRounds() public {
        for (uint256 i = 0; i < 7; i++) {
            hungRound(alice);
        }
        uint256 day0 = game.roundDays(0);
        assertGt(game.round(day0).sunsetShare, 0);
        vm.prank(bob);
        vm.expectRevert(MeatbagGame.NothingToClaim.selector);
        game.claimSunset(day0);
        // A round outside the window.
        enterAs(alice, "a");
        uint256 todayDay = game.today();
        vm.prank(alice);
        vm.expectRevert(MeatbagGame.NothingToClaim.selector);
        game.claimSunset(todayDay);
        vm.prank(alice);
        vm.expectRevert(MeatbagGame.NothingToClaim.selector);
        game.claimSunset(12345);
    }

    function test_sunsetSharesAreEqualPerEntryNotPerWallet() public {
        (bool ok,) = address(game).call{value: 11 ether}("");
        assertTrue(ok);
        for (uint256 i = 0; i < 7; i++) {
            enterAs(alice, "a");
            if (i == 0) enterAs(bob, "b");
            nextDay();
            judgeAs(keeper);
            vm.warp(vm.getBlockTimestamp() + game.VERDICT_TIMEOUT());
            game.declareHungJury();
        }
        uint256 share = game.round(game.roundDays(0)).sunsetShare;
        assertGt(share, 0);
        uint256 total;
        vm.startPrank(alice);
        for (uint256 i = 0; i < 7; i++) {
            uint256 before = alice.balance;
            game.claimSunset(game.roundDays(i));
            total += alice.balance - before;
        }
        vm.stopPrank();
        assertEq(total, share * 7, "alice: one share per round entered");
        uint256 firstDay = game.roundDays(0);
        vm.prank(bob);
        game.claimSunset(firstDay);
        assertEq(game.totalClaimable() - game.claimable(keeper), 0, "every sunset share claimed");
        vm.prank(keeper);
        game.claim();
        assertEq(game.totalClaimable(), 0, "everything claimed");
        assertEq(address(game).balance, game.pot());
    }

    function test_anEighthHungRoundStartsANewStreakNotANewSunset() public {
        for (uint256 i = 0; i < 7; i++) {
            hungRound(alice);
        }
        assertEq(game.unsettledStreak(), 0);
        hungRound(alice);
        assertEq(game.unsettledStreak(), 1);
        assertEq(game.round(game.roundDays(7)).sunsetShare, 0, "no sunset for a streak of one");
    }

    // ---------------------------------------------------------------- the sunset inside the callback

    /// @notice A seventh hung jury delivered by the oracle lands under the 200,000 gas callback stipend
    /// and leaves the split due; `sunset()` then performs it. Whether or not that delivery fits, the pot
    /// must still reach the entrants: by `sunset()`, or by `declareHungJury()` after the timeout.
    function test_seventhHungJuryFromTheOracleStillSunsetsThePot() public {
        (bool ok,) = address(game).call{value: 7 ether}("");
        assertTrue(ok);
        for (uint256 i = 0; i < 6; i++) {
            hungRound(alice);
        }
        enterAs(alice, "a");
        nextDay();
        bytes32 id = judgeAs(keeper);
        OracleAttestation.Attestation memory a = attestation(id, 0);
        a.agreed = 3; // the panel did not agree: hung, and the seventh in a row
        bool delivered = intake.deliver(id, a, sign(a));
        if (!delivered) {
            // Did not fit the stipend: the round is still pending and the timeout path takes over.
            assertEq(uint8(game.round(game.roundDays(6)).status), uint8(MeatbagGame.Status.Pending));
            vm.warp(vm.getBlockTimestamp() + game.VERDICT_TIMEOUT());
            game.declareHungJury();
        } else {
            assertEq(uint8(game.round(game.roundDays(6)).status), uint8(MeatbagGame.Status.Hung));
            assertEq(game.unsettledStreak(), 7, "the callback only marks the round hung");
            assertTrue(game.sunsetDue());
            game.sunset();
        }
        assertEq(game.unsettledStreak(), 0, "the sunset happened");
        uint256 share = game.round(game.roundDays(0)).sunsetShare;
        assertGt(share, 0);
        assertEq(game.totalClaimable() - game.claimable(keeper), share * 7);
        uint256 lastDay = game.roundDays(6);
        vm.prank(alice);
        game.claimSunset(lastDay);
    }

    // ---------------------------------------------------------------- carry-over across verdicts

    function test_carryOverCompoundsAcrossRounds() public {
        enterAs(alice, "a");
        (bool ok,) = address(game).call{value: 1 ether}("");
        assertTrue(ok);
        nextDay();
        bytes32 id = judgeAs(keeper);
        uint256 potAtJudging = game.pot(); // after the keeper's 3%
        OracleAttestation.Attestation memory a = attestation(id, 0);
        assertTrue(intake.deliver(id, a, sign(a)));
        uint256 carried = potAtJudging - potAtJudging * 8000 / 10_000;
        assertEq(game.pot(), carried);

        enterAs(bob, "b");
        nextDay();
        bytes32 id2 = judgeAs(keeper);
        uint256 pot2 = carried + 0.001 ether;
        assertEq(game.pot(), pot2 - pot2 * 300 / 10_000);
        a = attestation(id2, 0);
        assertTrue(intake.deliver(id2, a, sign(a)));
        assertEq(game.claimable(bob), (pot2 - pot2 * 300 / 10_000) * 8000 / 10_000);
        assertEq(address(game).balance, game.pot() + game.totalClaimable());
    }

    function test_fortyEntriesJudgeBodyFitsTheIntakeLimit() public {
        for (uint256 i = 0; i < 40; i++) {
            address who = address(uint160(0x3000 + i));
            vm.deal(who, 1 ether);
            bytes memory t = new bytes(200);
            for (uint256 j = 0; j < 200; j++) {
                t[j] = bytes1(uint8(0x20 + (i + j) % 95));
            }
            enterAs(who, string(t));
        }
        bytes memory body = game.judgeBody(game.today());
        assertLe(body.length, 16 * 1024, "over the intake's 16 KiB body limit");
        assertTrue(vm.contains(string(body), '"entry_39":"'));
        nextDay();
        bytes32 id = judgeAs(keeper);
        OracleAttestation.Attestation memory a = attestation(id, 39);
        assertTrue(intake.deliver(id, a, sign(a)), "a full round settles under 200k gas");
        assertEq(game.round(game.roundDays(0)).winner, 39);
    }

    // ---------------------------------------------------------------- unjudged rounds, the sunset call, the live price

    /// @notice A closed round nobody judged may be hung from `hungJuryAt()` exactly (01:00 UTC two days
    /// after its day) and not one second before; an open round can never be hung.
    function test_unjudgedRoundHangsAtHungJuryAtExactlyNotBefore() public {
        uint256 day = game.today();
        enterAs(alice, "a");
        assertEq(game.hungJuryAt(), (day + 1) * 1 days + game.VERDICT_TIMEOUT());
        vm.expectRevert(abi.encodeWithSelector(MeatbagGame.NotTimedOut.selector, day));
        game.declareHungJury(); // still open
        vm.warp(game.hungJuryAt() - 1);
        vm.expectRevert(abi.encodeWithSelector(MeatbagGame.NotTimedOut.selector, day));
        game.declareHungJury();
        vm.warp(game.hungJuryAt());
        game.declareHungJury();
        assertEq(uint8(game.round(day).status), uint8(MeatbagGame.Status.Hung));
        assertEq(game.unsettledStreak(), 1);
        assertEq(game.hungJuryAt(), 0, "nothing waits");
        vm.expectRevert(MeatbagGame.NothingToJudge.selector);
        game.declareHungJury();
    }

    /// @notice `hungJuryAt()` switches to the request's own timeout once a round is pending, so judging
    /// a round late pushes its hung-jury moment out rather than leaving it already due.
    function test_hungJuryAtFollowsTheRequestOnceJudged() public {
        uint256 day = game.today();
        enterAs(alice, "a");
        vm.warp((day + 1) * 1 days + game.VERDICT_TIMEOUT() - 1); // one second before it could be hung
        judgeAs(keeper);
        assertEq(game.hungJuryAt(), vm.getBlockTimestamp() + game.VERDICT_TIMEOUT());
        vm.expectRevert(abi.encodeWithSelector(MeatbagGame.NotTimedOut.selector, day));
        game.declareHungJury();
    }

    /// @notice `sunset()` is refused unless seven rounds are unsettled, and settles exactly once.
    function test_sunsetRefusedUnlessDueAndOnlyOnce() public {
        vm.expectRevert(MeatbagGame.NoSunsetDue.selector);
        game.sunset();
        for (uint256 i = 0; i < 6; i++) {
            hungRound(alice);
        }
        vm.expectRevert(MeatbagGame.NoSunsetDue.selector);
        game.sunset();
        // The seventh hung jury comes from the oracle: it leaves the split to anyone.
        enterAs(alice, "a");
        nextDay();
        bytes32 id = judgeAs(keeper);
        OracleAttestation.Attestation memory a = attestation(id, 0);
        a.agreed = 3;
        assertTrue(intake.deliver(id, a, sign(a)));
        assertTrue(game.sunsetDue());
        assertEq(game.unsettledStreak(), 7);
        uint256 pot = game.pot();
        game.sunset();
        assertFalse(game.sunsetDue());
        assertEq(game.pot(), pot - (pot / 7) * 7, "only the division's dust stays in the pot");
        assertEq(game.round(game.roundDays(6)).sunsetShare, pot / 7);
        vm.expectRevert(MeatbagGame.NoSunsetDue.selector);
        game.sunset();
    }

    /// @notice While a sunset is due, entering continues and the new round is untouched by the split.
    function test_entriesDuringADueSunsetAreNotPartOfTheSplit() public {
        for (uint256 i = 0; i < 6; i++) {
            hungRound(alice);
        }
        enterAs(alice, "a");
        nextDay();
        bytes32 id = judgeAs(keeper);
        OracleAttestation.Attestation memory a = attestation(id, 0);
        a.agreed = 3;
        assertTrue(intake.deliver(id, a, sign(a)));
        assertTrue(game.sunsetDue());
        enterAs(bob, "b"); // today's round, after the seventh hung one
        uint256 bobsDay = game.today();
        game.sunset();
        assertEq(game.round(bobsDay).sunsetShare, 0, "the open round was split");
        assertEq(uint8(game.round(bobsDay).status), uint8(MeatbagGame.Status.Open));
        vm.prank(bob);
        vm.expectRevert(MeatbagGame.NothingToClaim.selector);
        game.claimSunset(bobsDay);
    }

    /// @notice The keeper's IMD is pulled at the intake's price of the moment, and a price the intake
    /// raises after approval is what the next judge pays.
    function test_judgePullsThePriceOfTheMoment() public {
        intake.setPrice(0.75 ether);
        enterAs(alice, "a");
        nextDay();
        uint256 before = imd.balanceOf(keeper);
        judgeAs(keeper);
        assertEq(before - imd.balanceOf(keeper), 0.75 ether);
        assertEq(imd.balanceOf(address(intake)), 0.75 ether);
        assertEq(imd.allowance(address(game), address(intake)), 0, "no approval left dangling");
    }

    /// @notice A keeper who holds less IMD than the live price cannot judge.
    function test_judgeRefusedWhenTheKeeperCannotPayTheLivePrice() public {
        enterAs(alice, "a");
        nextDay();
        intake.setPrice(200 ether); // more than the keeper holds
        vm.prank(keeper);
        vm.expectRevert();
        game.judge();
        assertEq(uint8(game.round(game.roundDays(0)).status), uint8(MeatbagGame.Status.Open));
        assertEq(game.claimable(keeper), 0, "no reward for a failed judge");
    }
}
