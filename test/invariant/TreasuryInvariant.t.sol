// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HeartbeatTreasury} from "../../src/HeartbeatTreasury.sol";

/// @notice Feeds the treasury (fee-sized amounts and dust) and calls `fundNextRun` at random moments
/// from random callers. Every accepted run is checked against the rule: min(balance, 0.01 ETH), only
/// once the previous run's closing time has passed, and the next closing time proportional to the
/// amount sent.
contract TreasuryHandler is Test {
    HeartbeatTreasury public treasury;
    uint256 public fundedIn;
    uint256 public paidOut;
    uint256 public runs;
    uint256 public fullRuns;
    uint256 public dustRuns;
    uint256 public lastAmount;
    uint256 public start;

    constructor(HeartbeatTreasury t) {
        treasury = t;
        start = vm.getBlockTimestamp();
    }

    function feed(uint256 amount) external {
        amount = bound(amount, 0, 0.05 ether);
        _feed(amount);
    }

    /// @dev Dust: below the 0.01 ETH cap by orders of magnitude, so partial runs with short closings
    /// happen often.
    function feedDust(uint256 amount) external {
        amount = bound(amount, 1, 1e13);
        _feed(amount);
    }

    function _feed(uint256 amount) internal {
        if (amount == 0) return;
        vm.deal(address(this), amount);
        (bool ok,) = address(treasury).call{value: amount}("");
        require(ok);
        fundedIn += amount;
    }

    function warp(uint256 h) external {
        h = bound(h, 0, 20);
        vm.warp(vm.getBlockTimestamp() + h * 1 hours);
    }

    function warpSeconds(uint256 s) external {
        s = bound(s, 0, 3600);
        vm.warp(vm.getBlockTimestamp() + s);
    }

    function fund(uint256 callerSeed) external {
        address caller = address(uint160(0xF000 + callerSeed % 5));
        uint256 balance = address(treasury).balance;
        uint256 now_ = vm.getBlockTimestamp();
        bool allowed = now_ >= treasury.nextRunAt() && balance > 0;
        vm.prank(caller);
        try treasury.fundNextRun() returns (uint256 amount) {
            require(allowed, "a run was funded too soon or from nothing");
            require(amount <= 0.01 ether, "over the cap");
            require(amount == (balance < 0.01 ether ? balance : 0.01 ether), "not min(balance, cap)");
            require(treasury.lastRunAt() == now_, "lastRunAt is not now");
            require(treasury.nextRunAt() == now_ + 12 hours * amount / 0.01 ether, "closing is not proportional");
            paidOut += amount;
            lastAmount = amount;
            runs++;
            if (amount == 0.01 ether) fullRuns++;
            if (amount < 1e13) dustRuns++;
        } catch {
            require(!allowed, "a due run was refused");
        }
    }
}

/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = true
contract TreasuryInvariantTest is Test {
    address constant SWARM = 0xd01122bBfFd00fc96252c8b29867a5359a3bca13;
    uint256 constant CAP = 0.01 ether;
    uint256 constant INTERVAL = 12 hours;
    HeartbeatTreasury treasury;
    TreasuryHandler handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        treasury = new HeartbeatTreasury();
        handler = new TreasuryHandler(treasury);
        targetContract(address(handler));
    }

    /// @notice ETH only ever leaves to the swarm's wallet, and only what the runs paid.
    function invariant_onlyRunsMoveEth() public view {
        assertEq(address(treasury).balance, handler.fundedIn() - handler.paidOut());
        assertEq(SWARM.balance, handler.paidOut());
    }

    /// @notice Over any stretch of time the treasury cannot pay more than 0.01 ETH per 12 hours plus
    /// one run, whoever calls it and however often. Each run closes it for `12 h x amount / cap`,
    /// rounded down to the second, so the bound carries one second's worth of cap per run
    /// (`cap / 43200`, about 2.3e11 wei) for that rounding.
    function invariant_heartbeatCapHolds() public view {
        uint256 elapsed = vm.getBlockTimestamp() - handler.start();
        uint256 runs = handler.runs();
        assertLe(
            handler.paidOut() * INTERVAL,
            (elapsed + runs) * CAP + CAP * INTERVAL,
            "more than the cap over the elapsed time"
        );
        // Full runs are the brief's heartbeats: never more than one per 12 hours plus the first.
        assertLe(handler.fullRuns(), elapsed / INTERVAL + 1, "more full runs than the interval allows");
    }

    /// @notice The closing time after a run is proportional to what it sent: 12 hours for a full run,
    /// never more, never before the run itself.
    function invariant_closingIsProportionalAndBounded() public view {
        uint256 last = treasury.lastRunAt();
        uint256 next = treasury.nextRunAt();
        if (last == 0) {
            assertEq(next, 0, "closed before any run");
            return;
        }
        assertGe(next, last, "closing before the run");
        assertLe(next, last + INTERVAL, "closed for more than 12 hours");
        assertEq(next, last + INTERVAL * handler.lastAmount() / CAP, "closing is not 12 h x amount / cap");
        if (handler.lastAmount() == CAP) assertEq(next, last + INTERVAL, "a full run must close for 12 hours");
    }
}
