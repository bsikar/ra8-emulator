# AGENTS.md

House conventions for ra8-emulator. They win over habit, including habits
carried over from the C tree on `dev` and from ra8-firmware. Read this before
writing code here.

## Layout

Source is grouped, not a flat folder of `.zig` files. The model is
ra8-firmware's `libs/<lib>/` on `zig/dev`, where a library's parts sit side by
side:

```
src/main.zig          the program: argument in, run, report out
src/root.zig          the module index, imported as "ra8"
src/core/             the machine: engine, elf, memmap, disasm, cli, c
src/periph/           everything that answers on the peripheral bus:
                      registry (the bus itself), clocks, nvic, mstp,
                      gpio, crc, doc
tests/                one test file per source file, on the mirrored path
```

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
