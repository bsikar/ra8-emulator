//! Complete catalog/fault topology staged outside the live guest.
const std = @import("std");
const c = @import("ra8_components");
const run = @import("ra8_board").snapshot.run;
const fields = run.fields;
const file = run.file;
const Board = @import("ra8_board").board.Board;
const Plugs = @import("plug.zig").Plugs;
const Faults = @import("faults/faults.zig").Faults;
const codec = c.catalog_snapshot;
pub const graph = @import("attachment_graph.zig");
pub const nodes = @import("attachment_nodes.zig");
pub const topology = @import("attachment_topology.zig");
pub const inventory = @import("attachment_inventory.zig");
const install = @import("attachment_install.zig");

pub const section_kind: file.Kind = .attachments;
pub const layout: u16 = 1;
pub const Binding = struct {
    arena: *std.heap.ArenaAllocator,
    plugs: *Plugs,
    faults: *Faults,
};

pub fn capture(board: *Board, binding: ?Binding, g: *graph.Graph) !topology.Topology {
    if (binding) |held| {
        if (held.plugs.board != board or held.faults.board != board) return error.UnsupportedAttachment;
    }
    try g.retain(board, if (binding) |held| held.plugs else null, if (binding) |held| held.faults else null);
    const top = try topology.Topology.capture(board, if (binding) |held| held.plugs else null, g);
    if (binding == null) for (g.nodes[0..g.count]) |node| switch (node.kind) {
        .builtin, .floating => {},
        else => return error.AttachmentOwnerRequired,
    };
    return top;
}

pub fn save(board: *Board, binding: ?Binding, writer: *std.Io.Writer) !void {
    var g: graph.Graph = .{};
    const top = try capture(board, binding, &g);
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(&g, &top, &counter.writer);
    try file.writeSectionHeader(writer, section_kind, counter.fullCount());
    try body(&g, &top, writer);
}

fn body(g: *const graph.Graph, top: *const topology.Topology, writer: *std.Io.Writer) !void {
    try fields.write(writer, layout);
    try fields.write(writer, @as(u16, @intCast(g.count)));
    for (g.nodes[0..g.count]) |node| {
        try fields.write(writer, node.kind);
        try fields.write(writer, node.at);
        try fields.write(writer, node.inner);
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try nodes.writePayload(node, &counter.writer);
        try fields.write(writer, @as(u32, @intCast(counter.fullCount())));
        try nodes.writePayload(node, writer);
    }
    try fields.write(writer, @as(u16, @intCast(g.runtime_count)));
    for (g.runtime[0..g.runtime_count]) |id| try fields.write(writer, id.?);
    try fields.write(writer, g.wrapped);
    try fields.write(writer, g.spi_held);
    try fields.write(writer, g.uart_held);
    try top.write(writer);
}

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    next: *graph.Graph,
    previous: *graph.Graph,
    top: topology.Topology,
    committed: bool = false,

    pub fn deinit(self: *Prepared) void {
        if (!self.committed) self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.allocator.destroy(self.next);
        self.allocator.destroy(self.previous);
    }

    /// No allocation or fallible operation. All host resources move here.
    pub fn commit(self: *Prepared, board: *Board, binding: ?Binding) void {
        install.commit(self.next, self.previous, &self.top, self.arena, board, binding);
        self.committed = true;
    }
};

pub fn prepare(board: *Board, binding: ?Binding, bytes: []const u8) !Prepared {
    const section = try file.Reader.find(bytes, section_kind) orelse return error.Missing;
    const allocator = board.bus.cells.allocator;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer arena.deinit();
    const next = try allocator.create(graph.Graph);
    errdefer allocator.destroy(next);
    next.* = .{};
    const previous = try allocator.create(graph.Graph);
    errdefer allocator.destroy(previous);
    previous.* = .{};
    _ = try capture(board, binding, previous);
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    if (try fields.read(u16, &cursor) != layout) return error.BadValue;
    const count = try fields.read(u16, &cursor);
    if (count > nodes.limit) return error.BadValue;
    for (0..count) |id| try readNode(next, arena.allocator(), board, &cursor, id);
    next.runtime_count = try fields.read(u16, &cursor);
    if (next.runtime_count > next.runtime.len) return error.BadValue;
    for (next.runtime[0..next.runtime_count], 0..) |*entry, index| {
        const id = try fields.read(u16, &cursor);
        if (id >= count or next.nodes[id].kind != .part) return error.BadValue;
        for (next.runtime[0..index]) |previous_id| if (previous_id == id) return error.BadValue;
        entry.* = id;
    }
    next.wrapped = try fields.read(@TypeOf(next.wrapped), &cursor);
    next.spi_held = try fields.read(@TypeOf(next.spi_held), &cursor);
    next.uart_held = try fields.read(@TypeOf(next.uart_held), &cursor);
    inline for (.{ .{ next.wrapped, .i2c_fault }, .{ next.spi_held, .spi_fault }, .{ next.uart_held, .uart_fault } }) |group| {
        for (group[0], 0..) |entry, index| if (entry) |id| {
            if (id >= count or std.meta.activeTag(next.nodes[id].kind) != group[1]) return error.BadValue;
            for (group[0][0..index]) |previous_id| if (previous_id == id) return error.BadValue;
        };
    }
    const top = try topology.Topology.read(&cursor, next);
    if (!cursor.done()) return error.BadValue;
    if (binding == null) for (next.nodes[0..next.count]) |node| switch (node.kind) {
        .builtin, .floating => {},
        else => return error.AttachmentOwnerRequired,
    };
    return .{ .allocator = allocator, .arena = arena, .next = next, .previous = previous, .top = top };
}

fn readNode(g: *graph.Graph, allocator: std.mem.Allocator, board: *Board, cursor: *fields.Cursor, id: usize) !void {
    const kind = try fields.read(nodes.Kind, cursor);
    const at = try fields.read(c.endpoint.Endpoint, cursor);
    const inner = try fields.read(?u16, cursor);
    const len = try fields.read(u32, cursor);
    if (!nodes.validEndpoint(at) or len > cursor.bytes.len - cursor.at) return error.BadValue;
    const wrapped = kind == .i2c_fault or kind == .spi_fault or kind == .uart_fault;
    if (wrapped != (inner != null)) return error.BadValue;
    if (inner) |ref| if (ref >= id) return error.BadValue;
    if (kind == .builtin) for (g.nodes[0..g.count]) |node| {
        if (node.kind == .builtin and node.kind.builtin == kind.builtin) return error.BadValue;
    };
    var payload: fields.Cursor = .{ .bytes = cursor.bytes[cursor.at..][0..len] };
    var node = try nodes.readNode(allocator, board, kind, at, if (inner) |ref| g.nodes[ref].device else null, &payload);
    node.inner = inner;
    cursor.at += len;
    g.nodes[id] = node;
    g.count += 1;
}
