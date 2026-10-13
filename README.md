<!--
Copyright (c) 2026 Brighton Sikarskie
SPDX-License-Identifier: MIT
-->

# ra8_emulator

Runs the real, unmodified firmware `.elf` (the same image that flashes to an
EK-RA8D2) on emulated Cortex-M85 and Cortex-M33 cores over a modelled RA8
peripheral space. A pass here means the flashed firmware drove the hardware
the way the silicon expects. For the RA8P1, which has no board on the bench,
this is how its firmware gets proven.

It is three things in one repository: an emulator you run from the command
line, a debugger for the firmware it runs, and a Zig library other programs
embed. Everything is Zig, the CPU core and disassembler included, and no C
library is linked beyond libc.

## Install

Zig **0.17.0** is the only compiler needed.

```sh
# linux x86_64; swap the triple for aarch64-linux, x86_64-macos or aarch64-macos
curl -fsSLO https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz
sha256sum zig-x86_64-linux-0.17.0.tar.xz
# 1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
tar xf zig-x86_64-linux-0.17.0.tar.xz -C "$HOME/.local"
export PATH="$HOME/.local/zig-x86_64-linux-0.17.0:$PATH"
```

```sh
zig build                       # zig-out/bin/ra8_emulator
zig build -Dgui                 # also the windowed debugger (fetches SDL3)
zig build gate                  # zig fmt --check, file and function length, terms
```

Run each merge-gate command separately. Build one suite at a time, then run
its installed binary directly so compilation and execution have separate
command budgets:

```sh
zig build ra8_tests -j1 -Dtest-filter=chip.periph.crc_test
zig build ra8_host_tests-exe -j1
bash tools/test_batch.sh zig-out/bin/ra8_host_tests /tmp/ra8-host-tests.log
zig build ra8_tests-exe -j1
bash tools/test_batch.sh zig-out/bin/ra8_tests /tmp/ra8-core-tests.log
zig build ra8_gui_link_tests-exe -j1
bash tools/test_batch.sh zig-out/bin/ra8_gui_link_tests /tmp/ra8-link-tests.log
zig build consumer-smoke -j1
bash tests/tools/test_batch_test.sh
```

Repeat the targeted command for each changed file, using `ra8_host_tests`
for host tests. `-Dtest-filter=TEXT` matches the qualified test name: replace
the mirrored path's slashes with dots and omit `tests/` and `.zig`. Keep the
existing suite roots so sibling helpers and embedded fixtures stay within
Zig's module boundary. Unnamed import tests also run. Omit the filter from
full-suite builds. Use the corresponding `-exe` step to separate compilation
from execution for a larger target. `test-exe` remains available to install
all three suites, including cross builds. Never use the combined
`zig build test -j1` as a merge gate.

Run Linux suites from a Linux filesystem, including under WSL: the socket
fixtures need Unix filesystem semantics. The Bash runner needs GNU `timeout`
(Linux or WSL). It caps virtual memory
at 3,000,000 KiB and execution at 800 seconds, with five seconds to terminate
the process. `RA8_TEST_TIMEOUT_SECONDS` can lower that timeout. Every attempt
appends `START` and `COMPLETE`, `FAILED`, or `CUT` to its log and preserves
the exit status. Rerun a cut suite from its start with the same log path.
An attempt missing a terminal marker is incomplete. Earlier passes never
stand in for the latest attempt or a changed checkout. On Windows, installed
binaries have an `.exe` suffix and can run natively, but this Bash memory and
timeout policy requires a Linux build under WSL.

Keep the corpus golden comparisons (`tools/dualcore_corpus.sh`,
`tools/modules_corpus.sh`, `tools/fault_corpus.sh`, and `tools/plug_corpus.sh`)
as separate commands against the firmware images. A complete merge gate
includes those comparisons and the public consumer smoke test, as well as
the unit suites. Run a full batched sweep on the latest `main` at least once
per 90-minute monitor window. A failed or incomplete sweep blocks merges
until triaged or completed.

## Emulator

```sh
ra8_emulator app.elf                         # RA8D2 is the default part
ra8_emulator app.elf --part ra8p1            # the RA8P1, with its NPU
ra8_emulator app.elf --cpu1 cpu1.elf         # run both cores
ra8_emulator app.elf --ms 2000 --frame-out panel.png
```

The end-of-run report covers the cores, every peripheral the image touched,
and anything it reached that is mapped but not modelled. Run it with no
arguments to list every option.

## Debugger

```sh
ra8_emulator app.elf --debug                 # interactive, at the terminal
ra8_emulator app.elf --debug-script run.gdb  # play a script, print the transcript
ra8_emulator app.elf --gdb 3333              # serve gdb, each core a thread
```

`--cpu1` brings up the second core in any of them, and `core 1` selects it.
An ordinary run takes breakpoints and dumps too: `--break-sym`, `--watch`,
`--dump-regs` and `--dump-mem`. A `-Dgui` build adds a second executable, `ra8_gui`:
`ra8_gui <elf>` opens the windowed debugger on the image, with its session
in the same process. The image opens halted; Run, Pause and Step on the
time bar along the foot of the window run it, and the field beside them
takes a speed (`0.5`, `2`, `max`). The board leaf shows the board with its
LEDs; SW1, SW2 and the panel take clicks. Cmd+O (Ctrl+O on Windows and
Linux) picks another image in the OS's own file dialog, and it opens halted
the same way. `serve` and `ctl` run a
session in one process and drive it from another, locally or over TCP.

## Library

Zig packages can depend on this repository and import its `ra8` module:

```zig
// build.zig.zon
.dependencies = .{ .ra8_emulator = .{ .path = "../ra8-emulator" } },

// build.zig
const ra8 = b.dependency("ra8_emulator", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ra8", ra8.module("ra8"));
```

The harness owns the ELF bytes, CPU0, the board and the display wiring:

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
```

Taps aim at widgets the firmware publishes on ra8_widget's debug tree, by name,
and can target one part of a widget: a cell of a segmented control or nav bar,
a list row, a pager's previous or next control, or a point inside it:

```zig
try session.tapWidget(allocator, .cpu0, 500_000_000, "settings_button");
try session.tapWidgetPart(allocator, .cpu0, 900_000_000, "shell.tabs", .{ .cell = 2 });
try session.tapWidgetPart(allocator, .cpu0, 1_300_000_000, "apps.list", .{ .row = 0 });
try session.tapWidgetPart(allocator, .cpu0, 1_700_000_000, "chrome.bars.pager", .next);
```

`Options.device` defaults to `ra8p1`; `settle_window_ns` defaults to 50 ms.
Frames are native panel-resolution grayscale bytes owned by the caller.
