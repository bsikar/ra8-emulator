"""A malformed peer must not leave a partially written download behind."""
import socket
import struct
import subprocess
import threading


def exact(peer, size):
    data = bytearray()
    while len(data) < size:
        chunk = peer.recv(size - len(data))
        if not chunk:
            raise EOFError("download client closed")
        data.extend(chunk)
    return bytes(data)


def frame(peer):
    size, kind = struct.unpack("<IH", exact(peer, 6))
    assert size <= 1_048_590
    return kind, exact(peer, size)


def send(peer, kind, payload):
    peer.sendall(struct.pack("<IH", len(payload), kind) + payload)


def faulty_download(emulator, output):
    errors = []
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(10)
        port = listener.getsockname()[1]

        def serve():
            try:
                peer, _ = listener.accept()
                with peer:
                    peer.settimeout(10)
                    kind, hello = frame(peer)
                    assert kind == 1
                    send(peer, 1, hello)
                    kind, request = frame(peer)
                    identity, method = struct.unpack_from("<IH", request)
                    assert kind == 2 and method == 0x180
                    descriptor = struct.pack("<QQI", 1, 3, 32) + bytes(32)
                    send(peer, 3, struct.pack("<IBI", identity, 0, len(descriptor)) + descriptor)
                    kind, request = frame(peer)
                    identity, method = struct.unpack_from("<IH", request)
                    assert kind == 2 and method == 0x181
                    # A wrong offset fails after the CLI has created its temporary file.
                    chunk = struct.pack("<QQI", 1, 99, 3) + b"bad"
                    send(peer, 3, struct.pack("<IBI", identity, 0, len(chunk)) + chunk)
            except Exception as error:
                errors.append(error)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        try:
            result = subprocess.run([str(emulator), "export-session", "--connect",
                                     f"tcp:127.0.0.1:{port}", str(output / "invalid.tar")],
                                    capture_output=True, timeout=30)
            assert result.returncode == 1, result.stderr
        finally:
            thread.join(timeout=10)
        assert not thread.is_alive() and not errors, errors
    assert not (output / "invalid.tar").exists()
    assert not list(output.glob("*.partial")), "failed download removed its temporary file"
