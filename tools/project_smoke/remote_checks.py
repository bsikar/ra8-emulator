"""Assertions made on Windows from actual RPC bytes and forwarded DAP traffic."""
import hashlib
import json
from pathlib import Path

import dap
from remote_transport import Tunnel


def fetch(h, path, destination=None):
    data, offset, token = bytearray(), 0, None
    while True:
        current, eof, chunk = h.rpc.read(path, offset, 131072)
        if token is None:
            token = current
        h.check("remote ranged read version stable", current, token)
        data.extend(chunk)
        if len(data) > 2_000_000:
            raise AssertionError("remote fixture read byte bound")
        if eof:
            break
        if not chunk:
            raise AssertionError("remote ranged read stalled")
        offset += len(chunk)
    value = bytes(data)
    h.trace(dict(type="remote_rpc_bytes", path=path, bytes=len(value), sha256=hashlib.sha256(value).hexdigest()))
    if destination is not None:
        destination.write_bytes(value)
    return value


def build(h):
    job = h.rpc.build_project()
    result = h.rpc.finish(job, timeout=270)
    h.check("actual Mac project compiler succeeded", result["state"], "succeeded")
    path = h.rpc.prepare(job)
    receipt = json.loads(fetch(h, path, h.output / f"receipt-{job}.json"))
    record = json.loads(fetch(h, receipt["directory"] + "/result.json", h.output / f"result-{job}.json"))
    h.check("remote original result equals streamed terminal", record, result)
    selected = next(item for item in h.project_config["recipes"] if item["name"] == receipt["recipe"])
    arguments = [h.server["zig_path"], "build", "-j1", "--color=off", "--prefix", receipt["directory"] + "/out", "--build-file", "build.zig"]
    if selected.get("step", ""):
        arguments.append(selected["step"])
    arguments.extend(json.loads(selected["options"]))
    h.check("Windows verifies exact Mac project argv pins root build file", record["argv"], arguments)
    h.check("remote receipt config SHA from Windows RPC bytes", receipt["config_sha256"], h.config_sha)
    h.check("remote receipt ID", receipt["build_id"], job)
    h.check("remote target and recipe", (receipt["target"], receipt["recipe"]), ("ra8d2", "debug"))
    for field in ("directory", "artifact", "artifact_sha256", "source_sha256", "compiler", "compiler_version"):
        h.check("remote receipt binds original " + field, receipt[field], record[field])
    h.check("remote compiler is explicit Mac compiler", receipt["compiler"], h.server["zig_path"])
    h.check("remote compiler version", receipt["compiler_version"], "0.17.0")
    h.check("remote source revision independently computed on Windows", receipt["source_sha256"], h.revision)
    elf_path = h.output / f"remote-{job}.elf"
    elf = fetch(h, receipt["artifact"], elf_path)
    h.check("remote actual ELF+ARM header", (elf[:4], int.from_bytes(elf[18:20], "little")), (b"\x7fELF", 40))
    h.check("remote ELF SHA computed by Windows", hashlib.sha256(elf).hexdigest(), receipt["artifact_sha256"])
    h.oracle = dap.generate(elf_path, h.sources / "machine.zig")
    h.trace(dict(type="independent_windows_oracle", oracle=h.oracle))
    h.receipts.append(dict(path=path, value=receipt))
    return job, path, receipt


def debug(h, receipt, error=None, active_source=False):
    endpoint = h.controller.request("dap")
    tunnel, peer = None, None
    try:
        tunnel = Tunnel(h, h.ssh, endpoint["port"])
        peer = dap.module.Client(tunnel.port, dap.Case(h), 5, h.deadline)
        peer.request("initialize", {"adapterID": "windows-client-mac-server", "pathFormat": "path"})
        if error is not None:
            response = peer.request("launch", {"program": receipt}, success=False)
            h.check("cross-host rejected launch exact reason", response["message"], error)
            h.check("cross-host rejected launch not attached", peer.request("threads", success=False)["message"], "NotAttached")
        else:
            peer.request("launch", {"program": receipt, "stopOnEntry": True})
            peer.event("initialized")
            peer.request("configurationDone")
            peer.event("stopped")
            h.check("cross-host known entry", int(dap.frame(peer)["instructionPointerReference"], 0), h.oracle["entry"])
            peer.request("setInstructionBreakpoints", {"breakpoints": [{"instructionReference": hex(h.oracle["ready"])}]})
            peer.request("continue", {"threadId": 1});peer.event("stopped")
            frame = dap.frame(peer)
            scopes = peer.request("scopes", {"frameId": frame["id"]})["body"]["scopes"]
            reference = next(s["variablesReference"] for s in scopes if s["name"] == "Registers")
            registers = {v["name"]: int(v["value"], 0) for v in peer.request("variables", {"variablesReference": reference})["body"]["variables"]}
            for name, value in h.oracle["ready_registers"].items():h.check("cross-host known register " + name, registers[name], value)
            peer.request("setInstructionBreakpoints", {"breakpoints": []})
            peer.request("stepIn", {"threadId": 1, "granularity": "instruction"});peer.event("stopped")
            h.check("cross-host instruction step exact PC", int(dap.frame(peer)["instructionPointerReference"], 0), h.oracle["ready"]+2)
            source = "C:/client-only/project/machine.zig"
            args = dict(source=dict(path=source), breakpoints=[dict(line=60)])
            refused = peer.request("setBreakpoints", dict(source=dict(path="C:/wrong-root/machine.zig"), breakpoints=[dict(line=60)]), success=False)
            h.check("cross-host wrong client root explicitly refused", refused["message"], "SourceUnavailable")
            points = peer.request("setBreakpoints", args)["body"]["breakpoints"]
            h.check("Windows client-only source breakpoint verified on Mac", [p["verified"] for p in points], [True])
            peer.request("continue", {"threadId": 1});peer.event("stopped")
            frame = dap.frame(peer)
            h.check("Mac stack exposes Windows client-only path", frame["source"]["path"].replace("\\", "/"), source)
            h.check("cross-host source line+independent address", (frame["line"], int(frame["instructionPointerReference"], 0)), (60, h.oracle["source"]["address"]))
            h.trace(dict(type="cross_host_source_frame", frame=frame))
            if active_source:
                h.controller.request("mutate", kind="source")
                try:
                    h.check("cross-host active source revision refusal", peer.request("setBreakpoints", args, success=False)["message"], "SourceChanged")
                    h.check("cross-host stale source stack refusal", peer.request("stackTrace", {"threadId": 1}, success=False)["message"], "SourceChanged")
                finally:h.controller.request("restore")
        peer.request("disconnect");peer.event("terminated")
    finally:
        if peer is not None:peer.close()
        cleanup = h.controller.request("collect")
        h.remote_dap.append(cleanup)
        h.check("owned Mac DAP exited zero", cleanup["exit_code"], 0)
        h.check("owned Mac DAP reaped unforced and listener closed", cleanup["reaped"] and not cleanup["forced"] and cleanup["listener_closed"], True)
        if tunnel is not None:tunnel.close()
