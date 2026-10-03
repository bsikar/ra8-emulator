# CPU throughput benchmark

`tools/bench_releasefast.sh` builds this emulator with `-Doptimize=ReleaseFast`
and compares the Zig core with Unicorn on one ELF image. Both runs use the same
instruction budget and image on the same host. The output reports net
instructions per second for each backend, after subtracting each backend's
zero-instruction load time. Do not use numbers from a Debug build.

The initial corpus image is `secure_app_vault_kat.elf`, built from
`examples/ek_ra8d2/hw_pending/secure_app_vault_kat` in
`github.com/bsikar/ra8-firmware`, branch `dev`. It exercises a real RA8D2
firmware image without requiring a second-core companion. Build it from that
branch with `zig build arm`; the generated image is
`zig-out/arm/secure_app_vault_kat.elf`. The ELF remains in the firmware build
output and is not copied or modified by this repository.

From this repository, run the benchmark with the path to that image:

```sh
tools/bench_releasefast.sh /path/to/ra8-firmware/zig-out/arm/secure_app_vault_kat.elf
```

The tool prints the ELF's SHA-256 so results can be tied to the exact image.
It also accepts an instruction budget and, when needed, a prefix containing
Unicorn and Capstone:

```sh
tools/bench_releasefast.sh IMAGE 2000000 /path/to/deps
```

`tools/bench_core.sh` remains available for a prebuilt emulator and either a
single ELF or a directory of ELFs. The ReleaseFast entry point above is the
reproducible single-image benchmark for this ticket.
