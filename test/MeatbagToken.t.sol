// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MeatbagToken} from "../src/MeatbagToken.sol";

contract MeatbagTokenTest is Test {
    MeatbagToken token;

    function setUp() public {
        token = new MeatbagToken();
    }

    function test_mintsTheWholeSupplyToTheDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "MEATBAG");
        assertEq(token.symbol(), "MEAT");
    }

    function test_transferMovesExactlyWhatItWasAsked() public {
        address to = address(0xCAFE);
        assertTrue(token.transfer(to, 1_000 ether));
        assertEq(token.balanceOf(to), 1_000 ether);
        assertEq(token.balanceOf(address(this)), 10 ** 27 - 1_000 ether);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_hasNoMintOrOwner() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        assertEq(token.totalSupply(), 10 ** 27);
    }
}
