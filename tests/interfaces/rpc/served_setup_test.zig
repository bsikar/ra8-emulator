//! Tests for src/interfaces/rpc/served_setup.zig (RA8EMU-1093): an opened
//! image's server context answers a greeting over an in-memory loopback,
//! and its map, stack and rtc hooks are filled in.
const std = @import("std");
const ra8 = @import("ra8");

const setup = ra8.interfaces.rpc.setup;
const served = ra8.interfaces.rpc.server;
const proto = ra8.interfaces.rpc.session;
const rpc = served.rpc_lib;

const image = "tests/fixtures/fpu/fp_basic.elf";

test "an opened image greets a client over a loopback" {
    const gpa = std.testing.allocator;
    var opened: setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image);
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

test "the map, stack, rtc and parts hooks are set and the camera is left to the caller" {
    var opened: setup.Served = undefined;
    try opened.open(std.testing.allocator, std.testing.io, image);
    defer opened.deinit();
    const context = &opened.context;
    try std.testing.expect(context.listing != null);
    try std.testing.expect(context.clock != null);
    try std.testing.expect(context.camera == null);
    const mapping = context.mapping.?;
    var out: [8192]u8 = undefined;
    const text = try mapping.mapFn(mapping.context, 0, false, &out);
    try std.testing.expect(std.mem.indexOf(u8, text, "MRAM     0x") != null);
    const json = try mapping.mapFn(mapping.context, 0, true, &out);
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"regions\":"));
    try std.testing.expectError(error.NoImage, mapping.mapFn(mapping.context, 1, false, &out));
}
