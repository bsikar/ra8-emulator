# The instruction the compiler emits that the chip will not execute

Two EIL images stop on an instruction that does not mean anything:

    ea52 03cf    orrs.w  r3, r2, pc, lsl #3

`pc` as a shifted operand is UNPREDICTABLE in the Armv8-M encoding, so the
part is free to do whatever it likes with it and the model refuses to guess.
`--stop-on-undefined` halts the run at the first one that executes.

This document settles what it is: **a code generation bug in Arm GNU
Toolchain 13.3.Rel1**, not a modelling gap, not a stale object, and not
something the emulator can paper over. Everything below was re-derived by
running the compiler, not quoted.

## The reproducer

Two lines. No headers, no include path, no project:

```c
typedef unsigned long long u64;
unsigned long long f(unsigned int t) { return (u64)t * 46; }
```

```
arm-none-eabi-gcc -mcpu=cortex-m85 -mfloat-abi=hard -O0 -c -o v.o v.c
arm-none-eabi-objdump -d v.o
```

and the bad instruction is in `f`.

    arm-none-eabi-gcc (Arm GNU Toolchain 13.3.Rel1 (Build arm-13.24)) 13.3.1 20240614

## What flips it

Measured on that two-line file, one axis at a time:

| axis | bad | clean |
| --- | --- | --- |
| optimisation | `-O0`, `-O1` | `-O2`, `-O3`, `-Os` |
| core | `cortex-m85`, `cortex-m55` | `cortex-m4`, `cortex-m7`, `cortex-m33` |
| float ABI | `hard`, `softfp` | `soft` |

`-std` does not matter; `gnu2x` was in the first reproducer only because the
firmware builds with it. The multiplier does: a constant the compiler expands
into a shift-and-add sequence (46, 40, 24, 12) reproduces it, and a plain
power of two (`* 8`) does not. That is the shape of the bug. The 64-bit
shift-left of a constant multiply wants three instructions,

    lsls  r3, r3, #3
    orr.w r3, r3, r2, lsr #29
    lsls  r2, r2, #3

and the middle one comes out with its operands shifted one position: `Rn`
took `Rm`'s register and `Rm` became `r15`.

## Where it bites this tree

The firmware is built `-O0 -g3` for `cortex-m85` with `-mfloat-abi=hard`,
which is exactly the window above. Both SD walls sit on one of these:

- **FAT32** stops at `0x02007498`, `internal_fat_entry_byte_offset+0x5C`
  (`libs/ra8_fs/src/ra8_fs_fat.c`). The run reports `FAIL provision`.
- **FAT16** stops at `0x0201764E`, `mz_zip_reader_read_central_dir+0xF0A`,
  which is `miniz.c:3750`, `cdir_size < (mz_uint64)pZip->m_total_files *
  MZ_ZIP_CENTRAL_DIR_HEADER_SIZE`, a 64-bit multiply by 46. The run reports
  `FAIL open`.

They are two different sites in two different files, not one bug reached
twice: `--break-at` on either address is reached by one image and not the
other.

A whole-file build of `miniz.c` carries exactly one, and so does the object
the app build produced, so the compiler is where it enters. Preprocessing
that file to a self-contained translation unit (10633 lines, no include path)
and compiling that still carries it, which is the form a bug report takes if
the two-line case is ever argued away.

## A correction to an earlier reading

An earlier pass recorded that dropping the `ra8_core` include path made the
bad instruction go away, and read that as one of the project's headers
flipping code generation. It does not. Without that path `miniz.c` does not
compile at all:

    fatal error: ra8_check.h: No such file or directory

so there was no object to count instructions in. The include path is required
to build the file and has nothing to do with the bug; the two-line reproducer
above needs no headers at all.

## What this tree does about it

Nothing, deliberately. The emulator's job here is to refuse the instruction
and say where it is, which `--stop-on-undefined`, `--break-at` and the
undefined-site sweep already do. Modelling some behaviour for `pc` as a
shifted operand would invent an answer the silicon does not promise and would
hide the miscompile from whoever builds this firmware next.

The fix belongs upstream, or in a toolchain pin that steps around it.
