"""Known real Zig project and independently computed input revision."""
import hashlib
import json
from pathlib import Path
import sys

SOURCE = "export fn Reset_Handler() noreturn {\n    while (true) {}\n}\n"
HELPER = '''import pathlib, subprocess, sys, time
mode, tag = sys.argv[1:]
base = pathlib.Path('.ra8-builds')
if mode == 'child':
    time.sleep(5)
    (base / (tag + '.delayed')).write_text('descendant escaped cleanup')
elif mode == 'long':
    subprocess.Popen([sys.executable, __file__, 'child', tag])
    (base / (tag + '.ready')).write_text('nested child started')
    print('LONG_READY', flush=True)
    time.sleep(20)
elif mode == 'delay':
    (base / (tag + '.ready')).write_text('compiler input revision already captured')
    print('DELAY_READY', flush=True)
    time.sleep(3)
elif mode in ('flood', 'limit'):
    for _ in range(1024 if mode == 'flood' else 18 * 1024):
        print('OUTPUT:' + 'x' * 1016, flush=True)
'''


def create(root):
    python = json.dumps(sys.executable.replace("\\", "/"))
    build = '''const std = @import("std");
pub fn build(b: *std.Build) void {
    const tag = b.option([]const u8, "tag", "isolated marker tag") orelse "default";
    const target = b.resolveTargetQuery(.{ .cpu_arch = .thumb, .os_tag = .freestanding,
        .abi = .eabihf, .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m85 } });
    const exe = b.addExecutable(.{ .name = "tiny.elf", .root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"), .target = target, .optimize = .Debug,
        .strip = false, .sanitize_c = .off }) });
    exe.entry = .{ .symbol_name = "Reset_Handler" };
    exe.setLinkerScript(b.path("link.ld"));
    b.installArtifact(exe);
    inline for (.{ "long", "flood", "limit", "delay" }) |mode| {
        const command = b.addSystemCommand(&.{ PYTHON, "helper.py", mode, tag });
        const step = b.step(mode, mode);
        step.dependOn(&command.step);
        if (std.mem.eql(u8, mode, "delay")) {
            exe.step.dependOn(&command.step);
            step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        }
    }
}
'''.replace("PYTHON", python)
    (root / "build.zig").write_text(build, encoding="utf8")
    (root / "main.zig").write_text(SOURCE, encoding="utf8")
    (root / "helper.py").write_text(HELPER, encoding="utf8")
    (root / "link.ld").write_text("ENTRY(Reset_Handler)\nSECTIONS { . = 0x22000000; .text : { *(.text*) } }\n", encoding="utf8")


def revision(root):
    digest = hashlib.sha256()

    def visit(directory):
        for item in sorted(directory.iterdir(), key=lambda p: p.name.encode("utf8")):
            if item.name in (".git", ".zig-cache", "zig-out", ".ra8-builds"):
                continue
            digest.update(item.name.encode("utf8") + b"\0")
            if item.is_dir():
                digest.update(b"directory\0")
                visit(item)
                digest.update(b"end-directory\0")
            else:
                digest.update(hashlib.sha256(item.read_bytes()).digest())
    visit(Path(root))
    return digest.hexdigest()
