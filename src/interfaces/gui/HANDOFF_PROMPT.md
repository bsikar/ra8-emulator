# RA8 Emulator — Angular PWA (`Editorial Slate`) Completion Handoff Prompt (`M4` – `M8`)

> **How to use this file:** Give this entire prompt (or tell your coding agent: *"Read `src/interfaces/gui/HANDOFF_PROMPT.md` and execute Milestones 4 through 8 sequentially, committing and pushing `bsikar/RA8EMU-1242-gui` after each milestone"*) to a coding-capable Gemini agent working locally inside `ra8-emulator` on branch `bsikar/RA8EMU-1242-gui`.

---

## Role, Objective & Non-Negotiable Constraints

You are the autonomous lead Angular 19 / TypeScript engineer finishing the **Editorial Slate Progressive Web App (`src/interfaces/gui/`)** and its bundled **`ra8-rpc-client` SDK (`src/interfaces/gui/client/`)** on branch **`bsikar/RA8EMU-1242-gui`** in repository **`ra8-emulator`**.

**Milestones `M0`–`M4` (`0c04398d4` + code-hygiene enforcement) are already implemented, tested, committed, and pushed.** Your mission is to execute **Milestones `M5`, `M6`, `M7`, and `M8` sequentially**.

### Hard Operational Boundaries
1. **No External Access Assumed:** Do **NOT** try to connect to YouTrack, Stitch, or any remote SSH machines. All YouTrack ticket requirements, design specs, Stitch reference screenshots, and skills live locally inside **`src/interfaces/gui/handoff/`** and **`src/interfaces/gui/DESIGN.md`**.
2. **Workspace Ownership Boundary (`AGENTS.md`):** Keep all edits inside **`src/interfaces/gui/`** (the Angular PWA, `client/` SDK, mirrored Vitest `tests/`, Playwright `e2e/`, and `tools/`). Do **NOT** edit Zig files under `src/chip/`, `src/board/`, `src/session/`, `src/interfaces/rpc/`, etc., unless strictly required by a blocking backend bug (and if so, pass full Zig tests too). Notice `HANDOFF_PROMPT.md` and `handoff/` are temporary reference files — do **NOT** delete them during M5–M8; the maintainer will clean them out after reviewing M5–M8.
3. **Commit & Push After EVERY Milestone:** Execute one milestone at a time (`M5`, then `M6`, then `M7`, then `M8`). Do **NOT** batch multiple milestones into one commit. After finishing a milestone and passing 100% of its gates (client SDK + static gate + strict TypeScript + `ng build` + Vitest + Playwright live-daemon E2E + Zig `fmt`/`gate`), **immediately `git commit` and fast-forward `git push origin bsikar/RA8EMU-1242-gui:bsikar/RA8EMU-1242-gui`** before starting the next milestone.
4. **Zero Slop / Honest Software:** Zero `DEMO_*` fake data arrays, zero empty `catch {}` blocks, zero `: any` / `as any` / `<any>`, zero `@Input()`/`@Output()`/`*ngIf`/`*ngFor`, zero Light mode or neon accents, zero banned terminology (`tools/terms.zig` scans all source AND `.md` files).
5. **Zero Milestone / Screen-Code Identifiers in Source & Tests (`tools/gate.mjs` Enforced):** Never include milestone tags (`Milestone N`, `M0`–`M8`), Stitch/screen/modal codes (`Screen 01`–`12`, `04a`–`04h`, `07`/`07b`, `stitch_*`), internal phase/layer labels (`Layer 1`/`2`, `Phase N`), or ticket IDs (`RA8EMU-*`) anywhere in `src/`, `client/`, `tests/`, `e2e/`, or `tools/` (filenames, comments, strings, or test names). Use clean product/domain identifiers (`e2e/workbench-debug.spec.ts`, `e2e/console-hardware.spec.ts`, etc.).

---

## Required Local Skills & Specifications (Read Before Coding)

Read these files first inside the repo:
1. **House Architecture & Repo Rules:** `AGENTS.md` (repository root)
2. **Design System:** `src/interfaces/gui/DESIGN.md` and **`src/interfaces/gui/handoff/skills/ra8-editorial-slate.md`**
3. **Angular 19 / SDK / Test Rules:** **`src/interfaces/gui/handoff/skills/angular-19-signals-and-testing.md`**
4. **Milestones M4–M8 Full Specs & YouTrack Criteria:** **`src/interfaces/gui/handoff/specs/milestones_m4_to_m8_youtrack.md`**
5. **Rewind DAG & Wire Architecture:** **`src/interfaces/gui/handoff/specs/rewind_architecture_spec.md`**
6. **Stitch Visual Mockups (`16` PNGs):** **`src/interfaces/gui/handoff/stitch/stitch_*.png`**

---

## Current Baseline Inventory (`0c04398d4` + Hygiene Enforcement on `bsikar/RA8EMU-1242-gui`)

### What Already Exists & Passes (`275+` GUI files clean)
- **`ra8-rpc-client` (`src/interfaces/gui/client/`)**: Complete binary WebSocket client covering session opcodes `0x0100..0x013F` and backend opcodes `0x0140..0x0193`, including chunked CRC32 ELF upload (`> 64 KiB`), 45-byte `DiffReply` decoder, 43-byte `NavQueryResult` (`setMarker`), `.board` parser/serializer + 4 Renesas board presets (`ek_ra8d2`, `ek_ra8p1`, `fpb_ra8e1`, `fpb_ra4t1`), ARM ELF32 header/DWARF/symbol inspector, and USTAR/gzip `.tar` validator with `ArtifactsAbort` (`0x0185`) spool release (`client/test/`).
- **Custom Board Composer, Settings Schemes, SplitPane & HiDPI (`M4`, `0c04398d4`)**: `features/workspace/board-composer-*`, multi-section `SettingsModalComponent` with code-buffer color schemes + probe rescan, proportional persisted `SplitPaneComponent`, `shared/utils/hidpi-canvas.ts`, and `View > Full Screen`.
- **Signal Stores (`src/interfaces/gui/src/app/core/`)**:
  - `rpc/rpc-connection.store.ts` (WebSocket attach, `observeOnly`, `capabilitiesSummary`, toast/error reporting)
  - `stores/execution.store.ts` (`run`, `pause`, `step`, `stepOver`, `stepOut`, `reset`, `advanceAsync`, `Topic.Session` external GDB/`ctl` auto-sync)
  - `stores/workspace.store.ts` (recent workspaces, saved hosts, `CAP_WORKSPACE` list/stat/read/write, `CAP_BUILD`, `CAP_PROJECT`, `CAP_TARGETS`)
  - `stores/remote-hosts.store.ts` & `remote-hosts.types.ts` (live RTT rescan, SSH tunnel command builder, TLS/Bearer/mTLS drawer state, `ra8.hostProfiles.v1`)
  - `stores/board.store.ts` & `board-storage.ts` (`FramebufferRenderer` canvas, LED decoding via `decodeLedEvent`, ELF upload + `getMap` + `document.title`, `.board` import/export, custom board storage `ra8.customBoards.v1`)
  - `stores/debug.store.ts` & `debug-points.store.ts` (dual-core regs, `disassemble`, `backtrace`, `selectFrame`, `locals`/`locals_at`, `source_line`, `read_memory`, `write_register`, `write_memory`, `setVariable`, `undoWrite`, `skipBkpt`)
  - `stores/rewind.store.ts` (`branches`, `switchBranch`, `deleteBranch`, `confirmFork`, `stepBack`, `play`, `seek`, `navQuery`, `setMarker`, `compareDiff`, `previewStagedArchive`, `exportArtifactBundle`, `importArtifactBundle`, `ra8.recentBundles.v1`)
  - `stores/hardware-hil.store.ts` (`getListParts`, `plug`, `unplug`, `formatFaultSpec`, `setFault`, `clearFault`, `getPeriph` + 64B `readMemory` fallback)
  - `stores/profile.store.ts` (`metrics`, `cpu0Stack`, `cpu1Stack`, `traceTimeline`, `flamegraph`, `rtosTasks`, `hostCpuHistory`, `hostRssHistory`, `pacingRatio`)
  - `stores/console.store.ts` (`2000`-line bounded UART/TX buffer, channel filter, `exportLogBlob`)
  - `search/search-everywhere.store.ts` + `double-shift.ts` (`Shift+Shift`)
  - `vim/vim.store.ts` + `vim-engine.ts` + `vim-motions.ts` + `vim-edits.ts` (Layer-1 Vim + `:ex`)
  - `extensions/extension.store.ts` + `worker-host.ts` (sandboxed Web Worker extension bridge)
- **Existing Routes (`M0`–`M3`)**:
  - `/launch` (Screen 01 Workspace Index + `>` Launch Command Mode)
  - `/connect` (Screen 02 Live Session Picker, RTT Rescan & SSH/Auth Drawers)
  - `/import` (Screen 03 Session Bundle Manifest Preview & Admission)
  - `/workspace/new` + modal (Screen 04 New Workspace & Screen 04a Board Details Modal)
  - `/open` (Screen 05 Remote `--workspace` Directory Browser, Non-ELF Error Banner & `> 64 KiB` Chunked ELF Loader)
  - Shell & Stub/Initial Workbench Routes: `/debug`, `/hardware`, `/rewind`, `/profile`, `/console` (implemented as clean initial Signal/OnPush routes waiting for your M4–M8 full Screen 07–12 builds).

### Existing Test & DOM Contracts You MUST NOT Break
Existing Playwright E2E tests (`e2e/`) assert these exact elements and test IDs:
- Shell: `[data-testid="window-dot"]` (count `3`), `[data-testid="shell-topbar"]`, `[data-testid="shell-statusbar"]`, `[data-testid="statusbar-connection-btn"]`, `[data-testid="connection-popover"]`, `[data-testid="popover-observe-toggle"]`, `[data-testid="statusbar-observe-pill"]` (`OBSERVE`), `[data-testid="statusbar-vim"]`, `[data-testid="settings-trigger"]` opening `role="dialog"` with `aria-label="Session settings"` containing `[data-testid="settings-vim-toggle"]` and `[data-testid="settings-open-extensions"]`, `[data-testid="command-palette"]`, `[data-testid="command-palette-input"]`.
- Navigation Links: `[data-testid="nav-debug"]`, `nav-hardware`, `nav-rewind`, `nav-profile`, `nav-console`.
- Required Headings Still Present on Workbench Routes:
  - `/debug`: text `'CORE REGISTERS'`, `[data-reg="pc"]`, `[data-testid="debug-disasm"]`, `[data-testid="debug-step-btn"]`, `[data-testid="debug-run-btn"]`, and `[data-testid="debug-observe-pill"]` when in Observe mode.
  - `/hardware`: text `'FITTED PARTS'`
  - `/rewind`: text `'EXECUTION BRANCHES'`
  - `/profile`: text `'METRICS & STACKS'`
  - `/console`: text `'UART SERIAL STREAM'`

---

## Sequential Execution Plan (`M5` -> `M6` -> `M7` -> `M8`)

### Milestone 4 — Completed (`0c04398d4`)
- Custom Board Composer (`features/workspace/`), multi-section Settings modal (`PreferencesStore`, color schemes, probe rescan), proportional persisted `SplitPaneComponent`, `shared/utils/hidpi-canvas.ts`, and `View > Full Screen` (`e2e/board-composer-settings.spec.ts`).

### Milestone 5 — Workbench Debug (`stitch_08_workbench_debug.png`)
- **Spec:** `handoff/specs/milestones_m4_to_m8_youtrack.md#milestone-5`
- **Stitch Reference:** `stitch_08_workbench_debug.png`
- **Deliverables:**
  1. Spatial Mode 2 hairline-split `/debug` workbench: `TARGETS & THREADS` + `CALL STACK` (`0x011D` Stack MSP/PSP bars + click frame -> `getLocalsAt` `0x012A`) + `BREAKPOINTS (+)` (`pending` deferred breakpoints, `R/W/RW` watchpoints).
  2. Code Buffer (`Source | Disasm | Mixed | Decomp`) reading source via `0x0142` (`CAP_WORKSPACE`), syntax tokens strictly inside `.es-code-buffer`, active PC line `#181C24` + `2px #B8C4D9` bar + `#D9776C` gutter dot, `Follow PC`, hex/symbol jump + `+ Break`, `Split CPU0 | CPU1`, `Skip BKPT` (`0x0137`), and Vim buffer navigation (`j/k/gg/G///n/N/Ctrl+u/d/m/'`).
  3. `LOCALS & WATCH` (writable DWARF local/watch inline editing via `0x013D` `SetVar` + immediate re-read, read-only badge on optimized variables, `Undo Write` `0x013E`) + `Registers (Δ) | Memory | Peripherals` (`GPR·MVE·Sys` delta ticks & inline edit `0x0106`, 256B paged Hex+ASCII `Memory` bound to `debug.activeCore()` with `MRAM/SRAM/SP/PC` jumps & inline poke `0x0108`).
  4. Switchable `Board PREVIEW` + `SERIAL` right pane (`Board | Debugger | Side-by-Side Split` persisted).
  5. Mirrored Vitest specs + `e2e/workbench-debug.spec.ts` (live `blink.elf` + DWARF `uart_irq_echo.elf`).
- **Commit Subject:** `RA8EMU-1337: implement Workbench Debug, DWARF locals editing, memory hex, and Vim code navigation` -> **run full gates & push**.

### Milestone 6 — Device Monitor (`/console`) & Board, LCD Scrubber & HIL (`/hardware`)
- **Spec:** `handoff/specs/milestones_m4_to_m8_youtrack.md#milestone-6`
- **Stitch References:** `stitch_09_workbench_monitor.png`, `stitch_10_workbench_hardware.png`
- **Deliverables:**
  1. Console (`/console`): `All | UART | SWO | RTT` + SCI `CH0..CH9` picker, `ASCII | Hex`, `Elapsed | Virtual ns`, `>= 2,000`-line scrollback with wheel-up autoscroll lock (never in `ngAfterViewChecked`!), `Copy`, `Save Log`, `Clear`, interactive TX bar (`ConsoleInput` `0x011A`), `ELF SYMBOL DECODER`, `WATCH TRIGGERS`, `Reset Image` (`0x013F`).
  2. Hardware (`/hardware`): HiDPI aspect-locked `FramebufferRenderer` `<canvas>` (`Tap | Swipe | Longpress` with `atNs = execution.virtualTimeNs()`, crosshair, `Save PNG`), Frame History Scrubber + adaptive `0x010D` `subscribe` throttling (`1x`, `100x`, `max`, `0.1x` every-frame capture, skipped frame counter), clean headless state, `OV5640 Camera`, LEDs, Switches, `RTC`, `HIL COMPONENTS` (`plug`/`unplug` + `MODEL@ENDPOINT=RULE` Fault Injector `setFault`/`clearFault`), live hardware events, and `MMIO PERIPHERALS` (`getPeriph` JSON + 64B `readMemory` fallback).
  3. Mirrored Vitest specs (including scrubber ring & rate throttling) + `e2e/console-hardware.spec.ts`.
- **Commit Subject:** `RA8EMU-1338: implement Console Monitor and Hardware Inspector, LCD scrubber, and HIL faults` -> **run full gates & push**.

### Milestone 7 — Deterministic Time-Travel Rewind (`stitch_11_workbench_rewind.png`)
- **Spec:** `handoff/specs/milestones_m4_to_m8_youtrack.md#milestone-7` and `handoff/specs/rewind_architecture_spec.md`
- **Stitch Reference:** `stitch_11_workbench_rewind.png`
- **Deliverables:**
  1. Rewind (`/rewind`): Transport & seek strip (`stepBack` `0x012D`, `play` `0x0138`, valid `seekTarget` `0x012C`, `Prev/Next ISR & RTOS` `0x0139`, `+ Bookmark` `0x013A`, pending fork confirmation `0x0133`).
  2. Rooted single-parent CoW `BRANCH TREE` (`switchBranch` `0x0131`, `Prune` `0x0132`), `frameStatus` (`0x013B`), Snapshot/Restore controls (`0x0118`/`0x0119`), Interactive Center-Spine (`±Y`) + `Waterfall` (`+Y`) SVG/Canvas timeline (`shared/utils/rewind-layout.ts`), and 3-column `STATE DIFF` (`diff.regs`, `diff.pages`, `diff.periphs` with `Swap A↔B` & category filters).
  3. Mirrored Vitest specs + live `--history` E2E `e2e/rewind-history.spec.ts` (`RA8EMU-1201`).
- **Commit Subject:** `RA8EMU-1339: implement Rewind branch DAG, seek navigation, and state diff` -> **run full gates & push**.

### Milestone 8 — Execution Profiler, Flamegraph, Stack Watermarks & Soak Benchmark
- **Spec:** `handoff/specs/milestones_m4_to_m8_youtrack.md#milestone-8`
- **Stitch Reference:** `stitch_12_workbench_profile.png`
- **Deliverables:**
  1. Profiler (`/profile`): Pure TypeScript bounded ring-buffer `TimelineModel` (`features/profile/timeline-model.ts`) with mirrored Vitest unit tests (nested ISRs, idle gaps, utilization %, cursor zoom, clamped pan, brushed `[A, B]`, hit-testing) rendered on a HiDPI Editorial Slate `<canvas>`.
  2. `CALL STACK FLAMEGRAPH` (`Flamegraph | Icicle`, zoom, search) + `TOP SELF-CYCLE HOTSPOTS` table (`Export .folded` `0x0121`) + right sidebar (`STACK WATERMARKS` `0x011D` with `Near PSPLIM` warning, `GUEST COMPUTE & MEMORY` `0x012E`, `HOST RUNTIME METRICS` with `< 0.35x` pacing & `cpuPinned` alerts + optional monochrome sparklines).
  3. Coalesced streaming verification (`RA8EMU-1235` frontend scope), automated benchmark/soak script `src/interfaces/gui/tools/bench-soak.mjs` (`RA8EMU-228` / `RA8EMU-1199` recipe), and `e2e/profiler-timeline.spec.ts` against `ra8_emulator serve --profile-folded`.
  4. Final cross-app audit across all 10 routes (`npm run gate`, `tsc --noEmit`, `ng build`, `test:unit`, `playwright test`, `zig fmt --check`, `zig build gate -j1`).
- **Commit Subject:** `RA8EMU-1340: implement Profiler context-switch timeline, flamegraph, stack watermarks, and soak benchmark` -> **run full gates & push**.

---

## Mandatory Verification, Commit & Push Gate (Run After Every Single Milestone)

Verify the emulator binary exists first (if not, run `zig build -j1` from repo root so Playwright `startServeFixture` can spawn `zig-out/bin/ra8_emulator[.exe]`).

Run these checks in sequence after finishing each milestone's edits:

```bash
# 1. Client SDK typecheck, build & tests
npm --prefix src/interfaces/gui/client run typecheck
npm --prefix src/interfaces/gui/client run build
npm --prefix src/interfaces/gui/client test

# 2. GUI static gate (<=350L/file, <=80L/fn, OnPush, 0 any, inclusive terms)
npm --prefix src/interfaces/gui run gate

# 3. Strict Angular TypeScript & 0-warning production bundle
npx --prefix src/interfaces/gui tsc --noEmit -p src/interfaces/gui/tsconfig.app.json
npx --prefix src/interfaces/gui tsc --noEmit -p src/interfaces/gui/tsconfig.spec.json
npm --prefix src/interfaces/gui run build

# 4. Full Vitest suite
npm --prefix src/interfaces/gui run test:unit

# 5. Full Playwright E2E suite (real ra8_emulator serve + Editorial Slate 1440x900 & 1280x720 audits)
npm --prefix src/interfaces/gui run test:e2e

# 6. Repository-wide Zig formatting and gate (checks terms across ALL *.md/*.ts/*.zig files)
zig fmt --check --exclude tests/consumer/zig-pkg --exclude src/interfaces/gui/node_modules build.zig build_tests.zig src tests tools
zig build gate -j1

# 7. Commit and push this milestone cleanly (NO untracked scratch/report artifacts in repo)
git status --short --branch
git add src/interfaces/gui
git commit --author="Brighton Sikarskie <bsikar@tuta.io>" -m "<MILESTONE_SUBJECT>"
git push origin bsikar/RA8EMU-1242-gui:bsikar/RA8EMU-1242-gui
```

*(On Windows PowerShell, run each step separated by newline or `; if ($LASTEXITCODE -eq 0) { ... }`. Never leave untracked binaries, Playwright HTML reports, or temporary logs staged or uncommitted before moving on to the next milestone.)*
