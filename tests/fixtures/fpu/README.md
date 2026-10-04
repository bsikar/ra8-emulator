This PT_LOAD image is the FPU corpus fixture (RA8EMU-143). It is a
Cortex-M85 RA8 image linked at MRAM `0x02000000`. The reset handler turns on
CP10 and CP11 in CPACR, then calls `main`.

`fp_basic.zig` runs VADD, VSUB, VMUL, VDIV, VSQRT and VFMA in single and double
precision over five operand pairs each. The pairs cover exact results,
rounded results, divide by zero and the square root of a negative number.
Before every operation it clears FPSCR, and afterwards it stores the result
and FPSCR at SRAM `0x22000100`. The run ends with the marker `0x0F9C0DE5`.
The source is Zig, so the repository carries no C.

Zig 0.14.1's `cortex_m85` has no FP features, so the build adds them.
Rebuild with Zig 0.14.1:

```sh
M=cortex_m85+fp_armv8d16+fullfp16
zig cc -target thumb-freestanding-eabihf -mcpu=$M -c startup.S -o startup.o
zig build-obj -target thumb-freestanding-eabihf -mcpu=$M -O ReleaseSmall -fno-stack-check -fstrip -fno-compiler-rt -ffunction-sections fp_basic.zig -femit-bin=fp_basic.o
zig cc -target thumb-freestanding-eabihf -mcpu=$M -nostdlib -Wl,--build-id=none -Wl,--gc-sections -Wl,-s -Wl,-e,Reset_Handler -Wl,-z,max-page-size=4 -Wl,-T,fpu.ld startup.o fp_basic.o -o fp_basic.elf
```

`tests/core/cpu/fp_corpus_test.zig` embeds this exact ELF and boots it
through the Zig core. Its expected words come from the Arm ARM (DDI0553)
FPAdd, FPSub, FPMul, FPDiv, FPSqrt and FPMulAdd pseudocode, rounding to
nearest even. FPSCR is compared on its cumulative flag bits.
