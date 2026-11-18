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

## Toolchain planning

The backend executable and firmware compiler are separate installations.
Export the versioned toolchain decision and requirements for a host/target:

```sh
ra8_emulator toolchain plan x86_64-linux ra8d2 --cache-root /private/cache --offline
ra8_emulator toolchain plan x86_64-windows fpb-ra8e1 --backend-zig C:/tools/zig.exe
```

Baseline host plans are `x86_64-linux`, `x86_64-windows`, `aarch64-macos`
and `x86_64-macos`; targets are
`ra8d2`, `ra8p1`, `fpb-ra8e1`, `fpb-ra4t1` and `grove-vision-ai-v2`.
This prints a plan and performs no installation, tool execution or device
operation. An offline plan does not certify an installed compiler or SDK.
The output names pinned Zig archives, full-distribution requirements and
the separate SDK, probe, driver, flash-image and model-tool gates.

`--project-zig` takes precedence over `--backend-zig`, then the proposed
verified managed cache. Explicit paths are absolute for the selected host;
Windows requires a drive or UNC share. Invalid explicit overrides refuse
without fallback. Baseline archive hashes do not authenticate custom tools.
Managed provisioning is separate; physical flashing remains blocked until
the selected target's tools, access and reservation are verified.

The distribution decision and offline/remote limits are recorded in
RA8EMU-A-65. The public clean-toolchain test accepts a pinned archive or an
explicit download and records real firmware-build and DAP source checks:

```sh
python -B tools/toolchain_smoke/run.py --emulator zig-out/bin/ra8_emulator \
  --download --output /tmp/toolchain-proof --timeout 480
```

Append `.exe` on Windows. This test installs only into its fresh evidence
directory; it performs no physical flashing or production provisioning.

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
runs portable DAP on Linux, Windows and macOS and pinned real GDB on Linux, keeping
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

## Backend builds

`serve --workspace DIR --build-zig /absolute/path/to/zig` enables trusted
RPC clients to run Zig builds on the backend host. On Windows pass the
absolute path to `zig.exe`. Build scripts execute with the backend user's
permissions; enable this only for trusted projects and clients. Use the
existing secured remote transport for a server reached from another device.
The compiler is explicitly configured; managed provisioning is separate.

Capability bit 17 advertises `ra8.rpc.build_wire`: start/status/cancel at
`0x0160` through `0x0162`, output/diagnostic events on `0x0181`, and one
completion on `0x0182`. A start supplies an optional step name, a JSON array
of at most 16 `-D` options, an optional output-relative ELF path, and a
100 ms through 600 s deadline. The owning connection can cancel its job;
disconnect terminates the owned process tree and joins its worker.
One job runs per backend, while file and control RPC remain responsive.

Each job gets an exclusive `.ra8-builds/<id>/out` prefix, stdout/stderr logs,
and `result.json`. The result records host, platform, explicit compiler and
reported version, exact arguments, source content revision, exit/cleanup
status, and the selected ELF's SHA256. Only a successful build with matching
before/after workspace content revisions publishes an artifact. This is an
optimistic change check, not an immutable source snapshot. Nothing automatically loads it into Session.
Failed/canceled jobs never fall back to earlier artifacts; previous job
directories remain available. Compilation without artifact selection is
supported by an empty artifact path.

Source hashing covers at most 10,000 regular workspace entries, 32 directory
levels and 256 MiB, rejecting links and special files. `.git`, `.zig-cache`,
`zig-out` and `.ra8-builds` are excluded. External package dependencies are
not sealed by this revision. ELF hashing is capped at 64 MiB. Live output
uses a 64-chunk queue with sequence gaps and an explicit truncation flag;
retained output is capped at 16 MiB, with excess output failing the job.
Diagnostics give workspace-relative file/line/column when available and mark
external paths explicitly. Linux/macOS process groups and Windows job objects
provide cancellation; other host platforms do not advertise this service.

The public real-compiler harness runs on Linux, Windows, and Apple Silicon/Intel macOS CI:

```sh
python -B tools/build_smoke/run.py --emulator zig-out/bin/ra8_emulator \
  --fixture zig-out/bin/debug_conformance.elf --zig /absolute/path/to/zig \
  --output /tmp/build-proof
```

The fresh-source regression builds a dependency-free firmware project in a
new directory and checks absolute source breakpoints and stack paths through
public DAP, including a wrong-directory filename control:

```sh
python -B tools/source_conformance/run.py --emulator zig-out/bin/ra8_emulator \
  --zig /absolute/path/to/zig --output /tmp/source-directory-proof
```

Append `.exe` on Windows. The compiler is explicitly selected; this test
requires Zig 0.17.0 and records the actual compiler, source and ELF hashes.

## Projects and verified debug handoff

Project capability bit 18 is enabled by `serve --workspace DIR`. Project RPC
open/close/build/prepare use `0x0170` through `0x0173`. Open takes a
workspace-relative config filename, build selects a named recipe, and
prepare takes the successful current build ID. Existing build status,
cancel and output events apply to project jobs. While a project is open,
raw build-start requests are refused so they cannot bypass its recipes.
Close or disconnect cancels and joins the project build and restores the
base workspace. The base directory is the authorized boundary; a project's
root is relative to it and never follows descendant links.
Project builds require a regular `build.zig` at that root and pass an
explicit `--build-file`, preventing Zig's implicit search through parents.

A version-one config can contain:

```json
{
  "version": 1,
  "root": "firmware",
  "target": "ra8d2",
  "recipes": [
    {"name": "debug", "artifact": "bin/firmware.elf", "timeout_ms": 300000}
  ],
  "source_mappings": [
    {"host": ".", "client": "C:/client-only/project"}
  ]
}
```

Optional config `compiler` overrides the explicit backend compiler without
PATH discovery or fallback after an invalid override. A recipe can also
specify `step` and `options`, the latter a JSON-encoded array of at most
16 `-D` arguments, as in the build wire contract. Configs are bounded to
64 KiB, 16 recipes and 16 source mappings. Unknown versions, targets,
duplicate recipes/mappings and escaping paths are refused.

Prepare retains `.ra8-builds/<id>/project.json` beside the original result.
The receipt binds config SHA256, target, recipe, build ID, compiler/version,
source revision and exact ELF SHA256. Failed, canceled or active builds
cannot prepare a receipt or substitute an older selection. Loading verifies
the paired original successful result, recipe arguments, current config,
source and actual ELF bytes before Session receives them. Explicitly
loading an earlier receipt in a newly opened project still requires the
matching config and sources. Receipts are provenance records in the trusted
workspace, not signed attestations for untrusted files.

The local CLI calls the same host API without an RPC roundtrip:

```sh
ra8_emulator project build /server/workspace project.json debug --zig /absolute/path/to/zig
ra8_emulator project dap 0 /server/workspace project.json --zig /absolute/path/to/zig
```

Build prints the relative receipt path and ID as JSON. The second command
opens a loopback DAP listener; launch supplies that receipt path as
`program`, relative to the configured project root. The application or
remote host controller owns this DAP process. Source breakpoints and stack
paths translate between configured client and server prefixes. Missing,
changed or unmapped sources produce explicit errors, without presenting an
older file as current. Source revisions remain optimistic content checks,
with the build service's limits and dependency exclusions above. Rebuilds
use distinct artifacts; disconnect and relaunch against the chosen receipt
to reload Session. Existing plain `dap` behavior and locals availability
are preserved.

Targets describe build profiles. Project DAP currently accepts `ra8d2`;
other profiles return `UnsupportedProjectDebugTarget` until their machine
profiles are implemented. Compiler/SDK provisioning and physical flashing
are separate services. This adds no frontend or editor UI.

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

Backend code-quality checks run with `zig build lint -j1`; their regression
tests run with `zig build lint-test -j1`. They require Python 3.12 or newer
(`-Dpython=PATH` selects an interpreter). The immutable zlinter package is
resolved only by lint commands, so ordinary builds need no linter download.

The lint scope is `src/`, `tools/`, and `build.zig`.
The backend rules enforce named imports, a blank line after each import
group, alphabetical import chunks, braces on loops and multiline branches,
unused declarations, swallowed errors, and a 120-column limit. Columns count
Unicode code points, including comments and literals. GUI/render source and
the GUI smoke helper are excluded; third-party packages are outside the scope.

The custom complexity rule limits each function to a branch score of 15 and
nesting depth of 3. Each `if`, loop, `switch`, or `catch` adds one plus its
branch nesting; else-if chains stay flat. Each boolean operator sequence
adds one. Switch arms do not count individually, and nested functions are
measured independently. This is a documented branch metric, not an exact
implementation of Detekt or Sonar cognitive complexity. The separate gate
continues to enforce 400-line files and 80-line functions.

The style rules have no baseline allowances. Remaining legacy complexity
and ignored-error findings are counted in `tools/lint/baseline.json`. Fingerprints
include source and diagnostic text: moving code cannot hide a finding,
duplicating it uses another allowance, and increasing a complexity score
fails. Syntax and analysis errors cannot be baselined. A changed finding,
including an improved score still above the limit, requires reviewing its
new fingerprint. After removing findings, run
`zig build lint -- --prune-baseline`; this command refuses new debt.
`--update-baseline` accepts debt and requires explicit review of the diff.

## Session bundle writer

`ra8.snapshot.bundle.writer.Writer` packs a frozen session into a standalone
USTAR archive without allocating or buffering its payloads. `init` writes
`manifest.json`, `state.ra8snap`, and, when recording is enabled,
`recording/root.bin` and `recording/branches.bin`. The state uses the existing
snapshot format unchanged. Its magic and current version are checked before
any archive bytes are written; the caller supplies a reader buffer of at
least 12 bytes. Import performs the full state and recording validation.

The JSON manifest identifies `ra8-session-bundle` version 1, the snapshot
version, board label, primary/optional secondary ELF name, byte length and
16-byte BLAKE3 identity (32 lowercase hexadecimal characters), and whether
recording is present.
Names and board labels are nonempty UTF-8 strings of at most 256 bytes.
This descriptive metadata must come from the same frozen session as the
payloads; the format writer cannot establish that relationship itself.

For recordings, call `add(.log, leaf, source)` and
`add(.objects, leaf, source)` for all committed log segments and referenced
object files, including pack data and indexes. Supply entries in strictly
increasing archive-path order: log entries first, then objects. At least one
log entry is required; an empty segment is allowed. Files may be opened and
closed one at a time. Leaves are at most 96 ASCII letters, digits, dots,
dashes or underscores, excluding `.` and `..`. Paths, links, ownership locks,
lifecycle markers and scratch files do not belong in the bundle.

Each source supplies a reader and exact byte length, at most 8 GiB minus one
byte per file (USTAR's numeric limit). Entries use mode 0600 and timestamp
zero; `finish` appends two zero blocks. Short reads and I/O failures propagate
and prevent completion. After any `add` or `finish` error, discard the partial
output. The caller owns source consistency, output flushing and atomic
publication. CLI/RPC export/import verbs remain separate follow-on work.


`ra8.snapshot.bundle.reader.Reader` admits the same format as a bounded
stream. Its manifest fields are required; unknown bundle/snapshot versions,
duplicate JSON fields, unsafe or duplicate paths, unsupported tar entry
kinds, bad checksums, nonzero padding, missing payloads/footer and trailing
content fail admission. Standard USTAR zero record padding is accepted within
the byte budget. Consume each entry with `copy` or `readAlloc` before
calling `next`. An error poisons the reader. Default limits are 4 GiB total
(including headers and footer), 1 GiB per entry and 4096 entries; callers can
supply stricter limits.

`ra8.rpc.bundle_import.open` returns a separate, owned `*Served` ready for an
application to publish. It never receives or changes the live session.
Snapshot-only imports require the original ELF bytes and a matching board
profile. Recording imports require a host history root: they create a fresh
leased session, stream recording files into it, and use the recorded profile
and embedded ELF images. The lease transfers into the restored server without
being released. A failed import removes only that private session. Destroy a
successful import with `deinit` followed by the supplied allocator's `destroy`.

Admission checks snapshot section bounds/duplicates, model/build provenance,
image identities, branch tables, complete log frames, checkpoint snapshots,
optional derived checkpoint sidecars, and required referenced objects. Pack
indexes are validated before ordinary store recovery can repair them; pack
records and their declared expansion are bounded and verified. Recording
admission additionally caps each log at 64 MiB, other files at 256 MiB, roots
at 64 MiB, branch tables at 8 MiB, branches/checkpoints at 4096, and total pack
expansion at the reader's total-byte limit. Existing snapshot preparation
validates machine semantics before restoring the private machine. The saved
active line and scheduler position must fit the recording; future writes use
a fresh segment, preserving every imported segment.


### Headless target inventory

`serve --targets FILE --listen tcp:127.0.0.1:PORT firmware.elf` enables
operator-owned target bindings. FILE is a JSON array, for example:

```json
[
  {
    "kind": "emulator",
    "target": {
      "host_id": "backend-a",
      "probe_id": "virtual-a",
      "board_id": "emulator-a",
      "managed": false,
      "identity_verified": true,
      "vendor": "Renesas",
      "model": "RA8D2 emulation",
      "cores": "configured CPU0 M85; CPU1 M33 only with --cpu1",
      "transport": "in-process"
    }
  }
]
```

`ctl --connect tcp:127.0.0.1:PORT targets list` returns JSON descriptors,
registration generations, connection state, dynamically resolved `uart` port
and reservation state. Host, probe and board IDs are explicit operator
identities, never list positions, COM port numbers or shared USB VID/PID pairs.
Four binding kinds are supported:

- `"kind":"emulator"` (`"transport":"in-process"`): in-process CPU0 registers,
  halt and step.
- `"kind":"rsp"` (`"transport":"rsp"`, `"host"`, `"port"`): operator-pinned RSP
  endpoint for registers, halt, step and resume; starts `configured`.
- `"kind":"jlink"` (`"transport":"jlink-usb"`, `"program"`, `"scratch"`,
  `"device"`, `"cpuid"`, optional `"uart_wired"` defaulting to `true`, and
  `target.probe_serial`): physical USB J-Link discovery via `ShowEmuList USB`
  keyed strictly by probe serial, resolving the CDC `uart` port from the USB
  serial at scan time (Windows composite parent DevNode, Linux
  `/dev/serial/by-id`), acquiring an exclusive host-wide OS file lock
  (`<scratch>/jlink-<serial>.lease`) with a persisted monotonic fencing token
  across processes, and verifying both probe serial and `SCB.CPUID`
  (`0xE000ED00`) before registers, halt, step, resume, reset or `uart`.
  Hotplug, unplug or UART renumbering advances `generation` and drops active
  leases. `uart` names the probe's own USB CDC interface only; it is not
  evidence that the board routes that port to the target MCU (for example,
  `FPB-RA4T1` exposes OB CDC with VCOM unrouted on the PCB, so set
  `"uart_wired":false` to withhold `capabilities.uart` and refuse `uart` with
  `0x195`). When `uart_wired` is true on Linux or Windows, `reset` pre-opens
  the serial-resolved CDC port at 115200 8N1 so boot output from reset release
  is buffered for a subsequent bounded `uart` read, while unconditionally
  refusing host console ports (`COM1`, `COM3`, `COM9`). The CPUID check and
  the requested action run in two Commander sessions, both selected by
  `-USB SERIAL`. The probe serial is checked again after the action session,
  so a probe swapped between the two sessions would be reported only after the
  action ran. J-Link's own `-USB` selection is what keeps that window closed
  in practice.
- `"kind":"agent"`: authenticated link (`RA8PH2`) to `ra8_emulator probe-agent`,
  mirroring remote target presence, streaming bounded progress frames
  (`chunk:true`), forwarding claims/actions and calling
  `Registry.disconnect(host_id)` on agent loss. Two carriers are supported:
  - TCP (`"host"`, `"port"`, `"secret_file"`): connects to
    `probe-agent --targets FILE --secret-file KEY --host-id ID --listen tcp:HOST:PORT`
    over loopback or an `ssh -R` reverse tunnel (for a laptop-attached probe
    reaching a remote build/session server).
  - Host profile (`"profile"`, `"hosts_file"`, `"remote_targets"`,
    `"secret_file"`, optional `"remote_secret_file"`): spawns
    `probe-agent --targets ... --secret-file ... --host-id ID --stdio` over a
    named `ra8_host.profiles` `local` or `ssh` entry.
  Both ends prove the shared 256-bit key and exact `host_id` with HMAC-SHA256
  over fresh nonces (`RA8PH2`), derive directional session keys (`c2a` /
  `a2c`), and sign every subsequent request, streamed chunk and reply as
  `SEQ MAC_HEX64 JSON` with a strictly monotonic sequence counter to reject
  injection, tampering and replay. Frames are authenticated cleartext JSON, not
  encrypted; use loopback or SSH when payload confidentiality is required.

`ra8_emulator probe-agent --matrix` prints the machine-readable OS, probe,
placement and transport support matrix (`ra8_host.probe_host.matrix`). It keeps
`ra8_usbip` (emulated USB device export from the simulator) distinct from
physical probe attachment: physical `usbip_vhci` applies only when both probe
host and server run Linux with `vhci_hcd` available, automatically falling back
to `native_local` (same host) or `native_agent` (cross-host, including Windows
and macOS where `vhci_hcd` does not exist), while `bootloader_serial` targets
without SWD are reported explicitly as unsupported.

Configuration cannot enable build, flash or NPU execution. Separate capability
booleans (`emulation`, `hardware_debug`, `uart`) and `operations` report what
each provider implements.

Select with the complete identity and generation returned by list:

```sh
ra8_emulator ctl --connect tcp:127.0.0.1:PORT targets use backend-a virtual-a emulator-a GENERATION - registers step
```

`use` reserves exactly one target for that connection, runs its ordered
operations, then releases it. Disconnect also releases it, including failed
operations. RPC methods 0x190 through 0x193 expose list, reserve, release and
perform for clients that keep a connection open. The capability bit is 21.
Owners are server-side connection contexts, never client-supplied IDs.
Reservations share the host registry. Embedders must serialize registry calls
and hold descriptor/provider storage until removal. Provider errors fence the
binding as disconnected and clear its reservation; stale generations and stale
lease tokens both return `0x191`.

Two different mechanisms protect ownership:
- Across processes on one host, a `jlink` binding takes an exclusive OS file
  lock on `<scratch>/jlink-<serial>.lease`. The file also holds a persisted
  counter that advances on every acquisition. The provider admits an
  operation only with a token at least as new as the newest it has seen.
- Over an agent link, `probe-agent` gives each peer connection a claim token
  and refuses `perform` or `release` carrying any other token. A peer that
  disconnects loses its reservation at once. The persisted J-Link lease
  above is what fences the probe itself.

If physical identity is unavailable, keep `identity_verified` false and set
an operator-verified `disambiguation` binding; clients must supply that exact
string instead of `-`. This is a manual mapping, not proof from RSP: generic
RSP cannot verify probe or board serials or detect a physical swap behind a
still-running GDB server, so pin the endpoint to the identified board and do
not reuse it after hotplug without re-registering. Duplicate board IDs,
host/probe pairs, J-Link serials and conflicting RSP/agent endpoints are
refused. DNS aliases of one endpoint are not detected as duplicates.

`managed` is mandatory. Without an attached `Registry.custodian`, managed RA8CI
targets can be listed but reservation and operations fail closed with
custodian-unavailable (`0x196`); live RA8CI bench custodian integration is
tracked separately. `serve` and `ctl` targets add no network authentication
or encryption of their own: use the existing trusted listener or SSH host
boundary. Target bindings cannot be combined with artifact-session
replacement.

Managed Zig setup uses `ra8_emulator toolchain setup HOST TARGET --cache-root ABS --download`,
or `--archive ABS --offline` for an offline kit. `toolchain doctor HOST TARGET --cache-root ABS --offline`
checks an installation. Builds select it with `project build ... --toolchain-cache ABS` or
`serve --workspace DIR --build-toolchain-cache ABS`; builds never install or download a compiler.

Runnable images and their source are in [examples/](examples/). Build them with
`make -C examples`, or use `IMAGES='gpio/blink'` to select one. Firmware examples
use `make -C examples firmware APP=uart FW=/path/to/ra8-firmware ARM_BIN=/path/to/arm-gnu/bin`.
