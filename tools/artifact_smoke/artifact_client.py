"""Artifact extension encoded independently of the Zig codec."""
import hashlib
from pathlib import Path
import socket
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "workspace_smoke"))
import client as protocol
from websocket import Socket

protocol.METHODS.update(export_begin=0x180, export_read=0x181, import_begin=0x182,
                        import_write=0x183, import_end=0x184, abort=0x185,
                        read_register=0x105, write_register=0x106)
blob, take_blob = protocol.blob, protocol.take_blob


class Client(protocol.Client):
    def __init__(self, port, trace, deadline, websocket=False):
        self.socket = Socket(port) if websocket else socket.create_connection(("127.0.0.1", port), timeout=5)
        self.trace, self.deadline = trace, deadline
        self.buffer, self.events, self.next_id = bytearray(), [], 0
        self.send(1, struct.pack("<IHI", 0x52384152, 1, 0), fragmented=True)
        kind, payload = self.frame()
        assert kind == 1
        magic, version, self.caps = struct.unpack("<IHI", payload)
        assert magic == 0x52384152 and version == 1

    def frame(self, timeout=60):
        return super().frame(timeout)

    def register(self, value=None):
        if value is not None:
            assert self.call("write_register", struct.pack("<BBI", 0, 3, value)) == b"\x01"
        result = self.call("read_register", b"\x00\x03")
        assert len(result) == 4
        return struct.unpack("<I", result)[0]

    def download(self, recording=True):
        result = self.call("export_begin", bytes([recording]))
        identity, total = struct.unpack_from("<QQ", result)
        expected, end = take_blob(result, 16)
        assert end == len(result) and len(expected) == 32 and 0 < total <= 4 * 1024**3
        data = bytearray()
        while len(data) < total:
            response = self.call("export_read", struct.pack("<QQI", identity, len(data), 65536))
            received_id, offset = struct.unpack_from("<QQ", response)
            chunk, end = take_blob(response, 16)
            assert received_id == identity and offset == len(data) and end == len(response)
            assert 0 < len(chunk) <= min(65536, total - len(data))
            data.extend(chunk)
        assert hashlib.sha256(data).digest() == expected
        assert self.call("abort", struct.pack("<Q", identity)) == b"\x01"
        return bytes(data)

    def upload(self, data, digest=None, error=None):
        digest = hashlib.sha256(data).digest() if digest is None else digest
        result = self.call("import_begin", struct.pack("<Q", len(data)) + blob(digest))
        identity, = struct.unpack("<Q", result)
        for offset in range(0, len(data), 65536):
            assert self.call("import_write", struct.pack("<QQ", identity, offset) +
                             blob(data[offset:offset + 65536])) == b"\x01"
        result = self.call("import_end", struct.pack("<Q", identity), error)
        if error is None:
            assert result == b"\x01\x01"
