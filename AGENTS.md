# AGENTS.md

House conventions for ra8-emulator. They win over habit, including habits
carried over from the C tree on `dev` and from ra8-firmware. Read this before
writing code here.

## Layout

Source is grouped by job, not a flat folder of `.zig` files. Each top directory
answers one question, and a file's path is the first thing that says what it is
for:

```
src/main.zig          the program: argument in, run, report out
src/root.zig          the module index, imported as "ra8"
src/core/             the machine: engine, memmap, elf, session, the run
                      loop, the hooks the machine itself installs, and
                      src/core/c.zig
src/debug/            the debugger surface: breakpoints, watchpoints, their
                      hooks, disassembly, symbols, register and memory dumps
src/interfaces/cli/   the command line and the report renderers that write
                      its output
src/board/            how the board is wired: which blocks exist and what
                      they are connected to
src/periph/           everything that answers on the peripheral bus
tests/                one test file per source file, on the mirrored path
```

`src/periph/` is one directory per peripheral block, named for the block:
`src/periph/gpt/`, `src/periph/sci/`, `src/periph/glcdc/`, and so on. A block
with several files (the register file, its channels, its FIFO, its frames)
keeps them together. A genuine singleton stays flat at `src/periph/`: `nvic`,
`clocks`, `registry`, `crc` and the rest are one file each and a one-file
directory would say nothing. Give a block its own directory when it grows a
second file, not before.

`tests/` mirrors `src/` on the same paths, all the way down:
`src/periph/gpt/gpt_channel.zig` is tested by
`tests/periph/gpt/gpt_channel_test.zig`.

`src/core/c.zig` is the only `@cImport` in the tree and the only place a C
boundary is allowed to show.

## One file, one purpose

A file holds one thing, the way a Kotlin class or a DTO gets its own file. A
peripheral block, the bus, the ELF reader, the command line: each is its own
file. Files and functions stay short; split before a file sprawls. Abstraction
is good, over-abstraction is bad: add a seam when a second caller needs it, not
in anticipation of one.

## No inline tests

A `test` block at the bottom of a source file is wrong here. Tests live in
`tests/` mirroring the source path, one file per module:

```
src/periph/crc.zig   ->  tests/periph/crc_test.zig
src/core/elf.zig     ->  tests/core/elf_test.zig
```

`tests/all.zig` is the test root and lists every test file, so `zig build test`
runs everything. A test file reaches the code under test through the `ra8`
module (`const crc = ra8.periph.crc;`), never through a relative path into
`src/`. A decl a test needs is `pub`; a fixture the test owns lives in the test
file.

## Idiomatic Zig, not C habits

Slices and fat pointers, never null-terminated strings or a pointer plus a
length, unless a real C boundary needs them, and `src/core/c.zig` is the only
such boundary. Constants are `pub const` grouped under a namespace struct, not
`K_`-prefixed macro constants and not an enum standing in for a bag of
unrelated numbers; enums are for real enumerations. Errors are error sets, not
sentinel returns.

## The build gate is light

`build.zig` carries `zig fmt --check` and simple file and function length
checks, and nothing else. This is deliberately not ra8-firmware's gate set: the
emulator is a tool, and a heavy gate here would cost more than it catches.

## Commits and pull requests

One commit per slice, subject starting `#14 `, authored and committed as the
repository owner. Every slice gets its own branch and its own pull request,
rebase-merged the same session with the head branch deleted. A pull request is
indexable history, not a review queue, so nothing is left open. The pull
request body says what was run and what could not be.
