//! Read-only instruction and memory view backed by an ELF image and optional live core.
const bus = @import("ra8_chip").core.cpu.bus;
const core_view = @import("../core_view.zig");
const elf = @import("ra8_board").image.elf;

/// Read-only `Bus` serving bytes from ELF `PT_LOAD` segments first, falling
/// back to a paused `core_view.View` only for RAM/flash addresses outside ELF segments.
pub const ImageBus = struct {
    image: ?elf.Image = null,
    live: ?core_view.View = null,

    pub fn view(self: *ImageBus) bus.Bus {
        return .{
            .ctx = self,
            .vtable = &.{
                .read = read,
                .write = write,
                .peek = peek,
                .allowsExec = allowsExec,
            },
        };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *ImageBus = @ptrCast(@alignCast(ctx));
        if (into.len == 0) return;
        if (self.image) |img| {
            if (segmentBytes(img, address, into.len, false)) |slice| {
                @memcpy(into, slice);
                return;
            }
        }
        if (self.live) |core| {
            if (safeLiveRange(address, into.len)) return core.read(address, into);
        }
        return bus.Error.Unmapped;
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        _ = .{ ctx, address, bytes };
        return bus.Error.Unmapped;
    }

    fn peek(ctx: *anyopaque, address: u32, into: []u8) bool {
        const self: *ImageBus = @ptrCast(@alignCast(ctx));
        if (into.len == 0) return true;
        if (self.image) |img| {
            if (segmentBytes(img, address, into.len, false)) |slice| {
                @memcpy(into, slice);
                return true;
            }
        }
        if (self.live) |core| {
            if (safeLiveRange(address, into.len)) {
                core.read(address, into) catch return false;
                return true;
            }
        }
        return false;
    }

    fn allowsExec(ctx: *anyopaque, address: u32, len: usize) bool {
        const self: *ImageBus = @ptrCast(@alignCast(ctx));
        if (len == 0) return true;
        if (self.image) |img| {
            if (segmentBytes(img, address, len, true) != null) return true;
            // Relocated RAM code is readable from live core when not present in any ELF segment.
            if (self.live != null and segmentBytes(img, address, len, false) == null) {
                return safeLiveRange(address, len);
            }
            return false;
        }
        if (self.live != null) return safeLiveRange(address, len);
        return false;
    }
};

fn segmentBytes(image: elf.Image, address: u32, len: usize, exec_only: bool) ?[]const u8 {
    var index: u16 = 0;
    while (index < image.segmentCount()) : (index += 1) {
        const seg = image.loadSegment(index) orelse continue;
        if (exec_only and !seg.executable()) continue;
        const start: u64 = address;
        const seg_start: u64 = seg.vaddr;
        const seg_end: u64 = seg_start + seg.bytes.len;
        if (start >= seg_start and start + len <= seg_end) {
            const offset: usize = @intCast(start - seg_start);
            return seg.bytes[offset .. offset + len];
        }
    }
    return null;
}

/// Never let static speculative fetches read MMIO (`0x4000_0000..0x5FFF_FFFF`) or PPB (`0xE000_0000+`).
fn safeLiveRange(address: u32, len: usize) bool {
    const start: u64 = address;
    const end: u64 = start + len;
    if (end > 0xE000_0000) return false;
    if (start < 0x6000_0000 and end > 0x4000_0000) return false;
    return true;
}
