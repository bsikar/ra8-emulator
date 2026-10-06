# Documentation index

## Architecture decisions

- [ADR 0001: GUI stack](adr/0001-gui-stack.md) records the rendering, platform, threading, and support choices for the native GUI.
- [ADR 0002: interfaces and GUI direction](adr/0002-interfaces-and-gui-direction.md) records the product interfaces, time control, remote use, and pluggable-device direction.

## Platforms and performance

- [Platforms](platforms.md): what builds on Linux, macOS and Windows, what each still needs, and the same image's speed on three hosts.
- [Throughput benchmark](throughput-benchmark.md)
- [Memory layout](memory-layout.md): the EK-RA8D2 regions, run and load addresses, the stack, and the A/B layouts of the DFU bootloader and ra8_ota, with `--map` output.

## Engineering notes

- [EIL parity](eil-parity.md)
- [GCC miscompile](gcc-miscompile.md)
- [ThreadX caller error](threadx-caller-error.md)

