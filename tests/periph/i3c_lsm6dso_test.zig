//! The LSM6DSO IMU: the identity a probe reads, the registers the part owns,
//! and the output blocks it refuses while it has not been started.
const std = @import("std");
const ra8 = @import("ra8");
const lsm6dso = ra8.periph.i3c_lsm6dso;

fn start(imu: *lsm6dso.Imu) void {
    imu.write(lsm6dso.reg.ctrl1_xl);
    imu.write(0x40);
    imu.stop();
    imu.write(lsm6dso.reg.ctrl2_g);
    imu.write(0x40);
    imu.stop();
}

test "who am i reads the part's identity" {
    var imu = lsm6dso.Imu{};
    imu.write(lsm6dso.reg.who_am_i);
    var buffer: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), imu.read(buffer[0..]));
    try std.testing.expectEqual(lsm6dso.identity, buffer[0]);
}

test "a control write lands and the pointer auto-increments" {
    var imu = lsm6dso.Imu{};
    imu.write(lsm6dso.reg.ctrl1_xl);
    imu.write(0x40);
    imu.write(0x4C);
    try std.testing.expectEqual(@as(u8, 0x40), imu.registers[lsm6dso.reg.ctrl1_xl]);
    try std.testing.expectEqual(@as(u8, 0x4C), imu.registers[lsm6dso.reg.ctrl2_g]);
    try std.testing.expectEqual(@as(u32, 2), imu.writes);
}

test "a store over who am i is refused, the part keeps its identity" {
    var imu = lsm6dso.Imu{};
    imu.write(lsm6dso.reg.who_am_i);
    imu.write(0x6B);
    try std.testing.expectEqual(lsm6dso.identity, imu.registers[lsm6dso.reg.who_am_i]);
    try std.testing.expectEqual(@as(u32, 1), imu.read_only);
    try std.testing.expectEqual(@as(u32, 0), imu.writes);
}

test "a store into an output register is refused" {
    var imu = lsm6dso.Imu{};
    imu.write(lsm6dso.reg.outx_l_g);
    imu.write(0xFF);
    imu.write(0xFF);
    try std.testing.expectEqual(@as(u32, 2), imu.read_only);
    try std.testing.expectEqual(@as(u8, 0x00), imu.registers[lsm6dso.reg.outx_l_g]);
}

test "a gyro read with the part in power-down answers nothing" {
    var imu = lsm6dso.Imu{};
    imu.write(lsm6dso.reg.outx_l_g);
    var buffer: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), imu.read(buffer[0..]));
    try std.testing.expectEqual(@as(u32, 1), imu.unstarted);
    try std.testing.expectEqual(@as(u32, 0), imu.reads);
}

test "the same read answers once the gyro has an output data rate" {
    var imu = lsm6dso.Imu{};
    start(&imu);
    imu.write(lsm6dso.reg.outx_l_g);
    var buffer: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), imu.read(buffer[0..]));
    try std.testing.expectEqual(@as(u8, @truncate(lsm6dso.seed.gyro_x)), buffer[0]);
    try std.testing.expectEqual(@as(u32, 0), imu.unstarted);
    try std.testing.expectEqual(@as(u32, 1), imu.reads);
}

test "an accelerometer read is gated on its own control register" {
    var imu = lsm6dso.Imu{};
    imu.write(lsm6dso.reg.ctrl2_g);
    imu.write(0x40);
    imu.stop();
    imu.write(lsm6dso.reg.outz_l_a);
    var buffer: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), imu.read(buffer[0..]));
    try std.testing.expectEqual(@as(u32, 1), imu.unstarted);
}

test "status reports data ready for whichever half is running" {
    var imu = lsm6dso.Imu{};
    var buffer: [1]u8 = undefined;
    imu.write(lsm6dso.reg.status);
    try std.testing.expectEqual(@as(usize, 1), imu.read(buffer[0..]));
    try std.testing.expectEqual(@as(u8, 0), buffer[0]);
    imu.stop();
    start(&imu);
    imu.write(lsm6dso.reg.status);
    _ = imu.read(buffer[0..]);
    try std.testing.expectEqual(lsm6dso.ready.accel | lsm6dso.ready.gyro, buffer[0]);
}

test "status is the part's to write" {
    var imu = lsm6dso.Imu{};
    imu.write(lsm6dso.reg.status);
    imu.write(0x03);
    try std.testing.expectEqual(@as(u32, 1), imu.read_only);
}

test "a pointer past the map is refused and the payload behind it lands nowhere" {
    var imu = lsm6dso.Imu{};
    imu.write(0x80);
    try std.testing.expectEqual(@as(u32, 1), imu.bad_pointer);
    try std.testing.expect(!imu.pointed);
    imu.write(0xAA);
    try std.testing.expectEqual(@as(u32, 0), imu.writes);
}

test "a burst stops at the end of the map instead of serving zeros" {
    var imu = lsm6dso.Imu{};
    imu.write(0x7E);
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), imu.read(buffer[0..]));
    try std.testing.expectEqual(@as(u32, 1), imu.past_end);
}

test "the accelerometer seed is the sample dev came up holding" {
    var imu = lsm6dso.Imu{};
    start(&imu);
    imu.write(lsm6dso.reg.outz_l_a);
    var buffer: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), imu.read(buffer[0..]));
    const value = @as(u16, buffer[1]) << 8 | buffer[0];
    try std.testing.expectEqual(lsm6dso.seed.accel_z, value);
}

test "a stop re-arms the pointer capture" {
    var imu = lsm6dso.Imu{};
    imu.write(lsm6dso.reg.ctrl1_xl);
    imu.stop();
    imu.write(lsm6dso.reg.ctrl2_g);
    imu.write(0x40);
    try std.testing.expectEqual(@as(u8, 0x40), imu.registers[lsm6dso.reg.ctrl2_g]);
}

test "a part nobody touched is quiet" {
    var imu = lsm6dso.Imu{};
    try std.testing.expect(imu.quiet());
    imu.write(lsm6dso.reg.who_am_i);
    imu.write(0x00);
    try std.testing.expect(!imu.quiet());
}

test "the device seam answers at the part's address" {
    var imu = lsm6dso.Imu{};
    const device = imu.device();
    try std.testing.expectEqual(lsm6dso.address, device.address);
    device.write(lsm6dso.reg.who_am_i);
    var buffer: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), device.read(buffer[0..]));
    try std.testing.expectEqual(lsm6dso.identity, buffer[0]);
    device.stop();
    try std.testing.expect(!imu.pointed);
}
