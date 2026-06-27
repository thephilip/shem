# Design

Visual system for the Shem WebUI — a **scientific instrument** for time-travel debugging
of distributed, self-evolving agents. Dark, forensic, precise. Color is a coding system,
never decoration. See `PRODUCT.md` for the strategic register and principles.

## Theme

Dark, single theme. The surface is a near-black cool slate — a scope screen, not a SaaS
panel and not a warm-neutral page. Light is reserved for the data: bright ink, hairline
rules, and a restrained set of semantic colors that each *mean* something. No glassmorphism,
no gradients, no glow as decoration. Crisp small radii (2–4px); instruments are not pill-shaped.

## Color

OKLCH throughout. Strategy: **Restrained base + a semantic coding layer.** Neutrals carry
~95% of the surface; color appears only for event-type coding, trust/verify state, current
selection, and divergence.

### Neutrals (base)

```css
--bg:         oklch(0.16 0.012 240);  /* app background — near-black cool slate */
--surface:    oklch(0.20 0.013 240);  /* panels: session list, transport, lanes */
--surface-2:  oklch(0.245 0.015 240); /* raised: inputs, modal, hovered rows */
--border:     oklch(0.31 0.018 240);  /* hairline rules, 1px */
--border-strong: oklch(0.40 0.02 240);/* emphasized separators, focus ring base */

--ink:        oklch(0.95 0.008 240);  /* primary text — ~13.5:1 on --bg */
--ink-2:      oklch(0.76 0.012 240);  /* secondary text/labels — ~6:1 on --bg (AA body) */
--ink-3:      oklch(0.60 0.012 240);  /* de-emphasized: large/non-body only, ~3.3:1 */
```

Contrast floor: any text rendered on `--bg`/`--surface` uses `--ink` or `--ink-2` (both ≥
4.5:1). `--ink-3` is for ≥18px or non-essential meta only. Placeholder text uses `--ink-2`,
never `--ink-3`.

### Accent (action + selection only)

```css
--accent:     oklch(0.74 0.13 200);   /* instrument cyan — playhead, primary action, current selection */
--accent-dim: oklch(0.74 0.13 200 / 0.14); /* selection wash / focus halo */
```

Cyan is the single interactive accent: the scrub playhead, the selected event, primary
buttons, focus. It is never used to decorate static chrome.

### Semantic event coding (colorblind-safe)

Each event type pairs a hue with a **glyph and a text label** — color is never the only
channel (survives deuteranopia/protanopia). Hues chosen for lightness separation, not red/green
opposition.

```css
--ev-llm:    oklch(0.74 0.13 200);  /* llm_call — cyan (forkable)   glyph ◇ */
--ev-tool:   oklch(0.78 0.14 70);   /* tool_call — amber            glyph ▸ */
--ev-think:  oklch(0.70 0.12 290);  /* agent_thinking — violet       glyph ∿ */
--ev-grad:   oklch(0.75 0.13 160);  /* graduation/success — teal     glyph ✦ */
--ev-error:  oklch(0.68 0.17 25);   /* error — red (ALWAYS w/ ✕ + label) */
--ev-system: oklch(0.62 0.012 240); /* system/meta — neutral gray    glyph · */
```

### Trust / verify state (always paired with glyph + label)

```css
--ok:    oklch(0.75 0.13 160);  /* Verified · hash-chain intact   ✓ */
--warn:  oklch(0.78 0.14 70);   /* Legacy · unverifiable          ▲ */
--bad:   oklch(0.68 0.17 25);   /* Tampered at event #N           ✕ */
```

### Divergence (side-by-side replay)

Shared history renders at base ink. Diverged events get a `--accent-dim` background wash + a
"diverged" label/glyph — **not** a colored side-stripe border (banned). The original lane and
fork lane are distinguished by header label and a 1px full top accent rule, not by tinting the
whole column.

## Typography

Contrast-axis pairing: a humanist sans for UI chrome, monospace for all data (timestamps,
hashes, ids, payloads, counts). Mono numerics are the instrument voice.

```css
--font-ui:   'Inter', system-ui, -apple-system, sans-serif;
--font-mono: 'JetBrains Mono', 'Fira Code', ui-monospace, monospace;
```

Fixed rem scale (product register — not fluid), ratio ~1.15:

| token | px | use |
|---|---|---|
| `--t-micro` | 11 | dense meta, axis ticks |
| `--t-small` | 12 | labels, secondary data |
| `--t-base`  | 13 | event rows, body data |
| `--t-ui`    | 14 | UI text, buttons |
| `--t-h3`    | 16 | panel titles |
| `--t-h2`    | 18 | session header |
| `--t-h1`    | 22 | view title (sparingly) |

- `--font-mono` for: timestamps, event ids, session ids, sha256, counts, JSON payloads, the
  transport axis ticks, verify hashes.
- `--font-ui` for: nav, buttons, panel titles, labels, prose, empty/error copy.
- Line-height 1.45 for prose, 1.3 for dense data rows. Prose capped 65–75ch.

## Spacing & layout

4px base grid: `--s-1:4px … --s-2:8 --s-3:12 --s-4:16 --s-5:24 --s-6:32`. Hairline borders
1px `--border`. Radii: `--r-1:2px` (inputs, ticks), `--r-2:4px` (panels, buttons), no large pills.

Layout shell: left **session list** (fixed ~260px, `--surface`, collapses < 900px) · main
**timeline** column. Main column top-to-bottom: sticky **transport/scrub axis** → **event
spine** (single, or two aligned lanes after fork) → inline **event detail** on demand.
Flexbox for the shell (1D), grid only for the two-lane align. Responsive is structural
(collapse the session list, stack lanes) — never fluid type.

## Components

Every interactive element ships all states: default · hover · focus(-visible) · active ·
disabled · loading. Standardize once:

- **Buttons:** `--surface-2` bg, 1px `--border`; primary = `--accent` text on `--accent-dim`;
  focus = 2px `--accent` ring (`:focus-visible`), never removed.
- **Playhead:** 2px `--accent` vertical line + grabbable handle; keyboard-focusable, ←→ to step,
  Home/End to ends.
- **Event row:** dot (semantic hue + glyph) on the spine, mono timestamp, sans label; hover →
  `--surface-2`; selected → `--accent-dim` wash + 1px `--accent` left rule (1px is allowed; the
  ban is on >1px accent side-stripes); forkable (llm) rows reveal a Fork affordance on hover/focus.
- **Verify badge:** pill with glyph + label + mono event-count; one of `--ok`/`--warn`/`--bad`;
  click → which event broke. Always visible when a session is selected.
- **Loading:** skeleton spine rows (shimmer-free under reduced-motion), never a centered spinner.
- **Empty states teach:** "Select a session to scrub its timeline" / "No events yet — this
  session hasn't run."
- **Modals:** reserved (fork confirm only). Native `<dialog>`/fixed-position to escape clipping.

## Motion

State-conveying only; 150–250ms; ease-out (quart/expo), no bounce.

- **Scrub** is direct manipulation — the playhead tracks the pointer with no easing; the spine's
  as-of dimming transitions at 120ms.
- **Fork → side-by-side**: the single spine splits into two lanes via a 220ms ease-out width
  transition; reduced-motion → instant swap.
- **Replay**: a steady playhead advance at a readable cadence (≈1 event / 350ms, user-adjustable);
  reduced-motion → step-only, no auto-advance.
- **Divergence reveal**: diverged rows crossfade their wash in (160ms); reduced-motion → instant.
- Every animation has a `@media (prefers-reduced-motion: reduce)` path. No page-load
  choreography — the tool loads into the data.

## z-index scale

```css
--z-dropdown: 100; --z-sticky: 200; --z-modal-backdrop: 300;
--z-modal: 400; --z-toast: 500; --z-tooltip: 600;
```

## Anti-patterns (enforced)

No cream/warm-neutral bg · no purple-dev-tool accent · no gradient text · no glassmorphism ·
no decorative motion · no >1px colored side-stripe borders · no hero-metric template · no
identical-card grids · no color as the sole encoding channel.
