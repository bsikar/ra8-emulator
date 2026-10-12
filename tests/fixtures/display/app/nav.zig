//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! The screen stack. Screens push when the user goes deeper, pop on back,
//! and collapse to a single root when the user picks a tab or goes home.

const screen = @import("screen.zig");

pub const limits = struct {
    pub const depth: usize = 12;
};

pub const Stack = struct {
    items: [limits.depth]screen.Id = undefined,
    len: usize = 0,

    pub fn init(first: screen.Id) Stack {
        var stack: Stack = .{};
        stack.items[0] = first;
        stack.len = 1;
        return stack;
    }

    /// The screen on show.
    pub fn top(self: *const Stack) screen.Id {
        return self.items[self.len - 1];
    }

    /// Go one level deeper. At the depth limit the top screen is replaced,
    /// so a long chain of pushes can never strand the user.
    pub fn push(self: *Stack, id: screen.Id) void {
        if (self.top() == id) return;
        if (self.len == limits.depth) self.len -= 1;
        self.items[self.len] = id;
        self.len += 1;
    }

    /// Leave the top screen. The root stays: true when a screen was left.
    pub fn pop(self: *Stack) bool {
        if (self.len == 1) return false;
        self.len -= 1;
        return true;
    }

    /// Back: pop, or fall back to `home` when already at a root.
    pub fn back(self: *Stack, home: screen.Id) void {
        if (!self.pop()) self.root(home);
    }

    /// Collapse the stack to one screen: a tab switch or the home link.
    pub fn root(self: *Stack, id: screen.Id) void {
        self.items[0] = id;
        self.len = 1;
    }

    /// Keep everything up to and including the first `base`, then show `id`
    /// on top of it: how a tab inside an app replaces its sibling.
    pub fn within(self: *Stack, base: screen.Id, id: screen.Id) void {
        self.root(base);
        self.push(id);
    }
};
