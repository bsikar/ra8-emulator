//! Release artifacts, copied from the upstream release index, never a moving latest.
const std = @import("std");
pub const Artifact = struct {
    host: []const u8,
    version: []const u8 = "0.17.0",
    url: []const u8,
    sha256: []const u8,
    archive_bytes: u64,
    executable: []const u8,
};
pub const zig = [_]Artifact{
    .{ .host = "x86_64-linux", .url = "https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz", .sha256 = "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026", .archive_bytes = 57_332_648, .executable = "zig-x86_64-linux-0.17.0/zig" },
    .{ .host = "x86_64-windows", .url = "https://ziglang.org/download/0.17.0/zig-x86_64-windows-0.17.0.zip", .sha256 = "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428", .archive_bytes = 100_268_137, .executable = "zig-x86_64-windows-0.17.0/zig.exe" },
};

/// Reference pin for a future RA board profile, not a declaration of compatibility
/// or permission to redistribute all packages contained in this vendor archive.
pub const fsp_candidate = .{
    .name = "FSP_Packs_v6.6.0.zip",
    .version = "6.6.0",
    .url = "https://github.com/renesas/fsp/releases/download/v6.6.0/FSP_Packs_v6.6.0.zip",
    .sha256 = "a6925c8ff8566003de7147ac5594398ca44703985b03898d53e524e651a3645b",
    .archive_bytes = @as(u64, 180_347_017),
    .managed_eligible = false,
    .verification_source = "GitHub release asset SHA256 digest; profile compatibility and contained component licenses require review",
};

pub fn forHost(host: []const u8) !Artifact {
    for (zig) |artifact| if (std.mem.eql(u8, host, artifact.host)) return artifact;
    // Compiler availability alone does not establish backend/process/driver support.
    return error.UnsupportedHost;
}
