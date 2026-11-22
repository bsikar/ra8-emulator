//! Bounded annotated disassembly (`disassemble`) and packed row RPC (`disasm`).
const std = @import("std");

const api = @import("ra8_session").api;
const core_view = @import("ra8_session").core_view;
const decomp = @import("ra8_session").decomp;
const handlers = @import("handlers.zig");
const proto = @import("rpc.zig");
const rpc = @import("ra8_rpc_wire");
const session_disasm = @import("ra8_session").disasm;
const session_view = @import("ra8_session").view;
const symbols = @import("ra8_session").symbols;
const txm_debug = @import("ra8_session").txm.debug;
const wire = @import("disasm_wire.zig");

const Outcome = rpc.Outcome(proto.DisasmReply);

pub fn read(context: *handlers.Context, args: wire.Request) rpc.Outcome(wire.Reply) {
    const core: api.Core = if (args.core == .cpu0) .cpu0 else .cpu1;
    const view = context.session.view(core) catch |err| return if (err == error.CoreNotAttached)
        .{ .err = @fromBackingInt(@intCast(handlers.app_codes.no_core)) }
    else
        refuseRead();
    if (args.count == 0 or args.count > session_disasm.max_rows) return refuseRead();
    var rows: [session_disasm.max_rows]session_disasm.Row = undefined;
    const next = session_disasm.capture(
        view,
        handlers.imageOf(context, core),
        args.address,
        rows[0..args.count],
    ) catch return refuseRead();
    const room = @min(context.scratch.len, wire.Reply.max_len.text);
    var writer: std.Io.Writer = .fixed(context.scratch[0..room]);
    for (rows[0..args.count]) |row| session_disasm.write(row, &writer) catch return tooLong();
    return .{ .ok = .{ .core = args.core, .count = args.count, .next = next, .text = writer.buffered() } };
}

fn refuseRead() rpc.Outcome(wire.Reply) {
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}

fn tooLong() rpc.Outcome(wire.Reply) {
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.too_long)) };
}

pub fn disasm(context: *handlers.Context, args: proto.DisasmAsk) Outcome {
    const which: api.Core = @fromBackingInt(@intCast(@backingInt(args.core)));
    const pc = (context.session.register(which, .pc) catch |err| return refuse(err)) & ~@as(u32, 1);
    if (context.scratch.len < wire.disasm_bytes) return refuse(error.NoRoom);

    const requested: usize = if (args.count == 0) 24 else args.count;
    const count = @min(requested, wire.disasm_max_rows);
    var address: u32 = if (args.use_pc != 0) pc else (args.address & ~@as(u32, 1));
    const image = handlers.imageOf(context, which);
    const core_v: ?core_view.View = context.session.view(which) catch null;
    const alloc = context.gpa orelse std.heap.page_allocator;
    var decomp_cache: ?decomp.cache.CfgCache = decomp.cache.CfgCache.init(
        alloc,
        image,
        .{ .live = core_v },
    ) catch null;
    defer if (decomp_cache) |*c| c.deinit();

    var last_emit: ?*const decomp.emit.FunctionEmit = null;
    var at: usize = 0;
    var emitted: u8 = 0;
    for (0..count) |_| {
        var text_buf: [wire.disasm_text_cap]u8 = undefined;
        var pseudo_buf: [wire.disasm_pseudo_cap]u8 = undefined;
        var row = decodeOne(
            context.session,
            which,
            core_v,
            address,
            image,
            context.modules,
            &text_buf,
        ) catch |err| return refuse(err);
        row.pseudo = maybeLookupPseudo(&decomp_cache, &last_emit, &row, address, &pseudo_buf);
        wire.put(context.scratch[0..wire.disasm_bytes], &at, row) catch |err| return refuse(err);
        emitted += 1;
        address +%= if (row.size == 0) session_view.encoding.narrow else row.size;
    }

    return .{ .ok = .{
        .core = args.core,
        .pc = pc,
        .count = emitted,
        .rows = context.scratch[0..at],
    } };
}

fn maybeLookupPseudo(
    decomp_cache: *?decomp.cache.CfgCache,
    last_emit: *?*const decomp.emit.FunctionEmit,
    row: *const wire.DisasmRow,
    address: u32,
    pseudo_buf: *[wire.disasm_pseudo_cap]u8,
) []const u8 {
    if (row.decoded == 0) return "";
    const cache = if (decomp_cache.*) |*c| c else return "";
    return lookupPseudo(cache, last_emit, address, pseudo_buf);
}

fn lookupPseudo(
    cache: *decomp.cache.CfgCache,
    last_emit: *?*const decomp.emit.FunctionEmit,
    address: u32,
    pseudo_buf: *[wire.disasm_pseudo_cap]u8,
) []const u8 {
    const ext_entry = cache.extentEntry(address);
    const reuse = if (last_emit.*) |le|
        if (ext_entry) |ee| le.entry == ee else le.pseudoAt(address) != null
    else
        false;
    if (!reuse) {
        last_emit.* = cache.getEmit(address) catch null;
    }
    const em = last_emit.* orelse return "";
    const pseudo = em.pseudoAt(address) orelse return "";
    const len = @min(pseudo.len, pseudo_buf.len);
    @memcpy(pseudo_buf[0..len], pseudo[0..len]);
    return pseudo_buf[0..len];
}

fn decodeOne(
    session: *api.Session,
    core: api.Core,
    core_v: ?core_view.View,
    address: u32,
    image: ?symbols.Image,
    modules: ?*const txm_debug.Table,
    text_buf: *[wire.disasm_text_cap]u8,
) !wire.DisasmRow {
    var row: wire.DisasmRow = .{
        .address = address,
        .size = 0,
        .decoded = 0,
        .symbol = symbolAt(address, image, modules),
    };
    session.read(core, address, row.raw[0..2]) catch |err| {
        if (unreadable(err)) return row;
        return err;
    };
    const first = std.mem.readInt(u16, row.raw[0..2], .little);
    const wide = first >= session_view.encoding.wide_first;
    if (wide) {
        session.read(core, address +% 2, row.raw[2..4]) catch |err| {
            if (unreadable(err)) return row;
            return err;
        };
    }
    row.size = if (wide) 4 else 2;
    var formatted = session_disasm.one(address, row.raw[0..row.size]) catch return row;
    session_disasm.annotateLine(core_v, image, address, row.raw[0..row.size], &formatted);
    const slice = formatted.slice();
    const len = @min(slice.len, text_buf.len);
    @memcpy(text_buf[0..len], slice[0..len]);
    row.text = text_buf[0..len];
    row.decoded = 1;
    return row;
}

fn symbolAt(address: u32, image: ?symbols.Image, modules: ?*const txm_debug.Table) []const u8 {
    if (modules) |table| {
        if (table.inside(address)) |named| {
            if (named.offset == 0) return named.name[0..@min(named.name.len, wire.disasm_sym_cap)];
        }
    }
    const loaded = image orelse return "";
    if (symbols.inside(loaded, address)) |named| {
        if (named.offset == 0) return named.name[0..@min(named.name.len, wire.disasm_sym_cap)];
    }
    return "";
}

fn unreadable(err: anyerror) bool {
    return err == error.Unmapped or err == error.SecurityViolation;
}

fn refuse(err: anyerror) Outcome {
    if (err == error.CoreNotAttached) return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.no_core)) };
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}
