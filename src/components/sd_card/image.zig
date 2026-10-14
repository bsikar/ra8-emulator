//! The card behind the SPI line: 512-byte blocks, held only where something
//! actually wrote one.
//!
//! Sparse, the shape nor_flash/flash.zig and bus_card.zig already take: a block
//! nobody has written reads back as zeros, which is what a freshly formatted
//! card gives, and a run that only reads holds nothing at all. dev backs its
//! card with a real host file through a sparse `--sd` image; there is no
//! `--sd` imports a raw host file into the sparse RAM-backed image, so its
//! capacity is stated by the file and checked against the CSD field.
const std = @import("std");
const observer = @import("ra8_chip").core.cpu.memory.observer;

pub const geometry = struct {
    /// The block size every SD command works in.
    pub const block_bytes: u32 = 512;
    /// CSD v2.0 counts capacity in 512 KiB units, which is 1024 blocks.
    pub const csize_unit: u32 = 1024;
    /// The capacity a card comes up with, 64 MiB, enough for the firmware's
    /// exFAT formatter and a whole number of C_SIZE units. A blank card can
    /// be given another size before anything is written to it; see resize.
    pub const default_capacity_blocks: u32 = 128 * 1024;
};

/// One block, the unit everything here moves.
pub const Block = [geometry.block_bytes]u8;

pub const LoadError = error{ BadImageSize, CardNotBlank, OutOfMemory };

pub const Image = struct {
    allocator: std.mem.Allocator,
    blocks: std.AutoHashMap(u32, *Block),
    /// How big this card is. Settable while it is blank, because a card's
    /// size is a property of the card and not of the model.
    capacity_blocks: u32 = geometry.default_capacity_blocks,
    /// The recording run's trail observer (H6), wired by the machine that
    /// mounts the card. Null everywhere a card is just storage.
    obs: ?observer.Observer = null,

    pub fn init(allocator: std.mem.Allocator) Image {
        return .{
            .allocator = allocator,
            .blocks = std.AutoHashMap(u32, *Block).init(allocator),
        };
    }

    pub fn deinit(self: *Image) void {
        self.obs = null;
        self.release();
        self.blocks.deinit();
    }

    /// Give every held block back. A power cycle leaves a real card with its
    /// contents, so this is teardown rather than reset.
    pub fn release(self: *Image) void {
        if (self.obs) |o| o.barrier(.{ .component = .{ .owner = self, .what = .release } });
        var it = self.blocks.valueIterator();
        while (it.next()) |stored| self.allocator.destroy(stored.*);
        self.blocks.clearRetainingCapacity();
    }

    /// Give this card another size. Refused once anything is held: a card
    /// with data on it is not a blank card, and refused for a size that is
    /// not a whole number of C_SIZE units, because the CSD could not then
    /// state it exactly.
    pub fn resize(self: *Image, blocks: u32) bool {
        if (blocks == 0 or blocks % geometry.csize_unit != 0) return false;
        if (self.held() != 0) return false;
        if (self.capacity_blocks == blocks) return true;
        self.capacity_blocks = blocks;
        if (self.obs) |o| o.barrier(.{ .component = .{ .owner = self, .what = .resize } });
        return true;
    }

    /// Attach a raw SDHC image whose byte length is representable by this
    /// card's CSD. Zero blocks stay sparse in the host model.
    pub fn loadBytes(self: *Image, bytes: []const u8) LoadError!void {
        const block_bytes: usize = geometry.block_bytes;
        const capacity_unit: usize = geometry.csize_unit;
        if (bytes.len == 0 or bytes.len % (block_bytes * capacity_unit) != 0 or
            bytes.len / block_bytes > std.math.maxInt(u32))
        {
            return error.BadImageSize;
        }
        if (self.held() != 0) return error.CardNotBlank;
        const blocks: u32 = @intCast(bytes.len / block_bytes);
        if (blocks == 0 or blocks % geometry.csize_unit != 0) return error.BadImageSize;
        self.capacity_blocks = blocks;
        // H6: a whole-image load is an install barrier, and the blocks it
        // brings in are the barrier's payload, not a trail of writes.
        if (self.obs) |o| o.barrier(.{ .component = .{ .owner = self, .what = .install } });
        var index: u32 = 0;
        while (index < blocks) : (index += 1) {
            const start: usize = @as(usize, index) * block_bytes;
            const source = bytes[start .. start + block_bytes];
            if (!allZero(source)) {
                var block: Block = undefined;
                @memcpy(&block, source);
                if (!self.put(index, &block)) {
                    self.release();
                    self.capacity_blocks = geometry.default_capacity_blocks;
                    return error.OutOfMemory;
                }
            }
        }
    }

    /// Lay one block in without a trail record: the load path's own hand.
    fn put(self: *Image, index: u32, data: *const Block) bool {
        if (!self.inRange(index)) return false;
        const fresh = self.allocator.create(Block) catch return false;
        self.blocks.put(index, fresh) catch {
            self.allocator.destroy(fresh);
            return false;
        };
        fresh.* = data.*;
        return true;
    }

    /// Blocks currently holding data.
    pub fn held(self: *const Image) usize {
        return self.blocks.count();
    }

    /// Whether a block number is on this card at all.
    pub fn inRange(self: *const Image, index: u32) bool {
        return index < self.capacity_blocks;
    }

    /// Read one block. A block nobody wrote is zeros; a block past the end of
    /// the card is not a block, and the caller is told so rather than handed
    /// a zero-filled one.
    pub fn read(self: *const Image, index: u32, out: *Block) bool {
        if (!self.inRange(index)) return false;
        if (self.blocks.get(index)) |stored| {
            out.* = stored.*;
        } else {
            out.* = @splat(0);
        }
        return true;
    }

    /// Take one block. False means the card has nowhere to put it: past the
    /// end, or out of memory, which the card answers as a write error.
    pub fn write(self: *Image, index: u32, data: *const Block) bool {
        if (!self.inRange(index)) return false;
        var before: Block = @splat(0);
        var held_already = false;
        if (self.blocks.get(index)) |stored| {
            before = stored.*;
            held_already = true;
        }
        if (!self.commit(index, data)) return false;
        if (self.obs) |o| {
            // A write that changes no byte invents no record, and a zero
            // block laid over an absent one leaves the card reading the
            // same: only real changes cross the success boundary.
            if (held_already) {
                if (!std.mem.eql(u8, &before, data)) {
                    o.bytes(.{
                        .base = 0,
                        .offset = @as(u64, index) * geometry.block_bytes,
                        .initiator = .none,
                        .pre = &before,
                    });
                }
            } else if (!allZero(data)) {
                o.bytes(.{
                    .base = 0,
                    .offset = @as(u64, index) * geometry.block_bytes,
                    .initiator = .none,
                    .pre = &before,
                });
            }
        }
        return true;
    }

    /// One block in, no trail: write's recording half lives above.
    fn commit(self: *Image, index: u32, data: *const Block) bool {
        if (self.blocks.get(index)) |stored| {
            stored.* = data.*;
            return true;
        }
        return self.put(index, data);
    }

    /// Zero an inclusive range of blocks. A held block is given back rather
    /// than filled with zeros: an unheld block already reads as zeros, so the
    /// two are the same card and one of them is free.
    pub fn zero(self: *Image, first: u32, last: u32) u32 {
        var index = first;
        var cleared: u32 = 0;
        while (index <= last and self.inRange(index)) : (index += 1) {
            if (self.blocks.fetchRemove(index)) |gone| {
                if (self.obs) |o| o.bytes(.{
                    .base = 0,
                    .offset = @as(u64, index) * geometry.block_bytes,
                    .initiator = .none,
                    .pre = gone.value,
                });
                self.allocator.destroy(gone.value);
                cleared += 1;
            }
            if (index == last) break;
        }
        return cleared;
    }

    /// CSD v2.0 C_SIZE: capacity is (C_SIZE + 1) units of 512 KiB.
    pub fn csize(self: *const Image) u32 {
        return self.capacity_blocks / geometry.csize_unit - 1;
    }

    /// Every block of this card in order, for the host to write over an
    /// image file (host/disk_file.zig replace, RA8EMU-334 and RA8EMU-1020).
    pub fn writeTo(self: *const Image, out: *std.Io.Writer) !void {
        var block: Block = undefined;
        var index: u32 = 0;
        while (index < self.capacity_blocks) : (index += 1) {
            _ = self.read(index, &block);
            try out.writeAll(&block);
        }
    }
};

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
