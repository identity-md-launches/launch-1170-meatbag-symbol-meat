// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HeartbeatTreasury} from "../src/HeartbeatTreasury.sol";

contract HeartbeatTreasuryTest is Test {
    address constant SWARM = 0xd01122bBfFd00fc96252c8b29867a5359a3bca13;
    HeartbeatTreasury treasury;

    function setUp() public {
        treasury = new HeartbeatTreasury();
        vm.warp(1_800_000_000);
    }

    function test_capsEachRunAtOneHundredthOfAnEther() public {
        vm.deal(address(treasury), 0.05 ether);
        uint256 before = SWARM.balance;
        uint256 sent = treasury.fundNextRun();
        assertEq(sent, 0.01 ether);
        assertEq(SWARM.balance - before, 0.01 ether);
        assertEq(address(treasury).balance, 0.04 ether);
        assertEq(treasury.lastRunAt(), block.timestamp);
    }

    function test_onlyOncePerTwelveHours() public {
        vm.deal(address(treasury), 1 ether);
        treasury.fundNextRun();
        vm.expectRevert(abi.encodeWithSelector(HeartbeatTreasury.TooSoon.selector, block.timestamp + 12 hours));
        treasury.fundNextRun();
        vm.warp(block.timestamp + 12 hours - 1);
        vm.expectRevert();
        treasury.fundNextRun();
        vm.warp(block.timestamp + 1);
        assertEq(treasury.fundNextRun(), 0.01 ether);
    }

    function test_sendsWhatItHasWhenBelowTheCapAndClosesForAProportionalTime() public {
        vm.deal(address(treasury), 0.003 ether);
        assertEq(treasury.fundNextRun(), 0.003 ether);
        assertEq(address(treasury).balance, 0);
        assertEq(treasury.nextRunAt(), block.timestamp + 12 hours * 3 / 10, "30% of a run closes 30% of 12 h");
        vm.deal(address(treasury), 0.007 ether);
        vm.expectRevert(abi.encodeWithSelector(HeartbeatTreasury.TooSoon.selector, treasury.nextRunAt()));
        treasury.fundNextRun();
        vm.warp(treasury.nextRunAt());
        assertEq(treasury.fundNextRun(), 0.007 ether);
        assertEq(treasury.nextRunAt(), block.timestamp + 12 hours * 7 / 10);
    }

    function test_aDustRunCannotUseUpTheHeartbeatSlot() public {
        vm.deal(address(treasury), 2e11);
        vm.prank(address(0xBAD));
        assertEq(treasury.fundNextRun(), 2e11);
        assertEq(treasury.nextRunAt(), block.timestamp, "dust closes the treasury for no time at all");

        // Fees arrive: the full run is available at once, and only then does the 12 h window start.
        vm.deal(address(treasury), 0.04 ether);
        uint256 before = SWARM.balance;
        assertEq(treasury.fundNextRun(), 0.01 ether);
        assertEq(SWARM.balance - before, 0.01 ether);
        assertEq(treasury.nextRunAt(), block.timestamp + 12 hours);
        vm.expectRevert(abi.encodeWithSelector(HeartbeatTreasury.TooSoon.selector, block.timestamp + 12 hours));
        treasury.fundNextRun();
    }

    function test_revertsWhenEmpty() public {
        vm.expectRevert(HeartbeatTreasury.NothingToSend.selector);
        treasury.fundNextRun();
    }

    function test_anyoneMayCallIt() public {
        vm.deal(address(treasury), 1 ether);
        vm.prank(address(0xBEEF));
        treasury.fundNextRun();
        assertEq(SWARM.balance, 0.01 ether);
    }

    function test_hasNoAdminSurface() public {
        (bool ok,) = address(treasury).call(abi.encodeWithSignature("withdraw(address,uint256)", address(this), 1));
        assertFalse(ok);
        (ok,) = address(treasury).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }
}
