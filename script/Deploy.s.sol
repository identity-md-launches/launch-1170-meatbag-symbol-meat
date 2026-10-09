// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MeatbagHook} from "../src/MeatbagHook.sol";
import {MeatbagToken} from "../src/MeatbagToken.sol";

/// @title Local rehearsal deployment
/// @notice The launch factory deploys MEATBAG for real (token, then hook, then the pool). This script is
/// for rehearsals on a fork or a devnet: it deploys the token, mines a CREATE2 salt for the hook's
/// permission bits and deploys the hook, which deploys the treasury, herald and game itself. It reads
/// no environment variables: pass the chain's PoolManager and the factory address as arguments, e.g.
/// `forge script script/Deploy.s.sol --sig "run(address,address)" <poolManager> <factory>`.
contract Deploy is Script {
    uint160 public constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    function run(address poolManager, address factory) external returns (MeatbagToken token, MeatbagHook hook) {
        vm.startBroadcast();
        (token, hook) = deploy(IPoolManager(poolManager), factory, msg.sender);
        vm.stopBroadcast();
    }

    /// @notice Deploys the token and the hook from `deployer` (the CREATE2 sender whose address the salt
    /// is mined for). Tests call this directly.
    function deploy(IPoolManager poolManager, address factory, address deployer)
        public
        returns (MeatbagToken token, MeatbagHook hook)
    {
        token = new MeatbagToken();
        bytes memory creationCode = abi.encodePacked(type(MeatbagHook).creationCode, abi.encode(poolManager, factory));
        (bytes32 salt,) = mineSalt(deployer, creationCode);
        hook = new MeatbagHook{salt: salt}(poolManager, factory);
        require(HookFlags.matches(address(hook), FLAGS), "hook landed on the wrong address");
    }

    function mineSalt(address deployer, bytes memory creationCode) public pure returns (bytes32 salt, address at) {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 1_000_000; i++) {
            at = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initCodeHash))))
            );
            if (HookFlags.matches(at, FLAGS)) return (bytes32(i), at);
        }
        revert("no salt found");
    }
}
