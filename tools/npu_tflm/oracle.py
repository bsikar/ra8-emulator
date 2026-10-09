# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
"""Cross-check the NPU tests against host TensorFlow Lite Micro.

Each Vela replay test under tests/chip/periph/npu/ asserts that the emulator
writes a committed OFM (a hexBytes constant) for a committed IFM. This tool
runs the source .tflite model behind each test through the TFLM reference
kernels on the same IFM and diffs TFLM's output against that OFM, so a zero
diff here plus a green `zig build test` means emulator == TFLM byte for byte.

Run it through oracle.sh, which installs the pinned host TFLM build.
"""
import pathlib
import re
import sys

import numpy as np
from tflite_micro.python.tflite_micro import runtime

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
NPU_TESTS = ROOT / "tests" / "periph" / "npu"

# name, model, test file, IFM constants (input order), OFM constant
CASES = [
    ("CONV 1x1", "conv1x1.tflite", "npu_vela_run_test.zig", ["conv_ifm"], "conv_ofm"),
    ("CONV 3x3 s2 SAME", "conv3x3.tflite", "npu_vela_convop_test.zig", ["ifm"], "ofm"),
    ("DEPTHWISE 3x3 s2 SAME", "dw3x3.tflite", "npu_vela_convop_test.zig", ["dw_ifm"], "dw_ofm"),
    ("DEPTHWISE multiplier 8", "dwm.tflite", "npu_vela_convop_test.zig", ["ifm_x8"], "ofm_x8"),
    ("DEPTHWISE multiplier 2", "dwm2.tflite", "npu_vela_convop_test.zig", ["ifm_x2"], "ofm_x2"),
    ("MUL", "mul.tflite", "npu_vela_mul_test.zig", ["ifm", "ifm2"], "ofm"),
]

CONST = re.compile(r'^const (\w+) = hexBytes\(((?:\s*"[0-9a-f]*"\s*(?:\+\+)?)+)\);', re.M)


def hex_consts(test_file):
    text = (NPU_TESTS / test_file).read_text()
    out = {}
    for match in CONST.finditer(text):
        out[match.group(1)] = bytes.fromhex("".join(re.findall(r'"([0-9a-f]*)"', match.group(2))))
    return out


def run_case(model, test_file, inputs, output):
    consts = hex_consts(test_file)
    interp = runtime.Interpreter.from_file(str(HERE / "models" / model))
    for index, name in enumerate(inputs):
        shape = interp.get_input_details(index)["shape"]
        interp.set_input(np.frombuffer(consts[name], np.int8).reshape(shape), index)
    interp.invoke()
    got = interp.get_output(0).astype(np.int8).tobytes()
    want = consts[output]
    diff = sum(a != b for a, b in zip(got, want)) + abs(len(got) - len(want))
    return len(want), diff


def main():
    failed = 0
    for name, model, test_file, inputs, output in CASES:
        size, diff = run_case(model, test_file, inputs, output)
        print(f"{name:24} {size:4} bytes  diff {diff}")
        failed += diff != 0
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
