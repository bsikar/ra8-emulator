//! Tests for src/session/txm/publish.zig: which module instances appeared
//! and left between two reads of the Module Manager's list, and the wire
//! kinds they go out as.
const std = @import("std");
const ra8 = @import("ra8");
const txm = ra8.session.txm.modules;
const publish = ra8.session.txm.publish;

fn module(instance: u32) txm.Module {
    return .{ .instance = instance, .name_at = 0, .state = .started, .code_start = 0, .code_size = 0, .data_start = 0, .data_size = 0 };
}

test "a first read reports every module loaded" {
    var known = publish.Known{};
    var into: [2 * publish.most]publish.Change = undefined;
    const now = [_]txm.Module{ module(0x2000_0100), module(0x2000_0600) };
    try std.testing.expectEqual(@as(usize, 2), publish.changes(&known, &now, &into));
    try std.testing.expectEqual(.module_loaded, into[0].kind);
    try std.testing.expectEqual(@as(u32, 0x2000_0100), into[0].instance);
    try std.testing.expectEqual(@as(u32, 0x2000_0600), into[1].instance);
}

test "an unchanged list reports nothing" {
    var known = publish.Known{};
    var into: [2 * publish.most]publish.Change = undefined;
    const now = [_]txm.Module{module(0x2000_0100)};
    _ = publish.changes(&known, &now, &into);
    try std.testing.expectEqual(@as(usize, 0), publish.changes(&known, &now, &into));
}

test "a module that leaves is unloaded and a new one is loaded" {
    var known = publish.Known{};
    var into: [2 * publish.most]publish.Change = undefined;
    const before = [_]txm.Module{ module(0x2000_0100), module(0x2000_0600) };
    _ = publish.changes(&known, &before, &into);
    const after = [_]txm.Module{ module(0x2000_0600), module(0x2000_0B00) };
    try std.testing.expectEqual(@as(usize, 2), publish.changes(&known, &after, &into));
    try std.testing.expectEqual(.module_loaded, into[0].kind);
    try std.testing.expectEqual(@as(u32, 0x2000_0B00), into[0].instance);
    try std.testing.expectEqual(.module_unloaded, into[1].kind);
    try std.testing.expectEqual(@as(u32, 0x2000_0100), into[1].instance);
}

test "an emptied list unloads everything" {
    var known = publish.Known{};
    var into: [2 * publish.most]publish.Change = undefined;
    const before = [_]txm.Module{module(0x2000_0100)};
    _ = publish.changes(&known, &before, &into);
    try std.testing.expectEqual(@as(usize, 1), publish.changes(&known, &.{}, &into));
    try std.testing.expectEqual(.module_unloaded, into[0].kind);
    try std.testing.expectEqual(@as(usize, 0), known.count);
}

fn coded(instance: u32, start: u32, size: u32) txm.Module {
    var entry = module(instance);
    entry.code_start = start;
    entry.code_size = size;
    return entry;
}

test "a fault location belongs to the module whose code holds it" {
    const modules = [_]txm.Module{ coded(0x2000_0100, 0x6000_0000, 0x400), coded(0x2000_0600, 0x6000_1000, 0x200) };
    try std.testing.expectEqual(@as(?u32, 0x2000_0600), publish.owner(&modules, 0x6000_1010));
    try std.testing.expectEqual(@as(?u32, 0x2000_0100), publish.owner(&modules, 0x6000_0000));
    try std.testing.expectEqual(@as(?u32, null), publish.owner(&modules, 0x6000_0400));
    try std.testing.expectEqual(@as(?u32, null), publish.owner(&modules, 0x5FFF_FFFE));
}

test "only a new thread or location in the fault record is a fresh fault" {
    const none = publish.Fault{};
    const first = publish.Fault{ .thread = 0x2000_0900, .code = 0x6000_0010 };
    try std.testing.expect(!publish.fresh(none, none));
    try std.testing.expect(publish.fresh(none, first));
    try std.testing.expect(!publish.fresh(first, first));
    try std.testing.expect(publish.fresh(first, .{ .thread = 0x2000_0900, .code = 0x6000_0020 }));
    try std.testing.expect(!publish.fresh(first, none));
}

test "an observation reaches the inner boundary and publishes no module change" {
    const Seen = struct {
        observed: u32 = 0,
        fn tick(_: *anyopaque, _: u32) anyerror!void {}
        fn observe(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.observed += 1;
        }
    };
    const stream_mod = ra8.session.event.stream;
    var store = try ra8.chip.core.cpu.memory.store.Store.init(null);
    defer store.deinit();
    var stream: stream_mod.Stream = .{};
    const id = stream.subscribe().?;
    var seen: Seen = .{};
    var watcher: publish.Watcher = .{ .head_at = 0, .memory = .{ .guest = .{ .store = &store } }, .stream = &stream, .inner = .{ .context = &seen, .tickFn = Seen.tick, .observeFn = Seen.observe } };
    const edge = watcher.hook();
    ra8.session.step_hook.zig.boundary.observe(edge);
    try std.testing.expectEqual(@as(u32, 1), seen.observed);
    var out: [2]stream_mod.Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), stream.read(id, &out).?.count);
}
