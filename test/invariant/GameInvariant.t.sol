// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MeatbagGame} from "../../src/MeatbagGame.sol";
import {MeatbagHerald} from "../../src/MeatbagHerald.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";
import {MockIntake} from "../mocks/MockIntake.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Drives the game through random sequences: entries, donations, days passing, judging, oracle
/// deliveries (verdicts, weak panels, out-of-range answers), timeouts, claims and sunset claims. Every
/// call is guarded so it never reverts; the invariants below are checked after each one.
contract GameHandler is Test {
    uint256 constant SIGNER_KEY = 0xA11CE;
    uint256 constant ACTORS = 6;

    MeatbagGame public game;
    MockIntake public intake;
    MockERC20 public imd;

    address[] public actors;
    uint256 public deposited; // every wei that went in: entries and donations
    uint256 public withdrawn; // every wei that came out through claim / claimSunset
    uint256 public verdicts;
    uint256 public hungJuries;
    uint256 public sunsets;
    /// @dev Valid deliveries that ran out of the 200,000 gas stipend and had to be repeated with more.
    uint256 public stipendFailures;
    mapping(address => uint256) public withdrawnBy;

    constructor(MeatbagGame game_, MockIntake intake_, MockERC20 imd_) {
        game = game_;
        intake = intake_;
        imd = imd_;
        for (uint256 i = 0; i < ACTORS; i++) {
            address a = address(uint160(0xA000 + i));
            actors.push(a);
            vm.deal(a, 100 ether);
            imd.mint(a, 1_000 ether);
            vm.prank(a);
            imd.approve(address(game), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---------------------------------------------------------------- actions

    function enter(uint256 actorSeed, uint256 textSeed) external {
        address who = actors[actorSeed % ACTORS];
        uint256 day = game.today();
        if (game.hasEntered(day, who)) return;
        uint256 price = game.nextSlotPrice();
        if (price == 0) return;
        bytes memory text = new bytes(1 + textSeed % 200);
        for (uint256 i = 0; i < text.length; i++) {
            text[i] = bytes1(uint8(0x20 + (uint256(keccak256(abi.encode(textSeed, i))) % 95)));
        }
        vm.prank(who);
        game.enter{value: price}(string(text));
        deposited += price;
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 0, 2 ether);
        if (amount == 0) return;
        vm.deal(address(this), amount);
        (bool ok,) = address(game).call{value: amount}("");
        require(ok, "donation refused");
        deposited += amount;
    }

    function warp(uint256 hoursAhead) external {
        hoursAhead = bound(hoursAhead, 1, 30);
        vm.warp(vm.getBlockTimestamp() + hoursAhead * 1 hours);
    }

    /// @dev The intake's price moves (never to zero here: the mock then refuses the request, which is
    /// the mock's rule rather than the game's; the zero fallback has its own unit test).
    function setPrice(uint256 price) external {
        price = bound(price, 1, 2 ether);
        intake.setPrice(price);
    }

    /// @dev The intake stops or resumes selling the action.
    function setRefusing(bool refusing) external {
        intake.setRefusing(refusing);
    }

    function judge(uint256 actorSeed) external {
        address who = actors[actorSeed % ACTORS];
        uint256 day = game.nextRoundToJudge();
        if (day == 0) return;
        MeatbagGame.Round memory r = game.round(day);
        if (r.status == MeatbagGame.Status.Pending) {
            if (vm.getBlockTimestamp() < r.requestedAt + game.VERDICT_TIMEOUT()) return;
            // The sweep moves on to the next round, which may not exist or may still be open.
            uint256 idx = game.cursor() + 1;
            if (idx >= game.roundCount()) return;
            day = game.roundDays(idx);
        }
        if (day >= game.today()) return;
        if (intake.refusing()) {
            vm.prank(who);
            try game.judge() {
                revert("judge went through while the intake refuses the action");
            } catch {}
            return;
        }
        uint256 price = game.judgePrice();
        require(price == intake.price(), "judgePrice does not follow the intake");
        uint256 imdBefore = imd.balanceOf(who);
        uint256 potBefore = game.pot();
        bool sunsetWasDue = game.sunsetDue();
        vm.prank(who);
        game.judge();
        if (sunsetWasDue) sunsets++;
        require(imdBefore - imd.balanceOf(who) == price, "judge pulled something other than the price");
        require(imd.balanceOf(address(intake)) >= price, "the intake was not paid");
        // A sweep of a timed-out round or a due sunset shrinks the pot before the reward is measured.
        if (!sunsetWasDue && r.status != MeatbagGame.Status.Pending) {
            require(game.claimable(who) >= potBefore * 300 / 10_000, "keeper not rewarded 3%");
        }
        require(game.unsettledStreak() < game.SUNSET_AFTER(), "judge left a sunset due");
        _letterIsOut();
    }

    /// @dev Every public transition posts the first-verdict letter on its way once a verdict landed.
    function _letterIsOut() internal view {
        if (verdicts > 0) require(game.firstVerdictAnnounced(), "a verdict landed but the letter is missing");
    }

    function announce() external {
        game.announceFirstVerdict();
        _letterIsOut();
    }

    /// @dev Splits a sunset the oracle callback left due; refused otherwise.
    function sunset() external {
        if (game.sunsetDue()) {
            uint256 potBefore = game.pot();
            game.sunset();
            sunsets++;
            require(game.unsettledStreak() == 0, "sunset did not reset the streak");
            require(game.pot() <= potBefore, "sunset grew the pot");
            _letterIsOut();
            return;
        }
        try game.sunset() {
            revert("sunset went through while none was due");
        } catch {}
    }

    function deliver(uint256 answerSeed, uint256 kind) external {
        uint256 day = game.nextRoundToJudge();
        if (day == 0) return;
        MeatbagGame.Round memory r = game.round(day);
        if (r.status != MeatbagGame.Status.Pending) return;
        kind = kind % 10;
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("oracle", r.intakeRequestId)),
            chainId: 1,
            questionHash: keccak256(intake.lastBody()),
            answerType: OracleAttestation.ANSWER_UINT256,
            answer: abi.encode(answerSeed % r.count),
            figure: 0,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: keccak256(abi.encode("panel", r.intakeRequestId)),
            panelSize: 7,
            quorum: 4,
            agreed: 5,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp() + 1 days)
        });
        if (kind == 7) a.agreed = 3; // weak panel: hung
        if (kind == 8) a.answer = abi.encode(uint256(r.count) + answerSeed % 5); // out of range: hung
        if (kind == 9) a.panelSize = 5; // small panel: hung
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(SIGNER_KEY, game.attestationDigest(a));
        uint256 cursorBefore = game.cursor();
        uint256 streakBefore = game.unsettledStreak();
        bool letterBefore = game.firstVerdictAnnounced();
        bytes memory sig = abi.encodePacked(rr, ss, v);
        bool ok = intake.deliver(r.intakeRequestId, a, sig);
        if (!ok) {
            // A well-formed, well-signed answer for the pending request must land under the writer's
            // 200,000 gas stipend; a miss is counted (and `invariant_validAnswersFitTheStipend` fails on
            // it). The delivery is repeated with unbounded gas, which bubbles any revert that is not
            // out-of-gas: the attestation itself must be good.
            stipendFailures++;
            intake.deliverTo(address(game), game.onOracleResult.selector, r.intakeRequestId, a, sig);
        }
        // The callback never posts the first-verdict letter itself: it waits for an ordinary transaction.
        require(game.firstVerdictAnnounced() == letterBefore, "the oracle callback posted the letter");
        require(game.cursor() == cursorBefore + 1, "a delivered answer must close the round");
        if (kind >= 7) {
            hungJuries++;
            // The callback never splits the pot itself: the seventh hung jury leaves the sunset due.
            require(game.unsettledStreak() == streakBefore + 1, "streak grows by one per hung jury");
            require(game.sunsetDue() == (game.unsettledStreak() >= game.SUNSET_AFTER()), "sunsetDue");
        } else {
            verdicts++;
            require(game.unsettledStreak() == 0, "a verdict resets the streak");
        }
    }

    /// @dev Declares the cursor round hung once `hungJuryAt()` has passed: a timed-out request, or a
    /// closed round nobody judged (the intake refusing, say). Refused one second earlier.
    function declareHung() external {
        uint256 day = game.nextRoundToJudge();
        if (day == 0) return;
        uint256 at = game.hungJuryAt();
        if (vm.getBlockTimestamp() < at) {
            try game.declareHungJury() {
                revert("a round was hung before hungJuryAt");
            } catch {}
            return;
        }
        uint256 streakBefore = game.unsettledStreak();
        bool sunsetWasDue = game.sunsetDue();
        game.declareHungJury();
        hungJuries++;
        if (sunsetWasDue) sunsets++;
        uint256 streak = game.unsettledStreak();
        if (streak == 0) {
            sunsets++;
            require(sunsetWasDue || streakBefore + 1 == game.SUNSET_AFTER(), "streak reset without a sunset");
        } else {
            require(streak == (sunsetWasDue ? 1 : streakBefore + 1), "streak grows by one");
        }
        require(game.round(day).status == MeatbagGame.Status.Hung, "round not hung");
        _letterIsOut();
    }

    function claim(uint256 actorSeed) external {
        address who = actors[actorSeed % ACTORS];
        uint256 owed = game.claimable(who);
        if (owed == 0) return;
        uint256 before = who.balance;
        vm.prank(who);
        game.claim();
        require(who.balance - before == owed, "claim pays exactly what was owed");
        withdrawn += owed;
        withdrawnBy[who] += owed;
        _letterIsOut();
    }

    function claimSunset(uint256 actorSeed, uint256 roundSeed) external {
        address who = actors[actorSeed % ACTORS];
        uint256 n = game.roundCount();
        if (n == 0) return;
        uint256 day = game.roundDays(roundSeed % n);
        uint256 share = game.round(day).sunsetShare;
        if (share == 0 || !game.hasEntered(day, who) || game.sunsetClaimed(day, who)) return;
        uint256 before = who.balance;
        vm.prank(who);
        game.claimSunset(day);
        require(who.balance - before == share, "sunset claim pays exactly the share");
        withdrawn += share;
        withdrawnBy[who] += share;
    }
}

/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = true
contract GameInvariantTest is Test {
    uint256 constant SIGNER_KEY = 0xA11CE;

    MockIntake intake;
    MockERC20 imd;
    MeatbagHerald herald;
    MeatbagGame game;
    GameHandler handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        intake = new MockIntake();
        imd = new MockERC20("IMD", "IMD", 0);
        address predictedGame = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        herald = new MeatbagHerald(predictedGame);
        game = new MeatbagGame(herald, address(intake), address(imd), vm.addr(SIGNER_KEY));
        handler = new GameHandler(game, intake, imd);
        targetContract(address(handler));
    }

    /// @notice What the game holds is exactly the pot plus every unpulled claim.
    function invariant_balanceIsPotPlusClaims() public view {
        assertEq(address(game).balance, game.pot() + game.totalClaimable(), "balance != pot + claimable");
    }

    /// @notice Nothing leaves except through claims, and claims never exceed what went in.
    function invariant_ethIsConserved() public view {
        assertEq(handler.deposited(), address(game).balance + handler.withdrawn(), "ETH in != held + out");
        assertLe(handler.withdrawn(), handler.deposited());
    }

    /// @notice Pull balances and unclaimed sunset shares add up to `totalClaimable`: no claim is minted
    /// out of thin air and none is lost.
    function invariant_claimsAreFullyAccountedFor() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += game.claimable(handler.actors(i));
        }
        uint256 n = game.roundCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 day = game.roundDays(i);
            uint256 share = game.round(day).sunsetShare;
            if (share == 0) continue;
            MeatbagGame.Entry[] memory es = game.entries(day);
            for (uint256 j = 0; j < es.length; j++) {
                if (!game.sunsetClaimed(day, es[j].author)) sum += share;
            }
        }
        assertEq(sum, game.totalClaimable(), "claimable sum != totalClaimable");
    }

    /// @notice Rounds move through Open -> Pending -> Settled | Hung in order, and a finished round never
    /// reopens: everything before the cursor is finished, nothing at or after it is.
    function invariant_roundsAreFinishedInOrderAndStayFinished() public view {
        uint256 n = game.roundCount();
        uint256 cursor = game.cursor();
        assertLe(cursor, n, "cursor past the last round");
        for (uint256 i = 0; i < n; i++) {
            uint256 day = game.roundDays(i);
            MeatbagGame.Round memory r = game.round(day);
            assertTrue(r.count > 0 && r.count <= game.MAX_ENTRIES(), "entry count out of range");
            assertEq(r.count, game.entries(day).length, "count != entries");
            if (i < cursor) {
                assertTrue(
                    r.status == MeatbagGame.Status.Settled || r.status == MeatbagGame.Status.Hung,
                    "a round before the cursor is not finished"
                );
                if (r.status == MeatbagGame.Status.Settled) {
                    assertLt(r.winner, r.count, "winner out of range");
                    assertEq(r.sunsetShare, 0, "a settled round carries a sunset share");
                }
            } else {
                assertTrue(
                    r.status == MeatbagGame.Status.Open || r.status == MeatbagGame.Status.Pending,
                    "a round at or after the cursor is finished"
                );
                if (i > cursor) assertTrue(r.status == MeatbagGame.Status.Open, "only the cursor round may pend");
                assertEq(r.sunsetShare, 0, "an unfinished round carries a sunset share");
            }
            if (i + 1 < n) assertLt(day, game.roundDays(i + 1), "rounds out of day order");
        }
    }

    /// @notice The sunset rule fires at seven: the streak never passes it, and at seven the split is
    /// due (left by the oracle callback for `sunset()`, `judge()` or `declareHungJury()` to settle).
    function invariant_streakNeverPassesSunset() public view {
        uint256 streak = game.unsettledStreak();
        assertLe(streak, game.SUNSET_AFTER(), "streak passed the sunset threshold");
        assertEq(game.sunsetDue(), streak == game.SUNSET_AFTER(), "sunsetDue disagrees with the streak");
        assertLe(streak, game.cursor());
        // The streak's rounds are the last `streak` finished rounds, all hung and not yet split.
        for (uint256 i = game.cursor() - streak; i < game.cursor(); i++) {
            MeatbagGame.Round memory r = game.round(game.roundDays(i));
            assertTrue(r.status == MeatbagGame.Status.Hung, "a streak round is not hung");
            assertEq(r.sunsetShare, 0, "a streak round was already split");
        }
    }

    /// @notice A valid, well-signed answer always lands under the oracle writer's 200,000 gas stipend.
    function invariant_validAnswersFitTheStipend() public view {
        assertEq(handler.stipendFailures(), 0, "a valid answer ran out of the 200,000 gas stipend");
    }

    /// @notice The first-verdict letter is posted at most once, only by the game, and only after a round
    /// actually settled.
    function invariant_firstVerdictLetterFollowsASettledRound() public view {
        assertEq(herald.sent(4), game.firstVerdictAnnounced(), "herald and game disagree on the letter");
        if (!game.firstVerdictAnnounced()) return;
        bool settled;
        for (uint256 i = 0; i < game.cursor(); i++) {
            if (game.round(game.roundDays(i)).status == MeatbagGame.Status.Settled) settled = true;
        }
        assertTrue(settled, "letter posted without a verdict");
    }

    /// @notice The pot record never falls below the pot at any judging, and the pot never exceeds what
    /// went in.
    function invariant_potBounds() public view {
        assertLe(game.pot(), handler.deposited());
        assertLe(game.potRecord(), handler.deposited());
    }
}
