//! Covers src/core/cpu/exception/nvic_source.zig: the NVIC model reading and
//! writing its registers through the Zig core's bus.
const std = @import("std");
const ra8 = @import("ra8");
const NvicSource = ra8.core.cpu.exception.nvic_source.NvicSource;
const fixture = @import("ram.zig");

const icsr: u32 = 0xE000_ED04;
const shpr3: u32 = 0xE000_ED20;
const iser0: u32 = 0xE000_E100;
const ispr0: u32 = 0xE000_E200;
const iabr0: u32 = 0xE000_E300;
const ipr0: u32 = 0xE000_E400;

test "nothing pending gives no winner" {
    var ram: fixture.Ram = .{};
    var nvic: NvicSource = .{};
    try std.testing.expect((try nvic.source().winner(ram.view())) == null);
}

test "PendSV comes with its SHPR3 priority and taking it clears the pend" {
    var ram: fixture.Ram = .{};
    var nvic: NvicSource = .{};
    ram.putWord(icsr, 1 << 28);
    ram.putWord(shpr3, 0xE0F0_0000);
    const source = nvic.source();
    const found = (try source.winner(ram.view())).?;
    try std.testing.expectEqual(@as(u9, 14), found.number);
    try std.testing.expectEqual(@as(u8, 0xF0), found.priority);
    try source.taken(ram.view(), 14);
    try std.testing.expectEqual(@as(u32, 0), ram.word(icsr) & (1 << 28));
}

test "an enabled IRQ line wins over a less urgent PendSV and is marked active" {
    var ram: fixture.Ram = .{};
    var nvic: NvicSource = .{};
    ram.putWord(icsr, 1 << 28);
    ram.putWord(shpr3, 0xF0F0_0000);
    ram.putWord(iser0, 1 << 3);
    ram.putWord(ispr0, 1 << 3);
    ram.putWord(ipr0, 0x4000_0000); // line 3 at 0x40
    const source = nvic.source();
    const found = (try source.winner(ram.view())).?;
    try std.testing.expectEqual(@as(u9, 16 + 3), found.number);
    try source.taken(ram.view(), found.number);
    try std.testing.expectEqual(@as(u32, 0), ram.word(ispr0));
    try std.testing.expectEqual(@as(u32, 1 << 3), ram.word(iabr0));
    try source.returned(ram.view(), found.number);
    try std.testing.expectEqual(@as(u32, 0), ram.word(iabr0));
}

test "a pending line that is not enabled is not a winner" {
    var ram: fixture.Ram = .{};
    var nvic: NvicSource = .{};
    ram.putWord(ispr0, 1 << 3);
    try std.testing.expect((try nvic.source().winner(ram.view())) == null);
}
