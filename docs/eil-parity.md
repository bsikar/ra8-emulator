# Where the other 39 EIL apps went

The number this document settles: the C emulator's EIL baseline was recorded as
**83 apps passing, zero failures**, while the app set was **122** when that was
written. The 39 were read for a long time as apps the suite skipped, or as a
modelling gap that hid them. They are neither. No app is excluded, skipped, or
dropped: a full-set run of `scripts/emu/eil_all.sh` cannot report 83 of a set
it enumerates, so the 83 was never a full-set figure.

**The set is not a fixed number, and that is the rest of the answer.** This
document recorded 122 when it was written on 2026-09-28 (emulator commit
`5b5effd`). Re-deriving it two days later against `ra8-firmware` `fcb624f` on
`zig/dev` gives **125**: three more `uart_scrape` apps under
`hw_validated/hil`, nothing removed. So the set grew by three in two days, on
the only tree either emulator is measured against. A count of it is meaningful
only against the revision it was taken from, so the numbers below now carry
one and `tools/eil_set.sh` prints the revision beside the count. Quoting a
bare figure is exactly how "83 of 122" outlived the tree it was measured on,
and 122 was already on its way to becoming another one.

The revision the 122 was taken at is not recorded, and this tree's history
does not reach back far enough to recover it, so it is left unstated rather
than guessed.

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

At `fcb624f` (`zig/dev`):

    121  app directories under hw_validated/hil   (122 entries, one is README.md)
      4  ra8p1_foundation apps with a hil.conf    (blink_ra8p1, npu_infer,
    ---                                            npu_smoke, npu_vela)
    125  discovered

All 125 carry a `hil.conf`, so none falls out of discovery. The `HIL_MODE`
histogram over exactly that set:

     94  uart_scrape
     29  jlink_memprobe
      1  rtt_scrape
      1  hil_eth_tcp
    ---
    125

When this document was first written on 2026-09-28 the same command gave
118 + 4 = 122 with 91 `uart_scrape`. The three that have arrived since are all
`uart_scrape`, which is why only that row moved.

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
full-set run, passed + failed equals the discovered count, always, whatever
that count happens to be that week.

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

## The probe windows are not reachable at the firmware's own clock

Measured 2026-09-30, and it constrains any full-set parity run.

`jlink_memprobe` is the mode the 36 built images use, and its contract is a
window in *seconds*: read `HIL_PROBE_SYMBOL`, wait `HIL_PROBE_SECONDS`, assert
the symbol advanced by `HIL_PROBE_MIN_ADVANCE`, with `HIL_PROBE_FAILURE_SYMBOL`
still at or under `HIL_PROBE_MAX_FAILURE`. Windows in this tree run 3 to 5
seconds, plus a boot window of 12 to 15 on the four filesystem apps.

The model charges one cycle per instruction, so a modelled second costs as many
instructions as the firmware's clock has hertz. `k_ra8_cpuclk0_hz` is
1,000,000,000: an image that completes CGC bring-up runs its probe window at a
gigahertz, so a 4-second window is **four billion instructions**. Measured on
this box at roughly 2.5 M instructions per second of wall time, that is over
four hours for one image.

The exception is the handful that never leave the clock they reset on.
`blink` stays on MOCO at about 8.4 MHz, so its 3-second window is 25.2 M
instructions and runs in 2 seconds of wall time. It passes its contract outright:
`g_blink_tick` reaches 6 against a `HIL_PROBE_MIN_ADVANCE` of 5.

    blink            --ms 3000   2 s wall     g_blink_tick 6   >= 5   PASS
    threadx_blink    --ms 4000   519 s wall   (did not reach the window)

So the two ends of the corpus differ by two and a half orders of magnitude in
cost per modelled second, and the split is not slow images against fast ones:
it is images that brought the PLL up against images that did not.

What this means for PR #15. A full-set parity run cannot be a straight
execution of every probe window; the fast-clock images need either a longer
wall budget than a CI run has, or an idle seam. The ThreadX images spend that
budget in `__tx_ts_wait`, a three-instruction spin with interrupts briefly
open, waiting for the SysTick handler to make a thread ready. Nothing in it
needs to be executed four billion times, so the seam is available, but it is
its own slice and it is not written yet. Until it is, the parity statement for
the timed images has to name the budget it ran under rather than claim the
contract was met.

## Re-deriving it

    tools/eil_set.sh /path/to/ra8-firmware

prints the tree's revision, the discovered count and the mode histogram. Add
`--list` for the app names, so the next time the count moves the difference is
a diff rather than a discrepancy nobody can place. For the verdict arithmetic:

    grep -o 'eil_emit "$rf" [A-Z]*' scripts/emu/eil_all.sh | sort | uniq -c
