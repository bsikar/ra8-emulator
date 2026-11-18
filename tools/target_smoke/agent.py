"""Bounded ownership of a separate authenticated probe-agent subprocess."""
import queue
import signal
import subprocess
import threading
import time


class AgentProcess:
    def __init__(self, emulator, targets_path, secret_path, host_id, output, trace, deadline, port=0):
        command = [str(emulator), "probe-agent", "--targets", str(targets_path),
                   "--secret-file", str(secret_path), "--host-id", host_id,
                   "--listen", f"tcp:127.0.0.1:{port}"]
        flags = subprocess.CREATE_NEW_PROCESS_GROUP if hasattr(subprocess, "CREATE_NEW_PROCESS_GROUP") else 0
        self.process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, text=True, encoding="utf8",
                                        errors="replace", creationflags=flags)
        self.output, self.trace, self.lines = output, trace, []
        self.queue = queue.Queue(maxsize=128)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        trace(dict(type="agent_start", command=command, pid=self.process.pid))
        try:
            ready = min(deadline, time.monotonic() + 15)
            while time.monotonic() < ready:
                if self.process.poll() is not None:
                    raise RuntimeError("probe-agent exited before publishing listener")
                try:
                    line = self.queue.get(timeout=0.1)
                except queue.Empty:
                    continue
                if line.startswith("probe-agent: listening on tcp:"):
                    self.port = int(line.rsplit(":", 1)[1])
                    return
            raise TimeoutError("probe-agent startup deadline")
        except Exception:
            self.close()
            raise

    def _read(self):
        for line in iter(lambda: self.process.stdout.readline(4096), ""):
            if len(self.lines) < 256:
                self.lines.append(line[:4096])
            try:
                self.queue.put_nowait(line[:4096])
            except queue.Full:
                pass

    def close(self):
        if hasattr(self, "cleanup"):
            return self.cleanup
        if self.process.poll() is None:
            try:
                event = signal.CTRL_BREAK_EVENT if hasattr(signal, "CTRL_BREAK_EVENT") else signal.SIGTERM
                self.process.send_signal(event)
                self.process.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait(timeout=5)
        self.reader.join(timeout=1)
        self.process.stdout.close()
        self.output.write_text("".join(self.lines), encoding="utf8")
        self.cleanup = dict(exit_code=self.process.returncode)
        self.trace(dict(type="agent_cleanup", **self.cleanup))
        return self.cleanup
