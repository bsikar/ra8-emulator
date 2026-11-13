"""Bounded ownership of a separate public workspace RPC backend."""
import queue
import signal
import subprocess
import threading
import time


class Server:
    def __init__(self, emulator, fixture, workspace, output, trace, deadline, sanitize):
        command = [str(emulator), "serve"]
        if workspace is not None:
            command += ["--workspace", str(workspace)]
        command += ["--history", "off", "--listen", "tcp::0", str(fixture)]
        flags = subprocess.CREATE_NEW_PROCESS_GROUP if hasattr(subprocess, "CREATE_NEW_PROCESS_GROUP") else 0
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
                    raise RuntimeError("server exited before publishing listener")
                try:
                    line = self.queue.get(timeout=0.1)
                except queue.Empty:
                    continue
                if line.startswith("serve: listening on tcp:"):
                    self.port = int(line.rsplit(":", 1)[1])
                    return
            raise TimeoutError("workspace RPC listener startup deadline")
        except Exception:
            self.close()
            raise

    def _read(self):
        captured = 0
        for line in iter(lambda: self.process.stdout.readline(4096), ""):
            if captured < 1024 * 1024:
                bounded = line[:1024 * 1024 - captured]
                self.lines.append(bounded)
                captured += len(bounded)
            try:
                self.queue.put_nowait(line[:4096])
            except queue.Full:
                pass

    def close(self):
        if hasattr(self, "cleanup"):
            return self.cleanup
        method = "already_exited"
        if self.process.poll() is None:
            try:
                event = signal.CTRL_BREAK_EVENT if hasattr(signal, "CTRL_BREAK_EVENT") else signal.SIGTERM
                self.process.send_signal(event)
                method = "graceful_signal"
                self.process.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired) as error:
                method = "owned_terminate_after_" + type(error).__name__
                try:
                    self.process.terminate()
                    self.process.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    method = "owned_kill_after_termination_failure"
                    self.process.kill()
                    self.process.wait(timeout=5)
        self.reader.join(timeout=1)
        self.process.stdout.close()
        self.output.write_text(self.sanitize("".join(self.lines)), encoding="utf8")
        result = dict(method=method, exit_code=self.process.returncode,
                      owned_child_reaped=self.process.poll() is not None)
        self.trace(dict(type="server_cleanup", **result))
        self.cleanup = result
        return result
