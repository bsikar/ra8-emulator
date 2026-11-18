//! Import into a separate owned machine. The application may swap sessions only after success.
const std = @import("std");

const board_snap = @import("ra8_board").snapshot.board;
const Bridge = @import("../history_bridge.zig").Bridge;
const bundle = @import("ra8_snapshot").bundle;
const catalog = @import("ra8_chip").core.machine.catalog;
const history = @import("ra8_host").history;
const packs = @import("packs.zig");
const session = @import("ra8_session");
const setup = @import("../served_setup.zig");
const Stage = @import("stage.zig").Stage;
const validation = @import("validation.zig");
const validity = @import("../history_validity.zig");

pub const Options = struct {
    /// Required for recording bundles; receives only a newly created, leased history ID.
    history_root: ?[]const u8 = null,
    expected_board: ?[]const u8 = null,
    /// Explicit machine description; null uses `catalog.ra8p1`.
    machine: ?*const session.api.Machine = null,
    /// Snapshot-only bundles need the original images; recording roots embed them.
    elf0: ?[]const u8 = null,
    elf1: ?[]const u8 = null,
    board_profile: ?[]const u8 = null,
    limits: bundle.reader.Limits = .{},
};

pub fn open(gpa: std.mem.Allocator, io: std.Io, input: *std.Io.Reader, options: Options) !*setup.Served {
    var reader = try bundle.reader.Reader.init(gpa, input, options.limits);
    defer reader.deinit();
    const metadata = reader.metadata.value;
    if (options.expected_board) |expected| {
        if (!std.mem.eql(u8, expected, metadata.board)) return error.BoardMismatch;
    }
    _ = (try reader.next()) orelse return error.MissingSnapshot;
    const state = try reader.readAlloc(gpa, 1024 * 1024 * 1024);
    defer gpa.free(state);
    try validation.snapshotSections(gpa, state);
    const chosen = options.machine orelse &catalog.ra8p1;
    try board_snap.machineOf(chosen, state);
    if (metadata.recording) return recorded(gpa, io, &reader, state, options);
    if (try reader.next() != null) return error.UnexpectedEntry;
    const first = options.elf0 orelse return error.MissingImage;
    try images(metadata, first, options.elf1);
    const candidate = try gpa.create(setup.Served);
    errdefer gpa.destroy(candidate);
    try candidate.openInputs(
        gpa,
        io,
        "",
        options.board_profile,
        .{ .elf_bytes = first },
        if (options.elf1) |bytes| .{ .bytes = bytes } else null,
        .{ .machine = options.machine },
    );
    errdefer candidate.deinit();
    try candidate.owner.state.files.readFrom(state);
    return candidate;
}

fn recorded(
    gpa: std.mem.Allocator,
    io: std.Io,
    reader: *bundle.reader.Reader,
    state: []const u8,
    options: Options,
) !*setup.Served {
    var stage: Stage = .{ .base = undefined, .session = undefined };
    try stage.init(gpa, io, options.history_root orelse return error.MissingHistoryRoot);
    return staged(gpa, io, reader, state, options, &stage) catch |err| {
        try stage.close();
        return err;
    };
}

fn staged(
    gpa: std.mem.Allocator,
    io: std.Io,
    reader: *bundle.reader.Reader,
    state: []const u8,
    options: Options,
    stage: *Stage,
) !*setup.Served {
    while (try reader.next()) |entry| {
        if (entry.size > validation.max_file) return error.TooLarge;
        try stage.copy(reader, entry);
    }
    const root_bytes = try stage.read(gpa, .top, "root.bin", 64 * 1024 * 1024);
    defer gpa.free(root_bytes);
    const root = try session.history_root.decode(root_bytes);
    const chosen = options.machine orelse &catalog.ra8p1;
    try validity.checkFor(root, chosen.name);
    if (root.elf1 != null and !chosen.hasSecond()) return error.AbsentCore;
    try images(reader.metadata.value, root.elf0.bytes, if (root.elf1) |image| image.bytes else null);
    if (options.board_profile) |profile| {
        if (!std.mem.eql(u8, profile, root.board_profile)) return error.BoardMismatch;
    }
    var graph = try validation.branches(gpa, stage);
    defer graph.deinit();
    var logs: validation.Logs = .{
        .gpa = gpa,
        .store = history.storage.Store.from(&stage.session),
        .graph = &graph,
        .root = root_bytes,
    };
    try logs.check();
    try packs.check(gpa, stage, options.limits.total_bytes);
    const candidate = try gpa.create(setup.Served);
    errdefer gpa.destroy(candidate);
    const bind = try stage.adoptFor(gpa, chosen.name);
    // openInputs consumes the bind even on failure; the stage no longer owns its handles.
    try candidate.openInputs(
        gpa,
        io,
        "",
        root.board_profile,
        .{ .imported = bind, .elf_bytes = root.elf0.bytes },
        if (root.elf1) |image| .{ .bytes = image.bytes } else null,
        .{ .machine = options.machine },
    );
    errdefer candidate.deinit();
    logs.store = history.storage.Store.from(&bind.session);
    logs.candidate = candidate;
    logs.checkpoints = 0;
    try logs.check();
    try candidate.owner.state.files.readFrom(state);
    const grid = candidate.owner.session().grid orelse return error.MissingGrid;
    if (grid.at.branch != graph.active_branch) return error.BranchMismatch;
    const position = candidate.owner.session().currentPosition();
    const end = bind.router.recordedEnd();
    if (try graph.compareOnLine(graph.active_branch, position, end) == .gt) return error.PositionOutsideRecording;
    try candidate.owner.session().persistent_recorder.?.switchSegment(0, graph.active_branch, logs.next_segment);
    const log = try setupBridgeLog(candidate);
    try candidate.owner.session().loadReplayInterventions(log);
    return candidate;
}

fn images(metadata: bundle.manifest.Manifest, first: []const u8, second: ?[]const u8) !void {
    if ((metadata.elf1 == null) != (second == null)) return error.ImageMismatch;
    try imageCheck(metadata.elf0, first);
    if (second) |bytes| try imageCheck(metadata.elf1.?, bytes);
}

fn imageCheck(metadata: bundle.manifest.Elf, bytes: []const u8) !void {
    const identity = std.fmt.bytesToHex(session.history_root.identity(bytes), .lower);
    if (metadata.size != bytes.len or !std.mem.eql(u8, &metadata.identity, &identity)) return error.ImageMismatch;
}

fn setupBridgeLog(candidate: *setup.Served) ![]const u8 {
    return Bridge.logBytes(&candidate.bridge.?);
}
