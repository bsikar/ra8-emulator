const std = @import("std");

const builtin = @import("builtin");
const ra8 = @import("ra8");
const slow_peer = @import("slow_peer.zig");

const elf = ra8.board.image.elf;
const io = std.testing.io;
const listener_mod = ra8.rpc.host_listener;
const machine_mod = ra8.chip.core.machine;
const memmap = ra8.chip.core.memmap;
const ready = ra8.host.sock.ready;
const served_setup = ra8.rpc.served_setup;

fn homePath(gpa: std.mem.Allocator) ![]u8 {
    const parent = if (@import("builtin").os.tag == .windows)
        try (std.process.Environ{ .block = .global }).getAlloc(gpa, "TEMP")
    else
        try gpa.dupe(u8, "/tmp");
    defer gpa.free(parent);
    return std.fmt.allocPrint(gpa, "{s}/ra8_gdb_{d}", .{ parent, std.Io.Timestamp.now(io, .awake).nanoseconds });
}

fn packet(host: anytype, client: std.Io.net.Stream, out: []u8) ![]const u8 {
    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 2000;
    var used: usize = 0;
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        host.pump();
        if (!(try ready.wait(io, client.socket.handle, 0)).any()) {
            try io.sleep(.fromMilliseconds(1), .awake);
            continue;
        }
        var byte: [1]u8 = undefined;
        if ((ready.takeByte(io, client.socket.handle, &byte, false) orelse return error.LinkDown) == 0) return error.LinkDown;
        if (used == out.len) return error.Overflow;
        out[used] = byte[0];
        used += 1;
        if (used >= 3 and out[used - 3] == '#') return out[0..used];
    }
    return error.Timeout;
}

test "host GDB serves ordinary packets, reconnects and drops a slow peer in finite time" {
    const gpa = std.testing.allocator;
    const home = try homePath(gpa);
    defer gpa.free(home);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HOME", home);
    var opened: served_setup.Served = undefined;
    try opened.open(gpa, io, "tests/fixtures/fpu/fp_basic.elf", null, null);
    defer opened.deinit();
    var bound = try listener_mod.Listener.bind(gpa, io, &env);
    defer bound.deinit();
    const port = try bound.addGdb("fixture.elf", opened.context.session);
    const host = bound.gdb.items[0];
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
    for (0..4) |_| {
        const client = try address.connect(io, .{ .mode = .stream });
        var live = true;
        defer if (live) client.close(io);
        try ready.sendAll(io, client.socket.handle, "$qSupported#37", 1000);
        var buffer: [1024]u8 = undefined;
        const response = try packet(host, client, &buffer);
        try std.testing.expect(std.mem.indexOf(u8, response, "PacketSize=") != null);
        client.close(io);
        live = false;
        const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 2000;
        while (host.client != null and std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) host.pump();
        try std.testing.expect(host.client == null);
    }
    const client = try slow_peer.connect(port);
    defer client.close(io);
    try takeClient(host);
    const bytes = try gpa.alloc(u8, 16 * 1024 * 1024);
    defer gpa.free(bytes);
    @memset(bytes, 'g');
    var saturated = false;
    for (0..16) |_| {
        ready.sendAll(io, host.client.?.stream.socket.handle, bytes, 20) catch |err| {
            try std.testing.expectEqual(error.Timeout, err);
            saturated = true;
            break;
        };
    }
    try std.testing.expect(saturated);
    try slow_peer.block(host.client.?.stream);
    try ready.sendAll(io, client.socket.handle, "$qSupported#37", 1000);
    const start = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    while (host.client != null and std.Io.Timestamp.now(io, .awake).toMilliseconds() - start < 2000) host.pump();
    try std.testing.expect(host.client == null);
}

/// A frame pump may observe accept readiness after connect has returned.
fn takeClient(host: anytype) !void {
    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 2000;
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        host.pump();
        if (host.client != null) return;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

test "host GDB sends port 0's console text as O packets ahead of the stop reply" {
    const gpa = std.testing.allocator;
    const home = try homePath(gpa);
    defer gpa.free(home);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HOME", home);
    var opened: served_setup.Served = undefined;
    try opened.open(gpa, io, "tests/fixtures/fpu/fp_basic.elf", null, null);
    defer opened.deinit();
    var bound = try listener_mod.Listener.bind(gpa, io, &env);
    defer bound.deinit();
    const port = try bound.addGdb("fixture.elf", opened.context.session);
    const host = bound.gdb.items[0];
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
    const client = try address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    try takeClient(host);

    // Print through stimulus port 0 while the target is paused.
    const itm = ra8.chip.periph.itm;
    const itmp = try opened.context.session.itmPort(opened.context.session.currentCore());
    _ = itmp.write(itm.offsets.tcr, itm.tcr_bits.itmena, 4);
    _ = itmp.write(itm.offsets.ter, 1, 4);
    for ("host console\n") |ch| _ = itmp.write(itm.offsets.stim0, ch, 1);

    // A single step is a resume: its console text goes out as O packets
    // before the stop reply, and the port is then empty.
    try ready.sendAll(io, client.socket.handle, "$s#73", 1000);
    var buffer: [1024]u8 = undefined;
    const console_packet = try packet(host, client, &buffer);
    try std.testing.expect(std.mem.startsWith(u8, console_packet, "$O"));
    const hex = console_packet[2 .. console_packet.len - 3];
    var said: [64]u8 = undefined;
    const said_len = hex.len / 2;
    try std.testing.expect(said_len <= said.len);
    try std.testing.expectEqual(@as(usize, 2 * said_len), hex.len);
    for (0..said_len) |at| {
        said[at] = try std.fmt.parseInt(u8, hex[at * 2 .. at * 2 + 2], 16);
    }
    try std.testing.expect(std.mem.startsWith(u8, said[0..said_len], "host console\n"));
    const stop = try packet(host, client, &buffer);
    try std.testing.expect(stop.len > 1 and (stop[1] == 'T' or stop[1] == 'S'));
    try std.testing.expectEqual(@as(usize, 0), itmp.output().len);
}

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

fn soleM33Elf() [0x2000]u8 {
    const page: usize = 0x1000;
    const reset_at: u32 = memmap.mram_base + 0x40;
    var file: [0x2000]u8 align(@alignOf(elf.Header)) = @splat(0);
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
        .p_vaddr = memmap.mram_base,
        .p_paddr = memmap.mram_base,
        .p_filesz = 0x100,
        .p_memsz = 0x100,
        .p_flags = 5,
        .p_align = 4,
    };
    std.mem.writeInt(u32, file[page..][0..4], memmap.sram_base + 0x800, .little);
    std.mem.writeInt(u32, file[page + 4 ..][0..4], reset_at | 1, .little);
    const code = [_]u16{ 0x2001, 0x3002, 0x3003, 0xE7FE };
    for (code, 0..) |hw, i| {
        std.mem.writeInt(u16, file[page + 0x40 + i * 2 ..][0..2], hw, .little);
    }
    return file;
}

fn findGdbBinary(gpa: std.mem.Allocator) !?[]u8 {
    if (builtin.os.tag == .windows) {
        const win_arm =
            "C:\\Program Files (x86)\\Arm GNU Toolchain arm-none-eabi\\14.2 rel1\\bin\\arm-none-eabi-gdb.exe";
        if (std.Io.Dir.accessAbsolute(io, win_arm, .{})) |_| return try gpa.dupe(u8, win_arm) else |_| {}
    }
    for ([_][]const u8{ "arm-none-eabi-gdb", "gdb-multiarch" }) |name| {
        var child = std.process.spawn(io, .{
            .argv = &.{ name, "--version" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch continue;
        if ((child.wait(io) catch continue).success()) return try gpa.dupe(u8, name);
    }
    return null;
}

test "real GDB client attaches to sole-M33, reads armv8-m.main, sees one thread, steps and breaks" {
    const gpa = std.testing.allocator;
    const gdb_bin = (try findGdbBinary(gpa)) orelse return error.SkipZigTest;
    defer gpa.free(gdb_bin);

    const home = try homePath(gpa);
    defer gpa.free(home);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);

    const bytes = soleM33Elf();
    var h = try ra8.session.harness.open(gpa, io, .{
        .elf_bytes = &bytes,
        .machine = &sole_m33,
        .history_frames = 8,
    });
    defer h.deinit();

    const listen_addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen_addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const log_raw = try std.fs.path.join(gpa, &.{ home, "gdb.log" });
    defer gpa.free(log_raw);
    const log_fwd = try gpa.dupe(u8, log_raw);
    defer gpa.free(log_fwd);
    std.mem.replaceScalar(u8, log_fwd, '\\', '/');
    const script_path = try std.fs.path.join(gpa, &.{ home, "commands.gdb" });
    defer gpa.free(script_path);
    const script = try std.fmt.allocPrint(
        gpa,
        "set pagination off\nset confirm off\nset logging file {s}\n" ++
            "set logging overwrite on\nset logging enabled on\n" ++
            "target remote 127.0.0.1:{d}\nshow architecture\ninfo threads\n" ++
            "stepi\nbreak *0x02000046\ncontinue\ninfo registers r0 pc\n" ++
            "set logging enabled off\ndetach\nquit\n",
        .{ log_fwd, port },
    );
    defer gpa.free(script);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });

    var child = try std.process.spawn(io, .{
        .argv = &.{ gdb_bin, "--nx", "--quiet", "--batch", "-x", script_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(io);
    try serveOneGdb(&server, &h);
    try std.testing.expect((try child.wait(io)).success());

    const logged = try std.Io.Dir.cwd().readFileAlloc(io, log_raw, gpa, .unlimited);
    defer gpa.free(logged);
    try std.testing.expect(std.mem.indexOf(u8, logged, "armv8-m.main") != null);
    try std.testing.expect(std.mem.indexOf(u8, logged, "armv8.1-m.main") == null);
    try std.testing.expect(std.mem.indexOf(u8, logged, "CPU0 (Cortex-M33, armv8-m.main)") != null);
    try std.testing.expect(std.mem.indexOf(u8, logged, "Thread 2") == null);
    try std.testing.expect(std.mem.indexOf(u8, logged, "0x6") != null);
    try std.testing.expect(std.mem.indexOf(u8, logged, "0x2000046") != null);
}

fn serveOneGdb(server: *std.Io.net.Server, h: *ra8.session.harness.Harness) !void {
    const rsp_dispatch = ra8.gdb.rsp.dispatch;
    const rsp_poll = ra8.gdb.rsp.poll;
    var wall_clock = ra8.session.run.pacer.HostClock.init(io);
    const stream = try server.accept(io);
    defer stream.close(io);
    var socket: rsp_poll.Socket = .{ .handle = stream.socket.handle, .io = io };
    try h.session().setRunBudget(.cpu0, rsp_poll.chunk);
    var target: rsp_dispatch.zig_run.Target = .{
        .session = h.session(),
        .poll = socket.poll(),
        .transport = h.transport(),
        .wall = wall_clock.wall(),
    };
    const stub: rsp_dispatch.Dispatch = .{ .zig = &target };
    var in: [rsp_dispatch.server.limits.chunk]u8 = undefined;
    var out: [rsp_dispatch.server.limits.framed]u8 = undefined;
    var reader = stream.reader(io, &in);
    var writer = stream.writer(io, &out);
    const end = try rsp_dispatch.server.serve(stub, &reader.interface, &writer.interface);
    try std.testing.expectEqual(rsp_dispatch.server.End.detached, end);
}
