//! Backend build execution primitives; no Session or frontend dependencies.
pub const process = @import("process.zig");
pub const pipe = @import("pipe.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const request = @import("request.zig");
pub const queue = @import("queue.zig");
pub const source = @import("source.zig");
pub const Runner = @import("runner.zig").Runner;
