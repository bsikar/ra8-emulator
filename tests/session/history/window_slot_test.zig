const std = @import("std");
const testing = std.testing;
const ra8 = @import("ra8");
const slot_mod = ra8.session.history_window_slot;
const ArchState = slot_mod.ArchState;
const RegTag = slot_mod.RegTag;
const RegDiff = slot_mod.RegDiff;

test "window slot: perturb every single field of ArchState and roundtrip" {
    var pre: ArchState = .{};
    var post: ArchState = .{};

    // Perturb every tag with distinct values
    inline for (@typeInfo(RegTag).@"enum".field_values) |value| {
        const tag: RegTag = @fromBackingInt(@intCast(value));
        const idx: u32 = value;
        const val_pre: u32 = 0x1000_0000 + idx * 0x101;
        const val_post: u32 = 0x2000_0000 + idx * 0x303;

        // Ensure both boolean/enum and u32 fields get valid distinct values
        switch (tag) {
            .banked_current => {
                pre.writeField(tag, 0, true);
                post.writeField(tag, 1, true);
            },
            .event => {
                pre.writeField(tag, 0, true);
                post.writeField(tag, 1, true);
            },
            .exc_return => {
                pre.writeField(tag, val_pre, false); // pre is null
                post.writeField(tag, val_post, true); // post is some
            },
            .fnc_return => {
                pre.writeField(tag, val_pre, true);
                post.writeField(tag, val_post, false);
            },
            .exclusive => {
                pre.writeField(tag, val_pre, true);
                post.writeField(tag, val_post, false);
            },
            else => {
                pre.writeField(tag, val_pre, true);
                post.writeField(tag, val_post, true);
            },
        }
    }

    var diff_buf: [slot_mod.reg_tag_count]RegDiff = undefined;
    const diff_count = slot_mod.diffArch(&pre, &post, &diff_buf);

    // Every field was perturbed, so diff_count must be equal to reg_tag_count
    try testing.expectEqual(slot_mod.reg_tag_count, diff_count);

    // Current state starts at post
    var current = post;

    // Undo: swaps in-place, state becomes pre
    slot_mod.swapDiffInState(diff_buf[0..diff_count], &current);

    inline for (@typeInfo(RegTag).@"enum".field_values) |value| {
        const tag: RegTag = @fromBackingInt(@intCast(value));
        var cur_v: u32 = 0;
        var cur_ok: bool = false;
        current.readField(tag, &cur_v, &cur_ok);

        var pre_v: u32 = 0;
        var pre_ok: bool = false;
        pre.readField(tag, &pre_v, &pre_ok);

        try testing.expectEqual(pre_ok, cur_ok);
        if (pre_ok) try testing.expectEqual(pre_v, cur_v);
    }

    // Redo: swaps in-place again, state becomes post
    slot_mod.swapDiffInState(diff_buf[0..diff_count], &current);

    inline for (@typeInfo(RegTag).@"enum".field_values) |value| {
        const tag: RegTag = @fromBackingInt(@intCast(value));
        var cur_v: u32 = 0;
        var cur_ok: bool = false;
        current.readField(tag, &cur_v, &cur_ok);

        var post_v: u32 = 0;
        var post_ok: bool = false;
        post.readField(tag, &post_v, &post_ok);

        try testing.expectEqual(post_ok, cur_ok);
        if (post_ok) try testing.expectEqual(post_v, cur_v);
    }
}

test "window slot: compact delta for realistic instruction (PC + R0 change)" {
    var pre: ArchState = .{};
    pre.regs.pc = 0x0800_0100;
    pre.regs.low[0] = 42;

    var post = pre;
    post.regs.pc = 0x0800_0104;
    post.regs.low[0] = 100;

    var diff_buf: [16]RegDiff = undefined;
    const count = slot_mod.diffArch(&pre, &post, &diff_buf);

    // Only 2 fields changed
    try testing.expectEqual(@as(usize, 2), count);

    var current = post;
    slot_mod.swapDiffInState(diff_buf[0..count], &current);

    try testing.expectEqual(@as(u32, 0x0800_0100), current.regs.pc);
    try testing.expectEqual(@as(u32, 42), current.regs.low[0]);

    // Redo
    slot_mod.swapDiffInState(diff_buf[0..count], &current);
    try testing.expectEqual(@as(u32, 0x0800_0104), current.regs.pc);
    try testing.expectEqual(@as(u32, 100), current.regs.low[0]);
}
