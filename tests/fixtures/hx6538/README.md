# HX6538 / Grove Vision AI V2 dual-Cortex-M55 fixtures

Source-built deterministic bare-metal ELF pair for the Himax HX6538 (`hx6538` /
`grove-vision-ai-v2`) machine profile in loader-established TCM/SRAM mode (no
BootROM emulation).

Addresses, IRQs, and register layouts follow `WE2_device_addr.h`,
`WE2_ARMCM55.h`, `TrustZone_S_ONLY.ld`, `hx_drv_mb.h`, `hx_drv_uart.h`,
`hx_drv_timer.h`, and `hx_drv_scu_export.h`.

## Artifacts and checksums

| Artifact | Core | Link Regions | Size | SHA-256 |
|---|---|---|---:|---|
| `cm55m.elf` | `CM55M` (Cortex-M55, `400 MHz`) | `ITCM_S` `0x1000_0000` (256 KiB), stack `DTCM_S` `0x3004_0000` | 9,780 B | `ba602d24abe60b5fd673e21086e232847f2bbbb257dabe71f624316f669d7ca7` |
| `cm55s.elf` | `CM55S` (Cortex-M55, `150 MHz`) | `SRAM0_S` `0x3400_0000` (256 KiB), stack `DTCM_S` `0x3004_0000` | 9,356 B | `c00efa20c7fba6aa536065d496865ed7f331eb2f48ed7e3cdca92f25f6e569a3` |

## Reproducible rebuild (`arm-none-eabi-gcc 14.2.1`)

From `tests/fixtures/hx6538/`:

```sh
arm-none-eabi-gcc -mcpu=cortex-m55 -mthumb -mfloat-abi=hard -O2 -ffreestanding -nostdlib -nostartfiles -Wall -Wextra -Werror -Wl,--build-id=none -T cm55m.ld cm55m.c -o cm55m.elf
arm-none-eabi-gcc -mcpu=cortex-m55 -mthumb -mfloat-abi=hard -O2 -ffreestanding -nostdlib -nostartfiles -Wall -Wextra -Werror -Wl,--build-id=none -T cm55s.ld cm55s.c -o cm55s.elf
```

## Exercised behaviors and shared state (`0x3408_0000` / NS `0x2408_0000`)

1. **Identity, DWT/FPB, MVE/LOB, and inverted IDAU**: `CM55M` records `SCB->CPUID`,
   `DWT->CTRL[31:28] = 4`, `FP_CTRL = 8`, runs Helium MVE (`VLDRW`/`VADD.I32`)
   plus hardware low-overhead loops (`DLS`/`LE`), and queries `TT` with
   `SAU_CTRL.ALLNS = 1` to prove inverted HX bit-28 polarity (`0x1000_0000` &
   `0x5400_A000` Secure; `0x0000_0000` & `0x4400_A000` Non-secure).
2. **Negative boundaries**:
   - Reading unmapped Ethos-U55 MMIO (`0x5302_0000`) takes a precise `BusFault`
     (`BFAR = 0x5302_0000`), verifying `hasNpu() == false` and absent NPU MMIO.
   - Executing `MRS r0, PAC_KEY_P_0` (`0xF3EF 0x8020`) takes `UsageFault.UNDEFINSTR`,
     verifying Cortex-M55 omits PACBTI.
3. **Timer0 IRQ34 + DW APB UART0 console**: programs `TIMER0` (`0x5500_A000`) for
   IRQ 34 and emits `HX6538 M55 DUAL BOOT` then `HX6538 M55 DUAL PASS` on
   `UART0` (`0x5400_3000`).
4. **Cold hold, SCU release, Mailbox IRQ7, and exclusive monitor**: verifies
   `CM55S_STATE == 0` & `CM55S_CPUWAIT == 1` at boot (`cm55s_boot_seq == 0`),
   programs `CM55S_INITSVTOR = 0x3400_0000` + `CM55S_STATE = 1` + `CM55S_CPUWAIT = 0`,
   exchanges commands over Mailbox mutex `0`, shared words `0/1`, and `MBOX_IRQn = 7`,
   updates shared `LDREX`/`STREX` counter (`excl_counter == 2`), writes
   `magic = 0x4858_4D35` and `status = 1`, and parks in `hx_done_park` while
   `CM55S` advances `cm55s_loop_ticks` in `cm55s_idle_loop`.
