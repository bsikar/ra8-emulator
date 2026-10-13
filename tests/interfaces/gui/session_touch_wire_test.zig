//! Over-the-wire test for a touch on the board pane's panel (RA8EMU-812): a
//! spawned `serve --stdio` session runs tests/fixtures/touch/touch.elf, which
//! reads the GT911 over I3C and stores the last contact in SRAM. A press on
//! the pane's shown panel goes through board_touch at the session's virtual
//! time, and the firmware's touch driver reads the same panel coordinates.
//!
//! The historical contract assumed the board catches up after each fixed
//! 20_000 run. Under the frozen boundary grid a served run never catches the
//! board up, so the contact lands at the next closed boundary instead. This
//! test loops bounded semantic progress over several budget schedules and
//! asserts the same landing across all of them: the touch is ACKed but not
//! yet observed, then lands exactly once at the sent coordinates.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const proto = ra8.rpc.session.rpc;
const session_link = gui_app.session_link;
const pane = gui_app.board_pane;
const touch = gui_app.board.touch;
const local_rig = @import("local_rig.zig");
const Link = session_link.Link;
const Wire = local_rig.Wire;
const Env = proto.Client.Env;

const elf_path = "tests/fixtures/touch/touch.elf";
const width: u32 = 1024;
const height: u32 = 600;
/// touch.elf keeps x, y (u16 each) and a u32 count here.
const report_address: u32 = 0x2200_0100;
/// The contact must land within three full boundaries of awake instructions.
const landing_bound: u64 = 3 * frozen_width;
/// The served session's default frozen awake width (src/chip/core/cadence.zig).
const frozen_width: u64 = ra8.chip.periph.clocks.chunk_instructions;

fn clock() i64 {
    return std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds();
}

/// Pump until the answer to `id` arrives.
fn answer(link: *Link, id: u32) ![]const u8 {
    const deadline = clock() + 10_000;
    while (clock() < deadline) {
        if (link.state != .connected) return error.LinkLost;
        const arrival = link.pump() orelse {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
            continue;
        };
        switch (arrival) {
            .response => |response| if (response.id == id) return switch (response.result) {
                .ok => |bytes| bytes,
                .err => error.Refused,
            },
            .event => {},
        }
    }
    return error.Timeout;
}

fn run(link: *Link, mode: proto.RunMode, budget: u64) !void {
    _ = try answer(link, try link.send(proto.Run, .run, .{ .core = .cpu0, .mode = mode, .budget = budget }));
}

const Report = struct { x: u16, y: u16, count: u32 };

fn report(link: *Link) !Report {
    const read: proto.ReadMemory = .{ .core = .cpu0, .address = report_address, .length = 8 };
    const memory = try proto.decode(proto.Memory, try answer(link, try link.send(proto.ReadMemory, .read_memory, read)));
    const bytes = memory.bytes;
    return .{
        .x = std.mem.readInt(u16, bytes[0..2], .little),
        .y = std.mem.readInt(u16, bytes[2..4], .little),
        .count = std.mem.readInt(u32, bytes[4..8], .little),
    };
}

/// A fixed-seed random mix: budgets drawn in [1_000, 60_000] by a comptime
/// LCG, so every mirror runs the same draws.
const random_schedule: [12]u64 = blk: {
    @setEvalBranchQuota(10_000);
    var seed: u64 = 0x5EED_0123_4567_89AB;
    var out: [12]u64 = undefined;
    for (&out) |*budget| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        budget.* = 1_000 + (seed >> 33) % 59_000;
    }
    break :blk out;
};

/// One full-width run, one narrow split, and the fixed-seed mix.
const schedules = [_][]const u64{
    &.{50_000},
    &.{ 20_000, 20_000, 20_000, 20_000 },
    &random_schedule,
};
const labels = [_][]const u8{ "wide", "split", "random" };

/// Press and release at (x, y) in window pixels, then loop bounded semantic
/// progress until the firmware's count advances. The touch must not land
/// early and must land exactly once.
fn tapAt(link: *Link, shown: ra8.render.draw_list.Rect, x: i32, y: i32, before: u32, schedule: []const u64, label: []const u8) !void {
    const now = try proto.decode(proto.U64, try answer(link, try link.send(proto.Now, .now, .{ .core = .cpu0 })));
    var drag: touch.Drag = .{};
    drag.down(shown, width, height, x, y, now.value);
    const gesture = drag.up(shown, width, height, x, y, now.value) orelse return error.NoGesture;
    try std.testing.expectEqual(proto.InputKind.tap, gesture.kind);
    const ack = try proto.decode(proto.Ack, try answer(link, try touch.send(link, .cpu0, gesture, now.value)));
    try std.testing.expectEqual(@as(u32, 1), ack.accepted);
    // An ACK is not guest observation: the guest is halted, so the contact
    // cannot have landed without a run.
    try std.testing.expectEqual(before, (try report(link)).count);

    var cumulative: u64 = 0;
    var index: usize = 0;
    while (cumulative < landing_bound) {
        const budget = schedule[index % schedule.len];
        index += 1;
        try run(link, .cont, budget);
        cumulative += budget;
        if ((try report(link)).count != before) break;
    }
    std.debug.print("touch[{s}]: frozen width {d}, landed within {d} awake instructions, due virtual ns {d}\n", .{ label, frozen_width, cumulative, now.value });
    // Exactly once: the count advances by one and no further.
    try std.testing.expectEqual(before + 1, (try report(link)).count);
}

/// One full scenario under one budget schedule: two taps on fresh sessions
/// land identically; the first session carries the second tap for the
/// cumulative guest state.
fn scenario(schedule: []const u64, label: []const u8, carries_second_tap: bool) !void {
    var wire: Wire = .{};
    try wire.open(test_paths.emulator, elf_path);
    errdefer wire.kill();
    defer wire.deinit();

    try run(&wire.link, .run, 2_000);
    try std.testing.expectEqual(@as(u32, 0), (try report(&wire.link)).count);

    const layout = pane.Layout.of(.{ .x = 0, .y = 0, .w = 480, .h = 320 }, sample);
    const shown = touch.shownIn(layout, width, height);
    const mid_x = shown.x + @divTrunc(shown.w, 2);
    const mid_y = shown.y + @divTrunc(shown.h, 2);
    try tapAt(&wire.link, shown, mid_x, mid_y, 0, schedule, label);
    const mid = touch.toPanel(shown, width, height, mid_x, mid_y);
    try std.testing.expectEqual(Report{ .x = mid.x, .y = mid.y, .count = 1 }, try report(&wire.link));

    if (carries_second_tap) {
        try tapAt(&wire.link, shown, shown.x + shown.w - 1, shown.y + shown.h - 1, 1, schedule, label);
        try std.testing.expectEqual(Report{ .x = width - 1, .y = height - 1, .count = 2 }, try report(&wire.link));
    }

    wire.deinit();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try wire.local.reap());
}
const sample: pane.Parts = .{
    .panel = .{ .width = 1024, .height = 600 },
    .leds = &.{
        .{ .rgb565 = 0x001F, .name = "LED1 BLUE" },
        .{ .rgb565 = 0x07E0, .name = "LED2 GREEN" },
        .{ .rgb565 = 0xF800, .name = "LED3 RED" },
    },
    .switch_names = &.{ "SW1", "SW2" },
};

test "a touch on the board pane's panel reaches the firmware's touch driver under any budget schedule" {
    inline for (0..schedules.len) |i| try scenario(schedules[i], labels[i], i == 0);
}
