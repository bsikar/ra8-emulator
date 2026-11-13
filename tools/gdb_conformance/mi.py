"""Small actual-GDB MI client, used for bounded asynchronous interrupts."""
import json
import queue
import subprocess
import threading
import time


class Client:
    def __init__(self, gdb, deadline):
        self.deadline = deadline
        self.process = subprocess.Popen([str(gdb), "-q", "-nx", "--interpreter=mi2"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, text=True,
                                        encoding="utf-8", errors="replace", bufsize=1)
        self.lines, self.events = [], []
        self.queue = queue.Queue()
        self.token = 0
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.process.stdout:
            self.lines.append(line)
            self.queue.put(line.strip())

    def request(self, command, timeout=10, allow_error=False):
        self.token += 1
        token = str(self.token)
        self.lines.append("CLIENT " + token + command + "\n")
        self.process.stdin.write(token + command + "\n")
        self.process.stdin.flush()
        deadline = min(self.deadline, time.monotonic() + timeout)
        while time.monotonic() < deadline:
            try:
                line = self.queue.get(timeout=0.1)
            except queue.Empty:
                continue
            if line.startswith(token + "^"):
                if line.startswith(token + "^error") and not allow_error:
                    raise AssertionError(line)
                return line
            if line.startswith("*"):
                self.events.append(line)
        raise TimeoutError("GDB MI response deadline: " + command)

    def stopped(self, timeout=10):
        deadline = min(self.deadline, time.monotonic() + timeout)
        while time.monotonic() < deadline:
            for index, line in enumerate(self.events):
                if line.startswith("*stopped"):
                    return self.events.pop(index)
            try:
                line = self.queue.get(timeout=0.1)
            except queue.Empty:
                continue
            if line.startswith("*"):
                self.events.append(line)
        raise TimeoutError("GDB MI stopped event deadline")

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=5)
        self.reader.join(timeout=1)
        self.process.stdin.close()
        self.process.stdout.close()


def interrupt(gdb, emulator, fixture, oracle, deadline):
    loop = oracle["symbols"]["breakpoint_loop"]
    client = Client(gdb, deadline)
    try:
        client.request("-gdb-set mi-async on")
        client.request("-gdb-set remotetimeout 3")
        client.request("-gdb-set debug remote 1")
        client.request("-file-exec-and-symbols " + json.dumps(str(fixture)))
        client.request(f"-target-select remote 127.0.0.1:{emulator.port}")
        client.stopped()  # Consume the initial attach stop before waiting for execution.
        client.request(f"-break-insert *0x{loop:x}")
        client.request("-exec-continue")
        stopped = client.stopped()
        if 'reason="breakpoint-hit"' not in stopped:
            raise AssertionError(stopped)
        client.request("-break-delete")
        client.request("-exec-continue")
        time.sleep(0.1)
        start = time.monotonic()
        client.request("-exec-interrupt --all", timeout=3)
        stopped = client.stopped(timeout=3)
        elapsed = time.monotonic() - start
        if 'signal-name="SIGINT"' not in stopped or elapsed > 3:
            raise AssertionError("unexpected bounded interrupt: " + stopped)
        value = client.request('-data-evaluate-expression "$pc"')
        if f"0x{loop:x}" not in value and f"0x{loop + 2:x}" not in value:
            raise AssertionError("interrupt PC outside fixture loop: " + value)
        client.request("-target-detach")
        client.request("-gdb-exit")
        code = client.process.wait(timeout=5)
        if code != 0:
            raise AssertionError("GDB MI exit code " + str(code))
        return {"interrupt_seconds": elapsed, "interrupt_mechanism": "gdb-mi-exec-interrupt",
                "gdb_exit_code": code}, "".join(client.lines)
    except Exception as error:
        error.transcript = "".join(client.lines)
        raise
    finally:
        client.close()


def errors(gdb, emulator, fixture, oracle, deadline):
    client = Client(gdb, deadline)
    try:
        client.request("-file-exec-and-symbols " + json.dumps(str(fixture)))
        client.request(f"-target-select remote 127.0.0.1:{emulator.port}")
        client.stopped()
        before = client.request('-data-evaluate-expression "$pc"').split(",", 1)[1]
        thread = client.request("-thread-select 999", allow_error=True)
        memory = client.request("-data-read-memory-bytes 0xfffffff0 4", allow_error=True)
        if "^error" not in thread or "^error" not in memory:
            raise AssertionError("invalid thread and unmapped memory must both refuse")
        after = client.request('-data-evaluate-expression "$pc"').split(",", 1)[1]
        if before != after or f"0x{oracle['entry']:x}" not in before:
            raise AssertionError("error requests changed the fixture entry PC")
        client.request("-target-detach")
        client.request("-gdb-exit")
        code = client.process.wait(timeout=5)
        if code != 0:
            raise AssertionError("GDB MI exit code " + str(code))
        return {"invalid_thread_refused": True, "unmapped_memory_refused": True,
                "entry_pc_preserved": True, "gdb_exit_code": code}, "".join(client.lines)
    except Exception as error:
        error.transcript = "".join(client.lines)
        raise
    finally:
        client.close()
