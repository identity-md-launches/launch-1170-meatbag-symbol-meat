# MEATBAG interface design

## Overview

MEATBAG is a live Ethereum game and trading interface. The final design is dark, minimal and dryly
funny: an oversized condensed headline, a restrained coral accent, warm neutral text, and compact
monospaced onchain metadata. Humor stays in explanatory copy and empty states; transactions,
amounts, errors and approvals use plain, literal language.

The primary experience is the daily round. The seven hash-routed pages share the same masthead,
navigation, chain status, transaction notices and footer. There is no owner dashboard, social feed,
light theme or ornamental animation. Source: `web/src/App.tsx`, `web/src/style.css`.

## Colors

The hex tokens in `web/src/style.css:8` are the source of truth. All backgrounds are opaque;
there are no gradients or photo backgrounds behind text.

| Token | Value | Role |
| --- | --- | --- |
| `--bg` | `#141514` | Page, inputs, inset controls |
| `--surface` | `#1d1f1c` | Form panels, cards, dialogs |
| `--surface-raised` | `#252822` | Selected segments, notices, disabled actions |
| `--text` | `#f0efe5` | Headings and primary text |
| `--muted` | `#aaada2` | Descriptions, metadata, secondary labels |
| `--border` | `#41463c` | Decorative dividers and structural outlines |
| `--control-border` | `#747b6c` | Input, secondary-button and dialog boundaries |
| `--accent` | `#f47560` | Primary action fill and the MEATBAG brand emphasis |
| `--accent-hover` | `#ff947f` | Enabled primary action on pointer hover |
| `--on-accent` | `#171712` | Text on the primary fill |
| `--error` | `#ffbda9` | Inline errors and failure banners |
| `--success` | `#c3d69d` | Panel agreement and Ethereum indicator |
| `--focus` | `#e4edba` | Keyboard outline |

Coral also appears in the brand headline and decorative mark; this is a deliberate brand role,
not the sole indication of interactivity. Controls have button shapes, borders, underlines or a
stable navigation position. States always have text, not color alone.

Rendered sRGB pairs measured for this update: badge text/raised surface 12.939:1;
muted text/panel 7.279:1; treasury values and links/panel 14.374:1.
See `artifacts/pending-contrast.json` for computed foreground/background values and ratios. Forced-colors mode keeps system-color outlines.

## Typography

- **Display:** `--display`: locally bundled Barlow Condensed, weight 700, normal style; fallback
  Arial Narrow, Impact, sans-serif. The only font file is
  `web/src/assets/barlow-condensed-latin-700.woff2`; its OFL is retained in `web/public/fonts/OFL.txt`.
  `font-display: swap` is used. Browser `document.fonts.check` confirmed loading.
- **Body:** `--body`: Arial, Helvetica, sans-serif. Base 16px with unitless 1.55 line-height.
  Standard body/heading weights are 400/700; selected UI text uses 500/600 where the system face allows.
- **Metadata/numbers:** `--mono`: system monospace stack, SFMono-Regular, Consolas, Liberation Mono.
  Prices, countdowns, byte counters and amounts use tabular numbers.
- **Scale:** small text token 0.8125rem; body 1rem; lead 1.125rem; heading token 2rem.
  Functional captions are mostly 0.75rem (12px), with a few 11px mobile badges/status labels.
  Tiny 7–9px lettering is confined to the decorative, aria-hidden seal.
- **Headings:** page H1 uses `clamp(3.25rem, 6.7vw, 6.5rem)`; the daily hero uses
  `clamp(4rem, 8.4vw, 8.125rem)`, with narrower breakpoint overrides. Line-height is 0.89–0.96
  for short display text; H2/H3 use 1.1–1.3. Mobile page titles use
  `clamp(3rem, 12.2vw, 4.5rem)`. Large headings have small negative tracking.
- **Wrapping:** headings use balanced wrapping, paragraphs use pretty wrapping and a maximum 72ch
  measure. Letters use up to 65ch at 1.75 line-height (1.65 on narrow screens). Full entry/letter text
  and transaction identifiers wrap; none is line-clamped. Long hero words and the footer wordmark
  can wrap anywhere to support enlarged text. All mobile inputs are at least 16px.

## Layout

The shared content width is `min(calc(100% - 96px), 1320px)`. It becomes viewport minus 48px at
850px and viewport minus 32px at 570px. The spacing rhythm is 4/8/12/16/24/32/48/64px, declared as
`--space-*` properties and reflected in component spacing. The final source still uses explicit
spacing values in many selectors; there is no separate theme framework.

- **Above 1100px:** daily hero text + 250px decorative seal; round content + 370px entry panel,
  with 48px separation. Three round facts share a row. Jury uses two unequal columns; claims
  use equal columns; trade pairs a 500px form with an explanation; letters use a 280px sidebar.
- **At 1100px:** hide the ancillary launch label; reduce secondary-column widths/gaps and seal size.
- **At 850px:** daily entry panel, court, trade, claims and story become single-column. Letter
  sidebar moves above its feed. The page gutters shrink to 24px per side.
- **At 570px:** gutters are 16px; navigation becomes an explicit three-column/two-row grid,
  with the original six destinations visible and Pending actions in a full-width third row. Hide the decorative seal and header network word. The pot
  occupies a full fact row, with count/timer beneath. Form panels use 20px padding; steps and
  dialog actions stack; helper text wraps. Hero instructions use two short rows.

No fixed-height prose containers or sticky action bars obstruct content. The trade and message
areas use `minmax(0, 1fr)`; long identifiers wrap anywhere. Dialogs are limited to the viewport
with internal scrolling and overscroll containment. Tested widths: 1280, 768, 390 and 320 CSS
pixels on every page, with no horizontal overflow in the browser suite. At 390px, 200% root text enlargement also
reflowed after correcting the hero’s intrinsic minimum width.

## Elevation & depth

The system is intentionally flat. Tonal surfaces group forms and actions; 1px borders divide
rounds and letters. No card shadows are used. Native dialogs occupy the browser top layer with
an 80% black backdrop. The skip link uses z-index 100 and becomes visible on keyboard focus.

## Shapes

The shared radius token is 6px for fields, panels and buttons. The trade form and dialogs use
12px; their inset areas use 8px. Tags use 3px. The decorative humanity seal is an outlined oval,
rotated eight degrees, with an original inline SVG sketch. It is hidden from assistive technology
and on small screens. The M mark/favicon are small original SVGs, with no raster artwork.

## Components

All page patterns live in `web/src/App.tsx`; shared behavior is in `chain.ts`, `pending.ts`, `domain.ts` and
`wallet.ts`. This is an application, not an exported component library.

| Component / selector | Use and states |
| --- | --- |
| `External`, `Address` | Escaped React text, external-link marker and accessible new-tab note. Short addresses link to the full original address. |
| `SectionTitle` | Eyebrow, one H1, optional explanatory lead. |
| `Fact` / `.stats` | Label, prominent numeric value and subordinate note; tabular digits. |
| `Empty` | Explains what the area holds and how it becomes populated, without fabricating data. |
| `.primary`, `.full`, `.text-button` | Filled primary, full-width form action, low-emphasis refresh. Loading and unavailable states have literal labels and native disabled behavior. |
| `Modal` | Native `dialog`, labelled heading, Escape/close, trapped native focus and explicit focus restoration. A transaction in flight stays open. |
| `Today` / `.entry-panel` | Visible input label, printable-ASCII hint, UTF-8 byte output, field-associated error and focus-on-error; exact price reviewed again before send. |
| `Court`, `RoundCard` | Two-step IMD approval/judging, status-labelled history, filter, older-round pagination, details disclosure for full oracle IDs. Loaded history depth survives periodic refresh. |
| `Trade` / `.segmented` | Native buttons with `aria-pressed`; decimal amount, labelled tolerance select, quote and minimum output. Quotes clear when direction/amount/wallet changes. Exact approvals stay separate from swaps. |
| `Letters` / `.letter` | Full text, block and original transaction; honest scan/partial/complete states; load older messages in batches of 20. |
| `Claims` | Address-specific balance plus exhaustive sunset eligibility; disabled zero claims and explicit loading/error states. |
| `PendingActions` / `.pending-grid` | Four status sections use the existing panel surface: claims, first-verdict letter, heartbeat and housekeeping. Two equal `minmax(0, 1fr)` columns with a 24px gap; one column at 850px. Mobile panels use 24px block/16px inline padding at 570px. |
| `SimulatedButton` / `.simulated-action` | Native disabled transaction button until the selected sender's exact call succeeds at the snapshot block. Text states explain checking, missing wallet or decoded failure. Reuses review dialog; no new animation. Also used for the original Court and Claims operations. |
| `.pending-badge` | Compact raised-surface count beside the shared navigation label; 13px mono/tabular text, 24px visual minimum width, 6px radius. The entire navigation link is the touch target. An ellipsis means the required reads are incomplete. |
| `.claim-banner` | One-line Today claim notice at desktop widths, naturally wrapping on mobile; exact combined ETH amount and a 44px link to Pending actions. |
| `.pending-facts`, `.pending-prizes` | Definition lists for exact treasury amounts/Unix and UTC timestamps; semantic lists for claim addresses and per-round shares. Values wrap without clipping and use 13px mono text at 1.6 line height. Full swarm address remains visible. |
| `.banner`, `.transaction-notice` | Persistent actionable failures and polite transaction updates, with explorer links. |

All form controls use real labels. A 3px `--focus` outline with 4px offset is shared; buttons are
at least 44px high, including the quiet Refresh control. New standalone panel links and navigation targets also measure at least 44px in each dimension. Hover effects are gated to hover-capable
pointers. The only motion is a 120ms color/background/border transition and a 0.96 pressed-button
scale, both inside `prefers-reduced-motion: no-preference`. There are no page-load animations.

## Do’s and don’ts

- Start a new route with the shared masthead and `SectionTitle`; preserve one H1 and logical H2/H3 order.
- Use literal amounts and recipients in review dialogs. Keep the jokes out of errors and confirmations.
- Use the existing solid surface/text tokens, 6px control radius, focus ring, and 44px targets.
- Keep source-of-truth contract data separate from UI copy. Show unknown/loading/error values honestly.
- Preserve full letters, entry texts and oracle IDs. Wrap them instead of silently truncating them.
- Keep assets local and routes as hashes; retain Vite’s relative base. Do not introduce a social channel.
- Preserve reduced-motion and forced-colors behavior. Do not add motion or a second theme to fill a checklist.

The six-domain review and remaining verification limitations are recorded in `artifacts/validation.md`
and `web/VALIDATION.md`. No theme, token family or animation was added. IMD refused publication of this
update to the existing `meat` label; the finished local export is retained.
