// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MeatbagHook} from "../src/MeatbagHook.sol";
import {MeatbagToken} from "../src/MeatbagToken.sol";
import {MeatbagGame} from "../src/MeatbagGame.sol";
import {MeatbagHerald} from "../src/MeatbagHerald.sol";
import {HeartbeatTreasury} from "../src/HeartbeatTreasury.sol";

/// @notice Shared scaffolding: a PoolManager, the token, a hook mined onto a flag-matching address, and
/// v4-core's test routers. The test contract plays the launch factory.
abstract contract HookTestBase is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;
    address constant SWARM = 0xd01122bBfFd00fc96252c8b29867a5359a3bca13;
    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;

    IPoolManager manager;
    MeatbagToken token;
    MeatbagHook hook;
    MeatbagGame game;
    MeatbagHerald herald;
    HeartbeatTreasury treasury;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    PoolKey key;

    receive() external payable {}

    function deployHook(IPoolManager manager_, address factory) internal returns (MeatbagHook) {
        bytes memory creationCode =
            abi.encodePacked(type(MeatbagHook).creationCode, abi.encode(address(manager_), factory));
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 500_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initCodeHash))))
            );
            if (!HookFlags.matches(predicted, FLAGS)) continue;
            bytes32 salt = bytes32(i);
            address at;
            assembly ("memory-safe") {
                at := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
            }
            require(at == predicted, "hook deployment reverted");
            return MeatbagHook(payable(at));
        }
        revert("no salt");
    }

    function setUpPool(bool seedEth) internal {
        manager = new PoolManager(address(this));
        token = new MeatbagToken();
        hook = deployHook(manager, address(this));
        game = hook.game();
        herald = hook.herald();
        treasury = hook.treasury();
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 12500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        vm.deal(address(this), 1_000_000 ether);
        token.approve(address(lpRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        if (seedEth) {
            lpRouter.modifyLiquidity{value: 2_000 ether}(
                key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, 1_000 ether, bytes32(0)), ""
            );
        } else {
            // Tokens only: a position entirely below the current price holds currency1 (MEAT) alone.
            lpRouter.modifyLiquidity(key, ModifyLiquidityParams(MIN_TICK, -60, 1_000 ether, bytes32(0)), "");
        }
    }

    function buyExactIn(uint256 ethIn) internal returns (BalanceDelta) {
        return swapRouter.swap{value: ethIn}(
            key,
            SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function buyExactOut(uint256 tokensOut, uint256 ethBudget) internal returns (BalanceDelta) {
        return swapRouter.swap{value: ethBudget}(
            key,
            SwapParams(true, int256(tokensOut), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function sellExactIn(uint256 tokensIn) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams(false, -int256(tokensIn), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function sellExactOut(uint256 ethOut) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams(false, int256(ethOut), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }
}
