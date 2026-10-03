#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# gdb_corpus.sh -- gdb-multiarch against a real firmware image, on one core
# or two: attach, break on a function, continue, step, read registers and
# memory and backtrace on CPU0, then the same on CPU1 as thread 2 when a
# second image is given. tools/gdb_batch.sh covers a hand-built fixture;
# this is the same check on what the firmware tree actually builds.
#
#   tools/gdb_corpus.sh EMULATOR CPU0_ELF [CPU1_ELF] [FUNCTION] [GDB]
#
# FUNCTION defaults to main and must be one CPU0 reaches. On CPU1 the
# session breaks a few instructions past where it stopped and steps from
# there, so it needs no symbol of the second image's.
# CPU=zig serves both cores from the Zig core (--cpu zig, RA8EMU-110), CPU1
# as thread 2 (RA8EMU-338).
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 EMULATOR CPU0_ELF [CPU1_ELF] [FUNCTION] [GDB]" >&2
    exit 2
fi
emulator=$1
image=$2
second=${3:-}
function=${4:-main}
gdb=${5:-gdb-multiarch}
cpu=${CPU:-unicorn}
port=$((4500 + RANDOM % 400))
work=$(mktemp -d)
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

args=("$image" --cpu "$cpu")
[ -n "$second" ] && args+=(--cpu1 "$second")
"$emulator" "${args[@]}" --gdb "$port" 2>"$work/emu" &
pid=$!
for _ in $(seq 50); do
    grep -q listening "$work/emu" && break
    sleep 0.1
done

commands=(-ex "target remote :$port" -ex "break $function" -ex continue -ex stepi
    -ex 'info registers pc sp lr' -ex 'x/4xw $sp' -ex bt)
if [ -n "$second" ]; then
    commands+=(-ex 'thread 2' -ex 'break *($pc + 8)' -ex continue -ex stepi
        -ex 'info registers pc sp' -ex 'x/2xw $pc' -ex bt)
fi
commands+=(-ex detach)
timeout 120 "$gdb" -batch -nx "$image" "${commands[@]}" >"$work/out" 2>&1 || true

failed=0
expect() {
    if ! grep -qF -- "$1" "$work/out"; then
        echo "gdb_corpus: missing: $1"
        failed=1
    fi
}
expect "Breakpoint 1, "
expect "$function ("
expect "#0  "
expect "pc             0x"
expect "sp             0x"
if [ -n "$second" ]; then
    expect "[Switching to thread 2 (Thread 2)]"
    expect "Thread 2 hit Breakpoint 2, "
fi
expect "[Inferior 1 (Remote target) detached]"
if [ "$failed" -ne 0 ]; then
    grep -v "Python\|ModuleNotFound" "$work/out" >&2 || true
    exit 1
fi
echo "gdb_corpus ($cpu): $(basename "$image")${second:+ + $(basename "$second")} passed"
