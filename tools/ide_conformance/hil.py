"""Physical J-Link bench HIL scenarios (local Windows bench and remote Linux backend)."""
import io
import json
from pathlib import Path
import secrets
import shutil
import subprocess
import tarfile
import threading

import gdb_debug
import parity
from rpc_client import IdeClient
import workspace_setup

ROOT = Path(__file__).resolve().parents[2]
ALLOWED_SERIALS = ("001083322193", "001088957027")
FORBIDDEN_COM_PORTS = {"COM1", "COM3", "COM9"}


def _sel(entry):
    t = entry["target"]
    return dict(host_id=t["host_id"], probe_id=t["probe_id"], board_id=t["board_id"],
                generation=entry["generation"], disambiguation=t.get("disambiguation", ""))


def _find(entries, board_id, serial):
    match = next(e for e in entries if e["target"]["board_id"] == board_id)
    if match["target"]["probe_serial"] != serial or serial not in ALLOWED_SERIALS:
        raise AssertionError(f"unexpected probe serial {match['target']['probe_serial']!r}")
    return match


def _write_targets(path: Path, jlink: Path, scratch: Path, host_id: str):
    items = [
        ("jlink-ra8e1", "fpb-ra8e1", "001083322193", "FPB-RA8E1", "Cortex-M85 r0p2"),
        ("jlink-ra4t1", "fpb-ra4t1", "001088957027", "FPB-RA4T1", "Cortex-M33 r0p4"),
    ]
    rows = [dict(
        kind="jlink", program=str(jlink), scratch=str(scratch), use_board_profile=True,
        target=dict(managed=False, host_id=host_id, probe_id=pid, board_id=bid, probe_serial=sn,
                    vendor="Renesas", model=mdl, cores=core, transport="jlink-usb"),
    ) for pid, bid, sn, mdl, core in items]
    path.write_text(json.dumps(rows, indent=2), encoding="utf8")


def _write_remote_targets(local_path: Path, port: int, remote_secret: str, host_id: str):
    items = [
        ("jlink-ra8e1", "fpb-ra8e1", "001083322193", "FPB-RA8E1", "Cortex-M85 r0p2"),
        ("jlink-ra4t1", "fpb-ra4t1", "001088957027", "FPB-RA4T1", "Cortex-M33 r0p4"),
    ]
    rows = [dict(
        kind="agent", host="127.0.0.1", port=port, secret_file=remote_secret,
        target=dict(managed=False, host_id=host_id, probe_id=pid, board_id=bid, probe_serial=sn,
                    vendor="Renesas", model=mdl, cores=core, transport="jlink-usb"),
    ) for pid, bid, sn, mdl, core in items]
    local_path.write_text(json.dumps(rows, indent=2), encoding="utf8")


class _SshTunnel:
    def __init__(self, h, host: str, args: list[str], ready_marker: str, tag: str):
        self.h, self.tag, self.lines, self.ready = h, tag, [], threading.Event()
        argv = ["ssh", "-v", "-N", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "ExitOnForwardFailure=yes", *args, host]
        self.proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.PIPE, text=True, encoding="utf8", errors="replace")

        def drain():
            for line in iter(lambda: self.proc.stderr.readline(4096), ""):
                if len(self.lines) < 512:
                    self.lines.append(line)
                if ready_marker in line:
                    self.ready.set()

        self.reader = threading.Thread(target=drain, daemon=True)
        self.reader.start()
        if not self.ready.wait(timeout=15) or self.proc.poll() is not None:
            self.close()
            raise RuntimeError(f"SSH tunnel {tag} failed: {''.join(self.lines)}")
        h.trace(dict(type="ssh_tunnel_ready", tag=tag, argv=argv))

    def close(self):
        if hasattr(self, "cleanup"):
            return self.cleanup
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        self.reader.join(timeout=1)
        if self.proc.stderr:
            self.proc.stderr.close()
        self.cleanup = dict(tag=self.tag, exit_code=self.proc.returncode, reaped=self.proc.poll() is not None)
        self.h.trace(dict(type="ssh_tunnel_cleanup", **self.cleanup))
        return self.cleanup


def _repo_tar_bytes() -> bytes:
    tracked = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z",
         "build.zig", "build.zig.zon", "build_tests.zig", "src/root.zig",
         "src/chip", "src/components", "src/board", "src/session", "src/snapshot", "src/host",
         "src/interfaces/cli", "src/interfaces/dap", "src/interfaces/gdb", "src/interfaces/render",
         "src/interfaces/rpc", "src/interfaces/usbip", "tools", "tests"],
        cwd=ROOT,
    ).split(b"\0")
    rel_paths = {
        p.decode("utf8") for p in tracked
        if p and not p.startswith(b"tests/corpus/") and b"__pycache__" not in p
    }
    for extra in ROOT.glob("tools/ide_conformance/*.py"):
        rel_paths.add(extra.relative_to(ROOT).as_posix())
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for rel in sorted(rel_paths):
            full = ROOT / rel
            if full.is_file():
                tf.add(full, arcname=rel)
    return buf.getvalue()


def _verify_targets(h, listed):
    e1 = _find(listed, "fpb-ra8e1", "001083322193")
    t1 = _find(listed, "fpb-ra4t1", "001088957027")
    h.check("ra8e1 connected/verified", (e1["target"]["connection"], e1["target"]["identity_verified"]), ("connected", True))
    h.check("ra4t1 connected/verified", (t1["target"]["connection"], t1["target"]["identity_verified"]), ("connected", True))
    vcom = e1["target"]["uart"]
    h.require("ra8e1 VCOM safe port", bool(vcom) and vcom.upper() not in FORBIDDEN_COM_PORTS)
    h.check("ra4t1 VCOM unsupported", (t1["target"]["capabilities"]["uart"], "uart" in t1["target"]["operations"]), (False, False))
    return e1, t1


def _flash_e1_and_compare(h, client: IdeClient, e1, receipt: str, emu_e1: dict, tag: str, drain_progress=False):
    client.targets_reserve(_sel(e1))
    client.target_progress.clear()
    res = client.targets_flash_receipt(_sel(e1), receipt, reset=True, uart=True)
    h.check(f"{tag} ra8e1 flash/verify",
            (res["flash"]["flashed"], res["flash"]["verified"], res["flash"]["serial"],
             res["flash"]["cpuid"], res["flash"]["part"], res["flash"]["sha256"]),
            (True, True, "001083322193", "0x410FD232", "R7FA8E1AFDCFB", emu_e1["elf_sha256"]))
    h.check(f"{tag} ra8e1 reset", res["reset"]["reset"], True)
    h.check(f"{tag} ra8e1 uart parity", (res["uart"]["bytes"], res["uart"]["text"]), (172, emu_e1["uart"]))
    if drain_progress:
        client.targets_list()
        h.check(f"{tag} progress stages", [p["stage"] for p in client.target_progress[-3:]], ["flash", "reset", "uart"])
    for action in ("halt", "registers", "step", "resume"):
        client.targets_perform(_sel(e1), action)
    client.targets_release()
    return res


def _flash_t1_and_compare(h, client: IdeClient, t1, receipt: str, emu_t1: dict, tag: str):
    client.targets_reserve(_sel(t1))
    res = client.targets_flash_receipt(_sel(t1), receipt, reset=True, uart=False)
    h.check(f"{tag} ra4t1 flash/verify",
            (res["flash"]["flashed"], res["flash"]["verified"], res["flash"]["serial"],
             res["flash"]["cpuid"], res["flash"]["part"], res["flash"]["sha256"]),
            (True, True, "001088957027", "0x410FD214", "R7FA4T1BB3CFM", emu_t1["elf_sha256"]))
    h.check(f"{tag} ra4t1 reset", res["reset"]["reset"], True)
    client.targets_perform(_sel(t1), "uart", error=0x195)
    for action in ("halt", "registers", "step", "resume"):
        client.targets_perform(_sel(t1), action)
    client.targets_release()
    return res


def hil_local_windows_bench(h):
    jlink, gdb_srv = h.args.jlink.resolve(), h.args.jlink_gdb_server.resolve()
    h.require("JLink.exe exists", jlink.is_file())
    h.require("JLinkGDBServerCL.exe exists", gdb_srv.is_file())
    h.require("GDB exists", h.gdb is not None and h.gdb.is_file())

    ws, scratch = h.output / "hil_local_ws", h.output / "hil_local_scratch"
    workspace_setup.populate(ws)
    scratch.mkdir()
    tgt = h.output / "hil_local_targets.json"
    _write_targets(tgt, jlink, scratch, "win-bench")

    srv = h.spawn([h.emulator, "serve", "--targets", tgt, "--workspace", ws, "--build-zig", h.zig,
                   "--history", "off", "--listen", "tcp::0", h.fixture],
                  "serve: listening on tcp:", "hil_local_serve", "hil_local_serve.log", port_from_ready=True)
    client = IdeClient(srv.port, h.trace, h.deadline, frame_timeout=90.0)
    try:
        e1, t1 = _verify_targets(h, client.targets_list())
        b8 = parity.build_board_once(h, client, "fpb-ra8e1", ws)
        emu_e1 = parity.emulate_local(h, "hil_local_emu_e1", b8["elf_path"], "fpb-ra8e1")
        client.targets_reserve(_sel(t1))
        client.targets_flash_receipt(_sel(t1), b8["receipt"], error=0x198)
        client.targets_release()
        res_e1 = _flash_e1_and_compare(h, client, e1, b8["receipt"], emu_e1, "hil_local")
        client.close_project()

        b4 = parity.build_board_once(h, client, "fpb-ra4t1", ws)
        emu_t1 = parity.emulate_local(h, "hil_local_emu_t1", b4["elf_path"], "fpb-ra4t1")
        res_t1 = _flash_t1_and_compare(h, client, t1, b4["receipt"], emu_t1, "hil_local")
        client.close_project()
    finally:
        client.close()
        srv.close()

    h.physical_gates["local_windows_bench_fpb_ra8e1"] = "PASS"
    h.physical_gates["local_windows_bench_fpb_ra4t1"] = "PASS"

    gdb_e1 = gdb_debug.run_hardware_jlink_gdb(
        h.gdb, gdb_srv, "001083322193", "R7FA8E1AF", b8["elf_path"], "fpb_ra8e1.zig",
        "0x22060100", "0x52413845", "0x410fd232", h.output, "ra8e1", h.trace, h.deadline,
    )
    cmp_e1 = parity.compare_hw_state(h, "hil_local ra8e1", "fpb-ra8e1", emu_e1["state_words"], gdb_e1["state_words"])
    h.physical_gates["local_windows_hardware_jlink_gdb_ra8e1"] = "PASS"

    gdb_t1 = gdb_debug.run_hardware_jlink_gdb(
        h.gdb, gdb_srv, "001088957027", "R7FA4T1BB", b4["elf_path"], "fpb_ra4t1.zig",
        "0x20000100", "0x52413454", "0x410fd214", h.output, "ra4t1", h.trace, h.deadline,
    )
    cmp_t1 = parity.compare_hw_state(h, "hil_local ra4t1", "fpb-ra4t1", emu_t1["state_words"], gdb_t1["state_words"])
    h.physical_gates["local_windows_hardware_jlink_gdb_ra4t1"] = "PASS"

    h.results["hil_local"] = dict(
        ra8e1=dict(elf_sha256=emu_e1["elf_sha256"], flash_sha256=res_e1["flash"]["sha256"],
                   uart_bytes=172, uart_match=True, **cmp_e1, gdb=gdb_e1),
        ra4t1=dict(elf_sha256=emu_t1["elf_sha256"], flash_sha256=res_t1["flash"]["sha256"],
                   emu_uart_bytes=172, hw_uart="Unsupported(0x195)", boundary=emu_t1["uart_boundary"],
                   **cmp_t1, gdb=gdb_t1),
    )


def _stage_remote_env(h, ssh_base: list[str], remote_dir: str, secret: Path) -> tuple[str, int]:
    subprocess.run(ssh_base + [f"mkdir -p {remote_dir}/repo && tar -xzf - -C {remote_dir}/repo"],
                   input=_repo_tar_bytes(), check=True, timeout=60)
    remote_emu = h.args.remote_emulator or f"{remote_dir}/repo/zig-out/bin/ra8_emulator"
    if not h.args.remote_emulator:
        subprocess.run(ssh_base + [f"cd {remote_dir}/repo && {h.args.remote_zig} build"],
                       check=True, capture_output=True, text=True, timeout=240)
    subprocess.run(ssh_base + [
        f"python3 -c \"import sys; from pathlib import Path; sys.path.insert(0, '{remote_dir}/repo/tools/ide_conformance'); "
        f"import workspace_setup; workspace_setup.populate(Path('{remote_dir}/ws'))\""
    ], check=True, timeout=30)
    subprocess.run(ssh_base + [f"cat > {remote_dir}/probe_agent.key && chmod 600 {remote_dir}/probe_agent.key"],
                   input=secret.read_bytes(), check=True, timeout=15)
    r_agent_port = int(subprocess.check_output(
        ssh_base + ["python3 -c 'import socket; s=socket.socket(); s.bind((\"127.0.0.1\",0)); print(s.getsockname()[1]); s.close()'"],
        text=True, timeout=15).strip())
    rem_tgt = h.output / "hil_remote_targets.json"
    _write_remote_targets(rem_tgt, r_agent_port, f"{remote_dir}/probe_agent.key", "win-bench")
    subprocess.run(ssh_base + [f"cat > {remote_dir}/remote_targets.json"], input=rem_tgt.read_bytes(), check=True, timeout=15)
    return remote_emu, r_agent_port


def hil_remote_linux_backend_laptop_probe(h):
    h.require("ssh client available", shutil.which("ssh") is not None)
    ssh_base = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", h.args.ssh_host]
    gdb_srv = h.args.jlink_gdb_server.resolve()
    scratch = h.output / "hil_agent_scratch"
    scratch.mkdir()
    agent_cfg = h.output / "hil_agent_probes.json"
    _write_targets(agent_cfg, h.args.jlink.resolve(), scratch, "win-bench")
    secret = h.output / "hil_probe_agent.key"
    secret.write_text(secrets.token_hex(32) + "\n", encoding="utf8")

    agent = h.spawn([h.emulator, "probe-agent", "--targets", agent_cfg, "--secret-file", secret,
                     "--host-id", "win-bench", "--listen", "tcp:127.0.0.1:0"],
                    "probe-agent: listening on tcp:", "hil_win_agent", "hil_win_agent.log", port_from_ready=True)
    remote_dir = rev_tun = fwd_tun = r_serve = client = remote_pid = None
    try:
        remote_dir = subprocess.check_output(ssh_base + ["mktemp -d /tmp/ra8-ide-hil.XXXXXX"], text=True, timeout=15).strip()
        h.require("safe remote temp dir", remote_dir.startswith("/tmp/ra8-ide-hil."))
        remote_emu, r_agent_port = _stage_remote_env(h, ssh_base, remote_dir, secret)

        rev_tun = _SshTunnel(h, h.args.ssh_host, ["-R", f"127.0.0.1:{r_agent_port}:127.0.0.1:{agent.port}"],
                             "forwarding_success: all expected forwarding replies received", "rev_agent")
        remote_cmd = (f"echo PID:$$; exec {remote_emu} serve --targets {remote_dir}/remote_targets.json "
                      f"--workspace {remote_dir}/ws --build-zig {h.args.remote_zig} --history off "
                      f"--listen tcp:127.0.0.1:0 {remote_dir}/repo/tests/fixtures/uart/uart_irq_echo.elf")
        r_serve = h.spawn([*ssh_base, remote_cmd], "serve: listening on tcp:", "hil_remote_serve", "hil_remote_serve.log", port_from_ready=True)
        remote_pid = next(int(ln.split(":", 1)[1]) for ln in r_serve.lines if ln.startswith("PID:"))
        local_rpc_port = gdb_debug.free_port()
        fwd_tun = _SshTunnel(h, h.args.ssh_host, ["-L", f"127.0.0.1:{local_rpc_port}:127.0.0.1:{r_serve.port}"],
                             f"Local forwarding listening on 127.0.0.1 port {local_rpc_port}.", "fwd_rpc")

        client = IdeClient(local_rpc_port, h.trace, h.deadline, frame_timeout=90.0)
        e1, t1 = _verify_targets(h, client.targets_list())

        b8 = parity.build_board_once(h, client, "fpb-ra8e1")
        rem_e1 = parity.emulate_remote(h, ssh_base, remote_emu, f"{remote_dir}/ws/boards/{b8['artifact']}",
                                       b8["sha256"], "fpb-ra8e1", _SshTunnel, gdb_debug.free_port, "hil_rem_emu_e1")
        f_e1 = _flash_e1_and_compare(h, client, e1, b8["receipt"], rem_e1, "hil_remote", drain_progress=True)
        client.close_project()
        hw_e1 = gdb_debug.read_hardware_state(h.gdb, gdb_srv, "001083322193", "R7FA8E1AF", "0x22060100",
                                              h.output, "remote_ra8e1", h.trace, h.deadline)
        cmp_e1 = parity.compare_hw_state(h, "hil_remote ra8e1", "fpb-ra8e1", rem_e1["state_words"], hw_e1["state_words"])

        b4 = parity.build_board_once(h, client, "fpb-ra4t1")
        rem_t1 = parity.emulate_remote(h, ssh_base, remote_emu, f"{remote_dir}/ws/boards/{b4['artifact']}",
                                       b4["sha256"], "fpb-ra4t1", _SshTunnel, gdb_debug.free_port, "hil_rem_emu_t1")
        f_t1 = _flash_t1_and_compare(h, client, t1, b4["receipt"], rem_t1, "hil_remote")
        client.close_project()
        hw_t1 = gdb_debug.read_hardware_state(h.gdb, gdb_srv, "001088957027", "R7FA4T1BB", "0x20000100",
                                              h.output, "remote_ra4t1", h.trace, h.deadline)
        cmp_t1 = parity.compare_hw_state(h, "hil_remote ra4t1", "fpb-ra4t1", rem_t1["state_words"], hw_t1["state_words"])

        h.physical_gates["remote_linux_backend_laptop_windows_probe"] = "PASS"
        h.results["hil_remote"] = dict(
            ra8e1=dict(elf_sha256=rem_e1["elf_sha256"], flash_sha256=f_e1["flash"]["sha256"],
                       uart_bytes=172, uart_match=True, **cmp_e1),
            ra4t1=dict(elf_sha256=rem_t1["elf_sha256"], flash_sha256=f_t1["flash"]["sha256"],
                       emu_uart_bytes=172, hw_uart="Unsupported(0x195)", boundary=rem_t1["uart_boundary"],
                       **cmp_t1),
        )
    finally:
        if client is not None:
            client.close()
        if fwd_tun is not None:
            fwd_tun.close()
        if remote_pid is not None and r_serve is not None and r_serve.proc.poll() is None:
            try:
                subprocess.run(ssh_base + [f"kill -TERM {remote_pid}"], stdin=subprocess.DEVNULL, timeout=25)
            except subprocess.TimeoutExpired:
                pass
        if r_serve is not None:
            r_serve.close()
        if rev_tun is not None:
            rev_tun.close()
        agent.close()
        if remote_dir:
            subprocess.run(ssh_base + [f"rm -rf -- {remote_dir}"], timeout=15)


CASES = (hil_local_windows_bench, hil_remote_linux_backend_laptop_probe)
