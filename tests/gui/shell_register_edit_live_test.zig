//! Host test for register edits against a live session (RA8EMU-946): a
//! spawned `serve --stdio` on fp_basic takes one write per group from the
//! shell's register editor (system MSPLIM, FPU S3, MVE VPR and a q lane),
//! and each value comes back in the leaf's next batch of reads.
const std = @import("std");
const ra8 = @import("ra8");
const test_paths = @import("test_paths");
const proto = ra8.interfaces.rpc.session;
const platform = ra8.gui.platform;
const hex_entry = ra8.gui.hex_entry;
const registers_pane = ra8.gui.registers_pane;
const shell_registers = ra8.gui.shell_registers;
const edit = ra8.gui.shell_register_edit;
const session_link = ra8.gui.session_link;
const Link = session_link.Link;
const Env = proto.Client.Env;

const image_path = "tests/fixtures/fpu/fp_basic.elf";
const shown = registers_pane.shown;

const Shell = struct {
    registers: shell_registers.Pair = .{},
    editor: edit.Editor = .{},

    fn observe(self: *Shell, arrival: session_link.Arrival) void {
        self.registers.observe(arrival);
        _ = self.editor.observe(&self.registers, arrival);
    }

    /// cpu0 has published batch `serial` and no write is in flight.
    fn settled(self: *const Shell, serial: u32) bool {
        const model = &self.registers.cores[0];
        return self.editor.asked == null and model.serial == serial and model.left == 0 and !model.want;
    }
};

fn nowMs() i64 {
    return std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds();
}

/// Pump for up to ten seconds: until connected when `serial` is null, else
/// until cpu0 settles on batch `serial`.
fn pumpUntil(link: *Link, shell: *Shell, serial: ?u32) !void {
    const deadline = nowMs() + 10_000;
    while (nowMs() < deadline) {
        if (link.state != .connecting and link.state != .connected) return error.LinkDown;
        shell.registers.attach(link);
        if (link.pump()) |arrival| {
            shell.observe(arrival);
            continue;
        }
        const done = if (serial) |want| shell.settled(want) else link.state == .connected;
        if (done) return;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

/// Write `digits` into `cell` of cpu0 through the editor and wait for the
/// read-back batch.
fn write(link: *Link, shell: *Shell, cell: usize, digits: []const u8) !void {
    const serial = shell.registers.cores[0].serial +% 1;
    shell.editor.open = .{ .core = .cpu0, .cell = cell };
    try std.testing.expect(shell.editor.handle(link, .{ .text = platform.Text.of(digits) }));
    try std.testing.expect(shell.editor.handle(link, .{ .key = .{ .code = hex_entry.codes.enter, .down = true } }));
    try std.testing.expect(shell.editor.asked != null);
    try pumpUntil(link, shell, serial);
    try std.testing.expectEqual(@as(?[]const u8, null), shell.editor.note(.cpu0));
}

fn cellOf(which: shell_registers.Register) usize {
    return std.mem.indexOfScalar(shell_registers.Register, &shown, which).?;
}

test "a spawned serve --stdio takes one register write per group and reads it back" {
    const gpa = std.testing.allocator;
    var local: session_link.Local = undefined;
    try local.spawn(std.testing.io, test_paths.emulator, image_path);
    errdefer local.child.kill(std.testing.io);
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: Link = undefined;
    link.open(local.transport(), rx, tx);
    var shell: Shell = .{};
    try pumpUntil(&link, &shell, null);
    _ = try link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .stop });
    _ = try link.send(proto.Run, .run, .{ .core = .cpu0, .mode = .step, .budget = 0 });
    try pumpUntil(&link, &shell, 1);
    const model = &shell.registers.cores[0];

    try write(&link, &shell, cellOf(.msplim), "20000100");
    try std.testing.expectEqual(@as(?u32, 0x2000_0100), model.value(.msplim));
    try write(&link, &shell, cellOf(.s3), "40490FDB");
    try std.testing.expectEqual(@as(?u32, 0x4049_0FDB), model.value(.s3));
    try write(&link, &shell, cellOf(.vpr), "001200FF");
    try std.testing.expectEqual(@as(?u32, 0x0012_00FF), model.value(.vpr));
    // q1[2] aliases S6.
    try write(&link, &shell, shown.len + 6, "12345678");
    try std.testing.expectEqual(@as(?u32, 0x1234_5678), model.value(.s6));

    local.end();
    while (link.state == .connected) {
        if (link.pump() == null) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    _ = try local.reap();
}
