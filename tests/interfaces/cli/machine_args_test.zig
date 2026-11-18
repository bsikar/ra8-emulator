//! Covers src/interfaces/cli/machine_args.zig: custom catalog selection and
//! single-core `--cpu1` refusal (RA8EMU-1342).
const cli_app = @import("cli_app");
const ra8 = @import("ra8");
const std = @import("std");

const machine_mod = ra8.chip.core.machine;

const single_core: machine_mod.Machine = .{
    .name = "single-m33",
    .label = "SINGLE-M33",
    .cores = .{
        .primary = machine_mod.core.cortexM33(.{
            .security = false,
            .fpu = .single,
            .systicks = 1,
        }),
    },
    .part = .ra8d2,
};

test "machine_args resolves custom machine and refuses --cpu1 on single-core" {
    const list = [_]*const machine_mod.Machine{ &machine_mod.catalog.ra8d2, &single_core };
    const ok = try cli_app.cli.parseWithCatalog(&.{ "emu", "a.elf", "--device", "single-m33" }, &list);
    try std.testing.expectEqual(&single_core, ok.resolvedMachine());
    try std.testing.expect(ok.part_set);
    try std.testing.expectError(
        error.MissingValue,
        cli_app.cli.parseWithCatalog(&.{ "emu", "a.elf", "--part" }, &list),
    );
    try std.testing.expectError(
        error.AbsentCore,
        cli_app.cli.parseWithCatalog(&.{ "emu", "a.elf", "--device", "single-m33", "--cpu1", "b.elf" }, &list),
    );
}

test "machine_args leaves --part to a preceding flag that takes it as its value" {
    const list = [_]*const machine_mod.Machine{ &machine_mod.catalog.ra8d2, &single_core };
    const until = try cli_app.cli.parseWithCatalog(&.{ "emu", "a.elf", "--until", "--part" }, &list);
    try std.testing.expectEqualStrings("--part", until.until.?);
    try std.testing.expectEqual(@as(?*const machine_mod.Machine, null), until.machine);
    try std.testing.expect(!until.part_set);
    const watch = try cli_app.cli.parseWithCatalog(
        &.{ "emu", "a.elf", "--watch", "--device", "--part", "single-m33" },
        &list,
    );
    try std.testing.expectEqualStrings("--device", watch.watch_place.?);
    try std.testing.expectEqual(&single_core, watch.resolvedMachine());
    try std.testing.expectError(
        error.UnknownPart,
        cli_app.cli.parseWithCatalog(&.{ "emu", "a.elf", "--part", "ra8p1" }, &list),
    );
    const ctl_line = &.{ "emu", "ctl", "cpu-load", "a.elf", "--part", "single-m33" };
    const ctl = try cli_app.cli.parseWithCatalog(ctl_line, &list);
    try std.testing.expectEqual(&single_core, ctl.resolvedMachine());
}
