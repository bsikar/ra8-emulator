"""Build protocol assertions over the established public binary framing."""
import json
from pathlib import Path
import struct
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "workspace_smoke"))
import client as workspace_client

blob = workspace_client.blob
take_blob = workspace_client.take_blob
workspace_client.METHODS.update(build_start=0x160, build_status=0x161, build_cancel=0x162)


class Client(workspace_client.Client):
    def __init__(self, *args):
        self.outputs, self.completed, self.sequences = {}, {}, {}
        super().__init__(*args)

    def status_body(self, body):
        job, done = struct.unpack_from("<QB", body)
        raw, end = take_blob(body, 9)
        assert end == len(body) and done in (0, 1)
        result = json.loads(raw) if done else None
        return job, bool(done), result

    def event(self, payload):
        topic, = struct.unpack_from("<H", payload)
        body, end = take_blob(payload, 2)
        assert end == len(payload)
        if topic == 0x182:
            job, done, result = self.status_body(body)
            assert done and job not in self.completed, "single completion event"
            self.completed[job] = result
            self.trace(dict(type="build_completed", job=job, result=result))
            return
        assert topic == 0x181, ("unexpected topic", topic)
        job, sequence, kind = struct.unpack_from("<QQB", body)
        data, end = take_blob(body, 17)
        assert end == len(body) and len(data) <= 4096 and kind in (0, 1, 2)
        assert sequence > self.sequences.get(job, 0), "strict output sequence ordering"
        self.sequences[job] = sequence
        records = self.outputs.setdefault(job, [])
        assert len(records) < 8192, "bounded client event retention"
        value = json.loads(data) if kind == 2 else data.decode("utf8", errors="replace")
        records.append(dict(sequence=sequence, kind=kind, value=value))
        self.trace(dict(type="build_output", job=job, **records[-1]))

    def start(self, step="", options=None, artifact="bin/tiny.elf", timeout_ms=60000, error=None):
        encoded = options if isinstance(options, str) else json.dumps(options or [])
        args = blob(step) + blob(encoded) + blob(artifact) + struct.pack("<I", timeout_ms)
        started = time.monotonic()
        body = self.call("build_start", args, error)
        assert time.monotonic() - started < 3, "asynchronous start response"
        if error is not None:
            return None
        assert len(body) == 8
        return struct.unpack("<Q", body)[0]

    def status(self, job, error=None):
        body = self.call("build_status", struct.pack("<Q", job), error)
        if error is not None:
            return None
        received, done, result = self.status_body(body)
        assert received == job
        return done, result

    def cancel(self, job, error=None):
        body = self.call("build_cancel", struct.pack("<Q", job), error)
        if error is None:
            assert body == b"\x01"

    def finish(self, job, timeout=90):
        deadline = min(self.deadline, time.monotonic() + timeout)
        polls = 0
        while time.monotonic() < deadline:
            done, result = self.status(job)
            polls += 1
            if done:
                while job not in self.completed:
                    kind, body = self.frame(max(0.001, deadline - time.monotonic()))
                    assert kind == 4
                    self.event(body)
                assert self.completed[job] == result, "status agrees with completion event"
                if not result.get("stream_truncated", False):
                    events = self.outputs.get(job, [])
                    assert [event["sequence"] for event in events] == list(range(1, len(events) + 1)), "untruncated output has no sequence gaps"
                self.trace(dict(type="terminal_result", job=job, polls=polls, result=result))
                return result
            time.sleep(0.05)
        raise TimeoutError("build completion deadline")
