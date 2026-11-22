# Generic Cortex-M33, Cortex-M55, and Cortex-M85 Fixtures

Reproducible minimal bare-metal ELFs for exercising the generic `cortex-m33`,
`cortex-m55`, and `cortex-m85` machines (`--part cortex-m33`,
`--part cortex-m55`, `--part cortex-m85`), their end-state memory records, ITM
console output, M55 absent-PACBTI fault probing, and M85-on-M33 `UNDEFINSTR`
faulting.

All images target the shared generic memory map declared in `generic.ld`
(256 KiB flash at `0x0000_0000`, 64 KiB SRAM at `0x2000_0000`) and keep
unstripped ELF symbols (`-fstrip` only on object/link debug info while retaining
globals in `.symtab`, `--build-id=none`).

## Toolchain and Reproducible Build

Built with Zig `0.17.0` from the repository root:

```bash
zig build-obj tests/fixtures/generic_machines/cortex_m33.zig \
  -target thumb-freestanding-eabihf \
  -mcpu=cortex_m33+fp_armv8d16sp \
  -O ReleaseSmall -fno-stack-check -fno-unwind-tables -fstrip \
  -fno-compiler-rt -ffunction-sections \
  -femit-bin=/tmp/cortex_m33.o

zig cc -target thumb-freestanding-eabihf -nostdlib -fuse-ld=lld \
  -Wl,-T,tests/fixtures/generic_machines/generic.ld \
  -Wl,-e,Reset_Handler -Wl,-z,max-page-size=4 \
  -Wl,--gc-sections -Wl,--build-id=none \
  -o tests/fixtures/generic_machines/cortex_m33.elf /tmp/cortex_m33.o

zig build-obj tests/fixtures/generic_machines/cortex_m55.zig \
  -target thumb-freestanding-eabihf \
  -mcpu=cortex_m55+fp_armv8d16+mve_fp \
  -O ReleaseSmall -fno-stack-check -fno-unwind-tables -fstrip \
  -fno-compiler-rt -ffunction-sections \
  -femit-bin=/tmp/cortex_m55.o

zig cc -target thumb-freestanding-eabihf -nostdlib -fuse-ld=lld \
  -Wl,-T,tests/fixtures/generic_machines/generic.ld \
  -Wl,-e,Reset_Handler -Wl,-z,max-page-size=4 \
  -Wl,--gc-sections -Wl,--build-id=none \
  -o tests/fixtures/generic_machines/cortex_m55.elf /tmp/cortex_m55.o

zig build-obj tests/fixtures/generic_machines/cortex_m85.zig \
  -target thumb-freestanding-eabihf \
  -mcpu=cortex_m85+fp_armv8d16+mve_fp \
  -O ReleaseSmall -fno-stack-check -fno-unwind-tables -fstrip \
  -fno-compiler-rt -ffunction-sections \
  -femit-bin=/tmp/cortex_m85.o

zig cc -target thumb-freestanding-eabihf -nostdlib -fuse-ld=lld \
  -Wl,-T,tests/fixtures/generic_machines/generic.ld \
  -Wl,-e,Reset_Handler -Wl,-z,max-page-size=4 \
  -Wl,--gc-sections -Wl,--build-id=none \
  -o tests/fixtures/generic_machines/cortex_m85.elf /tmp/cortex_m85.o
```

Checksums and sizes:

- `cortex_m33.elf`: `2040` bytes, SHA-256 `a4e3ffd7b8519de20ef5069d495313a20c713bafd6c9e0bf35bc19a819ea2926`
- `cortex_m55.elf`: `2412` bytes, SHA-256 `0e914c2952240469278f0e69a7e57d8d86fdd41f5b2ccfa47ba47d53beb28097`
- `cortex_m85.elf`: `2068` bytes, SHA-256 `82d850a5cff3a14489b52fe9a89ec244b18a455bc77aaab432d58a0602dce9b9`

## Provenance and Behavior

Written for this repository without vendor SDK headers; only SCS, DWT, MPU,
SysTick, CPACR, and ITM stimulus/enable registers are touched.

- `cortex_m33.elf` verifies `CPUID` (`0x410F_D210`), `VTOR` (`0x0000_0000`),
  `DWT_CTRL` + `MPU_TYPE` (`0x0004_0008`), 4 SysTick interrupts (`tick_sum = 10`),
  and single-precision FPU (`2.5 * 3.0 + 1.0 = 8.5f32`, bits `0x4108_0000`), writes
  `known_state` at `0x2000_0100`, emits
  `GENERIC BOOT machine=cortex-m33` and
  `GENERIC END machine=cortex-m33 cpuid=410fd210 ticks=4 sum=10 status=PASS` on ITM
  port 0, and loops in `generic_park`.
- `cortex_m55.elf` verifies `CPUID` (`0x411F_D221`, r1p1), `VTOR`
  (`0x0000_0000`), `DWT_CTRL` + `MPU_TYPE` (`0x0004_0008`), `ID_ISAR5 == 0`,
  PAC hint NOP + `MRS r0, PAC_KEY_P_0` `UsageFault.UNDEFINSTR` (`pac_undef = 1`),
  5 SysTick interrupts, MVE + LOB + double-precision FPU (`3.25 * 2.0 + 0.5 = 7.0`),
  writes `known_state` at `0x2000_0100`, emits
  `GENERIC BOOT machine=cortex-m55` and
  `GENERIC M55 PASS cpuid=411fd221 ticks=5 sum=165 dwt=4 pac_undef=1` on ITM
  port 0, and loops in `generic_park`.
- `cortex_m85.elf` verifies `CPUID` (`0x410F_D230`), `VTOR` (`0x0000_0000`),
  `DWT_CTRL` + `MPU_TYPE` (`0x0008_0008`), 5 SysTick interrupts, MVE + LOB (`dls`/`le`
  and `vdup.32`/`vadd.i32` producing `165`), and double-precision FPU
  (`3.25 * 2.0 + 0.5 = 7.0f64`, high word `0x401C_0000`), writes `known_state` at
  `0x2000_0100`, emits
  `GENERIC BOOT machine=cortex-m85` and
  `GENERIC END machine=cortex-m85 cpuid=410fd230 ticks=5 sum=165 status=PASS`, and
  loops in `generic_park`.
- Running `cortex_m85.elf` under `--part cortex-m33` traps on the MVE/LOB
  instructions into `Fault_Handler`, recording `magic = 0xFA01_7000`, `status = CFSR`
  (`0x0001_0000`, `UNDEFINSTR`), and emitting `GENERIC FAULT machine=cortex-m85` on
  ITM port 0 before branching to `generic_park`.
