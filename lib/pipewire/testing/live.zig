//! Helpers for the tests that talk to the real PipeWire daemon. Each test skips when no daemon answers.
const std = @import("std");
const linux = std.os.linux;
const path = @import("../path.zig");
const Remote = @import("../Remote.zig");
const Registry = @import("../Registry.zig");
const Proxy = @import("../Proxy.zig");
const DataLoop = @import("../DataLoop.zig");

const gpa = std.testing.allocator;

pub const Seen = struct {
    id: u32,
    name: []u8,
};

/// A connection with a registry that records what the daemon reports.
pub const Live = struct {
    remote: *Remote,
    registry: *Registry,
    env: std.process.Environ.Map,
    core_name: ?[]u8 = null,
    core_globals: u32 = 0,
    wireplumber: bool = false,
    nodes: std.ArrayList(Seen) = .empty,
    removed: std.ArrayList(u32) = .empty,
    core_errors: u32 = 0,
    /// Registry events that could not be recorded.
    lost: u32 = 0,
    last_error: [160]u8 = undefined,
    last_error_len: usize = 0,

    pub fn open() !*Live {
        const self = try gpa.create(Live);
        errdefer gpa.destroy(self);
        self.* = .{ .remote = undefined, .registry = undefined, .env = try std.testing.environ.createMap(gpa) };
        errdefer self.env.deinit();
        self.remote = Remote.connect(gpa, path.ProcessEnv{ .map = &self.env }, .{ .app_name = "chorus-live-test" }) catch |err| switch (err) {
            error.FileNotFound, error.ConnectionRefused, error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };
        errdefer self.remote.deinit();
        self.remote.listener = .{ .ctx = self, .func = onCore };
        self.registry = try self.remote.getRegistry();
        self.registry.listener = .{ .ctx = self, .func = onRegistry };
        return self;
    }

    pub fn close(self: *Live) void {
        self.remote.deinit();
        if (self.core_name) |n| gpa.free(n);
        for (self.nodes.items) |n| gpa.free(n.name);
        self.nodes.deinit(gpa);
        self.removed.deinit(gpa);
        self.env.deinit();
        gpa.destroy(self);
    }

    fn onCore(ctx: ?*anyopaque, _: *Remote, event: Remote.CoreEvent) void {
        const self: *Live = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .info => |i| if (self.core_name == null) {
                self.core_name = gpa.dupe(u8, i.name) catch null;
            },
            .@"error" => |e| {
                self.core_errors += 1;
                const text = std.fmt.bufPrint(&self.last_error, "id={d} res={d} {s}", .{ e.id, e.res, e.message }) catch &self.last_error;
                self.last_error_len = text.len;
            },
            .done => {},
        }
    }

    fn onRegistry(ctx: ?*anyopaque, _: *Registry, event: Registry.Event) void {
        const self: *Live = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .removed => {},
            .global => |g| {
                if (std.mem.eql(u8, g.type, "PipeWire:Interface:Core")) self.core_globals += 1;
                if (std.mem.eql(u8, g.type, "PipeWire:Interface:Client")) {
                    if (g.props.get("application.name")) |app| {
                        if (std.mem.eql(u8, app, "WirePlumber")) self.wireplumber = true;
                    }
                }
                if (std.mem.eql(u8, g.type, "PipeWire:Interface:Node")) {
                    const name = g.props.get("node.name") orelse return;
                    const copy = gpa.dupe(u8, name) catch return;
                    self.nodes.append(gpa, .{ .id = g.id, .name = copy }) catch gpa.free(copy);
                }
            },
            .global_remove => |id| self.removed.append(gpa, id) catch {
                self.lost += 1;
            },
            .@"error" => {},
        }
    }

    pub fn findNode(self: *const Live, name: []const u8) ?u32 {
        for (self.nodes.items) |n| if (std.mem.eql(u8, n.name, name)) return n.id;
        return null;
    }

    pub fn wasRemoved(self: *const Live, id: u32) bool {
        return std.mem.indexOfScalar(u32, self.removed.items, id) != null;
    }

    pub fn errorText(self: *const Live) []const u8 {
        return self.last_error[0..self.last_error_len];
    }
};

pub fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Handles daemon messages for up to `ms`, and runs the data loop when it has no thread.
/// Returns early when `done` returns true.
pub fn pump(live: *Live, loop: ?*DataLoop, ms: i64, ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool) !bool {
    const deadline = nowMs() + ms;
    while (true) {
        try live.remote.dispatch();
        if (done(ctx)) return true;
        if (nowMs() >= deadline) return false;
        var pfd = [1]linux.pollfd{.{ .fd = live.remote.fd(), .events = linux.POLL.IN, .revents = 0 }};
        _ = linux.poll(&pfd, 1, 5);
        if (loop) |l| if (l.thread == null) try l.iterate(0);
    }
}

pub fn sinkName(buf: []u8, suffix: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "chorus-test-sink-{d}-{s}", .{ linux.getpid(), suffix }) catch unreachable;
}

/// The stream tests need WirePlumber to link the stream. Without it they skip.
pub fn requireWirePlumber(live: *Live) !void {
    if (!live.wireplumber) return error.SkipZigTest;
}

// The tests must not change the user's WirePlumber state.
pub const no_restore = [_][2][]const u8{
    .{ "state.restore-props", "false" },
    .{ "state.restore-target", "false" },
};

pub fn makeSink(live: *Live, name: []const u8) !*Proxy {
    const props = [_][2][]const u8{
        .{ "factory.name", "support.null-audio-sink" },
        .{ "node.name", name },
        .{ "media.class", "Audio/Sink" },
        .{ "audio.channels", "2" },
        .{ "audio.position", "[FL,FR]" },
        .{ "object.linger", "false" },
    } ++ no_restore;
    const sink = try live.remote.createObject("adapter", .node, &props);
    return sink;
}

/// Handles the messages of two connections until `done` returns true.
pub fn pumpBoth(a: *Live, b: *Live, ms: i64, ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool) !bool {
    const deadline = nowMs() + ms;
    while (true) {
        try a.remote.dispatch();
        try b.remote.dispatch();
        if (done(ctx)) return true;
        if (nowMs() >= deadline) return false;
        var pfd = [2]linux.pollfd{
            .{ .fd = a.remote.fd(), .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = b.remote.fd(), .events = linux.POLL.IN, .revents = 0 },
        };
        _ = linux.poll(&pfd, 2, 5);
    }
}

pub fn destroyOrPanic(proxy: *Proxy) void {
    proxy.destroy() catch |err| std.debug.panic("destroy failed: {t}", .{err});
}
