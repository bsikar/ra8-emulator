//! IsCPEnabled() for the FPU and MVE (RA8EMU-145), as the Arm ARM (DDI0553)
//! pseudocode for CheckCPEnabled() decides it: CP10 governs both, and CP11
//! must be programmed to match it, so only CP10 is read.
//!
//! A Non-secure access is refused first when NSACR.CP10 is clear, and that
//! refusal is taken to Secure. Otherwise the CPACR of the current Security
//! state grants the access by privilege. The reserved CPACR encoding 0b10
//! is UNPREDICTABLE; it is taken as no access, as QEMU takes it. CPPWR is
//! not modelled.
//!
//! This is the pure decision. Raising UsageFault.NOCP from it, through
//! src/core/cpu/exception/fault.zig, is the wiring half of RA8EMU-145.

/// The coprocessor number of the FPU and MVE.
pub const cp: u5 = 10;

/// CPACR.CP10, the access a coprocessor field grants.
pub const Access = enum(u2) {
    none = 0b00,
    privileged = 0b01,
    reserved = 0b10,
    full = 0b11,
};

/// The CP10 field of a CPACR value.
pub fn access(cpacr: u32) Access {
    return @fromBackingInt(@intCast(@as(u2, @truncate(cpacr >> (cp * 2)))));
}

/// What the check needs: the CPACR of the current Security state, NSACR,
/// and the state the instruction runs in.
pub const Request = struct {
    cpacr: u32,
    nsacr: u32 = 0,
    privileged: bool,
    secure: bool = true,
};

/// Whether the access runs and, when it does not, whether the NOCP fault
/// is taken to Secure.
pub const Verdict = struct {
    enabled: bool,
    to_secure: bool = false,
};

pub const allowed: Verdict = .{ .enabled = true };
pub const refused: Verdict = .{ .enabled = false };

/// IsCPEnabled(10, privileged, secure).
pub fn check(req: Request) Verdict {
    if (!req.secure and req.nsacr & (@as(u32, 1) << cp) == 0)
        return .{ .enabled = false, .to_secure = true };
    return switch (access(req.cpacr)) {
        .full => allowed,
        .privileged => if (req.privileged) allowed else refused,
        .none, .reserved => refused,
    };
}

/// The CPACR value that gives CP10 and CP11 full access, as SystemInit
/// writes it.
pub const full_access: u32 = 0x00F0_0000;
