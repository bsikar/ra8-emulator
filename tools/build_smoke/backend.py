"""Separate backend ownership, with the shared bounded cleanup implementation."""
import queue
import subprocess
import threading
import time

from server import Server


class Backend(Server):
    def __init__(self, emulator, firmware, workspace, compiler, output, trace, deadline, sanitize):
        command = [str(emulator), "serve", "--workspace", str(workspace)]
        if compiler is not None:
            command += ["--build-zig", str(compiler)]
        command += ["--history", "off", "--listen", "tcp::0", str(firmware)]
        flags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        self.process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, text=True, encoding="utf8",
                                        errors="replace", creationflags=flags)
        self.output, self.trace, self.lines, self.sanitize = output, trace, [], sanitize
        self.queue = queue.Queue(maxsize=128)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        trace(dict(type="server_start", command=command, pid=self.process.pid))
        try:
            ready = min(deadline, time.monotonic() + 15)
            while time.monotonic() < ready:
                if self.process.poll() is not None:
                    raise RuntimeError("backend exited before listener ready")
                try:
                    line = self.queue.get(timeout=0.1)
                except queue.Empty:
                    continue
                if line.startswith("serve: listening on tcp:"):
                    self.port = int(line.rsplit(":", 1)[1])
                    return
            raise TimeoutError("backend startup deadline")
        except Exception:
            self.close()
            raise
