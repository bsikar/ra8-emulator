//! `ra8_emulator sweep` (RA8EMU-645): run the synthetic weight-streaming
//! workload across every board memory configuration the RA8P1 controllers
//! support and print the sizing report, a table by default or JSON with
//! `--report json`.
const std = @import("std");
const workload = @import("../../sizing/workload.zig");
const matrix = @import("../../sizing/matrix.zig");
const sweep = @import("../../sizing/sweep.zig");
const sweep_report = @import("sweep_report.zig");
const sweep_table = @import("sweep_table.zig");

pub const usage =
    \\usage: ra8_emulator sweep [--weights-mib N] [--activations-kib N] [--passes N]
    \\                          [--target-ms N] [--report table|json]
    \\
;

pub const Options = struct {
    job: workload.Synthetic = .{},
    target_ns: ?u64 = null,
    json: bool = false,
};

/// The flags after `sweep`, each a name and a value.
pub fn parse(args: anytype) !Options {
    var options: Options = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.BadArguments;
        const flag: []const u8 = args[index];
        const value: []const u8 = args[index + 1];
        if (std.mem.eql(u8, flag, "--report")) {
            options.json = if (std.mem.eql(u8, value, "json")) true else if (std.mem.eql(u8, value, "table")) false else return error.BadArguments;
            continue;
        }
        const number = std.fmt.parseInt(u64, value, 10) catch return error.BadArguments;
        if (std.mem.eql(u8, flag, "--weights-mib")) {
            options.job.weights_bytes = std.math.mul(u64, number, workload.mib) catch return error.BadArguments;
        } else if (std.mem.eql(u8, flag, "--activations-kib")) {
            options.job.activations_bytes = std.math.mul(u64, number, workload.kib) catch return error.BadArguments;
        } else if (std.mem.eql(u8, flag, "--passes")) {
            options.job.passes = std.math.cast(u32, number) orelse return error.BadArguments;
        } else if (std.mem.eql(u8, flag, "--target-ms")) {
            options.target_ns = std.math.mul(u64, number, 1_000_000) catch return error.BadArguments;
        } else return error.BadArguments;
    }
    options.job.validate() catch return error.BadArguments;
    return options;
}

/// The whole command: argv[0] is the program, argv[1] is "sweep".
pub fn run(argv: anytype) !u8 {
    const options = parse(argv[2..]) catch {
        try std.io.getStdErr().writeAll(usage);
        return 2;
    };
    var rows: [matrix.count]sweep.Row = undefined;
    try sweep.all(options.job, options.target_ns, &rows);
    var buffered = std.io.bufferedWriter(std.io.getStdOut().writer());
    try emit(buffered.writer(), options, &rows);
    try buffered.flush();
    return 0;
}

/// The report the options asked for, over `out`.
pub fn emit(out: anytype, options: Options, rows: []const sweep.Row) !void {
    if (options.json) return sweep_report.document(out, options.job, options.target_ns, rows);
    try sweep_table.write(out, options.job, options.target_ns, rows);
}
