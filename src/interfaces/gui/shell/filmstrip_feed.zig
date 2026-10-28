//! The shell's filmstrip: the frames the session's navigation index holds,
//! asked one at a time over the link (nav_query 0x0139, kind frame) into the
//! thumbnails the history strip draws along its track. The index's frames
//! are the ones the frame tap composited, so each thumbnail sits where a
//! picture exists. At most `max_thumbnails` are kept, sampled evenly when
//! the index holds more; a stop asks again once the index has frames.
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const history_position = @import("ra8_session").history_position;
const session_link = @import("../session_link.zig");
const filmstrip = @import("../filmstrip.zig");

const Link = session_link.Link;

pub const Feed = struct {
    /// The thumbnails the strip draws: the last complete pass.
    strip: filmstrip.Filmstrip = .{},
    building: filmstrip.Filmstrip = .{},
    want: bool = true,
    asked: ?u32 = null,
    /// The frame index the pass asks next, and the stride between asks.
    next: u64 = 0,
    stride: u64 = 1,
    /// Frames the index held at the pass's first answer.
    count: u64 = 0,
    /// The index held frames at the last pass, so a stop is worth asking on.
    seen_frames: bool = false,

    /// Send the next ask of a pass unless one is in flight.
    pub fn attach(self: *Feed, link: *Link) void {
        if (link.state != .connected or !self.want or self.asked != null) return;
        const args: proto.NavQueryArgs = .{ .kind = .frame, .index = self.next };
        self.asked = link.send(proto.NavQueryArgs, .nav_query, args) catch |err| switch (err) {
            error.TableFull => return,
            else => {
                self.finish();
                return;
            },
        };
    }

    /// A stop starts a pass again once the index has shown frames; the
    /// answer to the ask in flight adds a thumbnail.
    pub fn observe(self: *Feed, arrival: session_link.Arrival) void {
        switch (arrival) {
            .event => |event| {
                if (event.topic != @backingInt(proto.Topic.stop) or !self.seen_frames or self.want) return;
                self.want = true;
                self.next = 0;
            },
            .response => |response| {
                if (self.asked != response.id) return;
                self.asked = null;
                const body = switch (response.result) {
                    .ok => |bytes| bytes,
                    .err => return self.finish(),
                };
                const found = proto.decode(proto.NavQueryResult, body) catch return self.finish();
                self.take(found);
            },
        }
    }

    /// A new image: whatever was drawn belongs to the old one.
    pub fn reload(self: *Feed) void {
        self.strip.clear();
        self.building.clear();
        self.want = true;
        self.next = 0;
        self.seen_frames = false;
    }

    fn take(self: *Feed, found: proto.NavQueryResult) void {
        if (self.next == 0) {
            self.count = found.count;
            self.stride = @max(1, (found.count + filmstrip.max_thumbnails - 1) / filmstrip.max_thumbnails);
            self.building.clear();
        }
        if (found.found == 0) return self.finish();
        const position: history_position.Position = .{
            .branch = found.branch,
            .r = found.r,
            .phase = std.enums.fromInt(history_position.Phase, found.phase) orelse .cpu0,
            .o = found.o,
            .gap = std.enums.fromInt(history_position.Gap, found.gap) orelse .retired,
        };
        _ = self.building.add(.{ .checkpoint_id = @intCast(self.next), .position = position, .virtual_ns = found.virtual_ns, .has_frame = true });
        self.next += self.stride;
        if (self.next >= self.count) self.finish();
    }

    fn finish(self: *Feed) void {
        self.strip = self.building;
        self.seen_frames = self.strip.items_len > 0;
        self.building.clear();
        self.want = false;
        self.next = 0;
    }
};
