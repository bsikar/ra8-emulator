#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
# Ported from the validation workflow's suites job
# (.github/workflows/validation.yml) for the BenchCI catalog task
# emulator-suites (RA8CI-169). Run from the repository root with Zig
# 0.17.0 on PATH. Phases run in the workflow's order and any failure
# stops the run. The signed-boot phase keeps its evidence log under
# artifacts/, mirroring the workflow's upload-artifact step.
set -euo pipefail

phase() {
    echo "=== suites: $1 ==="
}

phase "format check"
zig fmt --check --exclude tests/consumer/zig-pkg build.zig build_tests.zig src tests tools

phase "gate (length and terminology)"
zig build gate -j1

phase "memory writer guard"
zig run tools/memory_writer_guard.zig -- src

phase "build"
zig build -j1

phase "build with GUI"
zig build -Dgui -j1

phase "chip suite"
zig build ra8_tests-exe
./zig-out/bin/ra8_tests

phase "host suite"
zig build ra8_host_tests-exe
./zig-out/bin/ra8_host_tests

phase "current firmware signed boot matrix (ReleaseFast)"
mkdir -p artifacts
set -o pipefail
zig build ra8_tests -j1 -Doptimize=ReleaseFast -Dtest-filter=session.boot_auth_test 2>&1 | tee artifacts/signed-boot-releasefast.log

phase "GUI link suite"
zig build ra8_gui_link_tests-exe
./zig-out/bin/ra8_gui_link_tests
