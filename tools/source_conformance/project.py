"""Dependency-free real Zig build with isolated local and global caches."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

from regression import ROOT

BUILD = '''const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .thumb, .os_tag = .freestanding,
        .abi = .eabihf, .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m85 } });
    const exe = b.addExecutable(.{ .name = "fresh.elf", .root_module = b.createModule(.{
        .root_source_file = b.path("conformance.zig"), .target = target, .optimize = .Debug,
        .strip = false, .omit_frame_pointer = false, .sanitize_c = .off }) });
    exe.setLinkerScript(b.path("link.ld"));
    exe.entry = .{ .symbol_name = "Reset_Handler" };
    exe.link_function_sections = true;
    exe.link_gc_sections = true;
    b.installArtifact(exe);
}
'''


def command(argv, cwd, environment, output, case, deadline):
    forced = False
    out_path, err_path = output / "compiler.stdout.log", output / "compiler.stderr.log"
    case.record("compiler_spawn", argv=argv, cwd=str(cwd), caches={key: environment[key]
                for key in ("ZIG_LOCAL_CACHE_DIR", "ZIG_GLOBAL_CACHE_DIR")})
    with out_path.open("xb") as out, err_path.open("xb") as err:
        child = subprocess.Popen(argv, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
                                 stdout=out, stderr=err, start_new_session=os.name != "nt")
        try:
            child.wait(timeout=max(0.001, min(180, deadline-time.monotonic())))
        except subprocess.TimeoutExpired:
            forced = True
            if os.name == "nt":
                taskkill = Path(os.environ["SystemRoot"]) / "System32/taskkill.exe"
                subprocess.run([str(taskkill), "/PID", str(child.pid), "/T", "/F"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            else:
                os.killpg(child.pid, signal.SIGKILL)
            child.kill()
            child.wait(timeout=5)
    state = dict(exit_status=child.returncode, reaped=child.poll() is not None, forced_cleanup=forced)
    case.record("compiler_exit", **state)
    for path in (out_path, err_path):
        case.require("bounded compiler log", path.stat().st_size <= 2_000_000)
        path.write_text(case.evidence.clean(path.read_text(encoding="utf8", errors="replace")), encoding="utf8")
    case.require("compiler reaped without forced cleanup", state["reaped"] and not forced)
    case.equal("compiler succeeds", 0, child.returncode)


def build(zig, output, case, deadline):
    project = output / "fresh source project with spaces"
    project.mkdir()
    for name in ("conformance.zig", "machine.zig", "link.ld"):
        shutil.copyfile(ROOT / "tests/fixtures/debug" / name, project / name)
    (project / "build.zig").write_text(BUILD, encoding="utf8")
    local, global_cache = output / "fresh local cache", output / "fresh global cache"
    case.require("fresh build and global caches absent", not local.exists() and not global_cache.exists())
    environment = dict(os.environ)
    for key in list(environment):
        if key.upper().startswith("ZIG"):
            environment.pop(key)
    environment.update(ZIG_LOCAL_CACHE_DIR=str(local), ZIG_GLOBAL_CACHE_DIR=str(global_cache))
    prefix = output / "fresh install prefix"
    command([str(zig), "build", "-j1", "--color=off", "--cache-dir", str(local), "--prefix", str(prefix)],
            project, environment, output, case, deadline)
    return prefix / "bin/fresh.elf", project / "machine.zig"
