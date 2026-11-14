"""Public project lifecycle, immutable handoff and explicit failure scenarios."""
import json
from pathlib import Path
import time

import dap
import layout
import root_guard
from rpc import Client


def build(h):
    job = h.rpc.build_project()
    h.rpc.prepare(job + 999, error=0x171)
    result = h.rpc.finish(job)
    h.check("project build successful", result["state"], "succeeded")
    path = h.rpc.prepare(job)
    value = layout.receipt(h, path, job, result)
    return job, path, value


def root_build_guard(h):
    h.rpc.open_project()
    fixture = root_guard.Fixture(h.base, h.root, h.output)
    h.trace(dict(type="ancestor_build_negative_fixture", **fixture.metadata()))
    store = h.root / ".ra8-builds"
    before = {path.name for path in store.iterdir()} if store.exists() else set()
    try:
        h.check("root guard starts with no build jobs", before, set())
        for kind in ("missing", "directory"):
            if kind == "directory":
                fixture.child.mkdir()
            started = time.monotonic()
            h.rpc.build_project(error=0x172)
            h.check("invalid root build file refused immediately: " + kind, time.monotonic()-started < 3, True)
            after = {path.name for path in store.iterdir()} if store.exists() else set()
            h.check("root guard created no build job: " + kind, after, before)
            h.check("valid ancestor build never executed: " + kind, fixture.marker.exists(), False)
    finally:
        h.rpc.close_project()
        fixture.restore()
    h.check("root build restored byte-for-byte", fixture.child.read_bytes(), fixture.original)
    h.check("root guard close restores base workspace", h.rpc.stat("alpha.txt")[0], 1)


def lifecycle(h):
    h.check("project greeting capability", bool(h.rpc.caps & (1 << 18)), True)
    h.rpc.prepare(1, error=0x171)
    h.rpc.close_project(error=0x171)
    h.rpc.open_project()
    h.rpc.open_project(error=0x171)
    h.rpc.start(error=2)
    h.check("opened workspace is project child", h.rpc.stat("alpha.txt"), bytes(25))
    h.first_id, h.first_path, h.first_receipt = build(h)
    dap.run(h, h.first_path)
    h.rpc.close_project()
    h.check("close restores original workspace", h.rpc.stat("alpha.txt")[0], 1)
    h.rpc.open_project()
    h.rpc.completed.clear()
    h.rpc.outputs.clear()
    h.rpc.sequences.clear()
    h.rpc.prepare(h.first_id, error=0x171)
    h.current_id, h.current_path, h.current_receipt = build(h)
    h.check("reopen creates new unique artifact", h.current_receipt["artifact"] != h.first_receipt["artifact"], True)


def failed_and_rebuild(h):
    h.conformance.write_text("export fn Reset_Handler() noreturn { const broken = ; }\n")
    try:
        job = h.rpc.build_project()
        failed = h.rpc.finish(job)
        h.check("actual compiler failure status", failed["state"], "failed")
        h.check("failed build no artifact", failed["artifact"], "")
        h.rpc.prepare(job, error=0x173)
        h.rpc.prepare(h.current_id, error=0x171)
        dap.reject(h, h.current_path, "SourceChanged")
    finally:
        h.conformance.write_bytes(h.conformance_bytes)
    previous = h.current_receipt["artifact"]
    h.current_id, h.current_path, h.current_receipt = build(h)
    h.check("successful rebuild artifact unique", h.current_receipt["artifact"] != previous, True)
    dap.run(h, h.current_path)


def tampered_handoffs(h):
    receipt_path = h.root / h.current_path
    original = receipt_path.read_bytes()
    for field, value in (("build_id", h.current_id + 777), ("recipe", "slow"), ("artifact_sha256", "0" * 64)):
        changed = json.loads(original)
        changed[field] = value
        receipt_path.write_text(json.dumps(changed))
        try:
            dap.reject(h, h.current_path, "InvalidBuildReceipt")
        finally:
            receipt_path.write_bytes(original)
    result_path = h.root / h.current_receipt["directory"] / "result.json"
    result_bytes = result_path.read_bytes()
    original_arguments = json.loads(result_bytes)["argv"]
    unpinned = original_arguments[:6] + original_arguments[8:]
    for field, value in (("id", h.current_id + 1), ("step", "forged-step"), ("options", ["-Dforged=true"]), ("argv", unpinned)):
        changed = json.loads(result_bytes)
        changed[field] = value
        result_path.write_text(json.dumps(changed))
        try:
            dap.reject(h, h.current_path, "InvalidBuildReceipt")
        finally:
            result_path.write_bytes(result_bytes)
    elf = h.root / h.current_receipt["artifact"]
    data = elf.read_bytes()
    elf.write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
    try:
        dap.reject(h, h.current_path, "ArtifactChanged")
    finally:
        elf.write_bytes(data)
    h.machine.write_bytes(h.machine_bytes + b"\n// changed revision\n")
    try:
        dap.reject(h, h.current_path, "SourceChanged")
    finally:
        h.machine.write_bytes(h.machine_bytes)
    h.config_path.write_bytes(h.config_bytes + b"\n")
    try:
        dap.reject(h, h.current_path, "ProjectConfigChanged")
        h.rpc.build_project(error=0x174)
        h.rpc.prepare(h.current_id, error=0x174)
    finally:
        h.config_path.write_bytes(h.config_bytes)
    dap.reject(h, "../project.json", "InvalidPath")


def active_sources(h):
    for name, expected in (("edit", "SourceChanged"), ("missing", "SourceMissing"), ("config", "ProjectConfigChanged")):
        def mutate(h, peer, client_path):
            if name == "edit":
                h.machine.write_bytes(h.machine_bytes + b"\n// changed while debugging\n")
            elif name == "missing":
                h.machine.unlink()
            else:
                h.config_path.write_bytes(h.config_bytes + b"\n")
            try:
                response = peer.request("setBreakpoints", {"source": {"path": client_path}, "breakpoints": [{"line": 60}]}, success=False)
                h.check("active source mutation exact cause", response["message"], expected)
                response = peer.request("stackTrace", {"threadId": 1}, success=False)
                h.check("active stale stack explicitly fails", response["message"], expected)
            finally:
                h.machine.write_bytes(h.machine_bytes)
                h.config_path.write_bytes(h.config_bytes)
        dap.run(h, h.current_path, mutate)


def wait_ready(h):
    end = min(h.deadline, time.monotonic() + 30)
    while time.monotonic() < end:
        if (h.root / ".ra8-builds/project.ready").exists():
            return
        time.sleep(0.05)
    raise TimeoutError("project nested child readiness")


def watch_no_descendant(h):
    end = time.monotonic() + 5.5
    if end > h.deadline:
        raise TimeoutError("insufficient descendant proof budget")
    while time.monotonic() < end:
        h.check("closed project descendant cannot write marker", (h.root / ".ra8-builds/project.delayed").exists(), False)
        time.sleep(0.2)


def ownership(h):
    for disconnect in (False, True):
        (h.root / ".ra8-builds/project.ready").unlink(missing_ok=True)
        active = h.rpc.build_project("slow")
        wait_ready(h)
        h.rpc.prepare(active, error=0x171)
        if disconnect:
            h.rpc.close()
            h.rpc = Client(h.server.port, h.trace, h.deadline)
        else:
            h.rpc.close_project()
        h.check("ownership release restores base workspace", h.rpc.stat("alpha.txt")[0], 1)
        h.rpc.prepare(active, error=0x171)
        h.rpc.status(active, error=0x162)
        watch_no_descendant(h)
        h.rpc.open_project()
        h.rpc.completed.clear()
        h.rpc.outputs.clear()
        h.rpc.sequences.clear()


def cli_and_config(h):
    args = [str(h.emulator), "project", "build", str(h.base), "project.json", "debug", "--zig", str(h.zig)]
    result = h.command(args)
    h.check("direct CLI project build exit", result.returncode, 0)
    value = json.loads(result.stdout)
    h.check("direct CLI receipt JSON version", value["version"], 1)
    dap.run(h, value["receipt"])
    h.conformance.write_text("invalid syntax ;\n")
    try:
        result = h.command(args)
        h.check("direct CLI failed build nonzero", result.returncode != 0, True)
        h.check("direct CLI failed build no stdout receipt", result.stdout, "")
    finally:
        h.conformance.write_bytes(h.conformance_bytes)
    h.rpc.close_project()
    for change in (dict(version=999), dict(root="../escape"), dict(compiler="relative/zig")):
        h.config_path.write_text(json.dumps(dict(h.config, **change)))
        try:
            h.rpc.open_project(error=0x172)
        finally:
            h.config_path.write_bytes(h.config_bytes)
    h.config_path.write_text(json.dumps(dict(h.config, compiler=str(h.output / "missing-zig.exe"))))
    try:
        h.rpc.open_project()
        job = h.rpc.build_project()
        result = h.rpc.finish(job)
        h.check("missing explicit project compiler cannot fallback", result["state"], "failed")
        h.rpc.prepare(job, error=0x173)
        h.rpc.close_project()
    finally:
        h.config_path.write_bytes(h.config_bytes)
    h.config_path.write_text(json.dumps(dict(h.config, target="ra8p1")))
    try:
        result = h.command(args)
        h.check("other manifest target can build", result.returncode, 0)
        value = json.loads(result.stdout)
        dap.reject(h, value["receipt"], "UnsupportedProjectDebugTarget")
    finally:
        h.config_path.write_bytes(h.config_bytes)
    h.rpc.open_project()
    h.rpc.close_project()
    session = dap.Session(h, plain=h.fixture)
    try:
        session.peer.request("attach")
        session.peer.event("initialized")
        session.peer.request("configurationDone")
        session.peer.event("stopped")
        h.check("plain DAP still exposes CPU0", session.peer.request("threads")["body"]["threads"], [dict(id=1, name="CPU0")])
        session.disconnect()
    finally:
        session.close()


def dot_root(h):
    path = h.root / "in-root.json"
    path.write_text(json.dumps(dict(h.config, root=".")))
    prior = h.base
    try:
        args = [str(h.emulator), "project", "build", str(h.root), "in-root.json", "debug", "--zig", str(h.zig)]
        result = h.command(args)
        h.check("dot root builds with config inside hashed workspace", result.returncode, 0)
        value = json.loads(result.stdout)
        h.base, h.dap_config = h.root, "in-root.json"
        dap.run(h, value["receipt"])
    finally:
        h.base, h.dap_config = prior, "project.json"
        path.unlink()


CASES = (root_build_guard, lifecycle, failed_and_rebuild, tampered_handoffs, active_sources, ownership, cli_and_config, dot_root)
