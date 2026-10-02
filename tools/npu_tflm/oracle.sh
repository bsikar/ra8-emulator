#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# oracle.sh -- set up host TensorFlow Lite Micro and run the NPU oracle.
#
#   tools/npu_tflm/oracle.sh [VENV]
#
# Installs the pinned tflite-micro host build (the real TFLM reference
# kernels, prebuilt for the host) into VENV, default .zig-cache/tflm-venv,
# then runs oracle.py. Exits 1 when any case differs from TFLM.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
venv="${1:-$root/.zig-cache/tflm-venv}"
tflm_version="0.dev20261002031052"

if [ ! -x "$venv/bin/python" ]; then
    python3 -m venv "$venv"
fi
"$venv/bin/python" -m pip install -q "tflite-micro==$tflm_version" "numpy<2"
exec "$venv/bin/python" "$here/oracle.py"
