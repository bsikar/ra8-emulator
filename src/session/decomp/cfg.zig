//! Per-function static control-flow graph representation (RA8EMU-1353).
const std = @import("std");

const block = @import("ra8_chip").core.cpu.decode.block;
const decode = @import("ra8_chip").core.cpu.decode;
const Instr = @import("ra8_chip").core.cpu.instr.Instr;

pub const BlockId = u32;

/// Recorded computed or indirect edge whose static destination requires later analysis.
pub const UnresolvedEdge = struct {
    from_block: BlockId,
    at_address: u32,
    reason: block.flow.UnresolvedReason,
};

/// Classification of an outgoing CFG edge from a basic block.
pub const EdgeKind = enum {
    fallthrough,
    branch_taken,
    branch_not_taken,
    call,
    tail_call,
    indirect_call,
    indirect_jump,
    svc,
};

/// Static edge leaving a basic block (either intra-procedural via `target_block` or external/unresolved).
pub const Edge = struct {
    kind: EdgeKind,
    target_block: ?BlockId = null,
    target_address: ?u32 = null,
    target_name: ?[]const u8 = null,
    unresolved: ?block.flow.UnresolvedReason = null,
};

/// Decoded instruction paired with its decoded metadata inside a basic block.
pub const Insn = struct {
    instr: Instr,
    hit: decode.Hit,
};

/// Non-overlapping basic block owned by a reconstructed function `Cfg`.
pub const BasicBlock = struct {
    id: BlockId,
    start: u32,
    end: u32,
    summary: block.flow.EdgeSummary,
    insns: []const Insn,
    succs: []const Edge,
    preds: []const BlockId,
};

/// Arena-backed static control-flow graph for one function entry.
pub const Cfg = struct {
    arena: std.heap.ArenaAllocator,
    entry: u32,
    extent_size: u32,
    name: ?[]const u8,
    blocks: []const BasicBlock,
    unresolved: []const UnresolvedEdge,
    truncated: bool = false,

    pub fn deinit(self: *Cfg) void {
        self.arena.deinit();
    }

    pub fn blockById(self: *const Cfg, id: BlockId) ?*const BasicBlock {
        if (id >= self.blocks.len) return null;
        return &self.blocks[id];
    }

    /// Binary-search for a block whose entry equals normalized `address`.
    pub fn blockAt(self: *const Cfg, address: u32) ?BlockId {
        const norm = address & ~@as(u32, 1);
        var low: usize = 0;
        var high: usize = self.blocks.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.blocks[mid].start < norm) {
                low = mid + 1;
            } else if (self.blocks[mid].start > norm) {
                high = mid;
            } else {
                return @intCast(mid);
            }
        }
        return null;
    }

    /// Find the basic block whose byte span `[start, end)` covers normalized `address`.
    pub fn blockContaining(self: *const Cfg, address: u32) ?BlockId {
        const norm = address & ~@as(u32, 1);
        var low: usize = 0;
        var high: usize = self.blocks.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.blocks[mid].start <= norm) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        if (low == 0) return null;
        const candidate = &self.blocks[low - 1];
        if (norm >= candidate.start and norm < candidate.end) return candidate.id;
        return null;
    }

    pub fn instructionCount(self: *const Cfg) usize {
        var total: usize = 0;
        for (self.blocks) |blk| {
            total += blk.insns.len;
        }
        return total;
    }
};
