//! Socket flags needed by the host's network interfaces.
//!
//! Zig 0.14.1's std.c.MSG has no Darwin arm, so std.posix.MSG is void on
//! macOS. Darwin's <sys/socket.h> gives MSG_PEEK 0x2 and MSG_DONTWAIT 0x80.
//! Delete this file with the Zig upgrade (RA8EMU-628), which maps darwin.MSG.
const std = @import("std");
const builtin = @import("builtin");

const darwin = builtin.os.tag.isDarwin();

/// Read without taking the bytes off the socket.
pub const peek: u32 = if (darwin) 0x2 else std.posix.MSG.PEEK;

/// Return error.WouldBlock instead of waiting.
pub const dontwait: u32 = if (darwin) 0x80 else std.posix.MSG.DONTWAIT;

/// Report the original datagram size when the receive buffer is too small.
pub const trunc: u32 = if (darwin) 0x10 else std.posix.MSG.TRUNC;

/// Suppress SIGPIPE when sending to a closed peer. Windows has no SIGPIPE
/// and ws2_32 defines no MSG_NOSIGNAL, so the flag is 0 there.
pub const nosignal: u32 = if (darwin) 0x80000 else if (@hasDecl(std.posix.MSG, "NOSIGNAL")) std.posix.MSG.NOSIGNAL else 0;
