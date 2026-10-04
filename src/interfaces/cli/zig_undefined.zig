//! `--stop-on-undefined` on a Zig run: the sites the undefined-instruction
//! sweep found (src/core/undefined_ops.zig), counted as the core reaches
//! them, and the run ended at the first one, before it executes.
//!
//! The Unicorn path does this with a code hook in front of each site. Here
//! the core asks a fetch guard (src/core/cpu/fetch_guard.zig) before every
//! instruction. The guard is only installed when the flag asks for it,
//! because it turns off the trip skipping a plain run relies on.
const elf = @import("../../core/elf.zig");
const undefined_ops = @import("../../core/undefined_ops.zig");
const cpu = @import("../../core/cpu/cpu.zig");
const cli = @import("cli.zig");

pub const Found = undefined_ops.Found;
pub const print = undefined_ops.print;

/// The swept sites, each asked to end the run, or none without the flag.
pub fn resolve(image: elf.Image, options: cli.Options) ?Found {
    if (!options.stop_on_undefined) return null;
    var found = undefined_ops.sweep(image);
    found.stopOnRun();
    return found;
}

/// Count an arrival at `address` and say whether it ends the run.
pub fn arrive(found: *Found, address: u32) bool {
    const at = address & ~@as(u32, 1);
    for (found.kept()) |*site| {
        if (site.address != at) continue;
        site.runs += 1;
        return site.stop;
    }
    return false;
}

/// The guard the core asks before each instruction, or none when the sweep
/// found nothing, so an image without sites keeps its fast loop.
pub fn guard(found: *Found) ?cpu.FetchGuard {
    if (found.count == 0) return null;
    return .{ .context = found, .holdsFn = holdsThunk };
}

fn holdsThunk(context: *anyopaque, address: u32) bool {
    const found: *Found = @ptrCast(@alignCast(context));
    return arrive(found, address);
}
