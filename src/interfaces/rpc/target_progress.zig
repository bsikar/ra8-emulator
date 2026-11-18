//! Per-connection hardware flash assembly and bounded ring of progress events
//! emitted on `targets_wire.progress_topic` (`0x183`).
const load_chunks = @import("session/load_chunks.zig");

pub const Item = struct {
    sequence: u64 = 0,
    stage: [32]u8 = undefined,
    stage_len: usize = 0,
    json: [4096]u8 = undefined,
    json_len: usize = 0,
};

pub const Queue = struct {
    items: [16]Item = undefined,
    head: usize = 0,
    count: usize = 0,
    next_seq: u64 = 0,

    pub fn push(self: *Queue, stage: []const u8, json: []const u8) void {
        self.next_seq += 1;
        const slot = if (self.count == self.items.len) blk: {
            const idx = self.head;
            self.head = (self.head + 1) % self.items.len;
            break :blk idx;
        } else blk: {
            const idx = (self.head + self.count) % self.items.len;
            self.count += 1;
            break :blk idx;
        };
        const stage_take = @min(stage.len, self.items[slot].stage.len);
        const json_take = @min(json.len, self.items[slot].json.len);
        @memcpy(self.items[slot].stage[0..stage_take], stage[0..stage_take]);
        @memcpy(self.items[slot].json[0..json_take], json[0..json_take]);
        self.items[slot].sequence = self.next_seq;
        self.items[slot].stage_len = stage_take;
        self.items[slot].json_len = json_take;
    }

    pub fn pop(self: *Queue) ?Item {
        if (self.count == 0) return null;
        const item = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.count -= 1;
        return item;
    }

    pub fn clear(self: *Queue) void {
        self.head = 0;
        self.count = 0;
    }
};

pub const State = struct {
    chunks: load_chunks.Assembler = .{},
    progress: Queue = .{},

    pub fn reset(self: *State) void {
        self.chunks.drop();
        self.progress.clear();
    }
};
