//! Where the CEU's captured pixels come from (RA8EMU-505).
//!
//! The CEU used to paint one fixed gradient. A source behind this interface
//! can be swapped in instead: a still image, a video paced to emulated time,
//! a raw pipe, a host webcam. The CEU asks for one frame per armed capture,
//! at the emulated time of the arm, then pulls each destination line out of
//! it in chunks. A source answers in the bytes the firmware's buffer gets,
//! already in the format and size the firmware programmed, so the CEU never
//! knows which source it has.

/// The frame the CEU is about to write: bytes per line and how many lines.
pub const Shape = struct {
    width: u32,
    lines: u32,
};

pub const FrameSource = struct {
    context: *anyopaque,
    vtable: *const VTable,
    /// What the end-of-run report calls this source (RA8EMU-538).
    label: []const u8 = "synthetic gradient",
    /// The argument it was opened with, such as an image path; "" for none.
    detail: []const u8 = "",

    pub const VTable = struct {
        /// Ready the frame for one capture armed at `when` (emulated ns).
        frame: *const fn (context: *anyopaque, when: u64, shape: Shape) void,
        /// Fill `out` with line `row`'s bytes starting at byte `column`.
        fill: *const fn (context: *anyopaque, row: u32, column: u32, out: []u8) void,
        /// Let go of whatever the source holds open.
        close: *const fn (context: *anyopaque) void,
    };

    pub fn frame(self: FrameSource, when: u64, shape: Shape) void {
        self.vtable.frame(self.context, when, shape);
    }

    pub fn fill(self: FrameSource, row: u32, column: u32, out: []u8) void {
        self.vtable.fill(self.context, row, column, out);
    }

    pub fn close(self: FrameSource) void {
        self.vtable.close(self.context);
    }
};
