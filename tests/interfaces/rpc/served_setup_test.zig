//! Tests for src/interfaces/rpc/served_setup.zig (RA8EMU-1093): an opened
//! image's server context answers a greeting over an in-memory loopback,
//! its map, stack and rtc hooks are filled in, and set_camera_source opens
//! the source from the host and installs it (RA8EMU-1114).
const std = @import("std");
const ra8 = @import("ra8");

const setup = ra8.rpc.served_setup;
const served = ra8.rpc.session.server;
const proto = ra8.rpc.session.rpc;
const camera = ra8.rpc.session.camera;
const rpc = served.rpc_lib;

const image = "tests/fixtures/fpu/fp_basic.elf";

test "an opened image greets a client over a loopback" {
    const gpa = std.testing.allocator;
    var opened: setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image, null, null);
    defer opened.deinit();
    const Env = proto.Client.Env;
    const pipes = [2][]u8{ try gpa.alloc(u8, 2 * Env.max_frame), try gpa.alloc(u8, 2 * Env.max_frame) };
    defer for (pipes) |pipe| gpa.free(pipe);
    const client_rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(client_rx);
    var loop = rpc.Loopback.init(pipes[0], pipes[1]);
    var client = proto.Client.init(loop.a(), client_rx, proto.capabilities);
    var host = served.Host.init(loop.b(), opened.rx, &opened.context);
    try client.greet(opened.tx);
    try std.testing.expectEqual(rpc.Step.greeted, try host.poll(opened.tx));
    const ready = (try client.poll(opened.tx)).?;
    try std.testing.expectEqual(proto.capabilities, ready.ready);
}

test "the map, stack, rtc, parts and camera hooks are set" {
    var opened: setup.Served = undefined;
    try opened.open(std.testing.allocator, std.testing.io, image, null, null);
    defer opened.deinit();
    const context = &opened.context;
    try std.testing.expect(context.listing != null);
    try std.testing.expect(context.clock != null);
    try std.testing.expect(context.camera != null);
    const mapping = context.mapping.?;
    var out: [8192]u8 = undefined;
    const text = try mapping.mapFn(mapping.context, 0, false, &out);
    try std.testing.expect(std.mem.indexOf(u8, text, "MRAM     0x") != null);
    const json = try mapping.mapFn(mapping.context, 0, true, &out);
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"regions\":"));
    try std.testing.expectError(error.NoImage, mapping.mapFn(mapping.context, 1, false, &out));
}

/// A two-pixel picture on disk for the camera to open.
fn picture(dir: std.Io.Dir, name: []const u8) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "P6\n2 1\n255\n" ++ "\x10\x20\x30\x40\x50\x60" });
}

test "set_camera_source opens the source from the host and installs it on the board" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try picture(temp.dir, "still.ppm");
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const path = try std.fmt.allocPrint(gpa, "image:{s}/still.ppm", .{root});
    defer gpa.free(path);

    var opened: setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image, null, null);
    defer opened.deinit();
    const source = &opened.owner.board().capture.source;
    const before = source.label;
    const taken = camera.setCameraSource(&opened.context, .{ .text = path });
    try std.testing.expectEqual(@as(u8, 1), taken.ok.accepted);
    try std.testing.expectEqualStrings("still image", source.label);
    try std.testing.expect(!std.mem.eql(u8, before, source.label));

    const back = camera.setCameraSource(&opened.context, .{ .text = "gradient" });
    try std.testing.expectEqual(@as(u8, 1), back.ok.accepted);
    try std.testing.expectEqualStrings(before, source.label);
}

test "a source that will not open is refused and the old one stays" {
    var opened: setup.Served = undefined;
    try opened.open(std.testing.allocator, std.testing.io, image, null, null);
    defer opened.deinit();
    const source = &opened.owner.board().capture.source;
    const before = source.label;
    const refused = camera.setCameraSource(&opened.context, .{ .text = "image:/nonexistent/ra8/still.ppm" });
    try std.testing.expect(refused == .err);
    try std.testing.expectEqualStrings(before, source.label);
}

test "Served.open cleans up scratch buffer when frame pipeline initialization fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var opened: setup.Served = undefined;
    const result = opened.open(gpa, io, image, null, .{
        .root = root,
        .ram_budget = 1,
    });
    try std.testing.expectError(error.BudgetTooSmall, result);
}

const FailOnEngineAlloc = struct {
    parent: std.mem.Allocator,
    target_size: usize,
    has_failed: bool = false,

    fn allocator(self: *FailOnEngineAlloc) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FailOnEngineAlloc = @ptrCast(@alignCast(ctx));
        if (len == self.target_size and !self.has_failed) {
            self.has_failed = true;
            return null;
        }
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FailOnEngineAlloc = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FailOnEngineAlloc = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *FailOnEngineAlloc = @ptrCast(@alignCast(ctx));
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

test "Served.open error path stops compositor worker on attachNav failure" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var fail_alloc = FailOnEngineAlloc{
        .parent = gpa,
        .target_size = @sizeOf(ra8.session.smooth_rewind.SmoothRewindEngine),
    };

    var opened: setup.Served = undefined;
    const result = opened.open(fail_alloc.allocator(), io, image, null, .{
        .root = root,
    });
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expect(fail_alloc.has_failed);
    try std.testing.expect(opened.frames == null);
}

test "attachNav error path leaves no dangling pointer on allocation failure" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var opened: setup.Served = undefined;
    try opened.open(gpa, io, image, null, null);
    defer opened.deinit();

    const session = opened.owner.session();
    const served_history = ra8.rpc.served_history;
    served_history.deinitNav(&opened);
    try std.testing.expect(session.nav_index == null);

    var fail_alloc = FailOnEngineAlloc{
        .parent = gpa,
        .target_size = @sizeOf(ra8.session.smooth_rewind.SmoothRewindEngine),
    };

    const res = served_history.attachNav(&opened, fail_alloc.allocator());
    try std.testing.expectError(error.OutOfMemory, res);
    try std.testing.expect(fail_alloc.has_failed);
    try std.testing.expect(opened.nav == null);
    try std.testing.expect(opened.rewind == null);
    try std.testing.expect(session.nav_index == null);
    try std.testing.expect(session.smooth_rewind == null);
}
