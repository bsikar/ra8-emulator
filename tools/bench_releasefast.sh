#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# Build ReleaseFast and time the Zig core on one fixed ELF image.
# See docs/throughput-benchmark.md for the corpus image and procedure.
#
#   tools/bench_releasefast.sh IMAGE [INSTRUCTIONS] [DEPS_PREFIX]

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 3 ]; then
    echo "usage: $0 IMAGE [INSTRUCTIONS] [DEPS_PREFIX]" >&2
    exit 2
fi

image=$(realpath "$1")
budget=${2:-2000000}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

if [ ! -f "$image" ]; then
    echo "ELF image not found: $image" >&2
    exit 2
fi

cd "$root"
if [ $# -eq 3 ]; then
    zig build -Doptimize=ReleaseFast -Ddeps-prefix="$3"
else
    zig build -Doptimize=ReleaseFast
fi

echo "ReleaseFast build; fixed image: $image"
shasum -a 256 "$image"
"$here/bench_core.sh" "$root/zig-out/bin/ra8_emulator" "$image" "$budget"
