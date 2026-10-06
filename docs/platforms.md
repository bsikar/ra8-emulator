# Platforms

The emulator is one Zig codebase built for Linux, macOS and Windows. This page
records what builds where, what each platform still needs, and how fast the
same image runs on each host.

Everything here was measured on 2026-10-06 at main `f0995790` with Zig 0.14.1.

## Status

| platform | builds | tests | open work |
|---|---|---|---|
| Linux x86_64 (dev) | unmodified | `zig build test` and `zig build gate` pass | none |
| macOS arm64 | with two fixes | 7907 of 7918 pass | RA8EMU-726, RA8FW-836 then RA8EMU-721, RA8EMU-727 |
| Windows x86_64 | cross-compiled, with two fixes | never run | RA8EMU-725, RA8EMU-723, RA8EMU-722 |

**macOS.** Two things stop a clean Mac build:

- `src/debug/rsp_poll.zig` uses `std.posix.MSG.PEEK`, which Zig 0.14.1 leaves
  as `void` on Darwin (RA8EMU-726). Zig 0.16.0 and 0.17.0 define it, so the
  local fallback goes away with the toolchain bump (RA8EMU-628).
- The pinned ra8-firmware dependency's `tools/zig_build/build.zig` switches on
  the untagged `builtin.os.version_range`, which only compiles off macOS
  (RA8FW-836). A newer Zig does not fix this; the firmware fix plus a pin bump
  here does (RA8EMU-721). Until then a fresh fetch on any Mac fails.

On the Mac, `zig build test` also has a webcam test failure and a leak that
predate the portability work (RA8EMU-727).

**Windows.** Two host-I/O paths assume POSIX:

- the USB/IP bridge handed a socket to a function that takes `fd_t`
  (fixed in RA8EMU-729);
- SCI stdin and I3C touch input read host handles with POSIX calls. One
  non-blocking helper, `src/periph/host_read.zig`, covers both (RA8EMU-725).

With those, piped stdin and `--touch @file` work. Typing into a real console
with `--console` does nothing yet, because a console read would block the run
(RA8EMU-723). The unit tests have not run on Windows (RA8EMU-722).

## Building on each host

The toolchain section of the [README](../README.md) covers installing Zig
0.14.1. Then:

```sh
zig build -Doptimize=ReleaseFast    # zig-out/bin/ra8_emulator
zig build test
zig build gate
```

The first build fetches the pinned ra8-firmware tarball for `ra8_rpc`, so it
needs network access and GitHub credentials while that repository is private.

**Windows** needs no Zig on the Windows machine. Cross-compile from Linux or a
Mac and copy the `.exe` over:

```sh
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu
# optionally tune for the target CPU, e.g. -Dcpu=znver4 for Zen 4
```

The binary lands in `zig-out/bin/ra8_emulator.exe`.

## Speed on three hosts

`blink.elf` from ra8-firmware (`just apps::build blink`), ReleaseFast. Each
cell is a single run, so differences of a few percent are noise.

| | Mac | dev (Linux) | win (Windows 11) |
|---|---:|---:|---:|
| CPU | Apple A18 Pro | Intel i5-12600K | AMD Ryzen 9 7900X |
| plain run, no flags | exit 0 | exit 0 | exit 0 |
| `--speed max --run-for 10s --no-idle-skip` | 4.72 s | 5.02 s | 4.56 s |
| speedup over real time | 2.12x | 1.99x | 2.19x |
| guest instructions per second | 4.06 M | 3.81 M | 4.20 M |
| `--speed max --run-for 10s`, idle skip on | 5.07 s | 5.33 s | 4.79 s |
| speedup, idle skip on | 1.97x | 1.88x | 2.09x |
| `--realtime --run-for 10s` wall | 10.03 s | 10.01 s | 10.02 s |
| achieved pace | 1.000x | 1.000x | 0.999x |
| drift / slips | 0.000 ms / 0 | 0.000 ms / 0 | 6.227 ms / 0 |

All three hosts retired the same 19,161,607 instructions in the 10 s runs and
toggled LED1 2381 times, so the result is the same machine on every host; only
the wall time differs.

The Windows binary was cross-compiled on the Mac with
`-Dtarget=x86_64-windows-gnu -Dcpu=znver4`.

Idle skip came out slower than `--no-idle-skip` on every host, the opposite of
what an image that mostly sleeps in WFI should show. RA8EMU-730 tracked
that down and is closed.

### Reproducing

```sh
# faster than the board? under 10 s wall means yes; 10 / wall is the speedup
time ./zig-out/bin/ra8_emulator blink.elf --speed max --run-for 10s --no-idle-skip

# can it hold 1x? the report gives the achieved pace and the drift
./zig-out/bin/ra8_emulator blink.elf --realtime --run-for 10s
```

Guest instructions per second is the retired count from the end-of-run report
divided by the wall time. For repeated samples and more images, see
[throughput-benchmark.md](throughput-benchmark.md).
