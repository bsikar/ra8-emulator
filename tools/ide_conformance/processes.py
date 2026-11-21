"""Bounded subprocess and listener ownership tracking for CI and HIL conformance runs."""
import os
from pathlib import Path
import queue
import signal
import socket
import subprocess
import threading
import time
from types import SimpleNamespace


def listener_closed(port):
    if port is None:
        return True
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.15):
                pass
        except OSError:
            return True
        time.sleep(0.05)
    return False


class ManagedProcess:
    def __init__(self, command, ready_prefix, trace, tag, log_path: Path, deadline, env=None, port_from_ready=False):
        self.tag = tag
        self.trace = trace
        self.log_path = log_path
        self.port = None
        self.cleanup = None
        flags = subprocess.CREATE_NEW_PROCESS_GROUP if hasattr(subprocess, "CREATE_NEW_PROCESS_GROUP") else 0
        self.proc = subprocess.Popen(
            [str(part) for part in command],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf8",
            errors="replace",
            env=env,
            creationflags=flags,
            start_new_session=(os.name != "nt"),
        )
        self.q = queue.Queue(maxsize=512)
        self.lines = []
        self.reader = threading.Thread(target=self._drain, daemon=True)
        self.reader.start()
        trace(dict(type="proc_start", tag=tag, argv=[str(x) for x in command], pid=self.proc.pid))
        if ready_prefix is not None:
            limit = min(deadline, time.monotonic() + 25.0)
            while time.monotonic() < limit:
                if self.proc.poll() is not None:
                    self.close()
                    raise RuntimeError(f"{tag} exited before ready ({self.proc.returncode}): {''.join(self.lines)}")
                try:
                    line = self.q.get(timeout=0.1)
                except queue.Empty:
                    continue
                if ready_prefix in line:
                    self.ready_line = line.strip()
                    if port_from_ready:
                        self.port = int(self.ready_line.rsplit(":", 1)[1])
                    return
            self.close()
            raise TimeoutError(f"{tag} startup deadline waiting for {ready_prefix!r}")

    def _drain(self):
        captured = 0
        for line in iter(lambda: self.proc.stdout.readline(4096), ""):
            if captured < 1_000_000:
                self.lines.append(line[:1_000_000 - captured])
                captured += len(line)
            try:
                self.q.put_nowait(line)
            except queue.Full:
                pass

    def close(self, allow_signal_exit=False):
        if self.cleanup is not None:
            return self.cleanup
        forced = False
        method = "already_exited"
        if self.proc.poll() is None:
            method = "graceful_signal"
            try:
                if os.name == "nt":
                    self.proc.send_signal(signal.CTRL_BREAK_EVENT)
                else:
                    self.proc.terminate()
                self.proc.wait(timeout=8.0)
            except (OSError, subprocess.TimeoutExpired):
                forced = True
                method = "forced_kill"
                if os.name == "nt":
                    killer = Path(os.environ["SystemRoot"]) / "System32/taskkill.exe"
                    subprocess.run([str(killer), "/PID", str(self.proc.pid), "/T", "/F"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
                else:
                    try:
                        os.killpg(self.proc.pid, signal.SIGKILL)
                    except OSError:
                        self.proc.kill()
                self.proc.wait(timeout=5.0)
        self.reader.join(timeout=2.0)
        if self.proc.stdout:
            self.proc.stdout.close()
        self.log_path.write_text("".join(self.lines), encoding="utf8")
        closed = listener_closed(self.port)
        exit_ok = (self.proc.returncode == 0) or allow_signal_exit
        self.cleanup = dict(
            tag=self.tag,
            method=method,
            exit_code=self.proc.returncode,
            exit_ok=exit_ok,
            reaped=(self.proc.poll() is not None),
            forced=forced,
            listener_closed=closed,
        )
        self.trace(dict(type="proc_cleanup", **self.cleanup))
        return self.cleanup


def run_cli(argv, log_dir: Path, index: int, trace, deadline, env=None, cwd=None, timeout=120.0):
    budget = max(0.01, min(timeout, deadline - time.monotonic()))
    out_path = log_dir / f"cmd-{index:03d}.stdout.log"
    err_path = log_dir / f"cmd-{index:03d}.stderr.log"
    cmd = [str(x) for x in argv]
    trace(dict(type="cmd_start", index=index, argv=cmd))
    forced = False
    with out_path.open("wb") as out, err_path.open("wb") as err:
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                env=env, cwd=cwd, start_new_session=(os.name != "nt"))
        try:
            proc.wait(timeout=budget)
        except subprocess.TimeoutExpired:
            forced = True
            if os.name == "nt":
                killer = Path(os.environ["SystemRoot"]) / "System32/taskkill.exe"
                subprocess.run([str(killer), "/PID", str(proc.pid), "/T", "/F"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            else:
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=5.0)
    stdout = out_path.read_text(encoding="utf8", errors="replace")
    stderr = err_path.read_text(encoding="utf8", errors="replace")
    assert len(stdout) <= 2_000_000 and len(stderr) <= 2_000_000, "CLI output bound"
    rec = dict(index=index, exit_code=proc.returncode, reaped=(proc.poll() is not None), forced=forced)
    trace(dict(type="cmd_exit", **rec))
    if forced:
        raise TimeoutError(f"CLI command {index} timed out: {cmd}")
    return SimpleNamespace(returncode=proc.returncode, stdout=stdout, stderr=stderr, cleanup=rec)
