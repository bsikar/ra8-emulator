#!/usr/bin/env python3
"""Synthetic RA8 RPC peer: reject the real client's hello with another version."""
import struct
import sys
from pathlib import Path


def exact(stream, size):
    data = bytearray()
    while len(data) < size:
        chunk = stream.read(size - len(data))
        if not chunk:
            raise ValueError("truncated RPC frame")
        data.extend(chunk)
    return bytes(data)


def main():
    length, kind = struct.unpack("<IH", exact(sys.stdin.buffer, 6))
    if kind != 1 or length != 10:
        raise ValueError("expected a ten-byte hello")
    magic, version, _ = struct.unpack("<IHI", exact(sys.stdin.buffer, length))
    if magic != 0x52384152:
        raise ValueError("unexpected hello magic")
    payload = struct.pack("<IHI", magic, (version + 1) & 0xFFFF, 0)
    sys.stdout.buffer.write(struct.pack("<IH", len(payload), 1) + payload)
    sys.stdout.buffer.flush()
    # The client must send a version-mismatch fault, not a session request.
    length, kind = struct.unpack("<IH", exact(sys.stdin.buffer, 6))
    if kind != 5 or length != 4:
        raise ValueError("expected a version fault")
    code, _ = struct.unpack("<HH", exact(sys.stdin.buffer, length))
    if code != 4:
        raise ValueError("expected version_mismatch")
    if len(sys.argv) >= 3 and sys.argv[1] == "--receipt":
        with Path(sys.argv[2]).open("a") as receipt:
            receipt.write("version_mismatch fault verified\n")


if __name__ == "__main__":
    main()
