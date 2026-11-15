"""Independent assertions for the public read-only toolchain planning contract."""
import json
from pathlib import Path

from archive import PINS

BOARDS = {"ra8d2": "EK-RA8D2", "ra8p1": "exact board/part must be selected by the project",
          "fpb-ra8e1": "RTK7FPA8E1S00001BE", "fpb-ra4t1": "RTK7FPA4T1S00001BE",
          "grove-vision-ai-v2": "101021112"}


def call(h, host, target, *flags, invalid=False):
    result = h.command([str(h.emulator), "toolchain", "plan", host, target, *flags], cwd=h.plan_scratch)
    if invalid:
        h.equal("invalid plan explicitly refuses", result.returncode != 0, True)
        return None
    h.equal("plan exit", result.returncode, 0)
    value = json.loads(result.stdout)
    h.record("plan", host=host, target=target, flags=flags, value=value)
    return value


def common(h, value, host, target, offline):
    h.equal("manifest version", value["manifest_version"], 1)
    expected = dict(PINS[host], host=host, version="0.17.0")
    h.equal("independently pinned complete compiler archive", value["pinned_baseline"], expected)
    h.equal("target ID", value["target"]["id"], target)
    h.equal("board inventory identity", value["target"]["board"], BOARDS[target])
    h.equal("offline flag records intent", value["offline"], offline)
    h.require("plan refuses installed/readiness claim", "not probed" in value["availability"] and "does not claim" in value["availability"])
    for key, words in {"build_gate": ("dependencies", "SDK"), "debug_gate": ("ELF/source", "probe"),
                       "flash_gate": ("blocked", "image", "licensed", "USB", "reservation"),
                       "npu_gate": ("separate", "no universal")}.items():
        h.require(key + " preserves limitations", all(word in value[key] for word in words))
    h.require("explicit override not authenticated by archive digest", "does not authenticate" in value["override_verification"])
    h.require("production provisioning explicitly deferred", "1286" in value["policy"]["provisioning"])
    for key in ("sdk", "probe", "image_tools", "npu_tools"):
        h.require("target-specific " + key + " inventory", bool(value["target"][key]))
    if target == "grove-vision-ai-v2":
        h.equal("RA FSP reference cannot imply Grove compatibility", value["ra_sdk_reference"], None)
        h.require("Grove vendor GNU/make dependencies explicit", all(w in value["target"]["sdk"] for w in ("Himax", "Arm GNU", "make")))
        h.require("Grove image and transport tools explicit", all(w in value["target"]["image_tools"] for w in ("we2", "xmodem", "serial")))
    else:
        h.equal("RA SDK redistribution not authorized", value["ra_sdk_reference"]["managed_eligible"], False)
    if target in ("ra8p1", "grove-vision-ai-v2"):
        h.require("NPU tooling separately required", "Ethos-U55" in value["target"]["npu_tools"] and "not provisioned" in value["target"]["npu_tools"])


def run(h):
    h.plan_scratch = h.output / "plan invocation sandbox"
    h.plan_scratch.mkdir()
    for host in PINS:
        for target in BOARDS:
            for offline in (False, True):
                value = call(h, host, target, *( ["--offline"] if offline else []))
                common(h, value, host, target, offline)
                h.equal("default managed compiler not claimed installed", value["compiler_source"], "managed_required")
                h.equal("unconfigured compiler path", value["compiler_path"], "")
        project = "C:/future/project/zig.exe" if host.endswith("windows") else "/future/project/zig"
        backend = "C:/future/backend/zig.exe" if host.endswith("windows") else "/future/backend/zig"
        cache = "C:/future/cache" if host.endswith("windows") else "/future/cache"
        value = call(h, host, "ra8d2", "--backend-zig", backend, "--project-zig", project)
        h.equal("project override precedes backend", (value["compiler_source"], value["compiler_path"]), ("project_override", project))
        value = call(h, host, "ra8d2", "--project-zig", project, "--backend-zig", "invalid-losing-override")
        h.equal("valid winning override does not inspect losing executable", value["compiler_path"], project)
        value = call(h, host, "ra8d2", "--backend-zig", backend)
        h.equal("explicit backend override", (value["compiler_source"], value["compiler_path"]), ("backend_override", backend))
        value = call(h, host, "ra8d2", "--cache-root", cache, "--offline")
        expected = cache + "/zig/0.17.0/" + host + "/" + PINS[host]["sha256"] + "/" + PINS[host]["executable"]
        h.equal("managed cache path is host/version/digest qualified", value["compiler_path"], expected)
        call(h, host, "ra8d2", "--project-zig", "relative/zig", "--backend-zig", backend, invalid=True)
        for flag in ("--project-zig", "--backend-zig", "--cache-root"):
            call(h, host, "ra8d2", flag, "relative/zig", invalid=True)
            call(h, host, "ra8d2", flag, "", invalid=True)
            call(h, host, "ra8d2", flag, cache, flag, cache, invalid=True)
        for flags in (("--unknown", "value"), ("--offline", "--offline"), ("--project-zig",),
                      ("--project-zig", project, "--project-zig", project)):
            call(h, host, "ra8d2", *flags, invalid=True)
    for path in ("/tools/zig.exe", "\\tools\\zig.exe", "C:tools\\zig.exe"):
        call(h, "x86_64-windows", "ra8d2", "--project-zig", path, invalid=True)
    unc = "\\\\server\\share\\zig.exe"
    h.equal("remote Windows UNC grammar", call(h, "x86_64-windows", "ra8d2", "--backend-zig", unc)["compiler_path"], unc)
    for host in ("aarch64-linux", "unknown"):
        call(h, host, "ra8d2", invalid=True)
    call(h, "x86_64-linux", "unknown-target", invalid=True)
    for tail in (("toolchain", "plan"), ("toolchain", "plan", "x86_64-linux")):
        result = h.command([str(h.emulator), *tail], cwd=h.plan_scratch)
        h.equal("missing required plan arguments refuse", result.returncode != 0, True)
    h.equal("plan invocation creates no workspace/tool directories", list(h.plan_scratch.iterdir()), [])
