//! Host-only lifecycle and byte storage capabilities. Applications own
//! these resources and inject callbacks into the embedding API.
pub const app_dirs = @import("../app_dirs.zig");
pub const base = @import("base.zig");
pub const branches_file = @import("branches_file.zig");
pub const gates = @import("gates.zig");
pub const budget = @import("budget.zig");
pub const resources = @import("resources.zig");
pub const runtime = @import("runtime.zig");
pub const catalog = @import("catalog.zig");
pub const sweep = @import("sweep.zig");
pub const prune = @import("prune.zig");
pub const storage = @import("storage.zig");
pub const readback = @import("readback.zig");
pub const layout = @import("layout.zig");
pub const name = @import("name.zig");
pub const move = @import("move/root.zig");
pub const lock = @import("lock.zig");
pub const lease = @import("lease.zig");
pub const machine = @import("machine.zig");
pub const owner = @import("owner.zig");
pub const metadata = @import("metadata.zig");
pub const paths = @import("paths.zig");
pub const recover = @import("recover.zig");
pub const remove = @import("remove.zig");
pub const rename = @import("rename.zig");
pub const scratch = @import("scratch.zig");
pub const session = @import("session.zig");
