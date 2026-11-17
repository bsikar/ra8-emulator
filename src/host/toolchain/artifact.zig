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
    .{
        .host = "aarch64-macos",
        .url = "https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz",
        .sha256 = "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a",
        .archive_bytes = 53_985_220,
        .executable = "zig-aarch64-macos-0.17.0/zig",
    },
    .{
        .host = "x86_64-macos",
        .url = "https://ziglang.org/download/0.17.0/zig-x86_64-macos-0.17.0.tar.xz",
        .sha256 = "4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6",
        .archive_bytes = 59_317_572,
        .executable = "zig-x86_64-macos-0.17.0/zig",
    },
    .{
        .host = "x86_64-linux",
        .url = "https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz",
        .sha256 = "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026",
        .archive_bytes = 57_332_648,
        .executable = "zig-x86_64-linux-0.17.0/zig",
    },
    .{
        .host = "x86_64-windows",
        .url = "https://ziglang.org/download/0.17.0/zig-x86_64-windows-0.17.0.zip",
        .sha256 = "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428",
        .archive_bytes = 100_268_137,
        .executable = "zig-x86_64-windows-0.17.0/zig.exe",
    },
};

const manifest_hashes = [zig.len][]const u8{
    "505bfccec93f487e103711bd51cc9b05d8910c106af4450ed6369c1c23be06ef",
    "8719331aa989d630b5ea4c5bd3ef3af10eb7c7d698d1c875b1776bf04ee25283",
    "c73d50c2f8465f9448a84bae9290b03d61e6e61f635ec2eb1eaaf52193786e2d",
    "7e9c5761490d6efb67cbf25b058e9b5315ce5a2e790f5cf405d0e0bee3c37b01",
};

pub fn manifestSha256(artifact: Artifact) ?[]const u8 {
    for (zig, manifest_hashes) |entry, hash| {
        if (std.mem.eql(u8, artifact.host, entry.host) and
            std.mem.eql(u8, artifact.sha256, entry.sha256))
        {
            return hash;
        }
    }
    return null;
}

/// Reference pin for a future RA board profile, not a declaration of compatibility
/// or permission to redistribute all packages contained in this vendor archive.
pub const fsp_candidate = .{
    .name = "FSP_Packs_v6.6.0.zip",
    .version = "6.6.0",
    .url = "https://github.com/renesas/fsp/releases/download/v6.6.0/FSP_Packs_v6.6.0.zip",
    .sha256 = "a6925c8ff8566003de7147ac5594398ca44703985b03898d53e524e651a3645b",
    .archive_bytes = @as(u64, 180_347_017),
    .managed_eligible = false,
    .verification_source = "GitHub release asset SHA256 digest; profile compatibility and contained " ++
        "component licenses require " ++
        "review",
};

pub fn forHost(host: []const u8) !Artifact {
    for (zig) |artifact| if (std.mem.eql(u8, host, artifact.host)) return artifact;
    // Compiler availability alone does not establish backend/process/driver support.
    return error.UnsupportedHost;
}
