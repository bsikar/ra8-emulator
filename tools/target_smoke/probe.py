"""A bounded, loopback-only RSP register provider that records which device was contacted."""
import socket
import threading


class Probe:
    def __init__(self, name):
        self.name, self.calls, self.errors = name, [], []
        self.done = threading.Event()
        self.socket = socket.socket()
        self.socket.bind(("127.0.0.1", 0))
        self.socket.listen(4)
        self.socket.settimeout(0.1)
        self.port = self.socket.getsockname()[1]
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.done.is_set():
            try:
                peer, _ = self.socket.accept()
            except socket.timeout:
                continue
            except OSError as error:
                if not self.done.is_set():
                    self.errors.append(str(error))
                return
            with peer:
                peer.settimeout(3)
                try:
                    data = bytearray()
                    while len(data) < 5:
                        chunk = peer.recv(5 - len(data))
                        if not chunk:
                            raise EOFError("provider request truncated")
                        data.extend(chunk)
                    assert data == b"$g#67", data
                    self.calls.append(bytes(data).decode("ascii"))
                    body = b"01020304"
                    peer.sendall(b"$" + body + b"#" + f"{sum(body) % 256:02x}".encode("ascii"))
                    assert peer.recv(1) == b"+", "provider response acknowledgement"
                except Exception as error:
                    self.errors.append(repr(error))

    def close(self):
        self.done.set()
        self.socket.close()
        self.thread.join(timeout=4)
        assert not self.thread.is_alive() and not self.errors, self.errors

    def binding(self, managed=False):
        return dict(kind="rsp", host="127.0.0.1", port=self.port, target=dict(
            host_id="fixture-host", probe_id="probe-" + self.name, board_id="board-" + self.name,
            model="same-model-fixture", transport="rsp", managed=managed,
            disambiguation="binding-" + self.name))
