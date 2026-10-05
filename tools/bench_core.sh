#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# bench_core.sh -- the RA8EMU-12 throughput benchmark. Runs an ELF or every
# ELF in a directory for the same budget on the Zig core, subtracts the
# load-only time (budget 0) and prints net milliseconds and instructions per
# second for each image.
#
#   tools/bench_core.sh EMULATOR IMAGE_OR_DIR [INSTRUCTIONS] [RUNS]
#
# Build the emulator with -Doptimize=ReleaseFast first; a Debug number says
# nothing. An image the Zig core does not spend the whole budget on (it went
# idle with nothing to wake it, or stopped) is marked with how far it got and
# left out of the total, since its time is not for the full budget.
#
# An image runs the way the corpus runs it: NAME_cpu1.elf beside NAME.elf is
# passed as --cpu1 and NAME_ns.elf as --ns, and those companions are not
# timed on their own (RA8EMU-442). Each time is the minimum of RUNS runs
# (default 3), since a single run of a short image swings by a third.

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 EMULATOR IMAGE_OR_DIR [INSTRUCTIONS] [RUNS]" >&2
    exit 2
fi
emulator=$1
dir=$2
budget=${3:-2000000}
runs=${4:-3}

now() { date +%s%N; }

# The companion arguments for IMAGE, one per line: --cpu1 or --ns and the
# companion ELF, when one sits beside it.
companions() {
    local stem=${1%.elf}
    if [ -f "${stem}_cpu1.elf" ]; then
        printf '%s\n' --cpu1 "${stem}_cpu1.elf"
    fi
    if [ -f "${stem}_ns.elf" ]; then
        printf '%s\n' --ns "${stem}_ns.elf"
    fi
}

# Wall milliseconds for one run of IMAGE on the Zig core for N instructions.
wall() {
    local start end extra
    mapfile -t extra < <(companions "$1")
    start=$(now)
    "$emulator" "$1" --cpu zig --instructions "$2" "${extra[@]}" >/dev/null 2>&1 || true
    end=$(now)
    echo $(((end - start) / 1000000))
}

# The smaller of two numbers.
least() { if [ "$1" -lt "$2" ]; then echo "$1"; else echo "$2"; fi; }

# How the Zig core ended IMAGE: its "zig core:" summary line.
ending() {
    local out extra
    mapfile -t extra < <(companions "$1")
    out=$("$emulator" "$1" --cpu zig --instructions "$budget" "${extra[@]}" 2>&1 || true)
    printf '%s\n' "$out" | sed -n 's/^zig core: //p' | head -n 1
}

# Net milliseconds for IMAGE: the minimum of RUNS runs, less the minimum
# zero-instruction load.
timed() {
    local zig=999999999 zig0=999999999 i
    for ((i = 0; i < runs; i++)); do
        zig=$(least "$zig" "$(wall "$1" "$budget")")
        zig0=$(least "$zig0" "$(wall "$1" 0)")
    done
    echo "$((zig - zig0))"
}

ips() { awk -v n="$budget" -v ms="$1" 'BEGIN { printf "%.0f", (ms > 0) ? n * 1000 / ms : 0 }'; }

echo "budget $budget instructions per image, minimum of $runs runs, zig core"
echo
echo "| image | ms | instructions/s |"
echo "|---|---|---|"
total=0
if [ -f "$dir" ]; then
    images=("$dir")
else
    shopt -s nullglob
    images=()
    for image in "$dir"/*.elf; do
        case $image in
        *_cpu1.elf | *_ns.elf) [ -f "${image%_*.elf}.elf" ] && continue ;;
        esac
        images+=("$image")
    done
    shopt -u nullglob
fi
if [ "${#images[@]}" -eq 0 ]; then
    echo "no ELF image found in $dir" >&2
    exit 2
fi
for image in "${images[@]}"; do
    name=$(basename "$image")
    end=$(ending "$image")
    # The Zig core ends at a stretch boundary, and a skipped loop retires
    # whole trips, so a full run can go a little past the budget
    # (RA8EMU-594). Fewer than the budget means it stopped early.
    ran=$(printf '%s\n' "$end" | sed -n 's/^ran \([0-9][0-9]*\) instructions.*/\1/p')
    if [ -z "$ran" ] || [ "$ran" -lt "$budget" ]; then
        echo "| $name | not timed: ${end:-no summary line} | |"
        continue
    fi
    ms=$(timed "$image")
    [ "$ms" -lt 1 ] && ms=1
    total=$((total + ms))
    echo "| $name | $ms | $(ips "$ms") |"
done
echo "| total | $total | |"
