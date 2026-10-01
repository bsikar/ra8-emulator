//! A whole script run through a session over a compiled program, and the
//! transcript it prints.
//!
//! The program is the one tests/debug/step_hook_image_test.zig uses: a Zig
//! function built for thumb-freestanding-eabihf at ReleaseSmall and linked
//! at the start of SRAM, kept here as bytes:
//!
//!   target(x):  ldr r1,=counter; ldr r2,[r1]; add r0,r2; str r0,[r1]; bx lr
//!   reset():    calls target(0..4) in a loop, then target(1) forever
//!
//! The bytes carry no symbol table, so places here are addresses.
const std = @import("std");
const ra8 = @import("ra8");

const commands = ra8.core.commands;
const memmap = ra8.core.memmap;
const session = ra8.core.debug_session;
const stop_machine = ra8.core.stop_machine;
const step_hook = ra8.core.step_hook;
const Engine = ra8.core.engine.Engine;

const image = struct {
    const base: u32 = memmap.sram_base;
    const reset: u32 = base + 0x18;
    const stack: u32 = memmap.sram_base + 0x1F00;
    const budget: usize = 400;
    const bytes = [_]u8{
        0x00, 0x00, 0x01, 0x22, 0x19, 0x00, 0x00, 0x22, 0x02, 0x49, 0x0a, 0x68, 0x10,
        0x44, 0x08, 0x60, 0x70, 0x47, 0x00, 0xbf, 0x54, 0x00, 0x00, 0x22, 0x10, 0xb5,
        0x00, 0x24, 0x05, 0x2c, 0x04, 0xd0, 0x20, 0x46, 0xff, 0xf7, 0xf1, 0xff, 0x01,
        0x34, 0xf8, 0xe7, 0x01, 0x20, 0xff, 0xf7, 0xec, 0xff, 0xfb, 0xe7, 0x70, 0x47,
    };
};

const Fixture = struct {
    engine: Engine,
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,
    session: session.Session = undefined,

    fn open(self: *Fixture) !void {
        self.machine = .{};
        self.engine = try Engine.open();
        errdefer self.engine.close();
        try self.engine.mapBoardRam();
        try self.engine.write(image.base, &image.bytes);
        try self.engine.setRegister(.sp, image.stack);
        self.driver = .{ .machine = &self.machine };
        try step_hook.attach(self.engine.handle, &self.driver, true);
        self.session = .{ .core = &self.engine, .driver = &self.driver, .entry = image.reset, .budget = image.budget };
    }

    /// Run every line of `script` and return what the session printed.
    fn play(self: *Fixture, lines_text: []const u8, into: *std.ArrayList(u8)) !void {
        var lines = std.mem.splitScalar(u8, lines_text, '\n');
        while (lines.next()) |line| {
            const command = (try commands.parse(line)) orelse continue;
            if (try self.session.apply(command, into.writer()) == .quit) return;
        }
    }
};

const script =
    \\# stop on the third call into target, then look around
    \\break 0x22000008 3
    \\run
    \\info registers
    \\x 0x22000054 2
    \\p 0x22000054
    \\step
    \\step
    \\next
    \\finish
    \\disassemble 0x22000008 5
    \\bt
    \\tbreak 0x22000022
    \\continue
    \\continue
    \\delete 1
    \\watch 0x22000054
    \\continue
    \\core 1
    \\break nowhere
    \\delete 7
    \\quit
    \\step
;

const transcript_expected =
    \\Breakpoint 1 at 0x22000008, arrival 3
    \\Breakpoint 1, 0x22000008: ldr r1, [pc, #8]
    \\r0  0x00000002  r1  0x22000054  r2  0x00000000  r3  0x00000000
    \\r12 0x00000000  sp  0x22001EF8  lr  0x22000027  pc  0x22000008
    \\0x22000054: 0x00000001 0x00000000
    \\0x22000054 = 0x00000001 (1)
    \\0x2200000A: ldr r2, [r1]
    \\0x2200000C: add r0, r2
    \\0x2200000E: str r0, [r1]
    \\0x22000026: adds r4, #1
    \\0x22000008: ldr r1, [pc, #8]
    \\0x2200000A: ldr r2, [r1]
    \\0x2200000C: add r0, r2
    \\0x2200000E: str r0, [r1]
    \\0x22000010: bx lr
    \\#0 0x22000026
    \\#1 0x22000026
    \\Temporary breakpoint 2 at 0x22000022
    \\Temporary breakpoint 2, 0x22000022: bl #0x22000008
    \\Breakpoint 1, 0x22000008: ldr r1, [pc, #8]
    \\Deleted breakpoint 1
    \\Watchpoint 1 (write) at 0x22000054
    \\Watchpoint 1: write of 4 at 0x22000054, 0x22000010: bx lr
    \\error: CoreNotAttached
    \\error: NoSymbols
    \\error: NoSuchBreak
    \\
;

// What the script prints. A third arrival at target stops with r0 = 2,
// its argument, and the counter holding 0 + 1. A step over the add is a
// single step; finish lands after the call in reset. The temporary break
// is gone once it stops, the counted break stops on every arrival after
// its third, and the watch lands after the store. `quit` ends the script
// before the final `step`, and the bad lines say why without ending it.
test "a script drives the session through break, step, registers and memory" {
    var fixture: Fixture = undefined;
    try fixture.open();
    defer fixture.engine.close();
    var transcript = std.ArrayList(u8).init(std.testing.allocator);
    defer transcript.deinit();
    try fixture.play(script, &transcript);
    try std.testing.expectEqualStrings(transcript_expected, transcript.items);
}
