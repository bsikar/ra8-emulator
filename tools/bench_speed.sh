#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# bench_speed.sh -- the RA8EMU-180 throughput benchmark: which speed factors
# are reachable today. Runs each image unpaced on the Zig core for the same
# virtual time, with idle fast-forward on (the default) and off, and prints
# wall time, effective speed, and per-core retired instructions per wall second.
# Use a ReleaseFast build; Debug numbers do not count. See
# docs/throughput-benchmark.md.
#
#   tools/bench_speed.sh EMULATOR RUN_FOR IMAGE...
#
# RUN_FOR is --run-for's virtual duration (1s, 10s, 1m). NAME_ns.elf beside
# NAME.elf is passed as --ns and NAME_cpu1.elf as --cpu1, as the corpus does.
# BENCH_SPEED_REPEATS defaults to 3. BENCH_SPEED_LOG_DIR retains raw logs.

set -euo pipefail

if [ $# -lt 3 ]; then
    echo "usage: $0 EMULATOR RUN_FOR IMAGE..." >&2
    exit 2
fi
emulator=$1
run_for=$2
shift 2
repeats=${BENCH_SPEED_REPEATS:-3}

case $repeats in
    *[!0-9]* | 0 | 0*)
        echo "BENCH_SPEED_REPEATS must be a positive integer" >&2
        exit 2
        ;;
esac
[ -x "$emulator" ] || { echo "emulator is not executable: $emulator" >&2; exit 2; }
for image in "$@"; do
    [ -r "$image" ] || { echo "image is not readable: $image" >&2; exit 2; }
done

retain_logs=0
if [ -n "${BENCH_SPEED_LOG_DIR:-}" ]; then
    run_id="run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    log_dir=$BENCH_SPEED_LOG_DIR/$run_id
    mkdir -p "$log_dir" || exit 1
    retain_logs=1
else
    log_dir=$(mktemp -d)
fi
cleanup() {
    [ "$retain_logs" -eq 1 ] || rm -rf "$log_dir"
}
trap cleanup EXIT

# Virtual nanoseconds in a --run-for duration.
virtual_ns() {
    local n=${1%%[a-z]*} unit=${1##*[0-9.]}
    case $unit in
        s) echo $(( n * 1000000000 )) ;; m) echo $(( n * 60000000000 )) ;;
        h) echo $(( n * 3600000000000 )) ;; d) echo $(( n * 86400000000000 )) ;;
        *) echo "unknown unit in $1" >&2; exit 2 ;;
    esac
}

sample_valid() {
    local status=$1 out=$2 cpu0=$3 cpu1=$4 expected_cpu1=$5
    [ "$status" -eq 0 ] && [ -n "$cpu0" ] && \
        { [ "$expected_cpu1" -eq 0 ] || [ -n "$cpu1" ]; } && \
        grep -q '^soak: no events$' "$out" && \
        ! grep -q '^CPU1: halted' "$out" && \
        ! grep -q '^soak: stopped on' "$out"
}

virtual=$(virtual_ns "$run_for")
overall=0

run_mode() {
    local image=$1 mode=$2 ordinal=$3 stem name repeat log started ended wall status
    local cpu0 cpu1 valid expected_cpu1=0 best_set=0 best_valid=0
    local best_repeat best_log best_wall best_status best_cpu0 best_cpu1
    local companions=() skip=()
    stem=${image%.elf}
    name=$(basename "$stem")
    [ -f "${stem}_ns.elf" ] && companions+=(--ns "${stem}_ns.elf")
    if [ -f "${stem}_cpu1.elf" ]; then
        companions+=(--cpu1 "${stem}_cpu1.elf")
        expected_cpu1=1
    fi
    [ "$mode" = stepped ] && skip+=(--no-idle-skip)

    for ((repeat = 1; repeat <= repeats; repeat++)); do
        log=$log_dir/${ordinal}-${name}-${mode}-${repeat}.log
        started=$(date +%s%N)
        status=0
        "$emulator" "$image" "${companions[@]}" --cpu zig --run-for "$run_for" \
            "${skip[@]}" > "$log" 2>&1 || status=$?
        ended=$(date +%s%N)
        wall=$(( ended - started ))
        cpu0=$(sed -n 's/^zig core: ran \([0-9]*\) instructions.*/\1/p' "$log" | head -1)
        cpu1=$(sed -n 's/^CPU1: loaded .* ran \([0-9]*\) instructions over .*/\1/p' "$log" | head -1)
        valid=no
        sample_valid "$status" "$log" "$cpu0" "$cpu1" "$expected_cpu1" && valid=yes
        printf 'bench_speed: image=%s mode=%s repeat=%d valid=%s rc=%d wall_ns=%d log=%s\n' \
            "$name" "$mode" "$repeat" "$valid" "$status" "$wall" "$log" >&2

        if [ "$valid" = yes ]; then
            if [ "$best_valid" -eq 0 ] || [ "$wall" -lt "$best_wall" ]; then
                best_set=1
                best_valid=1
                best_repeat=$repeat
                best_log=$log
                best_wall=$wall
                best_status=$status
                best_cpu0=$cpu0
                best_cpu1=$cpu1
            fi
        elif [ "$best_valid" -eq 0 ] && \
                { [ "$best_set" -eq 0 ] || [ "$wall" -lt "$best_wall" ]; }; then
            best_set=1
            best_repeat=$repeat
            best_log=$log
            best_wall=$wall
            best_status=$status
            best_cpu0=$cpu0
            best_cpu1=$cpu1
        fi
    done

    if [ "$best_valid" -eq 0 ]; then
        overall=1
        valid=no
    else
        valid=yes
    fi
    local cpu0_rate=invalid cpu1_rate=-
    if [ -n "$best_cpu0" ]; then
        cpu0_rate=$(awk -v ret="$best_cpu0" -v wall="$best_wall" \
            'BEGIN { printf "%.1f", ret / (wall / 1e9) / 1e6 }')
    fi
    if [ "$expected_cpu1" -eq 1 ]; then
        cpu1_rate=invalid
        if [ -n "$best_cpu1" ]; then
            cpu1_rate=$(awk -v ret="$best_cpu1" -v wall="$best_wall" \
                'BEGIN { printf "%.1f", ret / (wall / 1e9) / 1e6 }')
        fi
    fi
    awk -v name="$name" -v mode="$mode" -v repeat="$best_repeat" \
        -v valid="$valid" -v rc="$best_status" -v wall="$best_wall" \
        -v virt="$virtual" -v cpu0="$cpu0_rate" -v cpu1="$cpu1_rate" \
        -v logfile="$best_log" \
        'BEGIN { printf "%-36s %-7s %3d %-5s %3d %9.0f %9.2f %10s %10s %s\n",
                 name, mode, repeat, valid, rc, wall / 1e6, virt / wall,
                 cpu0, cpu1, logfile }'
}

printf '%-36s %-7s %3s %-5s %3s %9s %9s %10s %10s %s\n' \
    image mode rep valid rc wall_ms speed cpu0_Mips cpu1_Mips log
ordinal=0
for image in "$@"; do
    ordinal=$(( ordinal + 1 ))
    run_mode "$image" skip "$ordinal"
    run_mode "$image" stepped "$ordinal"
done
result=$overall
cleanup
trap - EXIT
exit "$result"
