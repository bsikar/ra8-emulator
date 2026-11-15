"""Small independent RFC6455 binary stream for the artifact RPC acceptance test."""
import base64
import hashlib
import os
import socket
import struct


class Socket:
    def __init__(self, port):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.buffer = bytearray()
        key = base64.b64encode(os.urandom(16))
        self.socket.sendall(b"GET /rpc HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                            b"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                            b"Sec-WebSocket-Key: " + key + b"\r\nOrigin: http://localhost\r\n\r\n")
        headers = bytearray()
        while not headers.endswith(b"\r\n\r\n"):
            byte = self.socket.recv(1)
            if not byte or len(headers) > 8192:
                raise EOFError("WebSocket upgrade failed")
            headers.extend(byte)
        expected = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        assert headers.startswith(b"HTTP/1.1 101 ") and expected in headers

    def close(self):
        self.socket.close()

    def settimeout(self, value):
        self.socket.settimeout(value)

    def sendall(self, data):
        mask = os.urandom(4)
        size = len(data)
        length = bytes([size | 128]) if size < 126 else (
            b"\xfe" + struct.pack("!H", size) if size <= 65535 else b"\xff" + struct.pack("!Q", size))
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
        self.socket.sendall(b"\x82" + length + mask + masked)

    def exact(self, size):
        result = bytearray()
        while len(result) < size:
            chunk = self.socket.recv(size - len(result))
            if not chunk:
                raise EOFError("WebSocket closed")
            result.extend(chunk)
        return bytes(result)

    def recv(self, size):
        while not self.buffer:
            first, second = self.exact(2)
            assert first == 0x82 and not second & 128, "unmasked final binary response"
            length = second & 127
            if length == 126:
                length, = struct.unpack("!H", self.exact(2))
            elif length == 127:
                length, = struct.unpack("!Q", self.exact(8))
            assert length <= 1_048_600
            self.buffer.extend(self.exact(length))
        chunk = bytes(self.buffer[:size])
        del self.buffer[:size]
        return chunk
