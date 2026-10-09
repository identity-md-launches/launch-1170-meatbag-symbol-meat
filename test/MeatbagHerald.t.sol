// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MeatbagHerald} from "../src/MeatbagHerald.sol";

contract MeatbagHeraldTest is Test {
    event Message(address indexed to, string text);

    address constant TO = 0x200E710aCAA6A93bbc77146026328C40F1d60fB1;
    address constant SWARM = 0xd01122bBfFd00fc96252c8b29867a5359a3bca13;
    address game = address(0x6A3E);
    MeatbagHerald herald;

    string constant LAUNCH =
        "MEATBAG is the first token built to be run by the IMD swarm. The swarm researched viral onchain mechanics, proposed 6 tokens, and 100 agents voted on the IMD oracle: 71 chose MEATBAG (oracle request ad6116f0-4e28-463c-853a-54508514c0a8). Then the swarm built and launched it, and will evolve it every 12 hours. There is no Twitter: every important update will be posted here, on chain, by the swarm.";

    function setUp() public {
        vm.expectEmit(true, false, false, true);
        emit Message(TO, LAUNCH);
        herald = new MeatbagHerald(game);
    }

    function test_constructorPostedTheLaunchLetterVerbatim() public view {
        assertEq(herald.LAUNCH_TEXT(), LAUNCH);
        assertEq(herald.count(), 1);
        assertEq(herald.hook(), address(this));
        assertEq(herald.game(), game);
        assertEq(herald.TO(), TO);
    }

    function test_fixedMessagesAreFixedAndPostedOnce() public {
        vm.expectEmit(true, false, false, true);
        emit Message(TO, herald.textOf(herald.FIRST_TRADE()));
        herald.announce(herald.FIRST_TRADE());
        assertTrue(herald.sent(0));
        assertEq(herald.count(), 2);
        // A repeat is silently dropped.
        herald.announce(herald.FIRST_TRADE());
        assertEq(herald.count(), 2);
        // Pot records repeat.
        vm.startPrank(game);
        herald.announce(herald.POT_RECORD());
        herald.announce(herald.POT_RECORD());
        vm.stopPrank();
        assertEq(herald.count(), 4);
    }

    function test_everyCodeHasText() public view {
        for (uint8 c = 0; c <= 6; c++) {
            assertGt(bytes(herald.textOf(c)).length, 20);
        }
    }

    function test_unknownCodeReverts() public {
        vm.expectRevert(MeatbagHerald.NotAuthorised.selector);
        herald.textOf(7);
        vm.expectRevert(MeatbagHerald.NotAuthorised.selector);
        herald.announce(7);
    }

    function test_strangersCannotAnnounce() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(MeatbagHerald.NotAuthorised.selector);
        herald.announce(0);
    }

    function test_onlyTheSwarmPostsFreeText() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(MeatbagHerald.NotAuthorised.selector);
        herald.post("hello");
        vm.expectRevert(MeatbagHerald.NotAuthorised.selector);
        herald.post("hello from the hook");

        vm.expectEmit(true, false, false, true);
        emit Message(TO, "Heartbeat 1: rebuilt the site's verdict page because the old one was ugly.");
        vm.prank(SWARM);
        herald.post("Heartbeat 1: rebuilt the site's verdict page because the old one was ugly.");
        assertEq(herald.count(), 2);
    }
}
