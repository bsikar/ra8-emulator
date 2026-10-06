# UART fixtures

`uart_irq_echo.elf` (151264 bytes, sha256 `4c728802da61ce1474662d34d19004ba582cef8e24d5a007d865e1b2bc810215`) is the
`examples/ek_ra8d2/hw_validated/hil/uart_irq_echo` app from ra8-firmware
commit `4f362a1cc6a9bf02ac541cd0552107a69d1baf9a`, built standalone with
Arm GNU Toolchain 13.3.rel1 and Zig 0.14.1:

```sh
cmake -G Ninja -S examples/ek_ra8d2/hw_validated/hil/uart_irq_echo -B build \
  -DCMAKE_TOOLCHAIN_FILE=$PWD/cmake/toolchain-ra8d2.cmake
cmake --build build
```

On the Zig core it prints `uart_irq_echo ready` on SCI8 after about 18,000
instructions, then echoes every byte it receives. Its option-setting segments (OFS, SAS, BPS, OTP) make it the session
load test image (RA8EMU-760), and `ctl events --until` (RA8EMU-757)
waits on its banner.
