// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookTestBase} from "../HookTestBase.sol";
import {MeatbagHook} from "../../src/MeatbagHook.sol";
import {MeatbagToken} from "../../src/MeatbagToken.sol";
import {MeatbagGame} from "../../src/MeatbagGame.sol";
import {HeartbeatTreasury} from "../../src/HeartbeatTreasury.sol";

/// @notice Swaps the MEAT/ETH pool in random directions, sizes and modes, with and without a binding
/// price limit, with time passing through the decay window, donating ETH straight to the hook and
/// redeeming or redistributing on the way. Every fee the hook reports in `FeeTaken` is checked against
/// the ETH that actually moved, and the shares are summed as ghost totals.
contract HookHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

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
    uint256 public ghostDonated;
    uint256 public swaps;
    uint256 public failedSwaps;
    uint256 public partialFillsRefused;
    uint256 public limitedFills;
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
        _swap(true, -int256(ethIn), ethIn, false);
    }

    function buyExactOut(uint256 tokensOut) external {
        tokensOut = bound(tokensOut, 1, 10 ether);
        _swap(true, int256(tokensOut), 100 ether, false);
    }

    /// @dev Sells need ETH in the pool: the tokens-only pool (non-strict) only buys, which is the
    /// scenario it exists for (the claims path on a manager without ETH).
    function sellExactIn(uint256 tokensIn) external {
        if (!strict) return;
        tokensIn = bound(tokensIn, 1, 20 ether);
        _swap(false, -int256(tokensIn), 0, false);
    }

    function sellExactOut(uint256 ethOut) external {
        if (!strict) return;
        ethOut = bound(ethOut, 1, 10 ether);
        _swap(false, int256(ethOut), 0, false);
    }

    /// @dev The same four swaps with a price limit 0.2% away from the current price, so a large enough
    /// amount is cut short. Exact-input buys and exact-output sells cut short must be refused
    /// (`PartialFill`) without a trace; the other two pay on the ETH that settled.
    function limitedBuyExactIn(uint256 ethIn) external {
        ethIn = bound(ethIn, 1, 20 ether);
        _swap(true, -int256(ethIn), ethIn, true);
    }

    function limitedBuyExactOut(uint256 tokensOut) external {
        tokensOut = bound(tokensOut, 1, 10 ether);
        _swap(true, int256(tokensOut), 100 ether, true);
    }

    function limitedSellExactIn(uint256 tokensIn) external {
        if (!strict) return;
        tokensIn = bound(tokensIn, 1, 20 ether);
        _swap(false, -int256(tokensIn), 0, true);
    }

    function limitedSellExactOut(uint256 ethOut) external {
        if (!strict) return;
        ethOut = bound(ethOut, 1, 10 ether);
        _swap(false, int256(ethOut), 0, true);
    }

    /// @dev ETH sent straight to the hook is owed to nobody and must reach the pot, never stay behind.
    function donate(uint256 amount) external {
        amount = bound(amount, 0, 1 ether);
        if (amount == 0) return;
        vm.deal(address(this), amount);
        (bool ok,) = address(hook).call{value: amount}("");
        require(ok, "the hook refused ETH");
        hook.distribute();
        require(address(hook).balance == 0, "a donation stayed in the hook");
        ghostDonated += amount;
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

    function _priceLimit(bool buy) internal view returns (uint160) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint256 limit = buy ? uint256(sqrtPriceX96) * 999 / 1000 : uint256(sqrtPriceX96) * 1001 / 1000;
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        if (limit >= TickMath.MAX_SQRT_PRICE) limit = TickMath.MAX_SQRT_PRICE - 1;
        return uint160(limit);
    }

    function _swap(bool buy, int256 amountSpecified, uint256 ethValue, bool limited) internal {
        vm.deal(address(this), 1_000 ether);
        uint256 rate = buy ? hook.buyFeeBps() : hook.sellFeeBps();
        uint256 ethBefore = address(this).balance;
        bool exactIn = amountSpecified < 0;
        uint160 limit = limited ? _priceLimit(buy) : (buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        SwapParams memory params = SwapParams(buy, amountSpecified, limit);
        Snapshot memory s = _snapshot();
        vm.recordLogs();
        bool ok;
        try swapRouter.swap{value: ethValue}(key, params, PoolSwapTest.TestSettings(false, false), "") {
            ok = true;
        } catch (bytes memory reason) {
            if (limited && buy == exactIn && _contains(reason, MeatbagHook.PartialFill.selector)) {
                // Refused on purpose: nothing may have changed and nothing may have been charged.
                partialFillsRefused++;
                _assertUnchanged(s);
                require(address(this).balance == ethBefore, "a refused swap kept ETH");
            } else {
                require(!strict, "swap reverted on the ETH-seeded pool");
                failedSwaps++;
            }
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
        uint256 paid = buy ? ethBefore - address(this).balance : 0;
        uint256 received = buy ? 0 : address(this).balance - ethBefore;
        if (buy && exactIn) {
            // A swap that got here was filled in full: the price limit did not bind.
            require(paid == uint256(-amountSpecified), "exact-in buy did not spend exactly the input");
            require(fee == paid * rate / 10_000, "fee is not rate x ETH in");
            require(!seen || ethMoved == paid, "volume is not the ETH in");
        } else if (buy) {
            // paid = poolEth + fee, fee = poolEth * rate / (1e4 - rate): the rate on the whole spend,
            // the same base as an exact-input buy.
            uint256 poolEth = paid - fee;
            require(fee == poolEth * rate / (10_000 - rate), "fee is not the rate on the whole spend");
            require(!seen || ethMoved == paid, "volume is not the ETH spent");
            if (limited && paid > 0) limitedFills++;
        } else if (exactIn) {
            // received = poolEth - fee, fee = poolEth * 2% (fee may be zero on dust)
            uint256 poolEth = received + fee;
            require(fee == poolEth * 200 / 10_000, "fee is not 2% of the ETH the pool paid");
            require(!seen || ethMoved == poolEth, "volume is not the ETH the pool paid");
            if (limited && received > 0) limitedFills++;
        } else {
            require(received == uint256(amountSpecified), "exact-out sell did not deliver exactly");
            uint256 expected = received * 10_000 / 9_800 - received;
            require(fee == expected, "fee is not the grossed-up 2%");
            require(!seen || ethMoved == received + fee, "volume is not the gross ETH out");
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

    struct Snapshot {
        uint256 volume;
        uint256 owedPot;
        uint256 owedSwarm;
        uint256 owedTreasury;
        uint256 claims;
        uint256 pot;
        uint256 swarm;
        uint256 treasury;
        uint256 hookEth;
        uint256 tokens;
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.volume = hook.volume();
        s.owedPot = hook.owedPot();
        s.owedSwarm = hook.owedSwarm();
        s.owedTreasury = hook.owedTreasury();
        s.claims = hook.claims();
        s.pot = hook.game().pot();
        s.swarm = SWARM.balance;
        s.treasury = address(hook.treasury()).balance;
        s.hookEth = address(hook).balance;
        s.tokens = token.balanceOf(address(this));
    }

    function _assertUnchanged(Snapshot memory s) internal view {
        Snapshot memory n = _snapshot();
        require(keccak256(abi.encode(s)) == keccak256(abi.encode(n)), "a refused swap changed state");
    }

    function _contains(bytes memory hay, bytes4 needle) internal pure returns (bool) {
        if (hay.length < 4) return false;
        for (uint256 i = 0; i + 4 <= hay.length; i++) {
            if (bytes4(_slice(hay, i)) == needle) return true;
        }
        return false;
    }

    function _slice(bytes memory b, uint256 at) internal pure returns (bytes32 w) {
        assembly ("memory-safe") {
            w := mload(add(add(b, 0x20), at))
        }
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

    function _owed() internal view returns (uint256) {
        return hook.owedPot() + hook.owedSwarm() + hook.owedTreasury();
    }

    /// @notice Every wei of fee and donation is somewhere it should be: in the pot, with the swarm, in
    /// the treasury, or held as an ERC-6909 claim. Nothing leaks and nothing is counted twice. What is
    /// still owed is covered by claims; a donation may have prepaid part of it (never more than itself).
    function invariant_feesAreFullyAccountedFor() public view {
        uint256 held = game.pot() + SWARM.balance + address(treasury).balance + address(hook).balance + hook.claims();
        assertEq(held, handler.ghostFee() + handler.ghostDonated(), "ETH held != fees taken + donations");
        assertGe(hook.claims() + address(hook).balance, _owed(), "owed more than is held or claimed");
        assertLe(hook.claims() - _owed(), handler.ghostDonated(), "claims exceed owed by more than donations");
    }

    /// @notice The split is exact per recipient: 55% (plus the launch surplus) to the pot, 25% to the
    /// swarm's wallet, 20% to the treasury. Donations reach the pot and nobody else.
    function invariant_splitsAreExact() public view {
        assertEq(SWARM.balance + hook.owedSwarm(), handler.ghostSwarm(), "swarm share");
        assertEq(address(treasury).balance + hook.owedTreasury(), handler.ghostTreasury(), "treasury share");
        uint256 potSide = game.pot() + hook.owedPot();
        if (hook.claims() == 0) {
            assertEq(potSide, handler.ghostPot() + handler.ghostDonated(), "pot share + donations");
        } else {
            assertGe(potSide, handler.ghostPot(), "pot share");
            assertLe(potSide, handler.ghostPot() + handler.ghostDonated(), "pot share + donations");
        }
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
        assertEq(_owed(), 0, "fees left owed");
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
