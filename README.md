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
ra8_emulator dap 4711 app.elf               # DAP attach on 127.0.0.1:4711
ra8_emulator dap 4711                       # DAP launch supplies program
```

`--cpu1` brings up the second core in the terminal and GDB modes, and
`core 1` selects it.
The DAP listener serves one TCP client, then exits on disconnect or EOF.
Configure an editor's DAP client to connect to that port with `request:
"attach"`, or use `request: "launch"` and `program: "/path/to/app.elf"`
without a preloaded image. `stopOnEntry` defaults to true. Send
`configurationDone` after setting breakpoints. Source breakpoints use the
ELF's DWARF paths. Instruction breakpoints take hexadecimal address strings.
Stepping is at instruction granularity, with call-aware `next` and
`stepOut`. Clients must request `granularity: "instruction"`; omitted
granularity and source-level stepping are explicitly refused.
Registers and supported DWARF locals are read at the innermost frame.
Unavailable local locations and caller scopes are left unavailable.
Conditional/log breakpoints, expression evaluation, URI source paths and
reverse execution are unsupported. This adapter does not enable history
recording. The listener uses Session directly and does not connect to a
separate `serve` process. Editor-specific extension packaging is separate.
An ordinary run takes breakpoints and dumps too: `--break-sym`, `--watch`,
`--dump-regs` and `--dump-mem`. A `-Dgui` build adds a second executable, `ra8_gui`:
`ra8_gui <elf>` opens the windowed debugger on the image, with its session
in the same process. `ra8_gui cpu0.elf --cpu1 cpu1.elf` loads CPU0/M85 and
CPU1/M33 before recording begins. View > Device Metrics shows each core's
load and stack state; click its core label to switch, or open two panes.
RAM figures are shared across both cores. View > Host Metrics monitors the
host process. The image opens halted; Run, Pause and Step on the
time bar along the foot of the window run it, and the field beside them
takes a speed (`0.5`, `2`, `max`). The board leaf shows the board with its
LEDs; SW1, SW2 and the panel take clicks. Cmd+O (Ctrl+O on Windows and
Linux) picks another image in the OS's own file dialog, and it opens halted
the same way. `serve` and `ctl` run a
session in one process and drive it from another, locally or over TCP.

## Debugger conformance

Build the emulator and deterministic firmware separately before running the
public-client checks. These commands use Python 3.12 and a real
`gdb-multiarch` (or an explicit path to `arm-none-eabi-gdb`). On Windows,
append `.exe` to the emulator path and run the shell commands in Git Bash.

```sh
zig build -j1
zig build debug-fixtures -j1
proof=$(mktemp -d)
python -B tools/gdb_conformance/oracle.py \
  --fixture zig-out/bin/debug_conformance.elf \
  --fault-fixture zig-out/bin/debug_fault.elf \
  --cpu1-fixture zig-out/bin/debug_cpu1.elf --peripheral-fixture zig-out/bin/debug_peripheral.elf \
  --output "$proof/oracle.json"
python -B tools/dap_conformance/run.py --emulator zig-out/bin/ra8_emulator \
  --fixture zig-out/bin/debug_conformance.elf --fault-fixture zig-out/bin/debug_fault.elf \
  --oracle "$proof/oracle.json" --output "$proof/dap"
bash tools/gdb_batch.sh --conformance --emulator zig-out/bin/ra8_emulator \
  --fixture zig-out/bin/debug_conformance.elf --fault-fixture zig-out/bin/debug_fault.elf \
  --cpu1-fixture zig-out/bin/debug_cpu1.elf --peripheral-fixture zig-out/bin/debug_peripheral.elf \
  --oracle "$proof/oracle.json" \
  --output "$proof/gdb" --gdb gdb-multiarch
```

The independent ELF oracle binds assertions to fixture bytes, exported
instruction labels, DWARF source rows and known values. Each driver starts
fresh emulator processes, records bounded expected-versus-actual checks and
sanitized transcripts, and writes a terminal `result.json`. The DAP driver
checks launch/attach, breakpoints, calls across execution slices, inspection,
pause, framing errors and connection loss. The existing GDB batch entry
point also checks real-GDB memory access, call frames and CPU1. Unsupported
combinations are recorded explicitly. The `debug-conformance` CI workflow
runs portable DAP on Linux and Windows and pinned real GDB on Linux, keeping
its transcripts as artifacts.

The separate editor harness uses VS Code's native debug client in an
isolated extension host and Neovim's real `nvim-dap` client. It preserves
normal editor settings and requires an explicit native VS Code executable
and a checkout of `nvim-dap` at the revision its runner checks:

```sh
python -B tools/editor_conformance/run.py --emulator zig-out/bin/ra8_emulator \
  --fixture zig-out/bin/debug_conformance.elf --oracle "$proof/oracle.json" \
  --editor both --code /path/to/Code --nvim-dap /path/to/nvim-dap \
  --output "$proof/editors"
```

Editor results identify extension-host/headless automation and set
`manual_ui_verified` to false. Human UI acceptance is recorded separately
from these reproducible client checks.

## Workspace filesystem

An explicit workspace root enables the backend file service for connected
RPC clients. The root stays open for the lifetime of `serve`:

```sh
ra8_emulator serve --workspace /path/to/project --listen tcp::0 firmware.elf
```

Without `--workspace`, file methods refuse and capability bit 16 is absent.
The typed contract is `ra8.rpc.workspace_wire`: methods `0x0140`–`0x0145`
list, stat, read, write, watch and unwatch. Listing returns a bounded page of
JSON name/kind entries; read supports byte offsets. Paths are relative to
the selected root, accept slash or backslash separators, and refuse parent
traversal, absolute paths, alternate streams and descendant symlinks.
This grants trusted connected clients read/write access within that root.

Stat and read supply a version containing file kind, size, modification
time and identity. `encodeVersion` makes the 25-byte token a write request
must return; `decodeVersion` reads tokens in read/change replies. A missing
version means exclusive creation. Existing-file saves check the version,
stage and sync a sibling file, recheck, then atomically replace. Stale saves
refuse without truncating the original. Advisory locks coordinate cooperating
writers; this is optimistic conflict detection, not a transaction against
external programs that ignore locks or deliberately preserve metadata.

Limits are 4096 path bytes, 256 KiB per read/write, 64 entries per listing
page and an offset of at most 65,536 entries. Each connection can watch eight
paths. Watches reconcile one path every 100 ms and send `Change` events on
topic `0x0180`; directory watches inspect at most 1024 direct children,
including metadata changes to existing children. They coalesce changes and
are nonrecursive. A directory that exceeds the bound refuses registration;
later observation failures emit `unavailable` and release the watch.
Unwatch/disconnect clears the connection's watches; stale IDs are refused.
File size, time and identity changes are observed; edits preserving all
those metadata fields are outside this polling contract.

The public-client smoke test builds no code and records assertions, protocol
transcripts and owned-process cleanup in a fresh evidence directory:

```sh
python -B tools/workspace_smoke/run.py --emulator zig-out/bin/ra8_emulator \
  --fixture tests/fixtures/uart/uart_irq_echo.elf --output /tmp/workspace-proof
```

Append `.exe` on Windows. `--require-native-links` requires native final-file
and ancestor-link containment proof; Linux CI enables it. Windows records
unavailable symlink privileges separately and still tests a native directory
junction. Both platforms run the public-client check in CI.

## Rebuilt-ELF replay

`ra8_emulator history --root DIR replay-elf SESSION --elf REBUILT.elf [--json]`
opens the history read-only. Exit 0 requires at least one matching root-line
checkpoint, exit 3 reports the first divergence, and exit 1 reports an error
such as `NoRootCheckpoints`, `BuildMismatch`, `ModelMismatch`, or an
`UnsupportedRoot...` configuration. Only the ELF identity is overridden.
The recorded Git commit, source/compiler/dependency-manifest fingerprint,
snapshot version and original snapshot image identity must remain valid.
Historical roots with zero commit or placeholder metadata remain decodable,
but cannot authorize this comparison and are never rewritten.

Replay applies the recorded board-profile text through the existing profile
parser. It currently supports the served RA8P1 defaults: virtual RTC pace,
default RTC start, idle skip, gradient initial camera, and no additional root
memory/grid/attach/fault/input/vsync/loop-skip configuration. Other root
settings are rejected before image loading or replay host preparation.
Single- and dual-core root-line checkpoints at round openings are compared.
CPU0 uses the rebuilt ELF; CPU1 uses its recorded root bytes offline, with
both image identities checked before rebuilt-image or host preparation.
The normal scheduler preserves CPU1 reset hold and firmware release. Both
cores' registers, private/shared memory and board state are compared;
divergence PCs and symbols belong to the reported core. Branch-line replay
and a rebuilt CPU1 image remain unsupported. Unmutated CPU0 ELF-loaded
read-only bytes and load-time copies may differ between builds, while any
post-load guest writes to those addresses (including RAM-resident code,
constants, load-copy sources, and OSPI NOR flash programming) are checked.
CPU1 memory has no image exclusions. Plain CLI `--camera-source` runs
through Session history (refusing unrecordable raw-board flag combinations).
Served dual recordings must supply
both images at creation (`serve --cpu1`, or `Served.openInitial`); attaching
CPU1 after a history root is frozen fails with `HistoryAlreadyRooted`.
Existing histories are never upgraded or rewritten to add CPU1.

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
