"""Workspace layout combining RA8EMU-1270 debug conformance and per-board known-state projects."""
import ast
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]

BOARDS_BUILD_ZIG = """const std = @import("std");

pub fn build(b: *std.Build) void {
    const e1_target = b.resolveTargetQuery(.{
        .cpu_arch = .thumb,
        .os_tag = .freestanding,
        .abi = .eabi,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m85 },
    });
    const e1 = b.addExecutable(.{
        .name = "fpb_ra8e1.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fpb_ra8e1.zig"),
            .target = e1_target,
            .optimize = .ReleaseSmall,
            .strip = false,
            .unwind_tables = .none,
            .stack_check = false,
        }),
    });
    e1.entry = .{ .symbol_name = "Reset_Handler" };
    e1.setLinkerScript(b.path("fpb_ra8e1.ld"));
    e1.bundle_compiler_rt = false;
    e1.link_z_max_page_size = 4;
    e1.link_gc_sections = true;
    b.installArtifact(e1);

    const t1_target = b.resolveTargetQuery(.{
        .cpu_arch = .thumb,
        .os_tag = .freestanding,
        .abi = .eabi,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m33 },
    });
    const t1 = b.addExecutable(.{
        .name = "fpb_ra4t1.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fpb_ra4t1.zig"),
            .target = t1_target,
            .optimize = .ReleaseSmall,
            .strip = false,
            .unwind_tables = .none,
            .stack_check = false,
        }),
    });
    t1.entry = .{ .symbol_name = "Reset_Handler" };
    t1.setLinkerScript(b.path("fpb_ra4t1.ld"));
    t1.bundle_compiler_rt = false;
    t1.link_z_max_page_size = 4;
    t1.link_gc_sections = true;
    b.installArtifact(t1);
}
"""

OWNED_WAIT_PY = """import pathlib, subprocess, sys, time
base = pathlib.Path('.ra8-builds')
if len(sys.argv) > 1:
    time.sleep(5)
    (base / 'project.delayed').write_text('descendant survived')
else:
    subprocess.Popen([sys.executable, __file__, 'child'])
    (base / 'project.ready').write_text('nested child started')
    time.sleep(30)
"""


def populate(ws_dir: Path, python_exe: str = None):
    ws_dir.mkdir(parents=True, exist_ok=True)
    py = (python_exe or sys.executable).replace("\\", "/")

    fw = ws_dir / "firmware"
    fw.mkdir(exist_ok=True)
    for name in ("conformance.zig", "machine.zig", "link.ld"):
        shutil.copyfile(ROOT / "tests/fixtures/debug" / name, fw / name)

    tree = ast.parse((ROOT / "tools/toolchain_smoke/build_debug.py").read_text(encoding="utf8"))
    base_build = next(
        ast.literal_eval(node.value)
        for node in tree.body
        if isinstance(node, ast.Assign)
        and any(isinstance(t, ast.Name) and t.id == "BUILD" for t in node.targets)
    )
    slow_step = (
        f'    const wait = b.addSystemCommand(&.{{ {json.dumps(py)}, "owned_wait.py" }});\n'
        '    b.step("slow", "owned cancellation fixture").dependOn(&wait.step);\n'
    )
    (fw / "build.zig").write_text(base_build.rsplit("}", 1)[0] + slow_step + "}\n", encoding="utf8")
    (fw / "owned_wait.py").write_text(OWNED_WAIT_PY, encoding="utf8")

    project_ra8d2 = dict(
        version=1,
        root="firmware",
        target="ra8d2",
        source_mappings=[dict(host=".", client="C:/client-only/project")],
        recipes=[
            dict(name="debug", options="[]", artifact="bin/fresh.elf", timeout_ms=240000),
            dict(name="slow", step="slow", options="[]", artifact="bin/fresh.elf", timeout_ms=60000),
        ],
    )
    (ws_dir / "project.json").write_text(json.dumps(project_ra8d2, indent=2), encoding="utf8")

    boards = ws_dir / "boards"
    boards.mkdir(exist_ok=True)
    for name in ("fpb_ra8e1.zig", "fpb_ra8e1.ld", "fpb_ra4t1.zig", "fpb_ra4t1.ld"):
        shutil.copyfile(ROOT / "tests/fixtures/known_state" / name, boards / name)
    (boards / "build.zig").write_text(BOARDS_BUILD_ZIG, encoding="utf8")

    project_ra8e1 = dict(
        version=1,
        root="boards",
        target="fpb-ra8e1",
        source_mappings=[dict(host=".", client="C:/client-only/boards")],
        recipes=[dict(name="debug", options="[]", artifact="bin/fpb_ra8e1.elf", timeout_ms=240000)],
    )
    (ws_dir / "project_ra8e1.json").write_text(json.dumps(project_ra8e1, indent=2), encoding="utf8")

    project_ra4t1 = dict(
        version=1,
        root="boards",
        target="fpb-ra4t1",
        source_mappings=[dict(host=".", client="C:/client-only/boards")],
        recipes=[dict(name="debug", options="[]", artifact="bin/fpb_ra4t1.elf", timeout_ms=240000)],
    )
    (ws_dir / "project_ra4t1.json").write_text(json.dumps(project_ra4t1, indent=2), encoding="utf8")
    return dict(ws=ws_dir, firmware=fw, boards=boards)
