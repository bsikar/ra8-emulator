"""Independent remote binary RPC client covering workspace, build, project, and target wire contracts."""
import json
from pathlib import Path
import struct
import sys
import time
import zlib

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/project_smoke"))
from rpc import Client as ProjectClient, blob, take_blob, workspace_client

ACTION_CODES = {
    "registers": 0,
    "halt": 1,
    "step": 2,
    "resume": 3,
    "flash": 4,
    "reset": 5,
    "uart": 6,
}

workspace_client.METHODS.update(
    run=0x0101,
    read_memory=0x0107,
    subscribe=0x010d,
    now=0x010f,
    targets_list=0x190,
    targets_reserve=0x191,
    targets_release=0x192,
    targets_perform=0x193,
    targets_flash_begin=0x194,
    targets_flash_chunk=0x195,
    targets_flash_commit=0x196,
    targets_flash_receipt=0x197,
)


def pack_selection(sel):
    return (
        blob(sel["host_id"])
        + blob(sel["probe_id"])
        + blob(sel["board_id"])
        + struct.pack("<Q", int(sel["generation"]))
        + blob(sel.get("disambiguation", ""))
    )


class IdeClient(ProjectClient):
    def __init__(self, port, trace, deadline, frame_timeout=30.0):
        self.target_progress = []
        self.uart_bytes = bytearray()
        self.default_frame_timeout = frame_timeout
        super().__init__(port, trace, deadline)

    def frame(self, timeout=None):
        return super().frame(self.default_frame_timeout if timeout is None else timeout)

    def event(self, payload):
        topic, = struct.unpack_from("<H", payload)
        if topic == 0x0100:
            return
        if topic == 0x0101:
            body, end = take_blob(payload, 2)
            assert end == len(payload), "uart envelope"
            _, _, _, length = struct.unpack_from("<BBQI", body)
            chunk = body[14:14 + length]
            assert len(chunk) == length, "uart payload length"
            self.uart_bytes.extend(chunk)
            return
        if topic == 0x183:
            body, end = take_blob(payload, 2)
            assert end == len(payload), "target progress envelope"
            seq, = struct.unpack_from("<Q", body)
            stage_raw, at = take_blob(body, 8)
            json_raw, end = take_blob(body, at)
            assert end == len(body), "target progress body"
            item = dict(
                sequence=seq,
                stage=stage_raw.decode("utf8"),
                data=json.loads(json_raw.decode("utf8")),
            )
            if self.target_progress:
                assert seq > self.target_progress[-1]["sequence"], "monotonic target progress sequence"
            self.target_progress.append(item)
            self.trace(dict(type="target_progress", **item))
            return
        if topic == workspace_client.TOPIC:
            workspace_client.Client.event(self, payload)
            return
        super().event(payload)

    def targets_list(self, error=None):
        body = self.call("targets_list", b"", error)
        if error is not None:
            return None
        raw, end = take_blob(body)
        assert end == len(body)
        return json.loads(raw.decode("utf8"))

    def targets_reserve(self, sel, error=None):
        body = self.call("targets_reserve", pack_selection(sel), error)
        if error is None:
            assert body == b"\x01"

    def targets_release(self, error=None):
        body = self.call("targets_release", b"", error)
        if error is None:
            assert body == b"\x01"

    def targets_perform(self, sel, action, error=None):
        args = pack_selection(sel) + struct.pack("<B", ACTION_CODES[action])
        body = self.call("targets_perform", args, error)
        if error is not None:
            return None
        raw, end = take_blob(body)
        assert end == len(body)
        return json.loads(raw.decode("utf8"))

    def targets_flash_elf(self, sel, elf_bytes, reset=False, uart=False, error=None):
        crc = zlib.crc32(elf_bytes) & 0xFFFFFFFF
        assert self.call("targets_flash_begin", struct.pack("<QI", len(elf_bytes), crc)) == b"\x01"
        for offset in range(0, len(elf_bytes), 65536):
            chunk = elf_bytes[offset:offset + 65536]
            assert self.call("targets_flash_chunk", struct.pack("<Q", offset) + blob(chunk)) == b"\x01"
        args = pack_selection(sel) + struct.pack("<BB", int(bool(reset)), int(bool(uart)))
        body = self.call("targets_flash_commit", args, error)
        if error is not None:
            return None
        raw, end = take_blob(body)
        assert end == len(body)
        return json.loads(raw.decode("utf8"))

    def subscribe_uart(self, core=0):
        assert self.call("subscribe", struct.pack("<BHH", core, 0x0101, 0)) == b"\x01"

    def run_chunk(self, budget=2000, core=0):
        assert self.call("run", struct.pack("<BBQ", core, 1, budget)) == b"\x01"

    def read_memory(self, address, length, core=0):
        body = self.call("read_memory", struct.pack("<BII", core, address, length))
        mlen, = struct.unpack_from("<I", body)
        assert mlen == length and len(body) == 4 + length
        return body[4:4 + length]

    def now(self, core=0):
        body = self.call("now", struct.pack("<B", core))
        return struct.unpack("<Q", body)[0]

    def targets_flash_receipt(self, sel, receipt, reset=False, uart=False, error=None):
        args = pack_selection(sel) + blob(receipt) + struct.pack("<BB", int(bool(reset)), int(bool(uart)))
        body = self.call("targets_flash_receipt", args, error)
        if error is not None:
            return None
        raw, end = take_blob(body)
        assert end == len(body)
        return json.loads(raw.decode("utf8"))
