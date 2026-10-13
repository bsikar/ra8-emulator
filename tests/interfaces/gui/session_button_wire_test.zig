//! Over-the-wire test for a board pane click (RA8EMU-814): a spawned
//! `serve --stdio` session runs tests/fixtures/gpio/buttons.elf, which
//! mirrors SW1 onto LED1. Clicking SW1 through the pane's input handler at
//! the session's virtual time turns the LED on.
//!
//! The historical contract ran fixed 2_000 then 2x20_000 budgets and assumed
//! the board catches up after each run. Under the frozen boundary grid a
//! served run never catches the board up, so the press lands at the next
//! closed boundary instead. This test loops bounded semantic progress over
//! several budget schedules and asserts the same landing across all of
//! them: the press is ACKed but not yet observed, then lands exactly once,
//! lights LED1 and counts one press.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const proto = ra8.rpc.session.rpc;
const session_link = gui_app.session_link;
const pane = gui_app.board_pane;
const capture = gui_app.board.capture;
const input = gui_app.board.input;
const local_rig = @import("local_rig.zig");
const Link = session_link.Link;
const Wire = local_rig.Wire;
const Env = proto.Client.Env;

const elf_path = "tests/fixtures/gpio/buttons.elf";
/// buttons.elf counts press transitions in a word here.
const presses_address: u32 = 0x2200_0100;
/// The press must land within three full boundaries of awake instructions.
const landing_bound: u64 = 3 * frozen_width;
/// The served session's default frozen awake width (src/chip/core/cadence.zig).
const frozen_width: u64 = ra8.chip.periph.clocks.chunk_instructions;

const sample: pane.Parts = .{
    .panel = .{ .width = 1024, .height = 600 },
    .leds = &.{
        .{ .rgb565 = 0x001F, .name = "LED1 BLUE" },
        .{ .rgb565 = 0x07E0, .name = "LED2 GREEN" },
        .{ .rgb565 = 0xF800, .name = "LED3 RED" },
    },
    .switch_names = &.{ "SW1", "SW2" },
};
const ek_leds: usize = sample.leds.len;

fn clock() i64 {
    return std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds();
}

/// Pump until the answer to `id` arrives, folding LED events into `leds`.
fn answer(link: *Link, leds: *pane.Leds, id: u32) ![]const u8 {
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
            .event => |event| if (event.topic == @backingInt(proto.Topic.session)) {
                capture.observe(leds, ek_leds, try proto.decode(proto.SessionEvent, event.payload));
            },
        }
    }
    return error.Timeout;
}

/// `run` starts the image; once started, the session only continues it.
fn run(link: *Link, leds: *pane.Leds, mode: proto.RunMode, budget: u64) !void {
    _ = try answer(link, leds, try link.send(proto.Run, .run, .{ .core = .cpu0, .mode = mode, .budget = budget }));
}

/// The firmware's press count.
fn presses(link: *Link, leds: *pane.Leds) !u32 {
    const read: proto.ReadMemory = .{ .core = .cpu0, .address = presses_address, .length = 4 };
    const memory = try proto.decode(proto.Memory, try answer(link, leds, try link.send(proto.ReadMemory, .read_memory, read)));
    return std.mem.readInt(u32, memory.bytes[0..4], .little);
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

/// One full-width run, one narrow split, a ramp, and the fixed-seed mix.
const schedules = [_][]const u64{
    &.{50_000},
    &.{ 20_000, 20_000, 20_000, 20_000 },
    &.{ 1_000, 3_000, 7_000, 19_000, 50_000, 3_000 },
    &random_schedule,
};
const labels = [_][]const u8{ "wide", "split", "ramp", "random" };

/// One full scenario under one budget schedule: the press must not land
/// early, and must land exactly once at its real boundary under any split.
fn scenario(schedule: []const u64, label: []const u8) !void {
    var wire: Wire = .{};
    try wire.open(test_paths.emulator, elf_path);
    errdefer wire.kill();
    var leds: pane.Leds = .{};
    defer wire.deinit();

    // The LED mirror reaches this test as session-topic events, which only
    // flow once the client subscribes.
    _ = try answer(&wire.link, &leds, try wire.link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .session }));
    try run(&wire.link, &leds, .run, 2_000);
    try std.testing.expect(!leds.on[0]);
    try std.testing.expectEqual(@as(u32, 0), try presses(&wire.link, &leds));

    const layout = pane.Layout.of(.{ .x = 0, .y = 0, .w = 480, .h = 320 }, sample);
    const sw1 = layout.switches[0];
    const x = sw1.x + @divTrunc(sw1.w, 2);
    const y = sw1.y + @divTrunc(sw1.h, 2);
    var press: input.Press = .{};
    press.down(layout, x, y);
    const clicked = press.up(layout, x, y) orelse return error.NoClick;
    const now = try proto.decode(proto.U64, try answer(&wire.link, &leds, try wire.link.send(proto.Now, .now, .{ .core = .cpu0 })));
    const ack = try proto.decode(proto.Ack, try answer(&wire.link, &leds, try input.send(&wire.link, .cpu0, clicked, now.value)));
    try std.testing.expectEqual(@as(u32, 1), ack.accepted);
    // An ACK is not guest observation: the guest is halted, so the press
    // cannot have landed without a run.
    try std.testing.expectEqual(@as(u32, 0), try presses(&wire.link, &leds));

    var cumulative: u64 = 0;
    var index: usize = 0;
    while (cumulative < landing_bound) {
        const budget = schedule[index % schedule.len];
        index += 1;
        try run(&wire.link, &leds, .cont, budget);
        cumulative += budget;
        const count = try presses(&wire.link, &leds);
        if (count == 1) break;
        // Not early: before its real boundary the press stays unobserved
        // and LED1 stays off.
        try std.testing.expect(!leds.on[0]);
        try std.testing.expectEqual(@as(u32, 0), count);
    }
    std.debug.print("button[{s}]: frozen width {d}, landed within {d} awake instructions, due virtual ns {d}\n", .{ label, frozen_width, cumulative, now.value });
    // Exactly once: one held transition lights LED1 and counts one press.
    try std.testing.expectEqual(@as(u32, 1), try presses(&wire.link, &leds));
    try std.testing.expect(leds.on[0]);

    wire.deinit();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try wire.local.reap());
}

test "clicking SW1 on the board pane reaches the firmware under any budget schedule" {
    inline for (0..schedules.len) |i| try scenario(schedules[i], labels[i]);
}
