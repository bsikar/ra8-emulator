"""Actual project DAP process and independent client-only source requests."""
import importlib.util
from pathlib import Path, PurePosixPath
import queue
import re
import socket
import subprocess
import threading
import time
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("project_dap_client", ROOT / "tools/dap_conformance/client.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sys.path.insert(0, str(ROOT / "tools/gdb_conformance"))
from oracle import generate


class Case:
    def __init__(self, h):
        self.h = h

    def record(self, event, **values):
        self.h.trace(dict(type="dap_" + event, **values))

    def equal(self, name, expected, actual):
        self.h.check(name, actual, expected)

    def require(self, name, condition, actual=None):
        self.h.check(name, bool(condition), True)


class Session:
    def __init__(self, h, plain=None):
        self.h, self.peer, self.logs = h, None, []
        args = [str(h.emulator), "project", "dap", "0", str(h.base), getattr(h, "dap_config", "project.json"), "--zig", str(h.zig)]
        if plain is not None:
            args = [str(h.emulator), "dap", "0", str(plain)]
        self.child = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                      stderr=subprocess.STDOUT, text=True, encoding="utf8", errors="replace")
        h.trace(dict(type="dap_spawn", argv=args, pid=self.child.pid))
        self.lines = queue.Queue(maxsize=128)
        self.reader = threading.Thread(target=self.drain, daemon=True)
        self.reader.start()
        try:
            deadline = min(h.deadline, time.monotonic() + 15)
            while time.monotonic() < deadline:
                if self.child.poll() is not None:
                    raise RuntimeError("project DAP exited before listener: " + "".join(self.logs))
                try:
                    line = self.lines.get(timeout=0.1)
                except queue.Empty:
                    continue
                found = re.fullmatch(r"dap: listening on tcp:127\.0\.0\.1:(\d+)\s*", line)
                if found:
                    self.port = int(found.group(1))
                    self.peer = module.Client(self.port, Case(h), 5, h.deadline)
                    self.peer.request("initialize", {"adapterID": "project-public", "pathFormat": "path"})
                    return
            raise TimeoutError("project DAP listener deadline")
        except Exception:
            self.close()
            raise

    def drain(self):
        captured = 0
        for line in iter(lambda: self.child.stdout.readline(4096), ""):
            if captured < 1_000_000:
                self.logs.append(line[:1_000_000-captured])
                captured += len(line)
            try:
                self.lines.put_nowait(line)
            except queue.Full:
                pass

    def disconnect(self):
        self.peer.request("disconnect")
        self.peer.event("terminated")
        self.h.check("project DAP explicit disconnect exits zero", self.child.wait(timeout=5), 0)

    def close(self):
        if hasattr(self, "cleanup"):
            return
        if self.peer:
            self.peer.close()
        forced = False
        try:
            self.child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            forced = True
            self.child.kill()
            self.child.wait(timeout=5)
        self.reader.join(timeout=1)
        self.child.stdout.close()
        closed = True
        if hasattr(self, "port"):
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                    closed = False
            except OSError:
                pass
        self.cleanup = dict(kind="dap", exit_code=self.child.returncode, reaped=self.child.poll() is not None,
                            forced=forced, listener_closed=closed)
        self.h.processes.append(self.cleanup)
        self.h.trace(dict(type="dap_cleanup", **self.cleanup, log="".join(self.logs)))


def frame(peer):
    return peer.request("stackTrace", {"threadId": 1})["body"]["stackFrames"][0]


def reject(h, receipt, expected):
    session = Session(h)
    try:
        result = session.peer.request("launch", {"program": receipt}, success=False)
        h.check("rejected receipt exact reason", result["message"], expected)
        result = session.peer.request("threads", success=False)
        h.check("rejected launch never attached a target", result["message"], "NotAttached")
        session.disconnect()
    finally:
        session.close()


def run(h, receipt, mutation=None):
    value = __import__("json").loads((h.root / receipt).read_text())
    oracle = generate(h.root / value["artifact"], h.machine)
    h.trace(dict(type="oracle", value=oracle))
    session = Session(h)
    try:
        peer = session.peer
        peer.request("launch", {"program": receipt, "stopOnEntry": True})
        peer.event("initialized")
        peer.request("configurationDone")
        peer.event("stopped")
        h.check("project receipt loads known entry", int(frame(peer)["instructionPointerReference"], 0), oracle["entry"])
        peer.request("setInstructionBreakpoints", {"breakpoints": [{"instructionReference": hex(oracle["ready"])}]})
        peer.request("continue", {"threadId": 1})
        peer.event("stopped")
        current = frame(peer)
        scopes = peer.request("scopes", {"frameId": current["id"]})["body"]["scopes"]
        reference = next(s["variablesReference"] for s in scopes if s["name"] == "Registers")
        values = {v["name"]: int(v["value"], 0) for v in peer.request("variables", {"variablesReference": reference})["body"]["variables"]}
        for name, expected in oracle["ready_registers"].items():
            h.check("project known register " + name, values[name], expected)
        peer.request("setInstructionBreakpoints", {"breakpoints": []})
        peer.request("stepIn", {"threadId": 1, "granularity": "instruction"})
        stopped = peer.event("stopped")
        h.check("project instruction step uses Session stop reason", stopped["body"]["reason"], "step")
        h.check("project instruction step exact PC", int(frame(peer)["instructionPointerReference"], 0), oracle["ready"] + 2)
        client_path = "C:/client-only/project/machine.zig"
        rejected = peer.request("setBreakpoints", {"source": {"path": "C:/wrong-root/machine.zig"}, "breakpoints": [{"line": 60}]}, success=False)
        h.check("unmapped client source refused", rejected["message"], "SourceUnavailable")
        points = peer.request("setBreakpoints", {"source": {"path": client_path}, "breakpoints": [{"line": 60}]})["body"]["breakpoints"]
        h.check("client-only source breakpoint verified", [p["verified"] for p in points], [True])
        peer.request("continue", {"threadId": 1})
        peer.event("stopped")
        current = frame(peer)
        h.check("mapped stack client-only source", current["source"]["path"].replace("\\", "/"), client_path)
        h.check("mapped source line", current["line"], 60)
        h.check("mapped source exact address", int(current["instructionPointerReference"], 0), 0x220000e0)
        if mutation:
            mutation(h, peer, client_path)
        session.disconnect()
    finally:
        session.close()
