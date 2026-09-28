//! CPU_CTRL: the registers CPU0 uses to take the second core out of reset.
//!
//! Three registers on the CPU_CTRL page (ra8_dual_core.h,
//! k_ra8_dual_core_ctrl_base_addr 0x4000_F000 Secure, HUM Ch 2.9.1 p 128-130):
//!
//!   CPU1INITVTOR (+0x044, 32-bit)  CPU1's initial vector-table base
//!   CPU1WAITCR   (+0x054,  8-bit)  bit 0 CPUWAIT, stall the core
//!   CPU1ACTCSR   (+0x064, 16-bit)  bit 0 ACTREQ (W), bit 7 ACT (R),
//!                                  bits 15:8 the 0xA5 key
//!
//! ACTCSR IS A KEYED COMMAND, NOT A WORD, and that is the whole gap. The key
//! belongs to the WRITE and not to the register: ra8_dual_core.h says writes
//! "require KEY=0xA5 in bits 15:8 alongside the ACTREQ bit. Anything else is
//! silently dropped by the hardware." ACTREQ is a request, and ACT is the
//! answer the hardware gives back: the driver writes one and polls the other.
//! internal_wait_act_set in ra8_dual_core.c is the contract in four lines,
//! reading ACTCSR up to k_ra8_dual_core_release_poll_max (1000000) times and
//! returning a hardware timeout if ACT never comes up.
//!
//! WHAT THIS CLOSES. Nothing modelled this page, so it fell to the sparse
//! register file, which answers a written address with the word that was
//! written. ACTCSR therefore read back 0xA501, whose bit 7 is clear, so ACT
//! was never seen, the poll spent all one million iterations, and
//! ra8_cpu1_release returned k_ra8_err_hw_timeout. cache_coherency_hil's main
//! calls internal_park_forever() on exactly that failure, so the app parked
//! in a two-instruction loop at 0x0200026C before it ran a single round and
//! g_cache_coherency_match stayed at zero for the whole budget. The run
//! reported nothing worse than a million peripheral reads.
//!
//! Now the key gates the store and is not kept, the same cut MRMS's frequency
//! latches and MRAM's MENTRYR already make: a store carrying 0xA5 lands, a
//! store carrying anything else is dropped and counted, and a landed store
//! that asserts ACTREQ raises ACT. The readback carries ACTREQ and ACT and
//! never the key, which is what lets the driver's poll succeed on its first
//! read.
//!
//! NOT MODELLED, AND NOT GUESSED: THIS MODEL RUNS ONE CORE. ACT going up
//! means the release handshake completed, never that a second core is
//! fetching. Nothing executes from CPU1INITVTOR, no instruction retires on
//! the M33, and so an app that waits for the other core to answer still
//! waits. The report says which of the two happened rather than letting
//! "CPU1 active" stand for "CPU1 ran". There is no documented path back from
//! ACT once it is set, and the driver says so too, so ACT is sticky here and
//! only CPUWAIT stalls the core; nothing else on the 0x4000_F000 page is
//! claimed.
const periph = @import("registry.zig");

/// Window geometry: the CPU_CTRL Secure base and the three registers used to
/// release CPU1. The span reaches the end of ACTCSR and no further.
pub const win_base: u32 = 0x4000_F000;
pub const win_span: u32 = 0x66;

/// Register offsets from `win_base` (ra8_dual_core_off_t).
pub const regs = struct {
    pub const initvtor: u32 = 0x044;
    pub const waitcr: u32 = 0x054;
    pub const actcsr: u32 = 0x064;
};

/// The key ACTCSR demands, already in place in its byte, and the byte it
/// occupies. Everything below it is the request.
pub const key = struct {
    pub const value: u32 = 0xA5 << 8;
    pub const mask: u32 = 0xFF00;
};

/// The bits the two control registers carry (ra8_dual_core_bit_t).
pub const bits = struct {
    pub const actreq: u32 = 1 << 0;
    pub const act: u32 = 1 << 7;
    pub const cpuwait: u32 = 1 << 0;
};

/// The release handshake, and what the run did with it.
pub const CpuCtrl = struct {
    /// CPU1INITVTOR, retained as written: the vector table CPU1 would latch.
    initvtor: u32 = 0,
    /// CPU1WAITCR, only CPUWAIT is a bit of this register.
    waitcr: u32 = 0,
    /// ACTCSR.ACTREQ, as last requested by a store that carried the key.
    actreq: bool = false,
    /// ACTCSR.ACT, raised by an accepted request and sticky thereafter.
    act: bool = false,
    /// Stores that carried the key and landed.
    accepted: u32 = 0,
    /// Stores dropped because the key byte was not 0xA5.
    refused: u32 = 0,

    /// An image that never reached for the second core has nothing to say.
    pub fn quiet(self: *const CpuCtrl) bool {
        return self.accepted == 0 and self.refused == 0 and self.initvtor == 0;
    }

    /// The truth table ra8_cpu1_is_running walks: activated, and not stalled.
    pub fn running(self: *const CpuCtrl) bool {
        if (!self.act) return false;
        return self.waitcr & bits.cpuwait == 0;
    }

    /// What a load of ACTCSR sees: the request and the active bit, never the
    /// key, because the key was part of the write.
    pub fn status(self: *const CpuCtrl) u32 {
        var value: u32 = 0;
        if (self.actreq) value |= bits.actreq;
        if (self.act) value |= bits.act;
        return value;
    }

    /// A store lands only with the right key. An accepted request raises ACT,
    /// which is how the driver's bounded poll ends.
    pub fn request(self: *CpuCtrl, value: u32) void {
        if (value & key.mask != key.value) {
            self.refused +%= 1;
            return;
        }
        self.accepted +%= 1;
        self.actreq = value & bits.actreq != 0;
        if (self.actreq) self.act = true;
    }

    pub fn read(self: *CpuCtrl, address: u32, width: u3) u32 {
        _ = width;
        return switch (address -% win_base) {
            regs.initvtor => self.initvtor,
            regs.waitcr => self.waitcr,
            regs.actcsr => self.status(),
            else => 0,
        };
    }

    pub fn write(self: *CpuCtrl, address: u32, width: u3, value: u32) void {
        _ = width;
        switch (address -% win_base) {
            regs.initvtor => self.initvtor = value,
            regs.waitcr => self.waitcr = value & bits.cpuwait,
            regs.actcsr => self.request(value),
            else => {},
        }
    }

    pub fn block(self: *CpuCtrl) periph.Block {
        return .{
            .name = "CPU_CTRL",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *CpuCtrl = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *CpuCtrl = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
