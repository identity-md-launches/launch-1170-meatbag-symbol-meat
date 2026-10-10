# Pending actions — worker validation

Implementation and local validation are complete. Publication to the existing **meat** site was
refused by the IMD service. These are worker observations, not independent certification.

## Scope and source

Started from main at `85b2f03a7ca2351e34e5aeca1305a4c7ab5d7c3a` (confirmed by `git ls-remote`).
Preserved all six existing routes and added `#pending`, a shared count and a Today claim banner.
Read the provided project, deployment and network inputs, pinned Better Interface workflow,
all six domains' core principles and design-documentation method. Retained the existing attribution
and both licenses; the bundled license is byte-identical to the pinned input.

No Solidity, `src/`, `script/`, Solidity tests, protected configuration/dependencies, existing package
manifest/lockfile or ignore file changed. No mainnet transaction or contract deployment occurred.
The accepted ABIs/provenance were reused; all five deployed runtime hashes and wiring were checked
on the fork. No keys, private endpoints, backend, imagery, theme or animation was added.

Assumptions: a pending count includes each public operation, each address with positive prize credit,
and each connected-wallet sunset round. It counts waiting claims even when another wallet owns them
or simulation fails. It is unknown while required reads are incomplete. Sunset discovery requires
entry membership as well as the requested positive share and unclaimed flag, matching deployed code.

## Actual checks

Dependencies were installed in `/tmp/meat-pending/web`, an exact copy of `web/`, with caches in `/tmp`.
The source/production export remains complete in the repository. No dependency/cache directories or
npm archives are part of the submission. The unchanged lockfile installs the production toolchain;
Vitest 3.2.4 was installed with `--no-save --package-lock=false` in the temporary copy.

| Command (from temporary web/) | Result |
| --- | --- |
| `npm run typecheck` | Exit 0. Standalone TypeScript check including scripts/tests. |
| `npm run build` | Exit 0. Includes TypeScript; Vite exports relative local assets, no oversized-chunk warning. Root `dist/` copied byte-for-byte from the output. |
| `npm test` | Exit 0; 5 original Node tests passed. |
| `npx vitest run --config vitest.config.mjs` | Exit 0; 12 tests passed. Machine report: `artifacts/vitest-results.json`. |
| `FORK_RPC_URL=https://eth.drpc.org npm run test:fork -- /tmp/meat-pending/fork-final-results.json` | Exit 0; 20 checks passed at Ethereum block **26156153**. Report: `artifacts/fork-results.json`. |
| `FORK_RPC_URL=https://eth.drpc.org BROWSER_EXECUTABLE_PATH=/usr/bin/google-chrome npm run test:browser -- ../dist ../browser-final-reviewed` | Exit 0; 50 checks, zero unexpected console/page errors and zero axe violations across seven routes. Report: `artifacts/browser-results.json`. |
| Browser MCP, final export at local `/dist/` | Inspected live mainnet state at desktop width, navigation, screenshot, resources and console. No browser errors observed. The local preview is not a published URL. |
| `imd site publish dist --name meat` | Exit 1; HTTP 503 `member_sites_closed`: “this plane names no member sites”. See `artifacts/publish-result.json`. |

The managed preview descriptor mentioned in the reference was absent. The scripted browser owns
its preview and fork; MCP inspection used a local Python HTTP preview. Relative URLs were exercised
under `/preview/`, with locally bundled font and assets. Temporary previews are stopped after review.

### Eligibility and calls

Unit tests cover true/false letter states, cursor and round status; positive/zero prize credit;
sunset entry membership and double claims; treasury zero/dust/partial/cap/floor and exact cooldown
boundary; zero/early/elapsed hung deadlines; closed/open/pending/Court/sunset gating; count/empty
logic; deduplication of winner/keeper logs; all-history range subdivision, error propagation,
checkpoint reset on reorg, re-reading cached candidates' balances; exact targets/calldata/value;
and decoding custom game/treasury errors with arguments.

Every successful fork write performs frontend `eth_call` before sending its exact calldata. The
fork verifies the treasury's actual recipient balance change, zero/dust/partial/capped payment,
`lastRunAt` and `nextRunAt`, early cooldown reverts and equality at the deadline; first-verdict
herald event and cleared flag; real keeper credit discovered through Judging logs; claims clearing
and duplicate rejection; hung transitions; sunset settlement and shares. The original entry,
IMD approval/judge, buy, sell, Permit2 and swap guards also pass.

The production UI exercises wallet discovery, wrong-network switch, rejection/retry, exact review,
receipts and state refresh; disabled failed simulation with decoded `SendFailed()`; heartbeat and
letter actions; Court link/approval/judging; prize claim and Today banner; other-address balance with
Etherscan link and no Claim button; hung jury; sunset split, seven discovered shares, per-round claim,
badge decrement and the exact zero-count empty state. Wallet account changes clear stale context.
The test injects a 503 to check RPC failure and Retry recovery; its expected resource error is
separate from unexpected errors in the report.

## Better Interface review

| Domain | Coverage and evidence | Limits |
| --- | --- | --- |
| Accessibility — Checked | Native links/buttons, heading/region structure, explicit disabled states, described simulation messages, keyboard Enter/Escape/focus return, 44px new action/link/navigation targets, axe on all seven routes. Focus screenshot retained. | No screen-reader session, real wallet extension or physical touch-device test; axe is not comprehensive. |
| Layout — Checked | Existing gutters/panels retained. Two pending columns collapse at 850px; mobile navigation keeps six original destinations plus a full-width pending row. All seven pages fit 1280/768/390/320px. Pending and Today reflow with 200% root text size. | Text enlargement is not native browser zoom. English only; RTL and pseudo-localization not tested. |
| Writing — Checked | Literal calls, ETH amounts, recipients, gas, statuses and decoded failures. Full swarm recipient shown. Removed internal event-reader terminology from product copy. Exact requested empty state retained. | Future contract/letter data remains external content. State can change after simulation. |
| Typography — Checked | Existing local Barlow Condensed and system body/mono retained; numeric values use tabular digits, full wei precision formatted as ETH, no claim/address clipping. Screenshots inspected on desktop/mobile. | No cross-platform font-rendering or Safari/Firefox comparison. |
| Colors — Checked | Existing semantic tokens only. Rendered pairs: badge/raised 12.939:1; muted/panel 7.279:1; treasury values and links/panel 14.374:1. See `artifacts/pending-contrast.json`. Error token restored where the old panel rule overrode it. | No alternate theme exists; not added. Contrast is for identified rendered pairs, not every possible injected wallet UI. |
| UI — Checked | Loading, disconnected, eligible, failed simulation, confirmed, empty, wrong-network and read-failure states. Native review dialogs and existing flat surfaces reused. Reduced-motion and forced-colors checks pass. | No new motion exists; slowed animation timeline inspection is not applicable. |

### Findings, fixes and rechecks

| Severity / domain | Source | Evidence, repair, recheck |
| --- | --- | --- |
| High / UI | `web/src/App.tsx:204`, `web/src/chain.ts:459`, `web/src/wallet.ts:98` | Existing controls enabled from eligibility without an advance eth_call. Added exact sender/calldata/block-bound simulation before enable, decoded reverts, and a wallet eth_call immediately before send. Failed treasury receiver fixture disables the button with `SendFailed()`; recovery and transfer pass. |
| High / UI | `web/src/chain.ts:354` | Existing Claims only exposed the current wallet. Added complete Verdict/Judging candidate scan from deployment with bounded requests, deduplication, live balance reads and reorg reset. Unit reader cases and actual fork keeper/third-party UI balances pass. Failed scans do not become empty state. |
| Medium / UI | `web/src/App.tsx:452`, `web/src/pending.ts:1` | Account results and local countdown must not enable pending actions from stale/different state. Bind account reads to the snapshot block and selected address; use block.timestamp for eligibility. Boundary units, account-change browser checks and exact fork deadlines pass. |
| Medium / Accessibility | `web/src/style.css:1819` | Existing quiet Refresh target was 40px. Raised it to 44px; new panel links and nav are at least 44px, verified from rendered geometry including mobile. |
| Medium / Colors | `web/src/style.css:1835` | `.panel p` overrode the generic error color in new action feedback. Added scoped token-based error styling; failed-simulation browser state and recovery pass. |
| Low / Writing + Typography | `web/src/App.tsx:880`, `web/src/App.tsx:1070` | Removed event-reader implementation copy from the product and a punctuation-only line after the full mobile recipient. Kept the full address and exact call in the review. Final rendered copy reviewed. |
| Medium / Validation | `web/scripts/browser-check.ts:186`, `web/scripts/browser-check.ts:566`, `web/scripts/fork-check.ts:363` | A test credit lacked backing ETH, making the last synthetic sunset share insolvent. Funded the local fixture without changing the pot. Reset browser state across artificial fork rewinds; extended the refresh wait for archive latency and throttled fork requests. Corrected 20-check fork and 50-check browser runs pass. No production contract change. |

## Evidence and limitations

Representative images: `artifacts/pending-live-desktop.png`,
`artifacts/screenshots/pending-desktop-fork.png`, `pending-mobile-fork.png`,
`pending-focus-fork.png`, `pending-shares-mobile-fork.png`, `pending-other-claim-fork.png`,
plus original Today desktop/mobile regression screenshots. The first image is real mainnet reads;
images suffixed fork use explicitly local fixtures. Screenshots are not screen-reader evidence.

PublicNode could read current state but refused archived state at the pinned block. dRPC served the
fork, with intermittent rate limits and free-plan historical-filter errors on earlier attempts.
The complete successful reruns are recorded; these tests do not promise RPC availability.

Fixtures remain local: Anvil test accounts; IMD balance; a winner credit with matching ETH backing;
settled round/cursor/announcement flag for the first letter; seventh hung callback state for sunset;
treasury balance/cooldown boundaries; temporary reverting receiver bytecode to exercise SendFailed.
The real deployed game/herald/treasury execute every tested action. No real signed oracle callback
was produced, no mainnet funds moved, and no offchain job cadence was verified.

Packaging includes the source, existing lockfile and complete root static export. Old hashed app
assets are removed. No node_modules, cache, registry mirror, tarball, source map, new submodule or
ignore-file change is delivered. `artifacts/size-report.json` records the complete Git bundle size.
Publication remains incomplete because IMD rejected the requested existing label update; no new
CID or hosted version is claimed. The complete-history implementation bundle at `ab12df9ddaabce5f6a8611f01b565fc03cb9e38e`
measured **2652139 bytes**, below **8388608 bytes**. The final metadata commit is also size-checked.

The workspace's `.git/` is protected and was not changed. A separate checkout under `/tmp` began
from the same main commit and holds the implementation commit on `main`. `git push origin main`
failed with exit 128 because Git could not obtain a GitHub username/credential. No remote commit or
new hosted version is claimed. The task workspace retains the complete source, export and evidence
for the contributor submission upload. See `artifacts/git-result.json`.
