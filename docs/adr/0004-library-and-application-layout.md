# ADR 0004: library and application layout

Status: proposed, waiting on Brighton's review (RA8EMU-991). Epic: RA8EMU-985.
It replaces the layout section AGENTS.md had and settles the RA8EMU-974 moves.

## Context

On 2026-10-08 Brighton paused feature work and asked for an audit of separation,
dead code and organization. His model is that the chip is a standalone library,
a board library uses the chip plus pluggable components, and the CLI and the GUI
are separate applications that include the library. Scaffolding is not part of
the product.

Five read-only audits ran against main 1783e119: chip (RA8EMU-990), board and
components (RA8EMU-987), embedding API, session and RPC (RA8EMU-988), CLI and
GUI (RA8EMU-986), and build, tests, docs and dead code (RA8EMU-989). Their
findings disagree with that model in the same few places:

- The whole emulator is one build module, `ra8`, rooted at `src/root.zig`.
  `root.zig` re-exports the entire tree, the CLI and the GUI included, so the
  library contains both applications and import reachability proves nothing.
- The chip imports the CLI. `core/second_core.zig` imports
  `interfaces/cli/report/cores.zig`, and that one edge drags 168 non-chip files
  into the chip's closure, through `cli/window_stills.zig` and into
  `gui/platform.zig`.
- The production run loop lives in the CLI (`interfaces/cli/zig_run.zig` and
  23 related library files), so a board, a GUI or an embedder can only run the
  chip through the CLI application.
- Seven GUI files live in the CLI tree (`shell_main`, `window_*`), giving 34
  cli -> gui edges, and the GUI reaches back into `cli/board_view.zig`.
- The board reaches up into the debugger (`board/session_*`, `board_speed`,
  `board_boundary` import `debug/session_api.zig`) and into the CLI
  (`board/session_display.zig` -> `cli/frames_out.zig`).
- Off-chip parts sit inside on-chip controller directories (GT911 in `i3c/`,
  OV5640 in `riic/`, NOR flash in `xspi/`, the SD card in `sdhi/`, the USB stick
  in `usbhs/`). Host OS code sits inside device models (`periph/camera`'s
  AVFoundation, Media Foundation and V4L2 backends, `host_console`,
  `host_read`).
- Chip units live in `src/debug/`: ITM, DCB and DWT are registers firmware
  programs.

## Decision

### 1. Libraries are named build modules

Each library is one build module with a root file of `pub` declarations, wired
in `build.zig` with `addImport`. Code in one library imports another by module
name, for example `@import("ra8_chip")`, never by a relative path that leaves
its own directory. Zig refuses a file import outside a module's root directory,
so the compiler enforces the layering. No custom import-direction script is
needed (RA8EMU-979 is cancelled for that reason).

Inside a module, relative imports down or sideways in the same subtree are
fine. A `../` that leaves the subtree goes through the module root instead.
Module size costs nothing: Zig only analyzes and emits declarations that are
referenced. Watch only for `export`, `refAllDecls` outside tests, and comptime
blocks that force analysis.

### 2. The package tree and the allowed edges

```
module          directory            may import
ra8_host        src/host/            std only
ra8_snapshot    src/snapshot/        std only (the format: file, fields, sparse, units, blocks)
ra8_chip        src/chip/            ra8_snapshot
ra8_components  src/components/      ra8_chip (line interfaces only), ra8_snapshot
ra8_board       src/board/           ra8_chip, ra8_components, ra8_snapshot
ra8_session     src/session/         ra8_board, ra8_chip, ra8_snapshot
ra8_render      src/render/          ra8_session (value types), ra8_widget
ra8_rpc         src/interfaces/rpc/  ra8_session, ra8_host, ra8_rpc (firmware wire)
ra8_gdb         src/interfaces/gdb/  ra8_session, ra8_host
ra8_usbip       src/interfaces/usbip/ ra8_board, ra8_host
cli app         src/interfaces/cli/  libraries above, never the gui app
gui app         src/interfaces/gui/  libraries above + gui_sdl, never the cli app
```

`ra8_host` holds everything that touches the host OS: sockets, console and
handle readers, camera capture backends and image decoders, and file-backed
media (SD images, USB disk files, the ESP32-C6 tape). Libraries below the apps
never open host files or devices themselves. A component that needs host data
declares an interface (a frame source, a byte source, a socket), and the
application fills it from `ra8_host`.

`src/root.zig` stays as the `ra8` umbrella that tests and embedders import, but
it holds only module-name re-exports of the libraries: no file paths, no CLI, no
GUI.

### 3. Each library's public API

- **ra8_chip**: `Chip.init(gpa, part)` builds both cores (M85 CPU0, M33 CPU1),
  memories, the System Control Space (with ITM, DCB and DWT moved in) and the
  on-chip blocks for the part. The board passes in external clocks, bus ports for
  off-chip memory (SDRAM, OSPI and XSPI devices) and a line interface per pin
  function (SCI, SPI, I2C and I3C targets, GPIO and IRQ pins, USB PHY, MDIO and
  the Ethernet wire, SD bus, CEU and MIPI frames in, GLCDC pixels out, SSIE and
  PDM audio). The chip gives back `run(core, stretch) -> Stop` and `step`, where
  Stop is budget, wfi or wfe idle, breakpoint, raw fault record, reset request or
  lockup. It also gives register and memory access, breakpoint and watch hooks,
  an event sink and the timebase. CPU1 bring-up belongs to the chip (`dual/`),
  and the board only supplies its wiring config. The disassembler stays in the
  chip as `chip.disasm`, because it reuses the decoder. The chip's fault records
  carry raw facts: no disassembly text, no symbol names.
- **ra8_components**: one directory per part (camera_ov5640, expander_pi4ioe,
  touch_gt911, imu_lsm6dso, gauge_max17048, eink_it8951, modem_at,
  esp32c6_hosted, sd_card, nor_flash, usb_msc_stick, eth_phy with its wire peer,
  usb_loop_cable, button, led, user_switch). The plug layer (catalog, endpoint,
  parts, request, faults) sits at the root. A part implements its line's target
  contract plus an optional virtual-time tick, fault hooks and save and load of
  its own snapshot section.
- **ra8_board**: board construction, wiring, boundary, core clock, event sink,
  plug, profile, the image loader (elf, appimg, pages), board RAM and sizing,
  and board snapshot composition. Board definitions live underneath, starting
  with `board/ek_ra8d2/`.
- **ra8_session**: the one embedding API. `harness.open(gpa, io, options)` gives
  the owner, and `owner.session()` gives `*Session`. Session covers run, pause,
  step, next and finish per core, registers and memory, breaks and watches,
  input and plug, snapshot save and load, and events. Behind it are the debugger
  internals (stop machine, DWARF, unwinding, symbols, the command language), the
  run loop that drives both cores (moved out of `cli/zig_run.zig`), and the run
  instrumentation the reports read. `Session` becomes a concrete struct, because
  the function-pointer interface has had one implementation since Unicorn left.
- **ra8_render**: draw list, rasterizer, font, geometry, widget paint, the
  board-view composition (shared by `--frame-out` and the GUI window) and the
  PNG, GIF and WAV encoders.
- **ra8_rpc** is the remote adapter onto Session: the wire, the server and
  handlers, and the transports. The GDB RSP server becomes a second adapter in
  `src/interfaces/gdb/`.

### 4. Two executables

- `ra8_emulator`, the CLI, rooted at `src/interfaces/cli/main.zig`. It covers
  run, serve, ctl, `--map`, sweep and the report, and it never links SDL.
- `ra8_gui`, rooted at `src/interfaces/gui/main.zig` and built under `-Dgui`.
  The board window and the debugger shell merge into this one app, with the
  board view as one pane of the shell.

The `build_options.gui` branch in `main.zig` and the trick of setting
`window_main.opener` go away, because each app module only gets the library
imports, and the build graph shows the CLI and the GUI never import each other.
The GUI drives an in-process Session by default. `session_link` and RPC are for
a remote or out-of-process `serve`, not the glue between the apps. `gui_hello`
and the `gui-hello` step are deleted. The GUI smoke test runs the real app with
`--frames N`.

### 5. Open calls the audits left, decided

- One SD card model with two fronts (SPI mode and SD bus) in
  `components/sd_card/`, replacing `sd/sd_card` and `sdhi/sdhi_card`. Both
  files move there together under RA8EMU-1025, and merging their state is a
  follow-up inside that directory.
- `board/periph_layout.zig` is deleted with its test. No production code uses
  it, and map and ctl print from the registry.
- `debug/break_list.zig` gets wired into the command language (`info
  breakpoints`). `debug/boot_slots.zig` and `core/module_place.zig` stay, to be
  wired by the DFU and ThreadX-module work. All three are unfinished features,
  not dead code.
- The pend-hook stop (`pend_break`, `pend_resume`, `run_pace`) goes with the
  other Unicorn-era pacing leftovers (RA8EMU-1007): nothing sets `Session.pend`
  on the Zig path.
- `core/session.zig` becomes the chip's run options after RA8EMU-1007, renamed
  so it no longer collides with `debug/session.zig`.
- Snapshot sections move to per-unit save and load, owned by the unit they save
  (RA8EMU-1023), instead of the anytype field walk.

## Dead code, with evidence

The rule: unreachable from every build root and test root, or a declaration
whose name appears nowhere else.

- `src/interfaces/cli/report/steps.zig`: no importer but the root re-export,
  and the name is used nowhere (RA8EMU-992).
- Five `pub fn`s, each named exactly once across src, tests, tools and docs:
  nvic `pendingMasked`, icu `clearDtce`, usbhs_dfifo `isSelect`, eink_image
  `copyRectFrom`, esp_sock `isOpen` (RA8EMU-1013).
- 14 `root.zig` exports with zero by-name use (RA8EMU-1006).
- `core/run_pace.zig`, `core/pend_resume.zig` and the never-assigned Session
  fields (`pend`, `pend_pace`, `mask_pace`, `unmask`, `taken_from`, `taken_in`,
  `fns`, `pcs`, `deadline`, `park_on_wfe`), orphaned by RA8EMU-607
  (RA8EMU-1007).
- `src/gui_hello.zig` and the `gui-hello` step: scaffolding (RA8EMU-1004).
- `board/periph_layout.zig`: test-only, deleted per section 5.

Misplaced but live (moved, not deleted): the conformance bookkeeping under
`core/cpu/conformance/` goes to `tests/` (RA8EMU-1014).

## Migration order

One rule keeps every file to a single move: a directory is renamed only after
everything leaving it has left, and files arriving in a renamed directory move
after the rename.

1. **This ADR** (RA8EMU-991). Docs only.
2. **Cut the bad edges in place**, no moves: 993, 994, 996, 997, 998, 999,
   1012, then 1007, 992, 1013, 1006 and 1004 (with the periph_layout
   deletion). After this step nothing below the apps imports the CLI or the
   GUI, and the chip imports no board, debugger or CLI file.
3. **Move files out of src/core and src/periph to their final homes**:
   `src/host/` (1020, 1011, 1016, 1010), `src/components/` (1017 with 1019,
   1021, 1025), `src/board/` (1018), `src/render/` (1001), run policy out of
   `periph/time` (1015), and `tests/` (1014). Then split `periph.zig` (1026).
4. **Rename the chip**: `src/core` and `src/periph` become `src/chip/core` and
   `src/chip/periph`. That is pure renames, so open branches rebase through
   rename detection. Then move `board/option_memory` in (1024) and ITM, DCB and
   DWT in from `src/debug` (995).
5. **Session**: move the RSP server out of `src/debug` (1005), rename
   `src/debug` to `src/session`, then move in the board session adapters (1022),
   `harness.zig` and the 24 run-engine files from `src/interfaces/cli` (977).
   Make `Session` a concrete struct.
6. **Apps**: rename `src/gui` to `src/interfaces/gui` (973), move the seven GUI
   files out of the CLI and `gui_window.zig` in (983), and move `main.zig` to
   `src/interfaces/cli/main.zig`. Then make two executables and merge the window
   into the shell.
7. **Snapshot**: per-unit sections (1023).
8. **Modules**: `build.zig` declares the named modules and the DAG, and
   `root.zig` becomes module-name re-exports only (981 and 984 finish here).
9. **Docs**: stale paths (1008).

An open PR touching a moved path rebases through rename detection or lands
before that step. During the migration, a lane checks that no open PR touches
the paths a step moves before it starts.

## Ticket rulings

| ticket | ruling | reason |
| --- | --- | --- |
| 973 | accept | Brighton's call. src/gui becomes src/interfaces/gui (step 6). |
| 975 | cancel, duplicate of 995 | 995 moves ITM, DCB and DWT into the chip SCS, which is the same work. |
| 976 | rewrite into 1020 | src/host/ is the destination. 1020 lists every host adapter, 1011, 1016 and 1010 included. |
| 977 | rewrite | Session layer is src/debug renamed to src/session, plus the board adapters (1022), harness and the run engine out of cli (step 5). |
| 978 | cancel, covered by 1012 and 1018 | CPU1 bring-up stays chip-owned (1012). Board memory and the loader move out (1018). |
| 979 | cancel | Named modules make the compiler enforce the DAG. The AGENTS.md section ships in this ADR's PR. |
| 980 | cancel, duplicate of 1004 | 1004 deletes gui_hello and its step. The smoke run uses the real GUI. |
| 981 | accept, rewritten | src/render/ is a named module, with board_view (1001) and the encoders. |
| 982 | cancel, split | Covered by 999, 997 and 996 in step 2. |
| 983 | accept | GUI files out of the CLI into src/interfaces/gui. ra8_gui is its own executable, and main.zig no longer dispatches --gui. |
| 984 | rewrite | The GUI reads state only through the Session API (in-process, or over RPC remotely), never board, periph or core internals. |
| 992 | accept | Dead file. |
| 993 | accept | Chip -> CLI edge. Kept over 1003. |
| 994 | accept | Raw fault records, no disasm or symbols in the chip. |
| 995 | accept, widened | ITM, DCB and DWT into the chip. |
| 996 | accept | Cpu0 store into the library. Kept over 1002. |
| 997 | accept | Drop the step_hook re-export. Kept over 1000. |
| 998 | accept | app_codes belong with the wire. |
| 999 | accept | frames_out out of the CLI. Kept over 1009. |
| 1000 | cancel, duplicate of 997 | Same step_hook edge. |
| 1001 | accept | board_view into render. |
| 1002 | cancel, duplicate of 996 | Same Cpu0 move. |
| 1003 | cancel, duplicate of 993 | Same second_core -> report/cores edge. |
| 1004 | accept | gui_hello is scaffolding. |
| 1005 | accept | RSP server is an adapter, src/interfaces/gdb. |
| 1006 | accept | 14 dead root exports. |
| 1007 | accept | Unicorn-era pacing leftovers, pend_break included. |
| 1008 | accept | Stale doc paths. Runs last so it names final paths. |
| 1009 | cancel, duplicate of 999 | Same session_display -> frames_out edge. |
| 1010 | accept | The C6 uses a socket interface filled from ra8_host. |
| 1011 | accept | Camera host backends into src/host. |
| 1012 | accept | Chip owns CPU1 bring-up, and the board passes wiring config. |
| 1013 | accept | Five dead pub fns. |
| 1014 | accept | Conformance bookkeeping to tests. |
| 1015 | accept | Run policy (duration, soak, speed, pacer) out of the chip, into session or the apps. |
| 1016 | accept, folded into 1020's PR set | host_console and host_read into src/host. |
| 1017 | accept as umbrella | eink, modem, esp32c6, model catalog. Finer moves in 1019, 1021, 1025. |
| 1018 | accept | Loader and board memory into the board. |
| 1019 | accept | I2C and I3C parts into components. |
| 1020 | accept | Host adapter tree. |
| 1021 | accept | Wire peers and pin parts into components. |
| 1022 | accept | Board session adapters into the session layer. |
| 1023 | accept | Per-unit snapshot sections. |
| 1024 | accept | Option-setting memory is chip. |
| 1025 | accept | Storage parts into components, one SD card model with two fronts. |
| 1026 | accept | Split the periph.zig barrel. |

Cancellations and rewrites are applied in YouTrack once Brighton approves this
ADR.

## Consequences

Every library can be built and tested on its own, and an embedder imports
`ra8_session` without pulling in the CLI or SDL. The CLI and the GUI shrink to
applications over one API. The cost is a long run of move PRs. The order above
keeps each one a pure rename or a single edge cut, so open branches rebase
through rename detection.
