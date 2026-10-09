// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {MeatbagGame} from "./MeatbagGame.sol";
import {MeatbagHerald} from "./MeatbagHerald.sol";
import {HeartbeatTreasury} from "./HeartbeatTreasury.sol";

/// @title The MEATBAG hook: a 2% ETH fee on every swap that feeds the pot
/// @notice Deployed by the launch factory beside the MEATBAG token. Its constructor also deploys the
/// heartbeat treasury, the herald and the game, so the whole project ships in the launch with no
/// owner and no wiring step. On every swap of its one pool (MEAT/ETH) it takes a hook fee in ETH from
/// the ETH side of the trade, inside the swap, for both directions and for exact-input and
/// exact-output swaps alike:
///
/// - 2% of the ETH moved, on buys and sells. Buys only: for the first 30 minutes after the pool opens
///   the rate decays linearly from 25% to 2%, and everything above 2% goes to the pot.
/// - Every 2% base fee is split 55% to the pot, 25% to the swarm's wallet and 20% to the heartbeat
///   treasury. Nothing here can change those numbers.
///
/// The fee is taken as native ETH when the PoolManager holds enough, and as an ERC-6909 ETH claim when
/// it does not (a fresh pool seeded with tokens only); claims are redeemed on the next swap that can
/// cover them, or by anyone through `redeemClaims()`.
contract MeatbagHook is IHooks, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    event FeeTaken(bool indexed buy, uint256 ethMoved, uint256 fee, uint256 toPot, uint256 toSwarm, uint256 toTreasury);
    event Distributed(uint256 toPot, uint256 toSwarm, uint256 toTreasury);
    event ClaimsRedeemed(uint256 amount);
    event PoolOpened(PoolId indexed poolId, address token, uint256 at);

    error NotPoolManager();
    error NotFactory();
    error NotGame();
    error HookNotImplemented();
    error AlreadyOpened();
    error NotEthPair();
    error NotThisPool();
    error NothingToRedeem();

    uint256 public constant BASE_FEE_BPS = 200;
    uint256 public constant START_FEE_BPS = 2500;
    uint256 public constant DECAY_DURATION = 30 minutes;
    uint256 public constant POT_BPS = 5500;
    uint256 public constant SWARM_BPS = 2500;
    uint256 public constant TREASURY_BPS = 2000;
    /// @notice The swarm's wallet: 25% of every base fee.
    address public constant SWARM = 0xd01122bBfFd00fc96252c8b29867a5359a3bca13;
    /// @notice The IMD Intake, IMD token and oracle signer on Ethereum mainnet, handed to the game.
    address public constant INTAKE = 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56;
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    uint8 internal constant _H_FIRST_TRADE = 0;
    uint8 internal constant _H_VOLUME_1_ETH = 1;
    uint8 internal constant _H_VOLUME_10_ETH = 2;
    uint8 internal constant _H_VOLUME_100_ETH = 3;

    IPoolManager public immutable poolManager;
    /// @notice The launch factory: the only sender that may open this hook's pool.
    address public immutable factory;
    HeartbeatTreasury public immutable treasury;
    MeatbagHerald public immutable herald;
    MeatbagGame public immutable game;

    /// @notice The MEAT token, learned from the pool key when the factory opens the pool.
    address public token;
    PoolId public poolId;
    /// @notice When the pool opened; the buy-fee decay runs from here.
    uint256 public launchedAt;
    /// @notice ETH volume: the ETH amount each swap's fee was charged on (a buyer's ETH in, or the ETH the pool paid out).
    uint256 public volume;
    /// @notice ETH owed to the pot, the swarm and the treasury but not yet held as ETH (claims pending).
    uint256 public owedPot;
    uint256 public owedSwarm;
    uint256 public owedTreasury;
    /// @notice ERC-6909 ETH claims this hook holds against the PoolManager.
    uint256 public claims;

    /// @dev Transient: the fee beforeSwap charged on the specified (ETH) side, read back in afterSwap.
    uint256 private constant FEE_SLOT = 0x6d656174626167686f6f6b2e666565;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, address factory_) {
        poolManager = poolManager_;
        factory = factory_;
        // Three CREATEs from this address: nonces 1, 2 and 3. The herald must trust the game before the
        // game exists, so the game's address is computed from the nonce it will be created at.
        treasury = new HeartbeatTreasury();
        address predictedGame = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(this), bytes1(0x03)))))
        );
        herald = new MeatbagHerald(predictedGame);
        game = new MeatbagGame(herald, INTAKE, IMD, ORACLE_SIGNER);
        assert(address(game) == predictedGame);
    }

    receive() external payable {}

    // ------------------------------------------------------------------ permissions

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------ fee views

    /// @notice The fee rate on buys now, in basis points: 25% decaying to 2% over the first 30 minutes.
    function buyFeeBps() public view returns (uint256) {
        if (launchedAt == 0) return START_FEE_BPS;
        // forge-lint: disable-next-line(block-timestamp)
        uint256 elapsed = block.timestamp - launchedAt;
        if (elapsed >= DECAY_DURATION) return BASE_FEE_BPS;
        return START_FEE_BPS - (START_FEE_BPS - BASE_FEE_BPS) * elapsed / DECAY_DURATION;
    }

    /// @notice The fee rate on sells: always 2%.
    function sellFeeBps() public pure returns (uint256) {
        return BASE_FEE_BPS;
    }

    // ------------------------------------------------------------------ callbacks

    /// @notice Only the launch factory may open a pool on this hook, once, and it must pair MEAT with ETH.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (sender != factory) revert NotFactory();
        if (launchedAt != 0) revert AlreadyOpened();
        if (!key.currency0.isAddressZero()) revert NotEthPair();
        token = Currency.unwrap(key.currency1);
        poolId = key.toId();
        launchedAt = block.timestamp;
        emit PoolOpened(poolId, token, block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @notice When ETH is the specified currency (exact-input buy, exact-output sell) the fee is taken
    /// here, from the specified amount, so the pool swaps the net amount.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert NotThisPool();
        bool buy = params.zeroForOne;
        bool exactIn = params.amountSpecified < 0;
        if (buy != exactIn) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 fee;
        if (exactIn) {
            // Buy, exact input: the user pays `amount` ETH; the fee comes off the top.
            fee = uint256(-params.amountSpecified) * buyFeeBps() / 10_000;
        } else {
            // Sell, exact output: the user wants exactly `amount` ETH; the pool pays out the gross so
            // that the fee is 2% of what left the pool.
            uint256 amount = uint256(params.amountSpecified);
            fee = amount * 10_000 / (10_000 - BASE_FEE_BPS) - amount;
        }
        assembly ("memory-safe") {
            tstore(FEE_SLOT, fee)
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    /// @notice When ETH is the unspecified currency (exact-output buy, exact-input sell) the fee is taken
    /// here from the ETH the pool moved. Either way the fee is then settled in ETH and split.
    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        bool buy = params.zeroForOne;
        bool exactIn = params.amountSpecified < 0;
        uint256 rate = buy ? buyFeeBps() : BASE_FEE_BPS;
        uint256 fee;
        uint256 ethMoved;
        int128 unspecifiedDelta;

        if (buy == exactIn) {
            assembly ("memory-safe") {
                fee := tload(FEE_SLOT)
                tstore(FEE_SLOT, 0)
            }
            ethMoved = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified) + fee;
            if (!exactIn) rate = BASE_FEE_BPS;
        } else {
            int128 amount0 = delta.amount0();
            uint256 poolEth = amount0 < 0 ? uint256(uint128(-amount0)) : uint256(uint128(amount0));
            fee = poolEth * rate / 10_000;
            ethMoved = poolEth;
            unspecifiedDelta = int128(uint128(fee));
        }

        _splitAndSettle(buy, ethMoved, fee);
        _recordVolume(ethMoved);
        return (IHooks.afterSwap.selector, unspecifiedDelta);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ------------------------------------------------------------------ settlement

    /// @notice Redeems the hook's ERC-6909 ETH claims for ETH and distributes it. Anyone may call it;
    /// it only works once the PoolManager holds enough ETH.
    function redeemClaims() external {
        if (claims == 0) revert NothingToRedeem();
        poolManager.unlock("");
        _distribute();
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        uint256 amount = claims;
        claims = 0;
        poolManager.burn(address(this), 0, amount);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), amount);
        emit ClaimsRedeemed(amount);
        return "";
    }

    /// @notice Pushes whatever ETH this hook holds to the pot, the swarm and the treasury in the order
    /// owed. Anyone may call it; a swarm wallet that could not receive ETH is retried here.
    function distribute() external {
        _distribute();
    }

    function _splitAndSettle(bool buy, uint256 ethMoved, uint256 fee) internal {
        if (fee == 0) return;
        uint256 base = ethMoved * BASE_FEE_BPS / 10_000;
        if (base > fee) base = fee;
        uint256 toSwarm = base * SWARM_BPS / 10_000;
        uint256 toTreasury = base * TREASURY_BPS / 10_000;
        uint256 toPot = fee - toSwarm - toTreasury;
        owedPot += toPot;
        owedSwarm += toSwarm;
        owedTreasury += toTreasury;
        emit FeeTaken(buy, ethMoved, fee, toPot, toSwarm, toTreasury);

        uint256 managerEth = address(poolManager).balance;
        if (claims > 0 && managerEth >= fee + claims) {
            uint256 redeemed = claims;
            claims = 0;
            poolManager.burn(address(this), 0, redeemed);
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), fee + redeemed);
            emit ClaimsRedeemed(redeemed);
        } else if (managerEth >= fee) {
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), fee);
        } else {
            poolManager.mint(address(this), 0, fee);
            claims += fee;
        }
        _distribute();
    }

    function _distribute() internal {
        uint256 balance = address(this).balance;
        if (balance == 0) return;
        uint256 toPot = owedPot < balance ? owedPot : balance;
        balance -= toPot;
        uint256 toTreasury = owedTreasury < balance ? owedTreasury : balance;
        balance -= toTreasury;
        uint256 toSwarm = owedSwarm < balance ? owedSwarm : balance;

        if (toPot > 0) {
            owedPot -= toPot;
            (bool ok,) = address(game).call{value: toPot}("");
            require(ok, "pot transfer failed");
        }
        if (toTreasury > 0) {
            owedTreasury -= toTreasury;
            (bool ok,) = address(treasury).call{value: toTreasury}("");
            require(ok, "treasury transfer failed");
        }
        if (toSwarm > 0) {
            owedSwarm -= toSwarm;
            (bool ok,) = SWARM.call{value: toSwarm}("");
            // A wallet that cannot take ETH right now keeps its share owed; `distribute()` retries.
            if (!ok) owedSwarm += toSwarm;
            else emit Distributed(toPot, toSwarm, toTreasury);
            return;
        }
        emit Distributed(toPot, 0, toTreasury);
    }

    function _recordVolume(uint256 ethMoved) internal {
        uint256 before = volume;
        uint256 after_ = before + ethMoved;
        volume = after_;
        if (before == 0) herald.announce(_H_FIRST_TRADE);
        if (before < 1 ether && after_ >= 1 ether) herald.announce(_H_VOLUME_1_ETH);
        if (before < 10 ether && after_ >= 10 ether) herald.announce(_H_VOLUME_10_ETH);
        if (before < 100 ether && after_ >= 100 ether) herald.announce(_H_VOLUME_100_ETH);
    }
}
