"""Bounded owned SSH controller and loopback forwards, with no remote wire client."""
import json
from pathlib import Path
import queue
import shlex
import socket
import subprocess
import threading
import time


class Controller:
    def __init__(self, h, args):
        self.h, self.sequence = h, 0
        remote = ["/opt/homebrew/bin/python3", "-B", args.server_worktree + "/tools/project_smoke/remote_controller.py",
                  "--worktree", args.server_worktree, "--output", args.server_output,
                  "--zig", args.server_zig, "--timeout", str(args.timeout)]
        self.stderr = (h.output / "controller-ssh.stderr.log").open("w", encoding="utf8")
        self.child = subprocess.Popen(["ssh", "-oBatchMode=yes", "-oConnectTimeout=10", args.ssh, shlex.join(remote)],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
                                      text=True, encoding="utf8", errors="replace", bufsize=1)
        self.lines = queue.Queue(maxsize=32)
        def read():
            for line in iter(lambda: self.child.stdout.readline(1_000_001), ""):
                self.lines.put(line)
            self.lines.put(None)
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        self.ready = self.receive(30)
        assert self.ready["type"] == "ready"

    def receive(self, timeout):
        left = min(timeout, self.h.deadline-time.monotonic())
        if left <= 0:
            raise TimeoutError("SSH controller overall deadline")
        try:
            line = self.lines.get(timeout=left)
        except queue.Empty:
            raise TimeoutError("SSH controller response deadline")
        if line is None:
            raise EOFError("SSH controller closed; see owned stderr log")
        if len(line) > 1_000_000:
            raise AssertionError("controller response bound")
        result = json.loads(line)
        self.h.trace(dict(type="controller_response", value=result))
        return result

    def request(self, command, **values):
        self.sequence += 1
        request = dict(id=self.sequence, command=command, **values)
        self.h.trace(dict(type="controller_request", value=request))
        self.child.stdin.write(json.dumps(request)+"\n")
        self.child.stdin.flush()
        result = self.receive(30)
        assert result["id"] == self.sequence and result["ok"], result
        return result["result"]

    def close(self):
        remote_cleanup = self.request("quit")
        self.child.stdin.close()
        code = self.child.wait(timeout=10)
        self.reader.join(timeout=1)
        self.child.stdout.close()
        self.stderr.close()
        self.h.check("owned SSH controller exited zero", code, 0)
        return dict(exit_code=code, reaped=self.child.poll() is not None, remote_cleanup=remote_cleanup)


class Tunnel:
    def __init__(self, h, host, remote_port):
        self.h = h
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            self.port = reserve.getsockname()[1]
        self.lines, self.ready = [], threading.Event()
        argv = ["ssh", "-v", "-N", "-oBatchMode=yes", "-oConnectTimeout=10", "-oExitOnForwardFailure=yes",
                "-L", f"127.0.0.1:{self.port}:127.0.0.1:{remote_port}", host]
        self.child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                      stderr=subprocess.PIPE, text=True, encoding="utf8", errors="replace")
        def read():
            captured = 0
            for line in iter(lambda: self.child.stderr.readline(4096), ""):
                if captured < 1_000_000:
                    self.lines.append(line[:1_000_000-captured])
                    captured += len(line)
                if f"Local forwarding listening on 127.0.0.1 port {self.port}." in line:
                    self.ready.set()
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        if not self.ready.wait(timeout=15) or self.child.poll() is not None:
            self.close()
            raise RuntimeError("owned SSH forwarding startup failed")
        h.trace(dict(type="tunnel_ready", local_port=self.port, remote_port=remote_port, argv=argv))

    def close(self):
        if hasattr(self, "cleanup"):
            return self.cleanup
        if self.child.poll() is None:
            self.child.terminate()
        code = self.child.wait(timeout=10)
        self.reader.join(timeout=1)
        self.child.stderr.close()
        closed = True
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                closed = False
        except OSError:
            pass
        self.cleanup = dict(kind="ssh_tunnel", exit_code=code, reaped=self.child.poll() is not None,
                            listener_closed=closed, method="terminate_owned_ssh_handle")
        self.h.trace(dict(type="tunnel_cleanup", **self.cleanup, log="".join(self.lines)))
        self.h.tunnels.append(self.cleanup)
        return self.cleanup
