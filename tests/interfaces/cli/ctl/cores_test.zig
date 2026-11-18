//! Covers src/interfaces/cli/ctl/cores.zig and session RPC debugging on
//! sole-M33 and sole-M85: cores discovery, VPR register gating, step, break,
//! inspect, step-back, reset-image, snapshot, restore, and cross-target refusal.
const std = @import("std");

const cli_app = @import("cli_app");
const ra8 = @import("ra8");

const Bounded = ra8.chip.core.bounded.Bounded;
const cores_ctl = cli_app.ctl.cores;
const cores_rpc = ra8.rpc.session.cores;
const elf = ra8.board.image.elf;
const machine_mod = ra8.chip.core.machine;
const memmap = ra8.chip.core.memmap;
const proto = ra8.rpc.session.rpc;
const served = ra8.rpc.session.server;
const session_ctl = cli_app.session_ctl;

const page: usize = 0x1000;
const vectors: u32 = memmap.mram_base;
const reset_at: u32 = vectors + 0x40;
const stack: u32 = memmap.sram_base + 0x800;
const out_word: u32 = memmap.sram_base;

const sole_m33: machine_mod.Machine = .{
    .name = "sole-m33",
    .label = "SOLE-M33",
    .cores = .{
        .primary = machine_mod.core.cortexM33(.{
            .security = false,
            .fpu = .single,
            .systicks = 1,
        }),
    },
    .part = .ra8d2,
};

const sole_m85: machine_mod.Machine = .{
    .name = "sole-m85",
    .label = "SOLE-M85",
    .cores = .{
        .primary = machine_mod.core.cortexM85(.{
            .security = true,
            .fpu = .double,
            .systicks = 2,
        }),
    },
    .part = .ra8d2,
};

fn probeElf() [page * 2]u8 {
    var file: [page * 2]u8 align(@alignOf(elf.Header)) = @splat(0);
    const head: *elf.Header = @ptrCast(@alignCast(&file[0]));
    head.* = .{
        .magic = .{ 0x7f, 'E', 'L', 'F' },
        .class = 1,
        .data = 1,
        .version = 1,
        .osabi = 0,
        .abiversion = 0,
        .pad = @splat(0),
        .e_type = 2,
        .e_machine = elf.em_arm,
        .e_version = 1,
        .e_entry = reset_at | 1,
        .e_phoff = @sizeOf(elf.Header),
        .e_shoff = 0,
        .e_flags = 0,
        .e_ehsize = @sizeOf(elf.Header),
        .e_phentsize = @sizeOf(elf.ProgramHeader),
        .e_phnum = 1,
        .e_shentsize = 0,
        .e_shnum = 0,
        .e_shstrndx = 0,
    };
    const ph: *elf.ProgramHeader = @ptrCast(@alignCast(&file[@sizeOf(elf.Header)]));
    ph.* = .{
        .p_type = elf.pt_load,
        .p_offset = page,
        .p_vaddr = vectors,
        .p_paddr = vectors,
        .p_filesz = 0x100,
        .p_memsz = 0x100,
        .p_flags = 5,
        .p_align = 4,
    };
    std.mem.writeInt(u32, file[page..][0..4], stack, .little);
    std.mem.writeInt(u32, file[page + 4 ..][0..4], reset_at | 1, .little);
    const code = [_]u16{ 0x2001, 0x3002, 0x3003, 0x4902, 0x6008, 0xE7FE, 0xBF00, 0xBF00 };
    for (code, 0..) |hw, i| {
        std.mem.writeInt(u16, file[page + 0x40 + i * 2 ..][0..2], hw, .little);
    }
    std.mem.writeInt(u32, file[page + 0x50 ..][0..4], out_word, .little);
    return file;
}

const Env = proto.Client.Env;
const rpc = served.rpc_lib;

const Wire = struct {
    gpa: std.mem.Allocator,
    pipes: [2][]u8,
    rx: [2][]u8,
    tx: []u8,
    loop: rpc.Loopback = undefined,
    client: proto.Client = undefined,
    host: served.Host = undefined,
    stop: ?proto.Stopped = null,
    topics: Bounded(proto.Topic, 8) = .{},

    fn init(gpa: std.mem.Allocator, context: *served.Context) !*Wire {
        const self = try gpa.create(Wire);
        self.* = .{ .gpa = gpa, .pipes = undefined, .rx = undefined, .tx = try gpa.alloc(u8, Env.max_frame) };
        for (&self.pipes) |*pipe| pipe.* = try gpa.alloc(u8, 2 * Env.max_frame);
        for (&self.rx) |*rx| rx.* = try gpa.alloc(u8, 2 * Env.max_frame);
        self.loop = rpc.Loopback.init(self.pipes[0], self.pipes[1]);
        self.client = proto.Client.init(self.loop.a(), self.rx[0], proto.capabilities);
        self.host = served.Host.init(self.loop.b(), self.rx[1], context);
        try self.client.greet(self.tx);
        try std.testing.expectEqual(rpc.Step.greeted, try self.host.poll(self.tx));
        _ = (try self.client.poll(self.tx)).?;
        return self;
    }

    fn deinit(self: *Wire) void {
        for (self.pipes ++ self.rx) |buffer| self.gpa.free(buffer);
        self.gpa.free(self.tx);
        self.gpa.destroy(self);
    }

    fn call(self: *Wire, comptime Args: type, method: proto.Method, args: Args) !Env.Result {
        _ = try self.client.call(Args, @backingInt(method), args, 0, self.tx);
        try std.testing.expectEqual(rpc.Step.answered, try self.host.poll(self.tx));
        self.stop = null;
        self.topics.len = 0;
        var result: ?Env.Result = null;
        while (try self.client.poll(self.tx)) |incoming| switch (incoming) {
            .response => |response| result = response.result,
            .event => |event| {
                const known: proto.Topic = @fromBackingInt(@intCast(event.topic));
                try self.topics.append(known);
                if (known == .stop) self.stop = try proto.decode(proto.Stopped, event.payload);
            },
            .ready => return error.Unexpected,
        };
        return result orelse error.NoResponse;
    }

    fn ok(self: *Wire, comptime Reply: type, comptime Args: type, method: proto.Method, args: Args) !Reply {
        return switch (try self.call(Args, method, args)) {
            .ok => |bytes| try proto.decode(Reply, bytes),
            .err => error.Refused,
        };
    }
};

test "ctl parses cores and step-back and formats text and JSON core listings" {
    const gpa = std.testing.allocator;
    const req_cores = try session_ctl.parse(gpa, &.{ "emu", "ctl", "--connect", "tcp::1234", "cores" });
    try std.testing.expect(req_cores.command == .cores);
    const req_back = try session_ctl.parse(gpa, &.{ "emu", "ctl", "--connect", "tcp::1234", "step-back" });
    try std.testing.expect(req_back.command == .step_back);
    try std.testing.expectError(
        error.BadArguments,
        session_ctl.parse(gpa, &.{ "emu", "ctl", "--connect", "tcp::1234", "cores", "extra" }),
    );
    try std.testing.expectError(
        error.BadArguments,
        session_ctl.parse(gpa, &.{ "emu", "ctl", "--connect", "tcp::1234", "step-back", "1" }),
    );

    const bytes = probeElf();
    var h = try ra8.session.harness.open(gpa, std.testing.io, .{
        .elf_bytes = &bytes,
        .machine = &sole_m33,
        .history_frames = 0,
    });
    defer h.deinit();
    var scratch: [256]u8 = undefined;
    var ctx: served.Context = .{ .session = h.session(), .scratch = &scratch, .gpa = gpa };
    const listed = cores_rpc.listCores(&ctx, .{}).ok;

    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try cores_ctl.print(&writer, false, listed);
    try std.testing.expectEqualStrings(
        "sole-m33 cpu0: Cortex-M33 (attached, cpuid=0x410fd210, mve=false)\n",
        writer.buffered(),
    );
    writer.end = 0;
    try cores_ctl.print(&writer, true, listed);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("sole-m33", parsed.value.object.get("machine").?.string);
    const arr = parsed.value.object.get("cores").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), arr.len);
    try std.testing.expectEqualStrings("Cortex-M33", arr[0].object.get("name").?.string);
    try std.testing.expect(!arr[0].object.get("mve").?.bool);
}

test "sole-M33 and sole-M85 RPC sessions support step, break, step-back, reset, save, load and VPR gating" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir);
    const bytes = probeElf();
    const host_files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops);

    var m33 = try ra8.session.harness.open(gpa, std.testing.io, .{
        .elf_bytes = &bytes,
        .machine = &sole_m33,
        .history_frames = 8,
        .state_dir = dir,
        .files = host_files,
    });
    defer m33.deinit();
    var m85 = try ra8.session.harness.open(gpa, std.testing.io, .{
        .elf_bytes = &bytes,
        .machine = &sole_m85,
        .history_frames = 8,
        .state_dir = dir,
        .files = host_files,
    });
    defer m85.deinit();
    try checkSessionFlow(gpa, &m33, false, "m33.ra8snap");
    try checkSessionFlow(gpa, &m85, true, "m85.ra8snap");
    try checkCrossRestoreRefusal(gpa, &m33, "m85.ra8snap");
}

fn checkSessionFlow(
    gpa: std.mem.Allocator,
    h: *ra8.session.harness.Harness,
    has_mve: bool,
    snap_name: []const u8,
) !void {
    var scratch: [4096]u8 = undefined;
    var ctx: served.Context = .{
        .session = h.session(),
        .state = h.stateFiles(),
        .scratch = &scratch,
        .gpa = gpa,
    };
    const wire = try Wire.init(gpa, &ctx);
    defer wire.deinit();
    _ = try wire.ok(proto.Ack, proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .stop });

    const vpr_read = try wire.call(proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .vpr });
    const vpr_write = try wire.call(
        proto.WriteRegister,
        .write_register,
        .{ .core = .cpu0, .register = .vpr, .value = 7 },
    );
    try std.testing.expectEqual(has_mve, vpr_read == .ok);
    try std.testing.expectEqual(has_mve, vpr_write == .ok);

    _ = try wire.ok(proto.Ack, proto.CoreOnly, .step, .{ .core = .cpu0 });
    try std.testing.expectEqual(reset_at + 2, wire.stop.?.address);
    _ = try wire.ok(proto.Ack, proto.CoreOnly, .step, .{ .core = .cpu0 });
    try std.testing.expectEqual(reset_at + 4, wire.stop.?.address);

    _ = try wire.ok(proto.Ack, proto.CoreOnly, .step_back, .{ .core = .cpu0 });
    try std.testing.expectEqual(reset_at + 2, wire.stop.?.address);
    try std.testing.expectEqual(@as(u32, 1), (try wire.ok(
        proto.U32,
        proto.ReadRegister,
        .read_register,
        .{ .core = .cpu0, .register = .r0 },
    )).value);

    _ = try wire.ok(
        proto.U32,
        proto.Point,
        .set_breakpoint,
        .{ .core = .cpu0, .address = reset_at + 0x0A },
    );
    _ = try wire.ok(proto.Ack, proto.Run, .run, .{ .core = .cpu0, .mode = .cont, .budget = 32 });
    try std.testing.expectEqual(reset_at + 0x0A, wire.stop.?.address);
    const mem = try wire.ok(
        proto.Memory,
        proto.ReadMemory,
        .read_memory,
        .{ .core = .cpu0, .address = out_word, .length = 4 },
    );
    try std.testing.expectEqual(@as(u32, 6), std.mem.readInt(u32, mem.bytes[0..4], .little));
    const dis = try wire.ok(
        proto.Disassembly,
        proto.Disassemble,
        .disassemble,
        .{ .core = .cpu0, .address = reset_at, .count = 2 },
    );
    try std.testing.expectEqual(@as(u16, 2), dis.count);

    _ = try wire.ok(proto.Ack, proto.StatePath, .snapshot, .{ .path = snap_name });
    _ = try wire.ok(proto.Ack, proto.CoreOnly, .reset_image, .{ .core = .cpu0 });
    try std.testing.expectEqual(reset_at, try h.session().register(.cpu0, .pc));
    try std.testing.expectEqual(@as(u32, 0), try h.guest().readWord(out_word));

    _ = try wire.ok(proto.Ack, proto.StatePath, .restore, .{ .path = snap_name });
    try std.testing.expectEqual(reset_at + 0x0A, try h.session().register(.cpu0, .pc));
    try std.testing.expectEqual(@as(u32, 6), try h.guest().readWord(out_word));
}

fn checkCrossRestoreRefusal(
    gpa: std.mem.Allocator,
    m33: *ra8.session.harness.Harness,
    other_snap: []const u8,
) !void {
    try m33.guest().writeWord(out_word, 0xCAFE_BABE);
    try m33.session().setRegister(.cpu0, .r0, 0x1357_2468);
    var scratch: [4096]u8 = undefined;
    var ctx: served.Context = .{
        .session = m33.session(),
        .state = m33.stateFiles(),
        .scratch = &scratch,
        .gpa = gpa,
    };
    const wire = try Wire.init(gpa, &ctx);
    defer wire.deinit();
    const res = try wire.call(proto.StatePath, .restore, .{ .path = other_snap });
    try std.testing.expect(res == .err);
    try std.testing.expectEqual(@as(u32, 0xCAFE_BABE), try m33.guest().readWord(out_word));
    try std.testing.expectEqual(@as(u32, 0x1357_2468), try m33.session().register(.cpu0, .r0));
}
