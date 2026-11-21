"""Cross-platform simulated J-Link Commander fixture for reproducible CI target & profile tests."""
import json
import os
from pathlib import Path
import stat
import sys

BOARDS = {
    "001083322193": {
        "short": "1083322193",
        "device": "R7FA8E1AF",
        "cpuid": "410FD232",
        "part_addr": "030080F0",
        "part_words": "41463752 41314538 46434446 20202042",
        "pc": "02000100",
        "sp": "22070000",
    },
    "001088957027": {
        "short": "1088957027",
        "device": "R7FA4T1BB",
        "cpuid": "410FD214",
        "part_addr": "010080F0",
        "part_words": "41463752 42315434 46433342 2020204D",
        "pc": "00000100",
        "sp": "20004000",
    },
}


def normalize_serial(raw):
    digits = raw.strip().zfill(12)
    return digits


def create_fixture(state_dir: Path):
    state_dir.mkdir(parents=True, exist_ok=True)
    present_path = state_dir / "present.json"
    present_path.write_text(json.dumps(["001083322193", "001088957027"]), encoding="utf8")
    calls_path = state_dir / "calls.jsonl"
    calls_path.write_text("", encoding="utf8")
    script_py = Path(__file__).resolve()
    if os.name == "nt":
        wrapper = state_dir / "fake_jlink.cmd"
        wrapper.write_text(
            f'@echo off\r\n"{sys.executable}" -B "{script_py}" "{state_dir}" %*\r\nexit /b %ERRORLEVEL%\r\n',
            encoding="utf8",
        )
    else:
        wrapper = state_dir / "fake_jlink.sh"
        wrapper.write_text(
            f'#!/bin/sh\nexec "{sys.executable}" -B "{script_py}" "{state_dir}" "$@"\n',
            encoding="utf8",
        )
        wrapper.chmod(wrapper.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return wrapper, present_path, calls_path


def cli_main(argv):
    state_dir = Path(argv[1])
    rest = argv[2:]
    present = set(json.loads((state_dir / "present.json").read_text(encoding="utf8")))

    cmd_file = None
    usb = None
    device = None
    i = 0
    while i < len(rest):
        if rest[i] == "-CommandFile" and i + 1 < len(rest):
            cmd_file = Path(rest[i + 1])
            i += 2
        elif rest[i] == "-USB" and i + 1 < len(rest):
            usb = normalize_serial(rest[i + 1])
            i += 2
        elif rest[i] == "-Device" and i + 1 < len(rest):
            device = rest[i + 1]
            i += 2
        else:
            i += 1

    commands = cmd_file.read_text(encoding="utf8").splitlines() if cmd_file and cmd_file.exists() else []
    with (state_dir / "calls.jsonl").open("a", encoding="utf8") as log:
        log.write(json.dumps(dict(usb=usb, device=device, commands=commands)) + "\n")

    if any(line.strip().startswith("ShowEmuList") for line in commands):
        idx = 0
        for serial in ("001083322193", "001088957027"):
            if serial in present:
                short = BOARDS[serial]["short"]
                print(f"J-Link[{idx}]: Connection: USB, Serial number: {short}, ProductName: J-Link-OB-RA4M2")
                idx += 1
        return 0

    if usb is None or usb not in present or usb not in BOARDS:
        sys.stderr.write("Cannot connect to J-Link via USB.\n")
        return 1
    info = BOARDS[usb]
    if device != info["device"]:
        sys.stderr.write(f"Unknown or mismatched device {device}\n")
        return 1

    print(f"Connecting to J-Link via USB...O.K.\nS/N: {info['short']}")
    stepped = False
    for raw in commands:
        line = raw.strip()
        if line == "mem32 0xE000ED00 1":
            print(f"E000ED00 = {info['cpuid']} ")
        elif line == f"mem32 0x{info['part_addr']} 4":
            print(f"{info['part_addr']} = {info['part_words']} ")
        elif line == "s":
            stepped = True
        elif line == "regs":
            pc = int(info["pc"], 16) + (2 if stepped else 0)
            print(f"PC = {pc:08X}, CycleCnt = 00000010\nSP(R13)= {info['sp']}")
        elif line.startswith("loadfile "):
            print("Downloading file...O.K.")
        elif line.startswith("verifybin "):
            print("Verify successful.")
    return 0


if __name__ == "__main__":
    raise SystemExit(cli_main(sys.argv))
