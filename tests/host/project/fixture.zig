const std = @import("std");
const builtin = @import("builtin");
const host = @import("ra8").host;

const io = std.testing.io;
pub const Fixture = struct {
    tmp: std.testing.TmpDir = undefined,
    base: host.workspace.Workspace = undefined,
    project: host.project.Project = undefined,
    pub const directory = ".ra8-builds/00000000000000000000000000000001";
    pub const artifact = directory ++ "/out/bin/fw.elf";
    pub const receipt_path = directory ++ "/project.json";
    pub const config_bytes = "{\"version\":1,\"target\":\"ra8d2\",\"recipes\":[{\"name\":\"debug\",\"artifact\":\"bin/fw.elf\"}],\"source_mappings\":[{\"client\":\"C:/client/project\"}]}";
    pub fn init(self: *Fixture) !void {
        self.tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer self.tmp.cleanup();
        self.base = .{ .dir = self.tmp.dir, .io = io };
        self.project = .{ .allocator = std.testing.allocator, .base = &self.base, .backend_compiler = if (builtin.os.tag == .windows) "C:/not-installed/zig.exe" else "/not-installed/zig" };
        try self.tmp.dir.writeFile(io, .{ .sub_path = "project.json", .data = config_bytes });
        try self.tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "one" });
        try self.tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "fixture" });
        try self.project.open("project.json");
    }
    pub fn deinit(self: *Fixture) void {
        self.project.close();
        self.tmp.cleanup();
    }
    pub fn receipt(self: *Fixture) !void {
        try self.tmp.dir.createDirPath(io, directory ++ "/out/bin");
        const elf = "\x7fELFfixture";
        try self.tmp.dir.writeFile(io, .{ .sub_path = artifact, .data = elf });
        var cancel: std.atomic.Value(bool) = .init(false);
        const revision = try host.build.source.revision(self.project.workspace.?.dir, self.project.budget(&cancel));
        const digest = host.project.files.digest(elf);
        const value: host.project.receipt.Receipt = .{ .config_sha256 = &self.project.config_sha256, .recipe = "debug", .target = "ra8d2", .build_id = 42, .directory = directory, .artifact = artifact, .artifact_sha256 = &digest, .source_sha256 = &revision, .compiler = self.project.runner.?.compiler, .compiler_version = "0.17.0" };
        const original: host.project.receipt.Record = .{ .id = 42, .state = "succeeded", .cleanup = "complete", .directory = directory, .artifact = artifact, .artifact_sha256 = &digest, .source_sha256 = &revision, .compiler = value.compiler, .compiler_version = value.compiler_version, .step = "", .options = &.{}, .argv = &.{ value.compiler, "build", "-j1", "--color=off", "--prefix", directory ++ "/out", "--build-file", "build.zig" } };
        const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, value, .{});
        defer std.testing.allocator.free(bytes);
        const record = try std.json.Stringify.valueAlloc(std.testing.allocator, original, .{});
        defer std.testing.allocator.free(record);
        try self.tmp.dir.writeFile(io, .{ .sub_path = receipt_path, .data = bytes });
        try self.tmp.dir.writeFile(io, .{ .sub_path = directory ++ "/result.json", .data = record });
    }
};
