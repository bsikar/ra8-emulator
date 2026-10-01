<!--
Copyright (c) 2026 Brighton Sikarskie
SPDX-License-Identifier: MIT
-->

# ra8_emulator

Boots the **real, unmodified firmware `.elf`**, the same image that flashes to
an EK-RA8D2, on emulated Cortex-M cores over a modelled RA8 peripheral space.
It runs the actual cross-compiled binary through the genuine bring-up path, so
a pass here means the flashed firmware drove the hardware the way the
silicon expects. The RA8P1 has no board on the bench, so for that part this
emulator is the only way its firmware gets proven.

The emulator is written in Zig. Unicorn (the CPU) and Capstone (error-path
disassembly) are still linked today, and are being replaced by our own Zig
Armv8-M core (see [Where it is going](#where-it-is-going)).

## Building

```sh
zig build                       # the binary into zig-out/bin
zig build test                  # the unit tests, rooted at tests/all.zig
zig build gate                  # zig fmt --check plus the file/function length checks
./zig-out/bin/ra8_emulator path/to/app.elf
```

Run the binary with no arguments and it prints every option it takes.

### Toolchain

Zig **0.14.1**, matching `ARG ZIG_VERSION` in ra8-firmware's
`.devcontainer/Dockerfile`. It is the only compiler needed: Zig carries its own
clang for the two C libraries below.

```sh
# linux x86_64; swap the triple for aarch64-linux, x86_64-macos or aarch64-macos
curl -fsSLO https://ziglang.org/download/0.14.1/zig-x86_64-linux-0.14.1.tar.xz
sha256sum zig-x86_64-linux-0.14.1.tar.xz
# 24aeeec8af16c381934a6cd7d95c807a8cb2cf7df9fa40d359aa884195c4716c
tar xf zig-x86_64-linux-0.14.1.tar.xz -C "$HOME/.local"
export PATH="$HOME/.local/zig-x86_64-linux-0.14.1:$PATH"
```

A different Zig is not supported: the build graph uses 0.14 APIs and 0.15
renamed several of them.

### Unicorn and Capstone (until the Zig core replaces them)

```sh
sudo apt install libunicorn-dev libcapstone-dev      # Debian, Ubuntu
zig build -Ddeps-prefix="$HOME/.local/unicorn"       # or point at your own prefix
```

`-Ddeps-prefix` adds that prefix's `include/`, `lib/` and an rpath. Unicorn's
decode of Armv8.1-M differs between releases, so the version is pinned: the
pin lives in ra8-firmware's `docs/TOOLCHAIN.md`.

## Running

```sh
ra8_emulator app.elf --part ra8p1            # RA8D2 is the default part
ra8_emulator app.elf --cpu1 cpu1.elf         # run both cores
ra8_emulator app.elf --instructions 50000000 --ms 2000
```

The end-of-run report covers the run, the cores, every peripheral the image
touched, and anything it reached that is mapped but not modelled.

Debugging today is a set of flags rather than an interactive debugger:
`--break-sym` and `--break-at` (with arrival counts), `--watch`,
`--dump-regs`, `--dump-mem`, `--dump-sym`, `--count-pc`, `--taken-in`,
`--stop-sym`, `--stop-on-undefined`, `--trace-sd` and `--dump-sd`. A real
debugger is on the way (below).

## What is modelled

**Cores.** CPU0 is the Cortex-M85 and CPU1 the Cortex-M33, sharing one bus and
interleaved round robin at the chunk boundary. Unicorn tops out at Armv8.0-M,
so the Armv8.1-M instructions the firmware actually uses are hand-stepped off
the invalid-instruction hook: DLS/WLS/LE (`src/core/lob.zig`), the CSEL family
(`src/core/csel.zig`) and BLXNS (`src/core/tz.zig`). SAU registers are recorded
but attribution is not enforced yet, and the MPU enforces read-only regions
only.

**Parts.** The RA8P1 shares the RA8D2's register and memory maps; selecting it
adds the Ethos-U55 window. The NPU model runs the driver's real submit, run,
poll and read-output protocol against a documented stand-in program
(`src/periph/npu/`), not real Vela inference.

**Peripherals.** Register-accurate models, one directory per block under
`src/periph/`: clocks and PLLs, ICU and NVIC, GPT, AGT, ULPT, RTC, WDT and
IWDT, SCI, SPI, RIIC, I3C, CANFD, ADC, DAC, DMAC and DTC, ELC, GLCDC, DRW,
MIPI, the e-ink panel path, SDHI and the SD card, XSPI, MRAM, caches, Ethernet,
USBHS, SSIE, IPC between the cores, and more. A sparse fallback covers whatever
is not modelled: control writes read back, and a register polled past a
threshold alternates all-zeros and all-ones so a ready-bit poll falls through
instead of hanging. `src/board/` wires the blocks to what the EK-RA8D2 carries.

**Memory.** SRAM, SDRAM and OSPI live in host-owned apertures, with the Secure
window and its Non-secure alias mapped onto the same pages, so Secure and
Non-secure, CPU0 and CPU1 stay coherent with no write hook in the store path.

## Where it is going

All work is focused on making the emulator complete, in four parallel tracks:

- **Our own Zig CPU core.** One Armv8-M decoder and executor behind
  `src/core/engine.zig`, run in lockstep against Unicorn on every example image
  until there is zero divergence, then Unicorn and Capstone are removed
  entirely.
- **Cortex-M85 and Cortex-M33, complete.** FPv5, MVE (Helium), tail
  predication, PACBTI and stack limits on CPU0; CPU1 with its own NVIC,
  SysTick, MPU and SCB; TrustZone enforced on both, and the full fault model.
- **A debugger.** One debug core with a scriptable command layer and a GDB
  remote stub, plus DWT, FPB and ITM, and backtraces from DWARF.
- **ThreadX Modules and the RA8P1.** Module isolation proven end to end in the
  emulator, the RA8P1 modelled from its hardware manual, and the Ethos-U55
  running real command streams.

## Where the code lives

```
src/main.zig          the program: argument in, run, report out
src/root.zig          the module index, imported as "ra8"
src/core/             the machine: engine, memmap, elf, session, run loop,
                      the second core, and src/core/c.zig (the only @cImport)
src/debug/            breakpoints, watchpoints, disassembly, symbols, dumps
src/interfaces/cli/   the command line and the report renderers
src/board/            how the board is wired
src/periph/           everything that answers on the peripheral bus
tests/                one test file per source file, on the mirrored path
tools/gate.zig        the light build gate (file and function length)
tools/eil_set.sh      re-derives the EIL app set from a ra8-firmware tree
tools/lockstep_corpus.sh  runs a directory of ELFs under --cpu lockstep, one table
docs/                 notes: EIL parity, a GCC miscompile, a ThreadX caller error
```

`AGENTS.md` carries the conventions in full: one file one purpose, short files
and functions, idiomatic Zig, and tests in `tests/`, never inline.

## What it is for

It validates whether the firmware drives each controller correctly, not
silicon timing, and where the emulator and the silicon disagree the emulator is
what gets fixed. Running the real binary far longer than a bench run is how it
earns its keep: it has caught a module-stop reference leak that only faults
after a counter saturates, and USB demos silently stalling because their memory
pool could not satisfy a class's cache-safe buffer.
