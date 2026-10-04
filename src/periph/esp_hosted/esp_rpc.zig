//! esp-hosted RPC requests from the host and the C6's answers to them.
//!
//! A request arrives on the serial interface as two TLVs, the endpoint
//! name and the protobuf `Rpc` message. The model reads the envelope
//! (msg_type 1, msg_id 2, uid 3) and answers the requests it knows with a
//! response on endpoint RPCRsp that echoes the uid. Field numbers follow
//! esp-hosted-mcu v2.12.12 common/proto/esp_hosted_rpc.proto; the
//! version reported is the co-processor firmware the bench runs, 2.12.11.
const frame = @import("esp_frame.zig");
const event = @import("esp_event.zig");

pub const Error = error{ Truncated, NotRequest } || event.Error;

pub const Id = struct {
    pub const req_fw_version: u32 = 350;
    pub const resp_fw_version: u32 = 606;
};

/// The co-processor firmware version the bench C6 reports.
pub const Version = struct { major: u32 = 2, minor: u32 = 12, patch: u32 = 11 };
/// ESP_PRIV_FIRMWARE_CHIP_ESP32C6.
pub const chip_id: u32 = 0x0D;
pub const idf_target: []const u8 = "esp32c6";

pub const Request = struct { id: u32, uid: u32 };

const wire_varint: u3 = 0;

/// Reads protobuf wire values from a byte slice.
pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn done(self: *const Reader) bool {
        return self.pos >= self.buf.len;
    }

    pub fn varint(self: *Reader) Error!u64 {
        var value: u64 = 0;
        var shift: u32 = 0;
        while (shift < 64) : (shift += 7) {
            if (self.pos >= self.buf.len) return Error.Truncated;
            const b = self.buf[self.pos];
            self.pos += 1;
            value |= @as(u64, b & 0x7F) << @as(u6, @intCast(shift));
            if (b < 0x80) return value;
        }
        return Error.Truncated;
    }

    pub fn bytes(self: *Reader) Error![]const u8 {
        const len = try self.varint();
        if (len > self.buf.len - self.pos) return Error.Truncated;
        const start = self.pos;
        self.pos += @intCast(len);
        return self.buf[start..self.pos];
    }

    /// Steps over the value of a field with wire type `wire`.
    pub fn skip(self: *Reader, wire: u3) Error!void {
        switch (wire) {
            0 => _ = try self.varint(),
            1 => try self.advance(8),
            2 => _ = try self.bytes(),
            5 => try self.advance(4),
            else => return Error.Truncated,
        }
    }

    fn advance(self: *Reader, count: usize) Error!void {
        if (count > self.buf.len - self.pos) return Error.Truncated;
        self.pos += count;
    }
};

/// The value of the data TLV in a serial payload, or null when absent.
pub fn tlvData(payload: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (payload.len - pos >= 3) {
        const tag = payload[pos];
        const len = @as(usize, payload[pos + 1]) | @as(usize, payload[pos + 2]) << 8;
        pos += 3;
        if (len > payload.len - pos) return null;
        if (tag == event.tag_data) return payload[pos .. pos + len];
        pos += len;
    }
    return null;
}

/// Reads the envelope of an `Rpc` request message.
pub fn request(proto: []const u8) Error!Request {
    var r: Reader = .{ .buf = proto };
    var values = [3]u64{ 0, 0, 0 };
    while (!r.done()) {
        const key = try r.varint();
        const number = key >> 3;
        const wire: u3 = @truncate(key);
        if (wire == wire_varint and number >= 1 and number <= 3) {
            values[@intCast(number - 1)] = try r.varint();
        } else try r.skip(wire);
    }
    if (values[0] != @intFromEnum(event.Kind.request)) return Error.NotRequest;
    return .{ .id = @truncate(values[1]), .uid = @truncate(values[2]) };
}

/// Writes an `Rpc` response envelope carrying `body` as payload `id`.
pub fn response(w: *event.Writer, id: u32, uid: u32, body: []const u8) Error!void {
    try w.key(1, wire_varint);
    try w.varint(@intFromEnum(event.Kind.response));
    try w.key(2, wire_varint);
    try w.varint(id);
    try w.key(3, wire_varint);
    try w.varint(uid);
    try w.field(id, body);
}

/// Writes `Rpc_Resp_GetCoprocessorFwVersion` with resp 0 (left default).
pub fn fwVersion(w: *event.Writer) Error!void {
    const version: Version = .{};
    try w.key(2, wire_varint);
    try w.varint(version.major);
    try w.key(3, wire_varint);
    try w.varint(version.minor);
    try w.key(4, wire_varint);
    try w.varint(version.patch);
    try w.key(8, wire_varint);
    try w.varint(chip_id);
    try w.field(9, idf_target);
}

/// Builds the frame answering `req`; false when the model has no answer.
pub fn answerFrame(out: *[frame.frame_size]u8, req: Request) Error!bool {
    if (req.id != Id.req_fw_version) return false;
    var body_buf: [32]u8 = undefined;
    var body: event.Writer = .{ .buf = &body_buf };
    try fwVersion(&body);
    var proto_buf: [64]u8 = undefined;
    var proto: event.Writer = .{ .buf = &proto_buf };
    try response(&proto, Id.resp_fw_version, req.uid, body.written());
    var payload_buf: [96]u8 = undefined;
    var payload: event.Writer = .{ .buf = &payload_buf };
    try event.envelope(&payload, event.endpoint_response, proto.written());
    try frame.build(out, .{ .interface = .serial, .if_num = 0 }, payload.written());
    return true;
}
