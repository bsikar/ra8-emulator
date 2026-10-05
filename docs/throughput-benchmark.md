# CPU throughput benchmark

`tools/bench_releasefast.sh` builds this emulator with `-Doptimize=ReleaseFast`
and times the Zig core on one ELF image for a fixed instruction budget. The
output reports net milliseconds and instructions per second, after subtracting
the zero-instruction load time. Do not use numbers from a Debug build.

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
Capstone:

```sh
tools/bench_releasefast.sh IMAGE 2000000 /path/to/deps
```

`tools/bench_core.sh` remains available for a prebuilt emulator and either a
single ELF or a directory of ELFs. The ReleaseFast entry point above is the
reproducible single-image benchmark for this ticket.

It runs each image the way the corpus does: an ELF named `NAME_cpu1.elf` next
to `NAME.elf` is passed as `--cpu1`, and `NAME_ns.elf` as `--ns`, so the
dual-core and TrustZone images time both cores. Each figure is the minimum of
several runs (three by default) because a short image's single run
varies by about a third:

```sh
tools/bench_core.sh zig-out/bin/ra8_emulator DIR 4000000 3
```

The RA8EMU-12 speed budget is read from the total row of that table over a
directory holding the corpus images and their companions, compared with the
same total on an earlier build of main on the same host.

## Which speed factors are reachable (RA8EMU-180)

`tools/bench_speed.sh` runs each image unpaced on the Zig core for the same
virtual time, with idle fast-forward on (the default) and off, and prints wall
time, the effective speed factor (virtual seconds per wall second) and CPU0
instructions retired per wall second. CPU0's clock is 1 GHz virtual, so a core
that never sleeps needs 1e9 instructions per wall second to keep up at 1x.

```sh
zig build -Doptimize=ReleaseFast -p /tmp/rf
tools/bench_speed.sh /tmp/rf/bin/ra8_emulator 1s corpus/elf/IMAGE.elf...
```

The numbers below are for `--run-for 1s`, on a ReleaseFast build of main at
6e55a993 (RA8EMU-618), on a Linux x86_64 build sandbox with 2 vCPUs. They are
not lab VM numbers. Each image name drops the
`ek_ra8d2_hil_needs_revalidation_` prefix:

| image | skip | stepped | instr/s (skip) |
|---|---|---|---|
| rtc_alarm (idle) | 9.67x | 4.67x | 0.2 M |
| lpm_periodic_idle (idle) | 9.25x | 4.24x | 0.3 M |
| gpt_irq_demo (mixed) | 3.55x | 2.51x | 1.2 M |
| compress_demo (busy) | 0.01x | 0.01x | 10.1 M |

`cpu1_pingpong_ipc` is left out: without its CPU1 companion it stops on its
SecureFault soak event before the second is up, so its 11x is not a full
second.

What this means today:

- An idle-heavy image reaches 1x and 5x on this host, and about 10x unpaced.
  Idle fast-forward roughly doubles it. RA8EMU-184 measured 12.7x on
  rtc_alarm over 10 s on the same kind of host.
- A busy image runs at about 10 M instructions per second, which is 0.01x of
  a 1 GHz core. `--realtime` and `--speed 1` cannot keep up while firmware
  computes. The pacer reports the slip and does not burst afterwards
  (RA8EMU-181).
- `--speed` values below the unpaced figure are honoured exactly. Above it,
  the run goes as fast as the host allows.
