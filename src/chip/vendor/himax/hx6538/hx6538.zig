//! Himax HX6538 (WE2 / Grove Vision AI V2) silicon package.
pub const idau = @import("idau.zig");
pub const machine = @import("machine.zig");
pub const mailbox = @import("mailbox.zig");
pub const scu = @import("scu.zig");
pub const timer = @import("timer.zig");
pub const uart = @import("uart.zig");

pub const irqs = struct {
    pub const mailbox: u16 = 7;
    pub const timer_base_0: u16 = 34;
    pub const timer_base_6: u16 = 47;
    pub const uart0: u16 = 90;
    pub const uart1: u16 = 91;
    pub const uart2: u16 = 95;
    pub const ethos_u55: u16 = 192;
    pub const lines: u16 = 224;
};

pub const Periph = struct {
    scu: scu.Scu = .{},
    mailbox: mailbox.Mailbox = .{},
    uarts: uart.Bank = .{},
    timers: timer.Bank = .{},
};
