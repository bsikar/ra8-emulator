//! The card behind the SPI line: 512-byte blocks, held only where something
//! actually wrote one.
//!
//! Sparse, the shape xspi_flash.zig and sdhi_card.zig already take: a block
//! nobody has written reads back as zeros, which is what a freshly formatted
//! card gives, and a run that only reads holds nothing at all. dev backs its
//! card with a real host file through a sparse `--sd` image; there is no
//! host-file seam in this tree yet, so the image here is RAM-backed and its
//! capacity is the model's own choice, stated below rather than implied.
const std = @import("std");

pub const geometry = struct {
    /// The block size every SD command works in.
    pub const block_bytes: u32 = 512;
    /// CSD v2.0 counts capacity in 512 KiB units, which is 1024 blocks.
    pub const csize_unit: u32 = 1024;
    /// The model's own capacity, 32 MiB. Nothing in this tree fixes it; it
    /// is a whole number of C_SIZE units so the CSD comes out exact, and it
    /// is the same capacity sdhi_card.zig gives the card on the other host.
    pub const capacity_blocks: u32 = 64 * 1024;
};

/// One block, the unit everything here moves.
pub const Block = [geometry.block_bytes]u8;

pub const Image = struct {
    allocator: std.mem.Allocator,
    blocks: std.AutoHashMap(u32, *Block),

    pub fn init(allocator: std.mem.Allocator) Image {
        return .{
            .allocator = allocator,
            .blocks = std.AutoHashMap(u32, *Block).init(allocator),
        };
    }

    pub fn deinit(self: *Image) void {
        self.release();
        self.blocks.deinit();
    }

    /// Give every held block back. A power cycle leaves a real card with its
    /// contents, so this is teardown rather than reset.
    pub fn release(self: *Image) void {
        var it = self.blocks.valueIterator();
        while (it.next()) |stored| self.allocator.destroy(stored.*);
        self.blocks.clearRetainingCapacity();
    }

    /// Blocks currently holding data.
    pub fn held(self: *const Image) usize {
        return self.blocks.count();
    }

    /// Whether a block number is on this card at all.
    pub fn inRange(index: u32) bool {
        return index < geometry.capacity_blocks;
    }

    /// Read one block. A block nobody wrote is zeros; a block past the end of
    /// the card is not a block, and the caller is told so rather than handed
    /// a zero-filled one.
    pub fn read(self: *const Image, index: u32, out: *Block) bool {
        if (!inRange(index)) return false;
        if (self.blocks.get(index)) |stored| {
            out.* = stored.*;
        } else {
            out.* = .{0} ** geometry.block_bytes;
        }
        return true;
    }

    /// Take one block. False means the card has nowhere to put it: past the
    /// end, or out of memory, which the card answers as a write error.
    pub fn write(self: *Image, index: u32, data: *const Block) bool {
        if (!inRange(index)) return false;
        if (self.blocks.get(index)) |stored| {
            stored.* = data.*;
            return true;
        }
        const fresh = self.allocator.create(Block) catch return false;
        self.blocks.put(index, fresh) catch {
            self.allocator.destroy(fresh);
            return false;
        };
        fresh.* = data.*;
        return true;
    }

    /// Zero an inclusive range of blocks. A held block is given back rather
    /// than filled with zeros: an unheld block already reads as zeros, so the
    /// two are the same card and one of them is free.
    pub fn zero(self: *Image, first: u32, last: u32) u32 {
        var index = first;
        var cleared: u32 = 0;
        while (index <= last and inRange(index)) : (index += 1) {
            if (self.blocks.fetchRemove(index)) |gone| {
                self.allocator.destroy(gone.value);
                cleared += 1;
            }
            if (index == last) break;
        }
        return cleared;
    }

    /// CSD v2.0 C_SIZE: capacity is (C_SIZE + 1) units of 512 KiB.
    pub fn csize() u32 {
        return geometry.capacity_blocks / geometry.csize_unit - 1;
    }
};
