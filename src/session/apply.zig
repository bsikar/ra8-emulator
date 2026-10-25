//! Applying a host intervention to the machine, and the checks a fork runs
//! before it commits to one (time-travel design section 11).
//!
//! applyAction is the one place an intervention mutates the machine: the
//! live path, a fork and a replay all come through it. preflight answers
//! the failures an action can be refused with before any of it happens,
//! so a fork that would only fail at the action refuses before the line,
//! the log or branches.bin change.
const api = @import("api.zig");
const fork_router_mod = @import("history/fork_router.zig");
const elf = @import("ra8_board").image.elf;
const symbols = @import("symbols.zig");
const widget_tree = @import("widget_tree.zig");

const Session = api.Session;
pub const Action = fork_router_mod.Action;

/// Dispatches an action onto the machine without routing checks.
pub fn applyAction(self: *Session, action: Action) anyerror!void {
    switch (action) {
        .register => |reg| {
            try (try self.view(reg.core)).setRegister(reg.which, reg.value);
            self.dirty();
            self.publish(.{ .core = reg.core, .kind = .register_written });
        },
        .memory => |mem| {
            try (try self.view(mem.core)).write(mem.address, mem.bytes);
            self.dirty();
            self.publish(.{ .core = mem.core, .kind = .memory_written, .address = mem.address });
        },
        .input => |inp| {
            try self.select(inp.core);
            const script = self.input_script orelse return api.Error.NoInput;
            try script.schedule(.{ .at_ns = inp.at_ns, .event = inp.event });
            self.publish(.{ .core = inp.core, .kind = .input_scheduled });
        },
        .console => |con| {
            try self.select(con.core);
            if (self.console_hook) |hook| try hook.feedFn(hook.context, con.bytes);
            self.publish(.{ .core = con.core, .kind = .console_input });
        },
        .plug => |p| {
            const hook = self.plugs orelse return api.Error.NoPlugs;
            try hook.plugFn(hook.context, p.at, p.name);
            self.publish(.{ .core = p.core, .kind = if (p.name != null) .plugged else .unplugged });
        },
        .fault => |f| {
            const faults = self.faults orelse return api.Error.NoFaults;
            try faults.set(f.at, f.mode);
            self.publish(.{ .core = f.core, .kind = if (f.mode != null) .fault_set else .fault_cleared });
        },
        .camera => |cam| {
            try self.select(cam.core);
            if (self.camera_hook) |hook| try hook.changeFn(hook.context, cam.spec);
            self.publish(.{ .core = cam.core, .kind = .camera_changed });
        },
        .skip_bkpt => |sk| {
            try self.select(sk.core);
            const view = try self.view(sk.core);
            const pc = try view.register(.pc);
            try view.setRegister(.pc, pc + 2);
            self.dirty();
            self.publish(.{ .core = sk.core, .kind = .bkpt_skipped, .address = pc });
        },
        .load => |ld| {
            try self.select(ld.core);
            const loader = self.loader orelse return api.Error.NoLoader;
            try loader.loadFn(loader.context, ld.core, ld.image);
            self.dirty();
            const tree_address = if (elf.Image.init(ld.image)) |parsed| symbols.addressOf(parsed, widget_tree.symbol) else |_| null;
            self.widget_tree_addresses[@backingInt(ld.core)] = tree_address;
            self.publish(.{ .core = ld.core, .kind = .loaded });
        },
    }
}

/// Refuses an action the machine would refuse, without applying it: the
/// core is attached, the hook the action needs is bound, a memory write's
/// span answers a read, and a load has a loader. A fork runs this first, so
/// the common refusals never reach a half-made branch.
pub fn preflight(self: *Session, action: Action) anyerror!void {
    switch (action) {
        .register => |reg| _ = try (try self.view(reg.core)).register(reg.which),
        .memory => |mem| {
            const view = try self.view(mem.core);
            var probe: [64]u8 = undefined;
            var at: usize = 0;
            while (at < mem.bytes.len) {
                const n = @min(probe.len, mem.bytes.len - at);
                try view.read(mem.address + @as(u32, @intCast(at)), probe[0..n]);
                at += n;
            }
        },
        .input => |inp| {
            try attached(self, inp.core);
            if (self.input_script == null) return api.Error.NoInput;
        },
        .console => |con| try attached(self, con.core),
        .plug => if (self.plugs == null) return api.Error.NoPlugs,
        .fault => if (self.faults == null) return api.Error.NoFaults,
        .camera => |cam| try attached(self, cam.core),
        .skip_bkpt => |sk| _ = try (try self.view(sk.core)).register(.pc),
        .load => |ld| {
            try attached(self, ld.core);
            if (self.loader == null) return api.Error.NoLoader;
        },
    }
}

fn attached(self: *const Session, core: api.Core) api.Error!void {
    if (!self.hasCore(core)) return api.Error.CoreNotAttached;
}
