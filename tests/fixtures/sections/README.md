# Section-table fixtures

`fault_crashlog_hil.elf` (149892 bytes, sha256 `f385be4717988ccafb1767a0c619941b552850fdd0db78a8ac29601c113b3080`) is the
`examples/ek_ra8d2/hw_validated/hil/fault_crashlog_hil` app from ra8-firmware
commit `63c6f32cd372c57f6d0802889f9bf970020b7491`, built standalone with
Arm GNU Toolchain 13.3.rel1 and Zig 0.14.1:

```sh
cmake -G Ninja -S examples/ek_ra8d2/hw_validated/hil/fault_crashlog_hil -B build \
  -DCMAKE_TOOLCHAIN_FILE=$PWD/cmake/toolchain-ra8d2.cmake
cmake --build build
```

It is the image with every section kind the memory-layout view places: code,
read-only, `.data` stored in MRAM and run in SRAM, `.bss`, and a `.noinit`
section at the top of SRAM (0x220FFF00). The section table test (RA8EMU-783)
checks it against `arm-none-eabi-objdump -h`.
