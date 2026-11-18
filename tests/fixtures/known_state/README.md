# Known-state bare-metal board fixtures (`RA8EMU-1341`)

Source-built bare-metal firmware fixtures shared by the emulation machine profiles (`RA8EMU-1291`, `RA8EMU-1292`), per-board flash/debug profiles (`RA8EMU-1289`), and emulate-then-flash verification (`RA8EMU-1347`).

Every address, bit position, clock divider, baud divisor, and pin select comes exclusively from the target part's Renesas hardware manuals and board manuals indexed in `RA8EMU-A-70` (RA8E1 / FPB-RA8E1) and `RA8EMU-A-71` (RA4T1 / FPB-RA4T1), never from RA8D2/RA8P1 tables. Option-setting flash is intentionally omitted from both linker scripts so programming these images onto physical boards preserves factory option bytes and debug access.

## Artifacts and checksums

| Artifact | Board / MCU | Core | Linked Flash / SRAM | Size | SHA-256 |
|---|---|---|---|---:|---|
| `fpb_ra8e1.elf` | `FPB-RA8E1` (`RTK7FPA8E1S00001BE` / `R7FA8E1AFDCFB`) | Cortex-M85 (`r0p2`, `0x410FD232`) | Flash `0x0200_0000` (1 MB), `SRAM1` `0x2206_0000` (512 KB, SP `0x220D_FFF8`) | 2,288 B | `234da4bcee36cbe1f689feca822ef019e5d5a2f0c680620a8b398d07d15bd4d1` |
| `fpb_ra4t1.elf` | `FPB-RA4T1` (`RTK7FPA4T1S00001BE` / `R7FA4T1BB3CFM`) | Cortex-M33 (`r0p4`, `0x410FD214`) | Flash `0x0000_0000` (256 KB), `SRAM0` `0x2000_0000` (40 KB, SP `0x2000_9FF8`) | 2,300 B | `fee89cd9f2e3025498a989fa5131c8904abc56187db944e078047c8c839be1a8` |

## Reproducible rebuild (Zig `0.17.0`)

From `tests/fixtures/known_state/`:

```sh
zig build-obj -target thumb-freestanding-eabi -mcpu=cortex_m85 -O ReleaseSmall -fno-stack-check -fno-unwind-tables -fstrip -fno-compiler-rt -ffunction-sections fpb_ra8e1.zig -femit-bin=fpb_ra8e1.o
zig cc -target thumb-freestanding-eabi -mcpu=cortex_m85 -nostdlib -Wl,--build-id=none -Wl,--gc-sections -Wl,-e,Reset_Handler -Wl,-z,max-page-size=4 -Wl,-T,fpb_ra8e1.ld fpb_ra8e1.o -o fpb_ra8e1.elf
rm -f fpb_ra8e1.o

zig build-obj -target thumb-freestanding-eabi -mcpu=cortex_m33 -O ReleaseSmall -fno-stack-check -fno-unwind-tables -fstrip -fno-compiler-rt -ffunction-sections fpb_ra4t1.zig -femit-bin=fpb_ra4t1.o
zig cc -target thumb-freestanding-eabi -mcpu=cortex_m33 -nostdlib -Wl,--build-id=none -Wl,--gc-sections -Wl,-e,Reset_Handler -Wl,-z,max-page-size=4 -Wl,-T,fpb_ra4t1.ld fpb_ra4t1.o -o fpb_ra4t1.elf
rm -f fpb_ra4t1.o
```

Both ELFs retain `.symtab` (`vector_table`, `Reset_Handler`, `SysTick_Handler`, `Fault_Handler`, `known_state`, `known_state_park`) with DWARF stripped (`-fstrip`) and `--build-id=none` so debugger tests can resolve exact symbol addresses without host-path nondeterminism.

## Behavior and expected UART output

### 1. `fpb_ra8e1.elf` (`RA8EMU-A-70`: `R01UH1129EJ0110` Rev.1.10, `R20UT5474EG0100` Rev.1.00)
1. **Clock (`initClockHoco48M`)**: unlocks `SYSC.PRCR_S` (`0x4001_E3FA = 0xA503`), clears `SYSC.VBTICTLR` (`0x4001_EC4C = 0x00`), sets `FCACHE.FLWT` (`0x4001_C11C = 0x00`), configures **HOCO = 48 MHz** (`HOCOCR2` `0x4001_E037 = 0x07` while `HOCOCR = 0x01`, then `HOCOCR = 0x00` and waits `OSCSF.HOCOSF == 1` at `0x4001_E03C`), sets `/1` dividers (`SCKDIVCR = 0`, `SCKDIVCR2 = 0`), switches `SCKSCR` (`0x4001_E026`) to `0x00` (`HOCO`), and re-locks `PRCR_S`.
2. **Board VCOM UART (`initSci9Vcom`)**: clears `MSTPCRB.MSTPB22` (`0x4020_3004`), configures **`SCI9_B`** (`0x4035_8900`) for **115,200 8N1** at `PCLKA = 48 MHz` (`CCR1 = 0x30`, `CCR3 = 0x0000_1283`, `CCR2 = 0xFF00_0C04` -> `BRR = 12`, `115,384.6 bps`, `+0.16%`), routes **`P101 = RXD9_A`** (`0x4040_0844`) and **`P102 = TXD9_A`** (`0x4040_0848`, `PSEL = 0x05`) under `PWPRS` (`0x4040_0D14`), enables `CCR0 = 0x11` (`TE | RE`), and prints the boot banner.
3. **SysTick + LED1 (`runSysTickAndLed`)**: drives **`LED1` (`P404`, `PORT4.PCNTR1` `0x4040_0080`)** output low, arms `SysTick` (`RVR = 4799` = 100 us at 48 MHz, `CSR = 0x07` = `ENABLE | TICKINT | CLKSOURCE`), takes **3 `SysTick_Handler` interrupts** toggling `P404` `0 -> 1 -> 0 -> 1` (3 edges, leaving green `LED1` **ON** and `PORT4.PCNTR2` `PIDR04 == 1`), then clears `TICKINT` (`CSR = 0x05`).
4. **End-state record & signature**: writes `StateRecord` at `SRAM1` **`0x2206_0100`** (`magic = 0x5241_3845`, `status = 1`), prints the deterministic end-state line at **115,200 8N1**, waits `CSR.TEND`, and parks in `known_state_park` (`wfi` loop):

```text
RA8EMU KNOWN-STATE BOOT board=fpb-ra8e1 part=r7fa8e1afdcfb core=cortex-m85
RA8EMU KNOWN-STATE END board=fpb-ra8e1 cpuid=410fd232 clk=hoco48m systick=3 led1=1 status=PASS
```

(Each line terminated by `\r\n`, 172 bytes total: `tx_bytes = 172`.)

### 2. `fpb_ra4t1.elf` (`RA8EMU-A-71`: `R01UH0999EJ0140` Rev.1.40, `R20UT5524EG0100` Rev.1.00)
1. **Clock (`initClockHoco20M`)**: unlocks `SYSC.PRCR` (`0x4001_E3FE = 0xA503`), sets `FCACHE.FLWT` (`0x4001_C11C = 0x00`), configures **HOCO = 20 MHz** (`HOCOCR2` `0x4001_E037 = 0x02` while `HOCOCR = 0x01`, replacing blank `OFS1`'s `11b`, then `HOCOCR = 0x00` and waits `OSCSF.HOCOSF == 1` at `0x4001_E03C`), sets `SCKDIVCR` (`0x4001_E020 = 0x0000_0000`, `/1` -> 20 MHz), switches `SCKSCR` (`0x4001_E026`) to `0x00` (`HOCO`), and re-locks `PRCR`.
2. **UART (`initSci9Vcom`)**: clears `MSTPCRB.MSTPB22` (`0x4008_4004`), configures classic **`SCI9`** (`0x4011_8900`) for **115,200 8N1** at `PCLKA = 20 MHz` (`SMR = 0x00`, `SCMR = 0xF2`, `SEMR = 0x04` `BRME=1`, `SPTR = 0x06`, `BRR = 4`, `MDDR = 236` -> `115,234.4 bps`, `+0.03%`), routes **`P109 = TXD9`** (`0x4008_0864`) and **`P110 = RXD9`** (`0x4008_0868`, `PSEL = 0x05`) under `PWPR` (`0x4008_0D03`, `PmSAR` resets Non-secure `0xFFFF`), enables `SCR = 0x30` (`TE | RE`), and prints the boot banner.
   - **Physical board note (`R20UT5524EG0100` Fig. 4 & Table 3, verified on `FPB-RA4T1` `S/N 001088957027`)**: although the onboard J-Link OB-RA4M2 enumerates a USB CDC interface, `FPB-RA4T1` v1 does **not** wire J-Link OB VCOM RX/TX to any RA4T1 pin (`E33` routes `P109/TDO` SWO trace to debugger `P100`; toggling CDC break produces `0x0000` delta across `PORT0..8` `PIDR`). `SCI9` clocks all 172 bytes onto `P109` (`SSR.TEND == 1`) and serves as the emulated console UART; on physical `FPB-RA4T1` without an external UART adapter, `StateRecord` @ `0x2000_0100` over SWD is the physical state oracle.
3. **SysTick + LED1 (`runSysTickAndLed`)**: drives **`LED1` (`P207`, `PORT2.PCNTR1` `0x4008_0040`)** output low, arms `SysTick` (`RVR = 3999` = 200 us at 20 MHz, `CSR = 0x07`), takes **3 `SysTick_Handler` interrupts** toggling `P207` `0 -> 1 -> 0 -> 1` (3 edges, leaving green `LED1` **ON** and `PORT2.PCNTR2` `PIDR07 == 1`), then clears `TICKINT` (`CSR = 0x05`).
4. **End-state record & signature**: writes `StateRecord` at `SRAM0` **`0x2000_0100`** (`magic = 0x5241_3454`, `status = 1`), prints the deterministic end-state line at **115,200 8N1**, waits `SSR.TEND`, and parks in `known_state_park` (`wfi` loop):

```text
RA8EMU KNOWN-STATE BOOT board=fpb-ra4t1 part=r7fa4t1bb3cfm core=cortex-m33
RA8EMU KNOWN-STATE END board=fpb-ra4t1 cpuid=410fd214 clk=hoco20m systick=3 led1=1 status=PASS
```

(Each line terminated by `\r\n`, 172 bytes total: `tx_bytes = 172`.)

## `StateRecord` layout (`0x2206_0100` on RA8E1, `0x2000_0100` on RA4T1)

| Byte offset | Field | Expected on `FPB-RA8E1` | Expected on `FPB-RA4T1` |
|---:|---|---|---|
| `+0x00` | `magic` | `0x5241_3845` (`"RA8E"`) | `0x5241_3454` (`"RA4T"`) |
| `+0x04` | `cpuid` | `0x410F_D232` | `0x410F_D214` |
| `+0x08` | `reset_vtor` | `0x0200_0000` | `0x0000_0000` |
| `+0x0C` | `scksel` | `0x0000_0000` (`HOCO`) | `0x0000_0000` (`HOCO`) |
| `+0x10` | `oscsf` | bit 0 (`HOCOSF`) = `1` | bit 0 (`HOCOSF`) = `1` |
| `+0x14` | `syst_calib` | `0x0000_270F` | `0x4000_0147` |
| `+0x18` | `systick_ticks` | `3` | `3` |
| `+0x1C` | `led_transitions` | `3` | `3` |
| `+0x20` | `port_pidr` | `0x0000_0010` (`P404` = `1`) | `0x0000_01C3` (bit 7 `P207` = `1`) |
| `+0x24` | `tx_bytes` | `172` (`0x0000_00AC`) | `172` (`0x0000_00AC`) |
| `+0x28` | `status` | `1` (`PASS`) | `1` (`PASS`) |

### Physical bench oracle capture (SEGGER J-Link V8.18 over SWD)

- **`FPB-RA8E1`** (`S/N 001083322193`, `PNR0..3` @ `0x0300_80F0` = `"R7FA8E1AFDCFB"`):
  - VCOM UART (`115200 8N1`): 172 / 172 bytes exact match (`BOOT` + `END ... status=PASS`).
  - `StateRecord` @ `0x2206_0100`: `[0x52413845, 0x410FD232, 0x02000000, 0x00000000, 0x00000001, 0x0000270F, 0x00000003, 0x00000003, 0x00000010, 0x000000AC, 0x00000001]`.
- **`FPB-RA4T1`** (`S/N 001088957027`, `PNR0..3` @ `0x0100_80F0` = `"R7FA4T1BB3CFM"`):
  - `StateRecord` @ `0x2000_0100`: `[0x52413454, 0x410FD214, 0x00000000, 0x00000000, 0x00000001, 0x40000147, 0x00000003, 0x00000003, 0x000001C3, 0x000000AC, 0x00000001]`.
