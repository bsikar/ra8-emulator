"""Exercise public production setup, offline builds and integrity refusal on clean hosts."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import queue
import threading
import shutil
import stat
import subprocess
import sys
import time
import traceback

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/toolchain_smoke"))
from run import Harness
import archive
import build_debug
for name in ("client", "server", "protocol", "backend"):
    sys.modules.pop(name, None)
sys.path.insert(0, str(ROOT / "tools/project_smoke"))
import rpc as project_rpc


class ProvisionClient(project_rpc.Client):
    def frame(self, timeout=120):
        # Opening a managed project authenticates the full distribution tree.
        return super().frame(timeout=timeout)


def cli(h, host, cache, command, *extra, expect=0, timeout=None):
    argv = [str(h.emulator), "toolchain", command, host, "ra8d2", "--cache-root", str(cache), *map(str, extra)]
    limit = h.deadline - time.monotonic() if timeout is None else timeout
    result = h.command(argv, timeout=limit)
    h.equal(command + " exit", result.returncode, expect)
    return json.loads(result.stdout) if expect == 0 else result


def project(h, compiler=None, offline=False):
    folder = h.output / "source project with spaces"
    folder.mkdir(exist_ok=True)
    for name in ("conformance.zig", "machine.zig", "link.ld"):
        shutil.copyfile(ROOT / "tests/fixtures/debug" / name, folder / name)
    (folder / "build.zig").write_text(build_debug.BUILD, encoding="utf8")
    config = dict(version=1, root=".", target="ra8d2", recipes=[dict(name="debug", artifact="bin/fresh.elf")])
    if compiler:
        config["compiler"] = str(compiler)
    (folder / "project.json").write_text(json.dumps(config), encoding="utf8")
    # Marker is deliberately not an SDK/package closure: this sample has no dependencies.
    if offline:
        (folder / "build.zig.zon").write_text('.{ .name = .offline_sample, .version = "0.0.0", .fingerprint = 0x8c491fe1c848acda, .paths = .{""} }', encoding="utf8")
    return folder


def build(h, folder, cache, compiler=None):
    argv = [str(h.emulator), "project", "build", str(folder), "project.json", "debug",
            "--toolchain-cache", str(cache)]
    if compiler:
        argv += ["--zig", str(compiler)]
    result = h.command(argv, timeout=h.deadline - time.monotonic())
    h.equal("public project build exit", result.returncode, 0)
    response = json.loads(result.stdout)
    receipt = json.loads(inside(folder, response["receipt"]).read_text(encoding="utf8"))
    record = json.loads((inside(folder, receipt["directory"]) / "result.json").read_text(encoding="utf8"))
    h.equal("build cleanup complete", record["cleanup"], "complete")
    h.equal("compiler executable digest measured", record["compiler_sha256"], archive.sha256(Path(receipt["compiler"])))
    data = inside(folder, receipt["artifact"]).read_bytes()
    h.equal("real ARM ELF", data[:4], b"\x7fELF")
    h.equal("ARM ELF machine", int.from_bytes(data[18:20], "little"), 40)
    return receipt


def corruption(h, host, cache, compiler):
    victim = compiler.parent / "lib/std/std.zig"
    data, mode = victim.read_bytes(), victim.stat().st_mode
    victim.chmod(mode | stat.S_IWUSR)
    try:
        victim.write_bytes(data.replace(b"pub", b"xxx", 1))
        failed = cli(h, host, cache, "doctor", "--offline", expect=2)
        h.require("mutated installed library rejected", "CacheIntegrityMismatch" in failed.stderr)
        result = h.command([str(h.emulator), "project", "build", str(h.project), "project.json", "debug",
                            "--toolchain-cache", str(cache)], timeout=180)
        h.equal("actual build refuses corrupt managed generation", result.returncode, 1)
        h.require("public build integrity diagnostic", "CacheIntegrityMismatch" in result.stderr)
    finally:
        victim.write_bytes(data)
        victim.chmod(mode)


def concurrency(h, host, cache):
    argv = [str(h.emulator), "toolchain", "setup", host, "ra8d2", "--cache-root", str(cache), "--offline"]
    processes, logs = [], []
    try:
        for index in range(2):
            out = (h.output / f"concurrent-{index}.log").open("wb")
            logs.append(out)
            processes.append(subprocess.Popen(argv, env=h.env, stdin=subprocess.DEVNULL,
                                              stdout=out, stderr=subprocess.STDOUT))
        exits = [p.wait(timeout=min(240, h.deadline-time.monotonic())) for p in processes]
        h.equal("concurrent setup admits exactly one writer", sorted(exits), [0, 2])
    finally:
        for p in processes:
            if p.poll() is None:
                p.kill()
            p.wait(timeout=10)
        for log in logs:
            log.close()
    outputs = [(h.output / f"concurrent-{i}.log").read_text(encoding="utf8", errors="replace") for i in range(2)]
    h.require("competing writer got an OS lease refusal", any("ProvisionBusy" in text for text in outputs))


def interrupted(h, host, source, compiler):
    cache = h.output / "interrupted private cache"
    refused = cli(h, host, cache, "setup", "--offline", expect=2)
    h.require("setup prepares a private cache before requiring an archive", "OfflineArchiveRequired" in refused.stderr)
    retained = cache / "previous verified generation"
    shutil.copytree(compiler.parent.parent, retained)
    previous = retained / Path(archive.PINS[host]["executable"])
    before = {name: archive.sha256(retained / name) for name in (".archive", ".manifest")}
    h.equal("retained compiler starts valid", h.command([str(previous), "version"]).returncode, 0)
    argv = [str(h.emulator), "toolchain", "setup", host, "ra8d2", "--cache-root", str(cache),
            "--archive", str(source), "--offline"]
    with (h.output / "interrupted.log").open("wb") as log:
        p = subprocess.Popen(argv, env=h.env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                             start_new_session=os.name != "nt")
        try:
            deadline = min(h.deadline, time.monotonic() + 60)
            while time.monotonic() < deadline and p.poll() is None:
                stages = list(cache.glob("zig/0.17.0/*/.stage-*"))
                if stages and any(path.is_file() for path in stages[0].iterdir()):
                    # Interrupt before any admission probe can run: .archive alone exists,
                    # before the distribution's 19k files have materialized.
                    if not (stages[0] / Path(archive.PINS[host]["executable"]).parts[0]).exists():
                        p.kill()
                        break
                time.sleep(0.001)
            else:
                raise AssertionError("could not interrupt staging before publication")
        finally:
            if p.poll() is None:
                p.kill()
            p.wait(timeout=10)
    h.equal("interruption preserves previous verified generation",
            {name: archive.sha256(retained / name) for name in before}, before)
    failed = cli(h, host, cache, "doctor", "--offline", expect=2)
    h.require("unpublished staging never resolves as compiler", "FileNotFound" in failed.stderr)
    restored = build(h, h.project, cache, previous)
    h.equal("retained compiler remains usable after interrupted setup", Path(restored["compiler"]), previous)



def overrides(h, cache, compiler):
    config_path = h.project / "project.json"
    original = config_path.read_text()
    config = json.loads(original)
    config["compiler"] = str(compiler)
    config_path.write_text(json.dumps(config))
    try:
        receipt = build(h, h.project, cache, h.output / "missing backend compiler")
        h.equal("project override wins invalid backend", Path(receipt["compiler"]), compiler)
    finally:
        config_path.write_text(original)
    wrong = h.output / ("wrong version.exe" if os.name == "nt" else "wrong version")
    shim = h.output / "wrong-version.zig"
    shim.write_text('const std = @import("std");\n'
                    'pub fn main(init: std.process.Init) !void {\n'
                    'try std.Io.File.stdout().writeStreamingAll(init.io, "0.16.0\\n"); }\n')
    compiled = h.command([str(compiler), "build-exe", str(shim), "-femit-bin=" + str(wrong)], timeout=240)
    h.equal("wrong-version executable builds", compiled.returncode, 0)
    result = h.command([str(h.emulator), "project", "build", str(h.project), "project.json", "debug",
                        "--toolchain-cache", str(cache), "--zig", str(wrong)], timeout=30)
    h.equal("actual project refuses incompatible external executable", result.returncode, 1)
    h.require("incompatible override version diagnostic", "CompilerVersionMismatch" in result.stderr)


def rpc_build(h, cache, compiler):
    argv = [str(h.emulator), "serve", "--workspace", str(h.project),
            "--build-toolchain-cache", str(cache), "--history", "off", "--listen", "tcp::0",
            str(ROOT / "tests/fixtures/console/echo.elf")]
    process = subprocess.Popen(argv, env=h.env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, encoding="utf8", errors="replace")
    lines = queue.Queue()
    log = (h.output / "managed-rpc-server.log").open("w", encoding="utf8")
    def read():
        for line in process.stdout:
            log.write(h.clean(line)); log.flush()
            lines.put(line)
    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    client = None
    try:
        ready = min(h.deadline, time.monotonic() + 180)
        while time.monotonic() < ready:
            if process.poll() is not None:
                raise AssertionError("managed RPC backend exited before listening")
            try:
                line = lines.get(timeout=0.1)
            except queue.Empty:
                continue
            if line.startswith("serve: listening on tcp:"):
                port = int(line.rsplit(":", 1)[1]); break
        else:
            raise TimeoutError("managed RPC listener deadline")
        client = ProvisionClient(port, lambda value: h.record("rpc", value=value), h.deadline)
        client.open_project()
        job = client.build_project()
        record = client.finish(job, timeout=240)
        h.equal("actual managed RPC project build succeeds", record["state"], "succeeded")
        h.equal("RPC compiler admission selects managed path", Path(record["compiler"]), compiler)
        h.equal("RPC build compiler digest", record["compiler_sha256"], archive.sha256(compiler))
        h.equal("RPC build process cleanup complete", record["cleanup"], "complete")
        client.close_project()
    finally:
        if client is not None:
            client.close()
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(timeout=10)
            raise AssertionError("managed RPC backend required forced cleanup")
        reader.join(timeout=5)
        log.close()
    h.require("RPC backend reaped", process.poll() is not None)



def inside(folder, name):
    root = folder.resolve()
    candidate = (root / name).resolve()
    if not candidate.is_relative_to(root) or candidate == root or Path(name).is_absolute():
        raise ValueError("build receipt path leaves its source project")
    return candidate


def expected_compiler(cache, host):
    pin = archive.PINS[host]
    return cache / "zig/0.17.0" / host / pin["sha256"] / pin["executable"]


def save_state(h, args, cache, compiler):
    h.equal("baseline compiler has pinned cache layout", compiler.resolve(), expected_compiler(cache, args.host).resolve())
    value = dict(schema=1, host=args.host, cache="managed private cache with spaces",
                 compiler_sha256=archive.sha256(compiler), emulator_sha256=archive.sha256(h.emulator),
                 archive_sha256=archive.PINS[args.host]["sha256"])
    (h.output / "state.json").write_text(json.dumps(value, indent=2) + "\n", encoding="utf8")


def prior(h, args, evidence):
    evidence = evidence.resolve()
    summary = json.loads((evidence / "summary.json").read_text(encoding="utf8"))
    state = json.loads((evidence / "state.json").read_text(encoding="utf8"))
    h.equal("prior phase completed", (summary["status"], summary["phase"]), ("PASS", "baseline"))
    h.equal("prior host matches", (summary["host"], state["host"]), (args.host, args.host))
    h.equal("prior state schema", state["schema"], 1)
    h.equal("same backend under test", state["emulator_sha256"], archive.sha256(h.emulator))
    h.equal("prior cache archive identity", state["archive_sha256"], archive.PINS[args.host]["sha256"])
    h.equal("prior cache location", state["cache"], "managed private cache with spaces")
    cache = inside(evidence, state["cache"])
    expected = expected_compiler(cache, args.host).resolve()
    admitted = cli(h, args.host, cache, "doctor", "--offline")
    compiler = Path(admitted["compiler"]["compiler_path"])
    h.equal("prior compiler re-admitted at pinned path", compiler.resolve(), expected)
    h.equal("prior compiler digest unchanged", admitted["compiler"]["compiler_sha256"], state["compiler_sha256"])
    h.equal("prior managed selection", admitted["compiler"]["source"], "managed")
    h.record("prior_evidence", directory=evidence, compiler=compiler, archive_sha256=state["archive_sha256"])
    return cache, compiler


def baseline(h, args):
    pin = archive.PINS[args.host]
    source = args.archive.resolve()
    archive.verify(source, pin)
    cache = h.output / "managed private cache with spaces"
    missing = cli(h, args.host, cache, "doctor", "--offline", expect=2)
    h.require("empty offline cache identifies missing dependency", "FileNotFound" in missing.stderr)
    truncated = h.output / "incomplete archive"
    truncated.write_bytes(source.read_bytes()[:100])
    refused = cli(h, args.host, cache, "setup", "--archive", truncated, "--offline", expect=2)
    h.require("incomplete archive refused", "ArchiveSizeMismatch" in refused.stderr)
    corrupt = h.output / "corrupt same size archive"
    shutil.copyfile(source, corrupt)
    with corrupt.open("r+b") as stream:
        first = stream.read(1)
        stream.seek(0)
        stream.write(bytes([first[0] ^ 1]))
    refused = cli(h, args.host, cache, "setup", "--archive", corrupt, "--offline", expect=2)
    h.require("corrupt bytes refused before extraction", "ArchiveHashMismatch" in refused.stderr)
    installed = cli(h, args.host, cache, "setup", "--archive", source, "--offline")
    compiler = Path(installed["compiler"]["compiler_path"])
    h.equal("first offline install uses no network", installed["compiler"]["network_used"], False)
    h.require("installed library retained", (compiler.parent / "lib/std/std.zig").is_file())
    h.require("installed license retained", (compiler.parent / "LICENSE").is_file())
    h.require("full tree accounted", installed["compiler"]["verified_files"] > 19000)
    h.equal("compiler version", installed["compiler"]["compiler_version"], "0.17.0")
    h.project = project(h)
    receipt = build(h, h.project, cache)
    h.equal("actual project selects admitted compiler", Path(receipt["compiler"]).resolve(), compiler.resolve())
    # Setup/doctor APIs are offline by construction here. Clean PATH/package caches
    # prove no developer tools or package downloads are required by this sample.
    offline = cli(h, args.host, cache, "setup", "--offline")
    h.equal("offline cache reuse", offline["compiler"]["source"], "managed")
    h.equal("offline reuse never downloads", offline["compiler"]["network_used"], False)
    h.env["ZIG_GLOBAL_CACHE_DIR"] = str(h.output / "fresh offline global cache")
    h.env["ZIG_LOCAL_CACHE_DIR"] = str(h.output / "fresh offline local cache")
    build(h, h.project, cache)
    save_state(h, args, cache, compiler)


def rpc_phase(h, args):
    cache, compiler = prior(h, args, args.prior_evidence)
    h.project = project(h)
    explicit = cli(h, args.host, cache, "doctor", "--backend-zig", compiler, "--offline")
    h.equal("explicit override selected", explicit["compiler"]["source"], "backend_override")
    h.equal("override digest measured independently", explicit["compiler"]["compiler_sha256"], archive.sha256(compiler))
    build(h, h.project, cache, compiler)
    invalid = cli(h, args.host, cache, "doctor", "--project-zig", h.output / "missing compiler",
                  "--backend-zig", compiler, "--offline", expect=2)
    h.require("invalid winning override never falls back", "FileNotFound" in invalid.stderr)
    rpc_build(h, cache, compiler)
    overrides(h, cache, compiler)


def integrity_phase(h, args):
    cache, compiler = prior(h, args, args.prior_evidence)
    source = args.archive.resolve()
    archive.verify(source, archive.PINS[args.host])
    h.project = project(h)
    concurrency(h, args.host, cache)
    corruption(h, args.host, cache, compiler)
    interrupted(h, args.host, source, compiler)
    cli(h, args.host, cache, "doctor", "--offline")


def replay(h, args):
    cache, compiler = prior(h, args, args.offline_replay)
    h.env["ZIG_GLOBAL_CACHE_DIR"] = str(h.output / "empty offline global cache")
    h.env["ZIG_LOCAL_CACHE_DIR"] = str(h.output / "empty offline local cache")
    h.project = project(h, offline=True)
    receipt = build(h, h.project, cache)
    h.equal("isolated replay uses verified managed compiler", Path(receipt["compiler"]), compiler)
    h.env["ZIG_GLOBAL_CACHE_DIR"] = str(h.output / "second empty offline global cache")
    h.env["ZIG_LOCAL_CACHE_DIR"] = str(h.output / "second empty offline local cache")
    build(h, h.project, cache, compiler)
    h.record("network_isolation", mechanism="provided externally by runner", scope="these two real builds")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emulator", required=True, type=Path)
    parser.add_argument("--host", required=True, choices=archive.PINS)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--phase", choices=("baseline", "rpc", "integrity"), default="baseline")
    parser.add_argument("--prior-evidence", type=Path, help="completed baseline evidence for rpc/integrity")
    parser.add_argument("--offline-replay", type=Path, help="prior provisioning evidence; runner disables network")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()
    if sys.flags.optimize or not 0 < args.timeout <= 800:
        parser.error("assertions required; timeout must be positive and <=800")
    if args.offline_replay:
        if args.phase != "baseline" or args.archive or args.prior_evidence:
            parser.error("--offline-replay is separate from --phase/--archive/--prior-evidence")
    elif args.phase == "baseline":
        if args.archive is None or args.prior_evidence:
            parser.error("baseline requires --archive and no --prior-evidence")
    elif args.prior_evidence is None or (args.phase == "integrity" and args.archive is None):
        parser.error("rpc/integrity require --prior-evidence; integrity additionally requires --archive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    h = Harness(args.emulator.resolve(), output, args.timeout)
    summary = dict(status="FAIL", host=args.host, phase="offline-replay" if args.offline_replay else args.phase, production_provisioning="IMPLEMENTED_ZIG_BASELINE",
                   vendor_sdk_flash_driver_npu="UNSUPPORTED_POLICY_GATED", physical_flash="NOTRUN",
                   offline_scope="explicit offline API and dependency-free sample, not an OS firewall proof",
                   emulator_sha256=archive.sha256(h.emulator))
    try:
        if args.offline_replay:
            replay(h, args)
        else:
            {"baseline": baseline, "rpc": rpc_phase, "integrity": integrity_phase}[args.phase](h, args)
        summary["status"] = "PASS"
    except Exception as error:
        summary["error"] = str(error)
        traceback.print_exc()
    finally:
        summary.update(assertions=h.assertions, commands=h.commands)
        h.transcript.close()
        (output / "summary.json").write_text(json.dumps(h.clean(summary), indent=2), encoding="utf8")
    print(json.dumps(h.clean(summary)))
    return 0 if summary["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
