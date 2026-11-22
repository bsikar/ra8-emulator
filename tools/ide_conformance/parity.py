"""Emulate-then-flash parity helpers using public serve RPC and known-state oracles."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess

from rpc_client import IdeClient
import sim_agent

RA4T1_BANNER = (
    "RA8EMU KNOWN-STATE BOOT board=fpb-ra4t1 part=r7fa4t1bb3cfm core=cortex-m33\r\n"
    "RA8EMU KNOWN-STATE END board=fpb-ra4t1 cpuid=410fd214 clk=hoco20m systick=3 led1=1 status=PASS\r\n"
)

BOARD_ORACLES = {
    "fpb-ra8e1": {
        "canonical_part": "ra8e1",
        "alias_part": "fpb-ra8e1",
        "serial": "001083322193",
        "part_num": "R7FA8E1AFDCFB",
        "gdb_device": "R7FA8E1AF",
        "source_file": "fpb_ra8e1.zig",
        "project_cfg": "project_ra8e1.json",
        "uart_wired": True,
        "uart_boundary": None,
        "banner": sim_agent.KNOWN_BANNER,
        "state_addr": 0x2206_0100,
        "expected_state": [
            0x52413845, 0x410FD232, 0x02000000, 0x00000000, 0x00000001,
            0x0000270F, 0x00000003, 0x00000003, 0x00000010, 0x000000AC, 0x00000001,
        ],
    },
    "fpb-ra4t1": {
        "canonical_part": "ra4t1",
        "alias_part": "fpb-ra4t1",
        "serial": "001088957027",
        "part_num": "R7FA4T1BB3CFM",
        "gdb_device": "R7FA4T1BB",
        "source_file": "fpb_ra4t1.zig",
        "project_cfg": "project_ra4t1.json",
        "uart_wired": False,
        "uart_boundary": (
            "FPB-RA4T1 v1 J-Link OB VCOM CDC RX/TX is not wired to RA4T1 P109/P110 "
            "(tests/fixtures/known_state/README.md); SCI9 UART is verified via emulation "
            "and 44-byte StateRecord @ 0x2000_0100 is verified over SWD."
        ),
        "banner": RA4T1_BANNER,
        "state_addr": 0x2000_0100,
        "expected_state": [
            0x52413454, 0x410FD214, 0x00000000, 0x00000000, 0x00000001,
            0x40000147, 0x00000003, 0x00000003, 0x000001C3, 0x000000AC, 0x00000001,
        ],
    },
}


def build_board_once(h, client: IdeClient, board_id: str, ws: Path | None = None) -> dict:
    oracle = BOARD_ORACLES[board_id]
    client.open_project(oracle["project_cfg"])
    client.completed.clear()
    client.outputs.clear()
    client.sequences.clear()
    job = client.build_project("debug")
    res = client.finish(job, timeout=180)
    h.check(f"build {board_id}", res["state"], "succeeded")
    receipt = client.prepare(job)
    rec_obj = json.loads(client.read(receipt)[2])
    sha256 = rec_obj["artifact_sha256"]
    h.check(f"receipt sha match {board_id}", sha256, res["artifact_sha256"])
    elf_path = None
    if ws is not None:
        elf_path = ws / "boards" / rec_obj["artifact"]
        h.check(f"built elf sha {board_id}", hashlib.sha256(elf_path.read_bytes()).hexdigest(), sha256)
    return dict(receipt=receipt, artifact=rec_obj["artifact"], sha256=sha256, elf_path=elf_path)


def capture_rpc_session(client: IdeClient, state_addr: int) -> tuple[str, list[int]]:
    client.uart_bytes.clear()
    client.subscribe_uart()
    for step in range(120):
        client.run_chunk(2000)
        if step >= 25 and step % 10 == 9:
            words = list(struct.unpack("<11I", client.read_memory(state_addr, 44)))
            if words[10] == 1 and len(client.uart_bytes) >= 172:
                break
    client.now()
    words = list(struct.unpack("<11I", client.read_memory(state_addr, 44)))
    return client.uart_bytes.decode("ascii"), words


def _verify_pair(h, label: str, board_id: str, elf_sha256: str, canonical_cap, alias_cap) -> dict:
    oracle = BOARD_ORACLES[board_id]
    c_uart, c_words = canonical_cap
    a_uart, a_words = alias_cap
    h.check(f"{label} canonical uart", (len(c_uart), c_uart), (172, oracle["banner"]))
    h.check(f"{label} canonical state", c_words, oracle["expected_state"])
    h.check(f"{label} alias parity", (a_uart, a_words), (c_uart, c_words))
    return dict(
        board_id=board_id,
        elf_sha256=elf_sha256,
        canonical_part=oracle["canonical_part"],
        alias_part=oracle["alias_part"],
        uart_bytes=len(c_uart),
        uart_sha256=hashlib.sha256(c_uart.encode("ascii")).hexdigest(),
        uart=c_uart,
        state_addr=hex(oracle["state_addr"]),
        state_words=c_words,
        uart_boundary=oracle["uart_boundary"],
    )


def emulate_local(h, tag: str, elf_path: Path, board_id: str) -> dict:
    oracle = BOARD_ORACLES[board_id]
    elf_sha256 = hashlib.sha256(elf_path.read_bytes()).hexdigest()
    caps = []
    for part in (oracle["canonical_part"], oracle["alias_part"]):
        srv = h.spawn([h.emulator, "serve", "--part", part, "--history", "off", "--listen", "tcp::0", elf_path],
                      "serve: listening on tcp:", f"{tag}_{part}", f"{tag}_{part}.serve.log", port_from_ready=True)
        client = IdeClient(srv.port, h.trace, h.deadline, frame_timeout=30.0)
        try:
            caps.append(capture_rpc_session(client, oracle["state_addr"]))
        finally:
            client.close()
            srv.close()
    return _verify_pair(h, tag, board_id, elf_sha256, caps[0], caps[1])


def run_sim_parity(h, write_targets_fn, sim_boards, served_client_fn, find_fn, sel_fn):
    import secrets
    import workspace_setup

    ws = h.output / "parity_ws"
    secret = h.output / "parity_sim.key"
    key_hex = secrets.token_hex(32)
    workspace_setup.populate(ws)
    secret.write_text(key_hex + "\n", encoding="utf8")
    sim = sim_agent.SimProbeAgent("parity-sim-host", key_hex, h.trace)
    tgt = h.output / "parity_targets.json"
    write_targets_fn(tgt, "agent", "parity-sim-host", boards=sim_boards, host="127.0.0.1", port=sim.port,
                     secret_file=str(secret.resolve()))
    h.require("unknown --part refused", h.run_cli([h.emulator, "--part", "unknown-part", h.fixture]).returncode != 0)
    try:
        with served_client_fn(h, "parity_sim", tgt, ws) as (_, client):
            listed = client.targets_list()
            t8, t4 = find_fn(listed, "fpb-ra8e1"), find_fn(listed, "fpb-ra4t1")
            b8 = build_board_once(h, client, "fpb-ra8e1", ws)
            e8 = emulate_local(h, "sim_emu_e1", b8["elf_path"], "fpb-ra8e1")
            client.targets_reserve(sel_fn(t8))
            f8 = client.targets_flash_receipt(sel_fn(t8), b8["receipt"], reset=True, uart=True)
            client.targets_release()
            client.close_project()
            h.check("sim ra8e1 hash/uart", (f8["flash"]["sha256"], f8["uart"]["text"]), (e8["elf_sha256"], e8["uart"]))

            b4 = build_board_once(h, client, "fpb-ra4t1", ws)
            e4 = emulate_local(h, "sim_emu_t1", b4["elf_path"], "fpb-ra4t1")
            client.targets_reserve(sel_fn(t4))
            f4 = client.targets_flash_receipt(sel_fn(t4), b4["receipt"], reset=True, uart=False)
            h.check("sim ra4t1 hash", f4["flash"]["sha256"], e4["elf_sha256"])
            client.targets_perform(sel_fn(t4), "uart", error=0x195)
            client.targets_release()
            client.close_project()
            h.results["emulate_then_flash_sim"] = {
                "ra8e1": dict(sha256=e8["elf_sha256"], uart_bytes=e8["uart_bytes"], state_words=e8["state_words"]),
                "ra4t1": dict(sha256=e4["elf_sha256"], uart_bytes=e4["uart_bytes"], state_words=e4["state_words"],
                              boundary=e4["uart_boundary"]),
            }
    finally:
        sim.close()


def emulate_remote(h, ssh_base: list[str], remote_emu: str, remote_elf: str, elf_sha256: str,
                   board_id: str, ssh_tunnel_cls, free_port_fn, tag: str) -> dict:
    oracle = BOARD_ORACLES[board_id]
    caps = []
    for part in (oracle["canonical_part"], oracle["alias_part"]):
        cmd = f"echo PID:$$; exec {remote_emu} serve --part {part} --history off --listen tcp:127.0.0.1:0 {remote_elf}"
        srv = h.spawn([*ssh_base, cmd], "serve: listening on tcp:", f"{tag}_{part}",
                      f"{tag}_{part}.serve.log", port_from_ready=True)
        remote_pid = next(int(ln.split(":", 1)[1]) for ln in srv.lines if ln.startswith("PID:"))
        local_port = free_port_fn()
        tun = ssh_tunnel_cls(h, ssh_base[-1], ["-L", f"127.0.0.1:{local_port}:127.0.0.1:{srv.port}"],
                             f"Local forwarding listening on 127.0.0.1 port {local_port}.", f"{tag}_{part}_tun")
        client = IdeClient(local_port, h.trace, h.deadline, frame_timeout=45.0)
        try:
            caps.append(capture_rpc_session(client, oracle["state_addr"]))
        finally:
            client.close()
            tun.close()
            if srv.proc.poll() is None:
                try:
                    subprocess.run(ssh_base + [f"kill -TERM {remote_pid}"], stdin=subprocess.DEVNULL, timeout=25)
                except subprocess.TimeoutExpired:
                    pass
            srv.close()
    return _verify_pair(h, tag, board_id, elf_sha256, caps[0], caps[1])


def compare_hw_state(h, tag: str, board_id: str, emu_words: list[int], hw_words: list[int]) -> dict:
    h.require(f"{tag} len", len(hw_words) == len(emu_words) == 11)
    if board_id != "fpb-ra4t1" or hw_words == emu_words:
        h.check(f"{tag} StateRecord parity", hw_words, emu_words)
        return dict(state_match=True, exact_match=True, state_words=hw_words)
    # RA4T1 live board reads P201/P206 strap pins low (0x0181) vs modeled pull-ups (0x01c3).
    h.check(f"{tag} non-strap words", hw_words[:8] + hw_words[9:], emu_words[:8] + emu_words[9:])
    delta = hw_words[8] ^ emu_words[8]
    h.require(f"{tag} PORT2 LED1 (P207) active", (hw_words[8] & 0x0080) == 0x0080)
    h.require(f"{tag} PORT2 diff strictly external straps P201/P206 (0x0042)", (delta & ~0x0042) == 0)
    note = (
        f"PORT2.PIDR word[8]: hw=0x{hw_words[8]:04x} vs emu=0x{emu_words[8]:04x} "
        f"(delta=0x{delta:04x}: external board strap inputs P201/P206; "
        f"P207 LED1=1 and 10/10 non-strap words match)"
    )
    return dict(
        state_match=True,
        exact_match=False,
        state_words=hw_words,
        emu_state_words=emu_words,
        port2_pidr_delta=note,
    )
