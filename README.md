<!--
Copyright (c) 2026 Brighton Sikarskie
SPDX-License-Identifier: MIT
-->

# ra8_emulator

Runs real, unmodified firmware `.elf` images (the same binaries flashed to an
EK-RA8D2) on emulated Cortex-M85 and Cortex-M33 cores over a modelled RA8
peripheral space. For the RA8P1, which has no board on the bench, this is how
its firmware gets proven.

It is three things in one repository: an emulator you run from the command line,
a debugger for the firmware it runs, and a Zig library other programs embed. The
execution engine, CPU core, and disassembler are Zig (no C library is linked
beyond libc), and the browser workbench is an Angular TypeScript app.

## Install

The emulator backend requires **Zig 0.17.0**. The browser workbench also
requires **Node.js 22.13+** (22.x series) and npm.

```sh
# Linux x86_64 (swap the triple for aarch64-linux, x86_64-macos, or aarch64-macos)
curl -fsSLO https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz
sha256sum zig-x86_64-linux-0.17.0.tar.xz
# x86_64-linux:  1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
# aarch64-linux: 9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8
# x86_64-macos:  4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6
# aarch64-macos: b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a
tar xf zig-x86_64-linux-0.17.0.tar.xz -C "$HOME/.local"
export PATH="$HOME/.local/zig-x86_64-linux-0.17.0:$PATH"
```

```sh
zig build                       # builds zig-out/bin/ra8_emulator
```

Run `ra8_emulator` with no arguments (or `<subcommand> --help`) to list all
flags and subcommands.

## Emulator

```sh
ra8_emulator app.elf                         # RA8D2 is the default part
ra8_emulator app.elf --part ra8p1            # RA8P1, with NPU
ra8_emulator app.elf --cpu1 cpu1.elf         # dual-core (CPU0 + CPU1)
ra8_emulator app.elf --ms 2000 --frame-out panel.png
```

The end-of-run report summarizes core activity, peripherals touched, and any
mapped-but-unmodelled accesses.

Runnable example images and their source live in [examples/](examples/). Build
them with `make -C examples` (or `make -C examples IMAGES='gpio/blink'`).

## Browser workbench

The GUI is an Angular 19 app in `src/interfaces/gui/`. Run the backend RPC
server and the frontend dev server in two terminals:

```sh
# Terminal 1 (repository root)
zig build -j1
zig-out/bin/ra8_emulator serve --listen tcp:127.0.0.1:4567
```

```sh
# Terminal 2 (frontend)
cd src/interfaces/gui
npm ci
npm start
```

Open <http://localhost:4200/connect>, enter `ws://127.0.0.1:4567`, and click
**Connect**. From the debugger page, choose **Open firmware…** → **Browse Local
File…**, select an ARM `.elf` (for example `examples/gpio/blink.elf`) and its
board, and click **Open**.

Optional `serve` flags:
- Pass a startup ELF (`serve --listen tcp:127.0.0.1:4567 examples/gpio/blink.elf`)
  to boot directly into a session.
- Pass `--workspace /abs/path/to/project` to grant connected RPC clients
  read/write access to that directory (and `--build-zig /abs/path/to/zig` to
  enable backend builds).

Frontend scripts (run from `src/interfaces/gui/`):

```sh
npm run build                 # production PWA in dist/ra8-gui/browser/
npm test                      # unit tests
npm run gate                  # frontend source checks
```

## Debugger

```sh
ra8_emulator app.elf --debug                 # interactive terminal debugger
ra8_emulator app.elf --debug-script run.gdb  # replay script and print transcript
ra8_emulator app.elf --gdb 3333              # GDB RSP server (each core is a thread)
ra8_emulator dap 4711 app.elf                # DAP attach on 127.0.0.1:4711
ra8_emulator dap 4711                        # DAP launch (client supplies program)
```

`--cpu1` brings up the second core in terminal and GDB modes (`core 1` selects
it). Ordinary runs also accept `--break-sym`, `--watch`, `--dump-regs`, and
`--dump-mem`.

The DAP listener serves one TCP client and supports instruction-granularity
stepping (`granularity: "instruction"`), DWARF source/instruction breakpoints,
registers, and innermost-frame locals.

For remote or scripted control, `serve` and `ctl` run a session in one process
and drive it from another over TCP or WebSocket. `ra8_emulator` also includes
`targets`, `probe-agent`, `project`, `history`, and `toolchain` subcommands for
hardware-in-the-loop flashing, remote probes, project recipes, replay, and
managed Zig toolchains.

## Zig library

Depend on this repository in `build.zig.zon` and `build.zig` to import `ra8`:

```zig
// build.zig.zon
.dependencies = .{ .ra8_emulator = .{ .path = "../ra8-emulator" } },

// build.zig
const ra8 = b.dependency("ra8_emulator", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ra8", ra8.module("ra8"));
```

Drive a firmware image and inspect its rendered frames from Zig:

```zig
const ra8 = @import("ra8");

var emulator = try ra8.session.harness.open(allocator, io, .{
    .elf_path = "zig-out/image/ra8_ui.elf",
    .input_script = "flows/shell.input",
});
defer emulator.deinit();

const session = emulator.session();
try session.waitSettled(2_000_000_000);
var frame = try session.frame(allocator);
defer frame.deinit(allocator);

try session.tapWidget(allocator, .cpu0, 500_000_000, "settings_button");
try session.tapWidgetPart(allocator, .cpu0, 900_000_000, "shell.tabs", .{ .cell = 2 });
```

`Options.device` defaults to `ra8p1` and `settle_window_ns` defaults to 50 ms.

## Checks and linting

```sh
zig build gate                  # formatting, file/function length, terminology
zig build lint -j1              # Zig style, line width (120 cols), complexity
zig build lint-test -j1         # linter regression tests (requires Python 3.12+)
```

- **Gate**: enforces `zig fmt --check`, max 400 lines per file, max 80 lines per
  function, and inclusive terminology (`tools/terms.zig`).
- **Lint**: enforces named imports, 120-column width, and a per-function
  complexity cap of **branch score 15** and **nesting depth 3**. Each `if`,
  loop, `switch`, or `catch` adds `1 + nesting` (else-if chains stay flat), each
  boolean operator sequence adds 1, and nested functions are scored
  independently. After fixing baselined findings, run
  `zig build lint -- --prune-baseline`.
