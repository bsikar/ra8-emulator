"""Bounded public build-runner acceptance with an explicit real Zig compiler."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import traceback

from protocol import Client
from backend import Backend
import fixture
import scenarios
from run import Harness as WorkspaceHarness


def configured_compilers(h):
    for name, compiler in (("disabled", None), ("missing", h.output / "nonexistent-zig.exe")):
        backend = Backend(h.emulator, h.firmware, h.root, compiler, h.output / (name + "-server.log"),
                          h.trace, h.deadline, h.sanitize)
        peer = None
        try:
            peer = Client(backend.port, h.trace, h.deadline)
            h.check(name + " compiler capability", bool(peer.caps & (1 << 17)), compiler is not None)
            if compiler is None:
                peer.start(error=0x160)
                peer.status(1, error=0x160)
                peer.cancel(1, error=0x160)
            else:
                job = peer.start()
                result = peer.finish(job)
                scenarios.failed(h, result, cleanup=False)
        finally:
            if peer:
                peer.close()
            h.close_backend(name, backend)


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("emulator", "fixture", "zig", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=300)
    args = parser.parse_args()
    if sys.flags.optimize or not 0 < args.timeout <= 600:
        parser.error("assertions required; timeout must be >0 and <=600")
    if not args.zig.is_absolute():
        parser.error("--zig must be an explicit absolute compiler path")
    return args


def main():
    args = arguments()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    h = WorkspaceHarness(output, args.timeout)
    h.root = h.root.rename(output / "workspace with spaces")
    h.zig, h.emulator, h.firmware = args.zig.resolve(), args.emulator.resolve(), args.fixture.resolve()
    fixture.create(h.root)
    summary = dict(status="FAIL", cases=[], cleanup=[], platform=sys.platform,
                   head=subprocess.check_output(["git", "rev-parse", "HEAD"], text=True, timeout=5).strip(),
                   git_status=subprocess.check_output(["git", "status", "--porcelain"], text=True, timeout=5).splitlines(),
                   emulator_sha256=hashlib.sha256(h.emulator.read_bytes()).hexdigest(),
                   fixture_sha256=hashlib.sha256(h.firmware.read_bytes()).hexdigest(),
                   zig_sha256=hashlib.sha256(h.zig.read_bytes()).hexdigest())
    started = time.monotonic()
    try:
        h.zig_version = subprocess.check_output([str(h.zig), "version"], text=True, timeout=10).strip()
        summary["zig_version"] = h.zig_version
        h.server = Backend(h.emulator, h.firmware, h.root, h.zig, output / "build-server.log",
                           h.trace, h.deadline, h.sanitize)
        h.client = Client(h.server.port, h.trace, h.deadline)
        h.check("build capability advertised", bool(h.client.caps & (1 << 17)), True)
        for index, case in enumerate((*scenarios.CASES, configured_compilers)):
            name = str(index + 1) + "_" + case.__name__
            h.trace(dict(type="case_start", name=name))
            record = dict(name=name, status="PASS")
            try:
                case(h)
            except Exception as error:
                record.update(status="FAIL", error=h.sanitize(error))
                h.trace(dict(type="exception", name=name, traceback=traceback.format_exc()))
            summary["cases"].append(record)
            h.trace(dict(type="case_end", **record))
    except Exception as error:
        summary["fatal"] = h.sanitize(error)
        h.trace(dict(type="fatal", traceback=traceback.format_exc()))
    finally:
        if hasattr(h, "client"):
            h.client.close()
        if hasattr(h, "server"):
            h.close_backend("build", h.server)
        summary["cleanup"] = h.cleanup
        healthy = len(h.cleanup) == 3 and all(c.get("method") in ("graceful_signal", "already_exited")
                    and c.get("exit_code") == 0 and c.get("owned_child_reaped") for c in h.cleanup)
        if "fatal" not in summary and healthy and all(c["status"] == "PASS" for c in summary["cases"]):
            summary["status"] = "PASS"
        summary.update(assertions=h.assertions, elapsed_seconds=round(time.monotonic() - started, 3))
        (output / "summary.json").write_text(json.dumps(h.clean(summary), indent=2) + "\n", encoding="utf8")
        h.transcript.close()
    print(json.dumps(h.clean(summary)))
    return int(summary["status"] != "PASS")


if __name__ == "__main__":
    raise SystemExit(main())
