//! The cluster's two shared agents: GWCA, the CPU-side gateway, and COMA, the
//! common block that owns the frame buffer pool.
//!
//! Both are mostly one handshake each. The firmware asks for an
//! initialisation and polls for the answer, so the answer has to come: GWCA's
//! AXI init through GWARIRM, COMA's buffer-pool init through CABPIRM. dev
//! answered both as soon as the request bit was seen, which is faithful, and
//! that part is kept. What dev did not do is hold the gateway to its mode
//! machine, so that is where this file differs.
const std = @import("std");
const periph = @import("registry.zig");
const regs = @import("eth_regs.zig");
const eth_mode = @import("eth_mode.zig");

/// GWCA: the mode pair and the AXI-init handshake, two windows apart.
pub const Gateway = struct {
    base: u32 = regs.cluster.gwca0,
    mode: eth_mode.Machine = .{},
    /// AXI initialisations asked for through GWARIRM.ARIOG.
    inits: u32 = 0,
    arirm: u32 = 0,

    pub fn modeRead(self: *Gateway, address: u32, width: u3) u32 {
        _ = width;
        return switch (address -% self.base) {
            regs.gwca.gwmc => self.mode.status(),
            regs.gwca.gwms => self.mode.status(),
            else => 0,
        };
    }

    pub fn modeWrite(self: *Gateway, address: u32, width: u3, value: u32) void {
        _ = width;
        if (address -% self.base != regs.gwca.gwmc) return;
        self.mode.command(value & regs.gwca.opc_mask);
    }

    /// ARR follows ARIOG: the init the firmware asked for has finished by the
    /// time it reads back.
    pub fn arirmRead(self: *Gateway, address: u32, width: u3) u32 {
        _ = address;
        _ = width;
        if (self.arirm & regs.gwca.ariog == 0) return self.arirm;
        return self.arirm | regs.gwca.arr;
    }

    pub fn arirmWrite(self: *Gateway, address: u32, width: u3, value: u32) void {
        _ = address;
        _ = width;
        if (value & regs.gwca.ariog != 0 and self.arirm & regs.gwca.ariog == 0) self.inits += 1;
        self.arirm = value;
    }

    pub fn quiet(self: *const Gateway) bool {
        return self.mode.quiet() and self.inits == 0;
    }

    pub fn modeBlock(self: *Gateway) periph.Block {
        return .{
            .name = "GWCA",
            .base = self.base,
            .size = regs.gwca.mode_span,
            .context = self,
            .readFn = modeReadThunk,
            .writeFn = modeWriteThunk,
        };
    }

    pub fn arirmBlock(self: *Gateway) periph.Block {
        return .{
            .name = "GWARIRM",
            .base = self.base + regs.gwca.gwarirm,
            .size = regs.gwca.arirm_span,
            .context = self,
            .readFn = arirmReadThunk,
            .writeFn = arirmWriteThunk,
        };
    }
};

/// COMA: the buffer-pool init handshake, and nothing else yet.
pub const Pool = struct {
    base: u32 = regs.cluster.coma,
    /// Pool initialisations asked for through CABPIRM.BPIOG.
    inits: u32 = 0,
    cabpirm: u32 = 0,

    pub fn read(self: *Pool, address: u32, width: u3) u32 {
        _ = address;
        _ = width;
        if (self.cabpirm & regs.coma.bpiog == 0) return self.cabpirm;
        return self.cabpirm | regs.coma.bpr;
    }

    pub fn write(self: *Pool, address: u32, width: u3, value: u32) void {
        _ = address;
        _ = width;
        if (value & regs.coma.bpiog != 0 and self.cabpirm & regs.coma.bpiog == 0) self.inits += 1;
        self.cabpirm = value;
    }

    pub fn quiet(self: *const Pool) bool {
        return self.inits == 0;
    }

    pub fn block(self: *Pool) periph.Block {
        return .{
            .name = "COMA",
            .base = self.base + regs.coma.cabpirm,
            .size = regs.coma.cabpirm_span,
            .context = self,
            .readFn = poolReadThunk,
            .writeFn = poolWriteThunk,
        };
    }
};

fn modeReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Gateway = @ptrCast(@alignCast(context));
    return self.modeRead(address, width);
}

fn modeWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Gateway = @ptrCast(@alignCast(context));
    self.modeWrite(address, width, value);
}

fn arirmReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Gateway = @ptrCast(@alignCast(context));
    return self.arirmRead(address, width);
}

fn arirmWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Gateway = @ptrCast(@alignCast(context));
    self.arirmWrite(address, width, value);
}

fn poolReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Pool = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn poolWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Pool = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
