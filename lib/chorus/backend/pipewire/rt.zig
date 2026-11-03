//! Realtime promotion for a thread of this process.
//! The desktop portal (org.freedesktop.portal.Realtime on the session bus) is not used.
const std = @import("std");
const dbus = @import("dbus");
const linux = std.os.linux;
const builtin = @import("builtin");
const testing = std.testing;
const inChild = @import("child.zig").inChild;

const log = std.log.scoped(.chorus_rt);

pub const Result = enum { direct, rtkit, failed };

pub const Options = struct {
    priority: u32 = 20,
    rttime_usec: u64 = 200_000,
    /// Socket of the system bus. A leading '@' selects the abstract namespace.
    /// The default is /run/dbus/system_bus_socket. This code does not read the environment.
    bus_path: ?[:0]const u8 = null,
    timeout_ms: u32 = 1000,
    /// Counts the promotions that failed because the allocator ran out of memory.
    oom_count: ?*std.atomic.Value(u32) = null,
};

const rtkit_name = "org.freedesktop.RealtimeKit1";
const rtkit_path = "/org/freedesktop/RealtimeKit1";
const default_bus_path = "/run/dbus/system_bus_socket";
const reset_on_fork: usize = 0x40000000;
const spin_ms = 20;

const Failure = error{
    Connect,
    Send,
    Timeout,
    Rejected,
    Encode,
    BadReply,
    SetRlimit,
    OutOfMemory,
};

/// Makes the thread with kernel id `tid` realtime with SCHED_RESET_ON_FORK set. The direct
/// path sets SCHED_FIFO. RTKit sets SCHED_RR.
/// Tries sched_setscheduler first, then RTKit MakeThreadRealtimeWithPID on the system bus.
/// This call blocks. Each blocking step of the bus connect and its handshake can wait one
/// second in dbus.zig, so run it on a helper thread, never on the app thread. After the
/// connect, the property reads and the call together wait at most timeout_ms. A failure is
/// logged once.
pub fn promote(gpa: std.mem.Allocator, io: std.Io, tid: i32, options: Options) Result {
    return promoteVia(gpa, io, tid, options, true);
}

fn promoteVia(gpa: std.mem.Allocator, io: std.Io, tid: i32, options: Options, try_direct: bool) Result {
    if (try_direct and setDirect(tid, options.priority)) {
        limitRttime(options.rttime_usec) catch |err| log.warn("setting the RTTIME limit failed: {s}", .{@errorName(err)});
        return .direct;
    }
    var detail: Detail = .{};
    promoteRtkit(gpa, io, tid, options, &detail) catch |err| {
        noteFailure(err, options);
        log.warn("realtime promotion of thread {d} failed: {s}{s}{s}", .{ tid, @errorName(err), if (detail.len > 0) " " else "", detail.slice() });
        return .failed;
    };
    return .rtkit;
}

fn noteFailure(err: Failure, options: Options) void {
    if (err != error.OutOfMemory) return;
    if (options.oom_count) |count| _ = count.fetchAdd(1, .monotonic);
}

const Detail = struct {
    buf: [96]u8 = undefined,
    len: usize = 0,

    fn set(self: *Detail, name: []const u8) void {
        self.len = @min(name.len, self.buf.len);
        @memcpy(self.buf[0..self.len], name[0..self.len]);
    }

    fn slice(self: *const Detail) []const u8 {
        return self.buf[0..self.len];
    }
};

/// An allocation failure keeps its own error so that it can be counted. The error sets of
/// dbus.zig differ for each call, so this takes anyerror.
fn classify(err: anyerror, other: Failure) Failure {
    return if (err == error.OutOfMemory) error.OutOfMemory else other;
}

fn clampRttime(wanted: u64, max: u64) u64 {
    return @min(wanted, max);
}

fn setDirect(tid: i32, priority: u32) bool {
    const prio: i32 = @intCast(std.math.clamp(priority, 1, 99));
    const param: linux.sched_param = .{ .priority = prio };
    const rc = linux.sched_setscheduler(tid, .{ .mode = .FIFO, .RESET_ON_FORK = true }, &param);
    return linux.errno(rc) == .SUCCESS;
}

const Reply = struct {
    gpa: std.mem.Allocator,
    done: bool = false,
    ok: bool = false,
    value: i64 = 0,
    err: Detail = .{},

    fn onCall(ctx: ?*anyopaque, conn: *dbus.connection.Connection, reply: ?*const dbus.message.Message) void {
        _ = conn;
        const self: *Reply = @ptrCast(@alignCast(ctx.?));
        self.done = true;
        const msg = reply orelse return;
        self.ok = msg.msg_type == .method_return;
        if (msg.error_name) |name| self.err.set(name);
    }

    fn onProperty(ctx: ?*anyopaque, conn: *dbus.connection.Connection, reply: ?*const dbus.message.Message) void {
        _ = conn;
        const self: *Reply = @ptrCast(@alignCast(ctx.?));
        self.done = true;
        const msg = reply orelse return;
        if (msg.msg_type != .method_return) {
            if (msg.error_name) |name| self.err.set(name);
            return;
        }
        var r = dbus.Reader.init(msg.body, msg.endian);
        const v = r.readValue(self.gpa, "v") catch return;
        defer dbus.unmarshal.freeValue(self.gpa, v);
        const inner = switch (v) {
            .variant => |p| p.*,
            else => return,
        };
        self.value = switch (inner) {
            .int32 => |n| n,
            .int64 => |n| n,
            else => return,
        };
        self.ok = true;
    }
};

const Session = struct {
    gpa: std.mem.Allocator,
    loop: *dbus.event_loop.EventLoop,
    bus: *dbus.client.Bus,
    spins_left: u32,
    detail: *Detail,

    fn wait(self: *Session, reply: *const Reply) Failure!void {
        errdefer self.detail.* = reply.err;
        while (!reply.done) {
            if (self.spins_left == 0) return error.Timeout;
            self.spins_left -= 1;
            _ = self.loop.dispatch(spin_ms);
        }
        if (!reply.ok) return error.Rejected;
    }

    fn readInt(self: *Session, property: []const u8) Failure!i64 {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var w = dbus.marshal.Writer.init(self.gpa, &body, self.bus.conn.endian);
        w.string(rtkit_name) catch |err| return classify(err, error.Encode);
        w.string(property) catch |err| return classify(err, error.Encode);
        var reply = Reply{ .gpa = self.gpa };
        _ = self.bus.call(.{
            .msg_type = .method_call,
            .serial = 0,
            .destination = rtkit_name,
            .path = rtkit_path,
            .interface = "org.freedesktop.DBus.Properties",
            .member = "Get",
            .body_signature = "ss",
            .body = body.items,
        }, Reply.onProperty, &reply) catch |err| return classify(err, error.Send);
        try self.wait(&reply);
        return reply.value;
    }

    fn makeRealtime(self: *Session, tid: i32, priority: u32) Failure!void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var w = dbus.marshal.Writer.init(self.gpa, &body, self.bus.conn.endian);
        w.uint64(@intCast(linux.getpid())) catch |err| return classify(err, error.Encode);
        w.uint64(@intCast(tid)) catch |err| return classify(err, error.Encode);
        w.uint32(priority) catch |err| return classify(err, error.Encode);
        var reply = Reply{ .gpa = self.gpa };
        _ = self.bus.call(.{
            .msg_type = .method_call,
            .serial = 0,
            .destination = rtkit_name,
            .path = rtkit_path,
            .interface = rtkit_name,
            .member = "MakeThreadRealtimeWithPID",
            .body_signature = "ttu",
            .body = body.items,
        }, Reply.onCall, &reply) catch |err| return classify(err, error.Send);
        try self.wait(&reply);
    }
};

fn promoteRtkit(gpa: std.mem.Allocator, io: std.Io, tid: i32, options: Options, detail: *Detail) Failure!void {
    var loop = dbus.event_loop.EventLoop.init(gpa) catch |err| return classify(err, error.Connect);
    defer loop.deinit();
    const path = options.bus_path orelse default_bus_path;
    const abstract = path.len > 0 and path[0] == '@';
    const bus = dbus.client.Bus.connectUnix(gpa, &loop, io, if (abstract) path[1..] else path, abstract, linux.getuid()) catch |err| return classify(err, error.Connect);
    defer bus.deinit();

    var session = Session{ .gpa = gpa, .loop = &loop, .bus = bus, .spins_left = options.timeout_ms / spin_ms + 1, .detail = detail };
    const max_prio = std.math.cast(u32, try session.readInt("MaxRealtimePriority")) orelse return error.BadReply;
    const rttime_max = std.math.cast(u64, try session.readInt("RTTimeUSecMax")) orelse return error.BadReply;
    if (max_prio < 1) return error.BadReply;

    try limitRttime(clampRttime(options.rttime_usec, rttime_max));

    const other: linux.sched_param = .{ .priority = 0 };
    const rc = linux.sched_setscheduler(tid, .{ .mode = .NORMAL, .RESET_ON_FORK = true }, &other);
    if (linux.errno(rc) != .SUCCESS) log.warn("setting SCHED_OTHER on thread {d} failed", .{tid});

    const prio: u32 = std.math.clamp(options.priority, 1, max_prio);
    try session.makeRealtime(tid, prio);
}

fn limitRttime(limit: u64) Failure!void {
    var current: linux.rlimit = undefined;
    if (linux.errno(linux.getrlimit(.RTTIME, &current)) != .SUCCESS) return error.SetRlimit;
    const wanted: linux.rlimit = .{ .cur = @min(current.cur, limit), .max = @min(current.max, limit) };
    if (linux.errno(linux.setrlimit(.RTTIME, &wanted)) != .SUCCESS) return error.SetRlimit;
}

test "clampRttime keeps the smaller value" {
    try testing.expectEqual(@as(u64, 200_000), clampRttime(200_000, 200_000));
    try testing.expectEqual(@as(u64, 100_000), clampRttime(100_000, 200_000));
    try testing.expectEqual(@as(u64, 200_000), clampRttime(1_000_000, 200_000));
    try testing.expectEqual(@as(u64, 0), clampRttime(5, 0));
}

const Daemon = dbus.daemon.bus.Daemon;
const EventLoop = dbus.event_loop.EventLoop;
const Bus = dbus.client.Bus;
const Message = dbus.message.Message;
const Connection = dbus.connection.Connection;

const FakeRtkit = struct {
    sock: []const u8,
    max_prio: i64 = 20,
    max_sig: []const u8 = "i",
    rttime_max: i64 = 200_000,
    ready: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    calls: u32 = 0,
    pid: u64 = 0,
    tid: u64 = 0,
    prio: u32 = 0,
    limit_cur: linux.rlim_t = 0,
    limit_max: linux.rlim_t = 0,
    policy: usize = 0,
    err: ?anyerror = null,

    fn onMake(ctx: ?*anyopaque, call: *const Message, w: *dbus.marshal.Writer) dbus.object.HandlerError![]const u8 {
        _ = w;
        const self: *FakeRtkit = @ptrCast(@alignCast(ctx.?));
        var r = dbus.Reader.init(call.body, call.endian);
        self.pid = r.uint64() catch return error.Failed;
        self.tid = r.uint64() catch return error.Failed;
        self.prio = r.uint32() catch return error.Failed;
        var rl: linux.rlimit = undefined;
        if (linux.errno(linux.getrlimit(.RTTIME, &rl)) == .SUCCESS) {
            self.limit_cur = rl.cur;
            self.limit_max = rl.max;
        }
        self.policy = linux.sched_getscheduler(@intCast(self.tid));
        self.calls += 1;
        return "";
    }

    fn getMax(ctx: ?*anyopaque, w: *dbus.marshal.Writer) dbus.object.HandlerError!void {
        const self: *FakeRtkit = @ptrCast(@alignCast(ctx.?));
        if (std.mem.eql(u8, self.max_sig, "x")) try w.int64(self.max_prio) else try w.int32(@intCast(self.max_prio));
    }

    fn getRttime(ctx: ?*anyopaque, w: *dbus.marshal.Writer) dbus.object.HandlerError!void {
        const self: *FakeRtkit = @ptrCast(@alignCast(ctx.?));
        try w.int64(self.rttime_max);
    }

    fn onName(ctx: ?*anyopaque, conn: *Connection, reply: ?*const Message) void {
        _ = conn;
        _ = reply;
        const done: *bool = @ptrCast(@alignCast(ctx.?));
        done.* = true;
    }

    fn run(self: *FakeRtkit) void {
        self.serve() catch |err| {
            self.err = err;
        };
        self.ready.store(true, .release);
    }

    fn serve(self: *FakeRtkit) !void {
        var loop = try EventLoop.init(testing.allocator);
        defer loop.deinit();
        var iot: std.Io.Threaded = .init(testing.allocator, .{});
        defer iot.deinit();
        const bus = try Bus.connectUnix(testing.allocator, &loop, iot.io(), self.sock, true, linux.getuid());
        defer bus.deinit();

        const methods = [_]dbus.object.Method{.{ .name = "MakeThreadRealtimeWithPID", .handler = onMake, .ctx = self, .in_sig = "ttu" }};
        const props = [_]dbus.object.Property{
            .{ .name = "MaxRealtimePriority", .sig = self.max_sig, .getter = getMax, .ctx = self },
            .{ .name = "RTTimeUSecMax", .sig = "x", .getter = getRttime, .ctx = self },
        };
        try bus.exportObject("/org/freedesktop/RealtimeKit1", &.{.{
            .name = "org.freedesktop.RealtimeKit1",
            .methods = &methods,
            .properties = &props,
        }});

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(testing.allocator);
        var w = dbus.marshal.Writer.init(testing.allocator, &body, bus.conn.endian);
        try w.string("org.freedesktop.RealtimeKit1");
        try w.uint32(0);
        var named = false;
        _ = try bus.call(.{ .msg_type = .method_call, .serial = 0, .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "RequestName", .destination = "org.freedesktop.DBus", .body_signature = "su", .body = body.items }, onName, &named);
        var i: usize = 0;
        while (!named and i < 300) : (i += 1) _ = loop.dispatch(20);
        if (!named) return error.NameFailed;

        self.ready.store(true, .release);
        while (!self.stop.load(.acquire)) _ = loop.dispatch(10);
    }
};

const Sleeper = struct {
    tid: std.atomic.Value(i32) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),

    fn run(self: *Sleeper) void {
        self.tid.store(linux.gettid(), .release);
        while (!self.stop.load(.acquire)) _ = linux.nanosleep(&.{ .sec = 0, .nsec = 1_000_000 }, null);
    }

    fn waitTid(self: *Sleeper) i32 {
        while (self.tid.load(.acquire) == 0) _ = linux.nanosleep(&.{ .sec = 0, .nsec = 1_000_000 }, null);
        return self.tid.load(.acquire);
    }
};

fn waitFlag(flag: *const std.atomic.Value(bool)) void {
    while (!flag.load(.acquire)) _ = linux.nanosleep(&.{ .sec = 0, .nsec = 1_000_000 }, null);
}

fn daemonThread(d: *Daemon) void {
    d.run();
}

fn fakeCase(comptime wide_max: bool) !void {
    const saved_level = testing.log_level;
    if (wide_max) testing.log_level = .err;
    defer testing.log_level = saved_level;
    var dloop = try EventLoop.init(testing.allocator);
    defer dloop.deinit();
    var diot: std.Io.Threaded = .init(testing.allocator, .{});
    defer diot.deinit();
    const d = try Daemon.init(testing.allocator, &dloop, diot.io());
    defer d.deinit();
    var name_buf: [64]u8 = undefined;
    const sock = try std.mem.printSentinel(&name_buf, "chorus-rt-{d}", .{linux.getpid()}, 0);
    try d.listenUnix(sock, true);
    const dthread = try std.Thread.spawn(.{}, daemonThread, .{d});
    defer {
        d.stop();
        dthread.join();
    }

    var fake = FakeRtkit{ .sock = sock, .rttime_max = 100_000 };
    if (wide_max) {
        fake.max_prio = 1 << 40;
        fake.max_sig = "x";
    }
    const fthread = try std.Thread.spawn(.{}, FakeRtkit.run, .{&fake});
    var sleeper = Sleeper{};
    const sthread = try std.Thread.spawn(.{}, Sleeper.run, .{&sleeper});
    defer {
        sleeper.stop.store(true, .release);
        sthread.join();
    }
    waitFlag(&fake.ready);
    const tid = sleeper.waitTid();

    var path_buf: [66]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "@{s}", .{sock}, 0);
    const result = promoteVia(testing.allocator, diot.io(), tid, .{ .priority = 50, .rttime_usec = 200_000, .bus_path = path }, false);
    fake.stop.store(true, .release);
    fthread.join();

    try testing.expectEqual(@as(?anyerror, null), fake.err);
    if (wide_max) {
        try testing.expectEqual(Result.failed, result);
        try testing.expectEqual(@as(u32, 0), fake.calls);
        return;
    }
    try testing.expectEqual(Result.rtkit, result);
    try testing.expectEqual(@as(u32, 1), fake.calls);
    try testing.expectEqual(@as(u64, @intCast(linux.getpid())), fake.pid);
    try testing.expectEqual(@as(u64, @intCast(tid)), fake.tid);
    try testing.expectEqual(@as(u32, 20), fake.prio);
    // The limit and the policy were already set when the call arrived.
    try testing.expectEqual(@as(linux.rlim_t, 100_000), fake.limit_cur);
    try testing.expectEqual(@as(linux.rlim_t, 100_000), fake.limit_max);
    try testing.expectEqual(@as(usize, reset_on_fork), fake.policy);
    var rl: linux.rlimit = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.getrlimit(.RTTIME, &rl)));
    try testing.expect(rl.cur <= 100_000);
    try testing.expect(rl.max <= 100_000);
    try testing.expectEqual(@as(usize, reset_on_fork), linux.sched_getscheduler(tid));
}

test "rtkit path sends the clamped call to a fake RealtimeKit1" {
    try inChild(struct {
        fn run() !void {
            try fakeCase(false);
        }
    }.run);
}

test "an out of range MaxRealtimePriority gives failed" {
    try inChild(struct {
        fn run() !void {
            try fakeCase(true);
        }
    }.run);
}

test "promote returns failed when no bus is reachable" {
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    var iot: std.Io.Threaded = .init(testing.allocator, .{});
    defer iot.deinit();
    var sleeper = Sleeper{};
    const sthread = try std.Thread.spawn(.{}, Sleeper.run, .{&sleeper});
    defer {
        sleeper.stop.store(true, .release);
        sthread.join();
    }
    const tid = sleeper.waitTid();
    const result = promoteVia(testing.allocator, iot.io(), tid, .{ .bus_path = "/nonexistent/chorus-bus" }, false);
    try testing.expectEqual(Result.failed, result);
}

fn liveCase() !void {
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    var iot: std.Io.Threaded = .init(testing.allocator, .{});
    defer iot.deinit();
    var sleeper = Sleeper{};
    const sthread = try std.Thread.spawn(.{}, Sleeper.run, .{&sleeper});
    defer {
        sleeper.stop.store(true, .release);
        sthread.join();
    }
    const tid = sleeper.waitTid();
    const result = promote(testing.allocator, iot.io(), tid, .{});
    const policy: usize = switch (result) {
        .failed => return error.SkipZigTest,
        .direct => @backingInt(linux.SCHED.Mode.FIFO),
        .rtkit => @backingInt(linux.SCHED.Mode.RR),
    };
    try testing.expectEqual(policy | reset_on_fork, linux.sched_getscheduler(tid));
}

test "promote makes a fresh thread realtime" {
    try inChild(liveCase);
}

test "a lack of memory is kept apart and counted" {
    try testing.expectEqual(@as(Failure, error.OutOfMemory), classify(error.OutOfMemory, error.Connect));
    try testing.expectEqual(@as(Failure, error.Connect), classify(error.FileNotFound, error.Connect));
    var count: std.atomic.Value(u32) = .init(0);
    noteFailure(error.Timeout, .{ .oom_count = &count });
    try testing.expectEqual(@as(u32, 0), count.load(.monotonic));
    noteFailure(error.OutOfMemory, .{ .oom_count = &count });
    try testing.expectEqual(@as(u32, 1), count.load(.monotonic));
    noteFailure(error.OutOfMemory, .{});
}

test "promote gives failed with a buffer that is too small" {
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    var iot: std.Io.Threaded = .init(testing.allocator, .{});
    defer iot.deinit();
    var small: [8]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&small);
    const result = promoteVia(fba.allocator(), iot.io(), linux.gettid(), .{ .bus_path = "/nonexistent/chorus-bus" }, false);
    try testing.expectEqual(Result.failed, result);
}
