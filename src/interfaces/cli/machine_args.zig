//! Machine-selection and core-topology validation for CLI option parsing
//! (RA8EMU-1342), split out of cli.zig so cli.zig stays under the line cap.
//! The run parser records the name `--part` or `--device` gave in its own
//! place on the line, so a flag's value is never mistaken for a machine;
//! the name is resolved here, against whichever catalog the caller holds.
const cli = @import("cli.zig");
const machine_mod = @import("ra8_chip").core.machine;

/// Refuse `--cpu1` when the selected machine has no second core.
pub fn checkCores(options: cli.Options) !void {
    if (options.cpu1_path != null and !options.resolvedMachine().hasSecond()) {
        return error.AbsentCore;
    }
}

/// Parse `argv` against a caller-supplied machine catalog (`--part` / `--device`).
pub fn parseWithCatalog(
    argv: []const []const u8,
    machines: []const *const machine_mod.Machine,
) !cli.Options {
    var options = try cli.parseFlags(argv);
    try resolve(&options, machines);
    return options;
}

/// Turn the recorded machine name into its machine, refusing a name the
/// catalog does not hold, then check the core topology the line asks for.
pub fn resolve(options: *cli.Options, machines: []const *const machine_mod.Machine) !void {
    if (options.part_name) |name| {
        const chosen = machine_mod.catalog.findIn(machines, name) orelse return error.UnknownPart;
        options.machine = chosen;
        options.part = chosen.part;
        options.part_set = true;
    }
    try checkCores(options.*);
}
