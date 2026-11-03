//! The event loop of the realtime side of a stream. One thread polls the registered fds and
//! runs the functions that other threads ask for with `invoke`.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const DataLoop = @This();

pub const Options = struct { threaded: bool = !builtin.single_threaded };

pub const InitError = error{ OutOfMemory, SystemResources, Unsupported, Unexpected } || std.Thread.SpawnError;
pub const Error = error{ TooManySources, Threaded, Unexpected };

pub const SourceFn = *const fn (ctx: *anyopaque) void;
pub const InvokeFn = *const fn (ctx: *anyopaque) void;

/// The loop holds 32 sources at most.
const max_sources = 32;
const queue_len = 16;
const wake_tag: u32 = max_sources;

const slot_free = 0;
const slot_claimed = 1;
const slot_ready = 2;
const slot_done = 3;
const slot_running = 4;

const Source = struct {
    fd: linux.fd_t = -1,
    ctx: *anyopaque = undefined,
    func: SourceFn = undefined,
};

/// One waiting call of `invoke`.
const Slot = struct {
    state: std.atomic.Value(u32) = .init(slot_free),
    ctx: *anyopaque = undefined,
    func: InvokeFn = undefined,
};

gpa: std.mem.Allocator,
epfd: linux.fd_t,
wake_fd: linux.fd_t,
sources: [max_sources]Source = @splat(.{}),
slots: [queue_len]Slot = @splat(.{}),
stop: std.atomic.Value(bool) = .init(false),
/// Set when `poll` failed on the loop thread. The thread has left the loop then.
failed: std.atomic.Value(bool) = .init(false),
/// Set when the loop thread has left the loop, for any reason.
exited: std.atomic.Value(bool) = .init(false),
/// How many times `poll` failed on the loop thread.
poll_errors: std.atomic.Value(u32) = .init(0),
thread: ?std.Thread = null,
/// The kernel thread id of the loop thread, for example for RTKit. It is 0 until the thread runs.
thread_id: std.atomic.Value(std.Thread.Id) = .init(0),

/// With `threaded` a thread runs the loop. Without it the caller runs `iterate`.
pub fn init(gpa: std.mem.Allocator, options: Options) InitError!*DataLoop {
    const ep = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (linux.errno(ep) != .SUCCESS) return error.SystemResources;
    errdefer _ = linux.close(@intCast(ep));
    const efd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(efd) != .SUCCESS) return error.SystemResources;
    errdefer _ = linux.close(@intCast(efd));

    const self = try gpa.create(DataLoop);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .epfd = @intCast(ep), .wake_fd = @intCast(efd) };

    var ev: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .u32 = wake_tag } };
    if (linux.errno(linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, self.wake_fd, &ev)) != .SUCCESS) return error.Unexpected;

    if (options.threaded) {
        if (comptime builtin.single_threaded) return error.Unsupported;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    return self;
}

/// Stops and joins the thread, runs the calls of `invoke` that still wait and waits until
/// every caller has left `invoke`. A call that started before `deinit` completes. No thread
/// may start `invoke`, `addSource` or `removeSource` during or after `deinit`.
pub fn deinit(self: *DataLoop) void {
    if (self.thread) |t| {
        self.stop.store(true, .release);
        self.wake();
        t.join();
        self.runQueue();
        for (&self.slots) |*slot| {
            while (true) {
                const s = slot.state.load(.acquire);
                if (s == slot_free) break;
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
        }
    }
    _ = linux.close(self.wake_fd);
    if (self.epfd >= 0) _ = linux.close(self.epfd);
    self.gpa.destroy(self);
}

/// Runs `func(ctx)` on the loop thread between two polls and waits until it is done. It runs
/// inline when the loop has no thread or when the loop thread is the caller. Once the loop
/// thread has exited, calls from different threads can run inline at the same time. That is
/// fine with one control thread for each Remote.
pub fn invoke(self: *DataLoop, ctx: *anyopaque, func: InvokeFn) void {
    if (self.thread == null or self.exited.load(.seq_cst) or self.thread_id.load(.acquire) == std.Thread.getCurrentId()) {
        func(ctx);
        return;
    }
    var i: usize = 0;
    const slot = while (true) : (i +%= 1) {
        const s = &self.slots[i % queue_len];
        if (s.state.cmpxchgStrong(slot_free, slot_claimed, .acquire, .monotonic) == null) break s;
        if (i % queue_len == queue_len - 1) std.Thread.yield() catch std.atomic.spinLoopHint();
    };
    slot.ctx = ctx;
    slot.func = func;
    slot.state.store(slot_ready, .seq_cst);
    self.wake();
    // The thread may have left the loop after the check above. Then the call runs here.
    if (self.exited.load(.seq_cst) and slot.state.cmpxchgStrong(slot_ready, slot_running, .acquire, .monotonic) == null) {
        func(ctx);
        slot.state.store(slot_free, .release);
        return;
    }
    while (true) {
        const s = slot.state.load(.acquire);
        if (s == slot_done) break;
        futexWait(&slot.state, s);
    }
    slot.state.store(slot_free, .release);
}

/// Calls `func(ctx)` when `fd` is readable. Call it from `invoke` or from the loop thread.
pub fn addSource(self: *DataLoop, fd: linux.fd_t, ctx: *anyopaque, func: SourceFn) Error!void {
    var free: ?usize = null;
    for (self.sources, 0..) |s, i| {
        if (s.fd == fd) return error.Unexpected;
        if (s.fd < 0 and free == null) free = i;
    }
    const index = free orelse return error.TooManySources;
    var ev: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .u32 = @intCast(index) } };
    if (linux.errno(linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, fd, &ev)) != .SUCCESS) return error.Unexpected;
    self.sources[index] = .{ .fd = fd, .ctx = ctx, .func = func };
}

/// Stops watching `fd`. Call it from `invoke` or from the loop thread.
pub fn removeSource(self: *DataLoop, fd: linux.fd_t) void {
    for (&self.sources) |*s| {
        if (s.fd != fd) continue;
        _ = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_DEL, fd, null);
        s.fd = -1;
        return;
    }
}

/// Runs the ready sources and the waiting calls of `invoke` once, and waits at most
/// `timeout_ms` for the first one. Only for a loop with no thread.
pub fn iterate(self: *DataLoop, timeout_ms: i32) Error!void {
    if (self.thread != null) return error.Threaded;
    try self.poll(timeout_ms);
}

fn run(self: *DataLoop) void {
    self.thread_id.store(std.Thread.getCurrentId(), .release);
    while (!self.stop.load(.acquire)) {
        self.poll(-1) catch {
            _ = self.poll_errors.fetchAdd(1, .monotonic);
            self.failed.store(true, .seq_cst);
            break;
        };
    }
    self.exited.store(true, .seq_cst);
    self.runQueue();
}

fn poll(self: *DataLoop, timeout_ms: i32) Error!void {
    var events: [16]linux.epoll_event = undefined;
    const rc = linux.epoll_wait(self.epfd, &events, events.len, timeout_ms);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .INTR => return,
        else => return error.Unexpected,
    }
    for (events[0..rc]) |ev| {
        const tag = ev.data.u32;
        if (tag == wake_tag) {
            var count: [8]u8 = undefined;
            _ = linux.read(self.wake_fd, &count, count.len);
            self.runQueue();
        } else if (tag < max_sources) {
            const s = self.sources[tag];
            if (s.fd >= 0) s.func(s.ctx);
        }
    }
}

fn runQueue(self: *DataLoop) void {
    for (&self.slots) |*slot| {
        // seq_cst pairs with the seq_cst store of `ready` and load of `exited` in `invoke`.
        if (slot.state.cmpxchgStrong(slot_ready, slot_running, .seq_cst, .monotonic) != null) continue;
        slot.func(slot.ctx);
        slot.state.store(slot_done, .release);
        futexWake(&slot.state);
    }
}

fn wake(self: *DataLoop) void {
    const one = std.mem.toBytes(@as(u64, 1));
    _ = linux.write(self.wake_fd, &one, one.len);
}

fn futexWait(word: *std.atomic.Value(u32), expected: u32) void {
    _ = linux.futex_4arg(&word.raw, .{ .cmd = .WAIT, .private = true }, expected, null);
}

fn futexWake(word: *std.atomic.Value(u32)) void {
    _ = linux.futex_3arg(&word.raw, .{ .cmd = .WAKE, .private = true }, 1);
}

const testing = std.testing;
const util = @import("testing/util.zig");
const newEventfd = util.newEventfd;
const bump = util.bump;

const Probe = struct {
    ran: bool = false,
    thread: std.Thread.Id = 0,

    fn run(ctx: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.thread = std.Thread.getCurrentId();
        self.ran = true;
    }
};

const TestSource = struct {
    fd: linux.fd_t,
    hits: u32 = 0,

    fn hit(ctx: *anyopaque) void {
        const self: *TestSource = @ptrCast(@alignCast(ctx));
        var buf: [8]u8 = undefined;
        _ = linux.read(self.fd, &buf, 8);
        self.hits += 1;
    }
};

test "invoke runs inline when the loop has no thread" {
    const loop = try DataLoop.init(testing.allocator, .{ .threaded = false });
    defer loop.deinit();
    var probe: Probe = .{};
    loop.invoke(&probe, Probe.run);
    try testing.expect(probe.ran);
    try testing.expectEqual(std.Thread.getCurrentId(), probe.thread);
}

test "invoke runs on the loop thread and returns after it ran" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const loop = try DataLoop.init(testing.allocator, .{ .threaded = true });
    defer loop.deinit();
    var probe: Probe = .{};
    loop.invoke(&probe, Probe.run);
    try testing.expect(probe.ran);
    try testing.expect(probe.thread != std.Thread.getCurrentId());
    try testing.expectEqual(loop.thread_id.load(.acquire), probe.thread);
}

const Count = struct {
    n: u32 = 0,

    fn add(ctx: *anyopaque) void {
        const self: *Count = @ptrCast(@alignCast(ctx));
        self.n += 1;
    }
};

fn hammer(loop: *DataLoop, count: *Count) void {
    for (0..200) |_| loop.invoke(count, Count.add);
}

test "invoke from several threads runs every call once" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const loop = try DataLoop.init(testing.allocator, .{ .threaded = true });
    defer loop.deinit();
    var count: Count = .{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, hammer, .{ loop, &count });
    for (threads) |t| t.join();
    try testing.expectEqual(@as(u32, 800), count.n);
}

test "a ready source runs in iterate and stops after removeSource" {
    const loop = try DataLoop.init(testing.allocator, .{ .threaded = false });
    defer loop.deinit();
    const fd = try newEventfd();
    defer _ = linux.close(fd);
    var src: TestSource = .{ .fd = fd };
    try loop.addSource(fd, &src, TestSource.hit);

    try loop.iterate(0);
    try testing.expectEqual(@as(u32, 0), src.hits);
    try bump(fd);
    try loop.iterate(100);
    try testing.expectEqual(@as(u32, 1), src.hits);

    try bump(fd);
    loop.removeSource(fd);
    try loop.iterate(0);
    try testing.expectEqual(@as(u32, 1), src.hits);
}

test "a source added from invoke runs on the loop thread" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const loop = try DataLoop.init(testing.allocator, .{ .threaded = true });
    defer loop.deinit();
    const fd = try newEventfd();
    defer _ = linux.close(fd);
    var src: TestSource = .{ .fd = fd };
    const Add = struct {
        loop: *DataLoop,
        src: *TestSource,
        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.loop.addSource(self.src.fd, self.src, TestSource.hit) catch unreachable;
        }
    };
    var add: Add = .{ .loop = loop, .src = &src };
    loop.invoke(&add, Add.run);
    try bump(fd);
    var tries: u32 = 0;
    while (@atomicLoad(u32, &src.hits, .acquire) == 0 and tries < 200) : (tries += 1) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
        var ts: linux.timespec = .{ .sec = 0, .nsec = 5_000_000 };
        _ = linux.nanosleep(&ts, null);
    }
    try testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &src.hits, .acquire));
}

test "iterate on a threaded loop is an error" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const loop = try DataLoop.init(testing.allocator, .{ .threaded = true });
    defer loop.deinit();
    try testing.expectError(error.Threaded, loop.iterate(0));
}

test "the source table is full after max_sources fds" {
    const loop = try DataLoop.init(testing.allocator, .{ .threaded = false });
    defer loop.deinit();
    var fds: [max_sources + 1]linux.fd_t = undefined;
    var src: TestSource = .{ .fd = -1 };
    for (&fds) |*f| f.* = try newEventfd();
    defer for (fds) |f| {
        _ = linux.close(f);
    };
    for (fds[0..max_sources]) |f| try loop.addSource(f, &src, TestSource.hit);
    try testing.expectError(error.TooManySources, loop.addSource(fds[max_sources], &src, TestSource.hit));
}

test "invoke runs inline after the loop thread failed" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const loop = try DataLoop.init(testing.allocator, .{ .threaded = true });
    defer loop.deinit();
    // A closed epoll fd makes the next poll fail.
    _ = linux.close(loop.epfd);
    loop.epfd = -1;
    loop.wake();
    var tries: u32 = 0;
    while (!loop.exited.load(.acquire) and tries < 400) : (tries += 1) {
        var ts: linux.timespec = .{ .sec = 0, .nsec = 5_000_000 };
        _ = linux.nanosleep(&ts, null);
    }
    try testing.expect(loop.failed.load(.acquire));
    try testing.expectEqual(@as(u32, 1), loop.poll_errors.load(.acquire));
    var probe: Probe = .{};
    loop.invoke(&probe, Probe.run);
    try testing.expect(probe.ran);
    try testing.expectEqual(std.Thread.getCurrentId(), probe.thread);
}
