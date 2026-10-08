//! RA8EMU-812 fixture: firmware that reads the GT911 touch controller (0x5D)
//! over the I3C channel in legacy I2C mode, the way a touch driver does.
//! Each frame it reads the status byte at 0x814E. When a contact is ready it
//! reads the point record at 0x814F, stores x at SRAM 0x22000100 and y at
//! 0x22000102, bumps a count at 0x22000104, then writes a zero back to
//! status to acknowledge the frame.

const i3c_base: u32 = 0x4035_F000;
const cndctl: *volatile u32 = @ptrFromInt(i3c_base + 0x140);
const data: *volatile u32 = @ptrFromInt(i3c_base + 0x158);
/// MSTPCRB: the I3C channel runs once bit 4 is clear (HUM 11.2.7).
const mstpcrb: *volatile u32 = @ptrFromInt(0x4020_3004);
const i3c_stop: u32 = 1 << 4;

const start: u32 = 1;
const restart: u32 = 2;
const stop: u32 = 4;
const write_address: u32 = 0x5D << 1;
const read_address: u32 = write_address | 1;

const status_hi: u32 = 0x81;
const status_lo: u32 = 0x4E;
const point_lo: u32 = 0x4F;
const ready: u8 = 0x80;
const count_mask: u8 = 0x0F;

const touch_x: *volatile u16 = @ptrFromInt(0x2200_0100);
const touch_y: *volatile u16 = @ptrFromInt(0x2200_0102);
const touches: *volatile u32 = @ptrFromInt(0x2200_0104);

const Vectors = extern struct {
    sp: u32,
    reset: *const fn () callconv(.c) noreturn,
};

export const vector_table linksection(".isr_vector") = Vectors{
    .sp = 0x2219_FFF8,
    .reset = &Reset_Handler,
};

/// Read `into.len` bytes starting at register `lo` of the 0x81xx page.
fn readRegister(lo: u32, into: []u8) void {
    cndctl.* = start;
    data.* = write_address;
    data.* = status_hi;
    data.* = lo;
    cndctl.* = restart;
    data.* = read_address;
    _ = data.*;
    for (into) |*byte| byte.* = @truncate(data.*);
    cndctl.* = stop;
}

fn acknowledge() void {
    cndctl.* = start;
    data.* = write_address;
    data.* = status_hi;
    data.* = status_lo;
    data.* = 0;
    cndctl.* = stop;
}

export fn Reset_Handler() callconv(.c) noreturn {
    touch_x.* = 0;
    touch_y.* = 0;
    touches.* = 0;
    mstpcrb.* &= ~i3c_stop;
    while (true) {
        var status: [1]u8 = undefined;
        readRegister(status_lo, &status);
        if (status[0] & ready == 0 or status[0] & count_mask == 0) continue;
        var point: [8]u8 = undefined;
        readRegister(point_lo, &point);
        touch_x.* = @as(u16, point[2]) << 8 | point[1];
        touch_y.* = @as(u16, point[4]) << 8 | point[3];
        touches.* += 1;
        acknowledge();
    }
}
