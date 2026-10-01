//! The decode table: every instruction group the Zig core knows, in the order
//! the decoder tries them.
//!
//! This is the one registration point. A group is a file under
//! src/core/cpu/ops/ holding a `pub const group: op.Group`, plus one line in
//! this list. Groups must not claim each other's encodings; the first one that
//! answers wins, so an overlap is a bug in the group, not an ordering choice.
const op = @import("../op.zig");

pub const groups = [_]op.Group{
    @import("hint.zig").group,
};
