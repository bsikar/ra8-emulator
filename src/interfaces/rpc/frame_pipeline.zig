//! The application-side frame pipeline (milestone M7): connects the board's
//! frame tap to the pure compositor worker and the two-tier frame cache.
//!
//! The frame cache's cold tier bridges to the host history storage via Store.open(.frames, ...).
//! The pure compositor worker operates over private immutable value copies in a background thread.
//! The tap rate-caps in host time (60 Hz) and honours cache keyframe demands.
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const history = @import("ra8_host").history;
const scheduler = @import("ra8_chip").core.scheduler;
const CpuStore = @import("ra8_chip").core.cpu.memory.store.Store;

const session = @import("ra8_session");
const frame_types = session.history_frame_types;
const frame_queue = session.history_frame_queue;
const frame_tap = session.history_frame_tap;
const compositor_worker = session.history_compositor_worker;
const frame_cache = session.history_frame_cache;
const frame_cache_types = session.history_frame_cache_types;

/// Storage backing bridge from host history store to the frame cache cold tier.
pub const StorageBacking = struct {
    allocator: std.mem.Allocator,
    store: history.storage.Store,

    pub fn backing(self: *StorageBacking) frame_cache.Backing {
        return .{
            .context = self,
            .createFn = createFn,
        };
    }

    const WrappedFile = struct {
        allocator: std.mem.Allocator,
        byte_file: history.storage.ByteFile,

        fn read(ctx: *anyopaque, offset: u64, buffer: []u8) anyerror!usize {
            const self: *WrappedFile = @ptrCast(@alignCast(ctx));
            return self.byte_file.vtable.read(self.byte_file.context, offset, buffer);
        }

        fn write(ctx: *anyopaque, offset: u64, bytes: []const u8) anyerror!void {
            const self: *WrappedFile = @ptrCast(@alignCast(ctx));
            return self.byte_file.vtable.write(self.byte_file.context, offset, bytes);
        }

        fn close(ctx: *anyopaque) void {
            const self: *WrappedFile = @ptrCast(@alignCast(ctx));
            self.byte_file.vtable.close(self.byte_file.context);
            self.allocator.destroy(self);
        }

        const vtable = frame_cache_types.File.Vtable{
            .read = read,
            .write = write,
            .close = close,
        };
    };

    fn createFn(context: *anyopaque, name: []const u8) anyerror!frame_cache_types.File {
        const self: *StorageBacking = @ptrCast(@alignCast(context));
        const byte_file = try self.store.vtable.open(self.store.context, .frames, name, .create);
        errdefer byte_file.vtable.close(byte_file.context);
        const wrapped = try self.allocator.create(WrappedFile);
        wrapped.* = .{
            .allocator = self.allocator,
            .byte_file = byte_file,
        };
        return .{
            .context = wrapped,
            .vtable = &WrappedFile.vtable,
        };
    }
};

pub const FramePipeline = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: frame_queue.Queue,
    cache: frame_cache.FrameCache,
    worker: compositor_worker.CompositorWorker,
    tap: frame_tap.FrameTap,
    backing: ?StorageBacking = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        board: *Board,
        cpu_store: ?*CpuStore,
        grid: ?*const scheduler.State,
        branch: u32,
        maybe_store: ?history.storage.Store,
        ram_budget: u64,
        disk_budget: u64,
        clock: frame_tap.Clock,
    ) !*FramePipeline {
        const self = try allocator.create(FramePipeline);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .queue = frame_queue.Queue.init(io, allocator, frame_queue.default_capacity),
            .cache = undefined,
            .worker = undefined,
            .tap = undefined,
        };
        errdefer self.queue.deinit();

        const backing_opt: ?frame_cache.Backing = if (maybe_store) |store| blk: {
            self.backing = .{ .allocator = allocator, .store = store };
            break :blk self.backing.?.backing();
        } else null;

        const hot_bytes = frame_cache.hotBytesFor(ram_budget);
        const limits = frame_cache.Limits{
            .ram_bytes = hot_bytes,
            .disk_bytes = disk_budget,
            .max_markers = 4096,
        };
        self.cache = frame_cache.FrameCache.init(allocator, io, limits, backing_opt);
        errdefer self.cache.deinit();

        self.worker = compositor_worker.CompositorWorker.init(allocator, &self.queue, self.cache.sink());
        errdefer self.worker.deinit();
        try self.worker.start();
        errdefer self.worker.stop();

        self.tap = frame_tap.FrameTap.init(allocator, board, &self.queue, clock);
        self.tap.setPositionSource(grid, branch);
        self.tap.bindCache(&self.cache);
        self.tap.arm(io, cpu_store);

        return self;
    }

    pub fn setIntervalNs(self: *FramePipeline, ns: i96) void {
        self.tap.interval_ns = ns;
    }

    pub fn bindNav(self: *FramePipeline, nav: ?*session.history_nav_index.NavIndex) void {
        self.tap.bindNav(nav);
    }

    pub fn deinit(self: *FramePipeline) void {
        self.tap.deinit();
        self.worker.stop();
        _ = self.worker.drain() catch 0;
        self.cache.deinit();
        self.worker.deinit();
        self.queue.deinit();
        self.allocator.destroy(self);
    }
};
