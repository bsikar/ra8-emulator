"""Fresh dependency-free builds and public DAP source assertions."""
import hashlib
import os
from pathlib import Path
import shutil
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools/source_conformance"))
import regression as source_regression
from emission import assert_emission

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


class Case:
    def __init__(self, h):
        self.h = h
        self.result = dict(processes=[])

    def record(self, name, **values):
        self.h.record("dap_" + name, **values)

    def equal(self, name, expected, actual):
        self.h.equal(name, actual, expected)

    def require(self, name, condition, detail=None):
        self.h.require(name, condition, detail)


def debug(h, elf, source):
    case = Case(h)
    previous = dict(os.environ)
    try:
        os.environ.clear()
        os.environ.update(h.env)
        assert_emission(case, elf, source)
        source_regression.run(h.emulator, elf, source, case, h.deadline)
    finally:
        os.environ.clear()
        os.environ.update(previous)
        h.processes.extend(case.result["processes"])


def run(h, compiler):
    project = h.output / "new source project"
    project.mkdir()
    for name in ("conformance.zig", "machine.zig", "link.ld"):
        shutil.copyfile(REPO / "tests/fixtures/debug" / name, project / name)
    (project / "build.zig").write_text(BUILD, encoding="utf8")
    sources = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in project.iterdir()}
    h.record("source_project", hashes=sources)
    empty_packages = h.output / "empty package directory"
    empty_packages.mkdir()
    for name, offline in (("fresh", False), ("local-package-only", True)):
        cache, global_cache = h.output / (name + " cache"), h.output / (name + " global cache")
        prefix = h.output / (name + " prefix")
        h.require("both build caches start absent", not cache.exists() and not global_cache.exists())
        command = [str(compiler), "build", "-j1", "--color=off", "--cache-dir", str(cache),
                   "--prefix", str(prefix)]
        if offline:
            command += ["--system", str(empty_packages)]
        h.record("fresh_compiler_caches", local_cache=cache, global_cache=global_cache,
                 mechanism="ZIG_LOCAL_CACHE_DIR and ZIG_GLOBAL_CACHE_DIR; explicit --cache-dir")
        h.env["ZIG_GLOBAL_CACHE_DIR"] = str(global_cache)
        h.env["ZIG_LOCAL_CACHE_DIR"] = str(cache)
        try:
            result = h.command(command, cwd=project, timeout=120)
        finally:
            h.env.pop("ZIG_GLOBAL_CACHE_DIR")
            h.env.pop("ZIG_LOCAL_CACHE_DIR")
        h.equal(name + " actual compiler exit", result.returncode, 0)
        elf = prefix / "bin/fresh.elf"
        data = elf.read_bytes()
        h.equal("fresh ELF magic", data[:4], b"\x7fELF")
        h.equal("fresh ELF ARM machine", int.from_bytes(data[18:20], "little"), 40)
        h.record("firmware", mode=name, path=elf, sha256=hashlib.sha256(data).hexdigest(), compiler=compiler)
        debug(h, elf, project / "machine.zig")
        h.equal("copied source bytes unchanged", {file: hashlib.sha256((project / file).read_bytes()).hexdigest() for file in sources}, sources)
    h.equal("local package lookup directory remains empty", list(empty_packages.iterdir()), [])
