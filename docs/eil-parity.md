# Where the other 39 EIL apps went

The number this document settles: the C emulator's EIL baseline was recorded as
**83 apps passing, zero failures**, while the app set is **122**. The 39 were
read for a long time as apps the suite skipped, or as a modelling gap that hid
them. They are neither. No app is excluded, skipped, or dropped: a full-set run
of `scripts/emu/eil_all.sh` cannot report 83 of 122, so the 83 was never a
full-set figure.

Everything below was re-derived from the `ra8-firmware` tree on `zig/dev`
(`scripts/emu/eil_all.sh`, `scripts/hil/lib/hil_conf.sh`,
`scripts/checks/check_hil_eil_parity.py`) rather than quoted. `tools/eil_set.sh`
re-derives the set and the mode histogram from any firmware tree.

## The set really is 122, and all of it is checkable

`eil_all.sh` discovers apps from two roots. `HIL_DIR` is
`examples/ek_ra8d2/hw_validated/hil`, walked by `hil_discover_apps()`, which
takes every directory one level down (the `README.md` in there is a file, so it
falls out without being named). `EIL_RA8P1_DIR` is
`examples/ra8p1_foundation`, from which it takes every app carrying a
`hil.conf`; those are EIL-only, since no RA8P1 HIL rig exists.

    118  app directories under hw_validated/hil   (119 entries, one is README.md)
      4  ra8p1_foundation apps with a hil.conf
    ---
    122  discovered

All 122 carry both a `hil.conf` and a `CMakeLists.txt`, so none falls out of
discovery and none is missing a build target. The `HIL_MODE` histogram over
exactly that set:

     91  uart_scrape
     29  jlink_memprobe
      1  rtt_scrape
      1  hil_eth_tcp
    ---
    122

Every one of those four modes is in the `run_one` dispatch that
`check_hil_eil_parity.py` parses as the EIL-capable set. Not one app in the set
is in a mode the emulator cannot check. The two `c6_camera_livestream` apps,
the only mode that is not EIL-capable, live under `hw_pending` and
`hil_needs_revalidation`, which neither harness discovers.

## The suite has no way to report a skip

`eil_all.sh` emits a verdict through one function, `eil_emit`, and the call
sites are 23 `FAIL` and 5 `PASS`. **There is no `SKIP` call site at all.** The
summary still counts a `skip` bucket and still prints a "SKIPPED (hardware-only
modes the emulator cannot check)" section, both of which are dead: nothing can
fill them. The header's promise that "there must be NO EIL skips" is enforced
by construction, not just by the parity gate.

A worker that dies does not vanish either. The parent gathers rows by iterating
the selected list, not by globbing result files:

    rf="${EIL_RUN_DIR}/${app}.result"
    if [ -f "$rf" ]; then line="$(cat "$rf")"
    else line="FAIL|${app}|unknown|worker produced no result (crash?)"; fi

A build failure, a missing ELF, and a crashed worker are all `FAIL`. So for a
full-set run, passed + failed = 122, always.

## What that leaves

83 passed with zero failures is therefore impossible for the full set, and the
39 were never selected. The figure came from a narrower run: `--only`, `--mode`,
or, most likely, a tree in which the set was smaller than it is now. It does not
match any mode subset in the current tree either (uart_scrape is 91,
jlink_memprobe 29), nor any obvious manifest cut: 93 apps set `HIL_EXPECT`, 92
set `HIL_EXPECT_NEGATIVE`, 29 set `HIL_PROBE_SYMBOL`, 14 set `HIL_EMU_ARGS`.

The practical consequence for this rewrite: **there is no recorded C-side
baseline to reach parity against.** The 83 cannot be compared with a Zig-side
number, because nobody knows which 83 apps it covered. A parity claim for PR #15
needs a fresh full-set run of both emulators over the same 122, not a
comparison against this figure. Until that run exists, the honest statement is
that the Zig side matches the C side on the 36 images built here, and that the
remaining 86 are unmeasured on either.

## Re-deriving it

    tools/eil_set.sh /path/to/ra8-firmware

prints the discovered count and the mode histogram. For the verdict arithmetic:

    grep -o 'eil_emit "$rf" [A-Z]*' scripts/emu/eil_all.sh | sort | uniq -c
