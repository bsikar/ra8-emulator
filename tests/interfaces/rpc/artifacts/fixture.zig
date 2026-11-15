const std = @import("std");
const ra8 = @import("ra8");

const rig = @import("../regression_rig.zig");
pub const gpa = std.testing.allocator;
const elf = @embedFile("../../../fixtures/gpio/blink.elf");

pub const Fixture = struct {
    original: *ra8.rpc.served_setup.Served,
    service: *ra8.rpc.artifacts.service.Service,
    temp: std.testing.TmpDir,
    path: [:0]u8,

    pub fn open() !Fixture {
        const source = try gpa.create(ra8.rpc.served_setup.Served);
        errdefer gpa.destroy(source);
        try source.openInitial(gpa, std.testing.io, "", rig.small_profile, .{ .elf_bytes = elf }, null);
        errdefer source.deinit();
        var temp = std.testing.tmpDir(.{});
        errdefer temp.cleanup();
        const path = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
        errdefer gpa.free(path);
        const service = try ra8.rpc.artifacts.service.Service.open(gpa, std.testing.io, source, path, .{ .profile = rig.small_profile });
        return .{ .original = source, .service = service, .temp = temp, .path = path };
    }

    pub fn close(self: *Fixture) void {
        self.service.close() catch @panic("artifact service cleanup failed");
        gpa.destroy(self.original);
        gpa.free(self.path);
        self.temp.cleanup();
    }
};
