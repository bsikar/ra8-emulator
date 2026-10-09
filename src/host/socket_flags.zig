//! The no-SIGPIPE send flag the host's network code needs.
//!
//! std.posix.MSG has no NOSIGNAL on Darwin or Windows. Darwin's
//! <sys/socket.h> gives MSG_NOSIGNAL 0x80000; Windows has no SIGPIPE, so the
//! flag is 0 there. Every other recv and send flag comes from std.posix.MSG.
const std = @import("std");
const builtin = @import("builtin");

/// Suppress SIGPIPE when sending to a closed peer.
pub const nosignal: u32 = if (builtin.os.tag.isDarwin()) 0x80000 else if (@hasDecl(std.posix.MSG, "NOSIGNAL")) std.posix.MSG.NOSIGNAL else 0;
