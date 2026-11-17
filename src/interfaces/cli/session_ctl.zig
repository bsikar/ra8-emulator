//! `ra8_emulator ctl --connect unix:PATH|tcp:HOST:PORT [--json] COMMAND`
//! (RA8EMU-747): one command against a running `serve`, one connection per
//! command. serve keeps the session between clients, so a script of ctl
//! calls drives one continuous machine.
//!
//! `ctl --host NAME --image ELF` (RA8EMU-196) instead starts a `serve
//! --stdio` on the profile's host for this one command, so each call is a
//! fresh machine booted from ELF.
const std = @import("std");

const chunk_load = @import("ra8_rpc").session.load_chunks;
const ctl_client = @import("ctl/client.zig");
const proto = @import("ra8_rpc").session.rpc;
const Spec = @import("serve/listen.zig").Spec;
const targets = @import("ctl/targets.zig");

const Client = ctl_client.Client;
const ctl_branch = @import("ctl/branch.zig");
const ctl_diff = @import("ctl/diff.zig");
const ctl_disasm = @import("ctl/disasm.zig");
const ctl_nav = @import("ctl/nav.zig");
const ctl_write = @import("ctl/write.zig");
pub const events = @import("ctl/events.zig");
const host_spawn = @import("host/spawn.zig");
const out = @import("ctl/print.zig");
const profiles = @import("ra8_host").profiles;

pub const usage =
    "usage: ra8_emulator ctl --connect unix:PATH|tcp:[HOST]:PORT [--json] COMMAND\n" ++
    "       ra8_emulator ctl --host NAME [--hosts FILE] --image ELF [--json] " ++
    "COMMAND\n" ++
    "  commands: load ELF | run [--budget N] | step | pause | regs [NAME...] | mem " ++
    "ADDRESS LENGTH | disasm ADDRESS [COUNT]\n" ++
    "            speed FACTOR|max | break ADDRESS|NAME | break --clear ID\n" ++
    "            watch ADDRESS read|write|access | watch --clear ID\n" ++
    "            events [--topic uart|stop]... [--until TEXT] [--timeout 500ms|30s]\n" ++
    "            advance 500ms|600s | seek TARGET | frame N | iter N | marker NAME | " ++
    "marker set NAME PLACE | nav KIND [ARG] | frames | play [--dir=back]\n" ++
    "            rc | plug MODEL@ENDPOINT | unplug ENDPOINT | snapshot PATH | " ++
    "restore PATH\n" ++
    "            map | stack | rtc | periph [BLOCK] | folded [THREAD] | fault " ++
    "MODEL@ENDPOINT=MODE\n" ++
    "            branch ls | branch switch ID | branch rm ID [--confirm] | diff A B\n" ++
    "            fork confirm | fork cancel | fork status | write-reg NAME VALUE | " ++
    "set NAME=VALUE | console " ++
    "TEXT\n" ++
    "            undo | reset-image\n" ++
    "            targets list | targets use HOST_ID PROBE_ID BOARD_ID GENERATION DISAMBIGUATION|- ACTION...\n";

const command_parse = @import("ctl/parse.zig");
const command_types = @import("ctl/command.zig");

pub const Command = command_types.Command;
pub const Folded = command_types.Folded;
pub const Part = command_types.Part;
pub const Files = command_types.Files;
pub const Host = command_types.Host;
pub const Where = command_types.Where;
pub const Request = command_types.Request;

/// Parse `argv`; `--json`, `--hosts` and `--image` may sit anywhere after
/// the connect spec or host name.
pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) !Request {
    if (argv.len < 5 or !std.mem.eql(u8, argv[1], "ctl")) return error.BadArguments;
    const by_host = std.mem.eql(u8, argv[2], "--host");
    if (!by_host and !std.mem.eql(u8, argv[2], "--connect")) return error.BadArguments;
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(allocator);
    var json = false;
    var hosts: ?[]const u8 = null;
    var image: ?[]const u8 = null;
    var index: usize = 4;
    while (index < argv.len) : (index += 1) {
        const word = argv[index];
        if (std.mem.eql(u8, word, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, word, "--hosts") or std.mem.eql(u8, word, "--image")) {
            index += 1;
            if (index == argv.len) return error.BadArguments;
            if (word[2] == 'h') hosts = argv[index] else image = argv[index];
        } else try words.append(allocator, word);
    }
    if (words.items.len == 0) return error.BadArguments;
    const command = try command_parse.command(allocator, words.items[0], words.items[1..]);
    if (!by_host) {
        if (hosts != null or image != null) return error.BadArguments;
        return .{ .where = .{ .connect = try Spec.parse(argv[3]) }, .json = json, .command = command };
    }
    const host: Host = .{ .name = argv[3], .hosts = hosts, .image = image orelse return error.MissingImage };
    return .{ .where = .{ .host = host }, .json = json, .command = command };
}

/// The link `where` names: a socket, or a `serve --stdio` started for it.
fn target(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    where: Where,
) !ctl_client.Target {
    switch (where) {
        .connect => |spec| return .{ .socket = spec },
        .host => |host| {
            const profile = try profiles.load(allocator, io, env, host.hosts, host.name);
            return .{ .spawn = try host_spawn.serveArgv(allocator, io, profile, host.image) };
        },
    }
}

/// Run `argv` (`ra8_emulator ctl --connect|--host ...`) and return the exit code.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    const request = parse(allocator, argv) catch |err| {
        std.debug.print("ctl: {s}\n{s}", .{ @errorName(err), usage });
        return 2;
    };
    const reach = target(allocator, io, env, request.where) catch |err| return out.failed(io, request.json, err, 0);
    const client = Client.open(allocator, io, reach) catch |err| return out.failed(io, request.json, err, 0);
    defer client.close();
    return perform(allocator, io, client, request) catch |err| return out.failed(io, request.json, err, client.refused);
}

/// Ask for a break by symbol name: the server places it, or pends it
/// until its module loads (RA8EMU-1141).
fn breakNamed(client: *Client, w: *std.Io.Writer, json: bool, name: []const u8) !void {
    const reply = try client.call(
        proto.NamedPoint,
        proto.NamedBreak,
        .set_breakpoint_name,
        .{ .core = .cpu0, .name = name },
    );
    if (reply.deferred == 0) return out.point(w, json, "breakpoint", reply.id, reply.address, null);
    if (json) {
        try w.print("{{\"breakpoint\":{d},\"pending\":\"{s}\"}}\n", .{ reply.id, name });
    } else {
        try w.print("breakpoint {d} pending ({s})\n", .{ reply.id, name });
    }
}

fn perform(allocator: std.mem.Allocator, io: std.Io, client: *Client, request: Request) !u8 {
    var stdout = std.Io.File.stdout().writerStreaming(io, &.{});
    const w = &stdout.interface;
    const json = request.json;
    switch (request.command) {
        .targets => |cmd| try targets.run(client, w, cmd),
        .events => |options| return events.watch(client, w, json, options),
        .load => |path| try loadFile(allocator, io, client, w, json, path),
        .run => |budget| try runTo(client, w, json, budget),
        .advance => |ns| {
            const moved = try client.call(proto.Advanced, proto.Advance, .advance, .{ .core = .cpu0, .ns = ns });
            try out.advanced(w, json, moved);
        },
        .play => |cmd| try ctl_nav.runPlay(client, w, json, cmd),
        .seek => |text| try ctl_nav.runSeek(client, w, json, text),
        .frame_status => try ctl_nav.runFrameStatus(client, w, json),
        .nav => |query| try ctl_nav.runNav(client, w, json, query),
        .marker_set => |cmd| try ctl_nav.runMarkerSet(client, w, json, cmd),
        .rc => {
            _ = try client.call(proto.Ack, proto.CoreOnly, .rcont, .{ .core = .cpu0 });
            try out.rcont(w, json);
        },
        .step => try runTo(client, w, json, null),
        .pause => {
            _ = try client.call(proto.Ack, proto.CoreOnly, .pause, .{ .core = .cpu0 });
            try out.paused(w, json);
        },
        .regs => |regs| try readRegs(client, w, json, regs),
        .mem => |at| try readMem(client, w, json, at.address, at.length),
        .disasm => |args| try ctl_disasm.run(client, w, json, args),
        .speed => |milli| {
            _ = try client.call(proto.Ack, proto.SetSpeed, .set_speed, .{ .core = .cpu0, .milli = milli });
            try out.speed(w, json, milli);
        },
        .set_break => |address| {
            const id = try client.call(proto.U32, proto.Point, .set_breakpoint, .{ .core = .cpu0, .address = address });
            try out.point(w, json, "breakpoint", id.value, address, null);
        },
        .set_break_name => |name| try breakNamed(client, w, json, name),
        .set_watch => |at| try setWatch(client, w, json, at.address, at.access),
        .clear_break => |id| try clear(client, w, json, .clear_breakpoint, id),
        .clear_watch => |id| try clear(client, w, json, .clear_watchpoint, id),
        .part => |asked| {
            _ = try client.call(proto.Ack, proto.PartSpec, asked.method, .{ .core = .cpu0, .text = asked.text });
            try out.part(w, json, asked.method, asked.text);
        },
        .files => |asked| {
            _ = try client.call(proto.Ack, proto.StatePath, asked.method, .{ .path = asked.path });
            try out.files(w, json, asked.method, asked.path);
        },
        .map, .periph, .folded, .stack, .rtc => try inspect(client, w, json, request.command),
        .branch_cmd => |cmd| try ctl_branch.perform(client, w, json, cmd),
        .write_cmd => |cmd| return try ctl_write.perform(client, w, json, cmd),
        .diff_cmd => |cmd| try ctl_diff.perform(client, w, json, cmd.a, cmd.b),
    }
    return 0;
}

fn loadFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *Client,
    w: *std.Io.Writer,
    json: bool,
    path: []const u8,
) !void {
    const image = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(@intCast(chunk_load.max_image)));
    _ = try chunk_load.loadImageCall(client, .cpu0, image);
    try out.loaded(w, json, path, image.len);
}

fn readRegs(client: *Client, w: *std.Io.Writer, json: bool, regs: []const proto.Register) !void {
    var values: [32]out.Reg = undefined;
    for (regs, values[0..regs.len]) |reg, *value| {
        const read = try client.call(
            proto.U32,
            proto.ReadRegister,
            .read_register,
            .{ .core = .cpu0, .register = reg },
        );
        value.* = .{ .register = reg, .value = read.value };
    }
    try out.registers(w, json, values[0..regs.len]);
}

fn readMem(client: *Client, w: *std.Io.Writer, json: bool, address: u32, length: u32) !void {
    const args: proto.ReadMemory = .{ .core = .cpu0, .address = address, .length = length };
    const memory = try client.call(proto.Memory, proto.ReadMemory, .read_memory, args);
    try out.memory(w, json, address, memory.bytes);
}

fn setWatch(client: *Client, w: *std.Io.Writer, json: bool, address: u32, access: proto.Access) !void {
    const last = std.math.add(u32, address, watch_bytes - 1) catch return error.BadAddress;
    const args: proto.Watch = .{ .core = .cpu0, .first = address, .last = last, .access = access };
    const id = try client.call(proto.U32, proto.Watch, .set_watchpoint, args);
    try out.point(w, json, "watchpoint", id.value, address, access);
}

/// Bytes a `watch` covers from its address, the same span the debugger's
/// own watch command uses.
const watch_bytes = 4;

/// CPU0's sampled stacks folded for one thread and window (RA8EMU-833).
fn foldedRows(client: *Client, w: anytype, json: bool, asked: Folded) !void {
    const ask: proto.FoldedAsk = .{
        .core = .cpu0,
        .thread = asked.thread,
        .from_ns = asked.from_ns,
        .to_ns = asked.to_ns,
    };
    const rows = try client.call(proto.FoldedText, proto.FoldedAsk, .folded, ask);
    try out.folded(w, json, rows.text);
}

fn clear(client: *Client, w: anytype, json: bool, method: proto.Method, id: u32) !void {
    _ = try client.call(proto.Ack, proto.PointId, method, .{ .core = .cpu0, .id = id });
    try out.cleared(w, json, id);
}

/// Run with `budget` (or one step when null) and print the stop it ends in.
fn runTo(client: *Client, w: anytype, json: bool, budget: ?u64) !void {
    _ = try client.call(proto.Ack, proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .stop });
    if (budget) |instructions| {
        _ = try client.call(proto.Ack, proto.Run, .run, .{ .core = .cpu0, .mode = .cont, .budget = instructions });
    } else {
        _ = try client.call(proto.Ack, proto.CoreOnly, .step, .{ .core = .cpu0 });
    }
    try out.stopped(w, json, try client.stop());
}

fn inspect(client: *Client, w: *std.Io.Writer, json: bool, command: Command) !void {
    switch (command) {
        .map => {
            const map = try client.call(
                proto.MapText,
                proto.MapAsk,
                .map,
                .{ .core = .cpu0, .json = @intFromBool(json) },
            );
            try out.map(w, json, map.text);
        },
        .periph => |block| {
            const listed = try client.call(
                proto.PeriphText,
                proto.PeriphAsk,
                .periph,
                .{ .core = .cpu0, .json = @intFromBool(json), .block = block },
            );
            try out.periph(w, json, listed.text);
        },
        .folded => |asked| try foldedRows(client, w, json, asked),
        .stack => {
            const report = try client.call(proto.StackReport, proto.CoreOnly, .stack, .{ .core = .cpu0 });
            try out.stack(w, json, report);
        },
        .rtc => {
            const report = try client.call(proto.RtcReport, proto.CoreOnly, .rtc, .{ .core = .cpu0 });
            try out.rtc(w, json, report);
        },
        else => unreachable,
    }
}
