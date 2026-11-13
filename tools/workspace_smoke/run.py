"""Run bounded public workspace RPC acceptance without compiling the backend."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import traceback

import cases
from client import CAPABILITY, MISSING, Client
from server import Server


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def terminal_status(results, links, cleanup, require_native_links=False):
    if any(item["status"] == "FAIL" for item in results):
        return "FAIL"
    if len(cleanup) != 2 or any(item.get("method") not in ("graceful_signal", "already_exited")
                               or item.get("exit_code") != 0 or not item.get("owned_child_reaped")
                               for item in cleanup):
        return "FAIL"
    limited = any(item["status"] == "UNAVAILABLE" for item in links)
    if require_native_links and (limited or len(links) != 2):
        return "FAIL"
    return "PASS_WITH_LIMITS" if limited else "PASS"


class Harness:
    def __init__(self, output, timeout):
        self.output = output
        self.deadline = time.monotonic() + timeout
        self.assertions = 0
        self.cleanup = []
        self.transcript = (output / "transcript.jsonl").open("w", encoding="utf8")
        self.root = output / "workspace"
        self.root.mkdir()
        self.sentinel = output / "outside" / "sentinel.txt"
        self.sentinel.parent.mkdir()
        self.outside_bytes = b"OUTSIDE SENTINEL: must remain unchanged\n"
        self.sentinel.write_bytes(self.outside_bytes)
        (self.root / "src space").mkdir()
        (self.root / "watched dir").mkdir()
        (self.root / "watched dir" / "child.txt").write_bytes(b"initial child\n")
        for name in ("alpha.txt", "beta.txt", "unicodé.txt"):
            (self.root / name).write_bytes((name + " contents\n").encode("utf8"))
        self.source = self.root / "src space" / "source file.zig"
        self.initial_source = b"// independent public client fixture\npub const value = 7;\n"
        self.source.write_bytes(self.initial_source)
        os.utime(self.source, ns=(1_700_000_000_000_000_000, 1_700_000_000_000_000_000))

    def sanitize(self, value):
        text = str(value)
        roots = ((self.output, "<EVIDENCE>"), (Path(__file__).resolve().parents[2], "<REPO>"),
                 (Path.home(), "<HOME>"))
        for root, label in roots:
            components = re.split(r"[\\/]+", str(root))
            pattern = r"(?:\\+|/+)".join(re.escape(item) for item in components)
            text = re.sub(pattern, lambda _: label, text, flags=re.IGNORECASE if os.name == "nt" else 0)
        return text

    def close_backend(self, name, backend):
        try:
            result = backend.close()
        except Exception as error:
            result = dict(method="cleanup_exception", error=self.sanitize(error),
                          exit_code=backend.process.poll(), owned_child_reaped=backend.process.poll() is not None)
        self.cleanup.append(dict(backend=name, **result))

    def clean(self, value):
        if isinstance(value, bytes):
            return dict(length=len(value), sha256=hashlib.sha256(value).hexdigest(), preview_hex=value[:96].hex())
        if isinstance(value, dict):
            return {key: self.clean(item) for key, item in value.items()}
        if isinstance(value, (list, tuple, set)):
            return [self.clean(item) for item in value]
        if isinstance(value, (str, Path)):
            return self.sanitize(value)
        return value

    def trace(self, event):
        self.transcript.write(json.dumps(self.clean(event), ensure_ascii=False) + "\n")
        self.transcript.flush()

    def check(self, name, actual, expected):
        self.assertions += 1
        passed = actual == expected
        self.trace(dict(type="assertion", name=name, passed=passed, actual=actual, expected=expected))
        if not passed:
            raise AssertionError(f"{name}: expected {self.clean(expected)!r}, actual {self.clean(actual)!r}")


def unavailable(h, emulator, fixture):
    backend = Server(emulator, fixture, None, h.output / "without-workspace.log", h.trace, h.deadline, h.sanitize)
    peer = None
    try:
        peer = Client(backend.port, h.trace, h.deadline)
        h.check("workspace absent from disabled greeting", bool(peer.caps & CAPABILITY), False)
        peer.listing(error="unavailable")
        peer.stat("alpha.txt", error="unavailable")
        peer.read("alpha.txt", error="unavailable")
        peer.write("new.txt", MISSING, b"new", error="unavailable")
        peer.watch("alpha.txt", error="unavailable")
        peer.unwatch(1, error="unavailable")
        h.check("all six disabled methods explicitly refuse", True, True)
    finally:
        if peer is not None:
            peer.close()
        h.close_backend("without_workspace", backend)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emulator", required=True, type=Path)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--require-native-links", action="store_true",
                        help="fail when either native link containment probe is unavailable")
    args = parser.parse_args()
    if sys.flags.optimize:
        parser.error("run without Python optimization so protocol assertions remain active")
    emulator, fixture, output = args.emulator.resolve(), args.fixture.resolve(), args.output.resolve()
    if args.timeout <= 0 or args.timeout > 600:
        parser.error("--timeout must be >0 and <=600 seconds")
    output.mkdir(parents=True, exist_ok=False)
    h = Harness(output, args.timeout)
    summary = dict(status="FAIL", emulator_sha256=digest(emulator), fixture_sha256=digest(fixture),
                   python=sys.version, platform=sys.platform, cases=[], native_links=[], cleanup=[],
                   require_native_links=args.require_native_links)
    git = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, timeout=5)
    summary["head"] = git.stdout.strip() if git.returncode == 0 else None
    status = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True, timeout=5)
    summary["git_status"] = status.stdout.splitlines()
    started = time.monotonic()
    try:
        h.server = Server(emulator, fixture, h.root, output / "workspace-server.log", h.trace, h.deadline, h.sanitize)
        h.client = Client(h.server.port, h.trace, h.deadline)
        for case in (*cases.CASES, cases.link_escapes):
            name = case.__name__
            h.trace(dict(type="case_start", name=name))
            try:
                result = case(h)
                outcome = "PASS"
                if name == "link_escapes":
                    summary["native_links"] = result
                    if any(item["status"] == "UNAVAILABLE" for item in result):
                        outcome = "PASS_WITH_LIMITS"
                summary["cases"].append(dict(name=name, status=outcome))
            except Exception as error:
                summary["cases"].append(dict(name=name, status="FAIL", error=h.sanitize(error)))
                h.trace(dict(type="exception", name=name, traceback=traceback.format_exc()))
            h.trace(dict(type="case_end", **summary["cases"][-1]))
        try:
            unavailable(h, emulator, fixture)
            summary["cases"].append(dict(name="without_workspace", status="PASS"))
        except Exception as error:
            summary["cases"].append(dict(name="without_workspace", status="FAIL", error=h.sanitize(error)))
            h.trace(dict(type="exception", name="without_workspace", traceback=traceback.format_exc()))
        h.check("outside sentinel preserved at terminal", h.sentinel.read_bytes(), h.outside_bytes)
    except Exception as error:
        summary["fatal"] = h.sanitize(error)
        h.trace(dict(type="fatal", traceback=traceback.format_exc()))
    finally:
        if hasattr(h, "client"):
            h.client.close()
        if hasattr(h, "server"):
            h.close_backend("workspace", h.server)
        summary["cleanup"] = h.cleanup
        if "fatal" not in summary:
            summary["status"] = terminal_status(summary["cases"], summary["native_links"], h.cleanup,
                                                args.require_native_links)
        summary.update(assertions=h.assertions, elapsed_seconds=round(time.monotonic() - started, 3))
        (output / "summary.json").write_text(json.dumps(h.clean(summary), indent=2, ensure_ascii=False) + "\n", encoding="utf8")
        h.transcript.close()
    print(json.dumps(h.clean(dict(status=summary["status"], cases=summary["cases"], native_links=summary["native_links"],
                                  assertions=h.assertions, output=str(output))), ensure_ascii=False))
    return 1 if summary["status"] == "FAIL" else 0


if __name__ == "__main__":
    raise SystemExit(main())
