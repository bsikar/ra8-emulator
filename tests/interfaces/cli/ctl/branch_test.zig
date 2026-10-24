//! Tests for src/interfaces/cli/ctl/branch.zig (Slice 20.4).
const std = @import("std");
const cli_app = @import("cli_app");
const ctl_branch = cli_app.ctl.branch;
const session_ctl = cli_app.session_ctl;

test "branch and fork command line parsers handle valid commands and flags" {
    // branch ls
    const b_ls = try ctl_branch.parseBranch(&.{"ls"});
    try std.testing.expectEqual(ctl_branch.BranchCommand.branch_ls, b_ls);

    // branch switch
    const b_sw = try ctl_branch.parseBranch(&.{ "switch", "3" });
    try std.testing.expectEqual(ctl_branch.BranchCommand{ .branch_switch = 3 }, b_sw);

    // branch rm without confirm
    const b_rm0 = try ctl_branch.parseBranch(&.{ "rm", "4" });
    try std.testing.expectEqual(ctl_branch.BranchCommand{ .branch_rm = .{ .id = 4, .confirm = false } }, b_rm0);

    // branch rm with confirm
    const b_rm1 = try ctl_branch.parseBranch(&.{ "rm", "4", "--confirm" });
    try std.testing.expectEqual(ctl_branch.BranchCommand{ .branch_rm = .{ .id = 4, .confirm = true } }, b_rm1);

    // fork confirm
    const f_conf = try ctl_branch.parseFork(&.{"confirm"});
    try std.testing.expectEqual(ctl_branch.BranchCommand.fork_confirm, f_conf);

    // fork cancel
    const f_canc = try ctl_branch.parseFork(&.{"cancel"});
    try std.testing.expectEqual(ctl_branch.BranchCommand.fork_cancel, f_canc);

    // fork status
    const f_stat = try ctl_branch.parseFork(&.{"status"});
    try std.testing.expectEqual(ctl_branch.BranchCommand.fork_status, f_stat);
}

test "branch and fork command line parsers reject bad arguments" {
    try std.testing.expectError(error.BadArguments, ctl_branch.parseBranch(&.{}));
    try std.testing.expectError(error.BadArguments, ctl_branch.parseBranch(&.{ "ls", "extra" }));
    try std.testing.expectError(error.BadArguments, ctl_branch.parseBranch(&.{"switch"}));
    try std.testing.expectError(error.BadArguments, ctl_branch.parseBranch(&.{ "rm", "1", "nope" }));
    try std.testing.expectError(error.UnknownCommand, ctl_branch.parseBranch(&.{"unknown"}));

    try std.testing.expectError(error.BadArguments, ctl_branch.parseFork(&.{}));
    try std.testing.expectError(error.BadArguments, ctl_branch.parseFork(&.{ "confirm", "extra" }));
    try std.testing.expectError(error.UnknownCommand, ctl_branch.parseFork(&.{"unknown"}));
}

test "session_ctl integrates branch and fork commands into Request" {
    const allocator = std.testing.allocator;

    const req_ls = try session_ctl.parse(allocator, &.{ "ra8_emulator", "ctl", "--connect", "unix:ctl.sock", "branch", "ls" });
    try std.testing.expectEqual(ctl_branch.BranchCommand.branch_ls, req_ls.command.branch_cmd);

    const req_conf = try session_ctl.parse(allocator, &.{ "ra8_emulator", "ctl", "--connect", "unix:ctl.sock", "fork", "confirm" });
    try std.testing.expectEqual(ctl_branch.BranchCommand.fork_confirm, req_conf.command.branch_cmd);
}
