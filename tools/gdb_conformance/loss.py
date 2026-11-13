"""Actual-GDB connection loss while the public target runs an infinite fixture loop."""
import hashlib
import json
import os
import subprocess
import time

from mi import Client
from process import Emulator, sanitize, write_json


def running(client, loop):
    client.request("-gdb-set mi-async on")
    client.request("-gdb-set remotetimeout 3")
    client.request("-gdb-set debug remote 1")
    client.request(f"-target-select remote 127.0.0.1:{client.emulator_port}")
    client.stopped()
    client.request(f"-break-insert *0x{loop:x}")
    client.request("-exec-continue")
    stopped = client.stopped()
    if 'reason="breakpoint-hit"' not in stopped or f'addr="0x{loop:x}"' not in stopped:
        raise AssertionError("fixture loop breakpoint did not stop at its oracle PC: " + stopped)
    client.request("-break-delete")
    first = len(client.lines)
    client.request("-exec-continue")
    until = min(client.deadline, time.monotonic() + 3)
    while time.monotonic() < until:
        trace = "".join(client.lines[first:])
        sent = trace.find("Sending packet: $vCont;c")
        if sent >= 0 and "Received Ack" in trace[sent:]:
            return
        time.sleep(0.005)
    raise TimeoutError("actual GDB did not receive the running resume ACK")


def run(args, oracle):
    """Return one scenario result and write its transcript/artifacts for run.py aggregation."""
    name = "connection-loss-running"
    result = {"name": name, "status": "FAIL", "expected_emulator_exit_codes": [0, 1],
              "expected_exit_meaning": "normal EOF or controlled stream-close error"}
    emulator = None
    client = None
    try:
        deadline = min(args.deadline, time.monotonic() + 30)
        emulator = Emulator(args.emulator, args.fixture, deadline=deadline)
        emulator.ready()
        client = Client(args.gdb, deadline)
        client.emulator_port = emulator.port
        client.request("-file-exec-and-symbols " + json.dumps(str(args.fixture)))
        running(client, oracle["symbols"]["breakpoint_loop"])
        result["resume_ack_received"] = True
        client.lines.append("CLIENT deliberately kill and reap only the owned actual GDB client\n")
        began = time.perf_counter()
        client.process.kill()
        result["gdb_exit_code"] = client.process.wait(timeout=2)
        expected_client = 1 if os.name == "nt" else -9
        if result["gdb_exit_code"] != expected_client:
            raise AssertionError("unexpected owned GDB kill exit: " + str(result["gdb_exit_code"]))
        result["gdb_deliberately_killed"] = True
        code = emulator.process.wait(timeout=max(0.001, min(5, deadline - time.monotonic())))
        elapsed = time.perf_counter() - began
        result.update(emulator_exit_code=code, shutdown_seconds=elapsed)
        if code not in result["expected_emulator_exit_codes"] or elapsed > 5:
            raise AssertionError("connection loss exit must be controlled and within five seconds")
        emulator.reader.join(timeout=1)
        if code != 0 and "error: WriteFailed" not in "".join(emulator.lines):
            raise AssertionError("nonzero emulator exit lacks the expected stream-write diagnostic")
        result.update(status="PASS", forced_emulator_cleanup=False)
    except Exception as error:
        result["error"] = f"{type(error).__name__}: {error}"
    finally:
        if client is not None:
            client.close()
            result["owned_gdb_reaped"] = client.process.poll() is not None
            (args.output / (name + ".client.log")).write_text(
                sanitize("".join(client.lines), args.repo, args.output), encoding="utf-8")
        if emulator is not None:
            result["forced_emulator_cleanup"] = emulator.process.poll() is None
            emulator.close()
            result["owned_child_reaped"] = emulator.process.poll() is not None
            (args.output / (name + ".emulator.log")).write_text(
                sanitize("".join(emulator.lines), args.repo, args.output), encoding="utf-8")
        result["emulator_sha256"] = hashlib.sha256(args.emulator.read_bytes()).hexdigest()
        write_json(args.output / (name + ".result.json"), result)
    return result
