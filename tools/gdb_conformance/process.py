"""Finite process ownership for the public real-GDB conformance mode."""
import queue
import socket
import subprocess
import threading
import time
from pathlib import Path


def sanitize(text, repo, output):
    replacements = ((str(output), "${ARTIFACTS}"), (str(repo), "${REPO}"),
                    (str(Path.home()), "${HOME}"))
    for root, marker in replacements:
        escaped = root
        spellings = {root.replace("\\", "/")}
        for _ in range(3):
            spellings.add(escaped)
            escaped = escaped.replace("\\", "\\\\")
        for spelling in sorted(spellings, key=len, reverse=True):
            text = text.replace(spelling, marker)
    return text


class Emulator:
    def __init__(self, executable, fixture, cpu1=None, deadline=None):
        self.deadline = deadline or time.monotonic() + 180
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            self.port = reserve.getsockname()[1]
        args = [str(executable), str(fixture)]
        if cpu1:
            args += ["--cpu1", str(cpu1)]
        args += ["--gdb", str(self.port)]
        self.process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        text=True, encoding="utf-8", errors="replace")
        self.lines = []
        self.queue = queue.Queue()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.process.stdout:
            if sum(map(len, self.lines)) < 1024 * 1024:
                self.lines.append(line)
            self.queue.put(line)

    def ready(self):
        deadline = min(self.deadline, time.monotonic() + 10)
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError("emulator exited before listener readiness")
            try:
                if "gdb: listening" in self.queue.get(timeout=0.1):
                    return
            except queue.Empty:
                pass
        raise TimeoutError("GDB listener startup exceeded 10 seconds")

    def finish(self):
        try:
            code = self.process.wait(timeout=max(0.001, min(5, self.deadline - time.monotonic())))
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
            raise AssertionError("emulator did not exit within five seconds after client detach")
        self.reader.join(timeout=1)
        if code != 0:
            raise AssertionError("emulator exit code " + str(code))
        return {"exit_code": code, "reaped": True}

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=5)
        self.reader.join(timeout=1)
        self.process.stdout.close()


def write_json(path, value):
    import json
    text = json.dumps(value, indent=2) + "\n"
    path.write_text(sanitize(text, Path(__file__).resolve().parents[2], path.parent), encoding="utf-8")
