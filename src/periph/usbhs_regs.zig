//! The USBHS controller's window: where it answers, and the names of the
//! registers and bits inside it.
//!
//! One place for the vocabulary, so the power machine, the pipe table, the
//! block and the tests all name the same thing. Offsets are the HUM Ch 37
//! register file, the same transcription the firmware's own driver uses.

/// Where the controller sits and how much of it this tree models.
pub const window = struct {
    pub const base: u32 = 0x4035_1000;
    /// The modelled span reaches past the device page to the PHY page
    /// (LPSTS at 0x102), which the bring-up writes.
    pub const span: u32 = 0x200;
    /// Every register in the window is 16 bits wide.
    pub const word: u32 = 2;
    pub const words: u32 = span / word;
};

/// Register offsets from the window base.
pub const reg = struct {
    pub const syscfg: u32 = 0x000;
    pub const buswait: u32 = 0x002;
    pub const syssts0: u32 = 0x004;
    pub const dvstctr0: u32 = 0x008;
    pub const cfifo: u32 = 0x014;
    pub const cfifosel: u32 = 0x020;
    pub const cfifoctr: u32 = 0x022;
    pub const intenb0: u32 = 0x030;
    pub const intenb1: u32 = 0x032;
    pub const intsts0: u32 = 0x040;
    pub const intsts1: u32 = 0x042;
    pub const brdysts: u32 = 0x046;
    pub const nrdysts: u32 = 0x048;
    pub const bempsts: u32 = 0x04A;
    pub const frmnum: u32 = 0x04C;
    pub const usbaddr: u32 = 0x050;
    pub const usbreq: u32 = 0x054;
    pub const usbval: u32 = 0x056;
    pub const usbindx: u32 = 0x058;
    pub const usbleng: u32 = 0x05A;
    pub const dcpcfg: u32 = 0x05C;
    pub const dcpmaxp: u32 = 0x05E;
    pub const dcpctr: u32 = 0x060;
    pub const pipesel: u32 = 0x064;
    pub const pipecfg: u32 = 0x068;
    pub const pipebuf: u32 = 0x06A;
    pub const pipemaxp: u32 = 0x06C;
    pub const pipeperi: u32 = 0x06E;
    pub const pipectr: u32 = 0x070;
    /// PIPECTR is an array of nine, PIPE1 through PIPE9.
    pub const pipectr_count: u32 = 9;
    pub const pllsta: u32 = 0x13E;
    /// The PHY page past the device model's span; per-window state.
    pub const phy_page: u32 = 0x100;
};

/// SYSCFG: who this controller is and whether it is on at all.
pub const syscfg = struct {
    pub const usbe: u16 = 1 << 0;
    pub const dprpu: u16 = 1 << 4;
    pub const dcfm: u16 = 1 << 6;
    pub const scke: u16 = 1 << 10;
};

/// SYSSTS0 line state, and the DVSTCTR0 port control the host drives.
pub const port = struct {
    /// SYSSTS0.LNST J-state: something is attached and idle.
    pub const lnst_j: u16 = 0x0001;
    pub const lnst_mask: u16 = 0x0003;
    /// DVSTCTR0.RHST, the speed the reset settled on.
    pub const rhst_mask: u16 = 0x0007;
    pub const rhst_full: u16 = 0x0002;
    pub const rhst_high: u16 = 0x0003;
    pub const usbrst: u16 = 1 << 6;
    pub const uact: u16 = 1 << 8;
};

/// PLLSTA: the PHY PLL's lock flag, which the bring-up spins on.
pub const pllsta = struct {
    pub const plllock: u16 = 0x0001;
};

/// The pipe table's shape and the fields the host programs into it.
pub const pipe = struct {
    /// DCP is pipe 0; PIPE1..PIPE9 follow.
    pub const count: u32 = 10;
    pub const epnum_mask: u16 = 0x000F;
    pub const dir_in: u16 = 1 << 4;
    pub const maxp_mask: u16 = 0x07FF;
    /// The largest packet a high-speed bulk endpoint can carry.
    pub const maxp_limit: u16 = 512;
    pub const pid_mask: u16 = 0x0003;
    pub const pid_nak: u16 = 0;
    pub const pid_buf: u16 = 1;
    pub const pid_stall: u16 = 2;
};

/// CFIFOSEL / CFIFOCTR: which pipe the control FIFO port is aimed at.
pub const fifo = struct {
    pub const curpipe_mask: u16 = 0x000F;
    pub const isel: u16 = 1 << 5;
    pub const bclr: u16 = 1 << 6;
    pub const bval: u16 = 1 << 15;
    pub const frdy: u16 = 1 << 13;
    pub const dtln_mask: u16 = 0x0FFF;
};

/// DCPCTR: the control pipe's own control register, and the two edges the
/// host drives a control transfer with.
pub const dcpctr = struct {
    pub const pid_mask: u16 = 0x0003;
    pub const ccpl: u16 = 1 << 2;
    pub const sureq: u16 = 1 << 6;
    pub const bsts: u16 = 1 << 15;
};

/// INTSTS1 bits the SIE raises on a control transfer.
pub const int1 = struct {
    pub const sack: u16 = 1 << 4;
    pub const sign: u16 = 1 << 5;
};

/// BRDYSTS / NRDYSTS / BEMPSTS are one bit per pipe; bit 0 is the DCP.
pub const status = struct {
    pub const dcp: u16 = 1 << 0;
};

/// SETUP packet vocabulary: the wire fields and the direction bit.
pub const setup = struct {
    pub const len: u32 = 8;
    /// bmRequestType device-to-host (USB 2.0 section 9.3).
    pub const dir_in: u8 = 0x80;
};

/// How much this model stages on either side of the FIFO port.
pub const staging = struct {
    /// The largest packet a pipe carries, so the staging matches the wire.
    pub const packet_cap: u32 = 512;
    /// A control-read answer is a descriptor, not a payload.
    pub const reply_cap: u32 = 64;
};

/// True when the offset names a PIPECTR array slot.
pub fn isPipeCtr(offset: u32) bool {
    return offset >= reg.pipectr and
        offset < reg.pipectr + reg.pipectr_count * window.word;
}

/// Which pipe a PIPECTR offset names. PIPECTR[0] is PIPE1, so the index is
/// one higher than the slot.
pub fn pipeCtrIndex(offset: u32) u32 {
    return (offset - reg.pipectr) / window.word + 1;
}
