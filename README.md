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

Everything is Zig, the CPU core and disassembler included. No C library is
linked beyond libc.

## Build

Needs Zig **0.17.0** and nothing else.

```sh
zig build                       # zig-out/bin/ra8_emulator
zig build test                  # unit tests
zig build gate                  # zig fmt --check, file and function length, terms
```

Linux builds as is. macOS and Windows notes are in the Platforms article in
the knowledge base (RA8EMU-A-9).

## Run

```sh
ra8_emulator app.elf                         # RA8D2 is the default part
ra8_emulator app.elf --part ra8p1
ra8_emulator app.elf --cpu1 cpu1.elf         # run both cores
```

Run it with no arguments to list every option. The end-of-run report covers
the cores, every peripheral the image touched, and anything it reached that is
mapped but not modelled.

## More

Design docs, ADRs and engineering notes live in the project knowledge base
(article RA8EMU-A-1 is the index). `AGENTS.md` has the code conventions.
