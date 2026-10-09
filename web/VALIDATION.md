# MEATBAG website validation (source-tree copy)

**Completion: implementation and local validation complete; assignment incomplete because IMD
publication was refused.** This is the worker’s report, not an independent audit or network certification.

## Scope, inputs and decisions

Built on accepted commit `daa8dcc2fe3dfdf83aba9b16d7d9a8214d259364`. Read the supplied project,
deployment and network records, the pinned Better Interface workflow, all six domains’ core
principles, and the documentation method. Used the supplied build-website reference; no separate
installable SKILL.md was exposed. Attribution/license record: `web/provenance/DESIGN-NOTICE.md`.

The six routes cover daily entries, judging/history/hung juries, trading, letters, claims and origin.
The existing scaffold’s responsibilities are now implemented in React/TypeScript with bundled ethers;
the old `site/index.html` forwards to the new export. No Solidity or existing build dependencies/config
were changed. Frontend dependencies and browser tools were installed under `/tmp`, outside the repository.
No backend, API key, remote runtime asset, alternate RPC, wallet service or token deployment was added.

Design assumptions: dark-only English interface; coral brand/primary action; local condensed display
face over a system sans body; original code-native SVG marks; no imagery or theme switch. A playful
voice is used for explanation, with literal wording for financial actions. The zero native currency
in the pool key is the verified ETH sentinel, not an invented recipient.

## Commands and actual outcomes

Build/test commands were executed on the exact `web/` source mirrored into `/tmp/meatbag-frontend`;
its Vite output `/tmp/dist` was copied byte-for-byte to root `dist/`. This avoids placing dependencies
in the restricted repository. Normal equivalent commands are documented in root README.

| Executed command / operation | Result |
| --- | --- |
| `forge build --skip test --skip script` | Exit 0; accepted Solidity compiled. Existing lint warnings remain; no code changed. |
| `tsx scripts/generate-abis.ts <repository-root> <repository-root>/web` | Exit 0. Token/hook canonical ABI hashes match deployment records. All five actual deployed runtimes match source with only compiler-designated immutables masked. Full runtime hashes recorded at block 26156153. |
| `cd /tmp/meatbag-frontend && npm run typecheck` | Exit 0; standalone final typecheck. |
| `cd /tmp/meatbag-frontend && npm run build` | Exit 0, includes `tsc --noEmit`. Production output has relative script, stylesheet, font and icon references. |
| `cd /tmp/meatbag-frontend && npm test` | Exit 0: 5 tests passed. ASCII/UTF-8 limit, numeric input boundaries, time/amount format, real oracle UUID encoding, chain/account guards. |
| `cd /tmp/meatbag-frontend && npm run test:fork -- /tmp/meatbag-fork-results.json` | Exit 0: 18 checks passed. Report: `artifacts/fork-results.json`. |
| `cd /tmp/meatbag-frontend && npm run test:browser -- /tmp/dist /tmp/meatbag-browser-artifacts` | Exit 0: 41 checks passed, no unexpected browser console/page errors; no axe WCAG A/AA violations across six pages. Report: `artifacts/browser-results.json`. |
| Browser MCP: local `http://127.0.0.1:4173/dist/` | Production export reached and visually inspected at desktop/mobile; local font loaded; actual mainnet data and full two-message feed verified. This URL is local preview, not hosted delivery. |
| `imd site publish dist --name meatbag` | Exit 1 after bundling 206350 bytes. HTTP 503 `member_sites_closed`: “this plane names no member sites”. No URL/CID/site ID. |

The managed browser preview descriptor described in the reference was absent. A local Python HTTP
preview was used for the MCP inspection. The automated script manages its own foreground HTTP
preview and Anvil lifecycle, and serves the export at `/preview/` to exercise relative paths.

## Every exposed write on a mainnet fork

Forked Ethereum at **26156153** using `https://ethereum-rpc.publicnode.com`. All target code and
pool liquidity came from the actual live deployment. Tests use the frontend’s own encoders.

| Write | Evidence |
| --- | --- |
| `enter(string)` | Exact current price and printable ASCII accepted; duplicate wallet, invalid Unicode and wrong value reverted. Also submitted through production UI. |
| IMD `approve(game, price)` | Exact `judgePrice()` allowance verified. Also completed through the production UI. |
| `judge()` | Real deployed Intake accepted request on the fork; caller received exactly 3% of the pot as a claim. Also completed through UI. |
| `declareHungJury()` | Early attempt rejected; after real timeout, status moved to hung and pot carried over. Also completed through UI/history filter. |
| `sunset()` | Rejected before due; seven-round state split into equal per-entry claims and reset streak. |
| `claim()` | Actual judge reward paid, plus a winner-credit fixture. Balance cleared and duplicate claim rejected. UI review/receipt and balance refresh also checked. |
| `claimSunset(day)` | Eligible entrant received the exact share; duplicate claim rejected. Exhaustive account reader found six older remaining shares. |
| MEAT `approve(Permit2, amount)` | Exact input allowance checked; production UI also completed this step. |
| Permit2 `approve(token, router, amount, expiry)` | Exact allowance and usable expiry verified; production UI also completed this step. |
| Universal Router `execute` buy | Real v4 quote, received at least minimum output; production UI submitted the same encoding. |
| Universal Router `execute` sell | Actual MEAT deduction and emitted sell hook fee verified; production UI executed all sell steps. |
| Router protections | Expired deadline and excessive minimum output reverted. |

**Fixture limits:** Anvil supplies its local test account. IMD funding is a reversible, test-only
balance-storage fixture. A winner credit is seeded into `claimable`/`totalClaimable`; no actual oracle
signature is available. The seventh weak-panel callback’s deferred-sunset state is represented by
round-status/cursor/streak storage fixtures; preceding entries and timed-out transitions use real
public methods. No token, hook, router or game was redeployed. These checks do not establish that a
future offchain panel will deliver a valid callback, nor that the oracle or public RPC stays available.
No transaction was sent to real mainnet.

## Better Interface coverage

| Domain | Coverage and evidence | Limitations / not applicable |
| --- | --- | --- |
| Accessibility — Checked | Native headings, links, forms, labels and dialog; byte/error associations; visible 3px focus; Escape and restored focus; selected-wallet/chain messages; primary keyboard focus and hash navigation inspected. Axe found zero violations on six pages. | No screen-reader session, physical touch device, full keyboard-only transaction marathon, or formal compliance certification. |
| Layout — Checked | All six routes at 1280/768/390/320px; no document overflow. Production screenshots inspected at desktop/mobile. 200% root text enlargement at 390px reflowed after repair. Full addresses/messages wrap. | Native browser zoom and RTL/localization not tested; the product currently supports English/dark only. |
| Writing — Checked | Button labels match writes; exact approval amounts; separate judging cost/reward; permanence, gas, deadlines and fee bases explained; invalid input and RPC failures explain recovery; “no Twitter” and all launch-vote figures present. | Actual future swarm letters are contract data and remain verbatim, including their stated cadence. No claim that the cadence is guaranteed. |
| Typography — Checked | Local WOFF2 loaded via browser font check; body/input sizes, line-height, measure, numeric stability and wrapping inspected. Readability pass enlarged small functional captions. | System sans/mono faces vary across operating systems. No cross-platform font-rendering comparison. Decorative seal text is intentionally small and aria-hidden. |
| Colors — Checked | Solid rendered page/panel/action pairs measured; text 15.851:1, muted page 8.027:1, muted panel 7.279:1, enabled primary label 6.474:1. Focus appearance inspected; source-token contrast pairs also calculated. | No light theme exists. `contrast.json` distinguishes computed-style confirmation from token-only pairs. Axe is not exhaustive contrast evidence. |
| UI — Checked | Empty, loading, invalid, disconnected, wrong-chain, approved, pending, confirmed and rejected states exercised. Quote direction/tolerance, actual swaps, judging, claims and RPC retry validated. Reduced-motion disables transitions; forced-colors retains visible controls. | No animation timeline slowdown: there are no staged/page animations, only 120ms interaction transitions. Real wallet-extension UIs were not exercised. |

## Findings, fixes and rechecks

Source locations below refer to the final formatted source. Each is one root cause, not repeated
per component. No unresolved local primary-interaction blocker remains in the tested scope.

| Severity / domain | Final source | Evidence and repair | Recheck |
| --- | --- | --- | --- |
| High / Accessibility | `web/src/App.tsx:94` (`Modal`) | Browser test showed wallet-picker Escape did not reliably return focus. Captured the triggering element before `showModal()` and explicitly restored it during cleanup; native modal focus containment retained. | EIP-6963 chooser/Escape/focus assertion passes. Visible focus screenshot saved. |
| Medium / Layout + Typography | `web/src/style.css:1707` | At 390px with 200% root text size, the hero’s intrinsic word width produced a 448px document. Set hero child `min-width:0` and permit long display words/wordmark to wrap. | 390px/200% test passes; all six routes still fit 320px. |
| Medium / Typography | `web/src/style.css:8`, `:563`, `:1376` | First mobile inspection showed overly small metadata and form hints. Raised functional captions mostly to 12px, wrapped the hero instruction rows and byte-counter row. | Final 390px and 320px screenshots/overflow checks pass. |
| Medium / Writing | `web/src/App.tsx:814` | Initial entry example used smart quotes despite ASCII-only rules. Replaced with straight-quote ASCII and kept explicit no-emoji/no-line-break hints. | Unit boundary cases and browser validation pass. |
| High / UI + Writing | `web/src/config.ts` (`panelRequestUrl`), `web/src/App.tsx:1259` | The initial guessed UI oracle route returned 404; a panel bytes32 is a padded UUID, not an oracle-request URL itself. Verified the public origin endpoint and `jobId` lookup with the real launch vote, implemented padded-UUID decoding and preserved raw IDs. | Five-case unit suite covers decoding; public endpoints returned the original attested vote with 71/100 agreement. |
| Medium / UI | `web/src/App.tsx:1296`, `:1333` | Source review found a disconnected sell quote could remain in “checking approval” and swallow the connect action. Restricted the early return to connected wallets, added an explicit checking state, and rechecked approval before send. | Dedicated disconnected-sell chooser regression plus full sell approval/swap UI sequence pass. |
| Medium / Layout + UI | `web/src/App.tsx:895` | Periodic refresh originally reset older-history pages to the newest ten. Retained loaded history depth while refreshing, so older rounds stay reachable. | Source reviewed; fork verifies older sunset discovery. A multi-page long-lived production history is not yet available on mainnet. |
| Medium / UI | `web/src/wallet.ts` (`sendWalletTransaction`) | Recheck the currently selected first account, not mere membership in the exposed account list, immediately before simulation/send; account-change events clear claims/reviews. | Guard unit test, wrong-chain switch and account-disconnect browser checks pass. |
| Medium / Packaging | `web/vite.config.ts`, `web/src/assets/` | Initial export duplicated the font via public/ and the asset graph and produced an oversized chunk warning. Moved the font to source assets, kept its license public, and split framework/Ethereum modules. | Final build has one WOFF2 and no oversized-chunk warning; all asset requests load. |

## Browser evidence

Automated fork screenshots:
- `artifacts/screenshots/desktop-fork.png`
- `artifacts/screenshots/mobile-fork.png`
- `artifacts/screenshots/letters-fork.png`
- `artifacts/screenshots/trade-fork.png`

Separately inspected actual-mainnet views:
- `artifacts/screenshots/today-desktop-live.png`
- `artifacts/screenshots/today-mobile-live.png`
- `artifacts/screenshots/letters-mobile-live.png`
- `artifacts/screenshots/keyboard-focus-live.png`
- `artifacts/screenshots/trade-quote-mobile-live.png`

The browser run deliberately returned HTTP 503 for RPC requests to verify error and retry behavior.
Those expected console resource failures are separated from unexpected errors in the JSON report.
The final live MCP inspection had no browser console errors. Browser screenshots and snapshots are
not screen-reader evidence or proof of a real mobile wallet extension.

## Packaging and publication

The root export is 585606 bytes before compression. The IMD CLI bundled it to 206350 bytes but refused
publication with `503 member_sites_closed`. No success, CID or hosted URL is claimed. This is an
external publishing-service limitation; all task-specific contract addresses and parameters were
provided and verified. The deliverable is retained so the accepted export can be published when
that service path becomes available.

No dependency directories, npm registry mirror, archive vendor, source map or Git submodule is
included. Existing ignore files were not changed. Source and export are kept complete rather than
trimming required runtime assets. A complete temporary Git snapshot (including existing dependency sources, the frontend, export and all then-present evidence) bundled to **2231101 bytes**, below **8388608 bytes**. The small size report was generated afterwards. This is a complete-content size check; the platform’s final history packaging may differ. Details are in `artifacts/size-report.json`.
