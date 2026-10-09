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

    function test_sendsWhatItHasWhenBelowTheCap() public {
        vm.deal(address(treasury), 0.003 ether);
        assertEq(treasury.fundNextRun(), 0.003 ether);
        assertEq(address(treasury).balance, 0);
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
