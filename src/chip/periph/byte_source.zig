//! A host byte stream a model polls at board boundaries (ADR 0004).
//!
//! Models below the applications never open host handles. A model that
//! takes host input holds a ByteSource, and the application fills it from
//! the host library: `context` is one word the read function owns (a host
//! handle, say), and `readFn` hands back what is waiting without blocking.
pub const ByteSource = struct {
    context: usize,
    readFn: *const fn (context: usize, into: []u8) ?usize,

    /// Move what is waiting into `into`. Null means nothing is waiting and
    /// the caller asks again next boundary; 0 means end of input.
    pub fn read(self: ByteSource, into: []u8) ?usize {
        return self.readFn(self.context, into);
    }
};
