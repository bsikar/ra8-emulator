//! Static control-flow classification for decoded basic blocks (RA8EMU-1353).
//!
//! Pairs with `block.zig` and `end.zig`: interprets the terminating instruction
//! of a block into static successor addresses, call/return semantics, IT-block
//! slot counts, and unresolved computed-target reasons.
const block_end = @import("end.zig");
const block_mod = @import("block.zig");
const branch_table = @import("../ops/branch/table.zig");
const branch_wide = @import("../ops/branch/wide.zig");
const cbz = @import("../ops/cbz.zig");
const Instr = @import("../instr.zig").Instr;
const lob = @import("../../lob.zig");
const mve_lob_tp = @import("../ops/mve/lob_tp.zig");

/// Why a block transfers control to a target that cannot be resolved statically.
pub const UnresolvedReason = enum {
    indirect_branch,
    indirect_call,
    table_branch,
    pc_memory_load,
};

/// Coarse static control-flow exit kind of a basic block.
pub const Kind = enum {
    fallthrough,
    it_block,
    branch,
    cond_branch,
    call,
    indirect_call,
    svc,
    ret,
    indirect_jump,
    halt,
};

/// Static successor summary for one basic block.
pub const EdgeSummary = struct {
    kind: Kind,
    target: ?u32 = null,
    fallthrough: ?u32 = null,
    unresolved: ?UnresolvedReason = null,
    /// Remaining IT-block instruction slots (1..4) opened when `kind == .it_block`.
    it_slots: u3 = 0,
    /// True when block formation stopped because fetch or decode failed.
    decode_stop: bool = false,
};

/// Classify the static control-flow exit of a formed `Block`.
/// When `in_it` is true, the block's terminating instruction executes conditionally
/// inside an enclosing IT block and retains a fallthrough edge.
pub fn fromBlock(blk: block_mod.Block, in_it: bool) EdgeSummary {
    if (blk.len == 0) return .{ .kind = .halt, .decode_stop = true };
    const last = blk.items()[blk.len - 1].instr;
    if (!block_end.endsBlock(last)) {
        return .{ .kind = .fallthrough, .fallthrough = last.address +% last.size };
    }
    return classify(last, in_it);
}

/// Classify a single instruction into static outgoing edges.
pub fn classify(instr: Instr, in_it: bool) EdgeSummary {
    if (!block_end.endsBlock(instr)) {
        return .{ .kind = .fallthrough, .fallthrough = instr.address +% instr.size };
    }
    if (instr.size == 2) return classifyNarrow(instr, in_it);
    return classifyWide(instr, in_it);
}

fn optFallthrough(after: u32, keep: bool) ?u32 {
    return if (keep) after else null;
}

fn classifyNarrow(instr: Instr, in_it: bool) EdgeSummary {
    const hw1 = instr.hw1;
    const after = instr.address +% 2;

    if ((hw1 & 0xFF00) == 0xBF00 and (hw1 & 0x000F) != 0) {
        const mask: u4 = @truncate(hw1 & 0x000F);
        const slots: u3 = @intCast(4 - @ctz(mask));
        return .{ .kind = .it_block, .fallthrough = after, .it_slots = slots };
    }
    if ((hw1 & 0xFF00) == 0xDF00) return .{ .kind = .svc, .fallthrough = after };
    if ((hw1 & 0xFF00) == 0xBE00 or (hw1 & 0xFF00) == 0xDE00) {
        return .{ .kind = .halt, .fallthrough = optFallthrough(after, in_it) };
    }
    if ((hw1 & 0xF000) == 0xD000) return narrowCondBranch(instr, after);
    if ((hw1 & 0xF800) == 0xE000) return narrowBranch(instr, after, in_it);
    if ((hw1 & cbz.encodings.mask) == cbz.encodings.cb) {
        return .{ .kind = .cond_branch, .target = instr.address +% 4 +% cbz.offset(hw1), .fallthrough = after };
    }
    if ((hw1 & 0xFF00) == 0xBD00) {
        return .{ .kind = .ret, .fallthrough = optFallthrough(after, in_it) };
    }
    if ((hw1 & 0xFC00) == 0x4400) return classifySpecialData(hw1, after, in_it);
    return .{ .kind = .fallthrough, .fallthrough = after };
}

fn narrowCondBranch(instr: Instr, after: u32) EdgeSummary {
    const imm8: i8 = @bitCast(@as(u8, @truncate(instr.hw1)));
    const delta: u32 = @bitCast(@as(i32, imm8) << 1);
    return .{ .kind = .cond_branch, .target = instr.address +% 4 +% delta, .fallthrough = after };
}

fn narrowBranch(instr: Instr, after: u32, in_it: bool) EdgeSummary {
    const imm11: i11 = @bitCast(@as(u11, @truncate(instr.hw1)));
    const delta: u32 = @bitCast(@as(i32, imm11) << 1);
    const target = instr.address +% 4 +% delta;
    return .{
        .kind = if (in_it) .cond_branch else .branch,
        .target = target,
        .fallthrough = optFallthrough(after, in_it),
    };
}

fn classifySpecialData(hw1: u16, after: u32, in_it: bool) EdgeSummary {
    if ((hw1 & 0xFF80) == 0x4780) {
        return .{ .kind = .indirect_call, .fallthrough = after, .unresolved = .indirect_call };
    }
    if ((hw1 & 0xFF80) == 0x4700) {
        const rm: u4 = @truncate((hw1 >> 3) & 0xF);
        if (rm == 14) return .{ .kind = .ret, .fallthrough = optFallthrough(after, in_it) };
        return .{ .kind = .indirect_jump, .fallthrough = optFallthrough(after, in_it), .unresolved = .indirect_branch };
    }
    // 0x45xx is CMP hi-reg: updates APSR flags without writing PC.
    if ((hw1 & 0xFF00) == 0x4500) return .{ .kind = .fallthrough, .fallthrough = after };
    if ((hw1 & 0xFF87) == 0x4687) {
        const rm: u4 = @truncate((hw1 >> 3) & 0xF);
        if (rm == 14) return .{ .kind = .ret, .fallthrough = optFallthrough(after, in_it) };
        if (rm == 15) {
            return .{
                .kind = if (in_it) .cond_branch else .branch,
                .target = after +% 2,
                .fallthrough = optFallthrough(after, in_it),
            };
        }
        return .{ .kind = .indirect_jump, .fallthrough = optFallthrough(after, in_it), .unresolved = .indirect_branch };
    }
    if ((hw1 & 0xFF87) == 0x4487) {
        return .{ .kind = .indirect_jump, .fallthrough = optFallthrough(after, in_it), .unresolved = .indirect_branch };
    }
    return .{ .kind = .fallthrough, .fallthrough = after };
}

fn classifyWide(instr: Instr, in_it: bool) EdgeSummary {
    const hw1 = instr.hw1;
    const hw2 = instr.hw2;
    const after = instr.address +% 4;

    if ((hw1 & 0xF800) == 0xF000 and (hw2 & 0x8000) != 0) {
        return classifyWideF000(instr, after, in_it);
    }
    if ((hw1 & 0xFE00) == 0xE800) {
        return classifyWideE800(hw1, hw2, after, in_it);
    }
    if ((hw1 & 0xFE00) == 0xF800) {
        // Single-register Thumb-2 POP.W {pc}: LDR.W PC, [SP], #4.
        if (hw1 == 0xF85D and hw2 == 0xFB04) {
            return .{ .kind = .ret, .fallthrough = optFallthrough(after, in_it) };
        }
        // Only word loads with Rt == 15 modify PC; PLD/PLI hints keep Rt == 15 with size != 0b10.
        if ((hw1 & 0x0070) == 0x0050 and (hw2 & 0xF000) == 0xF000) {
            return .{
                .kind = .indirect_jump,
                .fallthrough = optFallthrough(after, in_it),
                .unresolved = .pc_memory_load,
            };
        }
    }
    return .{ .kind = .fallthrough, .fallthrough = after };
}

fn classifyWideLoop(instr: Instr, after: u32) ?EdgeSummary {
    if (lob.decode(instr.hw1, instr.hw2)) |loop| {
        return switch (loop.kind) {
            .dls => .{ .kind = .fallthrough, .fallthrough = after },
            .wls => .{ .kind = .cond_branch, .target = after +% loop.offset, .fallthrough = after },
            .le => .{ .kind = .cond_branch, .target = after -% loop.offset, .fallthrough = after },
        };
    }
    if (mve_lob_tp.fields(instr)) |tp| {
        return switch (tp.kind) {
            .dlstp, .lctp => .{ .kind = .fallthrough, .fallthrough = after },
            .wlstp => .{ .kind = .cond_branch, .target = after +% tp.offset, .fallthrough = after },
            .letp => .{ .kind = .cond_branch, .target = after -% tp.offset, .fallthrough = after },
        };
    }
    return null;
}

fn classifyWideF000(instr: Instr, after: u32, in_it: bool) EdgeSummary {
    if (classifyWideLoop(instr, after)) |loop_summary| return loop_summary;
    const hw1 = instr.hw1;
    const hw2 = instr.hw2;
    if ((hw2 & 0xD000) == 0xD000) {
        const target = instr.address +% 4 +% @as(u32, @bitCast(branch_wide.offset24(instr)));
        return .{ .kind = .call, .target = target, .fallthrough = after };
    }
    if ((hw2 & 0xD000) == 0x9000) {
        const target = instr.address +% 4 +% @as(u32, @bitCast(branch_wide.offset24(instr)));
        return .{
            .kind = if (in_it) .cond_branch else .branch,
            .target = target,
            .fallthrough = optFallthrough(after, in_it),
        };
    }
    if ((hw2 & 0xD000) == 0x8000 and ((hw1 >> 6) & 0xE) != 0xE) {
        const target = instr.address +% 4 +% @as(u32, @bitCast(branch_wide.offset20(instr)));
        return .{ .kind = .cond_branch, .target = target, .fallthrough = after };
    }
    if ((hw1 & 0xFFF0) == 0xF7F0 and (hw2 & 0xF000) == 0xA000) {
        return .{ .kind = .halt, .fallthrough = optFallthrough(after, in_it) };
    }
    if ((hw1 & 0xFFF0) == 0xF3D0 and (hw2 & 0xFF00) == 0x8F00) {
        return .{ .kind = .ret, .fallthrough = optFallthrough(after, in_it) };
    }
    return .{ .kind = .fallthrough, .fallthrough = after };
}

fn classifyWideE800(hw1: u16, hw2: u16, after: u32, in_it: bool) EdgeSummary {
    const is_table = (hw1 & branch_table.encodings.hw1_mask) == branch_table.encodings.hw1 and
        (hw2 & branch_table.encodings.hw2_mask) == branch_table.encodings.hw2;
    if (is_table) {
        return .{
            .kind = .indirect_jump,
            .fallthrough = optFallthrough(after, in_it),
            .unresolved = .table_branch,
        };
    }
    if (hw1 == 0xE97F and hw2 == 0xE97F) {
        return .{ .kind = .fallthrough, .fallthrough = after };
    }
    if (hw1 == 0xE8BD and (hw2 & 0x8000) != 0) {
        return .{ .kind = .ret, .fallthrough = optFallthrough(after, in_it) };
    }
    const is_ldm = (hw1 & 0x01D0) == 0x0090 or (hw1 & 0x01D0) == 0x0110;
    if (is_ldm and (hw2 & 0x8000) != 0) {
        return .{
            .kind = .indirect_jump,
            .fallthrough = optFallthrough(after, in_it),
            .unresolved = .pc_memory_load,
        };
    }
    return .{ .kind = .fallthrough, .fallthrough = after };
}
