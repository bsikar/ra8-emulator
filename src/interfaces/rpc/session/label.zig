//! Set or remove a debugger label on an absolute address.
const rpc = @import("ra8_rpc_wire");
const session = @import("ra8_session");

const handlers = @import("handlers.zig");
const locals = @import("locals.zig");
const proto = @import("rpc.zig");

pub const Request = struct {
    core: proto.Core,
    address: u32,
    width: u8,
    name: []const u8,

    pub const max_len = .{ .name = session.labels.max_name };
};

pub const LocalRequest = struct {
    core: proto.Core,
    frame: u32,
    local: []const u8,
    name: []const u8,

    pub const max_len = .{ .local = proto.local_name_cap, .name = proto.local_name_cap };
};

pub fn setLocal(context: *handlers.Context, request: LocalRequest) rpc.Outcome(proto.Ack) {
    const core: session.api.Core = if (request.core == .cpu0) .cpu0 else .cpu1;
    if (!context.session.?.hasCore(core)) {
        return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.no_core)) };
    }
    renameLocal(context, core, request) catch {
        return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
    };
    return .{ .ok = .{ .accepted = 1 } };
}

fn renameLocal(context: *handlers.Context, core: session.api.Core, request: LocalRequest) !void {
    const view = try context.session.?.view(core);
    const image = handlers.imageOf(context, core) orelse return error.NoImage;
    const pc = try locals.pcAtFrame(context, view, core, request.frame);
    const sections = session.dwarf.locals.ofImage(image);
    const names: session.labels.View = .{ .map = &context.session.?.labels, .core = core };
    const aliased = try session.label_locals.byName(names, sections, pc, request.local);
    const variable = aliased orelse (try session.dwarf.vars.findLocal(sections, pc, request.local)) orelse
        return error.NoLocal;
    const key = session.label_locals.keyOf(names, variable) orelse return error.NoStorage;
    try checkLocalName(names, sections, pc, request.name, variable.die_offset);
    try context.session.?.labels.set(key, request.name, 0);
}

fn checkLocalName(
    names: session.labels.View,
    sections: session.dwarf.locals.Sections,
    pc: u32,
    name: []const u8,
    die: usize,
) !void {
    if (name.len == 0) return;
    const aliased = try session.label_locals.byName(names, sections, pc, name);
    const match = aliased orelse (try session.dwarf.vars.findLocal(sections, pc, name)) orelse return;
    if (match.die_offset != die) return error.DuplicateLabel;
}

pub fn set(context: *handlers.Context, request: Request) rpc.Outcome(proto.Ack) {
    const core: session.api.Core = if (request.core == .cpu0) .cpu0 else .cpu1;
    if (!context.session.?.hasCore(core)) {
        return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.no_core)) };
    }
    const key: session.labels.Key = .{ .core = core, .address = request.address };
    const width = if (request.width == 0) previousWidth(&context.session.?.labels, key) else request.width;
    context.session.?.labels.set(key, request.name, width) catch {
        return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
    };
    return .{ .ok = .{ .accepted = 1 } };
}

fn previousWidth(map: *const session.labels.Map, key: session.labels.Key) u8 {
    const entry = map.at(key) orelse return 0;
    return entry.width;
}
