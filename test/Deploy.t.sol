// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MeatbagHook} from "../src/MeatbagHook.sol";
import {MeatbagToken} from "../src/MeatbagToken.sol";

contract DeployTest is Test {
    function test_deployFunctionMinesAMatchingAddressAndWiresTheProject() public {
        PoolManager manager = new PoolManager(address(this));
        Deploy d = new Deploy();
        (MeatbagToken token, MeatbagHook hook) = d.deploy(IPoolManager(address(manager)), address(0xFAC), address(d));
        assertEq(token.balanceOf(address(d)), 10 ** 27);
        assertEq(HookFlags.flagsOf(address(hook)), d.FLAGS());
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.factory(), address(0xFAC));
        assertEq(hook.herald().game(), address(hook.game()));
        assertEq(hook.herald().hook(), address(hook));
    }
}
