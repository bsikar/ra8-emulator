"""Reproducible RA8PH2 probe-host protocol fixture supporting verified ELF flash, reset, and UART."""
import hashlib
import hmac
import json
import os
import socket
import struct
import threading

KNOWN_BANNER = (
    "RA8EMU KNOWN-STATE BOOT board=fpb-ra8e1 part=r7fa8e1afdcfb core=cortex-m85\r\n"
    "RA8EMU KNOWN-STATE END board=fpb-ra8e1 cpuid=410fd232 clk=hoco48m systick=3 led1=1 status=PASS\r\n"
)


def ph2_mac(key: bytes, role: str, host_id: str, client_nonce: bytes, agent_nonce: bytes) -> bytes:
    h = hmac.new(key, digestmod=hashlib.sha256)
    h.update(b"RA8PH2:")
    h.update(role.encode("ascii"))
    h.update(b":")
    h.update(host_id.encode("ascii"))
    h.update(b":")
    h.update(client_nonce)
    h.update(agent_nonce)
    return h.digest()


def frame_mac(key: bytes, seq: int, payload: bytes) -> bytes:
    h = hmac.new(key, digestmod=hashlib.sha256)
    h.update(b"RA8PH2:frame:")
    h.update(struct.pack("<Q", seq))
    h.update(payload)
    return h.digest()


def check_arm_elf_window(elf: bytes, base: int, size: int):
    if len(elf) < 52 or elf[:4] != b"\x7fELF":
        return "NotElf"
    if elf[4] != 1 or elf[5] != 1:
        return "InvalidElf"
    etype, emachine = struct.unpack_from("<HH", elf, 16)
    if etype != 2 or emachine != 40:
        return "UnsupportedElfTarget"
    e_phoff, = struct.unpack_from("<I", elf, 28)
    e_phentsize, e_phnum = struct.unpack_from("<HH", elf, 42)
    if e_phentsize < 32 or e_phnum == 0:
        return "EmptyLoadImage"
    segments, total = 0, 0
    for idx in range(e_phnum):
        off = e_phoff + idx * e_phentsize
        if off + 32 > len(elf):
            return "InvalidElf"
        p_type, p_offset, _, p_paddr, p_filesz, _ = struct.unpack_from("<IIIIII", elf, off)
        if p_type != 1 or p_filesz == 0:
            continue
        if p_offset + p_filesz > len(elf):
            return "InvalidElf"
        if p_paddr < base or p_paddr + p_filesz > base + size:
            return "AddressOutOfRange"
        segments += 1
        total += p_filesz
    if segments == 0:
        return "EmptyLoadImage"
    return (segments, total)


class SimProbeAgent:
    def __init__(self, host_id: str, secret_hex: str, trace):
        self.host_id = host_id
        self.key = bytes.fromhex(secret_hex.strip())
        self.trace = trace
        self.done = threading.Event()
        self.lock = threading.Lock()
        self.connected = {"fpb-ra8e1": True, "fpb-ra4t1": True}
        self.flashed_counts = {"fpb-ra8e1": 0, "fpb-ra4t1": 0}
        self.reserved_by = {}
        self.next_token = 0
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.sock.settimeout(0.1)
        self.port = self.sock.getsockname()[1]
        self.peers = []
        self.thread = threading.Thread(target=self._accept_loop, daemon=True)
        self.thread.start()

    def set_connected(self, board_id: str, value: bool):
        with self.lock:
            self.connected[board_id] = value
            if not value:
                self.reserved_by.pop(board_id, None)

    def close(self):
        self.done.set()
        try:
            self.sock.close()
        except OSError:
            pass
        for conn in list(self.peers):
            try:
                conn.close()
            except OSError:
                pass
        self.thread.join(timeout=5)

    def _accept_loop(self):
        while not self.done.is_set():
            try:
                conn, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.peers.append(conn)
            threading.Thread(target=self._serve_peer, args=(conn,), daemon=True).start()

    def _recv_line(self, conn: socket.socket, buf: bytearray, limit: int = 65536) -> bytes:
        while not self.done.is_set():
            nl = buf.find(b"\n")
            if nl >= 0:
                line = bytes(buf[:nl + 1])
                del buf[:nl + 1]
                return line
            if len(buf) >= limit:
                raise ValueError("line exceeds limit")
            try:
                chunk = conn.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                return b""
            buf.extend(chunk)
        return b""

    def _serve_peer(self, conn: socket.socket):
        conn.settimeout(0.5)
        owner_id = id(conn)
        token = 0
        stage_buf = None
        stage_sha = ""
        rx_buf = bytearray()
        try:
            hello = self._recv_line(conn, rx_buf, 512).decode("ascii").strip().split(" ")
            if len(hello) != 4 or hello[:3] != ["RA8PH2", "client", self.host_id]:
                return
            c_nonce = bytes.fromhex(hello[3])
            a_nonce = os.urandom(32)
            proof = ph2_mac(self.key, "agent", self.host_id, c_nonce, a_nonce)
            conn.sendall(f"RA8PH2 agent {self.host_id} {a_nonce.hex()} {proof.hex()}\n".encode("ascii"))
            verify = self._recv_line(conn, rx_buf, 512).decode("ascii").strip().split(" ")
            expected = ph2_mac(self.key, "client", self.host_id, c_nonce, a_nonce)
            if len(verify) != 3 or verify[:2] != ["RA8PH2", "verify"] or not hmac.compare_digest(bytes.fromhex(verify[2]), expected):
                return
            conn.sendall(b"RA8PH2 ready\n")
            tx_key = ph2_mac(self.key, "a2c", self.host_id, c_nonce, a_nonce)
            rx_key = ph2_mac(self.key, "c2a", self.host_id, c_nonce, a_nonce)
            tx_seq, rx_seq = 0, 0

            def send_reply(obj):
                nonlocal tx_seq
                tx_seq += 1
                payload = json.dumps(obj, separators=(",", ":")).encode("utf8")
                tag = frame_mac(tx_key, tx_seq, payload)
                conn.sendall(f"{tx_seq} {tag.hex()} ".encode("ascii") + payload + b"\n")

            while not self.done.is_set():
                line = self._recv_line(conn, rx_buf, 65536)
                if not line:
                    return
                parts = line.rstrip(b"\r\n").split(b" ", 2)
                if len(parts) != 3:
                    return
                rx_seq += 1
                if int(parts[0]) != rx_seq:
                    return
                if not hmac.compare_digest(bytes.fromhex(parts[1].decode("ascii")), frame_mac(rx_key, rx_seq, parts[2])):
                    return
                req = json.loads(parts[2].decode("utf8"))
                op = req["op"]
                if op == "list":
                    send_reply(dict(ok=True, targets=self._snapshots()))
                elif op == "claim":
                    with self.lock:
                        board = req["board_id"]
                        if not self.connected.get(board, False):
                            send_reply(dict(ok=False, err="Disconnected"))
                        elif board in self.reserved_by:
                            send_reply(dict(ok=False, err="TargetBusy"))
                        else:
                            self.next_token += 1
                            token = self.next_token
                            self.reserved_by[board] = owner_id
                            send_reply(dict(ok=True, token=token))
                elif op == "release":
                    if token == 0 or req.get("token") != token:
                        send_reply(dict(ok=False, err="StaleLease"))
                    else:
                        with self.lock:
                            for k, v in list(self.reserved_by.items()):
                                if v == owner_id:
                                    self.reserved_by.pop(k, None)
                        token = 0
                        stage_buf = None
                        send_reply(dict(ok=True))
                elif op == "flash_begin":
                    if token == 0 or req.get("token") != token:
                        send_reply(dict(ok=False, err="StaleLease"))
                    else:
                        stage_buf = bytearray(req["total_len"])
                        stage_sha = req["sha256"]
                        send_reply(dict(ok=True))
                elif op == "flash_chunk":
                    if token == 0 or req.get("token") != token or stage_buf is None:
                        send_reply(dict(ok=False, err="StaleLease"))
                    else:
                        raw = bytes.fromhex(req["hex"])
                        off = req["offset"]
                        stage_buf[off:off + len(raw)] = raw
                        send_reply(dict(ok=True))
                elif op == "flash_commit":
                    send_reply(dict(ok=True, chunk=True, stream="flash:program_verify"))
                    send_reply(self._commit_flash(req, token, stage_buf, stage_sha))
                    stage_buf = None
                elif op == "perform":
                    send_reply(dict(ok=True, chunk=True, stream=req["action"]))
                    send_reply(self._perform(req, token))
        except Exception:
            pass
        finally:
            with self.lock:
                for k, v in list(self.reserved_by.items()):
                    if v == owner_id:
                        self.reserved_by.pop(k, None)
            try:
                conn.close()
            except OSError:
                pass

    def _snapshots(self):
        with self.lock:
            e1_conn = self.connected["fpb-ra8e1"]
            t1_conn = self.connected["fpb-ra4t1"]
        return [
            dict(
                probe_id="sim-jlink-ra8e1",
                board_id="fpb-ra8e1",
                probe_serial="001083322193",
                vendor="Renesas",
                model="FPB-RA8E1",
                cores="Cortex-M85 r0p2",
                transport="jlink-usb",
                connected=e1_conn,
                uart="SIM-CDC-RA8E1" if e1_conn else "",
                identity_verified=True,
                managed=False,
                operations=["registers", "halt", "step", "resume", "flash", "reset", "uart"],
                capabilities=dict(build=False, flash=True, hardware_debug=True, emulation=False, npu=False, uart=True),
            ),
            dict(
                probe_id="sim-jlink-ra4t1",
                board_id="fpb-ra4t1",
                probe_serial="001088957027",
                vendor="Renesas",
                model="FPB-RA4T1",
                cores="Cortex-M33 r0p4",
                transport="jlink-usb",
                connected=t1_conn,
                uart="",
                identity_verified=True,
                managed=False,
                operations=["registers", "halt", "step", "resume", "flash", "reset"],
                capabilities=dict(build=False, flash=True, hardware_debug=True, emulation=False, npu=False, uart=False),
            ),
        ]

    def _commit_flash(self, req, token, stage_buf, stage_sha):
        if token == 0 or req.get("token") != token or stage_buf is None:
            return dict(ok=False, err="StaleLease")
        digest = hashlib.sha256(stage_buf).hexdigest()
        if digest != stage_sha.lower():
            return dict(ok=False, err="BadChecksum")
        board = req["board_id"]
        with self.lock:
            if not self.connected.get(board, False):
                return dict(ok=False, err="Disconnected")
        win = (0x02000000, 0x00100000) if board == "fpb-ra8e1" else (0x00000000, 0x00040000)
        checked = check_arm_elf_window(bytes(stage_buf), *win)
        if isinstance(checked, str):
            return dict(ok=False, err=checked)
        segments, total = checked
        with self.lock:
            if not self.connected.get(board, False):
                return dict(ok=False, err="Disconnected")
            self.flashed_counts[board] += 1
        meta = ("001083322193", "0x410FD232", "R7FA8E1AFDCFB") if board == "fpb-ra8e1" else ("001088957027", "0x410FD214", "R7FA4T1BB3CFM")
        body = dict(flashed=True, verified=True, serial=meta[0], cpuid=meta[1], part=meta[2],
                    sha256=digest, segments=segments, bytes=total, lease=token)
        return dict(ok=True, json=json.dumps(body))

    def _perform(self, req, token):
        if token == 0 or req.get("token") != token:
            return dict(ok=False, err="StaleLease")
        board, action = req["board_id"], req["action"]
        with self.lock:
            if not self.connected.get(board, False):
                return dict(ok=False, err="Disconnected")
        meta = ("001083322193", "0x410FD232", "R7FA8E1AFDCFB", 0x02000100, 0x22070000) if board == "fpb-ra8e1" else (
            "001088957027", "0x410FD214", "R7FA4T1BB3CFM", 0x00000100, 0x20004000)
        if action == "uart":
            if board != "fpb-ra8e1":
                return dict(ok=False, err="Unsupported")
            return dict(ok=True, json=json.dumps(dict(
                serial=meta[0], cpuid=meta[1], part=meta[2], uart="SIM-CDC-RA8E1",
                bytes=len(KNOWN_BANNER), text=KNOWN_BANNER, lease=token)))
        if action == "reset":
            return dict(ok=True, json=json.dumps(dict(reset=True, serial=meta[0], cpuid=meta[1], part=meta[2], lease=token)))
        if action == "halt":
            return dict(ok=True, json=json.dumps(dict(halted=True, serial=meta[0], cpuid=meta[1], part=meta[2], pc=meta[3], sp=meta[4], lease=token)))
        if action == "registers":
            return dict(ok=True, json=json.dumps(dict(serial=meta[0], cpuid=meta[1], part=meta[2], pc=meta[3], sp=meta[4], lease=token)))
        if action == "step":
            return dict(ok=True, json=json.dumps(dict(stepped=True, serial=meta[0], cpuid=meta[1], part=meta[2], pc=meta[3] + 2, sp=meta[4], lease=token)))
        if action == "resume":
            return dict(ok=True, json=json.dumps(dict(resumed=True, serial=meta[0], cpuid=meta[1], part=meta[2], lease=token)))
        return dict(ok=False, err="Unsupported")
