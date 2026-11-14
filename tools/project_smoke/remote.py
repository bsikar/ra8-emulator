"""Actual Windows RPC/DAP clients controlling an owned shared Mac server over SSH."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import sys
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run as local_runner
import rpc
import layout
from remote_transport import Controller, Tunnel
from remote_checks import fetch, build, debug


def execute(h, args):
    h.controller = Controller(h, args)
    h.server = h.controller.ready["server"]
    h.check("actual wire client runs on Windows", platform.system(), "Windows")
    h.check("actual server runs on Darwin", h.server["system"], "Darwin")
    h.check("actual server is Apple Silicon", h.server["machine"], "arm64")
    h.check("explicit server compiler version", h.server["zig_version"], "0.17.0")
    h.check("Mac project root distinct from Windows source root", h.server["project_root"].startswith("/Users/"), True)
    h.rpc_tunnel = Tunnel(h, args.ssh, h.server["rpc_port"])
    h.rpc = rpc.Client(h.rpc_tunnel.port, h.trace, h.deadline)
    h.check("remote project capability", bool(h.rpc.caps & (1 << 18)), True)
    config = fetch(h, "project.json", h.output / "remote-config.json")
    h.config_sha = hashlib.sha256(config).hexdigest()
    h.check("remote config read over RPC matches owned server config", h.config_sha, h.server["config_sha256"])
    parsed = json.loads(config)
    h.project_config = parsed
    h.check("client-only root in remote config", parsed["source_mappings"][0]["client"], "C:/client-only/project")
    h.rpc.open_project()
    h.rpc.start(error=2)
    h.sources = h.output / "RPC source snapshot"
    h.sources.mkdir()
    names = {entry["name"] for entry in h.rpc.listing()[0]}
    expected = {"conformance.zig", "machine.zig", "link.ld", "build.zig", "owned_wait.py"}
    h.check("Windows receives complete remote source set", names, expected)
    for name in sorted(names):
        fetch(h, name, h.sources / name)
    h.revision = layout.revision(h.sources)
    before = h.rpc.stat(".ra8-builds")
    h.controller.request("root_guard")
    try:
        h.check("remote root guard starts before any build store exists", before, bytes(25))
        for kind in ("missing", "directory"):
            if kind == "directory":
                h.controller.request("root_guard_directory")
            began = time.monotonic()
            h.rpc.build_project(error=0x172)
            h.check("Windows observes immediate remote root-build refusal: " + kind, time.monotonic()-began < 3, True)
            h.check("remote root guard creates no build job: " + kind, h.rpc.stat(".ra8-builds"), before)
            h.check("remote valid ancestor never executed: " + kind, h.rpc.stat("parent-build-executed"), bytes(25))
    finally:
        h.controller.request("root_guard_restore")
    h.check("remote root build restored via RPC bytes", fetch(h, "build.zig"), (h.sources / "build.zig").read_bytes())
    h.rpc.close_project()
    h.check("remote root guard close restores base", h.rpc.stat("alpha.txt")[0], 1)
    h.rpc.open_project()
    first, receipt, value = build(h)
    debug(h, receipt, active_source=True)
    for kind, error in (("config", "ProjectConfigChanged"), ("artifact", "ArtifactChanged")):
        h.controller.request("mutate", kind=kind, artifact=value["artifact"])
        try:
            if kind == "config":
                h.rpc.prepare(first, error=0x174)
            debug(h, receipt, error=error)
        finally:
            h.controller.request("restore")
    h.controller.request("mutate", kind="syntax")
    try:
        failed = h.rpc.build_project()
        result = h.rpc.finish(failed, timeout=270)
        h.check("actual remote syntax build fails", result["state"], "failed")
        h.check("failed remote build cannot publish artifact", result["artifact"], "")
        h.rpc.prepare(failed, error=0x173)
        h.rpc.prepare(first, error=0x171)
        debug(h, receipt, error="SourceChanged")
    finally:
        h.controller.request("restore")
    second, next_receipt, next_value = build(h)
    h.check("remote rebuild unique artifact", next_value["artifact"] != value["artifact"], True)
    h.rpc.prepare(first, error=0x171)
    debug(h, next_receipt)
    h.rpc.close_project()
    h.check("remote close restores base workspace", h.rpc.stat("alpha.txt")[0], 1)
    h.rpc.open_project()
    h.rpc.prepare(second, error=0x171)
    h.rpc.close_project()
    h.check("remote reopen/close restores base again", h.rpc.stat("alpha.txt")[0], 1)


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("ssh", "server-worktree", "server-output", "server-zig"):
        parser.add_argument("--"+key, required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()
    if sys.flags.optimize or not 0 < args.timeout <= 600:
        parser.error("assertions and bounded timeout<=600 required")
    return args


def main():
    args = arguments()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    h = local_runner.workspace_evidence.Harness(output, args.timeout)
    h.ssh, h.tunnels, h.remote_dap, h.receipts = args.ssh, [], [], []
    summary = dict(status="FAIL", client=dict(system=platform.system(), machine=platform.machine(), python=platform.python_version()),
                   physical_flash="NOTRUN", remote_controller_clients="NONE: wire clients execute on Windows only")
    started = time.monotonic()
    try:
        execute(h, args)
    except Exception as error:
        summary["error"] = h.sanitize(error)
        h.trace(dict(type="exception", traceback=traceback.format_exc()))
    finally:
        try:
            if hasattr(h, "rpc"):
                h.rpc.close()
            if hasattr(h, "rpc_tunnel"):
                h.rpc_tunnel.close()
            if hasattr(h, "controller"):
                summary["controller_cleanup"] = h.controller.close()
        except Exception as error:
            summary["cleanup_error"] = h.sanitize(error)
            h.trace(dict(type="cleanup_error", traceback=traceback.format_exc()))
        if hasattr(h, "server"):
            summary["server"] = h.server
        summary.update(assertions=h.assertions, tunnels=h.tunnels, dap_cleanup=h.remote_dap,
                       receipts=h.receipts, elapsed_seconds=round(time.monotonic()-started, 3))
        if "error" not in summary and "cleanup_error" not in summary:
            final = summary["controller_cleanup"]["remote_cleanup"]
            healthy = final["binary_sha256"] == h.server["binary_sha256"] and final["head"] == h.server["head"] and final["git_status"] == h.server["git_status"]
            for process in final["cleanup"]:
                healthy = healthy and process["listener_closed"]
                if process["kind"] == "dap":
                    healthy = healthy and process["exit_code"] == 0 and process["reaped"] and not process["forced"]
                else:
                    healthy = healthy and process["exit_code"] == 0 and process["owned_child_reaped"] and process["method"] == "graceful_signal"
            healthy = healthy and all(t["reaped"] and t["listener_closed"] for t in h.tunnels)
            if healthy:
                summary["status"] = "PASS"
        (output / "summary.json").write_text(json.dumps(h.clean(summary), indent=2)+"\n", encoding="utf8")
        h.transcript.close()
    print(json.dumps(h.clean(summary)))
    return int(summary["status"] != "PASS")


if __name__ == "__main__":
    raise SystemExit(main())
