#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
# Run ONE already-built test suite per command window (RA8EMU-1182).
# Usage: bash tools/test_batch.sh BINARY LOG
# Logs append on every attempt. A cut suite must be rerun from its start:
# Zig's default runner cannot resume at an individual test. An attempt
# without a terminal marker is incomplete, never a pass.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 BINARY LOG" >&2
    exit 2
fi
seconds=${RA8_TEST_TIMEOUT_SECONDS:-800}
if [[ ! $seconds =~ ^[1-9][0-9]{0,2}$ ]] || (( seconds > 800 )); then
    echo "RA8_TEST_TIMEOUT_SECONDS must be an integer from 1 to 800" >&2
    exit 2
fi
binary=$(realpath "$1")
if [ ! -f "$binary" ] || [ ! -x "$binary" ]; then
    echo "$binary: not an executable test binary" >&2
    exit 2
fi
command -v timeout >/dev/null
log=$2
# Open once, before starting the suite, so an unwritable log cannot lose results.
exec 3>>"$log"
printf '\nSTART %s binary=%s timeout=%ss\n' "$(date -u +%FT%TZ)" "$binary" "$seconds" >&3
finish() {
    local status=$? result=FAILED
    case $status in
        0) result=COMPLETE ;;
        124|130|137|143) result=CUT ;;
    esac
    printf '%s %s exit=%s\n' "$result" "$(date -u +%FT%TZ)" "$status" >&3
    echo "$result: $binary (exit=$status, log=$log)"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
status=0
# Apply the memory cap only to execution, never to Zig compilation.
(
    ulimit -v 3000000
    exec timeout --signal=TERM --kill-after=5s "${seconds}s" "$binary"
) >&3 2>&1 || status=$?
exit "$status"
