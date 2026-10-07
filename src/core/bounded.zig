//! A list of at most `capacity` items kept inline (RA8EMU-843), the shape
//! std.BoundedArray had before Zig 0.17 removed it. It copies by value, so
//! a peripheral can hand back its due events without a pointer into a
//! buffer that moved with the copy.
const std = @import("std");

pub fn Bounded(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]T = undefined,
        len: usize = 0,

        pub fn slice(self: anytype) switch (@TypeOf(&self.buffer)) {
            *[capacity]T => []T,
            *const [capacity]T => []const T,
            else => unreachable,
        } {
            return self.buffer[0..self.len];
        }

        pub fn constSlice(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }

        pub fn get(self: Self, index: usize) T {
            return self.constSlice()[index];
        }

        pub fn set(self: *Self, index: usize, item: T) void {
            self.slice()[index] = item;
        }

        pub fn resize(self: *Self, len: usize) error{Overflow}!void {
            if (len > capacity) return error.Overflow;
            self.len = len;
        }

        pub fn append(self: *Self, item: T) error{Overflow}!void {
            if (self.len == capacity) return error.Overflow;
            self.appendAssumeCapacity(item);
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            std.debug.assert(self.len < capacity);
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn appendSlice(self: *Self, items: []const T) error{Overflow}!void {
            if (capacity - self.len < items.len) return error.Overflow;
            @memcpy(self.buffer[self.len..][0..items.len], items);
            self.len += items.len;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.buffer[self.len];
        }

        pub fn orderedRemove(self: *Self, index: usize) T {
            const item = self.buffer[index];
            std.mem.copyForwards(T, self.buffer[index .. self.len - 1], self.buffer[index + 1 .. self.len]);
            self.len -= 1;
            return item;
        }

        pub fn swapRemove(self: *Self, index: usize) T {
            const item = self.buffer[index];
            self.buffer[index] = self.buffer[self.len - 1];
            self.len -= 1;
            return item;
        }
    };
}
