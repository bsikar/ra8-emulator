"""Independent stdlib implementation of the public RA8 binary workspace client."""
import hashlib
import json
import socket
import struct
import time

CAPABILITY = 1 << 16
TOPIC = 0x0180
MISSING = bytes(25)
METHODS = {"list": 0x140, "stat": 0x141, "read": 0x142,
           "write": 0x143, "watch": 0x144, "unwatch": 0x145}
CODES = {"bad_args": 2, "unavailable": 0x150, "invalid_path": 0x151,
         "conflict": 0x152, "too_large": 0x153, "not_found": 0x154,
         "invalid_watch": 0x155, "io": 0x156, "not_file": 0x157}


def blob(value):
    if isinstance(value, str):
        value = value.encode("utf8")
    return struct.pack("<I", len(value)) + value


def take_blob(data, offset=0):
    assert offset + 4 <= len(data), "truncated blob length"
    length, = struct.unpack_from("<I", data, offset)
    end = offset + 4 + length
    assert end <= len(data), "truncated blob"
    return data[offset + 4:end], end


def version(data):
    assert len(data) == 25, "workspace version must contain 25 bytes"
    kind, size, modified_ns, identity = struct.unpack("<BQqQ", data)
    return dict(kind=kind, size=size, modified_ns=modified_ns, identity=identity)


class Client:
    def __init__(self, port, trace, deadline):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=3)
        self.trace, self.deadline = trace, deadline
        self.buffer, self.events, self.next_id = bytearray(), [], 0
        self.send(1, struct.pack("<IHI", 0x52384152, 1, 0), fragmented=True)
        kind, payload = self.frame()
        assert kind == 1 and len(payload) == 10, "server greeting shape"
        magic, protocol, self.caps = struct.unpack("<IHI", payload)
        assert magic == 0x52384152 and protocol == 1, "server greeting protocol"
        trace(dict(type="greeting", capabilities=self.caps))

    def close(self):
        self.socket.close()

    def send(self, kind, payload, fragmented=False):
        packet = struct.pack("<IH", len(payload), kind) + payload
        self.trace(dict(direction="client", kind=kind, bytes=len(packet),
                        sha256=hashlib.sha256(packet).hexdigest(), preview_hex=packet[:96].hex()))
        if fragmented:
            for offset in range(0, len(packet), 7):
                self.socket.sendall(packet[offset:offset + 7])
        else:
            self.socket.sendall(packet)

    def frame(self, timeout=3):
        deadline = min(self.deadline, time.monotonic() + timeout)
        while True:
            if len(self.buffer) >= 6:
                length, kind = struct.unpack_from("<IH", self.buffer)
                assert length <= 1_048_590, "server sent oversized frame"
                if len(self.buffer) >= 6 + length:
                    packet = bytes(self.buffer[:6 + length])
                    del self.buffer[:6 + length]
                    self.trace(dict(direction="server", kind=kind, bytes=len(packet),
                                    sha256=hashlib.sha256(packet).hexdigest(), preview_hex=packet[:96].hex()))
                    return kind, packet[6:]
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError("RPC frame deadline")
            self.socket.settimeout(left)
            try:
                chunk = self.socket.recv(65536)
            except socket.timeout as error:
                raise TimeoutError("RPC frame deadline") from error
            if not chunk:
                raise EOFError("RPC peer closed")
            self.buffer.extend(chunk)

    def event(self, payload):
        topic, = struct.unpack_from("<H", payload)
        body, end = take_blob(payload, 2)
        assert end == len(payload) and topic == TOPIC, "unexpected event envelope"
        watch_id, state = struct.unpack_from("<IB", body)
        path, at = take_blob(body, 5)
        token, end = take_blob(body, at)
        assert end == len(body), "event trailing bytes"
        event = dict(id=watch_id, state=state, path=path.decode("utf8"),
                     version=version(token), token=token.hex())
        self.trace(dict(type="workspace_event", event=event))
        self.events.append(event)

    def call(self, method, args, error=None, fragmented=False):
        self.next_id += 1
        request_id = self.next_id
        self.send(2, struct.pack("<IH", request_id, METHODS[method]) + blob(args), fragmented)
        while True:
            kind, payload = self.frame()
            if kind == 4:
                self.event(payload)
                continue
            assert kind == 3 and len(payload) >= 5, "expected RPC response"
            received_id, tag = struct.unpack_from("<IB", payload)
            assert received_id == request_id, "response correlation"
            if tag == 1:
                assert len(payload) == 7, "error response shape"
                code, = struct.unpack_from("<H", payload, 5)
                self.trace(dict(type="response", method=method, id=request_id, code=code))
                assert error is not None and code == CODES.get(error, error), (method, error, code)
                return None
            assert tag == 0 and error is None, (method, "expected refusal", error)
            result, end = take_blob(payload, 5)
            assert end == len(payload), "response trailing bytes"
            self.trace(dict(type="response", method=method, id=request_id, code=0, body_bytes=len(result)))
            return result

    def stat(self, path, error=None):
        return self.call("stat", blob(path), error)

    def read(self, path, offset=0, length=262144, error=None):
        body = self.call("read", blob(path) + struct.pack("<QI", offset, length), error)
        if error is not None:
            return None
        token, at = take_blob(body)
        assert at < len(body), "read EOF field"
        eof = body[at]
        data, end = take_blob(body, at + 1)
        assert end == len(body) and eof in (0, 1), "read response shape"
        version(token)
        return token, bool(eof), data

    def write(self, path, expected, data, error=None):
        return self.call("write", blob(path) + blob(expected) + blob(data), error)

    def listing(self, path="", offset=0, limit=64, error=None):
        body = self.call("list", blob(path) + struct.pack("<IH", offset, limit), error)
        if error is not None:
            return None
        at, count, more = struct.unpack_from("<IHB", body)
        entries, end = take_blob(body, 7)
        entries = json.loads(entries)
        assert end == len(body) and at == offset and len(entries) == count and more in (0, 1)
        return entries, bool(more)

    def watch(self, path, error=None):
        body = self.call("watch", blob(path), error)
        if error is not None:
            return None
        assert len(body) == 4, "watch response shape"
        return struct.unpack("<I", body)[0]

    def unwatch(self, watch_id, error=None):
        result = self.call("unwatch", struct.pack("<I", watch_id), error)
        if error is None:
            assert result == b"\x01", "unwatch acknowledgement"

    def changed(self, watch_id, state=0, path=None, timeout=3):
        deadline = min(self.deadline, time.monotonic() + timeout)
        while True:
            for index, event in enumerate(self.events):
                if event["id"] == watch_id:
                    self.events.pop(index)
                    assert event["state"] == state and (path is None or event["path"] == path), event
                    return event
            kind, payload = self.frame(max(0.001, deadline - time.monotonic()))
            assert kind == 4, "unexpected traffic while awaiting workspace event"
            self.event(payload)

    def silent(self, ids, duration=1.1):
        deadline = min(self.deadline, time.monotonic() + duration)
        while True:
            assert not any(event["id"] in ids for event in self.events), "unwatched id delivered an event"
            left = deadline - time.monotonic()
            if left <= 0:
                return
            try:
                kind, payload = self.frame(left)
            except TimeoutError:
                return
            assert kind == 4, "unexpected traffic during quiet watch interval"
            self.event(payload)
