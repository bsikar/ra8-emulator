//! A place in memory whose stores are worth naming.
//!
//! `--break-at` answers "was this function reached"; `--dump-mem` answers
//! "what does it hold at the end". Neither answers the question a wall
//! actually raises, which is who put this value here. A run that ends with
//! `g_eoh_err = 5` says the firmware gave up and says nothing about where,
//! and finding out by hand means breaking on one candidate after another.
//!
//! A watched place records every store that lands in it, with the program
//! counter that made it. src/core/watch_hook.zig is the other half: this
//! file knows nothing about Unicorn, so the recording can be tested
//! without a live engine.
const std = @import("std");
const elf = @import("elf.zig");
const place = @import("place.zig");
const symbols = @import("symbols.zig");

pub const limits = struct {
    /// Stores kept in full. A value written once at the end of a failed
    /// path is the usual case; a counter incremented in a loop is not what
    /// this flag is for, and the tail of one is noise.
    pub const listed: usize = 8;
    /// The width of the window watched around the named address: a word,
    /// so a byte store anywhere in it is caught.
    pub const window: u32 = 4;
};

/// One store that landed in the watched place.
pub const Store = struct {
    /// Where the instruction that made it sits.
    pc: u32 = 0,
    /// The link register as the store happened. A value set through a
    /// shared failure helper has the same pc every time and the helper's
    /// name answers nothing; the caller is what the reader wanted, and
    /// this is where it is. Meaningless when the storing function has
    /// already pushed lr and reused it, so it is reported as the return
    /// address it is and never as a certainty.
    lr: u32 = 0,
    /// The value it wrote, as wide as it wrote it.
    value: u32 = 0,
    /// How many bytes it wrote.
    width: u8 = 0,
    /// Which byte of the watched word it started at.
    offset: u8 = 0,
};

/// The place, and what has been written to it so far.
pub const Watched = struct {
    /// The address the command line named, already resolved.
    address: u32 = 0,
    /// Every store that landed in the window, counted whether or not it
    /// was kept: a count that stops at the list length would understate a
    /// value written in a loop, which is exactly when the count matters.
    seen: usize = 0,
    kept: [limits.listed]Store = undefined,

    /// Record a store. Anything past the list is counted and dropped, so
    /// the memory a watch costs does not grow with the run.
    pub fn record(self: *Watched, pc: u32, lr: u32, address: u32, width: u8, value: u32) void {
        if (self.seen < limits.listed) {
            self.kept[self.seen] = .{
                .pc = pc,
                .lr = lr,
                .value = value,
                .width = width,
                .offset = @truncate(address -% self.address),
            };
        }
        self.seen += 1;
    }

    /// The stores kept in full, oldest first.
    pub fn listed(self: *const Watched) []const Store {
        return self.kept[0..@min(self.seen, limits.listed)];
    }

    /// The last address of the watched window.
    pub fn end(self: Watched) u32 {
        return self.address + limits.window - 1;
    }
};

/// Where `--watch` named, resolved before the run starts.
///
/// A place with a dereference is refused the same way a break refuses one:
/// the pointer it would read has not been written yet when the hook has to
/// be attached, so the address it names does not exist. A spelling the
/// image cannot answer is reported and watched as nothing, because a run
/// that silently watches the wrong word is worse than one that watches
/// none.
pub fn resolve(image: elf.Image, spec: ?[]const u8) ?Watched {
    const asked = spec orelse return null;
    const parsed = place.parse(asked) catch |err| {
        std.debug.print("--watch {s}: {s}\n", .{ asked, @errorName(err) });
        return null;
    };
    if (parsed.deref) {
        std.debug.print("--watch {s}: a watched place cannot dereference\n", .{asked});
        return null;
    }
    const base = if (parsed.name) |name|
        symbols.addressOf(image, name) orelse {
            std.debug.print("--watch {s}: no symbol named {s}\n", .{ asked, name });
            return null;
        }
    else
        parsed.address;
    return .{ .address = parsed.apply(base) };
}

/// What landed in the watched word, once the run is over.
///
/// Each store names the function its program counter sits in, so the
/// answer to "who wrote this" is in the report rather than one objdump
/// away. A run in which nothing wrote there says so: that is an answer,
/// and often the surprising one.
pub fn print(out: anytype, image: elf.Image, spec: ?[]const u8, watched: ?Watched) !void {
    const one = watched orelse return;
    try out.print(
        "  watch         : {s} @0x{X:0>8}, {d} store(s)\n",
        .{ spec orelse "", one.address, one.seen },
    );
    for (one.listed()) |store| {
        try out.print(
            "                  +{d} {d}-byte 0x{X:0>8} from pc 0x{X:0>8}",
            .{ store.offset, store.width, store.value, store.pc },
        );
        if (symbols.inside(image, store.pc)) |at| {
            try out.print(" {s}+0x{X}", .{ at.name, at.offset });
        }
        // The return address, minus the Thumb bit, names the caller. A
        // shared helper is the common case and the pc alone is useless
        // there, so this is printed whenever it resolves to a function.
        if (symbols.inside(image, store.lr & ~@as(u32, 1))) |at| {
            try out.print(" via {s}+0x{X}", .{ at.name, at.offset });
        }
        try out.print("\n", .{});
    }
    if (one.seen > limits.listed) {
        try out.print("                  and {d} more\n", .{one.seen - limits.listed});
    }
}
