#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# speed_invariance.sh -- the RA8EMU-183 check that speed changes wall time and
# nothing else. Runs one image on the Zig core for the same virtual budget at
# --speed 0.1, 1, 5 and max and diffs every report line except the pace line
# against the max run. Exits 1 if any speed's report differs.
#
#   tools/speed_invariance.sh EMULATOR IMAGE [INSTRUCTIONS] [EXTRA_ARGS...]
#
# INSTRUCTIONS is the virtual budget in cycles (default 200000000, 0.2 s of
# virtual time, so the 0.1x run takes about 2 s of wall time). EXTRA_ARGS go
# to every run, e.g. --rtc-start 2026-01-01T00:00:00. NAME_ns.elf beside
# NAME.elf is passed as --ns and NAME_cpu1.elf as --cpu1, as the corpus does.
# Use a ReleaseFast build so 5x and max are not limited by the host.

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 EMULATOR IMAGE [INSTRUCTIONS] [EXTRA_ARGS...]" >&2
    exit 2
fi
emulator=$1
image=$2
budget=${3:-200000000}
shift $(( $# < 3 ? $# : 3 ))
extra=("$@")

companions=()
stem=${image%.elf}
[ -f "${stem}_ns.elf" ] && companions+=(--ns "${stem}_ns.elf")
[ -f "${stem}_cpu1.elf" ] && companions+=(--cpu1 "${stem}_cpu1.elf")

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

run() {
    local speed=$1 started ended status=0
    started=$(date +%s%N)
    "$emulator" "$image" "${companions[@]}" --cpu zig --instructions "$budget" \
        --speed "$speed" "${extra[@]}" > "$out/$speed.raw" 2>&1 || status=$?
    ended=$(date +%s%N)
    echo "rc=$status" >> "$out/$speed.raw"
    grep -v '^pace: ' "$out/$speed.raw" > "$out/$speed.report" || true
    printf '%-4s %8d ms  %s\n' "$speed" $(( (ended - started) / 1000000 )) \
        "$(grep '^pace: ' "$out/$speed.raw" || echo 'pace: unpaced')"
}

failed=0
run max
for speed in 0.1 1 5; do
    run "$speed"
    if ! diff -u "$out/max.report" "$out/$speed.report" > "$out/$speed.diff"; then
        echo "DIFF at ${speed}x:"
        head -20 "$out/$speed.diff"
        failed=1
    fi
done
[ $failed -eq 0 ] && echo "same report at 0.1x, 1x, 5x and max"
exit $failed
