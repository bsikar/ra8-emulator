#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# plug_corpus.sh -- run a corpus image while a `--faults FILE` schedule
# pulls a part off its line, and diff what the firmware reported against
# tools/plug_expected.md (RA8EMU-702).
#
#   tools/plug_corpus.sh EMULATOR DIR
#
# DIR is ra8-firmware's zig-out/arm (or any directory holding
# battery_monitor_demo.elf). That demo reads the MAX17048 every period over
# the touch line, which is where --click fits it (i2c:touch@0x36), prints
# `battery: soc=N% chg=Y|N PASS`, and halts with `battery: NAK (no fuel
# gauge)` on a NACK. The clean row is the control; the unplug row runs
# tools/plug/gauge_unplug.txt, so the firmware's own NAK line shows that
# it saw the part leave mid-run.
#
# Runs on the Zig core. Exits 1 on any difference. Update the expected file
# in the same PR as a change that means to move a row.

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 EMULATOR DIR" >&2
    exit 2
fi
emulator=$(realpath "$1")
image=$2/battery_monitor_demo.elf
here=$(cd "$(dirname "$0")" && pwd)

if [ ! -e "$image" ]; then
    echo "$image: missing" >&2
    exit 1
fi

row() {
    local name=$1 file=$2 out console stop
    local args=("$image" --click --run-for 3s)
    [ "$file" != - ] && args+=(--faults "$here/plug/$file")
    out=$("$emulator" "${args[@]}" </dev/null 2>&1 || true)
    console=$(grep -m1 '^SCI console:' <<<"$out" | sed 's/.*last "\(.*\)"/\1/')
    stop=$(grep -m1 '^soak:' <<<"$out" | sed 's/^soak: //' || echo -)
    printf '| %s | %s | %s |\n' "$name" "${console:--}" "${stop:--}"
}

actual=$(
    echo '| schedule | console | soak |'
    echo '|---|---|---|'
    row none -
    row gauge_unplug gauge_unplug.txt
)
diff -u "$here/plug_expected.md" <(printf '%s\n' "$actual")
