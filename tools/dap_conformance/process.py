"""Ownership and bounded cleanup for public emulator DAP processes."""
import queue
import re
import socket
import subprocess
import threading
import time

from client import Client


class Session:
    def __init__(self, settings, case, mode="launch"):
        self.settings = settings
        self.case = case
        self.mode = mode
        self.client = None
        self.process = None
        self.stderr = []
        self.stdout = []
        self.port = None
        self.exit = None
        self.forced = False

    def __enter__(self):
        args = [str(self.settings.emulator), "dap", "0"]
        if self.mode == "attach":
            args.append(str(self.settings.fixture))
        self.case.record("spawn", argv=args)
        self.process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
        lines = queue.Queue()
        self.threads = [threading.Thread(target=self._drain, args=(self.process.stderr, self.stderr, lines), daemon=True), threading.Thread(target=self._drain, args=(self.process.stdout, self.stdout, None), daemon=True)]
        for thread in self.threads:
            thread.start()
        until = min(self.settings.deadline, time.monotonic() + self.settings.startup_timeout)
        try:
            self._startup(lines, until)
            self.client = Client(self.port, self.case, self.settings.request_timeout, self.settings.deadline)
            return self
        except BaseException:
            self.close()
            raise

    @staticmethod
    def _drain(stream, target, lines):
        for line in stream:
            target.append(line)
            if lines is not None:
                lines.put(line)

    def _startup(self, lines, until):
        while time.monotonic() < until:
            if self.process.poll() is not None and lines.empty():
                raise RuntimeError(f"adapter exited during startup: {self.process.returncode}; {''.join(self.stderr)}")
            try:
                line = lines.get(timeout=min(0.05, max(0.001, until - time.monotonic())))
            except queue.Empty:
                continue
            found = re.fullmatch(r"dap: listening on tcp:127\.0\.0\.1:(\d+)\s*", line)
            if found:
                self.port = int(found.group(1))
                return
        raise TimeoutError("adapter did not publish its loopback endpoint before startup deadline")

    def wait_exit(self, expected=0):
        timeout = max(0.001, min(5, self.settings.deadline - time.monotonic()))
        self.exit = self.process.wait(timeout=timeout)
        if expected is not None:
            self.case.equal("adapter process exit", expected, self.exit)
        return self.exit

    def close(self):
        if self.client is not None:
            self.client.close()
            self.client = None
        if self.process is None:
            return
        try:
            self.exit = self.process.wait(timeout=max(0.001, min(5, self.settings.deadline - time.monotonic())))
        except subprocess.TimeoutExpired:
            self.forced = True
            self.process.kill()
            self.exit = self.process.wait(timeout=5)
        for thread in self.threads:
            thread.join(timeout=1)
        self.process.stdout.close()
        self.process.stderr.close()
        closed = True
        if self.port is not None:
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                    closed = False
            except OSError:
                pass
        result = {"exit_status": self.exit, "reaped": self.process.poll() is not None, "forced_cleanup": self.forced, "listener_closed": closed}
        self.case.result["processes"].append(result)
        self.case.record("process_exit", **result)
        self.case.record("stderr", text="".join(self.stderr))
        self.case.record("stdout", text="".join(self.stdout))
        self.case.require("owned process reaped without forced cleanup", result["reaped"] and not self.forced)
        self.case.equal("owned listener closed", True, closed)

    def __exit__(self, kind, error, traceback):
        self.close()
