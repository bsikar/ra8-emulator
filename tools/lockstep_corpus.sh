#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# lockstep_corpus.sh -- run every ELF in a directory under --cpu lockstep and
# print the RA8EMU-19 divergence table: how each image ended, then matched,
# diverged and skipped per instruction class, summed over the whole corpus.
#
#   tools/lockstep_corpus.sh EMULATOR DIR [INSTRUCTIONS]
#
# Exits 1 when any image diverged, 0 otherwise. An image that stops on an
# encoding the Zig core does not know yet is coverage, not divergence.

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 EMULATOR DIR [INSTRUCTIONS]" >&2
    exit 2
fi
emulator=$1
dir=$2
budget=${3:-100000}

rows=$(mktemp)
trap 'rm -f "$rows"' EXIT

echo "| image | end |"
echo "|---|---|"
for image in "$dir"/*.elf; do
    out=$("$emulator" "$image" --cpu lockstep --instructions "$budget" 2>&1 || true)
    end=$(printf '%s\n' "$out" | sed -n 's/^lockstep: //p' | head -n 1)
    echo "| $(basename "$image") | ${end:-no lockstep line} |"
    printf '%s\n' "$out" | grep '^| ' | grep -v '^| class \|^| total ' >>"$rows" || true
done
echo

awk -F'|' '
function trim(s) { gsub(/^ +| +$/, "", s); return s }
{
    class = trim($2)
    if (!(class in matched)) order[++n] = class
    matched[class] += trim($3); diverged[class] += trim($4); skipped[class] += trim($5)
}
END {
    print "| class | matched | diverged | skipped |"
    print "|---|---:|---:|---:|"
    for (i = 1; i <= n; i++) {
        c = order[i]
        print "| " c " | " matched[c] " | " diverged[c] " | " skipped[c] " |"
        tm += matched[c]; td += diverged[c]; ts += skipped[c]
    }
    print "| total | " tm + 0 " | " td + 0 " | " ts + 0 " |"
    exit td > 0
}' "$rows"
