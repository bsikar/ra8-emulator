#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
# Ported from the validation workflow's windows-sr2 job
# (.github/workflows/validation.yml) for the BenchCI catalog task
# emulator-windows (RA8CI-169). Run from the repository root with Zig
# 0.17.0 on PATH. Phases run in the workflow's order and any failure
# stops the run. The runner-environment privilege check stays out: the
# dedicated worker's provisioning owns it, not the task.
set -euo pipefail

phase() {
    echo "=== windows-sr2: $1 ==="
}

host_tests() {
    if [ -f zig-out/bin/ra8_host_tests.exe ]; then
        ./zig-out/bin/ra8_host_tests.exe
    else
        ./zig-out/bin/ra8_host_tests
    fi
}

bin_hash() {
    if [ -f zig-out/bin/ra8_host_tests.exe ]; then
        sha256sum zig-out/bin/ra8_host_tests.exe | awk '{print $1}'
    else
        sha256sum zig-out/bin/ra8_host_tests | awk '{print $1}'
    fi
}

log_path() {
    printf '%s/sr2-%s.log' "$(mktemp -d)" "$1"
}

run_history_suite() {
    # $1: build profile label, $2: extra zig build flags
    rm -rf zig-out
    zig build ra8_host_tests-exe -j1 -Dtest-filter=host.history.session_test "$@"
    echo "binary_sha256=$(bin_hash)"
    log="$(log_path "$1")"
    host_tests >"$log" 2>&1
    echo "output_sha256=$(sha256sum "$log" | awk '{print $1}')"
    cat "$log"
    if ! grep -Eq '^[0-9]+/[0-9]+ host\.history\.session_test\.test\.host lifecycle keep refuses symlink dangling link and unexpected directory without outside writes\.\.\.OK$' "$log"; then
        echo "expected symlink test OK in $1 output" >&2
        exit 1
    fi
    if ! grep -Eq '^All [0-9]+ tests passed\.$' "$log"; then
        echo "expected 'All <N> tests passed.' in $1 output" >&2
        exit 1
    fi
}

phase "socket regression suites"
zig build ra8_host_tests-exe -j1 -Dtest-filter=host.sock
host_tests

phase "host history session suite (Debug)"
run_history_suite debug

phase "host history session suite (ReleaseFast)"
run_history_suite releasefast -Doptimize=ReleaseFast
