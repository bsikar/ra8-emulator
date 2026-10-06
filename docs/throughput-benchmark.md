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
It also accepts an instruction budget:

```sh
tools/bench_releasefast.sh IMAGE 2000000
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
virtual time, with idle fast-forward on (the default) and off. It reports wall
time, effective speed (virtual seconds per wall second), and retired
instructions per wall second for CPU0 and CPU1. CPU0's clock is 1 GHz virtual,
so busy CPU0 code needs 1e9 retired instructions per wall second to keep up at
1x.

The command accepts two optional environment variables:

- `BENCH_SPEED_REPEATS` is the positive number of samples, default 3. The
  fastest valid sample supplies the summary row.
- `BENCH_SPEED_LOG_DIR` retains every raw emulator report in a new run
  subdirectory. Without it, the temporary reports are removed.

A sample is valid only when the emulator exits zero, reports the requested
soak completed with no event, reports every attached core's retired count, and
does not report a CPU1 halt. Repeat diagnostics on standard error identify the
raw log and wall nanoseconds. The script exits 1 if any image/mode has no valid
sample; invalid rows remain visible but must not be used as speed ceilings.

```sh
zig build -Doptimize=ReleaseFast -Ddeps-prefix=/home/bsikar/deps \
  -p /tmp/ra8emu-180-rf
BENCH_SPEED_REPEATS=3 \
BENCH_SPEED_LOG_DIR=/home/bsikar/ra8emu-180-benchmark/final-raw \
  tools/bench_speed.sh /tmp/ra8emu-180-rf/bin/ra8_emulator 1s IMAGE.elf...
```

### Lab VM measurement

These are minimum-wall-time results from three serial samples per row on the
`dev` Proxmox Linux x86_64 guest. The guest has 16 online vCPUs (12 available
to the benchmark's affinity) on an Intel Core i5-12600K and ran Zig 0.14.1.
The emulator is a ReleaseFast build of main at
`054b45353a7d609c14bb1041b4af824be8077397`; the firmware images are from
ra8-firmware main at `6196bf4d1d2d222affd89af20a5e2f51452bc383`, built with
`just apps::build APP`. Every row ran for one virtual second. `log` names the
selected report in retained run `run-20261006T005333Z-3919400`.

| image | class | mode | valid | rc | rep | log | wall ms | speed | CPU0 M instr/s | CPU1 M instr/s |
|---|---|---|---|---:|---:|---|---:|---:|---:|---:|
| rtc_alarm | idle | skip | yes | 0 | 1 | rtc_alarm-skip-1.log | 37 | 27.08x | 0.7 | - |
| rtc_alarm | idle | stepped | yes | 0 | 2 | rtc_alarm-stepped-2.log | 69 | 14.50x | 0.4 | - |
| lpm_periodic_idle | idle | skip | yes | 0 | 2 | lpm_periodic_idle-skip-2.log | 40 | 25.30x | 0.9 | - |
| lpm_periodic_idle | idle | stepped | yes | 0 | 2 | lpm_periodic_idle-stepped-2.log | 74 | 13.49x | 0.5 | - |
| gpt_irq_demo | mixed | skip | yes | 0 | 3 | gpt_irq_demo-skip-3.log | 82 | 12.22x | 4.0 | - |
| gpt_irq_demo | mixed | stepped | yes | 0 | 2 | gpt_irq_demo-stepped-2.log | 111 | 9.01x | 3.0 | - |
| compress_demo | busy | skip | yes | 0 | 3 | compress_demo-skip-3.log | 26078 | 0.04x | 38.3 | - |
| compress_demo | busy | stepped | yes | 0 | 3 | compress_demo-stepped-3.log | 25998 | 0.04x | 38.5 | - |
| cpu1_pingpong | dual-core | skip | yes | 0 | 2 | cpu1_pingpong-skip-2.log | 184 | 5.44x | 5436.7 | 5436.7 |
| cpu1_pingpong | dual-core | stepped | yes | 0 | 1 | cpu1_pingpong-stepped-1.log | 184 | 5.45x | 5448.9 | 5448.9 |

Firmware ELF SHA-256 values:

```text
rtc_alarm.elf                 0f30908cf99fc6a63b2fd8a1eabf9df95aa24c893be54f594d8f15f5d95b6107
lpm_periodic_idle.elf         40e45dc8e60370935e80a5519fb9c5b7fddb93e847e67da887bb4f54c1fd4eb6
gpt_irq_demo.elf              4af4e49b690b8abeb75c8b2673a4764ed4c505dae88e6e8b1965694bef81536d
compress_demo.elf             af9dab83e2010c7c7d432a16e9117d31f49ac2e420ca8a251964a2b27cc7c271
cpu1_pingpong.elf             5fab11c87b7619a9fbb1c9fc62893f33ac50567b7c595a46be3b12fad10f7ad6
cpu1_pingpong_cpu1.elf        972831b5ed26e1f32a7119eee633eb4b728b432ec946a00257ea9d4723e310b5
```

`cpu1_pingpong_ipc` was also built with its CPU1 companion, but CPU0 stopped
on a SecureFault at 50 us virtual in every sample. It is therefore not a
one-second throughput result and is deliberately excluded from the table.

### Reachable factors on this host

A factor is throughput-reachable here when the unrounded virtual/wall ratio is
at least that factor. This is a throughput ceiling, not a pacing-accuracy
test, and one host measurement is not a general guarantee.

- Both idle images reach 0.1x, 1x, and 5x in skip and stepped modes. Their
  observed maxima are 25.30x to 27.08x with idle skip and 13.49x to 14.50x
  stepped. Neither reaches 100x.
- The mixed GPT image reaches 0.1x, 1x, and 5x in both modes, at 12.22x with
  idle skip and 9.01x stepped. It does not reach 100x.
- The busy compression image reaches neither 0.1x nor 1x: both modes are about
  0.038x, despite CPU0 retiring about 38 M instructions/s. It therefore also
  cannot reach 5x or 100x.
- The dual-core image reaches 0.1x, 1x, and 5x in both modes, at about 5.44x.
  The whole run's virtual/wall ratio determines reachability; CPU0 and CPU1
  each retired about 5.44 billion instructions/s in this tight-loop image. It
  does not reach 100x.

Requested factors below an image's unpaced result can be paced. Requests above
it run as fast as the host permits; the pacer reports the slip and does not
burst afterwards (RA8EMU-181).
