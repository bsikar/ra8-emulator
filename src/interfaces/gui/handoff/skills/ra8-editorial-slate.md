# RA8 Editorial Slate Standards (`ra8-editorial-slate` Skill)

Apply every visual, architectural, and verification rule below to all changes inside `src/interfaces/gui/`.
Authoritative repo docs: `src/interfaces/gui/DESIGN.md` and root `AGENTS.md`.

---

## 1. Visual Design System: Editorial Slate

### Brand-Neutral Anonymous Chrome & Theme Discipline
- **Zero Branding:** Never display product names, application wordmarks, or logos in title bars, navigation headers, footers, HTML `<title>`, PWA manifest names, or empty states. Left-side window chrome contains only three `10px` `#242B35` window-control dots (`[data-testid="window-dot"]`) and plain utilitarian menu/view items.
- **Title Guard (`editorial-slate-audit.ts`):** Never let `document.title` or shell chrome match `/obsidian|ra8 workbench/i`. Default title is `'RA8 Emulator'`; when CPU0 ELF is loaded, set `'${fileName} — RA8 Emulator'`.
- **Dark-Only Monochromatic:** ~99% of every screen stays within the cool midnight-slate grayscale family (`#0B0E15` through `#F2F5FC`).
- **Zero Light Mode / Zero Neon Chrome:** Do NOT implement Light mode, System theme switching, or alternative UI chrome themes. Reject `#0A84FF`, `#30D158`, `#FFD60A`, `#FF453A`, `#BF5AF2` everywhere in `src/` (enforced by `tools/gate.mjs`).

### Exact CSS Variables (`src/interfaces/gui/src/styles/tokens.css`)
- Chrome & Surfaces:
  - `--es-chrome: #0b0e15`, `--es-chrome-deep: #0a0d12`, `--es-chrome-alpha: rgba(11, 14, 21, 0.9)`
  - `--es-canvas: #10131a` (root workspace surface)
  - `--es-container: #161920`, `--es-container-alpha: rgba(22, 25, 32, 0.7)` (hub cards & modals)
  - `--es-interactive: #1c2028`, `--es-interactive-high: #222630`, `--es-interactive-highest: #2a2f3a`
- Hairlines & Window Dots:
  - `--es-border: #21242b`, `--es-border-strong: #23262d`, `--es-divider: #1f2229`, `--es-rule-chrome: #171c22`, `--es-window-dot: #242b35`
- Text Hierarchy:
  - `--es-text-primary: #f2f5fc`
  - `--es-text-secondary: #dce0ec`
  - `--es-text-kicker: #989ca7`
  - `--es-text-muted: #80848d`
  - `--es-icon-footer: #a9adb8`
- Restrained Technical Micro-Signals (`5px–6px` dots or `1px–2px` indicator bars ONLY):
  - `--es-signal-cursor: #b8c4d9`
  - `--es-signal-fault: #d9776c` (`--es-signal-fault-bg: #2a1a1a`, `--es-signal-fault-text: #f2d6d3`)
  - `--es-signal-nominal: #7fa88d`
- Fonts & Layout Metrics:
  - `--font-sans: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif`
  - `--font-mono: 'JetBrains Mono', ui-monospace, 'SFMono-Regular', 'Cascadia Code', Consolas, monospace`
  - `--es-topbar-height: 48px`, `--es-statusbar-height: 32px`
  - `.mono` class in `base.css` enables `font-family: var(--font-mono); font-variant-numeric: tabular-nums;`. Always use `.mono` (NEVER `.font-mono`) on registers, hex dumps, disassembly, addresses, stack frames, UART logs, and metrics!

### Typography & Spatial Modes
- **Text Size Floor (`>= 12px`):** Every visible text node MUST have computed `fontSize >= 12px`, EXCEPT `.es-kicker`, `kbd` / `.es-kbd`, or explicit `[data-allow-11px]` micro-labels. `e2e/helpers/editorial-slate-audit.ts` fails CI if any other visible text is `< 12px`.
- **Spatial Mode 1 (Launch, Pickers & Modals):** Open `#10131A` canvas surrounding centered `#161920` panels (`border: 1px solid var(--es-border)`).
- **Spatial Mode 2 (Active IDE / Hardware / Rewind / Profiler / Console):** Edge-to-edge split panes separated strictly by `1px` `#21242B` hairlines (`SplitPaneComponent` — zero multi-card bento grids, zero nested subpanel boxes, zero wasted gutter margins).

### Code Buffer Syntax Highlighting Only (`src/interfaces/gui/src/styles/syntax.css`)
All chrome, dropdowns, call stacks, locals/registers, board views, forms, flamegraphs, and UART/telemetry consoles stay monochromatic Editorial Slate. Muted syntax tokens apply **only** inside `.es-code-buffer`:
- `--es-code-active-bg: #181c24`, `--es-code-gutter: #4e535e`
- `.tok-kw` (`--es-tok-kw: #95a6c8`)
- `.tok-type` (`--es-tok-type: #7faab8`)
- `.tok-fn` (`--es-tok-fn: #f2f5fc`)
- `.tok-num` (`--es-tok-num: #c4aa84`)
- `.tok-id` (`--es-tok-id: #c8cdd8`)
- `.tok-cmt` (`--es-tok-cmt: #5a606d`)

---

## 2. Engineering, Architecture & Gate Rules

- **Size Caps (`src/interfaces/gui/tools/gate.mjs`):** `<= 350` lines per file and `<= 80` lines per function across `src/`, `tests/`, `e2e/`, `client/src/`, `tools/`.
- **Strict TypeScript:** `strict: true`, `noUncheckedIndexedAccess: true`, `noUnusedLocals: true`, `noUnusedParameters: true`, **0 `: any` / `as any` / `<any>`**.
- **Honest Empty & Offline States:** 0 `catch {}` empty blocks (`tools/gate.mjs` forbids them), 0 `DEMO_*` placeholder rows or simulated telemetry in production components.
- **No Inline Tests & No Host OS Imports:** Tests live strictly under `src/interfaces/gui/tests/` mirroring `src/interfaces/gui/src/`, plus `client/test/` and `e2e/`. Never use Node/OS APIs or `@cImport` inside `src/app/`.
- **Zero Planning / Mockup Jargon in Code or Tests:** Never put milestone identifiers (`Milestone N`, `M0`–`M8`), mockup/screen codes (`Screen 01`–`12`, `04a`, `04b`–`04h`, `07`/`07b`), Stitch filenames (`stitch_*`), internal phase labels, or ticket IDs (`RA8EMU-*`) in source files, comments, UI labels, test descriptions, or spec filenames (`tools/gate.mjs` enforces this).
- **Inclusive Vocabulary (`tools/terms.zig` & `tools/gate.mjs`):**
  Always use **`Controller`**, **`Peripheral`**, **`Bus Initiator`**, **`CS`** (chip select), **`COPI`**, and **`CIPO`** in every code, CSS, test, and markdown file. Both `npm run gate` and `zig build gate -j1` fail immediately on any legacy banned word (even inside comments or URLs).
