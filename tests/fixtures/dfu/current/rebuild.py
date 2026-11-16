#!/usr/bin/env python3
"""Rebuild the current-firmware boot matrix fixture with public TEST identities.

Usage: python3 rebuild.py /path/to/disposable/ra8-firmware /tmp/build-directory
Never point this at a working firmware checkout: two source files are changed.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

REVISION = "506703b68104c4fa630a08ba3c12b457e0da8ef1"
HERE = Path(__file__).resolve().parent
APP = "examples/ek_ra8d2/hw_validated/hil/dfu_bootloader"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, **kwargs).stdout


def key(directory, label):
    # Known, disposable scalar derived from a public label; NEVER a production key.
    scalar = hashlib.sha256(label.encode("ascii")).digest()
    der = bytes.fromhex("30310201010420") + scalar + bytes.fromhex("a00a06082a8648ce3d030107")
    source = directory / (label + ".der")
    dest = directory / (label + ".pem")
    source.write_bytes(der)
    run("openssl", "ec", "-inform", "DER", "-in", str(source), "-out", str(dest))
    return dest


def provenance(firmware, compiler):
    sources = [APP + "/src/main.c", APP + "/CMakeLists.txt", "build.zig.zon",
               "libs/ra8_rot/src/rot_abi.zig", "libs/ra8_rot/src/internal/rot.zig",
               "libs/ra8_rot_launch/src/launch_gate_abi.zig", "scripts/secrets/rot_sign.py"]
    tools = {}
    for command, args in ((compiler, ["--version"]), ("zig", ["version"]),
                          ("cmake", ["--version"]), ("ninja", ["--version"]),
                          ("openssl", ["version"])):
        executable = Path(shutil.which(command)).resolve()
        tools[executable.name] = {"version": run(str(executable), *args).decode().splitlines()[0],
                                  "sha256": hashlib.sha256(executable.read_bytes()).hexdigest()}
    original = {name: hashlib.sha256(run("git", "-C", str(firmware), "show", REVISION + ":" + name)).hexdigest()
                for name in sources}
    patched = {name: hashlib.sha256((firmware / name).read_bytes()).hexdigest() for name in sources}
    return {"firmware_revision": REVISION, "tools": tools, "original_sources": original,
            "built_sources": patched, "firmware_mode": "MinSizeRel / Zig ReleaseSmall",
            "emulator_required_mode": "ReleaseFast"}


def main():
    firmware, build = map(lambda arg: Path(arg).resolve(), sys.argv[1:])
    assert run("git", "-C", str(firmware), "rev-parse", "HEAD").decode().strip() == REVISION
    assert not run("git", "-C", str(firmware), "status", "--porcelain"), "use a clean disposable clone"
    spec = importlib.util.spec_from_file_location("rot_sign", firmware / "scripts/secrets/rot_sign.py")
    signer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(signer)
    with tempfile.TemporaryDirectory(prefix="ra8emu-1271-test-keys-") as temp:
        directory = Path(temp)
        root = key(directory, "RA8EMU-1271-TEST-root")
        wrong = key(directory, "RA8EMU-1271-TEST-wrong-root")
        public = signer.public_key(root)
        (HERE / "root-public.bin").write_bytes(public)
        (HERE / "wrong-root-public.bin").write_bytes(signer.public_key(wrong))
        source = firmware / "libs/ra8_rot/src/rot_abi.zig"
        text = source.read_text()
        values = ", ".join(f"0x{byte:02X}" for byte in public)
        text, count = re.subn(r"const root_public_key = \[rot.Size.pubkey_bytes\]u8\{.*?\n\};",
                              "const root_public_key = [rot.Size.pubkey_bytes]u8{\n    " + values + ",\n};",
                              text, flags=re.S)
        assert count == 1
        source.write_text(text)
        run("zig", "fmt", str(source))
        cmake = firmware / APP / "CMakeLists.txt"
        text = cmake.read_text().replace("  USES threadx usbx", "  NO_NSC\n  USES threadx usbx")
        cmake.write_text(text + "\n# Resolve tf-psa unsigned 64-bit division after its archive.\n"
                         "target_link_libraries(dfu_bootloader.elf PRIVATE gcc)\n")
        # Retain the proven 32-byte Thumb payload: vector table, marker store,
        # incrementing heartbeat. Distinct markers identify which slot launched.
        original = bytes.fromhex("0000062209000222034a044b1a6000225a605a680132fbe7dec0109700000122")
        for label, marker, version in (("a", 0x9710C0A1, 1), ("b", 0x9710C0B2, 2)):
            body = bytearray(original)
            body[24:28] = marker.to_bytes(4, "little")
            body[28:32] = (0x22180000).to_bytes(4, "little")
            (HERE / ("body_" + label + ".bin")).write_bytes(body)
            (HERE / ("signed_" + label + ".bin")).write_bytes(signer.sign_body(root, bytes(body), version))
        (HERE / "wrong_root_b.bin").write_bytes(signer.sign_body(wrong, (HERE / "body_b.bin").read_bytes(), 2))
    subprocess.run(["cmake", "-S", str(firmware / APP), "-B", str(build), "-G", "Ninja",
                    "-DCMAKE_TOOLCHAIN_FILE=" + str(firmware / "cmake/toolchain-ra8d2.cmake"),
                    "-DCMAKE_BUILD_TYPE=MinSizeRel"], check=True)
    subprocess.run(["cmake", "--build", str(build), "--target", "dfu_bootloader.elf", "-j2"], check=True)
    elf = build / "dfu_bootloader.elf"
    stripped = HERE / "bootloader.elf"
    cache = (build / "CMakeCache.txt").read_text()
    compiler = re.search(r"CMAKE_C_COMPILER:[^=]+=(.+)", cache).group(1)
    strip = Path(compiler).with_name("arm-none-eabi-strip")
    run(str(strip), "--strip-debug", "-o", str(stripped), str(elf))
    patch = run("git", "-C", str(firmware), "diff", "--", "libs/ra8_rot/src/rot_abi.zig", APP + "/CMakeLists.txt")
    (HERE / "test-build.patch").write_bytes(patch)
    (HERE / "provenance.json").write_text(json.dumps(provenance(firmware, compiler), indent=2) + "\n")
    files = [path for path in HERE.iterdir() if path.suffix in (".bin", ".elf", ".patch", ".py")]
    (HERE / "sha256.json").write_text(json.dumps({path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                                                 for path in sorted(files)}, indent=2) + "\n")


if __name__ == "__main__":
    main()
