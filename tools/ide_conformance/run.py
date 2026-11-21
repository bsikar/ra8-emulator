"""Headless IDE conformance runner for portable CI and physical J-Link HIL."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time
import traceback

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import gdb_debug  # noqa: E402
import processes  # noqa: E402
import rpc_client  # noqa: E402

sys.path.insert(0, str(HERE))
import hil  # noqa: E402
import scenarios  # noqa: E402


class Harness:
    def __init__(self, args, output: Path, zig: Path, gdb: Path | None):
        self.args = args
        self.output = output
        self.emulator = args.emulator.resolve()
        self.zig = zig
        self.fixture = args.fixture.resolve()
        self.gdb = gdb
        self.deadline = time.monotonic() + args.timeout
        self.assertions = 0
        self.processes = []
        self.commands = []
        self.results = {}
        self.physical_gates = {}
        self._cmd_idx = 0
        self.transcript = (output / "transcript.jsonl").open("w", encoding="utf8")

    def clean(self, value):
        if isinstance(value, dict):
            return {k: self.clean(v) for k, v in value.items()}
        if isinstance(value, (list, tuple)):
            return [self.clean(v) for v in value]
        if isinstance(value, bytes):
            return dict(bytes=len(value), sha256=hashlib.sha256(value).hexdigest(), preview=value[:32].hex())
        if isinstance(value, (str, Path)):
            text = str(value)
            for root, label in ((self.output, "<EVIDENCE>"), (ROOT, "<REPO>"), (Path.home(), "<HOME>")):
                pattern = r"(?:\\+|/+)".join(re.escape(part) for part in re.split(r"[\\/]+", str(root)))
                text = re.sub(pattern, lambda _: label, text, flags=re.I if os.name == "nt" else 0)
            return text
        return value

    def sanitize(self, value):
        return self.clean(str(value))

    def trace(self, event):
        self.transcript.write(json.dumps(self.clean(event), ensure_ascii=False) + "\n")
        self.transcript.flush()

    def check(self, name, actual, expected):
        self.assertions += 1
        passed = actual == expected
        self.trace(dict(type="assertion", name=name, actual=actual, expected=expected, passed=passed))
        if not passed:
            raise AssertionError(self.sanitize(f"{name}: actual={actual!r}, expected={expected!r}"))

    def require(self, name, condition):
        self.check(name, bool(condition), True)

    def run_cli(self, argv, env=None, cwd=None, timeout=180.0):
        self._cmd_idx += 1
        res = processes.run_cli(argv, self.output, self._cmd_idx, self.trace, self.deadline, env=env, cwd=cwd, timeout=timeout)
        self.commands.append(res.cleanup)
        return res

    def spawn(self, argv, ready_prefix, tag, log_name, env=None, port_from_ready=False):
        proc = processes.ManagedProcess(
            argv, ready_prefix, self.trace, tag, self.output / log_name,
            self.deadline, env=env, port_from_ready=port_from_ready,
        )
        self.processes.append(proc)
        return proc


def resolve_tool(raw: str | None) -> Path | None:
    if raw is None:
        return None
    found = shutil.which(raw)
    path = Path(found).resolve() if found else Path(raw).resolve()
    if not path.is_file():
        raise FileNotFoundError(f"missing executable: {raw}")
    return path


def host_triplet() -> str:
    if sys.platform == "darwin":
        table = {"arm64": "aarch64-macos", "x86_64": "x86_64-macos"}
        return table[platform.machine()]
    if sys.platform == "win32":
        return "x86_64-windows"
    if sys.platform.startswith("linux"):
        return "x86_64-linux"
    raise RuntimeError(f"unsupported host platform: {sys.platform}")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    for flag in ("emulator", "zig", "fixture", "output"):
        p.add_argument("--" + flag, type=Path, required=True)
    p.add_argument("--timeout", type=float, default=480.0)
    p.add_argument("--gdb", type=str, default=None)
    p.add_argument("--hil", action="store_true")
    p.add_argument("--jlink", type=Path, default=Path(r"C:\Program Files\SEGGER\JLink_V818\JLink.exe"))
    p.add_argument("--jlink-gdb-server", type=Path, default=Path(r"C:\Program Files\SEGGER\JLink_V818\JLinkGDBServerCL.exe"))
    p.add_argument("--ssh-host", type=str, default="dev")
    p.add_argument("--remote-zig", type=str, default="/home/bsikar/opt/zig-0.17.0/zig")
    p.add_argument("--remote-emulator", type=str, default=None)
    return p


def initial_summary(h: Harness, args) -> dict:
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, timeout=10).strip()
    git_status = subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True, timeout=10).splitlines()
    if args.hil:
        gates = {
            "local_windows_bench_fpb_ra8e1": "NOTRUN",
            "local_windows_bench_fpb_ra4t1": "NOTRUN",
            "local_windows_hardware_jlink_gdb_ra8e1": "NOTRUN",
            "local_windows_hardware_jlink_gdb_ra4t1": "NOTRUN",
            "remote_linux_backend_laptop_windows_probe": "NOTRUN",
            "server_attached_probe": "PENDING_RA8EMU-1351",
            "ra8d2": "PENDING_HARDWARE",
            "grove-vision-ai-v2": "PENDING_HARDWARE",
            "ra8p1": "UNPURCHASED_UNAVAILABLE",
        }
    else:
        gates = {
            "local_windows_bench_fpb_ra8e1": "NOTRUN_CI",
            "local_windows_bench_fpb_ra4t1": "NOTRUN_CI",
            "local_windows_hardware_jlink_gdb_ra8e1": "NOTRUN_CI",
            "local_windows_hardware_jlink_gdb_ra4t1": "NOTRUN_CI",
            "remote_linux_backend_laptop_windows_probe": "NOTRUN_CI",
            "server_attached_probe": "PENDING_RA8EMU-1351",
            "ra8d2": "PENDING_HARDWARE",
            "grove-vision-ai-v2": "PENDING_HARDWARE",
            "ra8p1": "UNPURCHASED_UNAVAILABLE",
        }
    return dict(
        status="FAIL",
        mode="hil" if args.hil else "portable_ci",
        host=host_triplet(),
        head=head,
        git_status=git_status,
        emulator_sha256=hashlib.sha256(h.emulator.read_bytes()).hexdigest(),
        zig_sha256=hashlib.sha256(h.zig.read_bytes()).hexdigest(),
        fixture_sha256=hashlib.sha256(h.fixture.read_bytes()).hexdigest(),
        physical_hardware=bool(args.hil),
        physical_gates=gates,
        cases=[],
    )


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    max_t = 1200.0 if args.hil else 600.0
    if sys.flags.optimize or not 0 < args.timeout <= max_t:
        parser.error(f"assertions required and 0 < --timeout <= {max_t}")
    zig = resolve_tool(str(args.zig))
    if zig is None or not zig.is_absolute():
        parser.error("explicit absolute --zig required")
    gdb = resolve_tool(args.gdb)
    if args.hil and gdb is None:
        parser.error("--hil requires --gdb (e.g. arm-none-eabi-gdb)")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    h = Harness(args, output, zig, gdb)
    summary = initial_summary(h, args)
    h.physical_gates = dict(summary["physical_gates"])
    started = time.monotonic()
    cases = hil.CASES if args.hil else scenarios.CASES
    try:
        zig_ver = subprocess.check_output([str(h.zig), "version"], text=True, timeout=10).strip()
        h.check("explicit Zig 0.17.0", zig_ver, "0.17.0")
        for case in cases:
            name = case.__name__
            entry = dict(name=name, status="PASS")
            h.trace(dict(type="case_start", name=name))
            try:
                case(h)
            except Exception as err:
                entry.update(status="FAIL", error=h.sanitize(err))
                h.trace(dict(type="exception", name=name, traceback=traceback.format_exc()))
            summary["cases"].append(entry)
            h.trace(dict(type="case_end", **entry))
    except Exception as err:
        summary["fatal"] = h.sanitize(err)
        h.trace(dict(type="fatal", traceback=traceback.format_exc()))
    finally:
        daemons = [proc.close() for proc in h.processes]
        healthy = (
            all(d["exit_code"] == 0 and d["reaped"] and not d["forced"] and d["listener_closed"] for d in daemons)
            and all(c["reaped"] and not c["forced"] for c in h.commands)
        )
        if healthy and "fatal" not in summary and len(summary["cases"]) == len(cases) and all(c["status"] == "PASS" for c in summary["cases"]):
            summary["status"] = "PASS"
        elif args.hil:
            h.physical_gates.update({k: "FAIL" for k, v in h.physical_gates.items() if v == "NOTRUN"})
        summary.update(
            results=h.results,
            physical_gates=h.physical_gates,
            assertions=h.assertions,
            daemons=daemons,
            commands=h.commands,
            elapsed_seconds=round(time.monotonic() - started, 3),
        )
        (output / "summary.json").write_text(json.dumps(h.clean(summary), indent=2) + "\n", encoding="utf8")
        h.transcript.close()
    print(json.dumps(h.clean(summary)))
    return int(summary["status"] != "PASS")


if __name__ == "__main__":
    raise SystemExit(main())
