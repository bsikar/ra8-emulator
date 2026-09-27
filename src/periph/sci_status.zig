//! CSR, FRSR and FTSR: the SCI_B status words a polled driver lives on, and
//! what a store to one does.
//!
//! Split out of src/periph/sci.zig, which owns the channel, the line capture
//! and the transmit gate. This file owns the three words the controller
//! writes and firmware only reads, and the two clear strobes that sit beside
//! them.
//!
//! THE BITS THE DRIVER WANTS ARE IN THE TOP BYTE. TDRE is bit 29, TEND bit
//! 30 and RDRF bit 31, so a driver polling the transmitter with a byte load
//! reads CSR+3, and one watching RXDMON (bit 15) reads the halfword at CSR+0.
//! Those are ordinary accesses on silicon, and this file exists partly so
//! the window answers them: sci.zig used to switch on the raw byte offset,
//! so a load at CSR+3 matched no register at all and fell through to zero.
//! A `while ((REG8(CSR + 3) & TDRE) == 0)` on that answer never leaves its
//! loop, and the run dies at the instruction budget with the console silent.
//!
//! A STORE TO ONE OF THEM IS REFUSED, NOT SWALLOWED. CSR, FRSR and FTSR are
//! status: the transmitter and the FIFOs set those bits, firmware does not.
//! sci.zig used to drop such a store on the floor with the same `else => {}`
//! that serves CFCLR and FFCLR, so a driver storing CSR to force a flag was
//! told nothing and the run reported nothing. It is refused and counted
//! here, the way this tree already treats MSTATR, MRCPS, SRAMESR and INTS.
//!
//! CFCLR AND FFCLR STAY ACCEPTED NO-OPS, and that is not the same thing.
//! They are write-1-to-clear strobes over flags this model derives rather
//! than latches: TDRE and TEND never go down, and RDRF follows the receive
//! queue, so clearing them changes nothing and refusing them would report a
//! driver doing exactly what the hardware manual asks of it.
//!
//! NOT MODELLED, AND NOT GUESSED: the error flags. ORER, FER and PER live in
//! CSR too, and nothing in this model can raise one: there is no baud clock
//! to frame against and no line to see noise on. They read clear, so a
//! driver's error path is never entered rather than entered on an invented
//! fault.

/// The offsets this file owns inside a channel's 0x100 window.
pub const off = struct {
    pub const csr: u32 = 0x48;
    pub const frsr: u32 = 0x50;
    pub const ftsr: u32 = 0x54;
    pub const cfclr: u32 = 0x68;
    pub const ffclr: u32 = 0x70;
};

/// CSR status bits (ra8_sci_csr_bit_t).
pub const csr = struct {
    pub const rxdmon: u32 = 0x0000_8000;
    pub const tdre: u32 = 0x2000_0000;
    pub const tend: u32 = 0x4000_0000;
    pub const rdrf: u32 = 0x8000_0000;
};

/// The bits a read of FRSR or FTSR reports.
pub const fifo = struct {
    pub const frsr_dr: u32 = 0x0000_0001;
    pub const frsr_rdf: u32 = 0x0000_0040;
    pub const ftsr_tdfe: u32 = 0x0000_0040;
};

/// CSR as firmware reads it. The transmitter is always drained in this model,
/// because there is no baud-rate clock in an instruction-stepped emulator, so
/// TDRE and TEND read set; RXDMON idles high the way an unloaded line does;
/// and RDRF is a fact about the receive queue rather than a value a driver
/// wrote.
pub fn common(readable: bool) u32 {
    const idle = csr.tdre | csr.tend | csr.rxdmon;
    return if (readable) idle | csr.rdrf else idle;
}

/// FRSR: the receive FIFO reports a byte waiting exactly when the queue has
/// one and the receiver is enabled to hear it.
pub fn receive(readable: bool) u32 {
    return if (readable) fifo.frsr_dr | fifo.frsr_rdf else 0;
}

/// FTSR: the transmit FIFO is always empty here, for the same reason TDRE is
/// always set.
pub const transmit: u32 = fifo.ftsr_tdfe;

/// Whether a word in the channel window is one the controller owns, so a
/// store to it is a refusal rather than a value.
pub fn readOnly(word: u32) bool {
    return word == off.csr or word == off.frsr or word == off.ftsr;
}

/// Whether a word is one of the write-1-to-clear strobes, which take a store
/// and do nothing with it.
pub fn clearStrobe(word: u32) bool {
    return word == off.cfclr or word == off.ffclr;
}
