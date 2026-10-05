#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# npu_vela_conv.sh -- pin ra8-firmware's npu_vela_conv on the emulator
# (RA8EMU-173). The example runs a real Vela-compiled int8 conv on the
# RA8P1 Ethos-U55 and prints PASS only when all 256 output bytes equal the
# TFLM golden.
#
#   tools/npu_vela_conv.sh EMULATOR ELF [CPU...]
#
# ELF is npu_vela_conv.elf from ra8-firmware's `zig build arm`. CPU defaults
# to "zig". Each run must exit 0, print "npu_vela_conv: PASS" on the
# console and report one Vela program that ran to STOP; any miss exits 1.

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 EMULATOR ELF [CPU...]" >&2
    exit 2
fi
emulator=$1
elf=$2
shift 2
cpus=("$@")
[ ${#cpus[@]} -gt 0 ] || cpus=(zig)

status=0
for cpu in "${cpus[@]}"; do
    if ! out=$("$emulator" "$elf" --part ra8p1 --ms 2000 --cpu "$cpu" 2>&1); then
        echo "npu_vela_conv[$cpu]: emulator exited non-zero" >&2
        status=1
        continue
    fi
    if ! grep -q 'SCI console: .*last "npu_vela_conv: PASS"' <<<"$out"; then
        echo "npu_vela_conv[$cpu]: no PASS line" >&2
        status=1
    elif ! grep -q 'NPU(Ethos-U55): 1 Vela program(s) ran to STOP' <<<"$out"; then
        echo "npu_vela_conv[$cpu]: no Vela program ran to STOP" >&2
        status=1
    else
        echo "npu_vela_conv[$cpu]: PASS"
    fi
done
exit $status
