"""Independent DAP Content-Length client using only the Python standard library."""
import json
import socket
import time


class Client:
    def __init__(self, port, case, request_timeout, deadline):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=request_timeout)
        self.case = case
        self.timeout = request_timeout
        self.deadline = deadline
        self.buffer = bytearray()
        self.next_seq = 1
        self.last_server_seq = 0
        self.pending = {}
        self.responses = {}
        self.events = []

    def close(self):
        self.socket.close()

    def timeout_at(self, until=None):
        left = min(self.timeout, self.deadline - time.monotonic())
        if until is not None:
            left = min(left, until - time.monotonic())
        if left <= 0:
            raise TimeoutError("DAP deadline expired")
        self.socket.settimeout(left)

    def packet(self, command, arguments=None):
        seq = self.next_seq
        self.next_seq += 1
        message = {"seq": seq, "type": "request", "command": command}
        if arguments is not None:
            message["arguments"] = arguments
        body = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.pending[seq] = command
        self.case.record("client", message=message)
        return seq, f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body

    def send(self, command, arguments=None, fragment=0):
        seq, packet = self.packet(command, arguments)
        self.timeout_at()
        if fragment:
            for at in range(0, len(packet), fragment):
                self.socket.sendall(packet[at:at + fragment])
        else:
            self.socket.sendall(packet)
        return seq

    def coalesced(self, requests):
        packets = [self.packet(command, args) for command, args in requests]
        self.timeout_at()
        self.socket.sendall(b"".join(packet for _, packet in packets))
        return [seq for seq, _ in packets]

    def receive(self, until=None):
        self.timeout_at(until)
        while b"\r\n\r\n" not in self.buffer:
            self._read(until)
            if len(self.buffer) > 1024 * 1024:
                raise AssertionError("response header exceeds the independent client bound")
        header, _, rest = bytes(self.buffer).partition(b"\r\n\r\n")
        lengths = [line.split(b":", 1)[1].strip() for line in header.split(b"\r\n") if line.lower().startswith(b"content-length:")]
        if len(lengths) != 1:
            raise AssertionError(f"response has {len(lengths)} Content-Length headers")
        size = int(lengths[0])
        if not 0 < size <= 1024 * 1024:
            raise AssertionError(f"response body length outside client bound: {size}")
        self.buffer[:] = rest
        while len(self.buffer) < size:
            self._read(until)
        message = json.loads(bytes(self.buffer[:size]).decode("utf-8"))
        del self.buffer[:size]
        self.case.record("server", message=message)
        self.case.equal("server sequence is contiguous", self.last_server_seq + 1, message.get("seq"))
        self.last_server_seq += 1
        self._route(message)
        return message

    def _read(self, until):
        self.timeout_at(until)
        chunk = self.socket.recv(65536)
        if not chunk:
            raise EOFError("adapter closed the connection")
        self.buffer.extend(chunk)

    def _route(self, message):
        kind = message.get("type")
        if kind == "event":
            self.events.append(message)
            return
        if kind != "response":
            raise AssertionError(f"unexpected server message type {kind!r}")
        seq = message.get("request_seq")
        command = self.pending.pop(seq, None)
        self.case.require("response correlates to an outstanding request", command is not None, message)
        self.case.equal("response command matches request", command, message.get("command"))
        self.case.require("response success is boolean", type(message.get("success")) is bool)
        self.responses[seq] = message

    def response(self, seq, success=True):
        until = min(self.deadline, time.monotonic() + self.timeout)
        while seq not in self.responses:
            self.receive(until)
        message = self.responses.pop(seq)
        self.case.equal("request success", success, message["success"])
        return message

    def request(self, command, arguments=None, success=True, fragment=0):
        return self.response(self.send(command, arguments, fragment), success)

    def event(self, name, timeout=None):
        until = min(self.deadline, time.monotonic() + (timeout or self.timeout))
        while True:
            for index, message in enumerate(self.events):
                if message.get("event") == name:
                    return self.events.pop(index)
            self.receive(until)

    def expect_eof(self):
        self.timeout_at()
        try:
            chunk = self.socket.recv(1)
        except ConnectionResetError:
            chunk = b""
        self.case.equal("malformed connection is closed", 0, len(chunk))
