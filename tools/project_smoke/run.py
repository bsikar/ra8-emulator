"""Bounded public project RPC, CLI build and verified-receipt DAP acceptance."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import traceback
from types import SimpleNamespace

import rpc
import layout
sys.path.insert(0, str(Path(__file__).resolve().parent))
import scenarios

spec = importlib.util.spec_from_file_location("project_workspace_evidence", layout.ROOT / "tools/workspace_smoke/run.py")
workspace_evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workspace_evidence)


def command(h, argv):
    index = len(h.commands) + 1
    out_path, err_path = h.output / f"cli-{index}.stdout.log", h.output / f"cli-{index}.stderr.log"
    h.trace(dict(type="cli_start", argv=argv))
    forced = False
    with out_path.open("xb") as out, err_path.open("xb") as err:
        child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                 start_new_session=os.name != "nt")
        try:
            child.wait(timeout=max(0.001, min(270, h.deadline-time.monotonic())))
        except subprocess.TimeoutExpired:
            forced = True
            if os.name == "nt":
                killer = Path(os.environ["SystemRoot"]) / "System32/taskkill.exe"
                subprocess.run([str(killer), "/PID", str(child.pid), "/T", "/F"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            else:
                os.killpg(child.pid, signal.SIGKILL)
            child.kill()
            child.wait(timeout=5)
    record = dict(exit_code=child.returncode, reaped=child.poll() is not None, forced=forced)
    h.commands.append(record)
    h.trace(dict(type="cli_exit", **record))
    output = []
    for path in (out_path, err_path):
        if path.stat().st_size > 2_000_000:
            raise AssertionError("CLI evidence output bound")
        value = path.read_text(encoding="utf8", errors="replace")
        output.append(value)
        path.write_text(h.sanitize(value), encoding="utf8")
    if forced:
        raise TimeoutError("project CLI deadline")
    return SimpleNamespace(returncode=child.returncode, stdout=output[0], stderr=output[1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("emulator", "zig", "fixture", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()
    if sys.flags.optimize or not args.zig.is_absolute() or not 0 < args.timeout <= 600:
        parser.error("assertions required, explicit absolute --zig and timeout>0 <=600")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    h = workspace_evidence.Harness(output, args.timeout)
    h.emulator, h.zig, h.fixture = args.emulator.resolve(), args.zig.resolve(), args.fixture.resolve()
    h.processes, h.commands = [], []
    h.command = lambda argv: command(h, argv)
    layout.create(h)
    summary = dict(status="FAIL", cases=[], head=subprocess.check_output(["git", "rev-parse", "HEAD"], text=True, timeout=10).strip(),
                   git_status=subprocess.check_output(["git", "status", "--porcelain"], text=True, timeout=10).splitlines(),
                   emulator_sha256=hashlib.sha256(h.emulator.read_bytes()).hexdigest(),
                   zig_sha256=hashlib.sha256(h.zig.read_bytes()).hexdigest(),
                   fixture_sha256=hashlib.sha256(h.fixture.read_bytes()).hexdigest(),
                   remote_suite="Local-only suite; remote Windows-client/Mac-server proof is recorded separately by remote.py")
    started = time.monotonic()
    try:
        version = subprocess.check_output([str(h.zig), "version"], text=True, timeout=10).strip()
        h.check("explicit Zig0.17.0", version, "0.17.0")
        h.server = rpc.Backend(h.emulator, h.fixture, h.base, h.zig, output / "rpc-server.log",
                               h.trace, h.deadline, h.sanitize)
        h.rpc = rpc.Client(h.server.port, h.trace, h.deadline)
        for case in scenarios.CASES:
            name = case.__name__
            result = dict(name=name, status="PASS")
            h.trace(dict(type="case_start", name=name))
            try:
                case(h)
            except Exception as error:
                result.update(status="FAIL", error=h.sanitize(error))
                h.trace(dict(type="exception", name=name, traceback=traceback.format_exc()))
            summary["cases"].append(result)
            h.trace(dict(type="case_end", **result))
    except Exception as error:
        summary["fatal"] = h.sanitize(error)
        h.trace(dict(type="fatal", traceback=traceback.format_exc()))
    finally:
        if hasattr(h, "rpc"):
            h.rpc.close()
        if hasattr(h, "server"):
            h.close_backend("project-rpc", h.server)
        healthy = len(h.cleanup) == 1 and all(p["method"] in ("graceful_signal", "already_exited")
                      and p["exit_code"] == 0 and p["owned_child_reaped"] for p in h.cleanup)
        healthy = healthy and all(p["exit_code"] == 0 and p["reaped"] and not p["forced"] and p["listener_closed"] for p in h.processes)
        healthy = healthy and all(p["reaped"] and not p["forced"] for p in h.commands)
        if healthy and "fatal" not in summary and len(summary["cases"]) == len(scenarios.CASES) and all(c["status"] == "PASS" for c in summary["cases"]):
            summary["status"] = "PASS"
        summary.update(assertions=h.assertions, backend_cleanup=h.cleanup, dap_cleanup=h.processes,
                       cli_cleanup=h.commands, elapsed_seconds=round(time.monotonic()-started, 3))
        (output / "summary.json").write_text(json.dumps(h.clean(summary), indent=2) + "\n", encoding="utf8")
        h.transcript.close()
    print(json.dumps(h.clean(summary)))
    return int(summary["status"] != "PASS")


if __name__ == "__main__":
    raise SystemExit(main())
