//! The local GUI's native session link (slice 15): the shell's typed
//! requests dispatch straight to the served handlers, and the feeds' events
//! land on a queue the shell takes one arrival at a time. Between the shell
//! and the session it owns in-process there is no RPC framing, no loopback
//! byte transport and no client/server handshake; the vocabulary stays the
//! protocol's typed messages, which are the handlers' own argument and
//! reply types. The machinery runs on the thread that owns the session; how
//! the shell's calls reach that thread is the wiring's concern, not this
//! file's. The run plane stays off this link: `run` and `advance` reply
//! only once their job ends, so those commands go through the session's
//! Transport when the wiring reaches them.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("ra8_rpc").session.rpc;
const session_server = @import("ra8_rpc").session.server;

pub const Env = proto.Client.Env;

/// One arrival the shell takes off the link, in the same shape the wire
/// client's pump produces: a reply keyed by its request id, or an event.
pub const Arrival = union(enum) {
    response: struct { id: u32, result: Env.Result },
    event: Env.Event,
};

/// A zero-length stand-in for the frame buffer the wire servers pass their
/// emitters; the sink never frames, so nothing reads it.
var tx_stub: [0]u8 = .{};

/// The shell's end of a native local session: typed requests in, one
/// arrival per pump out.
pub const Link = struct {
    context: *session_server.Context,
    gpa: std.mem.Allocator,

    /// Replies not yet taken, in the order their requests were sent.
    responses: std.ArrayListUnmanaged(Pending) = .empty,
    /// Events the feeds queued, oldest first.
    events: std.ArrayListUnmanaged(Queued) = .empty,
    next_id: u32 = 1,
    /// The last taken arrival's owned payload bytes, freed by the next pump.
    taken: ?[]const u8 = null,

    const Pending = struct { id: u32, result: Env.Result };
    const Queued = struct { topic: u16, payload: []u8 };

    pub fn init(gpa: std.mem.Allocator, context: *session_server.Context) Link {
        return .{ .context = context, .gpa = gpa };
    }

    pub fn deinit(self: *Link) void {
        for (self.responses.items) |pending| {
            if (pending.result == .ok) self.gpa.free(pending.result.ok);
        }
        self.responses.deinit(self.gpa);
        for (self.events.items) |queued| self.gpa.free(queued.payload);
        self.events.deinit(self.gpa);
        if (self.taken) |bytes| self.gpa.free(bytes);
    }

    /// Dispatch `args` for `method` straight to its handler and queue the
    /// reply; `pump` hands the reply over under the returned id, like any
    /// client's. A queue at the client's pending-table cap refuses more
    /// sends: the same back-pressure the wire client gives, not a broken
    /// session.
    pub fn send(self: *Link, comptime Args: type, comptime method: proto.Method, args: Args) anyerror!u32 {
        if (self.responses.items.len >= proto.pending_slots) return error.TableFull;
        const id = self.next_id;
        self.next_id += 1;
        const result = try self.dispatch(Args, method, args);
        try self.responses.append(self.gpa, .{ .id = id, .result = result });
        return id;
    }

    /// Call the handler `method` routes to, with `args` already typed, and
    /// return the reply as the envelope would carry it. A mismatched Args
    /// fails to compile at the call site, which is the check the wire's
    /// decoder did.
    fn dispatch(self: *Link, comptime Args: type, comptime method: proto.Method, args: Args) !Env.Result {
        inline for (session_server.routes) |route| {
            if (route[0] == @backingInt(method)) {
                const handler = route[1];
                const info = @typeInfo(@TypeOf(handler)).@"fn";
                const Reply = @FieldType(info.return_type.?, "ok");
                switch (handler(self.context, args)) {
                    .ok => |reply| return self.encodeReply(Reply, reply),
                    .err => |code| return .{ .err = code },
                }
            }
        }
        return .{ .err = .unknown_method };
    }

    fn encodeReply(self: *Link, comptime Reply: type, reply: Reply) !Env.Result {
        const body = try self.gpa.alloc(u8, rpc.codec.maxSize(Reply));
        defer self.gpa.free(body);
        const bytes = proto.encode(Reply, reply, body) catch return .{ .err = .failed };
        return .{ .ok = try self.gpa.dupe(u8, bytes) };
    }

    /// How many replies wait to be taken; the mailbox's dispatcher reads
    /// it to keep the reply queue inside the pending table's cap.
    pub fn pendingCount(self: *Link) usize {
        return self.responses.items.len;
    }

    /// The caller moved the last taken arrival's payload onto its own
    /// bookkeeping; the link forgets it, so the bytes are freed once, by
    /// the caller's next pump.
    pub fn releaseTaken(self: *Link) void {
        self.taken = null;
    }

    /// Take one arrival the session owes: a reply, or the next event the
    /// feeds queued; null once everything owed is taken. A payload slice in
    /// the arrival lives until the next pump.
    pub fn pump(self: *Link) anyerror!?Arrival {
        if (self.taken) |bytes| {
            self.gpa.free(bytes);
            self.taken = null;
        }
        if (self.take()) |arrival| return arrival;
        try self.drain();
        return self.take();
    }

    /// Collect everything the session now owes, in Host.poll's order: the
    /// feeds, then a stop the last job left pending.
    fn drain(self: *Link) anyerror!void {
        var sink = Sink{ .link = self };
        try session_server.pumpFeeds(self.context, &sink, &tx_stub);
        if (self.context.pending) |stopped| {
            self.context.pending = null;
            if (self.context.wants(stopped.core, .stop)) {
                try sink.emit(proto.Stopped, @backingInt(proto.Topic.stop), stopped, &tx_stub);
            }
        }
    }

    fn take(self: *Link) ?Arrival {
        if (self.responses.items.len > 0) {
            const pending = self.responses.orderedRemove(0);
            switch (pending.result) {
                .ok => |bytes| {
                    self.taken = bytes;
                    return .{ .response = .{ .id = pending.id, .result = .{ .ok = bytes } } };
                },
                .err => |code| return .{ .response = .{ .id = pending.id, .result = .{ .err = code } } },
            }
        }
        if (self.events.items.len > 0) {
            const queued = self.events.orderedRemove(0);
            self.taken = queued.payload;
            return .{ .event = .{ .topic = queued.topic, .payload = queued.payload } };
        }
        return null;
    }
};

/// The server the feed pumps write through: what they would have framed
/// onto a wire, the link queues instead.
pub const Sink = struct {
    link: *Link,

    pub fn emit(self: *Sink, comptime T: type, topic: u16, payload: T, tx: []u8) anyerror!void {
        _ = tx;
        const body = try self.link.gpa.alloc(u8, rpc.codec.maxSize(T));
        defer self.link.gpa.free(body);
        const bytes = try proto.encode(T, payload, body);
        const owned = try self.link.gpa.dupe(u8, bytes);
        errdefer self.link.gpa.free(owned);
        try self.link.events.append(self.link.gpa, .{ .topic = topic, .payload = owned });
    }
};
