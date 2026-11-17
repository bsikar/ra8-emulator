//! Parsed control requests and their payloads.
const ctl_branch = @import("branch.zig");
const ctl_nav = @import("nav.zig");
const ctl_write = @import("write.zig");
const events = @import("events.zig");
const proto = @import("ra8_rpc").session.rpc;
const Spec = @import("../serve/listen.zig").Spec;
const targets = @import("targets.zig");

pub const Command = union(enum) {
    targets: targets.Command,
    load: []const u8,
    run: u64,
    advance: u64,
    seek: []const u8,
    marker_set: ctl_nav.MarkerSet,
    nav: ctl_nav.NavQuery,
    frame_status,
    play: ctl_nav.PlayCmd,
    rc,
    step,
    pause,
    regs: []const proto.Register,
    mem: struct { address: u32, length: u32 },
    disasm: proto.Disassemble,
    /// Thousandths of the default rate; zero is `max`.
    speed: u64,
    set_break: u32,
    set_break_name: []const u8,
    clear_break: u32,
    set_watch: struct { address: u32, access: proto.Access },
    clear_watch: u32,
    events: events.Options,
    part: Part,
    files: Files,
    /// The memory map of the last loaded image (RA8EMU-794).
    map,
    /// The stack pointers, their low marks and any overflow (RA8EMU-816).
    stack,
    /// The board's RTC calendar (RA8EMU-809).
    rtc,
    /// The peripheral blocks, or one block's registers when named (RA8EMU-818).
    periph: []const u8,
    /// CPU0's sampled stacks, folded, for one thread and window (RA8EMU-833).
    folded: Folded,
    branch_cmd: ctl_branch.BranchCommand,
    write_cmd: ctl_write.WriteCommand,
    diff_cmd: struct { a: []const u8, b: []const u8 },
};

/// What `ctl folded` asks for; the defaults take every thread, all time.
pub const Folded = struct { thread: u32 = proto.all_threads, from_ns: u64 = 0, to_ns: u64 = 0xFFFF_FFFF_FFFF_FFFF };

pub const Part = struct { method: proto.Method, text: []const u8 };

pub const Files = struct { method: proto.Method, path: []const u8 };

/// A profile from the hosts file and the image its `serve` boots.
pub const Host = struct { name: []const u8, hosts: ?[]const u8, image: []const u8 };

pub const Where = union(enum) { connect: Spec, host: Host };

pub const Request = struct { where: Where, json: bool, command: Command };
