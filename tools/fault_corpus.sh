#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# fault_corpus.sh -- run a firmware image's I2C error path under each
# `--fault` mode and diff what the firmware reported against
# tools/fault_expected.md (RA8EMU-516).
#
#   tools/fault_corpus.sh EMULATOR DIR [CPU]
#
# DIR is ra8-firmware's zig-out/arm (or any directory holding
# iic_b_facade_demo.elf). That demo reads the GT911 the board fits at
# i2c:touch@0x5D and prints `ctrl=OK|NAK id0=0xHH`, so faulting the fitted
# part (`--fault @i2c:touch@0x5D=MODE`, RA8EMU-536) shows the firmware's own
# NACK, bad-data and bus-busy paths. The clean row is the control: a run
# without --fault must not move. bus_low holds the touch line low, which the
# I3C model shows as a bus that never reads free (RA8EMU-537).
#
# CPU is the backend, zig by default. Exits 1 on any difference. Update the expected file in
# the same PR as a change that means to move a row.

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "usage: $0 EMULATOR DIR [CPU]" >&2
    exit 2
fi
emulator=$(realpath "$1")
image=$2/iic_b_facade_demo.elf
cpu=${3:-zig}
here=$(cd "$(dirname "$0")" && pwd)
target=@i2c:touch@0x5D

if [ ! -e "$image" ]; then
    echo "$image: missing" >&2
    exit 1
fi

row() {
    local mode=$1 out console i3c
    local args=("$image" --cpu "$cpu" --instructions 3000000)
    [ "$mode" != none ] && args+=(--fault "$target=$mode")
    out=$("$emulator" "${args[@]}" </dev/null 2>&1 || true)
    console=$(grep -m1 '^SCI console:' <<<"$out" | sed 's/.*last "\(.*\)"/\1/')
    i3c=$(grep -m1 '^I3C:' <<<"$out" | grep -o '[0-9]* address(es) NACKed' || echo -)
    printf '| %s | %s | %s |\n' "$mode" "${console:--}" "$i3c"
}

actual=$(
    echo '| fault | console | I3C |'
    echo '|---|---|---|'
    for mode in none disconnected nack:1 stuck:0xA5 garbage:7 bus_low; do
        row "$mode"
    done
)
diff -u "$here/fault_expected.md" <(printf '%s\n' "$actual")
