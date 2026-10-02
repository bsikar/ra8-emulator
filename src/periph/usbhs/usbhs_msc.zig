//! The far end's mass-storage function: a Bulk-Only Transport target (USB
//! MSC BOT 1.0) answering the handful of SCSI commands a host needs to mount
//! a disk and read a sector, over an image the board hands it.
//!
//! A command arrives as one 31-byte CBW on bulk OUT. What the device owes
//! comes back on bulk IN: the data stage, if any, then a 13-byte CSW. A
//! command it does not implement fails in the CSW with ILLEGAL REQUEST, the
//! way a real stick answers, rather than stalling the pipe.
const std = @import("std");

pub const block_len: u32 = 512;
pub const cbw_len: usize = 31;
pub const csw_len: usize = 13;
pub const cbw_signature: u32 = 0x4342_5355;
pub const csw_signature: u32 = 0x5342_5355;

/// The SCSI operation codes the target implements.
pub const op = struct {
    pub const test_unit_ready: u8 = 0x00;
    pub const request_sense: u8 = 0x03;
    pub const inquiry: u8 = 0x12;
    pub const mode_sense6: u8 = 0x1A;
    pub const prevent_allow: u8 = 0x1E;
    pub const read_capacity10: u8 = 0x25;
    pub const read10: u8 = 0x28;
};

/// bCSWStatus.
pub const Status = enum(u8) { passed = 0, failed = 1 };

/// The fixed-format sense a REQUEST SENSE reports after a failure.
pub const Sense = struct {
    key: u8 = 0,
    asc: u8 = 0,
    ascq: u8 = 0,

    pub const none = Sense{};
    pub const no_medium = Sense{ .key = 0x02, .asc = 0x3A };
    pub const invalid_opcode = Sense{ .key = 0x05, .asc = 0x20 };
    pub const lba_out_of_range = Sense{ .key = 0x05, .asc = 0x21 };
};

/// Where the current command has got to.
pub const Phase = enum { command, data_in, status };

/// Standard INQUIRY data: a removable direct-access block device, SPC-2.
pub const inquiry_data = [_]u8{ 0x00, 0x80, 0x04, 0x02, 31, 0, 0, 0 } ++
    "RA8EMU  ".* ++ "EMULATED DISK   ".* ++ "1.00".*;

pub const Target = struct {
    disk: []const u8 = &.{},
    phase: Phase = .command,
    sense: Sense = .{},
    status: Status = .passed,
    tag: u32 = 0,
    /// dCBWDataTransferLength: what the host said it would take.
    expected: u32 = 0,
    sent: u32 = 0,
    data: []const u8 = &.{},
    scratch: [18]u8 = [_]u8{0} ** 18,
    commands: u32 = 0,
    invalid: u32 = 0,
    failed: u32 = 0,
    reads: u32 = 0,

    pub fn blocks(self: *const Target) u32 {
        return @intCast(self.disk.len / block_len);
    }

    /// A packet from the host on bulk OUT. False when it is not a CBW the
    /// target can take now: a short packet, a bad signature, or a command
    /// sent while the last one still owes its CSW.
    pub fn command(self: *Target, packet: []const u8) bool {
        if (self.phase != .command or packet.len != cbw_len or
            le32(packet[0..4]) != cbw_signature)
        {
            self.invalid += 1;
            return false;
        }
        self.tag = le32(packet[4..8]);
        self.expected = le32(packet[8..12]);
        self.sent = 0;
        self.commands += 1;
        self.execute(packet[15..31]);
        if (self.data.len > self.expected) self.data = self.data[0..self.expected];
        self.phase = if (self.data.len > 0) .data_in else .status;
        return true;
    }

    /// The next bulk IN packet, at most `buf.len` bytes: the data stage
    /// first, then the CSW. Zero when nothing is owed.
    pub fn reply(self: *Target, buf: []u8) usize {
        switch (self.phase) {
            .command => return 0,
            .data_in => {
                const n = @min(buf.len, self.data.len);
                @memcpy(buf[0..n], self.data[0..n]);
                self.data = self.data[n..];
                self.sent += @intCast(n);
                if (self.data.len == 0) self.phase = .status;
                return n;
            },
            .status => {
                if (buf.len < csw_len) return 0;
                self.writeCsw(buf[0..csw_len]);
                self.phase = .command;
                return csw_len;
            },
        }
    }

    /// A bus reset: whatever command was in flight is gone with it.
    pub fn reset(self: *Target) void {
        self.phase = .command;
        self.data = &.{};
    }

    fn writeCsw(self: *const Target, out: *[csw_len]u8) void {
        std.mem.writeInt(u32, out[0..4], csw_signature, .little);
        std.mem.writeInt(u32, out[4..8], self.tag, .little);
        std.mem.writeInt(u32, out[8..12], self.expected -| self.sent, .little);
        out[12] = @intFromEnum(self.status);
    }

    fn execute(self: *Target, cdb: []const u8) void {
        self.status = .passed;
        self.data = &.{};
        switch (cdb[0]) {
            op.test_unit_ready => _ = self.requireMedium(),
            op.request_sense => self.requestSense(),
            op.inquiry => self.data = inquiry_data[0..@min(inquiry_data.len, cdb[4])],
            op.mode_sense6 => {
                self.scratch[0..4].* = .{ 3, 0, 0, 0 };
                self.data = self.scratch[0..4];
            },
            op.prevent_allow => {},
            op.read_capacity10 => self.readCapacity(),
            op.read10 => self.read(cdb),
            else => self.fail(Sense.invalid_opcode),
        }
    }

    fn requireMedium(self: *Target) bool {
        if (self.blocks() != 0) return true;
        self.fail(Sense.no_medium);
        return false;
    }

    fn fail(self: *Target, sense: Sense) void {
        self.status = .failed;
        self.sense = sense;
        self.data = &.{};
        self.failed += 1;
    }

    /// Fixed-format sense data, then the condition is reported and cleared.
    fn requestSense(self: *Target) void {
        @memset(&self.scratch, 0);
        self.scratch[0] = 0x70;
        self.scratch[2] = self.sense.key;
        self.scratch[7] = 10;
        self.scratch[12] = self.sense.asc;
        self.scratch[13] = self.sense.ascq;
        self.sense = Sense.none;
        self.data = self.scratch[0..18];
    }

    fn readCapacity(self: *Target) void {
        if (!self.requireMedium()) return;
        std.mem.writeInt(u32, self.scratch[0..4], self.blocks() - 1, .big);
        std.mem.writeInt(u32, self.scratch[4..8], block_len, .big);
        self.data = self.scratch[0..8];
    }

    fn read(self: *Target, cdb: []const u8) void {
        if (!self.requireMedium()) return;
        const lba: u64 = std.mem.readInt(u32, cdb[2..6], .big);
        const count: u64 = std.mem.readInt(u16, cdb[7..9], .big);
        if (lba + count > self.blocks()) return self.fail(Sense.lba_out_of_range);
        self.reads += 1;
        self.data = self.disk[lba * block_len .. (lba + count) * block_len];
    }
};

fn le32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .little);
}
