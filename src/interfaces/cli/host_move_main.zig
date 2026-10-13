//! Native peer executable over the existing named CLI application module.
const std = @import("std");
const app = @import("cli_app");
pub fn main(init: std.process.Init) !u8 {
    return app.host.relocation.peer(init);
}
