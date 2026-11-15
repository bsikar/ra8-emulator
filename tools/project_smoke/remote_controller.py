"""Owned Mac processes and fixtures; wire clients run on Windows, never here."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import platform
import queue
import re
import socket
import subprocess
import sys
import threading
import time
import traceback
from types import SimpleNamespace

import rpc
import layout
import root_guard


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Controller:
    def __init__(self, args):
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.work = args.worktree.resolve()
        self.deadline = time.monotonic() + args.timeout
        self.stream = (self.output / "controller.jsonl").open("w", encoding="utf8")
        self.root = self.output / "bootstrap"
        self.root.mkdir()
        self.saved, self.cleanup, self.dap, self.guard = {}, [], None, None
        self.emulator = self.work / "zig-out/bin/ra8_emulator"
        self.fixture = self.work / "zig-out/bin/debug_conformance.elf"
        self.zig = args.zig.resolve()
        layout.create(self)
        (self.base / "alpha.txt").write_bytes(b"base workspace marker\n")
        self.server = rpc.Backend(self.emulator, self.fixture, self.base, self.zig,
                                  self.output / "rpc-server.log", self.trace, self.deadline, self.sanitize)

    def sanitize(self, value):
        return str(value).replace(str(self.output), "<REMOTE_EVIDENCE>").replace(str(self.work), "<REMOTE_WORKTREE>")

    def trace(self, value):
        self.stream.write(json.dumps(value) + "\n")
        self.stream.flush()

    def ready(self):
        return dict(system=platform.system(), machine=platform.machine(), python=platform.python_version(),
                    head=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.work, text=True, timeout=10).strip(),
                    git_status=subprocess.check_output(["git", "status", "--porcelain"], cwd=self.work, text=True, timeout=10).splitlines(),
                    binary_sha256=digest(self.emulator), fixture_sha256=digest(self.fixture),
                    zig_path=str(self.zig), zig_sha256=digest(self.zig),
                    zig_version=subprocess.check_output([str(self.zig), "version"], text=True, timeout=10).strip(),
                    rpc_port=self.server.port, project_root=str(self.root), base=str(self.base),
                    config_sha256=digest(self.config_path))

    def start_dap(self):
        if self.dap is not None:
            raise RuntimeError("previous owned DAP process must be collected first")
        index = len(self.cleanup) + 1
        args = [str(self.emulator), "project", "dap", "0", str(self.base), "project.json", "--zig", str(self.zig)]
        self.dap = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, encoding="utf8", errors="replace")
        self.dap_lines, self.dap_queue = [], queue.Queue(maxsize=128)
        def drain():
            captured = 0
            for line in iter(lambda: self.dap.stdout.readline(4096), ""):
                if captured < 1_000_000:
                    self.dap_lines.append(line[:1_000_000-captured])
                    captured += len(line)
                try:
                    self.dap_queue.put_nowait(line)
                except queue.Full:
                    pass
        self.dap_thread = threading.Thread(target=drain, daemon=True)
        self.dap_thread.start()
        deadline = min(self.deadline, time.monotonic()+15)
        while time.monotonic() < deadline:
            if self.dap.poll() is not None:
                raise RuntimeError("owned DAP startup failed: " + "".join(self.dap_lines))
            try:
                line = self.dap_queue.get(timeout=0.1)
            except queue.Empty:
                continue
            match = re.fullmatch(r"dap: listening on tcp:127\.0\.0\.1:(\d+)\s*", line)
            if match:
                self.dap_port = int(match.group(1))
                return dict(port=self.dap_port, pid=self.dap.pid)
        raise TimeoutError("owned remote DAP startup")

    def collect_dap(self, force=False):
        if self.dap is None:
            return None
        forced = False
        try:
            self.dap.wait(timeout=5)
        except subprocess.TimeoutExpired:
            forced = True
            self.dap.terminate()
            try:
                self.dap.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.dap.kill()
                self.dap.wait(timeout=5)
        self.dap_thread.join(timeout=1)
        self.dap.stdout.close()
        result = dict(kind="dap", exit_code=self.dap.returncode, reaped=self.dap.poll() is not None, forced=forced)
        result["listener_closed"] = self.port_closed(self.dap_port) if hasattr(self, "dap_port") else True
        (self.output / ("dap-" + str(len(self.cleanup)+1) + ".log")).write_text(self.sanitize("".join(self.dap_lines)))
        self.cleanup.append(result)
        self.dap = None
        self.trace(dict(type="dap_cleanup", **result))
        return result

    @staticmethod
    def port_closed(port):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return False
        except OSError:
            return True

    def mutate(self, kind, artifact=None):
        if kind not in ("config", "source", "artifact", "syntax"):
            raise ValueError("unknown owned fixture mutation")
        target = self.config_path if kind == "config" else self.machine
        if kind == "syntax":
            target = self.conformance
        if kind == "artifact":
            parts = PurePosixPath(artifact)
            if parts.is_absolute() or ".." in parts.parts or ":" in artifact or "\\" in artifact:
                raise ValueError("mutation must stay in owned project")
            target = self.root.joinpath(*parts.parts)
            if not target.resolve().is_relative_to(self.root.resolve()):
                raise ValueError("owned mutation escaped project")
        data = target.read_bytes()
        self.saved.setdefault(target, data)
        changed = data[:-1] + bytes([data[-1] ^ 1]) if kind == "artifact" else data + b"\n"
        target.write_bytes(b"invalid syntax ;\n" if kind == "syntax" else changed)
        return dict(kind=kind, sha256=digest(target))

    def restore(self):
        for path, data in self.saved.items():
            path.write_bytes(data)
        self.saved.clear()
        return dict(restored=True)

    def close(self):
        self.collect_dap(force=True)
        self.restore()
        if self.guard is not None:
            self.guard.restore()
            self.guard = None
        result = self.server.close()
        self.cleanup.append(dict(kind="rpc", listener_closed=self.port_closed(self.server.port), **result))
        self.final = dict(cleanup=self.cleanup, head=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.work, text=True, timeout=10).strip(),
                          git_status=subprocess.check_output(["git", "status", "--porcelain"], cwd=self.work, text=True, timeout=10).splitlines(),
                          binary_sha256=digest(self.emulator))
        (self.output / "controller-summary.json").write_text(json.dumps(self.final, indent=2)+"\n")
        self.stream.close()
        return self.final


def main():
    parser = argparse.ArgumentParser()
    for key in ("worktree", "output", "zig"):
        parser.add_argument("--"+key, required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()
    if not 0 < args.timeout <= 600:
        parser.error("bounded timeout required")
    controller = Controller(args)
    incoming = queue.Queue(maxsize=16)
    def read():
        for line in iter(lambda: sys.stdin.readline(65537), ""):
            incoming.put(line)
        incoming.put(None)
    threading.Thread(target=read, daemon=True).start()
    try:
        print(json.dumps(dict(type="ready", server=controller.ready())), flush=True)
        while time.monotonic() < controller.deadline:
            try:
                line = incoming.get(timeout=1)
            except queue.Empty:
                continue
            if line is None:
                break
            request = json.loads(line)
            command = request["command"]
            if command == "quit":
                cleanup = controller.close()
                print(json.dumps(dict(id=request["id"], ok=True, result=cleanup)), flush=True)
                return 0
            try:
                if command == "dap": result = controller.start_dap()
                elif command == "collect": result = controller.collect_dap()
                elif command == "restore": result = controller.restore()
                elif command == "mutate": result = controller.mutate(request["kind"], request.get("artifact"))
                elif command == "root_guard":
                    if controller.guard is not None: raise RuntimeError("root guard already active")
                    controller.guard = root_guard.Fixture(controller.base, controller.root, controller.output)
                    result = controller.guard.metadata()
                elif command == "root_guard_directory":
                    controller.guard.child.mkdir()
                    result = dict(kind="directory")
                elif command == "root_guard_restore":
                    controller.guard.restore()
                    controller.guard = None
                    result = dict(restored=True)
                else: raise ValueError("unknown controller operation")
                print(json.dumps(dict(id=request["id"], ok=True, result=result)), flush=True)
            except Exception as error:
                controller.trace(dict(type="controller_error", traceback=traceback.format_exc()))
                print(json.dumps(dict(id=request["id"], ok=False, error=str(error))), flush=True)
    finally:
        if not controller.stream.closed:
            controller.close()


if __name__ == "__main__":
    raise SystemExit(main())
