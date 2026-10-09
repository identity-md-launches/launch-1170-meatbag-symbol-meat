// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HeartbeatTreasury} from "../../src/HeartbeatTreasury.sol";

/// @notice Feeds the treasury and calls `fundNextRun` at random moments from random callers.
contract TreasuryHandler is Test {
    HeartbeatTreasury public treasury;
    uint256 public fundedIn;
    uint256 public paidOut;
    uint256 public runs;
    uint256 public start;

    constructor(HeartbeatTreasury t) {
        treasury = t;
        start = vm.getBlockTimestamp();
    }

    function feed(uint256 amount) external {
        amount = bound(amount, 0, 0.05 ether);
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

    function fund(uint256 callerSeed) external {
        address caller = address(uint160(0xF000 + callerSeed % 5));
        uint256 balance = address(treasury).balance;
        bool allowed = vm.getBlockTimestamp() >= treasury.nextRunAt() && balance > 0;
        vm.prank(caller);
        try treasury.fundNextRun() returns (uint256 amount) {
            require(allowed, "a run was funded too soon or from nothing");
            require(amount <= 0.01 ether, "over the cap");
            require(amount == (balance < 0.01 ether ? balance : 0.01 ether), "not min(balance, cap)");
            paidOut += amount;
            runs++;
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

    /// @notice Over any stretch of time the treasury cannot pay more than 0.01 ETH per 12 hours (plus
    /// the first run), whoever calls it and however often.
    function invariant_heartbeatCapHolds() public view {
        uint256 elapsed = vm.getBlockTimestamp() - handler.start();
        uint256 maxRuns = elapsed / 12 hours + 1;
        assertLe(handler.runs(), maxRuns, "more runs than the interval allows");
        assertLe(handler.paidOut(), maxRuns * 0.01 ether, "more than the cap over the elapsed time");
    }

    function invariant_nextRunIsNeverBeforeTheLast() public view {
        if (treasury.lastRunAt() != 0) assertEq(treasury.nextRunAt(), treasury.lastRunAt() + 12 hours);
    }
}
