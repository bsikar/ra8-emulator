//! The cross-core part of the end-of-run report: what went through the IPC
//! mailbox, what the other core was supposed to hear about, and what the
//! core's own MPU was asked to protect.
const Board = @import("board.zig").Board;
const Writer = @import("report.zig").Writer;
const ipc = @import("../periph/ipc.zig");
const sync = @import("../periph/ipc_sync.zig");
const cpu_ctrl = @import("../periph/cpu_ctrl.zig");
const mpu = @import("../periph/mpu.zig");

/// What CPU0 did with the second-core release handshake. ACT going up means
/// the handshake completed, never that a second core is fetching: this model
/// runs one core, so the line says released rather than running and the two
/// are never allowed to blur.
fn secondCore(board: *Board, out: Writer) !void {
    const unit = &board.second_core;
    if (unit.quiet()) return;
    try out.print(
        "CPU1: {s}, vector table 0x{X:0>8}, ACTCSR 0x{X:0>4}{s}\n",
        .{
            if (unit.act) "released" else "never activated",
            unit.initvtor,
            unit.status(),
            if (unit.running()) "" else ", CPUWAIT held",
        },
    );
    if (unit.act) {
        try out.print(
            "CPU1: no instruction was executed on it, this model runs one core\n",
            .{},
        );
    }
    if (unit.refused != 0) {
        try out.print(
            "CPU1: DROPPED {d} ACTCSR store(s) whose key byte was not 0x{X:0>2}\n",
            .{ unit.refused, cpu_ctrl.key.value >> 8 },
        );
    }
}

/// What the firmware programmed into the MPU, and what enforcement made of
/// it. A store into a read-only region and a fetch out of an execute-never
/// one are both refused with a MemManage, so the violations are the line that
/// matters: a run that programmed a protected span and never tripped it is a
/// different run from one that did.
fn regions(board: *Board, out: Writer) !void {
    const unit = &board.regions;
    const latch = &board.guard.latch;
    if (!unit.on() and unit.programmed() == 0) return;
    try out.print(
        "MPU: {s}, {d} of {d} region(s) enabled, {d} read-only{s}\n",
        .{
            if (unit.on()) "enabled" else "programmed but never enabled",
            unit.programmed(),
            mpu.geometry.regions,
            unit.readOnly(),
            if (unit.privilegedDefault()) ", privileged default map on" else "",
        },
    );
    if (latch.violations != latch.fetches + latch.loads) {
        try out.print(
            "MPU: REFUSED {d} store(s) the region did not allow\n",
            .{latch.violations - latch.fetches - latch.loads},
        );
    }
    if (latch.loads != 0) {
        try out.print(
            "MPU: REFUSED {d} load(s) the region did not allow\n",
            .{latch.loads},
        );
    }
    if (latch.fetches != 0) {
        try out.print(
            "MPU: REFUSED {d} fetch(es) the region did not allow\n",
            .{latch.fetches},
        );
    }
    if (latch.background != 0) {
        try out.print(
            "MPU: {d} of those landed outside every region, with no default map\n",
            .{latch.background},
        );
    }
    if (latch.privilege != 0) {
        try out.print(
            "MPU: {d} of those were unprivileged, into a privileged-only region\n",
            .{latch.privilege},
        );
    }
    if (latch.violations != 0) {
        try out.print(
            "MPU: {d} of {d} violation(s) took MemManage\n",
            .{ latch.faults, latch.violations },
        );
    }
    if (latch.escalated != 0) {
        try out.print(
            "MPU: {d} of those escalated to HardFault, MemManage was never enabled\n",
            .{latch.escalated},
        );
    }
    if (latch.unhandled != 0) {
        try out.print(
            "MPU: {d} violation(s) with no MemManage handler to take them\n",
            .{latch.unhandled},
        );
    }
    if (latch.stood_down) {
        try out.print("MPU: enforcement stood down, a refused fetch had nowhere to go\n", .{});
    }
    if (unit.on() and latch.violations == 0) {
        try out.print(
            "MPU: {d} read-only region(s) enforced, no access was refused\n",
            .{unit.readOnly()},
        );
    }
}

/// One line per channel that carried anything, plus the losses. A message a
/// full FIFO dropped and a read that found nothing are both real failures of
/// the handshake, so they are reported apart from the traffic that worked.
pub fn sections(board: *Board, out: Writer) !void {
    try secondCore(board, out);
    try regions(board, out);
    const mailbox = &board.mailbox;
    if (mailbox.quiet()) return;
    for (&mailbox.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try out.print(
            "IPC ch{d}: {d} poke(s), {d} word(s) sent, {d} taken, STA 0x{X:0>8}\n",
            .{ index, unit.sends, unit.pushes, unit.pops, unit.status() },
        );
        if (unit.lost != 0) {
            try out.print(
                "IPC ch{d}: {d} message(s) LOST, the four stages were full\n",
                .{ index, unit.lost },
            );
        }
        if (unit.starved != 0) {
            try out.print(
                "IPC ch{d}: {d} read(s) with the FIFO empty, no message was there\n",
                .{ index, unit.starved },
            );
        }
        if (unit.narrow_reads != 0) {
            try out.print(
                "IPC ch{d}: REFUSED {d} load(s) of RXD narrower than a word, the stage was kept\n",
                .{ index, unit.narrow_reads },
            );
        }
        if (unit.narrow_writes != 0) {
            try out.print(
                "IPC ch{d}: REFUSED {d} store(s) to TXD narrower than a word, no part message was sent\n",
                .{ index, unit.narrow_writes },
            );
        }
    }
    if (mailbox.wakes != 0) {
        try out.print("IPC: {d} receive event(s) raised on this core\n", .{mailbox.wakes});
    }
    if (mailbox.undelivered != 0) {
        try out.print(
            "IPC: {d} poke(s) addressed to the secondary core, which this build does not run\n",
            .{mailbox.undelivered},
        );
    }
    try locks(&mailbox.locks, out);
}

/// The semaphore file and the two NMI doorbells. A lock still held at the end
/// of a run is the interesting one: the core that took it never gave it back,
/// and on a two-core part the other side is still spinning for it.
fn locks(unit: *const sync.Sync, out: Writer) !void {
    for (&unit.semaphores, 0..) |*one, index| {
        if (one.quiet()) continue;
        try out.print(
            "IPCSEM{d}: {d} taken, {d} contended, {d} released, {s}\n",
            .{
                index,
                one.takes,
                one.contentions,
                one.releases,
                if (one.locked) "STILL HELD" else "free",
            },
        );
        if (one.stray_releases != 0) {
            try out.print(
                "IPCSEM{d}: {d} release(s) of a lock nobody held\n",
                .{ index, one.stray_releases },
            );
        }
    }
    for (&unit.doorbells, 0..) |*one, index| {
        if (one.quiet()) continue;
        try out.print(
            "IPC{d} NMI: {d} sent, {d} acknowledged, {s}\n",
            .{ index, one.sends, one.acks, if (one.pending) "PENDING" else "idle" },
        );
        if (one.coalesced != 0) {
            try out.print(
                "IPC{d} NMI: {d} send(s) onto a request already standing\n",
                .{ index, one.coalesced },
            );
        }
    }
}
