# Remaining Milestones (`M4` – `M8`): Complete YouTrack & Stitch Specification

This document contains every requirement from the private YouTrack sprint (`PWA GUI — Editorial Slate Workbench`) and Stitch visual mockups (`handoff/stitch/`), so you can implement **Milestones 4 through 8** without needing YouTrack or Stitch access.

---

## Milestone 4 (`RA8EMU-1336`, `RA8EMU-964`, `RA8EMU-966`)
**Custom Board Composer (`04b`–`04h`), Settings & Color Schemes (`07`, `07b`), Responsive Splits, HiDPI & Fullscreen**

### Stitch Visual References to Inspect Before Coding
- `handoff/stitch/stitch_04_new_workspace.png` & `stitch_04a_board_details_modal.png`
- `handoff/stitch/stitch_04b_create_board_modal.png` — `Configure Target Board`
- `handoff/stitch/stitch_04c_custom_component_modal.png` — `Define Component & Pin Mapping`
- `handoff/stitch/stitch_04d_configure_cores_modal.png` — `Configure Cores & On-Chip Memory`
- `handoff/stitch/stitch_04e_add_preset_mcu_modal.png` — `Add Preset MCU`
- `handoff/stitch/stitch_04f_custom_silicon_modal.png` — `Define Custom Silicon / MCU Preset`
- `handoff/stitch/stitch_04g_add_memory_region_modal.png` — `Add Memory Region`
- `handoff/stitch/stitch_04h_add_component_modal.png` — `Add Component & Pin Mapping`
- `handoff/stitch/stitch_07_settings_modal.png` — `Settings · Hardware Probes & HIL`
- `handoff/stitch/stitch_07b_settings_color_schemes.png` — `Settings · Syntax & Semantic Signal Schemes`

### Requirements
1. **Custom Board Composer (`04b`–`04h`, `features/workspace/` + trigger from `New Workspace` & `BoardDetailsModalComponent`):**
   - Triggered by `+ New Board` or row `Edit` button in `LaunchNewWorkspaceDialogComponent` / `BoardDetailsModalComponent`.
   - **Screen `04b` (`Configure Target Board`)**:
     - Fields: `BOARD NAME` (e.g. `Dual-MCU Motor Carrier`), `PROFILE FILE` (`.board` stem).
     - `MCUs & COMPUTE TOPOLOGY` section with `+ Add Preset MCU` (`04e`) and `+ Custom Silicon` (`04f`), listing U1/U2 MCU rows with `pencil` (opens `04d` Configure Cores & On-Chip Memory) and `trash` icons (never literal text `"Configure Cores"` on row buttons — icon actions only per Stitch `04b`).
     - `EXTERNAL MEMORY & TIMING` section with OSPI / SDRAM / QSPI / HyperRAM / Custom MMIO rows and `+ Add Memory Region` (`04g`: interface type tabs, MCU mount + base address `0x80000000`/`0x90000000`, capacity, bus width & mode, XIP/security, clock MHz, read latency cycles, burst, backing store).
     - `COMPONENTS & PIN MAPPING` section with `+ Add Component` (`04h` catalog: `OV5640`, `GT911 + LCD`, `LSM6DSO`, `ESP32-C6`, `User LED / Switch` + inline pin mapping) and `+ Custom Component` (`04c`: name, target MCU, `GPIO/Timer | I2C (Peripheral) | SPI (COPI/CIPO/CS) | UART (SCI) | ADC/Analog`, signal-to-pin rows, simulation model). Notice **strict inclusive terminology**: `COPI / CIPO / CS` and `Controller / Peripheral`!
     - Footer: `Remove Board`, `Export .board` (downloads serialized `.board` text via `serializeBoardProfile` matching `src/board/profile.zig`), `Cancel`, `Save Board` (persists to `BoardStore.savedBoards` via `board-storage.ts` `ra8.customBoards.v1` and selects it).
     - Also extend custom board metadata cleanly in `board-storage.ts` (keeping `BoardPreset.profile` compatible with `parseBoardProfile` / `serializeBoardProfile`).
2. **Global Settings Modal (`07` & `07b`) — Upgraded Replacement for `AppShellComponent`'s Basic Settings Dialog:**
   - **CRITICAL SELECTOR CONTRACT:** Must remain reachable from `[data-testid="settings-trigger"]` and `Cmd/Ctrl+,`, render `role="dialog"` with `aria-label="Session settings"`, and preserve `[data-testid="settings-vim-toggle"]` + `[data-testid="settings-open-extensions"]` so existing `shell-cuj.spec.ts` and `app-shell.component.spec.ts` continue passing!
   - **2-Column Layout (`stitch_07` / `stitch_07b`)**:
     - Left nav: `General & Defaults`, `Appearance & Color Schemes`, `Session Recording`, `Hardware Probes & HIL`, `Remote & SSH Hosts`, `Toolchains & Keybindings`.
     - **Appearance & Color Schemes (`07b`)**: Select between `Editorial Slate Vivid` (default `#95A6C8`/`#7FAAB8`/`#C4AA84` tokens), `Tokyo Slate`, `Nordic Frost`, `High-Contrast Mono`. Show `LIVE WORKBENCH PREVIEW` code snippet and apply **ONLY** to `--es-tok-*`, `--es-signal-*`, code font size (`12px..15px`), and `Dim Zero Registers (0x00000000)` toggle — window chrome MUST stay 100% monochromatic Editorial Slate! Persist settings cleanly in `localStorage`.
     - **Hardware Probes & HIL (`07`, `RA8EMU-1324`)**: `Device Binding Identity` (`USB Serial + VID:PID`), `Auto-Rebind VCOM on Reset / Replug` toggle, `Default SWD Connect Mode` (`Under Reset | Normal | Hot-Plug`), `↻ Rescan Probes` querying `client.listTargets()` (`0x0190`) when `CAP_TARGETS` is present (honest empty state when offline/unavailable), `Export Settings JSON`, `Save Preferences`.
3. **Responsive Splits, HiDPI `<canvas>` & Fullscreen (`RA8EMU-964`, `RA8EMU-966`):**
   - Upgrade `SplitPaneComponent` to use proportional percentage/flex-basis or CSS Grid `fr` bounds with draggable resize handle + `localStorage` persistence key (optional `@Input`/`input<string>('persistKey')`), enforcing `min-width`/`min-height` so panes never collapse cleanly down to `1280x720`.
   - Create `shared/utils/hidpi-canvas.ts`: `ResizeObserver` + `window.devicePixelRatio` helper keeping `<canvas>` backing buffers crisp across 1x/Retina displays and computing exact aspect-locked inverse coordinates for touch events (`0x011F`).
   - Add `View > Full Screen` action (`nav-fullscreen` / `F11` / `Ctrl+Cmd+F`) wired to `document.documentElement.requestFullscreen()` / `document.exitFullscreen()`.
4. **Tests & Commit Target:** `npm run gate`, `tsc --noEmit`, `ng build` (0 warnings), `npm run test:unit`, new `e2e/composer-settings-04-07.spec.ts` (`1440x900` + `1280x720` `auditEditorialSlateScreen` + custom board round-trip + scheme CSS var update + fullscreen/split check), `zig build gate -j1`. Commit & push `bsikar/RA8EMU-1242-gui`.

---

## Milestone 5 (`RA8EMU-1337`, `RA8EMU-1330`, `RA8EMU-1125`, `RA8EMU-1187`, `RA8EMU-1264`, `RA8EMU-1246`, `RA8EMU-1169`)
**Screen 08 — Workbench Debug (CodeMirror 6 + Vim Layer 2, Dual-Core Disasm, Call Stack, Locals Edit, Memory Hex & Registers)**

### Stitch Visual Reference
- `handoff/stitch/stitch_08_workbench_debug.png`

### Critical Selector Contracts to Preserve
- `e2e/shell-cuj.spec.ts` & `e2e/live-session.spec.ts` require `/debug` to contain `'CORE REGISTERS'`, `[data-reg="pc"]` matching `/0x[0-9a-f]{8}/`, `[data-testid="debug-disasm"]`, `[data-testid="debug-step-btn"]`, `[data-testid="debug-run-btn"]`, and `[data-testid="debug-observe-pill"]` when `rpc.observeOnly()` is true.
- Top-left workspace switcher pill `[data-testid="debug-layout-switcher"]` supporting `Board | Debugger | Side-by-Side Split` (`RA8EMU-958` alignment with `/hardware`), persisted in `localStorage`.

### Requirements
1. **Spatial Mode 2 Edge-to-Edge Split Layout (Strictly matching `stitch_08_workbench_debug.png`):**
   - **Left Column**:
     - `TARGETS & THREADS`: CPU0 (`Cortex-M85`) & CPU1 (`Cortex-M33`, shown when `execution.cpu1Attached()`) core selector calling `debug.activeCore.set(...)` + `Sync Halt` indicator + RTOS task/thread rows when `ProfileStore.rtosTasks()` has entries + `ACCELERATORS` Ethos-U55 line when board has NPU.
     - `CALL STACK` (`0x0120` `backtrace` + `0x011D` `StackReport` MSP/PSP watermark bar fixing inverted utilization math via `shared/utils/stack-math.ts`): Clicking frame `#i` calls `debug.selectFrame(i, frame.frameBase)` which fetches `getLocalsAt(core, i)` (`0x012A`).
     - `BREAKPOINTS (+)` (`0x0109..0x010C`): Toggle enabled/remove breakpoints & watchpoints; `+` popover lets users add address/symbol breakpoint (showing `pending` badge if `deferred === true`) or watchpoint with `R | W | RW` access mode and byte length `1 | 2 | 4 | 8`.
   - **Center Top — Code Buffer (`Source | Disasm | Mixed | Decomp`)**:
     - Read source files over `CAP_WORKSPACE` (`0x0142` `readWorkspaceFile`) when `sourceLine().found && path`, highlighting the active PC line (`#181C24` wash + `2px #B8C4D9` bar + `#D9776C` gutter breakpoint dot).
     - `Disasm`: `0x012F` disassembly with instruction bytes, symbols, gutter click to toggle `0x0109` / `0x010A`, `Follow PC` toggle, optional `Split CPU0 | CPU1` dual-core view, hex/symbol jump input (`<datalist>` from `cpu0ElfSymbols`/`cpu1ElfSymbols`) + `+ Break`.
     - `Mixed`: interleaved source line headers with disassembly instructions.
     - `Decomp`: deterministic Thumb-2 pseudo-C lift using `shared/utils/decompiler.ts` (styled strictly in `.es-code-buffer` tokens — no colored warning banner).
     - Integrate Layer-2 **Vim navigation (`RA8EMU-1330`)**: when `VimStore.enabled()`, handle `j`/`k`, `gg`/`G`, `Ctrl+u`/`Ctrl+d`, `/` search (`n`/`N`), marks, and `:ex` line/hex jumps inside the code pane! (May install `@codemirror/view` + `@codemirror/state` + `@codemirror/lang-cpp` + `@replit/codemirror-vim` if bundle stays clean and tests pass under jsdom/Vite, OR use an Editorial Slate virtualized line-buffer editor directly bound to `VimStore` engine if lighter and simpler.)
     - Contextual `Skip BKPT` (`0x0137`) button when stopped reason is `SwBkpt`.
   - **Center Bottom — Split `LOCALS & WATCH` & `Registers (Δ) | Memory | Peripherals`**:
     - `LOCALS & WATCH` (`RA8EMU-1187`, `RA8EMU-1246`, `RA8EMU-1264`): Display evaluated DWARF locals (`dwarf-eval.ts`) + user watch expressions; show storage `Where` metadata subtly; clicking a writable scalar row opens an inline hex/decimal/float value editor calling `0x013D` `setVariable` (`writeMemory`/`writeRegister` fallback) and immediately re-reads `locals`! Read-only/optimized-out locals render a clear disabled badge explaining why. Include `Undo Write` (`0x013E`) when `canUndoWrite()`.
     - `Registers (Δ)`: `GPR · MVE · Sys` filter tabs covering general registers, FPSCR/VPR/S0..S31, and Primask/MSP/PSP/MSPLIM/PSPLIM (`DebugStore` reads full groups cleanly); dim zero registers (`0x00000000`) when setting is enabled; `2px #B8C4D9` left tick on changed registers (`delta`); click-to-edit register (`0x0106` `writeRegister` + immediate re-read, disabled in `observeOnly`).
     - `Memory` (`RA8EMU-1125`): Bound to **`debug.activeCore()`** (never hardcoding `Core.Cpu0`!), `256 B` paged Hex + ASCII dump with `MRAM (0x02000000)`, `SRAM (0x20000000)`, `SP`, `PC` preset chips, hex jump input, delta byte highlight, `+ Watch`, and click-to-poke byte (`0x0108` `writeMemory` + immediate re-read).
     - `Peripherals`: quick MMIO summary for the selected core (`HardwareHilStore`).
   - **Right Column (When Layout Mode Includes Board/Split)**:
     - `BOARD PREVIEW`: Live HiDPI `FramebufferRenderer` LCD `<canvas>`, `cameraSource` picker (`0x011B`), LED1–N indicators (`decodeLedEvent`), `SW1`/`SW2` buttons (`sendButton` with current `virtualTimeNs()`), clean headless state if the active `.board` profile has `panel === null`.
     - `SERIAL · SCI8 UART`: Compact live UART tail + quick TX command input + `Open Console ↗` link to `/console`.
   - **Typography Check (`RA8EMU-1169`):** Verify `.mono` (`tabular-nums`) applies to EVERY hex/code/address/value element across Debug panes.
2. **Tests & Commit Target:** Full gates + `e2e/debug-screen-08.spec.ts` (live `blink.elf` + DWARF ELF `tests/fixtures/uart/uart_irq_echo.elf`: registers, step, disassembly toggle, breakpoint add/remove, memory jump/poke, register edit + readback, Vim `j`/`k`/`gg` navigation, `auditEditorialSlateScreen` at `1440x900` & `1280x720`). Commit & push `bsikar/RA8EMU-1242-gui`.

---

## Milestone 6 (`RA8EMU-1338`, `RA8EMU-205`, `RA8EMU-958`, `RA8EMU-1122`, `RA8EMU-826`)
**Screen 09 (Workbench Console / Device Monitor) & Screen 10 (Board & Hardware Inspector, HIL Faults, LCD Scrubber & Layout Split)**

### Stitch Visual References
- `handoff/stitch/stitch_09_workbench_monitor.png`
- `handoff/stitch/stitch_10_workbench_hardware.png`

### Critical Selector Contracts to Preserve
- `/console` must contain `'UART SERIAL STREAM'`.
- `/hardware` must contain `'FITTED PARTS'`.

### Requirements
1. **Screen 09 (`/console`) — Interactive Device Monitor (`stitch_09_workbench_monitor.png`, `RA8EMU-1122`):**
   - Top bar: Stream filter (`All | UART | SWO | RTT` / SCI Channel picker `All / CH0..CH9` via `ConsoleStore.selectedChannel`), regex/substring search filter, `ASCII | Hex` display toggle, `Time: Elapsed | Virtual ns`, `Autoscroll` smart lock (pauses automatically on wheel-up scroll; shows `Resume Tail` pill; NEVER forces scroll-to-bottom unconditionally in dirty checks!), `Copy`, `Save Log` (exports `ConsoleStore.exportLogBlob()` via `<a download>`), `Clear`.
   - Scrollback buffer: Supports `>= 2,000` timestamped entries (`MAX_CONSOLE_ENTRIES = 2000` in `console.store.ts`).
   - Bottom interactive bar: Serial TX `<input>` (`Send`, `LF | CRLF` line ending toggle, `Local Echo` toggle) -> `ConsoleStore.sendInput()` (`0x011A`).
   - Right sidebar: `SERIAL & PROBE LINK` (active session endpoint + core selector `CPU0`/`CPU1`), `ELF SYMBOL DECODER` (paste or auto-decode `0x...` PCs using loaded `BoardStore.cpu0ElfSymbols` + optional `getSourceLine`), `WATCH TRIGGERS` (`+ Add` pattern with `Alert + Halt | Marker` action on matching incoming UART line), and `Reset Image` (`0x013F`).
2. **Screen 10 (`/hardware`) — Board, LCD Canvas Scrubber, HIL Faults & MMIO Peripherals (`stitch_10_workbench_hardware.png`, `RA8EMU-205`, `RA8EMU-826`):**
   - **Col 1 (`INTERACTIVE PANEL` & `STIMULUS & FRONT PANEL I/O`)**:
     - Aspect-locked HiDPI `FramebufferRenderer` `<canvas>` (`devicePixelRatio` crisp), pointer mode toggle (`Tap | Swipe | Longpress`), crosshair `(x, y)` mapped accurately back to native panel pixel coordinates (`0x011F` `sendTouch` with `atNs = execution.virtualTimeNs()`), `Save PNG`. Clean headless card when `panel === null` (`FPB-RA8E1`/`FPB-RA4T1`).
     - **Adaptive `0x010D` `subscribe` & Frame History Scrubber (`RA8EMU-205`)**: Maintain a bounded ring buffer (e.g. up to 120 composited frames keyed by `virtualNs`), track & display skipped/captured frames, throttle `0x0103` `lcd_dirty` subscription rate when pacing > `1x` (`100x`/`max`) and capture every frame in `0.1x` slow-motion, with interactive slider scrubbing back through captured frames.
     - `OV5640 Camera` source selector (`none`, `gradient`, custom path + webcam consent toggle -> `0x011B`), live LED indicators (`decodeLedEvent`), `Pulse SW1 / SW2` (`0x011F`), board silicon/memory specs & RTC readout (`0x011E` `getRtc`).
   - **Col 2 (`HIL COMPONENTS & FAULT INJECTION` & `SESSION HARDWARE EVENTS`)**:
     - `FITTED PARTS`: `HardwareHilStore.fittedParts()` (`getListParts` `0x0113`), `+ Plug Component` (`0x0114`) / `Unplug` (`0x0115`) using exact `model@endpoint` syntax.
     - `FAULT INJECTOR`: Mode chips (`disconnected`, `nack:N`, `stuck:0xHH`, `garbage:SEED`, `slow:NS`, `stretch:NS`, `bus_low`), numeric/seed parameter input, `Apply Fault` -> `HardwareHilStore.setFault()` (`formatFaultSpec` producing `MODEL@ENDPOINT=RULE` for `0x0116`) & `Clear Fault` (`0x0117`).
     - `SESSION HARDWARE EVENTS`: live feed (`5px` nominal / `6px` fault dots + timestamps).
   - **Col 3 (`MMIO PERIPHERALS`)**:
     - Filter input (`Filter peripheral or 0x40...`), quick block chips (`NPU`, `GLCDC`, `CEU`, `RIIC0`, `SCI8`, `IPC`, `SCB`, `SAU`, ...), CPU0/CPU1 core selector, collapsible register & bitfield inspector (`getPeriph(core, block, true)` `0x0123`, falling back cleanly to 64B `readMemory` dump when no descriptor exists).
3. **Layout Switcher & LCD Rate Benchmark Tests (`RA8EMU-958`, `RA8EMU-826`):**
   - Persist `Board | Debugger | Side-by-Side Split` mode cleanly across `/debug` and `/hardware` via `localStorage`.
   - Write automated benchmark/scrubber unit + E2E tests (`e2e/monitor-hardware-09-10.spec.ts` + Vitest scrubber/throttle tests verifying `1x`, `100x`, `max`, `0.1x` subscription rate adaptation and frame scrubber playback).
4. **Tests & Commit Target:** All gates clean, commit & push `bsikar/RA8EMU-1242-gui`.

---

## Milestone 7 (`RA8EMU-1339`, `RA8EMU-1201`)
**Screen 11 — Deterministic Time-Travel Rewind & State Diff (`stitch_11_workbench_rewind.png`)**

### Stitch Visual & Architectural References
- `handoff/stitch/stitch_11_workbench_rewind.png`
- `handoff/specs/rewind_architecture_spec.md`

### Critical Selector Contract to Preserve
- `e2e/shell-cuj.spec.ts` requires `/rewind` to contain `'EXECUTION BRANCHES'`.

### Requirements
1. **Top Transport & History Nav Strip:**
   - Buttons: `Step Back` (`0x012D`), `Play Reverse` (`0x0138`), `Pause`, `Step Forward`, `Seek` input (supporting `12ms`, `1842` rounds, `frame:N`, `isr:prev`, `bm:name` — NO `@` prefix!) + `Seek` button (`0x012C`), `Prev ISR`, `Next ISR`, `Prev RTOS`, `Next RTOS` (`0x0139` `navQuery`), `+ Bookmark` (`0x013A` `setMarker`), `Export Session (.tar)` (links to `/import` or exports via `RewindStore.exportArtifactBundle`).
   - Display prominent honest message if backend started with `--history off` (`!rewind.historySupported()`).
   - Show pending fork banner when `rewind.forkStatus()?.pending` (`Confirm Counterfactual Fork` `0x0133`).
2. **Left Column (`EXECUTION BRANCHES` / `BRANCH TREE (COW)` + `FRAME & CACHE STATUS`):**
   - Rooted branch tree rows (`0x0130` `getBranches`) showing `#id`, parent fork round, reason badge, `LIVE` badge; clicking a branch calls `switchBranch` (`0x0131`); `Prune` button (`0x0132` `deleteBranch`) enabled on non-live branches.
   - Frame / scrub cache status readout (`0x013B` `frameStatus` hot/cold counts + snapshot controls `0x0118` / `0x0119`).
3. **Center Interactive Timeline Canvas (`shared/utils/rewind-layout.ts`):**
   - Bind `computeRewindTreeLayout(branches, nodes, layoutMode())` with a 1-click toggle between **`Spine: Center ±Y`** (default) and **`Waterfall`**.
   - Render SVG/HTML edges, `◆` checkpoints, branch fork curves, Point `A` and Point `B` comparison pins, and interactive click-to-seek / shift-click-to-set-Point-B behavior (honoring `virtualTimeNs` / round coordinates cleanly).
4. **Bottom 3-Column `STATE DIFF (Point A -> Point B)` (`0x013C` `compareDiff`):**
   - Header: Point A / Point B inputs + `Swap A↔B` + filter tabs (`All Changes | CPU Registers | Dirty CoW Pages | Peripheral MMIO`).
   - Three equal split columns:
     - `CPU REGISTERS`: `before -> after` for changed registers in `activeDiff().regs`.
     - `DIRTY COW RAM PAGES`: page address + diff byte count in `activeDiff().pages`.
     - `PERIPHERAL MMIO`: block/register transitions in `activeDiff().periphs`.
5. **Live `--history` Playwright E2E (`e2e/rewind-screen-11.spec.ts`, `RA8EMU-1201`):**
   - Start `startServeFixture` with `--history <tempHistoryDir> --artifacts-root <tempArtifactsDir>` (check `ra8_emulator serve --help`: `--history DIR --checkpoint-every 4`!).
   - Advance execution, inspect `/rewind`, set a bookmark (`setMarker`), step back (`stepBack`), trigger seek (`seek`), compare `diff` between two positions, verify snapshot/restore (`0x0118` / `0x0119`), run `auditEditorialSlateScreen` at `1440x900` & `1280x720`.
6. **Tests & Commit Target:** All gates clean, commit & push `bsikar/RA8EMU-1242-gui`.

---

## Milestone 8 (`RA8EMU-1340`, `RA8EMU-834`, `RA8EMU-1235`, `RA8EMU-1199`, `RA8EMU-228`)
**Screen 12 — Execution Profiler, Context-Switch Timeline, Flamegraph, Stack Watermarks & Sustained Soak**

### Stitch Visual Reference
- `handoff/stitch/stitch_12_workbench_profile.png`

### Critical Selector Contract to Preserve
- `e2e/shell-cuj.spec.ts` requires `/profile` to contain `'METRICS & STACKS'`.

### Requirements
1. **Top Filter & Export Bar:**
   - Core selector (`CPU0 · Cortex-M85 | CPU1 · Cortex-M33 | Both Cores`), thread filter, brushed `[A – B]` range display + `Full Run` reset, `Export .folded` download (`0x0121` `getFolded` saved via `<a download>`), `Clear`.
2. **Top Pane — `CONTEXT-SWITCH & EXECUTION TIMELINE` (`RA8EMU-834`):**
   - Pure TypeScript bounded ring-buffer model (`src/app/features/profile/timeline-model.ts` + exhaustive mirrored `tests/features/profile/timeline-model.spec.ts`):
     - Folds `Topic.Trace` (`EventKind.RtosSwitch`, `EventKind.RtosIdle`, `EventKind.IsrEnter`, `EventKind.IsrExit`) per core into closed `[startNs, endNs)` slices across lanes (`CPU0 Threads`, `CPU0 ISRs`, `CPU1 Threads`, `CPU1 ISRs`).
     - Handles nested ISRs preempting threads cleanly, idle gaps, and bounded ring eviction without unbounded heap growth.
     - Computes per-lane & per-core utilization `%` over any visible `[viewStartNs, viewEndNs)` viewport (`0x012E` semantics).
     - Supports cursor-anchored wheel zoom, clamped panning, `[A, B]` time range brushing (filtering the Flamegraph/Hotspots), and deterministic `(lane, xPx) -> Slice | null` hit-testing for hover tooltips.
   - Rendered on a crisp HiDPI `devicePixelRatio` `<canvas>` styled exclusively in Editorial Slate tonal greys (`#161920`, `#1C2028`, `#222630`, `#2A2F3A`, hairline borders `#21242B`, cursor `#B8C4D9`).
3. **Bottom-Left — `CALL STACK FLAMEGRAPH` & `TOP SELF-CYCLE HOTSPOTS`:**
   - `Flamegraph | Icicle` toggle + symbol filter + click-to-zoom frame (updating `Selected Frame` readout with self%/total%) powered by `shared/utils/flamegraph.ts`.
   - `TOP SELF-CYCLE HOTSPOTS` sortable table (`FUNCTION SYMBOL`, `SELF %`, `TOTAL %`, `SAMPLES`, `SOURCE LOCATION` jump to `/debug`).
4. **Bottom-Right (`METRICS & STACKS`) — `STACK WATERMARKS`, `GUEST COMPUTE & MEMORY` & `HOST RUNTIME METRICS`:**
   - `STACK WATERMARKS`: `CPU0 MSP`, `CPU0 PSP`, `CPU1 MSP`, `CPU1 PSP` from `ProfileStore.cpu0StackMetrics()` / `cpu1StackMetrics()` (`computeStackMetrics` in `shared/utils/stack-math.ts`), highlighting high usage (`>= 85%`) with `#D9776C` `Near PSPLIM` dot alert.
   - `GUEST COMPUTE & MEMORY`: CPU0/CPU1 load %, WFI %, SRAM & SDRAM usage from `MetricsReport` (`0x012E`).
   - `HOST RUNTIME METRICS`: Pacing (`pacingRatio` with `< 0.35x` bottleneck warning & `cpuPinned` indicator if reported), `Host CPU %`, `Host RSS MB`, plus optional subtle monochrome SVG hairline sparkline over `hostCpuHistory()` / `hostRssHistory()`.
5. **Throughput Coalescing & Sustained Benchmark Script (`RA8EMU-1235` Frontend, `RA8EMU-228` / `RA8EMU-1199` Recipe):**
   - Audit `ExecutionStore` + `DebugStore` + `ProfileStore`: confirm active runs use streaming `run` (`0x0101`) / `advanceAsync` (`0x012B`) + rate-capped `subscribe` and inspect registers/stack/locals ONLY on halt (`stop`) or explicit throttle (never tight polling loops).
   - Add automated sustained-load benchmark script `src/interfaces/gui/tools/bench-soak.mjs` (plus unit tests / docs) that starts `ra8_emulator serve` with `--profile-folded`, connects a headless Chromium/RPC client for timed runs, logs virtual-time throughput, `MetricsReport` RSS/CPU, JS heap stability, and frame timing p50/p99 without failing offline CI (`e2e/profile-screen-12.spec.ts` runs short `--profile-folded` E2E verification + `auditEditorialSlateScreen` at `1440x900` & `1280x720`).
6. **Final Epic Audit & Commit Target:** Confirm every route (`/launch`, `/open`, `/import`, `/workspace/new`, `/connect`, `/debug`, `/hardware`, `/rewind`, `/profile`, `/console`), all unit tests, all Playwright E2E tests, `npm run gate`, `tsc --noEmit`, `ng build`, `zig fmt --check`, and `zig build gate -j1` pass 100%, then commit & push `bsikar/RA8EMU-1242-gui`.
