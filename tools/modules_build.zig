//! Named library modules and application dependency edges (ADR 0004).
const history_build = @import("history_build.zig");
const std = @import("std");

/// The libraries that are build modules of their own (ADR 0004 section 1,
/// RA8EMU-1031). Each is rooted in its own directory, so Zig refuses an
/// import that leaves it, and is given exactly the modules it may import:
/// only ones below it, and the host only where the ADR allows it.
pub const Libraries = struct {
    host: *std.Build.Module,
    snapshot: *std.Build.Module,
    chip: *std.Build.Module,
    components: *std.Build.Module,
    board: *std.Build.Module,
    session: *std.Build.Module,
    render: *std.Build.Module,
    rpc: *std.Build.Module,
    gdb: *std.Build.Module,
    dap: *std.Build.Module,
    usbip: *std.Build.Module,

    /// Every library, under its own name, into `module`.
    pub fn importInto(self: Libraries, module: *std.Build.Module) void {
        inline for (@typeInfo(Libraries).@"struct".field_names) |name| {
            module.addImport(
                "ra8_" ++ name,
                @field(self, name),
            );
        }
    }
};

pub fn libraries(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    firmware: *std.Build.Dependency,
) Libraries {
    const host = library(b, target, optimize, "ra8_host", "src/host/root.zig", &.{});
    const snapshot = library(b, target, optimize, "ra8_snapshot", "src/snapshot/root.zig", &.{});
    const chip = library(
        b,
        target,
        optimize,
        "ra8_chip",
        "src/chip/root.zig",
        &.{.{ .name = "ra8_snapshot", .module = snapshot }},
    );
    const components = library(b, target, optimize, "ra8_components", "src/components/root.zig", &.{
        .{ .name = "ra8_chip", .module = chip },
        .{ .name = "ra8_snapshot", .module = snapshot },
    });
    const board = library(b, target, optimize, "ra8_board", "src/board/root.zig", &.{
        .{ .name = "ra8_chip", .module = chip },
        .{ .name = "ra8_components", .module = components },
        .{ .name = "ra8_snapshot", .module = snapshot },
    });
    const session = library(b, target, optimize, "ra8_session", "src/session/root.zig", &.{
        .{ .name = "ra8_board", .module = board },
        .{ .name = "ra8_chip", .module = chip },
        .{ .name = "ra8_components", .module = components },
    });
    const render = library(b, target, optimize, "ra8_render", "src/interfaces/render/root.zig", &.{
        .{ .name = "ra8_session", .module = session },
    });
    const rpc = library(b, target, optimize, "ra8_rpc", "src/interfaces/rpc/root.zig", &.{
        .{ .name = "ra8_snapshot", .module = snapshot },
        .{ .name = "ra8_session", .module = session },
        .{ .name = "ra8_components", .module = components },
        .{ .name = "ra8_host", .module = host },
        .{ .name = "ra8_board", .module = board },
        .{ .name = "ra8_chip", .module = chip },
        .{ .name = "ra8_rpc_wire", .module = firmware.module("ra8_rpc") },
    });
    const gdb = library(b, target, optimize, "ra8_gdb", "src/interfaces/gdb/root.zig", &.{
        .{ .name = "ra8_session", .module = session },
        .{ .name = "ra8_chip", .module = chip },
        .{ .name = "ra8_host", .module = host },
    });
    const dap = library(
        b,
        target,
        optimize,
        "ra8_dap",
        "src/interfaces/dap/root.zig",
        &.{.{ .name = "ra8_session", .module = session }},
    );
    // The host listener (RA8EMU-1156) serves GDB through the library adapter.
    rpc.addImport("ra8_gdb", gdb);
    rpc.addOptions("history_build", history_build.options(b));
    const usbip = library(b, target, optimize, "ra8_usbip", "src/interfaces/usbip/root.zig", &.{
        .{ .name = "ra8_board", .module = board },
        .{ .name = "ra8_chip", .module = chip },
        .{ .name = "ra8_host", .module = host },
    });
    return .{
        .host = host,
        .snapshot = snapshot,
        .chip = chip,
        .components = components,
        .board = board,
        .session = session,
        .render = render,
        .rpc = rpc,
        .gdb = gdb,
        .dap = dap,
        .usbip = usbip,
    };
}

/// One library module, importable by its name from this build and from a
/// build that depends on this package.
fn library(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root: []const u8,
    imports: []const std.Build.Module.Import,
) *std.Build.Module {
    return b.addModule(
        name,
        .{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = imports,
        },
    );
}

/// The CLI application's own files, exposed as a module so the executable
/// and its tests import the same code (ADR 0004 section 1, RA8EMU-1031).
pub fn application(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libs: Libraries,
    firmware: *std.Build.Dependency,
) *std.Build.Module {
    const cli = b.createModule(
        .{
            .root_source_file = b.path("src/interfaces/cli/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        },
    );
    libs.importInto(cli);
    cli.addImport("ra8_rpc_wire", firmware.module("ra8_rpc"));
    return cli;
}
