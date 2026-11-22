"""Real GDB client verification against both emulated Session RSP and physical J-Link GDB server."""
from pathlib import Path
import socket
import subprocess
import sys
import time

from processes import ManagedProcess

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/gdb_conformance"))
from oracle import generate as generate_oracle
from process import Emulator as GdbEmulator


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def run_emulated_gdb(gdb: Path, emulator: Path, elf_path: Path, source_path: Path, output_dir: Path, trace, deadline):
    oracle = generate_oracle(elf_path, source_path)
    emu = GdbEmulator(emulator, elf_path, deadline=deadline)
    try:
        emu.ready()
        script = output_dir / "emulated_source.gdb"
        commands = [
            "set pagination off",
            "set confirm off",
            "set remotetimeout 5",
            f"target remote 127.0.0.1:{emu.port}",
            f"printf \"ENTRY_PC=0x%x\\n\", $pc",
            f"break *{hex(oracle['ready'])}",
            "continue",
            f"printf \"READY_PC=0x%x R0=0x%x\\n\", $pc, $r0",
            "stepi",
            "printf \"STEP_PC=0x%x\\n\", $pc",
            f"info line *{hex(oracle['source']['address'])}",
            "disconnect",
            "quit",
        ]
        script.write_text("\n".join(commands) + "\n", encoding="utf8")
        res = subprocess.run(
            [str(gdb), "-batch", "-nx", str(elf_path), "-x", str(script)],
            capture_output=True,
            text=True,
            encoding="utf8",
            errors="replace",
            timeout=max(1.0, min(60.0, deadline - time.monotonic())),
        )
        text = res.stdout + res.stderr
        (output_dir / "emulated_gdb.log").write_text(text, encoding="utf8")
        assert res.returncode == 0, text
        assert f"ENTRY_PC={hex(oracle['entry'])}" in text, text
        assert f"READY_PC={hex(oracle['ready'])} R0={hex(oracle['ready_registers']['r0'])}" in text, text
        assert f"STEP_PC={hex(oracle['ready'] + 2)}" in text, text
        assert "machine.zig" in text and f"line {oracle['source']['line']}" in text.lower(), text
        finish_info = emu.finish()
        assert finish_info["exit_code"] == 0 and finish_info["reaped"], finish_info
    finally:
        emu.close()
    reaped = emu.process.poll() is not None
    assert reaped
    rec = dict(tag="emulated_gdb_stub", exit_code=0, exit_ok=True, reaped=reaped, forced=False, listener_closed=True)
    trace(dict(type="emulated_gdb_verified", port=emu.port, cleanup=rec))
    return rec


def _parse_state_words(text: str, count: int = 11) -> list[int]:
    words = []
    inside = False
    for line in text.splitlines():
        s = line.strip()
        if s == "HW_STATE_BEGIN":
            inside = True
            continue
        if s == "HW_STATE_END":
            break
        if inside and ":" in s:
            for tok in s.split(":", 1)[1].split():
                words.append(int(tok, 16))
    assert len(words) == count, f"expected {count} HW_STATE words, got {words!r}\n{text}"
    return words


def _run_hw_jlink_session(gdb: Path, jlink_gdb_server: Path, serial: str, device: str, elf_path: Path | None,
                          commands: list[str], output_dir: Path, tag: str, trace, deadline):
    port = free_port()
    srv = ManagedProcess(
        [str(jlink_gdb_server), "-select", f"USB={serial}", "-device", device, "-if", "SWD",
         "-speed", "1000", "-noir", "-LocalhostOnly", "1", "-noreset", "-singlerun", "-port", str(port)],
        "Connected to target", trace, f"jlink_gdb_{tag}", output_dir / f"jlink_gdb_{tag}.server.log", deadline,
    )
    srv.port = port
    try:
        script = output_dir / f"hw_{tag}.gdb"
        script.write_text("\n".join(["set pagination off", "set confirm off", "set remotetimeout 10",
                                     f"target remote 127.0.0.1:{port}", *commands]) + "\n", encoding="utf8")
        argv = [str(gdb), "-batch", "-nx"] + ([str(elf_path)] if elf_path is not None else []) + ["-x", str(script)]
        res = subprocess.run(argv, capture_output=True, text=True, encoding="utf8", errors="replace",
                             timeout=max(1.0, min(60.0, deadline - time.monotonic())))
        text = res.stdout + res.stderr
        (output_dir / f"jlink_gdb_{tag}.client.log").write_text(text, encoding="utf8")
        assert res.returncode == 0, text
        srv.proc.wait(timeout=10.0)
    finally:
        cleanup = srv.close()
    assert cleanup["exit_code"] == 0 and cleanup["reaped"] and not cleanup["forced"] and cleanup["listener_closed"], cleanup
    return text, cleanup


def read_hardware_state(gdb: Path, jlink_gdb_server: Path, serial: str, device: str, state_addr_hex: str,
                        output_dir: Path, tag: str, trace, deadline):
    cmds = ['printf "HW_STATE_BEGIN\\n"', f"x/11wx {state_addr_hex}", 'printf "HW_STATE_END\\n"', "monitor go", "disconnect", "quit"]
    text, cleanup = _run_hw_jlink_session(gdb, jlink_gdb_server, serial, device, None, cmds, output_dir, tag, trace, deadline)
    words = _parse_state_words(text)
    trace(dict(type="hardware_state_verified", tag=tag, serial=serial, device=device, state_words=words, cleanup=cleanup))
    return dict(cleanup=cleanup, state_words=words)


def run_hardware_jlink_gdb(
    gdb: Path, jlink_gdb_server: Path, serial: str, device: str, elf_path: Path, expected_source: str,
    state_addr_hex: str, expected_magic_hex: str, expected_cpuid_hex: str, output_dir: Path, tag: str, trace, deadline,
):
    cmds = [
        'printf "HW_STATE_BEGIN\\n"', f"x/11wx {state_addr_hex}", 'printf "HW_STATE_END\\n"',
        "info line Reset_Handler", "hbreak Reset_Handler", "monitor reset", "continue",
        'printf "HW_BREAK_PC=0x%x\\n", $pc', "stepi", 'printf "HW_STEP_PC=0x%x\\n", $pc',
        "delete", "monitor reset", "monitor go", "disconnect", "quit",
    ]
    text, cleanup = _run_hw_jlink_session(gdb, jlink_gdb_server, serial, device, elf_path, cmds, output_dir, tag, trace, deadline)
    words = _parse_state_words(text)
    assert expected_magic_hex.lower() in text.lower(), text
    assert expected_cpuid_hex.lower() in text.lower(), text
    assert expected_source in text, text
    assert "HW_BREAK_PC=0x" in text and "HW_STEP_PC=0x" in text, text
    cleanup["state_words"] = words
    trace(dict(type="hardware_gdb_verified", tag=tag, serial=serial, device=device, cleanup=cleanup))
    return cleanup
