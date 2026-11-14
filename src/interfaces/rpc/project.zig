//! RPC project lifecycle delegates to the same host Project used by the CLI.
const rpc = @import("ra8_rpc_wire");
const wire = @import("project_wire.zig");
const builds = @import("build.zig");
const build_wire = @import("build_wire.zig");
const Context = @import("session/handlers.zig").Context;
const Ack = @import("session/rpc.zig").Ack;

pub const routes = .{ .{ @backingInt(wire.Method.open), open }, .{ @backingInt(wire.Method.close), close }, .{ @backingInt(wire.Method.build), start }, .{ @backingInt(wire.Method.prepare), prepare } };

pub fn open(context: *Context, args: wire.Open) rpc.Outcome(Ack) {
    const project = context.project orelse return refuse(Ack, error.Unavailable);
    project.open(args.config) catch |err| return refuse(Ack, err);
    builds.forget(context);
    context.workspace_watches.clear();
    context.workspace = &project.workspace.?;
    context.build_runner = &project.runner.?;
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn close(context: *Context, _: struct {}) rpc.Outcome(Ack) {
    const project = context.project orelse return refuse(Ack, error.Unavailable);
    if (project.parsed == null) return refuse(Ack, error.ProjectNotOpen);
    forget(context);
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn start(context: *Context, args: wire.Build) rpc.Outcome(build_wire.Id) {
    const project = context.project orelse return refuse(build_wire.Id, error.Unavailable);
    const id = project.start(args.recipe) catch |err| return refuse(build_wire.Id, err);
    context.build_id = id;
    context.build_completion_sent = false;
    return .{ .ok = .{ .id = id } };
}

pub fn prepare(context: *Context, args: build_wire.Id) rpc.Outcome(wire.Prepared) {
    const project = context.project orelse return refuse(wire.Prepared, error.Unavailable);
    if (context.build_id != args.id) return refuse(wire.Prepared, error.UnknownBuild);
    const path = project.prepare(args.id) catch |err| return refuse(wire.Prepared, err);
    return .{ .ok = .{ .receipt = path } };
}

pub fn forget(context: *Context) void {
    const project = context.project orelse return;
    if (project.parsed == null) return;
    builds.forget(context);
    context.workspace_watches.clear();
    project.close();
    context.workspace = context.project_base_workspace;
    context.build_runner = context.project_base_runner;
}

fn refuse(comptime T: type, err: anyerror) rpc.Outcome(T) {
    const code: u16 = switch (err) {
        error.Unavailable => wire.codes.unavailable,
        error.ProjectNotOpen, error.ProjectAlreadyOpen, error.BuildBusy, error.UnknownBuild => wire.codes.state,
        error.BuildNotSuccessful => wire.codes.failed,
        error.SourceChanged, error.ArtifactChanged, error.ProjectConfigChanged, error.ProjectFileChanged => wire.codes.changed,
        else => wire.codes.invalid,
    };
    return .{ .err = @fromBackingInt(code) };
}
