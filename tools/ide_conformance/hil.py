"""Physical J-Link bench HIL scenarios (local Windows bench and remote Linux backend)."""
import io
import json
from pathlib import Path
import queue
import secrets
import shutil
import socket
import subprocess
import tarfile
import threading
import time

import gdb_debug
from rpc_client import IdeClient
import sim_agent
import workspace_setup

ROOT = Path(__file__).resolve().parents[2]
ALLOWED_SERIALS = ("001083322193", "001088957027")
FORBIDDEN_COM_PORTS = {"COM1", "COM3", "COM9"}


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


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
        ["git", "ls-files", "-z", "build.zig", "build.zig.zon", "build_tests.zig", "src/root.zig",
         "src/chip", "src/components", "src/board", "src/session", "src/snapshot", "src/host",
         "src/interfaces/cli", "src/interfaces/dap", "src/interfaces/gdb", "src/interfaces/render",
         "src/interfaces/rpc", "src/interfaces/usbip", "tools", "tests"],
        cwd=ROOT,
    ).split(b"\0")
    rel_paths = {p.decode("utf8") for p in tracked if p and not p.startswith(b"tests/corpus/")}
    for extra in ROOT.glob("tools/ide_conformance/*.py"):
        rel_paths.add(extra.relative_to(ROOT).as_posix())
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for rel in sorted(rel_paths):
            full = ROOT / rel
            if full.is_file():
                tf.add(full, arcname=rel)
    return buf.getvalue()


def hil_local_windows_bench(h):
    jlink = h.args.jlink.resolve()
    gdb_srv = h.args.jlink_gdb_server.resolve()
    h.require("JLink.exe exists", jlink.is_file())
    h.require("JLinkGDBServerCL.exe exists", gdb_srv.is_file())
    h.require("GDB exists", h.gdb is not None and h.gdb.is_file())

    ws = h.output / "hil_local_ws"
    workspace_setup.populate(ws)
    scratch = h.output / "hil_local_scratch"
    scratch.mkdir()
    tgt = h.output / "hil_local_targets.json"
    _write_targets(tgt, jlink, scratch, "win-bench")

    srv = h.spawn([h.emulator, "serve", "--targets", tgt, "--workspace", ws, "--build-zig", h.zig,
                   "--history", "off", "--listen", "tcp::0", h.fixture],
                  "serve: listening on tcp:", "hil_local_serve", "hil_local_serve.log", port_from_ready=True)
    client = IdeClient(srv.port, h.trace, h.deadline, frame_timeout=90.0)
    elf_e1 = elf_t1 = None
    try:
        listed = client.targets_list()
        e1 = _find(listed, "fpb-ra8e1", "001083322193")
        t1 = _find(listed, "fpb-ra4t1", "001088957027")
        h.check("ra8e1 connected/verified", (e1["target"]["connection"], e1["target"]["identity_verified"]), ("connected", True))
        h.check("ra4t1 connected/verified", (t1["target"]["connection"], t1["target"]["identity_verified"]), ("connected", True))
        vcom = e1["target"]["uart"]
        h.require("ra8e1 VCOM safe port", bool(vcom) and vcom.upper() not in FORBIDDEN_COM_PORTS)
        h.check("ra4t1 VCOM unsupported", (t1["target"]["capabilities"]["uart"], "uart" in t1["target"]["operations"]), (False, False))

        client.open_project("project_ra8e1.json")
        j1 = client.build_project("debug")
        h.check("local HIL build ra8e1", client.finish(j1)["state"], "succeeded")
        rec_e1 = client.prepare(j1)
        elf_e1 = ws / "boards" / json.loads((ws / "boards" / rec_e1).read_text(encoding="utf8"))["artifact"]

        client.targets_reserve(_sel(t1))
        client.targets_flash_receipt(_sel(t1), rec_e1, error=0x198)
        client.targets_release()

        client.targets_reserve(_sel(e1))
        res_e1 = client.targets_flash_receipt(_sel(e1), rec_e1, reset=True, uart=True)
        h.check("HIL ra8e1 flash/verify", (res_e1["flash"]["flashed"], res_e1["flash"]["verified"], res_e1["flash"]["serial"], res_e1["flash"]["cpuid"], res_e1["flash"]["part"]),
                (True, True, "001083322193", "0x410FD232", "R7FA8E1AFDCFB"))
        h.check("HIL ra8e1 reset", res_e1["reset"]["reset"], True)
        h.check("HIL ra8e1 172B VCOM UART", (res_e1["uart"]["bytes"], res_e1["uart"]["text"]), (172, sim_agent.KNOWN_BANNER))
        for action in ("halt", "registers", "step", "resume"):
            client.targets_perform(_sel(e1), action)
        client.targets_release()
        client.close_project()

        client.open_project("project_ra4t1.json")
        client.completed.clear(); client.outputs.clear(); client.sequences.clear()
        j2 = client.build_project("debug")
        h.check("local HIL build ra4t1", client.finish(j2)["state"], "succeeded")
        rec_t1 = client.prepare(j2)
        elf_t1 = ws / "boards" / json.loads((ws / "boards" / rec_t1).read_text(encoding="utf8"))["artifact"]

        client.targets_reserve(_sel(t1))
        res_t1 = client.targets_flash_receipt(_sel(t1), rec_t1, reset=True, uart=False)
        h.check("HIL ra4t1 flash/verify", (res_t1["flash"]["flashed"], res_t1["flash"]["verified"], res_t1["flash"]["serial"], res_t1["flash"]["cpuid"], res_t1["flash"]["part"]),
                (True, True, "001088957027", "0x410FD214", "R7FA4T1BB3CFM"))
        h.check("HIL ra4t1 reset", res_t1["reset"]["reset"], True)
        client.targets_perform(_sel(t1), "uart", error=0x195)
        for action in ("halt", "registers", "step", "resume"):
            client.targets_perform(_sel(t1), action)
        client.targets_release()
        client.close_project()
    finally:
        client.close()
        srv.close()

    h.physical_gates["local_windows_bench_fpb_ra8e1"] = "PASS"
    h.physical_gates["local_windows_bench_fpb_ra4t1"] = "PASS"

    gdb_e1 = gdb_debug.run_hardware_jlink_gdb(
        h.gdb, gdb_srv, "001083322193", "R7FA8E1AF", elf_e1, "fpb_ra8e1.zig",
        "0x22060100", "0x52413845", "0x410fd232", h.output, "ra8e1", h.trace, h.deadline,
    )
    h.physical_gates["local_windows_hardware_jlink_gdb_ra8e1"] = "PASS"
    gdb_t1 = gdb_debug.run_hardware_jlink_gdb(
        h.gdb, gdb_srv, "001088957027", "R7FA4T1BB", elf_t1, "fpb_ra4t1.zig",
        "0x20000100", "0x52413454", "0x410fd214", h.output, "ra4t1", h.trace, h.deadline,
    )
    h.physical_gates["local_windows_hardware_jlink_gdb_ra4t1"] = "PASS"
    h.results["hil_local"] = dict(ra8e1_uart_bytes=172, gdb_ra8e1=gdb_e1, gdb_ra4t1=gdb_t1)


def hil_remote_linux_backend_laptop_probe(h):
    h.require("ssh client available", shutil.which("ssh") is not None)
    ssh_base = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", h.args.ssh_host]
    scratch = h.output / "hil_agent_scratch"
    scratch.mkdir()
    agent_cfg = h.output / "hil_agent_probes.json"
    _write_targets(agent_cfg, h.args.jlink.resolve(), scratch, "win-bench")
    secret = h.output / "hil_probe_agent.key"
    secret.write_text(secrets.token_hex(32) + "\n", encoding="utf8")

    agent = h.spawn([h.emulator, "probe-agent", "--targets", agent_cfg, "--secret-file", secret,
                     "--host-id", "win-bench", "--listen", "tcp:127.0.0.1:0"],
                    "probe-agent: listening on tcp:", "hil_win_agent", "hil_win_agent.log", port_from_ready=True)
    remote_dir = None
    rev_tun = fwd_tun = r_serve = client = remote_pid = None
    try:
        remote_dir = subprocess.check_output(ssh_base + ["mktemp -d /tmp/ra8-ide-hil.XXXXXX"], text=True, timeout=15).strip()
        h.require("safe remote temp dir", remote_dir.startswith("/tmp/ra8-ide-hil."))
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

        rev_tun = _SshTunnel(h, h.args.ssh_host, ["-R", f"127.0.0.1:{r_agent_port}:127.0.0.1:{agent.port}"],
                             "forwarding_success: all expected forwarding replies received", "rev_agent")
        remote_cmd = (f"echo PID:$$; exec {remote_emu} serve --targets {remote_dir}/remote_targets.json "
                      f"--workspace {remote_dir}/ws --build-zig {h.args.remote_zig} --history off "
                      f"--listen tcp:127.0.0.1:0 {remote_dir}/repo/tests/fixtures/uart/uart_irq_echo.elf")
        r_serve = h.spawn([*ssh_base, remote_cmd], "serve: listening on tcp:", "hil_remote_serve", "hil_remote_serve.log", port_from_ready=True)
        remote_pid = next(int(ln.split(":", 1)[1]) for ln in r_serve.lines if ln.startswith("PID:"))
        local_rpc_port = _free_port()
        fwd_tun = _SshTunnel(h, h.args.ssh_host, ["-L", f"127.0.0.1:{local_rpc_port}:127.0.0.1:{r_serve.port}"],
                             f"Local forwarding listening on 127.0.0.1 port {local_rpc_port}.", "fwd_rpc")

        client = IdeClient(local_rpc_port, h.trace, h.deadline, frame_timeout=90.0)
        e1 = _find(client.targets_list(), "fpb-ra8e1", "001083322193")
        client.open_project("project_ra8e1.json")
        job = client.build_project("debug")
        b_res = client.finish(job, timeout=180)
        h.check("remote Linux build succeeded", (b_res["state"], b_res["platform"]), ("succeeded", "linux-x86_64"))
        rec = client.prepare(job)
        client.targets_reserve(_sel(e1))
        client.target_progress.clear()
        f_res = client.targets_flash_receipt(_sel(e1), rec, reset=True, uart=True)
        h.check("remote->laptop flash/verify", (f_res["flash"]["flashed"], f_res["flash"]["verified"], f_res["flash"]["serial"], f_res["flash"]["part"]),
                (True, True, "001083322193", "R7FA8E1AFDCFB"))
        h.check("remote->laptop reset", f_res["reset"]["reset"], True)
        h.check("remote->laptop 172B UART", (f_res["uart"]["bytes"], f_res["uart"]["text"]), (172, sim_agent.KNOWN_BANNER))
        client.targets_list()
        h.check("remote->laptop progress stages", [p["stage"] for p in client.target_progress[-3:]], ["flash", "reset", "uart"])
        client.targets_release()
        client.close_project()
        h.physical_gates["remote_linux_backend_laptop_windows_probe"] = "PASS"
        h.results["hil_remote"] = dict(build_host=b_res["host"], build_platform=b_res["platform"], ra8e1_uart_bytes=172,
                                       server_attached_probe="PENDING_RA8EMU-1351")
    finally:
        if client is not None:
            client.close()
        if fwd_tun is not None:
            fwd_tun.close()
        if remote_pid is not None and r_serve is not None and r_serve.proc.poll() is None:
            subprocess.run(ssh_base + [f"kill -TERM {remote_pid}"], timeout=10)
        if r_serve is not None:
            r_serve.close()
        if rev_tun is not None:
            rev_tun.close()
        agent.close()
        if remote_dir:
            subprocess.run(ssh_base + [f"rm -rf -- {remote_dir}"], timeout=15)


CASES = (hil_local_windows_bench, hil_remote_linux_backend_laptop_probe)
