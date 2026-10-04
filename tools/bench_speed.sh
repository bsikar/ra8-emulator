#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# bench_speed.sh -- the RA8EMU-180 throughput benchmark: which speed factors
# are reachable today. Runs each image unpaced on the Zig core for the same
# virtual time, with idle fast-forward on (the default) and off, and prints
# wall time, the effective speed factor (virtual seconds per wall second) and
# CPU0 instructions retired per wall second. Use a ReleaseFast build; Debug numbers do not
# count. See docs/throughput-benchmark.md.
#
#   tools/bench_speed.sh EMULATOR RUN_FOR IMAGE...
#
# RUN_FOR is --run-for's virtual duration (1s, 10s, 1m). NAME_ns.elf beside
# NAME.elf is passed as --ns and NAME_cpu1.elf as --cpu1, as the corpus does.

set -euo pipefail

if [ $# -lt 3 ]; then
    echo "usage: $0 EMULATOR RUN_FOR IMAGE..." >&2
    exit 2
fi
emulator=$1
run_for=$2
shift 2

out=$(mktemp)
trap 'rm -f "$out"' EXIT

# Virtual nanoseconds in a --run-for duration.
virtual_ns() {
    local n=${1%%[a-z]*} unit=${1##*[0-9.]}
    case $unit in
        s) echo $(( n * 1000000000 )) ;; m) echo $(( n * 60000000000 )) ;;
        h) echo $(( n * 3600000000000 )) ;; d) echo $(( n * 86400000000000 )) ;;
        *) echo "unknown unit in $1" >&2; exit 2 ;;
    esac
}
virtual=$(virtual_ns "$run_for")

run() {
    local image=$1 mode=$2 started ended status=0 retired
    local stem=${image%.elf} companions=() skip=()
    [ -f "${stem}_ns.elf" ] && companions+=(--ns "${stem}_ns.elf")
    [ -f "${stem}_cpu1.elf" ] && companions+=(--cpu1 "${stem}_cpu1.elf")
    [ "$mode" = stepped ] && skip+=(--no-idle-skip)
    started=$(date +%s%N)
    "$emulator" "$image" "${companions[@]}" --cpu zig --run-for "$run_for" \
        "${skip[@]}" > "$out" 2>&1 || status=$?
    ended=$(date +%s%N)
    # Retired instructions, not elapsed cycles: a sleeping core's cycles pass
    # without retiring anything.
    retired=$(sed -n 's/^zig core: ran \([0-9]*\) instructions.*/\1/p' "$out" | head -1)
    awk -v name="$(basename "$stem")" -v mode="$mode" -v rc="$status" \
        -v wall=$(( ended - started )) -v virt="$virtual" -v ret="${retired:-0}" \
        'BEGIN { printf "%-44s %-7s rc=%-3s %9.0f ms %10.2fx %8.1f M instr/s\n",
                 name, mode, rc, wall / 1e6, virt / wall, ret / (wall / 1e9) / 1e6 }'
}

printf '%-44s %-7s %-6s %12s %11s %17s\n' image mode status wall speed throughput
for image in "$@"; do
    run "$image" skip
    run "$image" stepped
done
