//! Rebind host services and debugger hooks onto each admitted session.
const api = @import("ra8_session").api;
const setup = @import("ra8_rpc").served_setup;
const txm = @import("ra8_session").txm.debug;
const Workbench = @import("workbench.zig").Workbench;

pub const Bindings = struct {
    workbench: *Workbench,
    folded: bool,
    allow_state: bool,

    pub fn prepare(context: ?*anyopaque, candidate: *setup.Served) anyerror!void {
        const self: *Bindings = @ptrCast(@alignCast(context orelse return error.NoBindings));
        self.workbench.bind(&candidate.context);
        debugger(candidate);
        try candidate.startWorker();
        if (self.folded) try candidate.sampleStacks(1000);
        if (!self.allow_state) candidate.context.state = null;
    }
};

pub fn debugger(source: *setup.Served) void {
    if (source.context.modules) |table| {
        table.armer = .{ .ctx = source.context.session, .arm = arm, .drop = drop };
    }
}

fn arm(context: *anyopaque, core: txm.Core, address: u32) anyerror!u32 {
    const session: *api.Session = @ptrCast(@alignCast(context));
    return session.setBreakpoint(core, .{ .address = address });
}

fn drop(context: *anyopaque, core: txm.Core, id: u32) anyerror!void {
    const session: *api.Session = @ptrCast(@alignCast(context));
    return session.clearBreakpoint(core, id);
}
