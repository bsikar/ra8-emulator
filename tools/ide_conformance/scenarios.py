"""Portable CI scenarios for headless IDE project, debug, and 3-topology simulated targets."""
from contextlib import contextmanager
import hashlib, importlib.util, json, os, platform, secrets, sys, time
from pathlib import Path

import fake_jlink, gdb_debug, parity, sim_agent, workspace_setup
from rpc_client import IdeClient

ROOT = Path(__file__).resolve().parents[2]
BOARDS = (
    ("jlink-ra8e1", "fpb-ra8e1", "001083322193", "FPB-RA8E1", "Cortex-M85 r0p2"),
    ("jlink-ra4t1", "fpb-ra4t1", "001088957027", "FPB-RA4T1", "Cortex-M33 r0p4"),
)
SIM_BOARDS = (("sim-jlink-ra8e1",) + BOARDS[0][1:], ("sim-jlink-ra4t1",) + BOARDS[1][1:])


def _load(name: str, rel: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod); return mod


dap_client = _load("ide_dap_client", "tools/dap_conformance/client.py")
build_fixture = _load("ide_build_fixture", "tools/build_smoke/fixture.py")


class _DapCase:
    def __init__(self, h): self.h = h
    def record(self, event, **values): self.h.trace(dict(type="dap_" + event, **values))
    def equal(self, name, expected, actual): self.h.check(name, actual, expected)
    def require(self, name, condition, detail=None): self.h.require(name, condition)


def _host():
    if sys.platform == "darwin": return {"arm64": "aarch64-macos", "x86_64": "x86_64-macos"}[platform.machine()]
    return "x86_64-windows" if sys.platform == "win32" else "x86_64-linux"


def _sha(p: Path) -> str: return hashlib.sha256(p.read_bytes()).hexdigest()
def _find(entries, board_id): return next(e for e in entries if e["target"]["board_id"] == board_id)


def _sel(entry):
    t = entry["target"]
    return dict(host_id=t["host_id"], probe_id=t["probe_id"], board_id=t["board_id"],
                generation=entry["generation"], disambiguation=t.get("disambiguation", ""))


def _write_targets(path: Path, kind: str, host_id: str, boards=BOARDS, **extra):
    rows = [dict(kind=kind, **extra, target=dict(
        managed=False, host_id=host_id, probe_id=pid, board_id=bid, probe_serial=sn,
        vendor="Renesas", model=mdl, cores=core, transport="jlink-usb",
    )) for pid, bid, sn, mdl, core in boards]
    path.write_text(json.dumps(rows, indent=2), encoding="utf8")


def _offline_env(h, tag):
    env = {k: v for k, v in os.environ.items() if not k.upper().startswith(("ZIG", "CC", "CXX", "GDB"))}
    for sub in ("empty_path", "gcache", "lcache"): (h.output / f"{sub}_{tag}").mkdir(exist_ok=True)
    return dict(env, PATH=str(h.output / f"empty_path_{tag}"),
                ZIG_GLOBAL_CACHE_DIR=str(h.output / f"gcache_{tag}"),
                ZIG_LOCAL_CACHE_DIR=str(h.output / f"lcache_{tag}"))


@contextmanager
def _served_client(h, tag: str, targets_path: Path, ws: Path, timeout: float = 60.0):
    srv = h.spawn([h.emulator, "serve", "--targets", targets_path, "--workspace", ws, "--build-zig", h.zig,
                   "--history", "off", "--listen", "tcp::0", h.fixture], "serve: listening on tcp:", f"serve_{tag}", f"{tag}.serve.log", port_from_ready=True)
    client = IdeClient(srv.port, h.trace, h.deadline, frame_timeout=timeout)
    try: yield srv, client
    finally: client.close(); srv.close()


def _open_project(client: IdeClient, cfg: str):
    client.open_project(cfg); client.completed.clear(); client.outputs.clear(); client.sequences.clear()


def _mutated(path: Path, fn):
    class _Ctx:
        def __enter__(self): self.orig = path.read_bytes(); path.write_bytes(fn(self.orig))
        def __exit__(self, *_): path.write_bytes(self.orig)
    return _Ctx()


def _check_receipt(h, root: Path, cfg_path: Path, target: str, job: int, result: dict, rec: dict):
    h.check("receipt metadata", (rec["version"], rec["build_id"], rec["target"]), (1, job, target))
    h.check("receipt config/source sha", (rec["config_sha256"], rec["source_sha256"]), (_sha(cfg_path), build_fixture.revision(root)))
    data = (root / rec["artifact"]).read_bytes()
    h.check("ARM ELF header", (data[:4], int.from_bytes(data[18:20], "little")), (b"\x7fELF", 40))
    h.check("receipt artifact/compiler", (rec["artifact_sha256"], Path(rec["compiler"]).resolve(), rec["compiler_version"], result["artifact_sha256"]),
            (hashlib.sha256(data).hexdigest(), h.zig, "0.17.0", rec["artifact_sha256"]))


def _dap_session(h, ws: Path):
    proc = h.spawn([h.emulator, "project", "dap", "0", ws, "project.json", "--zig", h.zig], "dap: listening on tcp:", "project_dap", "project_dap.log", port_from_ready=True)
    peer = dap_client.Client(proc.port, _DapCase(h), 5, h.deadline)
    peer.request("initialize", {"adapterID": "ide-conformance", "pathFormat": "path"})
    return proc, peer


def _dap_reject(h, ws: Path, receipt_rel: str, expected_msg: str):
    proc, peer = _dap_session(h, ws)
    try:
        h.check("launch refused", peer.request("launch", {"program": receipt_rel}, success=False)["message"], expected_msg)
        h.check("unattached threads", peer.request("threads", success=False)["message"], "NotAttached")
        peer.request("disconnect"); peer.event("terminated"); h.check("dap reject exit", proc.proc.wait(timeout=5), 0)
    finally: peer.close(); proc.close()


def _run_dap_e2e(h, ws: Path, receipt_rel: str, rec: dict):
    oracle = gdb_debug.generate_oracle(ws / "firmware" / rec["artifact"], ws / "firmware/machine.zig")
    proc, peer = _dap_session(h, ws)
    try:
        peer.request("launch", {"program": receipt_rel, "stopOnEntry": True}); peer.event("initialized"); peer.request("configurationDone"); peer.event("stopped")
        frame = lambda: peer.request("stackTrace", {"threadId": 1})["body"]["stackFrames"][0]
        h.check("DAP entry PC", int(frame()["instructionPointerReference"], 0), oracle["entry"])
        peer.request("setInstructionBreakpoints", {"breakpoints": [{"instructionReference": hex(oracle["ready"])}]})
        peer.request("continue", {"threadId": 1}); peer.event("stopped")
        scopes = peer.request("scopes", {"frameId": frame()["id"]})["body"]["scopes"]
        reg_ref = next(s["variablesReference"] for s in scopes if s["name"] == "Registers")
        regs = {v["name"]: int(v["value"], 0) for v in peer.request("variables", {"variablesReference": reg_ref})["body"]["variables"]}
        for k, v in oracle["ready_registers"].items(): h.check(f"DAP reg {k}", regs[k], v)
        peer.request("setInstructionBreakpoints", {"breakpoints": []})
        peer.request("stepIn", {"threadId": 1, "granularity": "instruction"}); peer.event("stopped")
        h.check("DAP step PC", int(frame()["instructionPointerReference"], 0), oracle["ready"] + 2)
        h.check("unmapped source refused", peer.request("setBreakpoints", {"source": {"path": "C:/wrong/machine.zig"}, "breakpoints": [{"line": 60}]}, success=False)["message"], "SourceUnavailable")
        src = "C:/client-only/project/machine.zig"
        bps = peer.request("setBreakpoints", {"source": {"path": src}, "breakpoints": [{"line": oracle["source"]["line"]}]})["body"]["breakpoints"]
        h.check("mapped source bp verified", [b["verified"] for b in bps], [True])
        peer.request("continue", {"threadId": 1}); peer.event("stopped")
        top = frame()
        h.check("DAP mapped source", (top["source"]["path"].replace("\\", "/"), top["line"], int(top["instructionPointerReference"], 0)),
                (src, oracle["source"]["line"], oracle["source"]["address"]))
        peer.request("disconnect"); peer.event("terminated"); h.check("DAP clean exit", proc.proc.wait(timeout=5), 0)
    finally: peer.close(); proc.close()


def case_toolchain_and_offline_builds(h):
    host = _host()
    prof = h.run_cli([h.emulator, "toolchain", "profiles"]); h.check("profiles exit", prof.returncode, 0)
    profs = {p["id"]: p for p in json.loads(prof.stdout)}
    h.check("profile matrix IDs", sorted(profs), ["fpb-ra4t1", "fpb-ra8e1", "grove-vision-ai-v2", "ra8d2", "ra8p1"])
    h.check("ra8e1/ra4t1 uart caps", (profs["fpb-ra8e1"]["uart_wired"], profs["fpb-ra8e1"]["capabilities"]["uart"],
            profs["fpb-ra4t1"]["uart_wired"], profs["fpb-ra4t1"]["capabilities"]["uart"]), (True, "qualified", False, "unsupported"))
    h.check("absent boards", (profs["ra8d2"]["capabilities"]["flash_verify"], profs["ra8p1"]["availability"]), ("pending_hardware", "unpurchased_unavailable"))
    h.require("grove non-SWD", "not SWD" in profs["grove-vision-ai-v2"]["probe_transport"])
    mat = h.run_cli([h.emulator, "probe-agent", "--matrix"])
    h.check("probe-agent matrix", (mat.returncode, json.loads(mat.stdout)["emulated_usbip_distinct"]), (0, True))

    empty_cache = h.output / "empty_tc_cache"; empty_cache.mkdir()
    doc_miss = h.run_cli([h.emulator, "toolchain", "doctor", host, "ra8d2", "--cache-root", empty_cache, "--offline"])
    h.require("offline missing cache refuses", doc_miss.returncode != 0 and any(k in doc_miss.stderr for k in ("FileNotFound", "UnsafeCacheOwnership")))
    doc_ok = h.run_cli([h.emulator, "toolchain", "doctor", host, "fpb-ra8e1", "--backend-zig", h.zig, "--offline"])
    h.check("offline doctor explicit zig", (doc_ok.returncode, json.loads(doc_ok.stdout)["compiler"]["network_used"]), (0, False))

    ws = h.output / "offline_ws"; workspace_setup.populate(ws); off_env = _offline_env(h, "builds")
    for cfg, sub, tgt in (("project.json", "firmware", "ra8d2"), ("project_ra8e1.json", "boards", "fpb-ra8e1"), ("project_ra4t1.json", "boards", "fpb-ra4t1")):
        plan = h.run_cli([h.emulator, "toolchain", "plan", host, tgt, "--offline"])
        h.check(f"plan offline {tgt}", (plan.returncode, json.loads(plan.stdout)["offline"]), (0, True))
        bld = h.run_cli([h.emulator, "project", "build", ws, cfg, "debug", "--zig", h.zig], env=off_env); h.check(f"offline build {cfg}", bld.returncode, 0)
        info = json.loads(bld.stdout); rec = json.loads((ws / sub / info["receipt"]).read_text(encoding="utf8"))
        _check_receipt(h, ws / sub, ws / cfg, tgt, info["build_id"], json.loads((ws / sub / rec["directory"] / "result.json").read_text(encoding="utf8")), rec)
    for bad in (h.output / "no_such_zig.exe", "relative/zig"):
        h.require(f"invalid tool refused {bad}", h.run_cli([h.emulator, "project", "build", ws, "project.json", "debug", "--zig", bad]).returncode != 0)
    h.results["toolchain_profiles"] = sorted(profs)


def case_project_debug_and_failures(h):
    ws = h.output / "main_ws"; workspace_setup.populate(ws); (ws / "workspace.txt").write_text("base-marker\n", encoding="utf8")
    jl_dir = h.output / "fake_jlink"; wrapper, present_path, calls_path = fake_jlink.create_fixture(jl_dir)
    tgt_path = h.output / "local_jlink.json"
    _write_targets(tgt_path, "jlink", "local-bench", program=str(wrapper), scratch=str(jl_dir), use_board_profile=True)
    h.shared = dict(ws=ws, jl_dir=jl_dir, wrapper=wrapper, present_path=present_path, calls_path=calls_path, tgt_path=tgt_path)

    with _served_client(h, "local1", tgt_path, ws) as (_, client):
        h.require("IdeClient caps", all(client.caps & (1 << b) for b in (16, 17, 18, 21)))
        tok, _, cfg_raw = client.read("project.json")
        client.write("project.json", bytes(25), cfg_raw, error="conflict")
        cfg_obj = json.loads(cfg_raw); cfg_obj["recipes"][0]["timeout_ms"] = 240001
        client.write("project.json", tok, json.dumps(cfg_obj, indent=2).encode("utf8"))
        _open_project(client, "project.json")
        h.check("opened project hides base", client.stat("workspace.txt"), bytes(25))
        h.check("opened project exposes firmware", client.stat("conformance.zig")[0], 1)
        client.close_project(); h.check("close restores base", client.stat("workspace.txt")[0], 1); _open_project(client, "project.json")

        job = client.build_project("debug"); res = client.finish(job); h.check("build succeeded", res["state"], "succeeded")
        rec_rel = client.prepare(job); rec = json.loads(client.read(rec_rel)[2])
        _check_receipt(h, ws / "firmware", ws / "project.json", "ra8d2", job, res, rec)
        _run_dap_e2e(h, ws, rec_rel, rec)
        h.results["emulated_gdb"] = (gdb_debug.run_emulated_gdb(h.gdb, h.emulator, ws / "firmware" / rec["artifact"], ws / "firmware/machine.zig", h.output, h.trace, h.deadline)
                                     if h.gdb else dict(status="SKIPPED", reason="no --gdb provided"))

        with _mutated(ws / "firmware/conformance.zig", lambda _: b"export fn Reset_Handler() noreturn { const broken = ; }\n"):
            fj = client.build_project("debug"); fr = client.finish(fj)
            h.check("failed build state", (fr["state"], fr["failure"], fr["artifact"]), ("failed", "CompilerFailed", ""))
            client.prepare(fj, error=0x173)
            diags = [e["value"] for e in client.outputs[fj] if e["kind"] == 2]
            h.require("diagnostic at conformance.zig:1", any(d["path"] == "conformance.zig" and d["line"] == 1 and not d["external"] for d in diags))
        rj = client.build_project("debug"); client.finish(rj); rrec_rel = client.prepare(rj); rrec = json.loads(client.read(rrec_rel)[2])
        h.require("rebuild unique artifact", rrec["artifact"] != rec["artifact"])

        for target_p, mut_fn, err_msg in ((ws / "firmware/machine.zig", lambda b: b + b"\n// stale\n", "SourceChanged"),
                                          (ws / "firmware" / rrec["artifact"], lambda b: b[:-1] + bytes([b[-1] ^ 1]), "ArtifactChanged")):
            with _mutated(target_p, mut_fn): _dap_reject(h, ws, rrec_rel, err_msg)

        client.close_project()
        (ws / "project_missing_tool.json").write_text(json.dumps(dict(cfg_obj, compiler=str(h.output / "missing-zig.exe"))), encoding="utf8")
        _open_project(client, "project_missing_tool.json")
        mj = client.build_project("debug"); mr = client.finish(mj)
        h.check("missing tool fails", (mr["state"], mr["failure"]), ("failed", "FileNotFound"))
        client.prepare(mj, error=0x173); client.close_project()

        _open_project(client, "project.json")
        ready_p, delayed_p = ws / "firmware/.ra8-builds/project.ready", ws / "firmware/.ra8-builds/project.delayed"
        ready_p.unlink(missing_ok=True); delayed_p.unlink(missing_ok=True)
        sj = client.build_project("slow"); until = min(h.deadline, time.monotonic() + 30.0)
        while not ready_p.exists() and time.monotonic() < until: time.sleep(0.05)
        h.require("slow nested child ready", ready_p.exists())
        client.cancel(sj); sr = client.finish(sj)
        h.check("slow build canceled", (sr["state"], sr["cleanup"], sr["artifact"]), ("canceled", "complete", ""))
        end = time.monotonic() + 5.5
        while time.monotonic() < end: h.check("reaped nested child never wrote delayed", delayed_p.exists(), False); time.sleep(0.2)


def case_competing_and_unplug(h):
    ws, tgt_path, calls_path, present_path = h.shared["ws"], h.shared["tgt_path"], h.shared["calls_path"], h.shared["present_path"]
    with _served_client(h, "compete1", tgt_path, ws, 30.0) as (_, c1), _served_client(h, "compete2", tgt_path, ws, 30.0) as (_, c2):
        before = len(calls_path.read_text(encoding="utf8").splitlines())
        e1, e2 = _find(c1.targets_list(), "fpb-ra8e1"), _find(c2.targets_list(), "fpb-ra8e1")
        c1.targets_reserve(_sel(e1)); c2.targets_reserve(_sel(e2), error=0x193); c2.targets_perform(_sel(e2), "registers", error=0x194)
        rows = [json.loads(line) for line in calls_path.read_text(encoding="utf8").splitlines()[before:]]
        h.check("0 calls to sibling 001088957027", [r for r in rows if r["usb"] == "001088957027"], [])
        h.check("0 ops on busy target", [r for r in rows if r["usb"] == "001083322193"], [])
        c1.targets_release(); c2.targets_reserve(_sel(e2))
        h.check("c2 registers after release", c2.targets_perform(_sel(e2), "registers")["pc"], 0x02000100); c2.targets_release()

        c1.targets_reserve(_sel(e1))
        with _mutated(present_path, lambda _: json.dumps(["001088957027"]).encode("utf8")):
            lost = _find(c1.targets_list(), "fpb-ra8e1")
            h.check("unplug drops lease", (lost["target"]["connection"], lost["reserved"]), ("disconnected", False))
            c1.targets_perform(_sel(e1), "registers", error=0x191)
        back = _find(c1.targets_list(), "fpb-ra8e1")
        h.require("replug bumps generation", back["target"]["connection"] == "connected" and back["generation"] != e1["generation"])
        c1.targets_reserve(_sel(e1), error=0x191); c1.targets_reserve(_sel(back)); c1.targets_release()


def _sim_flash(h, client: IdeClient, ws: Path, check_uart: bool):
    e1, t1 = _find(client.targets_list(), "fpb-ra8e1"), _find(client.targets_list(), "fpb-ra4t1")
    _open_project(client, "project_ra8e1.json"); j1 = client.build_project("debug")
    h.check("build ra8e1", client.finish(j1)["state"], "succeeded")
    rec_e1 = client.prepare(j1); elf_e1 = ws / "boards" / json.loads((ws / "boards" / rec_e1).read_text(encoding="utf8"))["artifact"]
    client.targets_reserve(_sel(t1)); client.targets_flash_receipt(_sel(t1), rec_e1, error=0x198); client.targets_release()
    for target_p, mut_fn in ((elf_e1, lambda b: b[:-1] + bytes([b[-1] ^ 1])), (ws / "boards/fpb_ra8e1.zig", lambda b: b + b"\n// stale\n")):
        with _mutated(target_p, mut_fn): client.targets_reserve(_sel(e1)); client.targets_flash_receipt(_sel(e1), rec_e1, error=0x198); client.targets_release()

    client.targets_reserve(_sel(e1)); client.target_progress.clear()
    r1 = client.targets_flash_receipt(_sel(e1), rec_e1, reset=True, uart=check_uart)
    h.check("ra8e1 flash/verify", (r1["flash"]["verified"], r1["flash"]["serial"], r1["flash"]["part"]), (True, "001083322193", "R7FA8E1AFDCFB"))
    h.check("ra8e1 reset", r1["reset"]["reset"], True)
    if check_uart:
        h.check("ra8e1 172B UART", (r1["uart"]["bytes"], r1["uart"]["text"]), (172, sim_agent.KNOWN_BANNER))
        client.targets_list()
        h.check("progress stages", [p["stage"] for p in client.target_progress[-3:]], ["flash", "reset", "uart"])
    for act in ("halt", "registers", "step", "resume"):
        out = client.targets_perform(_sel(e1), act)
        if act == "step": h.check("step pc", out["pc"], 0x02000102)
    client.targets_release(); client.close_project()

    _open_project(client, "project_ra4t1.json"); j2 = client.build_project("debug")
    h.check("build ra4t1", client.finish(j2)["state"], "succeeded"); rec_t1 = client.prepare(j2)
    client.targets_reserve(_sel(t1)); r2 = client.targets_flash_receipt(_sel(t1), rec_t1, reset=True, uart=False)
    h.check("ra4t1 flash/verify", (r2["flash"]["verified"], r2["flash"]["serial"], r2["flash"]["part"]), (True, "001088957027", "R7FA4T1BB3CFM"))
    client.targets_perform(_sel(t1), "uart", error=0x195); client.targets_release(); client.close_project()


def case_topology_local_fake_jlink(h):
    ws, tgt_path, calls_path = h.shared["ws"], h.shared["tgt_path"], h.shared["calls_path"]
    with _served_client(h, "topo_local", tgt_path, ws) as (srv, client):
        _sim_flash(h, client, ws, check_uart=False); e1 = _find(client.targets_list(), "fpb-ra8e1"); client.close()
        cli_flash = h.run_cli([h.emulator, "project", "flash", ws, "project_ra8e1.json", "debug", "--connect", f"tcp:127.0.0.1:{srv.port}",
                               "--target", e1["target"]["host_id"], e1["target"]["probe_id"], e1["target"]["board_id"], str(e1["generation"]), "-", "--zig", h.zig, "--reset"])
        h.check("project flash CLI", (cli_flash.returncode, json.loads(cli_flash.stdout)["hardware"]["flash"]["verified"]), (0, True))
        rows = [json.loads(line) for line in calls_path.read_text(encoding="utf8").splitlines()]
        h.require("fake_jlink recorded verifybin", any(any(c.startswith("verifybin ") for c in r["commands"]) for r in rows))
    h.results["topology_local_fake_jlink"] = "PASS"


def case_topology_loopback_probe_agent(h):
    ws, jl_dir, wrapper = h.shared["ws"], h.shared["jl_dir"], h.shared["wrapper"]
    agent_cfg, secret, wrong = h.output / "loop_probes.json", h.output / "loop.key", h.output / "loop_wrong.key"
    _write_targets(agent_cfg, "jlink", "loopback-host", program=str(wrapper), scratch=str(jl_dir), use_board_profile=True)
    secret.write_text(secrets.token_hex(32) + "\n", encoding="utf8"); wrong.write_text(secrets.token_hex(32) + "\n", encoding="utf8")
    agent = h.spawn([h.emulator, "probe-agent", "--targets", agent_cfg, "--secret-file", secret, "--host-id", "loopback-host", "--listen", "tcp:127.0.0.1:0"],
                    "probe-agent: listening on tcp:", "loop_agent", "loop_agent.log", port_from_ready=True)
    bad_tgt, good_tgt = h.output / "loop_bad.json", h.output / "loop_good.json"
    _write_targets(bad_tgt, "agent", "loopback-host", host="127.0.0.1", port=agent.port, secret_file=str(wrong.resolve()))
    _write_targets(good_tgt, "agent", "loopback-host", host="127.0.0.1", port=agent.port, secret_file=str(secret.resolve()))

    with _served_client(h, "loop_bad", bad_tgt, ws, 30.0) as (_, c_bad): h.check("wrong secret fails closed", c_bad.targets_list(), [])
    with _served_client(h, "loop_good", good_tgt, ws) as (_, client):
        _sim_flash(h, client, ws, check_uart=False); old = _find(client.targets_list(), "fpb-ra8e1"); agent.close()
        h.check("agent loss drops targets", client.targets_list(), [])
        agent2 = h.spawn([h.emulator, "probe-agent", "--targets", agent_cfg, "--secret-file", secret, "--host-id", "loopback-host", "--listen", f"tcp:127.0.0.1:{agent.port}"],
                         "probe-agent: listening on tcp:", "loop_agent2", "loop_agent2.log", port_from_ready=True)
        try:
            new = _find(client.targets_list(), "fpb-ra8e1")
            h.require("agent reconnect bumps generation", new["generation"] != old["generation"])
            client.targets_reserve(_sel(old), error=0x191)
        finally: agent2.close()
    h.results["topology_loopback_probe_agent"] = "PASS"


def case_topology_remote_sim_agent(h):
    ws, key_hex, secret = h.shared["ws"], secrets.token_hex(32), h.output / "sim.key"
    secret.write_text(key_hex + "\n", encoding="utf8")
    sim = sim_agent.SimProbeAgent("remote-sim-host", key_hex, h.trace)
    tgt = h.output / "sim_targets.json"
    _write_targets(tgt, "agent", "remote-sim-host", boards=SIM_BOARDS, host="127.0.0.1", port=sim.port, secret_file=str(secret.resolve()))
    try:
        with _served_client(h, "remote_sim", tgt, ws) as (_, client):
            _sim_flash(h, client, ws, check_uart=True); e1 = _find(client.targets_list(), "fpb-ra8e1"); client.targets_reserve(_sel(e1))
            sim.set_connected("fpb-ra8e1", False); lost = _find(client.targets_list(), "fpb-ra8e1")
            h.check("SimProbeAgent unplug drops lease", (lost["target"]["connection"], lost["reserved"]), ("disconnected", False))
            client.targets_perform(_sel(e1), "registers", error=0x191)
            sim.set_connected("fpb-ra8e1", True); back = _find(client.targets_list(), "fpb-ra8e1")
            client.targets_reserve(_sel(back)); client.targets_release()
    finally: sim.close()
    h.results["topology_remote_sim_agent"] = "PASS"


def case_emulate_then_flash_sim(h):
    parity.run_sim_parity(h, _write_targets, SIM_BOARDS, _served_client, _find, _sel)


CASES = (case_toolchain_and_offline_builds, case_project_debug_and_failures, case_competing_and_unplug,
         case_topology_local_fake_jlink, case_topology_loopback_probe_agent, case_topology_remote_sim_agent,
         case_emulate_then_flash_sim)
