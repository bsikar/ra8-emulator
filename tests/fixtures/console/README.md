# Polled SCI8 host-input fixture

`echo.elf` is the RA8EMU-725 Cortex-M85 fixture built from `echo.zig` and
`echo.ld` in this directory. It clears only SCI8's module-stop bit
(MSTPCRB bit 23), enables RE/TE, then polls CSR.RDRF and echoes RDR bytes
to TDR. It records the number of consumed bytes at SRAM `0x22000100`.
There is no interrupt setup or external firmware dependency.

This isolates actual host stdin delivery from NVIC interrupt routing.
`tests/interfaces/cli/zig/main_test.zig` spawns the real CLI with a pipe,
checks the echoed marker and consumed-byte count, checks the negative
control without `--console`, and leaves an idle pipe open to check that
virtual execution finishes without waiting for EOF. The touch-file case
uses the existing `tests/fixtures/touch` guest separately.

Register encodings follow the emulator's SCI_B and module-stop contracts
in `src/chip/periph/sci/sci.zig` and `src/chip/periph/mstp/mstp.zig`.
This fixture tests host plumbing, not UART baud timing or interrupt fidelity.

Rebuild from the repository root with Zig 0.17.0:

```sh
zig build-obj -target thumb-freestanding-eabihf -mcpu=cortex_m85 -O ReleaseSmall -fno-stack-check -fstrip -fno-compiler-rt -ffunction-sections tests/fixtures/console/echo.zig -femit-bin=/tmp/ra8-console-echo.o
zig cc -target thumb-freestanding-eabihf -mcpu=cortex_m85 -nostdlib -Wl,--build-id=none -Wl,--gc-sections -Wl,-s -Wl,-e,Reset_Handler -Wl,-z,max-page-size=4 -Wl,-T,tests/fixtures/console/echo.ld /tmp/ra8-console-echo.o -o tests/fixtures/console/echo.elf
```

ELF size: 712 bytes. SHA-256: `35910d594d4c55d98acd871d51a044b1c907b22677bea0926bf10cd867092880`.
