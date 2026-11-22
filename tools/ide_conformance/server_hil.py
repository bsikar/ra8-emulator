"""Server-attached-probe HIL verification over SSH against macOS server host."""
import json
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess

import gdb_debug
import hil
import parity
from rpc_client import IdeClient
import workspace_setup

SAFE_GUARD_PATTERN = "5B42058357"


def _write_remote_json(ssh_base: list[str], remote_path: str, payload):
    raw = json.dumps(payload, indent=2).encode("utf8")
    subprocess.run(ssh_base + [f"cat > {remote_path}"], input=raw, check=True, timeout=15)


def _free_remote_port(ssh_base: list[str]) -> int:
    return int(subprocess.check_output(
        ssh_base + ["python3 -c 'import socket; s=socket.socket(); s.bind((\"127.0.0.1\",0)); print(s.getsockname()[1]); s.close()'"],
        text=True, timeout=15).strip())


def _stat_unrelated_device(ssh_base: list[str]) -> str:
    cmd = ("if [ -e /dev/cu.usbmodem5B420583571 ]; then ls -l /dev/cu.usbmodem5B420583571 && "
           "/usr/bin/stat -f '%r %z' /dev/cu.usbmodem5B420583571; else echo ABSENT; fi")
    return subprocess.check_output(ssh_base + [cmd], stdin=subprocess.DEVNULL, text=True, timeout=15).strip()


def _assert_unrelated_untouched(h, ssh_base: list[str], before: str):
    h.check("unrelated device 5B420583571 unchanged", _stat_unrelated_device(ssh_base), before)
    for log_file in sorted(h.output.glob("*.log")):
        h.require(f"log {log_file.name} untouched 5B42058357",
                  SAFE_GUARD_PATTERN not in log_file.read_text(encoding="utf8", errors="replace"))


def _stage_neo(h, ssh_base: list[str], remote_dir: str) -> str:
    subprocess.run(ssh_base + [f"mkdir -p {remote_dir}/repo {remote_dir}/scratch && tar -xzf - -C {remote_dir}/repo"],
                   input=hil._repo_tar_bytes(), check=True, timeout=90)
    z = shlex.quote(h.args.probe_remote_zig)
    if not h.args.probe_remote_emulator:
        subprocess.run(ssh_base + [f"cd {remote_dir}/repo && {z} build -j1"],
                       check=True, capture_output=True, text=True, timeout=300)
    remote_emu = h.args.probe_remote_emulator or f"{remote_dir}/repo/zig-out/bin/ra8_emulator"
    subprocess.run(ssh_base + [f"cd {remote_dir}/repo && {z} build ra8_host_tests -j1 -Dtest-filter=host.jlink"],
                   check=True, capture_output=True, text=True, timeout=240)
    subprocess.run(ssh_base + [
        f"python3 -c \"import sys; from pathlib import Path; sys.path.insert(0, '{remote_dir}/repo/tools/ide_conformance'); "
        f"import workspace_setup; workspace_setup.populate(Path('{remote_dir}/ws'))\""
    ], check=True, timeout=30)
    return remote_emu


def _verify_neo_targets(h, listed, expected_host_id: str):
    h.require("no target entry touches 5B42058357", SAFE_GUARD_PATTERN not in json.dumps(listed))
    e1, t1 = hil._find(listed, "fpb-ra8e1", "001083322193"), hil._find(listed, "fpb-ra4t1", "001088957027")
    for name, item in (("ra8e1", e1), ("ra4t1", t1)):
        h.check(f"neo {name} host_id/state", (item["target"]["host_id"], item["target"]["connection"],
                                             item["target"]["identity_verified"]), (expected_host_id, "connected", True))
    h.check("neo ra8e1 macOS CDC callout", e1["target"]["uart"], "/dev/cu.usbmodem0010833221931")
    h.check("neo ra4t1 VCOM unsupported", (t1["target"]["capabilities"]["uart"],
            "uart" in t1["target"]["operations"], t1["target"]["uart"]), (False, False, "/dev/cu.usbmodem0010889570271"))
    return e1, t1


def _run_remote_jlink_gdb(h, ssh_base: list[str], remote_dir: str, elf_rel: str, board_id: str,
                          emu_words: list[int], tag: str) -> dict:
    oracle = parity.BOARD_ORACLES[board_id]
    port = _free_remote_port(ssh_base)
    srv_cmd = (
        f"echo PID:$$; exec {shlex.quote(h.args.probe_remote_jlink_gdb_server)} "
        f"-select USB={oracle['serial']} -device {oracle['gdb_device']} -if SWD -speed 1000 "
        f"-noir -LocalhostOnly 1 -noreset -singlerun -port {port}"
    )
    srv = h.spawn([*ssh_base, srv_cmd], "Connected to target",
                  f"neo_gdb_{tag}", f"neo_gdb_{tag}.server.log")
    remote_elf = f"{remote_dir}/ws/boards/{elf_rel}"
    cmds = [
        "set pagination off", "set confirm off", "set remotetimeout 10",
        f"target remote 127.0.0.1:{port}",
        'printf "HW_STATE_BEGIN\\n"', f"x/11wx {hex(oracle['state_addr'])}", 'printf "HW_STATE_END\\n"',
        "info line Reset_Handler", "hbreak Reset_Handler", "monitor reset", "continue",
        'printf "HW_BREAK_PC=0x%x\\n", $pc', "stepi", 'printf "HW_STEP_PC=0x%x\\n", $pc',
        "delete", "monitor reset", "monitor go", "disconnect", "quit",
    ]
    remote_pid = next(int(ln.split(":", 1)[1]) for ln in srv.lines if ln.startswith("PID:"))
    try:
        script_path = f"{remote_dir}/hw_{tag}.gdb"
        subprocess.run(ssh_base + [f"cat > {script_path}"], input=("\n".join(cmds) + "\n").encode("utf8"), check=True, timeout=15)
        res = subprocess.run(
            ssh_base + [f"{shlex.quote(h.args.probe_remote_gdb)} -batch -nx {shlex.quote(remote_elf)} -x {script_path}"],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, encoding="utf8", errors="replace", timeout=60,
        )
        text = res.stdout + res.stderr
        (h.output / f"neo_gdb_{tag}.client.log").write_text(text, encoding="utf8")
        h.check(f"neo gdb {tag} rc", res.returncode, 0)
        srv.proc.wait(timeout=10.0)
    finally:
        if srv.proc.poll() is None:
            _stop_remote(ssh_base, srv, remote_pid)
        cleanup = srv.close()
    h.require(f"neo gdb server {tag} exit", cleanup["exit_code"] == 0 and cleanup["reaped"] and not cleanup["forced"])
    words = gdb_debug._parse_state_words(text)
    h.require(f"neo gdb source {tag}", oracle["source_file"] in text and "HW_BREAK_PC=0x" in text and "HW_STEP_PC=0x" in text)
    cmp_state = parity.compare_hw_state(h, f"neo_gdb_{tag}", board_id, emu_words, words)
    return dict(cleanup=cleanup, **cmp_state)


def _stop_remote(ssh_base: list[str], proc, pid: int | None):
    if pid is not None and proc.proc.poll() is None:
        try:
            subprocess.run(ssh_base + [f"kill -TERM {pid}"], stdin=subprocess.DEVNULL, timeout=25)
        except subprocess.TimeoutExpired:
            pass
        try:
            proc.proc.wait(timeout=8.0)
        except subprocess.TimeoutExpired:
            pass
    proc.close()


def _target_rows(program: str, scratch: str, host_id: str) -> list[dict]:
    return [dict(
        kind="jlink", program=program, scratch=scratch, use_board_profile=True,
        target=dict(managed=False, host_id=host_id, probe_id=pid, board_id=bid, probe_serial=sn,
                    vendor="Renesas", model=mdl, cores=core, transport="jlink-usb"),
    ) for pid, bid, sn, mdl, core in (
        ("jlink-ra8e1", "fpb-ra8e1", "001083322193", "FPB-RA8E1", "Cortex-M85 r0p2"),
        ("jlink-ra4t1", "fpb-ra4t1", "001088957027", "FPB-RA4T1", "Cortex-M33 r0p4"),
    )]


def _open_remote_serve(h, ssh_base: list[str], cmd: str, tag: str):
    srv = h.spawn([*ssh_base, cmd], "serve: listening on tcp:", tag, f"{tag}.log", port_from_ready=True)
    remote_pid = next(int(ln.split(":", 1)[1]) for ln in srv.lines if ln.startswith("PID:"))
    local_port = gdb_debug.free_port()
    tun = hil._SshTunnel(h, h.args.probe_ssh_host, ["-L", f"127.0.0.1:{local_port}:127.0.0.1:{srv.port}"],
                         f"Local forwarding listening on 127.0.0.1 port {local_port}.", f"{tag}_tun")
    return srv, remote_pid, tun, IdeClient(local_port, h.trace, h.deadline, frame_timeout=90.0)


def _check_remote_fencing(h, ssh_base: list[str], cmd: str, c1: IdeClient, e1: dict):
    c1.targets_reserve(hil._sel(e1))
    srv2, pid2, tun2, c2 = _open_remote_serve(h, ssh_base, cmd, "neo_srv2")
    try:
        e2 = hil._find(c2.targets_list(), "fpb-ra8e1", "001083322193")
        c2.targets_reserve(hil._sel(e2), error=0x193)
        c2.targets_perform(hil._sel(e2), "registers", error=0x194)
        c1.targets_release()
        c2.targets_reserve(hil._sel(e2))
        c2.targets_release()
    finally:
        c2.close()
        tun2.close()
        _stop_remote(ssh_base, srv2, pid2)


def _exercise_remote_jlink_serve(h, ssh_base: list[str], remote_dir: str, remote_emu: str) -> dict:
    _write_remote_json(ssh_base, f"{remote_dir}/srv_targets.json",
                       _target_rows(h.args.probe_remote_jlink, f"{remote_dir}/scratch", "neo-server"))
    cmd = (f"echo PID:$$; exec {remote_emu} serve --targets {remote_dir}/srv_targets.json --workspace {remote_dir}/ws "
           f"--build-zig {shlex.quote(h.args.probe_remote_zig)} --history off --listen tcp:127.0.0.1:0 "
           f"{remote_dir}/repo/tests/fixtures/uart/uart_irq_echo.elf")
    srv, remote_pid, tun, c1 = _open_remote_serve(h, ssh_base, cmd, "neo_srv")
    try:
        e1, t1 = _verify_neo_targets(h, c1.targets_list(), "neo-server")
        _check_remote_fencing(h, ssh_base, cmd, c1, e1)

        b8 = parity.build_board_once(h, c1, "fpb-ra8e1")
        rem_e1 = parity.emulate_remote(h, ssh_base, remote_emu, f"{remote_dir}/ws/boards/{b8['artifact']}",
                                       b8["sha256"], "fpb-ra8e1", hil._SshTunnel, gdb_debug.free_port, "neo_emu_e1")
        c1.targets_reserve(hil._sel(t1))
        c1.targets_flash_receipt(hil._sel(t1), b8["receipt"], error=0x198)
        c1.targets_release()
        f_e1 = hil._flash_e1_and_compare(h, c1, e1, b8["receipt"], rem_e1, "neo_srv", drain_progress=True)
        c1.close_project()

        b4 = parity.build_board_once(h, c1, "fpb-ra4t1")
        rem_t1 = parity.emulate_remote(h, ssh_base, remote_emu, f"{remote_dir}/ws/boards/{b4['artifact']}",
                                       b4["sha256"], "fpb-ra4t1", hil._SshTunnel, gdb_debug.free_port, "neo_emu_t1")
        f_t1 = hil._flash_t1_and_compare(h, c1, t1, b4["receipt"], rem_t1, "neo_srv")
        c1.close_project()
    finally:
        c1.close()
        tun.close()
        _stop_remote(ssh_base, srv, remote_pid)

    gdb_e1 = _run_remote_jlink_gdb(h, ssh_base, remote_dir, b8["artifact"], "fpb-ra8e1", rem_e1["state_words"], "ra8e1")
    gdb_t1 = _run_remote_jlink_gdb(h, ssh_base, remote_dir, b4["artifact"], "fpb-ra4t1", rem_t1["state_words"], "ra4t1")
    return dict(
        ra8e1=dict(elf_sha256=rem_e1["elf_sha256"], flash_sha256=f_e1["flash"]["sha256"], uart_bytes=172,
                   uart=e1["target"]["uart"], **gdb_e1),
        ra4t1=dict(elf_sha256=rem_t1["elf_sha256"], flash_sha256=f_t1["flash"]["sha256"], emu_uart_bytes=172,
                   hw_uart="Unsupported(0x195)", boundary=rem_t1["uart_boundary"], **gdb_t1),
    )


def _exercise_win_agent_round(h, cfg: Path, win_ws: Path, tag: str, extra_fn=None) -> dict:
    srv = h.spawn([h.emulator, "serve", "--targets", cfg, "--workspace", win_ws, "--build-zig", h.zig,
                   "--history", "off", "--listen", "tcp:127.0.0.1:0", h.fixture],
                  "serve: listening on tcp:", f"{tag}_serve", f"{tag}_serve.log", port_from_ready=True)
    client = IdeClient(srv.port, h.trace, h.deadline, frame_timeout=90.0)
    try:
        e1, t1 = _verify_neo_targets(h, client.targets_list(), "neo-agent")
        b8 = parity.build_board_once(h, client, "fpb-ra8e1", win_ws)
        emu_e1 = parity.emulate_local(h, f"{tag}_emu_e1", b8["elf_path"], "fpb-ra8e1")
        f_e1 = hil._flash_e1_and_compare(h, client, e1, b8["receipt"], emu_e1, tag)
        client.close_project()
        client.targets_reserve(hil._sel(t1))
        client.targets_perform(hil._sel(t1), "uart", error=0x195)
        client.targets_release()
        out = dict(ra8e1_flash_sha256=f_e1["flash"]["sha256"], uart_bytes=f_e1["uart"]["bytes"],
                   ra4t1_uart="Unsupported(0x195)")
        if extra_fn is not None:
            out.update(extra_fn(client))
        return out
    finally:
        client.close()
        srv.close()


def _exercise_win_stdio(h, remote_dir: str, remote_emu: str, win_ws: Path, win_secret: Path) -> dict:
    hosts_path = h.output / "neo_hosts"
    hosts_path.write_text(f"ssh neo-probe {h.args.probe_ssh_host} emulator={remote_emu}\n", encoding="utf8")
    rows = [dict(
        kind="agent", profile="neo-probe", hosts_file=str(hosts_path.resolve()),
        remote_targets=f"{remote_dir}/agent_probes.json", remote_secret_file=f"{remote_dir}/agent.key",
        secret_file=str(win_secret.resolve()), target=row["target"],
    ) for row in _target_rows(h.args.probe_remote_jlink, f"{remote_dir}/scratch", "neo-agent")]
    cfg = h.output / "win_stdio_targets.json"
    cfg.write_text(json.dumps(rows, indent=2), encoding="utf8")
    return _exercise_win_agent_round(h, cfg, win_ws, "win_stdio")


def _exercise_win_tcp_agent(h, ssh_base: list[str], remote_dir: str, remote_emu: str,
                            win_ws: Path, win_secret: Path) -> dict:
    r_port = _free_remote_port(ssh_base)
    agent_cmd = (f"echo PID:$$; exec {remote_emu} probe-agent --targets {remote_dir}/agent_probes.json "
                 f"--secret-file {remote_dir}/agent.key --host-id neo-agent --listen tcp:127.0.0.1:{r_port}")
    agent = h.spawn([*ssh_base, agent_cmd], "probe-agent: listening on tcp:", "neo_tcp_agent", "neo_tcp_agent.log")
    a_pid = next(int(ln.split(":", 1)[1]) for ln in agent.lines if ln.startswith("PID:"))
    l_port = gdb_debug.free_port()
    tun = hil._SshTunnel(h, h.args.probe_ssh_host, ["-L", f"127.0.0.1:{l_port}:127.0.0.1:{r_port}"],
                         f"Local forwarding listening on 127.0.0.1 port {l_port}.", "neo_agent_tun")
    cfg = h.output / "win_tcp_targets.json"
    hil._write_remote_targets(cfg, l_port, str(win_secret.resolve()), "neo-agent")
    state = dict(agent2=None, a2_pid=None, tun2=None)

    def after_flash(client: IdeClient) -> dict:
        old_e1 = hil._find(client.targets_list(), "fpb-ra8e1", "001083322193")
        client.targets_reserve(hil._sel(old_e1))
        tun.close()
        _stop_remote(ssh_base, agent, a_pid)
        h.check("tcp agent mid-lease disconnect clears targets", client.targets_list(), [])
        state["agent2"] = h.spawn([*ssh_base, agent_cmd], "probe-agent: listening on tcp:", "neo_tcp_agent2", "neo_tcp_agent2.log")
        state["a2_pid"] = next(int(ln.split(":", 1)[1]) for ln in state["agent2"].lines if ln.startswith("PID:"))
        state["tun2"] = hil._SshTunnel(h, h.args.probe_ssh_host, ["-L", f"127.0.0.1:{l_port}:127.0.0.1:{r_port}"],
                                       f"Local forwarding listening on 127.0.0.1 port {l_port}.", "neo_agent_tun2")
        new_e1 = hil._find(client.targets_list(), "fpb-ra8e1", "001083322193")
        h.require("tcp agent reconnect bumps generation", new_e1["generation"] != old_e1["generation"])
        client.targets_reserve(hil._sel(old_e1), error=0x191)
        client.targets_reserve(hil._sel(new_e1))
        client.targets_release()
        return dict(old_generation=old_e1["generation"], new_generation=new_e1["generation"])

    try:
        return _exercise_win_agent_round(h, cfg, win_ws, "win_tcp", extra_fn=after_flash)
    finally:
        (state["tun2"] or tun).close()
        if state["agent2"] is not None:
            _stop_remote(ssh_base, state["agent2"], state["a2_pid"])
        _stop_remote(ssh_base, agent, a_pid)


def hil_server_attached_probe(h):
    h.require("ssh client available", shutil.which("ssh") is not None)
    ssh_base = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", h.args.probe_ssh_host]
    before_5b = _stat_unrelated_device(ssh_base)
    remote_dir = None
    try:
        remote_dir = subprocess.check_output(ssh_base + ["mktemp -d /tmp/ra8-ide-srv.XXXXXX"], text=True, timeout=15).strip()
        h.require("safe server-attached remote temp dir", remote_dir.startswith("/tmp/ra8-ide-srv."))
        remote_emu = _stage_neo(h, ssh_base, remote_dir)
        remote_srv = _exercise_remote_jlink_serve(h, ssh_base, remote_dir, remote_emu)

        win_ws = h.output / "win_agent_ws"
        workspace_setup.populate(win_ws)
        win_secret = h.output / "srv_agent.key"
        win_secret.write_text(secrets.token_hex(32) + "\n", encoding="utf8")
        subprocess.run(ssh_base + [f"cat > {remote_dir}/agent.key && chmod 600 {remote_dir}/agent.key"],
                       input=win_secret.read_bytes(), check=True, timeout=15)
        _write_remote_json(ssh_base, f"{remote_dir}/agent_probes.json",
                           _target_rows(h.args.probe_remote_jlink, f"{remote_dir}/scratch", "neo-agent"))

        win_stdio = _exercise_win_stdio(h, remote_dir, remote_emu, win_ws, win_secret)
        win_tcp = _exercise_win_tcp_agent(h, ssh_base, remote_dir, remote_emu, win_ws, win_secret)
        _assert_unrelated_untouched(h, ssh_base, before_5b)

        h.physical_gates["server_attached_probe"] = "PASS"
        h.results["server_attached_probe"] = dict(
            ssh_host=h.args.probe_ssh_host,
            remote_host_jlink_tests="PASS",
            unrelated_device_5B420583571="UNTOUCHED" if before_5b != "ABSENT" else "UNTOUCHED_ABSENT",
            remote_serve_jlink=remote_srv,
            win_serve_ssh_stdio_agent=win_stdio,
            win_serve_tcp_agent=win_tcp,
        )
    finally:
        if remote_dir:
            subprocess.run(ssh_base + [f"rm -rf -- {remote_dir}"], stdin=subprocess.DEVNULL, timeout=15)


CASES = (hil_server_attached_probe,)
