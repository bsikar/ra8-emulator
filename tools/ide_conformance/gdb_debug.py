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
            "info line *0x220000e0",
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
        assert "machine.zig" in text and "line 60" in text, text
        exit_code = emu.finish()
        assert exit_code == 0
    finally:
        emu.close()
    reaped = emu.process.poll() is not None
    assert reaped
    rec = dict(tag="emulated_gdb_stub", exit_code=0, exit_ok=True, reaped=reaped, forced=False, listener_closed=True)
    trace(dict(type="emulated_gdb_verified", port=emu.port, cleanup=rec))
    return rec


def run_hardware_jlink_gdb(
    gdb: Path,
    jlink_gdb_server: Path,
    serial: str,
    device: str,
    elf_path: Path,
    expected_source: str,
    state_addr_hex: str,
    expected_magic_hex: str,
    expected_cpuid_hex: str,
    output_dir: Path,
    tag: str,
    trace,
    deadline,
):
    port = free_port()
    srv = ManagedProcess(
        [
            str(jlink_gdb_server),
            "-select",
            f"USB={serial}",
            "-device",
            device,
            "-if",
            "SWD",
            "-speed",
            "1000",
            "-noir",
            "-LocalhostOnly",
            "1",
            "-noreset",
            "-singlerun",
            "-port",
            str(port),
        ],
        "Waiting for GDB connection",
        trace,
        f"jlink_gdb_{tag}",
        output_dir / f"jlink_gdb_{tag}.server.log",
        deadline,
    )
    srv.port = port
    try:
        script = output_dir / f"hw_{tag}.gdb"
        commands = [
            "set pagination off",
            "set confirm off",
            "set remotetimeout 10",
            f"target remote 127.0.0.1:{port}",
            f"x/4wx {state_addr_hex}",
            "info line Reset_Handler",
            "hbreak Reset_Handler",
            "monitor reset",
            "continue",
            "printf \"HW_BREAK_PC=0x%x\\n\", $pc",
            "stepi",
            "printf \"HW_STEP_PC=0x%x\\n\", $pc",
            "delete",
            "monitor reset",
            "monitor go",
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
        (output_dir / f"jlink_gdb_{tag}.client.log").write_text(text, encoding="utf8")
        assert res.returncode == 0, text
        assert expected_magic_hex.lower() in text.lower(), text
        assert expected_cpuid_hex.lower() in text.lower(), text
        assert expected_source in text, text
        assert "HW_BREAK_PC=0x" in text and "HW_STEP_PC=0x" in text, text
        srv.proc.wait(timeout=10.0)
    finally:
        cleanup = srv.close()
    assert cleanup["reaped"] and not cleanup["forced"] and cleanup["listener_closed"], cleanup
    trace(dict(type="hardware_gdb_verified", tag=tag, serial=serial, device=device, cleanup=cleanup))
    return cleanup
