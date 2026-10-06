#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# Run the firmware image that deliberately divides by zero and pin the shared
# handler's decoded output (RA8EMU-188).
#
#   tools/fault_handler_corpus.sh EMULATOR DIR [CPU]
#
# DIR contains the named firmware ELF. The app list is deliberately explicit:
# this proof exercises fault_div0_hil and no unrelated HIL or corpus images.

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "usage: $0 EMULATOR DIR [CPU]" >&2
    exit 2
fi

emulator=$(realpath "$1")
dir=$2
cpu=${3:-zig}
apps=(fault_div0_hil)

for app in "${apps[@]}"; do
    image=$dir/$app.elf
    if [ ! -e "$image" ]; then
        echo "$image: missing" >&2
        exit 1
    fi

    output=$(
        "$emulator" "$image" \
            --cpu "$cpu" \
            --console \
            --instructions 3000000
    )

    grep -Fqx 'console> [EXC] ERROR: exception=6' <<<"$output"
    grep -Fqx 'console> [EXC] ERROR: cfsr =33554432' <<<"$output"
    grep -Fqx 'console> [EXC] ERROR: cause=DIVBYZERO' <<<"$output"
    grep -Eq '^console> \[EXC\] ERROR: stacked_pc=[1-9][0-9]*$' <<<"$output"
    if grep -Eq '^console> \[EXC\] ERROR: (mm_fault_addr|bus_fault_addr|mmfar|bfar)' <<<"$output"; then
        echo "$app: reported a fault address with MMARVALID and BFARVALID clear" >&2
        exit 1
    fi

    causes=$(grep '^console> \[EXC\] ERROR: cause=' <<<"$output")
    if [ "$causes" != 'console> [EXC] ERROR: cause=DIVBYZERO' ]; then
        printf 'unexpected decoded causes for %s:\n%s\n' "$app" "$causes" >&2
        exit 1
    fi
done
