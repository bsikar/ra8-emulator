//! The command line: the flags the emulator takes and nothing else.
const std = @import("std");
const part = @import("../../core/part.zig");
const place = @import("../../debug/place.zig");
const pc_hits = @import("../../debug/pc_hits.zig");
const gt911 = @import("../../periph/i3c/i3c_gt911.zig");
const touch_spec = @import("touch_spec.zig");
const max17048 = @import("../../periph/i3c/i3c_max17048.zig");
const sd_format = @import("../../periph/sd/sd_format.zig");
const cpu_choice = @import("../../core/cpu/choice.zig");
const rtos_load = @import("../../debug/rtos_load.zig");

pub const usage = @import("cli_usage.zig").text;
pub const card_setup = @import("card_setup.zig");
pub const console_output = @import("console_output.zig");

/// How many `--dump-sym` names one run will carry. The suite that drives
/// this asks for at most two, a progress counter and a failure counter; the
/// cap is a little room above that rather than an allocation.
pub const dump_limit: usize = 8;

/// Instructions a run gets when nothing tells it when to stop. Long enough
/// for an app to reach whatever it prints and short enough that a sweep of
/// the whole corpus stays quick.
pub const budget: usize = 2_000_000;

/// Instructions a run gets when `--stop-sym` is watching a counter. A
/// watched run has an end of its own and reaches it early, so the budget is
/// only the ceiling on an app that never gets there: at the throughput this
/// model runs at, roughly 37 million instructions a second, that ceiling is
/// a few seconds rather than the fraction of one the default would give.
/// The suite's own apps need tens of millions (blink_ra8p1 reaches its fifth
/// tick at about 24 million), which the default budget ends ten times short
/// of, reporting a clean run for an app that had barely started.
pub const watched_budget: usize = 200_000_000;

/// Instructions one modelled millisecond costs at the fastest core clock
/// this corpus reaches, which is what bounds a `--ms` run.
///
/// The deadline itself is counted in SysTick periods, not here: this is only
/// the ceiling that keeps an image which never arms SysTick from running to
/// no end at all. cpuclk0 comes up at 1 GHz, the model charges one cycle per
/// instruction, and `ra8_time_init` arms SysTick at `cpu_hz / 1000`, so a
/// period there is a million instructions: measured on `doc_demo`,
/// `gpt_one_shot_demo` and `gpt_irq_demo`, all of which report exactly 50
/// periods in a 50,000,000-instruction run. Nothing in the corpus runs a
/// faster core, so no timed run is cut short by this; a slower one, like
/// `blink` at about 8,400 instructions a period, reaches its deadline long
/// before the ceiling.
pub const instructions_per_ms: usize = 1_000_000;

pub const Options = struct {
    path: []const u8,
    /// The budget `--instructions` asked for, or null to take whichever
    /// default fits the run. Resolved by `budget`, never read raw.
    instructions: ?usize = null,
    /// Which part the run models. The two share a register map; the RA8P1
    /// also carries the Ethos-U55, so this decides whether that window
    /// answers at all.
    part: part.Part = .ra8d2,
    /// Format the card on the SPI line before the run. Null leaves it the
    /// way it has always come up: blank, with no volume on it at all.
    sd_new: ?sd_format.Kind = null,
    /// The volume label that format gives the card.
    sd_label: []const u8 = "RA8",
    /// The card's size in MiB. Null keeps the image's own default.
    sd_size_mb: ?u32 = null,
    /// Raw SDHC image file to attach to the SPI card.
    sd_path: ?[]const u8 = null,
    /// A disk in the HS jack's USB stick: "blank" or a raw image path.
    usb_disk: ?[]const u8 = null,
    /// Cable the HS host jack to the board's own FS device jack.
    usb_loop: bool = false,
    /// Write one line per SD command to stderr.
    trace_sd: bool = false,
    /// Stream completed SCI console lines to stdout as they arrive.
    console: bool = false,
    /// Print this card block back as hex once the run is over.
    dump_sd: ?u32 = null,
    /// Contacts to queue on the touch panel, one drained per frame the
    /// firmware reads.
    touches: [gt911.queue_depth]gt911.Contact = .{gt911.Contact{}} ** gt911.queue_depth,
    touch_count: usize = 0,
    /// What the fuel gauge says is in the battery; the gauge range-checks it.
    battery: max17048.Battery = .{},
    /// Fit the Click module, so the IMU and the fuel gauge answer at all.
    click: bool = false,
    /// A refused access raises the precise BusFault it raises on silicon
    /// instead of ending the run; src/core/bus_error.zig. On by default;
    /// `--no-bus-errors` brings back the old end-of-run fault report.
    bus_errors: bool = true,
    /// Globals to read out of RAM once the run is over, in the order asked.
    dump: [dump_limit][]const u8 = .{""} ** dump_limit,
    dump_count: usize = 0,
    /// A global to watch, and the value that ends the run once it reaches
    /// it. Null watches nothing and the run goes to its instruction budget.
    stop_symbol: ?[]const u8 = null,
    stop_at: u32 = 0,
    /// Where to stop, spelled the way `place.parse` reads it: a function,
    /// an address, or either with an offset. Null stops at nothing and the
    /// run goes to its instruction budget.
    break_place: ?[]const u8 = null,
    /// Which arrival at `break_place` ends the run. One is the first.
    break_arrival: u32 = 1,
    /// Print the core registers after the run.
    dump_regs: bool = false,
    /// End the run at the first undefined instruction it reaches, before
    /// that instruction executes. Off by default: the sweep reports, it
    /// does not decide.
    stop_on_undefined: bool = false,
    /// A place in memory to read once the run is over, spelled the way
    /// `place.parse` reads it. Null reads nothing.
    dump_mem: ?[]const u8 = null,
    /// How many words that read prints. Null takes the default.
    dump_mem_words: ?u32 = null,
    /// A place whose stores to record, as the command line spelled it.
    /// Null watches nothing and costs the run nothing.
    watch_place: ?[]const u8 = null,
    /// `--trace-rtos`: record ThreadX thread switches. src/debug/rtos_hook.zig.
    trace_rtos: bool = false,
    /// `--cpu-load`: CPU load per thread and ISR, per core, from the same
    /// hook. src/debug/rtos_report.zig.
    cpu_load: bool = false,
    /// `--cpu-load-from` / `--cpu-load-to`: the virtual instructions the
    /// load is charged over. Either one turns `--cpu-load` on.
    cpu_load_window: rtos_load.Window = .{},
    /// `--taken-in`: a function to catch every exception taken inside.
    /// src/debug/taken_in.zig says why a tally cannot answer that.
    taken_in_place: ?[]const u8 = null,
    /// `--count-pc`: instruction addresses to count executions of, in the
    /// order they were given. src/debug/pc_hits.zig says why a counter
    /// that measures nothing but the execution is worth having.
    count_pc: [pc_hits.limits.places]u32 = [_]u32{0} ** pc_hits.limits.places,
    /// How many of `count_pc` were actually given.
    count_pc_len: usize = 0,
    /// `--chunk`: how many instructions between two boundaries, overriding
    /// the run's own cadence. For asking whether a result depends on where
    /// the boundaries fall. src/core/cadence.zig carries the default.
    chunk_instructions: ?u32 = null,
    /// `--drain-pends`: let a Thread-mode store that raises nothing still
    /// end the stretch, so the controller gets another look at a pend it
    /// still owes the firmware. Off by default; src/core/pend_break.zig
    /// carries what it measures and why it is not the default yet.
    drain_pends: bool = false,
    /// `--look-per-rise`: the bounded form of `--drain-pends`, one look
    /// per rise rather than one per store. src/core/pend_look.zig carries
    /// why the bound does not bound anything in practice.
    look_per_rise: bool = false,
    /// `--pace-masked`: narrow the boundary while a masked pend keeps
    /// coming back stuck. Off by default; src/core/mask_pace.zig carries
    /// the measurement that says it recovers nothing.
    pace_masked: bool = false,
    /// The second core's image, when the run is a two-core one.
    cpu1_path: ?[]const u8 = null,
    /// `--ns`: the Non-Secure companion image, loaded beside the main one.
    ns_path: ?[]const u8 = null,
    /// `--cpu`: which CPU runs the image; src/core/cpu/choice.zig.
    cpu: cpu_choice.Choice = .unicorn,
    /// Milliseconds of modelled time the run is allowed, counted in SysTick
    /// periods. Null is untimed and the run goes to its instruction budget.
    ms: ?u64 = null,

    /// The names asked for, as a slice rather than the fixed array.
    pub fn dumps(self: *const Options) []const []const u8 {
        return self.dump[0..self.dump_count];
    }

    /// How many instructions this run gets. An explicit `--instructions`
    /// always wins; otherwise a run with a counter to watch gets the
    /// watched budget and every other run gets the default.
    ///
    /// `watching` is whether a counter was actually resolved, not whether
    /// the flag was spelled: a `--stop-sym` naming a symbol the image does
    /// not carry watches nothing, and spending the larger budget on it
    /// would cost seconds per app to reach the same verdict.
    ///
    /// A timed run sizes its own ceiling from the deadline it was given, so
    /// asking for more milliseconds buys more instructions to spend them in
    /// rather than running into a number set for some other app.
    /// Whether the ThreadX hook is armed: either flag reads it.
    /// The load window when a flag asked for the RTOS trace, else null.
    pub fn rtosWanted(self: *const Options) ?rtos_load.Window {
        if (!self.trace_rtos and !self.cpu_load) return null;
        return self.cpu_load_window;
    }

    pub fn budgetFor(self: *const Options, watching: bool) usize {
        if (self.instructions) |asked| return asked;
        if (self.ms) |milliseconds| return ceilingFor(milliseconds);
        return if (watching) watched_budget else budget;
    }
};

/// The instruction ceiling a deadline of `milliseconds` gets, saturating
/// rather than wrapping: a deadline nothing could reach is still a run that
/// ends, not one that overflows into a short budget.
pub fn ceilingFor(milliseconds: u64) usize {
    const wanted = milliseconds *| @as(u64, instructions_per_ms);
    return std.math.cast(usize, wanted) orelse std.math.maxInt(usize);
}

pub fn parse(argv: []const []const u8) !Options {
    if (argv.len < 2) return error.MissingImage;
    var options = Options{ .path = argv[1] };
    var index: usize = 2;
    while (index < argv.len) : (index += 1) {
        if (try parseWorld(&options, argv, &index)) continue;
        if (try parseDebug(&options, argv, &index)) continue;
        if (std.mem.eql(u8, argv[index], "--instructions")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            options.instructions = try std.fmt.parseInt(usize, argv[index], 10);
        } else if (std.mem.eql(u8, argv[index], "--dump-sym")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            if (options.dump_count >= options.dump.len) return error.TooManyDumps;
            options.dump[options.dump_count] = argv[index];
            options.dump_count += 1;
        } else if (std.mem.eql(u8, argv[index], "--stop-sym")) {
            if (index + 2 >= argv.len) return error.MissingValue;
            options.stop_symbol = argv[index + 1];
            options.stop_at = try std.fmt.parseInt(u32, argv[index + 2], 10);
            index += 2;
        } else if (std.mem.eql(u8, argv[index], "--break-sym") or
            std.mem.eql(u8, argv[index], "--break-at"))
        {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            options.break_place = argv[index];
            // The count is optional, so it is taken only when the next
            // argument is one. A place that is itself a number is written
            // 0x-prefixed or not, and either way it has already been
            // taken by the line above; the flag that may follow instead
            // always starts with a dash.
            if (index + 1 < argv.len) {
                if (std.fmt.parseInt(u32, argv[index + 1], 0) catch null) |nth| {
                    if (nth == 0) return error.BadValue;
                    options.break_arrival = nth;
                    index += 1;
                }
            }
        } else if (std.mem.eql(u8, argv[index], "--ms")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            options.ms = try std.fmt.parseInt(u64, argv[index], 10);
        } else if (std.mem.eql(u8, argv[index], "--part") or
            std.mem.eql(u8, argv[index], "--device"))
        {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            options.part = part.Part.parse(argv[index]) orelse return error.UnknownPart;
        } else if (std.mem.eql(u8, argv[index], "--dump-mem")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            options.dump_mem = argv[index];
            // The count is optional, taken the same way `--break-sym`
            // takes its arrival: only when the next argument is a number.
            if (index + 1 < argv.len) {
                if (std.fmt.parseInt(u32, argv[index + 1], 0) catch null) |count| {
                    if (count == 0) return error.BadValue;
                    options.dump_mem_words = count;
                    index += 1;
                }
            }
        } else return error.UnknownFlag;
    }
    return options;
}

/// The flags that describe the world the board comes up in: the card on the
/// SPI line, the panel, the gauge. They read the same way the rest do and
/// are only kept apart so neither reader sprawls.
///
/// Returns whether the argument was one of them. False leaves the index
/// where it found it, so the caller can carry on looking.
/// The flags that inspect a run rather than shape the board: which image
/// the second core runs, what to watch, what to print at the end.
///
/// Split out of `parse` for the same reason `parseWorld` was: one chain of
/// else-ifs per concern keeps each function inside the length gate, and
/// these five have nothing to say to the timing and memory flags above.
/// Returns true when the flag was one of these and `index` has been walked
/// past any value it took.
fn parseDebug(options: *Options, argv: []const []const u8, index: *usize) !bool {
    const flag = argv[index.*];
    if (std.mem.eql(u8, flag, "--cpu1")) {
        options.cpu1_path = try next(argv, index);
    } else if (std.mem.eql(u8, flag, "--ns")) {
        options.ns_path = try next(argv, index);
    } else if (std.mem.eql(u8, flag, "--watch")) {
        options.watch_place = try next(argv, index);
    } else if (std.mem.eql(u8, flag, "--trace-rtos")) {
        options.trace_rtos = true;
    } else if (std.mem.eql(u8, flag, "--cpu-load")) {
        options.cpu_load = true;
    } else if (std.mem.eql(u8, flag, "--cpu-load-from")) {
        options.cpu_load = true;
        options.cpu_load_window.from = try std.fmt.parseInt(u64, try next(argv, index), 0);
    } else if (std.mem.eql(u8, flag, "--cpu-load-to")) {
        options.cpu_load = true;
        options.cpu_load_window.to = try std.fmt.parseInt(u64, try next(argv, index), 0);
    } else if (std.mem.eql(u8, flag, "--taken-in")) {
        options.taken_in_place = try next(argv, index);
    } else if (std.mem.eql(u8, flag, "--count-pc")) {
        const at = try std.fmt.parseInt(u32, try next(argv, index), 0);
        if (options.count_pc_len >= options.count_pc.len) return error.BadValue;
        options.count_pc[options.count_pc_len] = at;
        options.count_pc_len += 1;
    } else if (std.mem.eql(u8, flag, "--chunk")) {
        const width = try std.fmt.parseInt(u32, try next(argv, index), 0);
        if (width == 0) return error.BadValue;
        options.chunk_instructions = width;
    } else if (std.mem.eql(u8, flag, "--cpu")) {
        options.cpu = cpu_choice.Choice.parse(try next(argv, index)) orelse return error.BadValue;
    } else if (std.mem.eql(u8, flag, "--drain-pends")) {
        options.drain_pends = true;
    } else if (std.mem.eql(u8, flag, "--look-per-rise")) {
        options.look_per_rise = true;
    } else if (std.mem.eql(u8, flag, "--pace-masked")) {
        options.pace_masked = true;
    } else if (std.mem.eql(u8, flag, "--dump-regs")) {
        options.dump_regs = true;
    } else if (std.mem.eql(u8, flag, "--stop-on-undefined")) {
        options.stop_on_undefined = true;
    } else return false;
    return true;
}

fn parseWorld(options: *Options, argv: []const []const u8, index: *usize) !bool {
    const flag = argv[index.*];
    if (std.mem.eql(u8, flag, "--console")) {
        options.console = true;
    } else if (std.mem.eql(u8, flag, "--trace-sd")) {
        options.trace_sd = true;
    } else if (std.mem.eql(u8, flag, "--charge")) {
        options.battery.charging = true;
    } else if (std.mem.eql(u8, flag, "--click")) {
        options.click = true;
    } else if (std.mem.eql(u8, flag, "--bus-errors")) {
        options.bus_errors = true;
    } else if (std.mem.eql(u8, flag, "--no-bus-errors")) {
        options.bus_errors = false;
    } else if (std.mem.eql(u8, flag, "--sd-size")) {
        options.sd_size_mb = try std.fmt.parseInt(u32, try next(argv, index), 10);
    } else if (std.mem.eql(u8, flag, "--sd")) {
        options.sd_path = try next(argv, index);
    } else if (std.mem.eql(u8, flag, "--dump-sd")) {
        options.dump_sd = try std.fmt.parseInt(u32, try next(argv, index), 0);
    } else if (std.mem.eql(u8, flag, "--usb-loop")) {
        options.usb_loop = true;
    } else if (std.mem.eql(u8, flag, "--usb-disk")) {
        options.usb_disk = try next(argv, index);
    } else if (std.mem.eql(u8, flag, "--battery")) {
        options.battery.soc_pct = try std.fmt.parseInt(u8, try next(argv, index), 10);
    } else if (std.mem.eql(u8, flag, "--sd-new")) {
        const spec = try next(argv, index);
        const split = std.mem.indexOfScalar(u8, spec, ':') orelse spec.len;
        options.sd_new = sd_format.Kind.parse(spec[0..split]) orelse return error.UnknownFormat;
        if (split < spec.len) options.sd_label = spec[split + 1 ..];
    } else if (std.mem.eql(u8, flag, "--touch")) {
        const spec = try next(argv, index);
        if (options.touch_count >= options.touches.len) return error.TooManyTouches;
        options.touches[options.touch_count] = try touch_spec.parse(spec);
        options.touch_count += 1;
    } else return false;
    return true;
}

/// The argument after the flag, or a refusal when the flag was last.
fn next(argv: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= argv.len) return error.MissingValue;
    return argv[index.*];
}
