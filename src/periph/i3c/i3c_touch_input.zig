//! Host touches fed to the GT911 while the firmware runs (RA8EMU-343).
//!
//! `--touch @PATH` opens PATH (a file or a FIFO) without blocking, and each
//! board boundary moves the complete lines waiting on it onto the panel's
//! queue, the way host stdin reaches SCI8 under `--console`. A line is
//! "X,Y", optionally led by "down " or "move "; a drag is a run of lines,
//! one contact per frame. "up" and blank lines are accepted and add
//! nothing: this panel model reports single contacts, so a release is
//! simply the next frame with nothing armed.
//!
//! The same stream carries the two user switches (RA8EMU-344): "sw1 down",
//! "sw1 up", "sw2 down" and "sw2 up" drive P009 and P008 through the GPIO
//! model, active-low as the board wires them, so the firmware's PIDR reads
//! see the press for as long as it is held. Each real level change is also
//! queued as an edge on the switch's IRQ channel (SW1 IRQ13, SW2 IRQ12, as
//! the board code wires them), and the boundary raises it when PFS ISEL and
//! IRQCR say the part would (RA8EMU-375).
const std = @import("std");
const gt911 = @import("i3c_gt911.zig");
const gpio = @import("../gpio/gpio.zig");
const pin_irq = @import("../icu/icu_pin_irq.zig");
const host_read = @import("../host_read.zig");

/// The host-side name of each user switch, the pin it drives and the IRQ
/// channel that pin feeds.
pub const switches = [_]struct { name: []const u8, pin: u4, irq: u8 }{
    .{ .name = "sw1", .pin = gpio.sw1_pin, .irq = 13 },
    .{ .name = "sw2", .pin = gpio.sw2_pin, .irq = 12 },
};

/// Longest line kept. A longer one is dropped whole and counted.
pub const line_bytes: usize = 32;

pub const Input = struct {
    enabled: bool = false,
    fd: ?host_read.Handle = null,
    line: [line_bytes]u8 = undefined,
    len: usize = 0,
    /// The current line ran past line_bytes and is being skipped.
    overlong: bool = false,
    /// Something has been read, so end of file now means the writer is done.
    seen: bool = false,
    /// Contacts put on the panel's queue.
    taken: u32 = 0,
    /// Switch presses and releases driven onto their pins.
    switched: u32 = 0,
    /// Level changes waiting for the boundary to offer them to the ICU.
    edges: pin_irq.Queue = .{},
    /// Lines that were not a contact, or a contact the full queue refused.
    refused: u32 = 0,

    /// Open PATH for reading without blocking, so a FIFO with no writer yet
    /// does not hold up the run.
    pub fn open(self: *Input, path: []const u8) !void {
        self.fd = host_read.open(path) catch |err| {
            std.debug.print("--touch @{s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        self.enabled = true;
    }

    /// Move every complete line waiting on the handle onto the panel.
    /// A partial line waits for its newline. End of file stops the polling
    /// once anything has arrived; before that it is a FIFO whose writer has
    /// not opened yet, so it is asked again next boundary.
    pub fn poll(self: *Input, panel: *gt911.Panel, pins: *gpio.Gpio) void {
        if (!self.enabled) return;
        const fd = self.fd orelse return;
        var bytes: [256]u8 = undefined;
        while (true) {
            const count = host_read.read(fd, &bytes) orelse return;
            if (count == 0) {
                if (self.seen) self.enabled = false;
                return;
            }
            self.seen = true;
            for (bytes[0..count]) |byte| self.take(panel, pins, byte);
        }
    }

    fn take(self: *Input, panel: *gt911.Panel, pins: *gpio.Gpio, byte: u8) void {
        if (byte != '\n') {
            if (self.len == line_bytes) self.overlong = true;
            if (!self.overlong) {
                self.line[self.len] = byte;
                self.len += 1;
            }
            return;
        }
        if (self.overlong) {
            self.refused += 1;
        } else self.feedLine(panel, pins, self.line[0..self.len]);
        self.len = 0;
        self.overlong = false;
    }

    /// One host line: a switch moved, a contact queued, or nothing for "up"
    /// and blanks.
    pub fn feedLine(self: *Input, panel: *gt911.Panel, pins: *gpio.Gpio, raw: []const u8) void {
        var text = std.mem.trim(u8, raw, " \t\r");
        if (text.len == 0 or std.mem.eql(u8, text, "up")) return;
        if (self.feedSwitch(pins, text)) return;
        for ([_][]const u8{ "down ", "move " }) |verb| {
            if (std.mem.startsWith(u8, text, verb)) text = std.mem.trimLeft(u8, text[verb.len..], " ");
        }
        const contact = parse(text) orelse {
            self.refused += 1;
            return;
        };
        panel.queue(contact) catch {
            self.refused += 1;
            return;
        };
        self.taken += 1;
    }

    /// "swN down" or "swN up": true when the line named a switch at all.
    fn feedSwitch(self: *Input, pins: *gpio.Gpio, text: []const u8) bool {
        for (switches) |one| {
            if (!std.mem.startsWith(u8, text, one.name)) continue;
            const verb = std.mem.trim(u8, text[one.name.len..], " ");
            const pressed = std.mem.eql(u8, verb, "down");
            if (!pressed and !std.mem.eql(u8, verb, "up")) {
                self.refused += 1;
                return true;
            }
            // Active-low with a pull-up: a held button reads low.
            const was_low = !pins.pinLevel(gpio.sw_port, one.pin);
            pins.setInput(gpio.sw_port, one.pin, !pressed);
            self.switched += 1;
            if (was_low != pressed) self.edges.push(.{
                .channel = one.irq,
                .port = gpio.sw_port,
                .pin = one.pin,
                .falling = pressed,
            });
            return true;
        }
        return false;
    }
};

/// "X,Y" in the panel's own coordinates, or null.
pub fn parse(text: []const u8) ?gt911.Contact {
    const split = std.mem.indexOfScalar(u8, text, ',') orelse return null;
    return .{
        .x = std.fmt.parseInt(u16, std.mem.trim(u8, text[0..split], " "), 10) catch return null,
        .y = std.fmt.parseInt(u16, std.mem.trim(u8, text[split + 1 ..], " "), 10) catch return null,
    };
}
