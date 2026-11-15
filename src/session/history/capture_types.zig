//! Inputs, object sink, and results for checkpoint capture.
const chip = @import("ra8_chip");
const manifest_mod = @import("manifest.zig");
const ObjectId = @import("object_id.zig").ObjectId;

pub const SpaceSpan = struct {
    space: manifest_mod.SpaceId,
    bytes: []const u8,
    sdram_resident: ?*const chip.core.cpu.memory.store.SdramSet = null,
};

pub const BlobSpan = struct {
    space: manifest_mod.SpaceId,
    bytes: []const u8,
};

pub const ObjectSink = struct {
    context: *anyopaque,
    putFn: *const fn (context: *anyopaque, id: ObjectId, bytes: []const u8) anyerror!void,

    pub fn put(self: ObjectSink, id: ObjectId, bytes: []const u8) anyerror!void {
        return self.putFn(self.context, id, bytes);
    }
};

pub const CaptureStats = struct {
    pages_hashed: usize = 0,
    pages_reused: usize = 0,
    objects_stored: usize = 0,
};

pub const CaptureResult = struct {
    manifest: manifest_mod.Manifest,
    stats: CaptureStats,
};
