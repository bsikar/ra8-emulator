//! Optional code-quality checks, separate from the lightweight gate.
const builtin = @import("builtin");
const std = @import("std");

pub fn add(b: *std.Build, comptime parent: type) void {
    const python = b.option([]const u8, "python", "Python interpreter for tooling") orelse
        if (builtin.os.tag == .windows) "python" else "python3";
    const check = b.addSystemCommand(&.{ python, "-B" });
    check.addFileArg(b.path("tools/lint/run.py"));
    check.addArg("--zig");
    check.addFileArg(.zig_exe);
    check.addPassthruArgs();
    check.setCwd(b.path("."));
    b.step("lint", "Reject new backend code-quality findings").dependOn(&check.step);

    const tests = b.addSystemCommand(&.{ python, "-B" });
    tests.addFileArg(b.path("tests/tools/lint/test_import_style.py"));
    tests.addArg("--zig");
    tests.addFileArg(.zig_exe);
    tests.setCwd(b.path("."));
    b.step("lint-test", "Test import rules and incremental lint enforcement").dependOn(&tests.step);

    // Resolve upstream analysis only for the nested report invocation. Ordinary
    // builds and the lightweight gate do not configure its tool probes.
    const report = b.step("lint-report", "Raw zlinter report (used by lint)");
    if (b.option(bool, "lint-report", "Enable the raw linter invocation") orelse false) {
        const zlinter = b.lazyImport(parent, "zlinter") orelse return;
        report.dependOn(reportStep(b, zlinter));
    } else {
        report.dependOn(&b.addFail("Use zig build lint; raw reports require -Dlint-report=true").step);
    }
}

fn reportStep(b: *std.Build, comptime zlinter: type) *std.Build.Step {
    var lint = zlinter.builder(b, .{});
    lint.setCompileUnits(&.{.all});
    lint.addRule(.{ .custom = .{ .name = "import_style", .path = "tools/lint/import_style.zig" } }, .{});
    lint.addRule(.{ .custom = .{ .name = "complexity", .path = "tools/lint/complexity.zig" } }, .{});
    lint.addRule(.{ .custom = .{ .name = "line_width", .path = "tools/lint/line_width.zig" } }, .{});
    lint.addRule(.{ .builtin = .import_ordering }, .{});
    lint.addRule(.{ .builtin = .no_unused }, .{});
    lint.addRule(.{ .builtin = .no_swallow_error }, .{});
    lint.addRule(.{ .builtin = .require_braces }, .{
        .for_statement = .{ .warning = .all },
        .while_statement = .{ .warning = .all },
    });
    lint.addPaths(.{
        .include_dirs = &.{ b.path("src"), b.path("tools") },
        .include_files = &.{b.path("build.zig")},
        .exclude_dirs = &.{ b.path("src/interfaces/gui"), b.path("src/interfaces/render") },
        .exclude_files = &.{b.path("tools/gui_smoke.zig")},
    });
    return lint.build();
}
