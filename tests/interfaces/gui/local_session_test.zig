//! Tests for src/interfaces/gui/local_session.zig (RA8EMU-1092): the shell's
//! local session opens the image in-process and sets its own camera hook.
//! Its requests cross the worker's native mailbox, so serving is
//! session_worker_test's and the rig's subject.
const std = @import("std");
const gui_app = @import("gui_app");

const local_session = gui_app.local_session;

const image = "tests/fixtures/fpu/fp_basic.elf";

test "the local session opens in-process and sets its own camera hook" {
    var session: local_session.LocalSession = undefined;
    try session.open(std.testing.allocator, std.testing.io, image, null);
    defer session.deinit();
    try std.testing.expect(session.setup.context.camera != null);
}
