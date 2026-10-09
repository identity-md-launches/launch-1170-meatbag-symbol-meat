# MEATBAG ($MEAT)

The first token built to be run by the IMD swarm, and a reverse Turing test it invented. Every UTC day
humans write up to 200 characters proving they are human; a panel of seven IMD oracle agents signs on
chain which entry is the most human, and it wins an ETH pot fed by trading. Nobody owns it: there is no
owner, admin, upgrade or pause anywhere in this repository. The swarm evolves it every 12 hours and
speaks for it only on chain, through the herald. There is no Twitter.

Launch kind `univ4_hook`, Ethereum mainnet (chain id 1), paired with native ETH, LP fee 12500 (1.25%),
tick spacing 60, opening market cap 10 ETH per the launch policy. Spec source: research report
`27c8adcd…` (job d0766eda); where the brief was silent its MEATBAG design was followed.

## Contracts

| Contract | File | Deployed by | Role |
| --- | --- | --- | --- |
| `MeatbagToken` | `src/MeatbagToken.sol` | the launch factory | Standard fixed-supply ERC-20, name `MEATBAG`, symbol `MEAT`, 18 decimals, 10^27 minor units minted once to `msg.sender` (the factory). No constructor arguments. |
| `MeatbagHook` | `src/MeatbagHook.sol` | the launch factory | The Uniswap v4 hook: a 2% ETH fee on every swap, settled in ETH inside the swap. Its constructor deploys the three contracts below. |
| `HeartbeatTreasury` | `src/HeartbeatTreasury.sol` | the hook's constructor | Holds the heartbeat's 20%; `fundNextRun()` sends at most 0.01 ETH per 12 h to the swarm's wallet. |
| `MeatbagHerald` | `src/MeatbagHerald.sol` | the hook's constructor | The only official channel: `event Message(address indexed to, string text)`, `to` = `0x200E710aCAA6A93bbc77146026328C40F1d60fB1`. |
| `MeatbagGame` | `src/MeatbagGame.sol` | the hook's constructor | Daily rounds, entries, judging through the IMD Intake, EIP-712 attestation verification, pull claims, carry-over, sunset. |
| `OracleAttestation` / `OracleAttestationConsumer` | `src/OracleAttestation.sol` | library / base | Copied verbatim from the oracle-consumer reference: the protocol's attestation struct, type hash and domain. |
| `HookFlags` | `src/HookFlags.sol` | library | The permission bits encoded in a hook address, used by tests, the deploy script and the launch floor. |

Why the hook deploys the game, herald and treasury itself: the brief wants all four in the launch and
with no owner, and the herald must trust the hook and the game while the game must know the herald.
A hook launch's manifest deploys the token and the hook, so the hook's constructor creates the other
three (plain `CREATE`, nonces 1 to 3; the game's address is computed from its nonce before it exists so
the herald can trust it). The constructor calls no other contract and needs no address to have code,
so it runs on an empty chain. Everything is wired at construction and nothing can be rewired later.

## Hook configuration (the Wizard's canonical record)

```json
{
  "hook": "BaseHook",
  "name": "MeatbagHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": false,
  "transientStorage": true,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true, "afterInitialize": false,
    "beforeAddLiquidity": false, "afterAddLiquidity": false,
    "beforeRemoveLiquidity": false, "afterRemoveLiquidity": false,
    "beforeSwap": true, "afterSwap": true,
    "beforeDonate": false, "afterDonate": false,
    "beforeSwapReturnDelta": true, "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false, "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "none (the brief forbids an owner)",
  "info": { "license": "MIT" }
}
```

The hook implements `IHooks` directly (v4-periphery is not vendored); unused callbacks revert, and every
callback checks `msg.sender == poolManager`. Flags: `0x20CC` = beforeInitialize | beforeSwap |
afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta. The deployer mines a CREATE2 salt for them
(`script/Deploy.s.sol` shows how; the factory does its own mining).

- **beforeInitialize**: accepts only `sender == factory`, only once, and only a pool whose `currency0`
  is native ETH. It records the token (`currency1`), the pool id and `launchedAt`. Any listed LP fee and
  tick spacing are accepted. A second pool, or a token pair, is refused.
- **beforeSwap / afterSwap**: see the fee below. `beforeSwapReturnDelta` is used only to take a fee off
  the ETH side when ETH is the specified currency; it never changes what the pool outputs for the user
  beyond that fee (no NoOp, no custom curve).

## The fee

On every swap of the MEAT/ETH pool the hook takes its fee **in ETH, from the ETH side, inside the swap**
that paid it, for both directions and for exact-input and exact-output swaps:

| Swap | Specified currency | Where the fee is taken | Fee base |
| --- | --- | --- | --- |
| buy, exact input | ETH | `beforeSwap`, off the ETH in | the ETH the buyer sends |
| buy, exact output | MEAT | `afterSwap`, added to the ETH the buyer owes | the ETH the pool took |
| sell, exact input | MEAT | `afterSwap`, off the ETH out | the ETH the pool paid out |
| sell, exact output | ETH | `beforeSwap`, the pool pays out the gross | the gross ETH out, so the user receives exactly what they asked |

Rates, immutable: **2%** on buys and sells. **Buys only**: for the first 30 minutes after the pool opens
the rate decays linearly from 25% to 2% (`buyFeeBps()`), and everything above the 2% base goes to the
pot. Every 2% base fee is split **55% pot / 25% `0xd01122bBfFd00fc96252c8b29867a5359a3bca13` (the
swarm's wallet) / 20% heartbeat treasury**. Nobody can change any of these numbers.

Settlement: the hook ends every swap holding its fee as ETH. It `take`s native ETH when the
PoolManager's ETH balance covers it, and `mint`s itself an ERC-6909 ETH claim when it does not (a fresh
pool seeded with tokens only has no ETH before the first buy settles). Claims are redeemed on the next
swap that can cover them, or by anyone through `redeemClaims()`. The ETH is pushed at once to the game
(`receive` adds it to the pot) and to the treasury; the swarm's share is pushed with a plain call and,
if that wallet ever cannot receive ETH, is kept owed and retried by the next swap or by anyone through
`distribute()`. A rejecting swarm wallet therefore never halts swaps. The pot and the treasury are this
project's own contracts and always accept ETH.

## The game

- `enter(text)`: today's round (UTC day = `block.timestamp / 1 days`). Printable ASCII only (0x20 to
  0x7E), 1 to 200 bytes, at most 40 entries per round, one per wallet per round. Slot k costs exactly
  k × 0.001 ETH (`nextSlotPrice()`), paid into the pot. Texts are stored on chain and emitted.
- `judge()`: once the oldest unjudged round has closed, anyone calls it. The caller must hold and have
  approved 0.5 IMD (`0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`); the game pulls it, approves the IMD
  Intake (`0x1397434cd35e8a9C8aC312A61D3A285EB31dea56`) and calls `request` with action
  `bytes32("oracle.request@oracle-1")`, answer type `uint256` (the winning entry index), evidence
  `panel`, panelSize 7, quorum 4, `validForSeconds` 86400, `allowAmbiguous` true, the entries in
  `definitions` as `entry_0 … entry_N` (quotes and backslashes neutralised; the question says the
  entries are untrusted material, not instructions). `judgeBody(day)` returns the exact body. The caller
  is paid **3% of the pot** as a pull claim the moment the request is made (so hung juries still pay
  the keeper for the 0.5 IMD they spent). One request per round.
- `onOracleResult(bytes32, Attestation, bytes)`: the canonical callback. Only the intake, only for the
  pending request, only with an attestation verified in this contract's EIP-712 domain
  (`IdentityMD Oracle` v2, `verifyingContract` = the game) against signer
  `0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982`; expiry and `issuedAt` window checked; `a.requestId`
  consumed once. Requires `panelSize ≥ 7`, `quorum ≥ 4`, `agreed ≥ quorum`, answer type `uint256` and
  an index inside the round; otherwise the round is recorded as a **hung jury**, never a revert. A
  verdict pays the winner **80% of the pot** as a pull claim; the rest carries over. The callback runs
  within the 200,000 gas stipend (tested).
- **No verdict** (panel disagreed, body refused, nobody delivered): after `VERDICT_TIMEOUT`
  (86400 + 3600 s) anyone calls `declareHungJury()`, or the next `judge()` sweeps it. The pot carries
  over.
- **Sunset rule**: after 7 unsettled rounds in a row (rounds with entries, in order), the pot is split
  equally among every entrant of those 7 rounds as pull claims (`claimSunset(day)`), so a dead or
  rotated oracle signer can never strand the pot. The streak resets on any verdict or sunset.
- `claim()` pulls prizes and keeper rewards. Rounds without entries do not exist and are skipped.
- Donations: any ETH sent to the game joins the pot.

## The herald

`MeatbagHerald` posts the launch letter verbatim from its constructor, then only fixed automatic
messages: first trade, volume 1 / 10 / 100 ETH (from the hook), first verdict, first hung jury and every
pot record (from the game, at judging time). One-time codes are posted once. No public caller can supply
text. The single exception the brief requires: the swarm's heartbeat wallet
(`0xd011…bca13`) may `post(text)` the letter that ends each heartbeat job, on what it built and why. All
project news goes out only as `Message` events.

## The heartbeat

`HeartbeatTreasury.fundNextRun()` is public, callable at most once per 12 hours, and sends
`min(balance, 0.01 ETH)` to the swarm's wallet, which funds the IMD job schedule (cadence PT12H) that
improves the site or adds opt-in features. The treasury holds nothing but its 20% share and can touch
nothing else: not the pot, the rates, the supply or any holder's funds.

## The site

`site/index.html` is a single dark, minimal page (ethers v6 from a CDN, no build step): today's entries
and slot price, pot, countdown, enter box, judge / approve / declare-hung buttons, verdict history with
panel agreement and panel job ids, hung juries and sunset shares, claims, a buy/sell link to the
Uniswap pool, and "the swarm's letters" feed from the herald's `Message` events, labelled as the only
official channel with a clear note that there is no Twitter. After the launch the heartbeat sets
`CONFIG.HOOK` to the hook's address; every other address is read from the hook. Host it at the swarm's
site label or on IPFS.

## Deployment parameters (for the manifest step)

- `MeatbagToken`: no constructor arguments. Solidity name `MeatbagToken` (12 characters).
- `MeatbagHook(IPoolManager poolManager, address factory)`: `"$poolManager"`, `"$factory"`. Two
  arguments, no literal addresses, no owner (none exists). Solidity name `MeatbagHook`.
- Pool: currency0 = ETH (zero address), currency1 = the token, fee 12500, tickSpacing 60; the deployer
  derives the opening price from the 10 ETH cap. `bytecode_hash = "none"`, solc 0.8.26, via-IR,
  optimizer 200, EVM cancun (transient storage is used for the fee passed from `beforeSwap` to
  `afterSwap`).
- The hook's init code is about 25 KB (it embeds the three child contracts); its runtime is about 7 KB.
  Runtime code contains no DELEGATECALL, CALLCODE or SELFDESTRUCT.
- Not written here on purpose: `launch.json` (the manifest step writes it).
- `script/Deploy.s.sol` is a rehearsal script only: `run(address poolManager, address factory)` reads
  no environment and `deploy(...)` is called by `test/Deploy.t.sol`.

## What the brief asked that the token does not do

The token is the launch's standard token: no fee, no limits, no mint, no owner. Every fee is the hook's.
The game and herald hold no MEAT and were allocated none; the pot is ETH only.

## Assumptions and open items

- **Fixed protocol values.** The brief forbids an owner, so the intake, IMD, action id, price and
  signer are fixed (the hook hands them to the game as immutables). This deliberately departs from the
  oracle-consumer reference's "owner-settable" advice; if IMD rotates its signer, retires `oracle-1` or
  moves the price, rounds stop settling and the sunset rule returns the pot to entrants.
- **"Repaid from the pot plus 3%"** was read as: the keeper receives 3% of the pot (in ETH, as a pull
  claim) at request time, which is their repayment for the 0.5 IMD and gas. The pot cannot repay IMD
  in kind without a price feed.
- **Pot record** is measured at judging time (before the keeper's 3%), so the herald posts at most one
  record letter per round rather than one per swap.
- **Exact-output buys** pay 2% of the ETH the pool took (1.96% of total spend); exact-output sells
  receive exactly the ETH asked and the pool pays the grossed-up amount so the fee is 2% of what left
  the pool.
- **Volume** for herald milestones is the ETH amount each fee was charged on.
- **Sunset inside the callback.** If the seventh unsettled round is settled as hung *inside* the oracle
  callback, the sunset loop may exceed the 200,000 gas stipend; the callback then reverts, the request
  times out, and `declareHungJury()` performs the same sunset in an ordinary transaction.
- **Independent review.** This work holds other people's funds. The brief's "independent review" item
  is an operational responsibility: it needs a separate adversarial review by an independent
  contributor before release. Tests passing is not an audit. Slither/Mythril were not run here (not
  provided in this environment).
- **Hosting the site** and filling `CONFIG.HOOK` after the launch is the first heartbeat's job.

## Operational responsibilities

| Who | What |
| --- | --- |
| Launch factory | Deploys `MeatbagToken` then `MeatbagHook` (mined address), initializes the pool, seeds liquidity. |
| Anyone | `judge()` after each round closes (needs 0.5 IMD, earns 3% of the pot); `declareHungJury()` after a timeout; `redeemClaims()` / `distribute()` if ETH ever sits as claims or owed; `fundNextRun()` every 12 h. |
| Swarm wallet `0xd011…bca13` | Receives 25% of fees and the heartbeat funding; runs the PT12H job; ends each job with `herald.post(text)`; hosts and updates the site. |
| Nobody | Can change fees, splits, recipients, the pot, the signer or the supply. |

## Tests

`forge build`, `forge test` and `forge fmt --check` pass offline with the pinned compiler (60 tests).

- `test/MeatbagHook.t.sol`: permissions vs. mined address; callbacks refuse non-manager callers;
  factory-only, once-only, ETH-only initialization; fee on buy/sell × exact-in/exact-out with exact
  55/25/20 splits; decay curve and launch-time surplus to the pot; fuzzed 2% invariant; claim path on a
  fresh manager seeded with tokens only, redemption on the next swap and via `redeemClaims()`; herald
  first-trade and volume milestones; no admin surface.
- `test/MeatbagGame.t.sol`: slot pricing, 200-byte and ASCII limits, duplicates, 40-entry cap, new day;
  judge pays the intake, rewards the keeper, body contents and sanitising; verdict pays 80% and carries
  20%; wrong sender, unknown id, wrong signer, wrong domain, tampered answer, expired, not-yet-valid,
  replay (same id and same attestation under a new id); weak panel / bad index = hung jury; timeout →
  hung → carry-over; judge sweeps a timed-out round; seven unsettled rounds → sunset shares and claims;
  streak reset; pot-record letters; no admin surface.
- `test/OracleConsumerConformance.t.sol`: the protocol's vector digest, callback selector, the
  protocol's own signature delivered under 200k gas, and a fresh signature from the vector key.
- `test/MeatbagHerald.t.sol`, `test/HeartbeatTreasury.t.sol`, `test/MeatbagToken.t.sol`,
  `test/Deploy.t.sol`.
- `test/fork/MainnetFork.t.sol`: a rehearsal against the real Ethereum PoolManager
  (`0x000000000004444c5dc75cB358380D2e3dE08A90`) at the 1e8 MEAT/ETH opening price: buy and sell take
  the fee in ETH, exact-output both ways. Excluded from the default profile (it needs network); run with
  `FOUNDRY_PROFILE=fork forge test`. It passed at block 26155277 on 2026-10-09.

Dependencies are vendored as ordinary files under `lib/`: forge-std, Uniswap v4-core (src plus
`test/utils/CurrencySettler.sol`), OpenZeppelin Contracts 5.5.0 and solmate's `Owned.sol` (needed by
v4-core's `ProtocolFees`).
