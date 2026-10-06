# Memory layout on the EK-RA8D2

This walks through where an EK-RA8D2 image lives: the linker script's regions,
how sections are placed, what startup copies and zeroes, where the stack sits,
and how the two firmware update paths lay out their A and B images. Every
number comes from ra8-firmware's `libs/ra8_board_ek_ra8d2/ld/linker_script.ld`
and from `ra8_emulator --map` (RA8EMU-793) on two real images:

- `tests/fixtures/sections/fault_crashlog_hil.elf`, a small application.
- `dfu_bootloader.elf`, built MinSizeRel from ra8-firmware dev.

Run the same view on any image with:

```
ra8_emulator --map IMAGE.elf
```

A served session gives the same text (or JSON with `--json`) through
`ra8_emulator ctl map` (RA8EMU-794). The memory map pane (RA8EMU-778,
RA8EMU-781) draws the same regions and rows.

## The regions

The linker script's `MEMORY` block names ten regions. `--map` prints one
header line per region, in this order:

| Region | Base | Size | What it is |
|---|---|---|---|
| MRAM | 0x02000000 | 1 MiB | Code MRAM: vectors, code, constants, load copies |
| OFS_CFG | 0x02C9F000 | 2 KiB | Option-setting configuration words |
| OFS_OTP | 0x02E07000 | 68 KiB | Option-setting OTP and anti-rollback area |
| ITCM | 0x00000000 | 64 KiB | Instruction TCM |
| DTCM | 0x20000000 | 64 KiB | Data TCM |
| SRAM | 0x22000000 | 1 MiB - 256 | Main SRAM: data, bss, stack |
| NOINIT | 0x220FFF00 | 256 B | Crash-log record that survives a warm reset |
| SDRAM | 0x68000000 | 64 MiB | External SDRAM |
| NS_MRAM | 0x12080000 | 512 KiB | Non-Secure alias of upper MRAM |
| NS_SRAM | 0x32100000 | 640 KiB | Non-Secure SRAM placeholder |

OFS_CFG and OFS_OTP are the two disjoint option-setting blocks in the extra
MRAM, placed at their real secure-alias addresses so the flashing tool writes
the right cells. Each option word is its own section, for example
`.option_setting_ofs0` at 0x02C9F040 and `.option_setting_otp_fsblctrl0` at
0x02E07600.

SRAM stops 256 bytes short of 1 MiB because the top 256 bytes are their own
region, NOINIT, at 0x220FFF00. Keeping it separate keeps the SRAM usage figure
honest instead of reading near 100% for one section pinned at the top.

NS_MRAM and NS_SRAM overlap MRAM and SRAM: they are the bit-28 Non-Secure
aliases of the same physical bytes, and the SAU split programmed at boot is
what makes the CPU treat them as Non-Secure. With TrustZone off, nothing is
placed there, and `--map` shows both at 0 bytes.

ITCM at 0x0 is a region in the linker script, but the emulator leaves address
0 unmapped on purpose: the EK-RA8D2 takes a precise BusFault on a read of 0
(RA8EMU-495).

## Run address and load address

Every section has a run address (VMA, where the code expects it) and a load
address (LMA, where its bytes are stored in the image). Most sections run
where they are stored. `--map` marks those `run`:

```
MRAM     0x02000000-0x020fffff     13686 /  1048576 bytes  1.3%
  .vectors                       run  0x02000000                        512
  .text                          run  0x02000200                       9068
  .rodata                        run  0x0200256c                       4026
  .ARM.exidx                     run  0x02003528                         40
  .data                          load 0x02003550  (runs at 0x22000000)        40
```

`.data` is different. Initialised variables have to be writable, so they run
in SRAM, but SRAM is empty at power-on, so their initial values are stored in
MRAM right after the read-only sections. `--map` lists `.data` twice: as a
`load` row under MRAM, and as a `run` row under SRAM with its load address:

```
SRAM     0x22000000-0x220ffeff      2936 /  1048320 bytes  0.2%
  .data                          run  0x22000000  load 0x02003550        40
  .bss                           run  0x22000028                       2864
  .stack_canary                  run  0x22000b58                         32
```

The linker script exports the load address as `g_ra8_ls_sidata =
LOADADDR(.data)`. Reset_Handler copies `.data` from there to its run address,
then zeroes `.bss`, which has a run address and no stored bytes at all.

Images that run code from SRAM add a third copied section, `.sram_text`. The
DFU bootloader stores 1432 bytes of it right after the vectors and runs it at
the bottom of SRAM:

```
  .sram_text                     load 0x02000200  (runs at 0x22000000)      1432
  ...
  .sram_text                     run  0x22000000  load 0x02000200      1432
  .data                          run  0x22000598  load 0x02015db4       284
  .bss                           run  0x220006b8                     165108
```

Its load address comes from `g_ra8_ls_sram_text_load = LOADADDR(.sram_text)`.
If that symbol links as 0, Reset_Handler copies from address 0 and takes a
BusFault before `main`. That happened to the DFU bootloader until RA8FW-900
moved the symbol's fallback `PROVIDE`s inside `SECTIONS`, ahead of the
fragment include.

## The stack

The stack sits at the top of SRAM, just under NOINIT:

- `g_ra8_ls_stack_top = ORIGIN(SRAM) + LENGTH(SRAM)`, which is 0x220FFF00.
- `g_ra8_ls_stack_size` is 8 KiB unless the image defines it.
- The script asserts `g_ra8_ls_ebss + g_ra8_ls_stack_size <=
  g_ra8_ls_stack_top`, so bss can't grow into the reserved stack.

`--map` prints the stack as the last line, beside the regions rather than
inside SRAM's used count:

```
stack    0x220fdf00-0x220ffeff      8192 bytes in SRAM
```

The stack grows down from 0x220FFF00. Between the stack bottom and the end of
`.bss` is free SRAM. A 32-byte `.stack_canary` section sits right after
`.bss`, so a stack that runs through all of that free space hits the canary
before it reaches `.bss`. Live stack tracking (current SP and
the lowest SP reached) is RA8EMU-816; drawing it in the map pane is RA8EMU-815.

NOINIT above the stack holds the crash-log record (`.noinit`, 92 bytes in the
fault_crashlog_hil image). Startup leaves it alone, so a warm reset after a
fault can still read it.

## A/B slots in the DFU bootloader

`dfu_bootloader` is an immutable resident in the first 128 KiB of MRAM
(0x02000000). It does not run the application in place. At reset it picks one
of two software slots and copies the winner to a fixed SRAM run base:

| | Base | Size | Header |
|---|---|---|---|
| Slot A | 0x02020000 | 0x70000 | 0x0208FFE0 |
| Slot B | 0x02090000 | 0x70000 | 0x020FFFE0 |
| Run base | 0x22020000 | | |

Each slot's header is the last 32 bytes of the slot (base + 0x6FFE0) and
holds, in order: magic 0x52413844, sequence number, image length, CRC-32 of
the image, and the run base. The image is the payload followed by a 116-byte
ROT1 trailer, an ECDSA P-256 signature over SHA-256 that the bootloader checks
against its root public key.

The bootloader takes the valid slot with the higher sequence number. A slot
with a bad magic, CRC or signature is skipped, so a corrupt B falls back to A.
The winner is copied to 0x22020000 and launched there, which is why a payload
must be linked at the run base and not at its slot address. The console
reports the choice, for example `dfu-bootloader: Slot B -> copy-to-run
@0x22020000`.

`stage_slot_image.py` (in the dfu_bootloader example) builds a slot image
with this layout, and `boot_slots` in the emulator (`src/debug/boot_slots.zig`)
reads it back the same way.

In `--map` terms the bootloader's own image is everything in MRAM below
0x02020000: 89808 bytes of the 128 KiB.

## How libs/ra8_ota differs

`libs/ra8_ota` is an in-application updater, not a bootloader. The running
application streams a signed image into the inactive code-MRAM bank in place,
checks it, then latches the hardware boot-bank swap and resets. There is no
copy to SRAM: the new image executes from MRAM where it was written. Its flash
interface is configured with the inactive bank's address, size and index
(`inactive_bank_addr`, `bank_size_bytes`, `inactive_bank_index`), and an image
larger than the bank is refused.

| | ra8_dfu (dfu_bootloader) | ra8_ota |
|---|---|---|
| Runs | at reset, before any application | while the application runs |
| A/B choice | software, by slot header sequence | hardware boot-bank swap |
| Where the image runs | copied to 0x22020000 in SRAM | in place in MRAM |
| Fed by | USB-DFU | a network interface |
| World | Secure | Non-Secure |

The two never share an image. `libs/ra8_ota/README.md` covers when to use
which.
