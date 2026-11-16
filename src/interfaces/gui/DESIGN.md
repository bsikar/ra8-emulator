---
name: Editorial Slate
colors:
  background: '#10131a'
  surface: '#10131a'
  surface-dim: '#0b0e15'
  surface-bright: '#222630'
  surface-container-lowest: '#0b0e15'
  surface-container-low: '#161920'
  surface-container: '#1c2028'
  surface-container-high: '#222630'
  surface-container-highest: '#2a2f3a'
  surface-variant: '#1c2028'
  on-background: '#f2f5fc'
  on-surface: '#f2f5fc'
  on-surface-variant: '#dce0ec'
  inverse-surface: '#f2f5fc'
  inverse-on-surface: '#10131a'
  outline: '#80848d'
  outline-variant: '#21242b'
  surface-tint: '#dce0ec'
  primary: '#dce0ec'
  on-primary: '#0b0e15'
  primary-container: '#222630'
  on-primary-container: '#f2f5fc'
  inverse-primary: '#989ca7'
  secondary: '#989ca7'
  on-secondary: '#0b0e15'
  secondary-container: '#1c2028'
  on-secondary-container: '#dce0ec'
  tertiary: '#80848d'
  on-tertiary: '#0b0e15'
  tertiary-container: '#161920'
  on-tertiary-container: '#dce0ec'
  error: '#d9776c'
  on-error: '#0b0e15'
  error-container: '#2a1a1a'
  on-error-container: '#f2d6d3'
  primary-fixed: '#f2f5fc'
  primary-fixed-dim: '#dce0ec'
  on-primary-fixed: '#0b0e15'
  on-primary-fixed-variant: '#1c2028'
  secondary-fixed: '#dce0ec'
  secondary-fixed-dim: '#989ca7'
  on-secondary-fixed: '#0b0e15'
  on-secondary-fixed-variant: '#1c2028'
  tertiary-fixed: '#dce0ec'
  tertiary-fixed-dim: '#80848d'
  on-tertiary-fixed: '#0b0e15'
  on-tertiary-fixed-variant: '#161920'
typography:
  headline-lg:
    fontFamily: Inter
    fontSize: 1.375rem
    fontWeight: '500'
    lineHeight: 1.875rem
    letterSpacing: -0.02em
  headline-md:
    fontFamily: Inter
    fontSize: 1.125rem
    fontWeight: '500'
    lineHeight: 1.625rem
    letterSpacing: -0.015em
  headline-sm:
    fontFamily: Inter
    fontSize: 0.9375rem
    fontWeight: '500'
    lineHeight: 1.375rem
    letterSpacing: -0.01em
  body-md:
    fontFamily: Inter
    fontSize: 0.8125rem
    fontWeight: '400'
    lineHeight: 1.375rem
  body-sm:
    fontFamily: Inter
    fontSize: 0.75rem
    fontWeight: '300'
    lineHeight: 1.125rem
  label-md:
    fontFamily: Inter
    fontSize: 0.75rem
    fontWeight: '500'
    lineHeight: 1rem
    letterSpacing: 0.02em
  label-sm:
    fontFamily: Inter
    fontSize: 0.6875rem
    fontWeight: '500'
    lineHeight: 0.875rem
    letterSpacing: 0.15em
  code-lg:
    fontFamily: JetBrains Mono
    fontSize: 0.8125rem
    fontWeight: '400'
    lineHeight: 1.5rem
  code-md:
    fontFamily: JetBrains Mono
    fontSize: 0.75rem
    fontWeight: '400'
    lineHeight: 1.375rem
  code-sm:
    fontFamily: JetBrains Mono
    fontSize: 0.75rem
    fontWeight: '400'
    lineHeight: 1.125rem
  keybinding:
    fontFamily: JetBrains Mono
    fontSize: 0.6875rem
    fontWeight: '400'
    lineHeight: 0.875rem
rounded:
  sm: 0.125rem
  DEFAULT: 0.25rem
  md: 0.375rem
  lg: 0.5rem
  xl: 0.75rem
  full: 9999px
spacing:
  gutter: 0.5rem
  gutter-compact: 0.25rem
  margin: 0.75rem
  space-xs: 0.25rem
  space-sm: 0.375rem
  space-md: 0.5rem
  space-lg: 0.75rem
  space-xl: 1rem
---

## Brand & Style

**Brand-Neutral Anonymous Chrome:** Never display any product name, brand title, application wordmark, or logo anywhere in window title bars, navigation headers, footers, or empty states. Left-side window chrome contains only the three muted window-control dots and plain utilitarian menu or view items.

This design system defines a quiet, monochromatic, cool midnight-slate desktop IDE and hardware workbench:
- **Editorial Calm & Restraint:** Avoid visual noise, heavy card grids, colored pill clutter, and saturated buttons. Let typography, whitespace, and subtle tonal steps carry hierarchy.
- **Monochromatic First:** Approximately 99% of every screen stays within a single cool blue-slate grayscale family (`#0B0E15` through `#F2F5FC`). Never use bright blue (`#0A84FF`), purple, neon green, or bright yellow fills for buttons, tabs, or badges.
- **Icon-Assisted Ghost Actions:** Prefer clean borderless icon + text links (`Material Symbols Outlined` at `15px–18px` in `#80848D`) over boxed rectangular buttons.

## Colors

### Foundational Cool Midnight-Slate Stack
- **Window Chrome (`#0B0E15` / `#0A0D12`):** Top title/menu strip and bottom status bar sit **darker** than the main canvas so structural chrome recedes cleanly into the frame (`90%` opacity with `backdrop-blur-xl`).
- **Primary Canvas (`#10131A`):** Root workspace surface, code/disassembly viewport, and open negative space.
- **Elevated Container (`#161920`):** Centered hub panels, modal sheets, and quiet recessed list wells (`70%` opacity with `backdrop-blur-md`).
- **Interactive Hover / Active Wash (`#1C2028` – `#222630`):** Subtle tonal lift for hovered rows, active tabs, and tonal commit actions.
- **Hairlines & Dividers:** Perimeter borders and underline rules use `#21242B` – `#23262D`; interior list and table separators use `#1F2229`; header/footer rules use `#171C22`. Window control dots sit muted at `#242B35`.

### Text & Icon Hierarchy
- **Primary Text (`#F2F5FC`):** Active menu item, item titles, current instruction/PC text, primary code tokens.
- **Secondary Action / Menu Text (`#DCE0EC`):** Unselected top-bar items, inline ghost action labels (`Open Directory`, `Clone Repository`, `+ New Workspace`), active field labels.
- **Section Kickers (`#989CA7`):** Small `11px` uppercase column/section headers (`WORKSPACE INDEX`, `MODIFIED`) with wide `0.15em` letter spacing.
- **Metadata, Paths & Muted Icons (`#80848D`):** Light-weight (`300`) inline descriptors separated by middle dots (`Zig · Cortex-M85/M33`), `JetBrains Mono` paths/addresses/timestamps, and inactive icons (`#A9ADB8` for active footer gear icon).

### Restrained Technical Micro-Signals
Do not introduce colorful dashboards. When technical debugger or hardware states strictly require semantic distinction, restrict color to tiny `5px–6px` indicator dots or `1px–2px` indicator strokes:
- **Execution Cursor / Active View Rule:** `#B8C4D9` (cool ice-steel `2px` underline or `2px` left tick on active/changed rows).
- **Breakpoint / Fault / NACK Dot:** `#D9776C` (muted ember coral, `6px` gutter dot or `12px` inline label text only — never bright `#FF453A` filled banners).
- **Connected / Nominal Dot:** `#7FA88D` (desaturated sage-slate `5px` dot beside plain `#80848D` status text — never bright green pills).

## Typography

Use **Inter** for UI chrome and **JetBrains Mono** (`tabular-nums`) for paths, addresses, hex dumps, registers, timestamps, and disassembly, paired with `15px–18px` `Material Symbols Outlined` glyphs.
- **Editorial Trio Pattern:**
  1. Kicker: `11px` uppercase `Inter`, weight `500`, tracking `0.15em`, `#989CA7`.
  2. Title + Inline Descriptor: `15px` `Inter` weight `500` (`#F2F5FC`) paired on the same baseline with `12px` `Inter` weight `300` (`#80848D`) metadata separated by `·`.
  3. Technical Subline: `12px` `JetBrains Mono` weight `400` (`#80848D`) directly below for paths, ELF targets, or memory locations.

## Layout & Spacing

- **Desktop Window Frame:**
  - **Top Bar (`48px` height):** Recessed `#0B0E15/90` bar with `1px` `#171C22` bottom border, `px-6`. Left: three `10px` `#242B35` circles + quiet `12px` text links (`File`, `Edit`, `View`, `Terminal`, `Help` or workspace view links). Right: sparse ghost transport controls only when inside a live debug session.
  - **Bottom Status Bar (`32px` height):** Recessed `#0B0E15/90` bar with `1px` `#171C22` top border, `px-6`. Left: quiet `12px` `JetBrains Mono` session metrics (`ws://`, virtual time `ns`, core summary) in `#80848D`. Right: minimal `#A9ADB8` `16px` settings icon.
- **Spatial Mode 1 — Launch & Setup Views:**
  - Keep `60%–75%` of the `#10131A` canvas open as breathing room around a single centered focal column (`max-w-3xl` to `max-w-4xl`), holding one `#161920` container (`rounded-xl`, `p-5`, `border border-[#21242B]`).
- **Spatial Mode 2 — Active Technical IDE Views (Debugger / Rewind / Hardware / Profiler):**
  - Edge-to-edge split panes separated strictly by `1px` `#21242B` hairlines on the `#10131A` canvas — **no** multi-card bento grids, **no** nested inner subpanel boxes inside cards, and **no** decorative padding gutters between panes.

## Elevation, Shapes & Components

- **Inputs & Command Bars:** Transparent background sitting directly on the canvas or container over a single `1px` `#21242B` bottom border (brightening to `#989CA7` on `:focus-within`), prefixed by an `18px` `#80848D` icon. Never wrap search/filter fields in heavy bordered boxes.
- **Ghost Action Links (Default):** Zero background, zero border (`15px` `#80848D` icon + `13px` `#DCE0EC` text -> `#F2F5FC` on hover).
- **Tonal Action Trigger (When a Single Commit Action Is Required):** `#1C2028` background, `1px` `#2A2F3A` hairline, `#F2F5FC` text, `4px` radius (`rounded`), `28px` height — never bright blue filled CTAs.
- **Segmented Mode Switches:** Text-only inline tabs or whisper-quiet `#161920` strips with a `1px` `#B8C4D9` bottom indicator on the active option.
- **Lists, Code Buffers & Tables:** Rows separated solely by `1px` `#1F2229` horizontal rules (`divide-y`), generous `16px` vertical padding (`py-4`) in index/setup lists and crisp `24px` tabular rows in code/disassembly/register views. Changed registers or diff rows are denoted by `#F2F5FC` text and a `2px` `#B8C4D9` left edge tick rather than colored pill badges or yellow row boxes.
