// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
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
import {HookTestBase} from "../HookTestBase.sol";
import {MeatbagHook} from "../../src/MeatbagHook.sol";
import {MeatbagToken} from "../../src/MeatbagToken.sol";
import {MeatbagGame} from "../../src/MeatbagGame.sol";
import {HeartbeatTreasury} from "../../src/HeartbeatTreasury.sol";

/// @notice Swaps the MEAT/ETH pool in random directions, sizes and modes, with time passing through the
/// decay window, and redeems or redistributes on the way. Every fee the hook reports in `FeeTaken` is
/// checked against the ETH that actually moved, and the shares are summed as ghost totals.
contract HookHandler is Test {
    address constant SWARM = 0xd01122bBfFd00fc96252c8b29867a5359a3bca13;
    bytes32 constant FEE_TAKEN = keccak256("FeeTaken(bool,uint256,uint256,uint256,uint256,uint256)");

    IPoolManager public manager;
    MeatbagToken public token;
    MeatbagHook public hook;
    PoolSwapTest public swapRouter;
    PoolKey public key;
    bool public strict; // revert on a failed swap (ETH-seeded pool) or tolerate it (tokens-only pool)

    uint256 public ghostFee;
    uint256 public ghostPot;
    uint256 public ghostSwarm;
    uint256 public ghostTreasury;
    uint256 public ghostVolume;
    uint256 public swaps;
    uint256 public failedSwaps;
    uint256 public redeemed;

    receive() external payable {}

    constructor(
        IPoolManager manager_,
        MeatbagToken token_,
        MeatbagHook hook_,
        PoolSwapTest swapRouter_,
        PoolKey memory key_,
        bool strict_
    ) {
        manager = manager_;
        token = token_;
        hook = hook_;
        swapRouter = swapRouter_;
        key = key_;
        strict = strict_;
        token.approve(address(swapRouter), type(uint256).max);
    }

    function warpMinutes(uint256 m) external {
        m = bound(m, 0, 20);
        vm.warp(vm.getBlockTimestamp() + m * 1 minutes);
    }

    function buyExactIn(uint256 ethIn) external {
        ethIn = bound(ethIn, 1, 20 ether);
        _swap(true, -int256(ethIn), ethIn);
    }

    function buyExactOut(uint256 tokensOut) external {
        tokensOut = bound(tokensOut, 1, 10 ether);
        _swap(true, int256(tokensOut), 100 ether);
    }

    /// @dev Sells need ETH in the pool: the tokens-only pool (non-strict) only buys, which is the
    /// scenario it exists for (the claims path on a manager without ETH).
    function sellExactIn(uint256 tokensIn) external {
        if (!strict) return;
        tokensIn = bound(tokensIn, 1, 20 ether);
        _swap(false, -int256(tokensIn), 0);
    }

    function sellExactOut(uint256 ethOut) external {
        if (!strict) return;
        ethOut = bound(ethOut, 1, 10 ether);
        _swap(false, int256(ethOut), 0);
    }

    function redeemClaims() external {
        if (hook.claims() == 0) return;
        if (address(manager).balance < hook.claims()) return;
        uint256 before = hook.claims();
        hook.redeemClaims();
        redeemed += before;
    }

    function distribute() external {
        hook.distribute();
    }

    function _swap(bool buy, int256 amountSpecified, uint256 ethValue) internal {
        vm.deal(address(this), 1_000 ether);
        uint256 rate = buy ? hook.buyFeeBps() : hook.sellFeeBps();
        uint256 ethBefore = address(this).balance;
        SwapParams memory params = SwapParams(
            buy, amountSpecified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.recordLogs();
        bool ok;
        try swapRouter.swap{value: ethValue}(key, params, PoolSwapTest.TestSettings(false, false), "") {
            ok = true;
        } catch {
            require(!strict, "swap reverted on the ETH-seeded pool");
            failedSwaps++;
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!ok) return;
        swaps++;

        uint256 fee;
        uint256 ethMoved;
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != FEE_TAKEN) continue;
            require(!seen, "two FeeTaken events in one swap");
            seen = true;
            (uint256 moved, uint256 f, uint256 toPot, uint256 toSwarm, uint256 toTreasury) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            ethMoved = moved;
            fee = f;
            require(toPot + toSwarm + toTreasury == f, "split does not sum to the fee");
            uint256 base = moved * 200 / 10_000;
            if (base > f) base = f;
            require(toSwarm == base * 2500 / 10_000, "swarm share is not 25% of the 2% base");
            require(toTreasury == base * 2000 / 10_000, "treasury share is not 20% of the 2% base");
            ghostFee += f;
            ghostPot += toPot;
            ghostSwarm += toSwarm;
            ghostTreasury += toTreasury;
        }

        // The fee against the ETH the swapper actually paid or received.
        bool exactIn = amountSpecified < 0;
        uint256 paid = buy ? ethBefore - address(this).balance : 0;
        uint256 received = buy ? 0 : address(this).balance - ethBefore;
        if (buy && exactIn) {
            require(paid == uint256(-amountSpecified), "exact-in buy did not spend exactly the input");
            require(fee == paid * rate / 10_000, "fee is not rate x ETH in");
            require(!seen || ethMoved == paid, "volume is not the ETH in");
        } else if (buy) {
            // paid = poolEth + fee, fee = poolEth * rate / 1e4
            uint256 poolEth = paid - fee;
            require(fee == poolEth * rate / 10_000, "fee is not rate x ETH the pool took");
            require(!seen || ethMoved == poolEth, "volume is not the ETH the pool took");
        } else if (exactIn) {
            // received = poolEth - fee, fee = poolEth * 2% (fee may be zero on dust)
            uint256 poolEth = received + fee;
            require(fee == poolEth * 200 / 10_000, "fee is not 2% of the ETH the pool paid");
            require(!seen || ethMoved == poolEth, "volume is not the ETH the pool paid");
        } else {
            require(received == uint256(amountSpecified), "exact-out sell did not deliver exactly");
            uint256 expected = received * 10_000 / 9_800 - received;
            require(fee == expected, "fee is not the grossed-up 2%");
        }
        if (seen) ghostVolume += ethMoved;
        else ghostVolume += _dustVolume(buy, exactIn, amountSpecified, paid, received);
    }

    /// @dev A swap whose fee rounds to zero still records its ETH as volume.
    function _dustVolume(bool buy, bool exactIn, int256 amountSpecified, uint256 paid, uint256 received)
        internal
        pure
        returns (uint256)
    {
        if (buy && exactIn) return uint256(-amountSpecified);
        if (buy) return paid;
        if (exactIn) return received;
        return uint256(amountSpecified);
    }
}

abstract contract HookInvariantBase is HookTestBase {
    HookHandler handler;

    function _setUp(bool seedEth) internal {
        vm.warp(1_800_000_000);
        setUpPool(seedEth);
        handler = new HookHandler(manager, token, hook, swapRouter, key, seedEth);
        token.transfer(address(handler), 1_000_000 ether);
        targetContract(address(handler));
    }

    /// @notice Every fee the hook reported is somewhere it should be: in the pot, with the swarm, in the
    /// treasury, still owed, or held as a claim. Nothing leaks and nothing is counted twice.
    function invariant_feesAreFullyAccountedFor() public view {
        uint256 held = game.pot() + SWARM.balance + address(treasury).balance + hook.owedPot() + hook.owedSwarm()
            + hook.owedTreasury();
        assertEq(held, handler.ghostFee(), "fees held != fees taken");
        assertEq(hook.claims(), hook.owedPot() + hook.owedSwarm() + hook.owedTreasury(), "claims != owed");
    }

    /// @notice The split is exact per recipient: 55% (plus the launch surplus) to the pot, 25% to the
    /// swarm's wallet, 20% to the treasury.
    function invariant_splitsAreExact() public view {
        assertEq(game.pot() + hook.owedPot(), handler.ghostPot(), "pot share");
        assertEq(SWARM.balance + hook.owedSwarm(), handler.ghostSwarm(), "swarm share");
        assertEq(address(treasury).balance + hook.owedTreasury(), handler.ghostTreasury(), "treasury share");
    }

    /// @notice The hook never sits on ETH and its ERC-6909 claims match what the manager says it holds.
    function invariant_hookHoldsNothingItself() public view {
        assertEq(address(hook).balance, 0, "the hook kept ETH");
        assertEq(manager.balanceOf(address(hook), 0), hook.claims(), "claims out of sync with the manager");
        assertEq(token.balanceOf(address(hook)), 0, "the hook holds MEAT");
    }

    /// @notice The buy rate is always between 2% and 25%, sells are always 2%, and the rate never rises.
    function invariant_rateBounds() public view {
        uint256 r = hook.buyFeeBps();
        assertTrue(r >= 200 && r <= 2500, "buy rate out of range");
        assertEq(hook.sellFeeBps(), 200);
        if (vm.getBlockTimestamp() >= hook.launchedAt() + 30 minutes) assertEq(r, 200, "decay did not end at 30 min");
    }

    /// @notice Volume is the ETH each swap moved, and the herald's milestones agree with it.
    function invariant_volumeAndMilestones() public view {
        assertEq(hook.volume(), handler.ghostVolume(), "volume");
        assertEq(herald.sent(0), handler.swaps() > 0, "first trade");
        assertEq(herald.sent(1), hook.volume() >= 1 ether, "1 ETH milestone");
        assertEq(herald.sent(2), hook.volume() >= 10 ether, "10 ETH milestone");
        assertEq(herald.sent(3), hook.volume() >= 100 ether, "100 ETH milestone");
    }

    /// @notice The game's pot is backed by ETH, and the token supply never moves.
    function invariant_potIsBackedAndSupplyIsFixed() public view {
        assertEq(address(game).balance, game.pot() + game.totalClaimable());
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}

/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = true
contract HookInvariantEthSeededTest is HookInvariantBase {
    function setUp() public {
        _setUp(true);
    }

    /// @notice On a manager that holds ETH every fee is settled as ETH at once: no claims ever.
    function invariant_noClaimsOnAFundedManager() public view {
        assertEq(hook.claims(), 0, "a funded manager produced a claim");
        assertEq(hook.owedPot() + hook.owedSwarm() + hook.owedTreasury(), 0, "fees left owed");
    }
}

/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = true
contract HookInvariantTokensOnlyTest is HookInvariantBase {
    function setUp() public {
        _setUp(false);
    }
}
