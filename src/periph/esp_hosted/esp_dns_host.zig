//! Asynchronous host DNS resolution for the C6 station bridge.
const std = @import("std");
const dns = @import("esp_dns.zig");
const eth = @import("esp_eth.zig");
const frame = @import("esp_frame.zig");
const Queue = @import("esp_queue.zig").Queue;

const State = enum(u8) { running, ready };

const Job = struct {
    refs: std.atomic.Value(u8) = .init(2),
    state: std.atomic.Value(State) = .init(.running),
    canceled: std.atomic.Value(bool) = .init(false),
    valid: bool = false,
    resolver: dns.Resolver,
    route: eth.Route,
    request: [eth.udp_payload_max]u8 = undefined,
    request_len: usize,
    response: [frame.frame_size]u8 = undefined,

    fn release(self: *Job) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) std.heap.page_allocator.destroy(self);
    }
};

pub const Host = struct {
    job: ?*Job = null,
    thread: ?std.Thread = null,

    pub fn start(self: *Host, request: []const u8, route: eth.Route, resolver: dns.Resolver) void {
        if (self.job != null or request.len > eth.udp_payload_max) return;
        const job = std.heap.page_allocator.create(Job) catch return;
        job.* = .{ .resolver = resolver, .route = route, .request_len = request.len };
        @memcpy(job.request[0..request.len], request);
        const thread = std.Thread.spawn(.{}, run, .{job}) catch {
            std.heap.page_allocator.destroy(job);
            return;
        };
        self.job = job;
        self.thread = thread;
    }

    pub fn poll(self: *Host, queue: *Queue, limit: usize) void {
        const job = self.job orelse return;
        if (job.state.load(.acquire) != .ready) return;
        if (job.valid and queue.len >= limit) return;
        self.thread.?.join();
        self.thread = null;
        self.job = null;
        if (job.valid) _ = queue.push(&job.response);
        job.release();
    }

    pub fn deinit(self: *Host) void {
        const job = self.job orelse return;
        job.canceled.store(true, .release);
        self.thread.?.detach();
        self.thread = null;
        self.job = null;
        job.release();
    }

    fn run(job: *Job) void {
        defer job.release();
        var payload: [eth.udp_payload_max]u8 = undefined;
        const payload_len = dns.answer(&payload, job.request[0..job.request_len], job.resolver);
        var hosted: [frame.frame_size]u8 = undefined;
        var valid = false;
        if (payload_len) |len| {
            var ethernet: [frame.max_payload]u8 = undefined;
            if (eth.udpFrame(&ethernet, job.route, payload[0..len])) |ethernet_len| {
                valid = true;
                frame.build(&hosted, .{ .interface = .sta, .if_num = 0 }, ethernet[0..ethernet_len]) catch {
                    valid = false;
                };
            }
        }
        if (!job.canceled.load(.acquire)) {
            if (valid) job.response = hosted;
            job.valid = valid;
        }
        job.state.store(.ready, .release);
    }
};
