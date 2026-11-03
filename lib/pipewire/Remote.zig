//! A client of the PipeWire daemon. It owns the connection, the table of proxies and the
//! memory blocks, and it routes every message to the right object.
const std = @import("std");
const linux = std.os.linux;
const path = @import("path.zig");
const pod = @import("pod.zig");
const Connection = @import("Connection.zig");
const Proxy = @import("Proxy.zig");
const Registry = @import("Registry.zig");
const MemPool = @import("MemPool.zig");
const ClientNode = @import("ClientNode.zig");

const Remote = @This();

pub const Options = struct {
    app_name: []const u8,
    props: []const [2][]const u8 = &.{},
    /// The remote name. PIPEWIRE_REMOTE wins over it.
    path: ?[:0]const u8 = null,
};

pub const ConnectError = Connection.Error || path.Error;
pub const SendError = error{ OutOfMemory, NoSpace, Disconnected, Protocol, Unexpected };
pub const HandleError = pod.Error || error{ OutOfMemory, Protocol };
/// `Reentrant` means a listener called `dispatch` or `roundtrip`.
pub const DispatchError = error{ OutOfMemory, Disconnected, Protocol, Unexpected, Reentrant };
pub const RoundtripError = DispatchError || error{Timeout};

pub const CoreInfo = struct {
    cookie: u32,
    version: []const u8,
    name: []const u8,
    props: pod.Dict,
};

/// Strings and dicts in an event are valid only during the call.
/// New variants may be added. Switch with an `else` arm.
pub const CoreEvent = union(enum) {
    info: CoreInfo,
    done: struct { id: u32, seq: i32 },
    @"error": struct { id: u32, seq: i32, res: i32, message: []const u8 },
};

pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, remote: *Remote, event: CoreEvent) void,
};

pub const Stats = struct {
    /// Messages for an id that has no live proxy.
    dropped: u64 = 0,
    /// Messages with a body that did not decode.
    bad: u64 = 0,
    /// Flushes that failed while `dispatch` reported a protocol error. The next call reports the
    /// broken connection.
    flush_failures: u64 = 0,
};

const Slot = union(enum) {
    free,
    /// Core and Client.
    fixed,
    proxy: *Proxy,
};

const hello_version = 4;
const sync_flag = 1 << 30;

gpa: std.mem.Allocator,
conn: Connection,
slots: std.ArrayList(Slot) = .empty,
listener: ?Listener = null,
mem: MemPool,
stats: Stats = .{},
wait_seq: i32 = 0,
wait_hit: bool = false,
waiters: ?*SyncWaiter = null,
dispatching: bool = false,

pub fn connect(gpa: std.mem.Allocator, env: anytype, options: Options) ConnectError!*Remote {
    var buf: [108]u8 = undefined;
    var fallback_buf: [108]u8 = undefined;
    const resolved = try path.resolve(&buf, env, options.path);
    const env_name: ?[]const u8 = env.get("PIPEWIRE_REMOTE");
    const name: ?[]const u8 = if (env_name != null and env_name.?.len > 0) env_name else options.path;
    const fallback = try path.fallback(&fallback_buf, name);
    return connectPaths(gpa, resolved, fallback, options);
}

/// Connects to `primary`. When that gives FileNotFound or ConnectionRefused and `fallback`
/// is a different path, it tries `fallback` once.
fn connectPaths(gpa: std.mem.Allocator, primary: [:0]const u8, fallback: ?[:0]const u8, options: Options) ConnectError!*Remote {
    const conn = Connection.connect(gpa, primary) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => blk: {
            const other = fallback orelse return err;
            if (std.mem.eql(u8, primary, other)) return err;
            break :blk try Connection.connect(gpa, other);
        },
        else => return err,
    };
    return create(gpa, conn, options);
}

/// Takes ownership of `sock`.
pub fn fromFd(gpa: std.mem.Allocator, sock: linux.fd_t, options: Options) ConnectError!*Remote {
    return create(gpa, Connection.fromFd(gpa, sock), options);
}

/// Takes ownership of `conn`, also when it fails.
fn create(gpa: std.mem.Allocator, conn: Connection, options: Options) ConnectError!*Remote {
    var owned = conn;
    const self = gpa.create(Remote) catch {
        owned.deinit();
        return error.OutOfMemory;
    };
    // From here `self.conn` owns the connection and deinitParts closes it.
    self.* = .{ .gpa = gpa, .conn = owned, .mem = MemPool.init(gpa) };
    errdefer {
        self.deinitParts();
        gpa.destroy(self);
    }
    try self.slots.appendSlice(gpa, &.{ .fixed, .fixed });
    self.handshake(options) catch |err| return switch (err) {
        error.NoSpace => error.MessageTooLarge,
        else => |e| e,
    };
    return self;
}

fn handshake(self: *Remote, options: Options) SendError!void {
    var buf: [16384]u8 = undefined;
    var b = pod.Builder.init(buf[0..64]);
    var f = try b.beginStruct();
    try b.int(hello_version);
    b.end(f);
    try self.sendBody(0, 1, b.bytesWritten());

    var pid_buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{linux.getpid()}) catch unreachable;
    b = pod.Builder.init(&buf);
    f = try b.beginStruct();
    const inner = try b.beginStruct();
    try b.int(@intCast(3 + options.props.len));
    try b.string("application.name");
    try b.string(options.app_name);
    try b.string("application.process.id");
    try b.string(pid);
    try b.string("pipewire.protocol");
    try b.string("protocol-native");
    for (options.props) |kv| {
        try b.string(kv[0]);
        try b.string(kv[1]);
    }
    b.end(inner);
    b.end(f);
    try self.sendBody(1, 2, b.bytesWritten());
    try self.flush();
}

/// Frees the remote and all its proxies. A listener must not call it, and every `Stream` must be
/// destroyed before it.
pub fn deinit(self: *Remote) void {
    std.debug.assert(!self.dispatching);
    std.debug.assert(self.waiters == null);
    const gpa = self.gpa;
    self.deinitParts();
    gpa.destroy(self);
}

fn deinitParts(self: *Remote) void {
    for (self.slots.items) |slot| switch (slot) {
        .proxy => |p| {
            if (p.handler == ClientNode.handle) {
                const node: *ClientNode = @fieldParentPtr("proxy", p);
                std.debug.assert(node.listener == null);
            }
            p.free(p);
        },
        else => {},
    };
    self.slots.deinit(self.gpa);
    self.mem.deinit();
    self.conn.deinit();
}

pub fn fd(self: *const Remote) linux.fd_t {
    return self.conn.fd();
}

fn sendError(err: Connection.Error) SendError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.MessageTooLarge, error.TooManyFds => error.NoSpace,
        error.Disconnected => error.Disconnected,
        error.Protocol => error.Protocol,
        else => error.Unexpected,
    };
}

/// Queues one message. It goes out with the next `flush` or `dispatch`.
pub fn sendBody(self: *Remote, id: u32, opcode: u8, body: []const u8) SendError!void {
    _ = self.conn.send(id, opcode, body, &.{}) catch |err| return sendError(err);
}

/// Queues one message that carries `fds`. The caller keeps its own fds.
pub fn sendBodyFds(self: *Remote, id: u32, opcode: u8, body: []const u8, fds: []const linux.fd_t) SendError!void {
    _ = self.conn.send(id, opcode, body, fds) catch |err| return sendError(err);
}

/// Writes the queued messages as far as the socket takes them.
pub fn flush(self: *Remote) SendError!void {
    _ = self.conn.flush() catch |err| return sendError(err);
}

fn dispatchError(err: Connection.Error) DispatchError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Disconnected => error.Disconnected,
        error.Protocol, error.MessageTooLarge, error.TooManyFds => error.Protocol,
        else => error.Unexpected,
    };
}

/// Writes the queued messages, then handles every message that is readable now. A message
/// with a bad body gives `error.Protocol`. The next call goes on with the next message. A
/// listener must not call `dispatch` or `roundtrip`, which give `error.Reentrant`.
pub fn dispatch(self: *Remote) DispatchError!void {
    if (self.dispatching) return error.Reentrant;
    self.dispatching = true;
    defer self.dispatching = false;
    _ = self.conn.flush() catch |err| return dispatchError(err);
    while (self.conn.receive() catch |err| return dispatchError(err)) |msg| {
        self.handleMessage(msg) catch |err| switch (err) {
            error.Truncated, error.BadPod, error.WrongType, error.Protocol => {
                self.stats.bad += 1;
                // Send what the handlers queued, for example a pong.
                _ = self.conn.flush() catch {
                    self.stats.flush_failures += 1;
                };
                return error.Protocol;
            },
            error.OutOfMemory => return error.OutOfMemory,
            error.Disconnected => return error.Disconnected,
            error.NoSpace, error.Unexpected => return error.Unexpected,
        };
    }
    _ = self.conn.flush() catch |err| return dispatchError(err);
}

/// Sends Core.sync. The seq that Core.done carries is returned.
pub fn sync(self: *Remote) SendError!i32 {
    const seq: i32 = @intCast(sync_flag | self.conn.seq);
    var buf: [48]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(0);
    try b.int(seq);
    b.end(f);
    try self.sendBody(0, 2, b.bytesWritten());
    return seq;
}

/// A pending Core.sync that calls back on its done. The caller owns the memory. It must stay
/// valid while the waiter is linked, and `cancelSync` unlinks it.
pub const SyncWaiter = struct {
    seq: i32 = 0,
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, remote: *Remote, seq: i32) void,
    next: ?*SyncWaiter = null,
    armed: bool = false,
};

/// Sends Core.sync and calls the waiter on the matching done, before the listener sees it. The
/// waiter must not be armed already.
pub fn syncFor(self: *Remote, w: *SyncWaiter) SendError!void {
    std.debug.assert(!w.armed);
    w.seq = try self.sync();
    w.next = self.waiters;
    w.armed = true;
    self.waiters = w;
}

/// Unlinks the waiter. It does nothing when the waiter is not armed.
pub fn cancelSync(self: *Remote, w: *SyncWaiter) void {
    if (!w.armed) return;
    var link: *?*SyncWaiter = &self.waiters;
    while (link.*) |cur| : (link = &cur.next) {
        if (cur == w) {
            link.* = w.next;
            break;
        }
    }
    w.next = null;
    w.armed = false;
}

fn runWaiters(self: *Remote, seq: i32) void {
    while (true) {
        var found: ?*SyncWaiter = null;
        var cur = self.waiters;
        while (cur) |w| : (cur = w.next) {
            if (w.seq == seq) {
                found = w;
                break;
            }
        }
        const w = found orelse return;
        self.cancelSync(w);
        w.func(w.ctx, self, seq);
    }
}

/// Sends Core.sync and handles messages until the matching done arrives.
pub fn roundtrip(self: *Remote, timeout_ms: i32) RoundtripError!void {
    if (self.dispatching) return error.Reentrant;
    self.wait_seq = self.sync() catch |err| switch (err) {
        error.NoSpace => return error.Unexpected,
        else => |e| return e,
    };
    self.wait_hit = false;
    const deadline = try nowMs() + timeout_ms;
    while (true) {
        try self.dispatch();
        if (self.wait_hit) return;
        const left = deadline - try nowMs();
        if (left <= 0) return error.Timeout;
        var pfd = [1]linux.pollfd{.{ .fd = self.fd(), .events = linux.POLL.IN, .revents = 0 }};
        switch (linux.errno(linux.poll(&pfd, 1, @intCast(left)))) {
            .SUCCESS, .INTR => {},
            else => return error.Unexpected,
        }
    }
}

fn nowMs() error{Unexpected}!i64 {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return error.Unexpected;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

pub fn getRegistry(self: *Remote) SendError!*Registry {
    const reg = try self.newProxy(Registry, .registry, Proxy.defaultVersion(.registry));
    errdefer self.release(&reg.proxy);
    var buf: [48]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(reg.proxy.version));
    try b.int(@bitCast(reg.proxy.id));
    b.end(f);
    try self.sendBody(0, 5, b.bytesWritten());
    return reg;
}

const Generic = struct {
    proxy: Proxy,

    pub fn handle(proxy: *Proxy, msg: Connection.Message) HandleError!void {
        _ = proxy;
        _ = msg;
    }
};

/// Sends Core.create_object. The returned proxy ignores its events.
pub fn createObject(self: *Remote, factory: []const u8, interface: Proxy.Interface, props: []const [2][]const u8) SendError!*Proxy {
    const obj = try self.createObjectAs(Generic, interface, factory, props);
    return &obj.proxy;
}

/// Sends Core.create_object for a proxy of type `T`, which gets the events of the new object.
/// `T` has the same shape as for `newProxy`.
pub fn createObjectAs(self: *Remote, comptime T: type, interface: Proxy.Interface, factory: []const u8, props: []const [2][]const u8) SendError!*T {
    const version = Proxy.defaultVersion(interface);
    const obj = try self.newProxy(T, interface, version);
    errdefer self.release(&obj.proxy);
    var size: usize = 256 + factory.len;
    for (props) |kv| size += kv[0].len + kv[1].len + 32;
    const buf = try self.gpa.alloc(u8, size);
    defer self.gpa.free(buf);
    var b = pod.Builder.init(buf);
    const f = try b.beginStruct();
    try b.string(factory);
    try b.string(Proxy.typeName(interface));
    try b.int(@bitCast(version));
    try b.dict(props);
    try b.int(@bitCast(obj.proxy.id));
    b.end(f);
    try self.sendBody(0, 6, b.bytesWritten());
    return obj;
}

/// Allocates an `T` with the lowest free id of 2 or more. `T` has a `proxy` field first, a
/// `handle` function, and defaults for its other fields.
pub fn newProxy(self: *Remote, comptime T: type, interface: Proxy.Interface, version: u32) error{OutOfMemory}!*T {
    const t = try self.gpa.create(T);
    errdefer self.gpa.destroy(t);
    const index = for (self.slots.items[2..], 2..) |slot, i| {
        if (slot == .free) break i;
    } else blk: {
        try self.slots.append(self.gpa, .free);
        break :blk self.slots.items.len - 1;
    };
    t.* = .{ .proxy = .{
        .remote = self,
        .id = @intCast(index),
        .interface = interface,
        .version = version,
        .handler = T.handle,
        .free = Proxy.freeFor(T),
        .on_error = if (@hasDecl(T, "onError")) T.onError else null,
        .on_removed = if (@hasDecl(T, "onRemoved")) T.onRemoved else null,
        .on_bound = if (@hasDecl(T, "onBound")) T.onBound else null,
    } };
    self.slots.items[index] = .{ .proxy = &t.proxy };
    return t;
}

/// True when a `ClientNode` of this remote exports the node with this global id.
pub fn exportsNode(self: *const Remote, global_id: u32) bool {
    for (self.slots.items) |slot| switch (slot) {
        .proxy => |p| if (p.handler == ClientNode.handle and p.global_id == global_id) return true,
        else => {},
    };
    return false;
}

/// Frees the proxy and its id.
pub fn release(self: *Remote, proxy: *Proxy) void {
    self.slots.items[proxy.id] = .free;
    proxy.free(proxy);
}

fn lookup(self: *Remote, id: u32) ?*Proxy {
    if (id >= self.slots.items.len) return null;
    return switch (self.slots.items[id]) {
        .proxy => |p| if (p.zombie) null else p,
        else => null,
    };
}

fn handleMessage(self: *Remote, msg: Connection.Message) (HandleError || SendError)!void {
    switch (msg.id) {
        0 => try self.handleCore(msg),
        1 => {},
        else => {
            const proxy = self.lookup(msg.id) orelse {
                self.stats.dropped += 1;
                return;
            };
            try proxy.handler(proxy, msg);
        },
    }
}

fn emit(self: *Remote, event: CoreEvent) void {
    if (self.listener) |l| l.func(l.ctx, self, event);
}

fn handleCore(self: *Remote, msg: Connection.Message) (HandleError || SendError)!void {
    var a = try Proxy.args(msg);
    switch (msg.opcode) {
        0 => {
            _ = try a.int();
            const cookie = try a.uint();
            _ = try a.string();
            _ = try a.string();
            const version = try a.string();
            const name = try a.string();
            _ = try a.long();
            const props = try a.dict();
            self.emit(.{ .info = .{ .cookie = cookie, .version = version, .name = name, .props = props } });
        },
        1 => {
            const id = try a.uint();
            const seq = try a.int();
            if (id == 0 and seq == self.wait_seq) self.wait_hit = true;
            if (id == 0) self.runWaiters(seq);
            self.emit(.{ .done = .{ .id = id, .seq = seq } });
        },
        2 => {
            const id = try a.int();
            const seq = try a.int();
            var buf: [48]u8 = undefined;
            var b = pod.Builder.init(&buf);
            const f = try b.beginStruct();
            try b.int(id);
            try b.int(seq);
            b.end(f);
            try self.sendBody(0, 3, b.bytesWritten());
        },
        3 => {
            const id = try a.uint();
            const seq = try a.int();
            const res = try a.int();
            const message = try a.string();
            self.emit(.{ .@"error" = .{ .id = id, .seq = seq, .res = res, .message = message } });
            if (self.lookup(id)) |proxy| {
                if (proxy.on_error) |f| f(proxy, .{ .seq = seq, .res = res, .message = message });
            }
        },
        4 => try self.handleRemoveId(try a.uint()),
        5 => {
            const id = try a.uint();
            const global_id = try a.uint();
            if (self.lookup(id)) |proxy| proxy.global_id = global_id else self.countDropped(id);
        },
        6 => {
            const id = try a.uint();
            const ty = try a.id();
            const index = try (try a.next()).fd();
            const flags = try a.uint();
            if (index < 0 or index >= msg.fds.len) return error.Protocol;
            const taken = self.conn.takeFd(msg, @intCast(index)) catch return error.Protocol;
            try self.mem.add(id, ty, taken, flags);
        },
        7 => self.mem.remove(try a.uint()),
        8 => {
            const id = try a.uint();
            const global_id = try a.uint();
            const props = try a.dict();
            const proxy = self.lookup(id) orelse {
                self.countDropped(id);
                return;
            };
            const copy = try Proxy.OwnedDict.init(self.gpa, props);
            if (proxy.bound_props) |*old| old.deinit(self.gpa);
            proxy.bound_props = copy;
            proxy.global_id = global_id;
            if (proxy.on_bound) |f| f(proxy);
        },
        else => self.stats.dropped += 1,
    }
}

/// The Client object has id 1 and is not a proxy, so events for it are not drops.
fn countDropped(self: *Remote, id: u32) void {
    if (id != 1) self.stats.dropped += 1;
}

fn handleRemoveId(self: *Remote, id: u32) HandleError!void {
    if (id < 2 or id >= self.slots.items.len) {
        self.stats.dropped += 1;
        return;
    }
    switch (self.slots.items[id]) {
        .proxy => |p| if (p.zombie) {
            self.release(p);
        } else {
            p.removed = true;
            if (p.on_removed) |f| f(p);
        },
        else => self.stats.dropped += 1,
    }
}

const testing = std.testing;
const Builder = pod.Builder;
const FakeServer = @import("testing/FakeServer.zig");
const Node = @import("Node.zig");
const tgpa = testing.allocator;

const util = @import("testing/util.zig");
const Rig = @import("testing/Rig.zig");
const fieldsOf = util.fieldsOf;
const nextInt = util.nextInt;
const ints = util.ints;
const expectQuiet = util.expectQuiet;

const Rec = struct {
    errors: u32 = 0,
    err_id: u32 = 0,
    err_res: i32 = 0,
    err_message_ok: bool = false,
    globals: u32 = 0,
    global_id: u32 = 0,
    global_perm: u32 = 0,
    global_version: u32 = 0,
    global_type_ok: bool = false,
    global_name_ok: bool = false,
    removed: u32 = 0,
    removed_id: u32 = 0,
    proxy_removed: u32 = 0,
    reg_errors: u32 = 0,
    reg_err_seq: i32 = 0,
    reg_err_res: i32 = 0,
    reg_err_message_ok: bool = false,

    fn onCore(ctx: ?*anyopaque, remote: *Remote, event: Remote.CoreEvent) void {
        _ = remote;
        const self: *Rec = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .@"error" => |e| {
                self.errors += 1;
                self.err_id = e.id;
                self.err_res = e.res;
                self.err_message_ok = std.mem.eql(u8, e.message, "boom");
            },
            else => {},
        }
    }

    fn onRegistry(ctx: ?*anyopaque, registry: *Registry, event: Registry.Event) void {
        _ = registry;
        const self: *Rec = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .removed => self.proxy_removed += 1,
            .global => |g| {
                self.globals += 1;
                self.global_id = g.id;
                self.global_perm = g.permissions;
                self.global_version = g.version;
                self.global_type_ok = std.mem.eql(u8, g.type, "PipeWire:Interface:Node");
                self.global_name_ok = std.mem.eql(u8, g.props.get("node.name") orelse "", "x");
            },
            .global_remove => |id| {
                self.removed += 1;
                self.removed_id = id;
            },
            .@"error" => |e| {
                self.reg_errors += 1;
                self.reg_err_seq = e.seq;
                self.reg_err_res = e.res;
                self.reg_err_message_ok = std.mem.eql(u8, e.message, "boom");
            },
        }
    }
};

fn globalBody(buf: []u8, id: i32, ty: []const u8, version: i32) []const u8 {
    var b = Builder.init(buf);
    const f = b.beginStruct() catch unreachable;
    b.int(id) catch unreachable;
    b.int(0o400) catch unreachable;
    b.string(ty) catch unreachable;
    b.int(version) catch unreachable;
    b.dict(&.{.{ "node.name", "x" }}) catch unreachable;
    b.end(f);
    return b.bytesWritten();
}

test "connect sends hello and update_properties" {
    var rig = try Rig.initWith(.{ .get_registry = false, .app_props = &.{.{ "extra.key", "extra value" }} });
    defer rig.deinit();

    var hello = try rig.server.expect(0, 1);
    defer hello.deinit(tgpa);
    var hit = try fieldsOf(hello.body);
    try testing.expectEqual(@as(i32, 4), try nextInt(&hit));

    var up = try rig.server.expect(1, 2);
    defer up.deinit(tgpa);
    var uit = try fieldsOf(up.body);
    const d = try pod.Dict.parse((try uit.next()).?);
    try testing.expectEqualStrings("chorus-test", d.get("application.name").?);
    try testing.expectEqualStrings("protocol-native", d.get("pipewire.protocol").?);
    try testing.expectEqualStrings("extra value", d.get("extra.key").?);
    try testing.expect(d.get("application.process.id") != null);
}

test "roundtrip ends on the done with the same seq" {
    var rig = try Rig.initWith(.{ .get_registry = false });
    defer rig.deinit();
    try rig.skipHandshake();
    var buf: [64]u8 = undefined;

    try rig.server.send(0, 1, ints(&buf, &.{ 0, 5 }), &.{});
    try testing.expectError(error.Timeout, rig.remote.roundtrip(200));
    var s1 = try rig.server.expect(0, 2);
    defer s1.deinit(tgpa);
    var it1 = try fieldsOf(s1.body);
    try testing.expectEqual(@as(i32, 0), try nextInt(&it1));
    try testing.expectEqual(@as(i32, (1 << 30) | 2), try nextInt(&it1));

    try rig.server.send(0, 1, ints(&buf, &.{ 0, (1 << 30) | 3 }), &.{});
    try rig.remote.roundtrip(2000);
    var s2 = try rig.server.expect(0, 2);
    defer s2.deinit(tgpa);
    var it2 = try fieldsOf(s2.body);
    _ = try nextInt(&it2);
    try testing.expectEqual(@as(i32, (1 << 30) | 3), try nextInt(&it2));
}

test "ping is answered with pong" {
    var rig = try Rig.initWith(.{ .get_registry = false });
    defer rig.deinit();
    try rig.skipHandshake();
    var buf: [64]u8 = undefined;

    try rig.server.send(0, 2, ints(&buf, &.{ 7, 3 }), &.{});
    try rig.remote.dispatch();
    var pong = try rig.server.expect(0, 3);
    defer pong.deinit(tgpa);
    var it = try fieldsOf(pong.body);
    try testing.expectEqual(@as(i32, 7), try nextInt(&it));
    try testing.expectEqual(@as(i32, 3), try nextInt(&it));
}

test "registry events reach the listener" {
    var rig = try Rig.initWith(.{ .get_registry = false });
    defer rig.deinit();
    try rig.skipHandshake();
    var buf: [256]u8 = undefined;

    const reg = try rig.remote.getRegistry();
    try rig.remote.dispatch();
    var m = try rig.server.expect(0, 5);
    defer m.deinit(tgpa);
    var it = try fieldsOf(m.body);
    try testing.expectEqual(@as(i32, 3), try nextInt(&it));
    try testing.expectEqual(@as(i32, 2), try nextInt(&it));
    try testing.expectEqual(@as(u32, 2), reg.proxy.id);

    var rec: Rec = .{};
    reg.listener = .{ .ctx = &rec, .func = Rec.onRegistry };
    try rig.server.send(2, 0, globalBody(&buf, 31, "PipeWire:Interface:Node", 3), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 1), rec.globals);
    try testing.expectEqual(@as(u32, 31), rec.global_id);
    try testing.expectEqual(@as(u32, 0o400), rec.global_perm);
    try testing.expectEqual(@as(u32, 3), rec.global_version);
    try testing.expect(rec.global_type_ok);
    try testing.expect(rec.global_name_ok);

    try rig.server.send(2, 1, ints(&buf, &.{31}), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 1), rec.removed);
    try testing.expectEqual(@as(u32, 31), rec.removed_id);
}

test "bind sends Registry.bind and bound_id sets the global id" {
    var rig = try Rig.initWith(.{ .get_registry = false });
    defer rig.deinit();
    try rig.skipHandshake();
    var buf: [64]u8 = undefined;

    const reg = try rig.remote.getRegistry();
    const node = try reg.bind(31, Node, null);
    try testing.expectEqual(@as(u32, 3), node.proxy.id);
    try testing.expectEqual(@as(u32, 3), node.proxy.version);
    try testing.expectEqual(@as(?u32, null), node.proxy.global_id);
    try rig.remote.dispatch();

    var get = try rig.server.expect(0, 5);
    get.deinit(tgpa);
    var m = try rig.server.expect(2, 1);
    defer m.deinit(tgpa);
    var it = try fieldsOf(m.body);
    try testing.expectEqual(@as(i32, 31), try nextInt(&it));
    try testing.expectEqualStrings("PipeWire:Interface:Node", (try (try it.next()).?.string()).?);
    try testing.expectEqual(@as(i32, 3), try nextInt(&it));
    try testing.expectEqual(@as(i32, 3), try nextInt(&it));

    try rig.server.send(0, 5, ints(&buf, &.{ 3, 31 }), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(?u32, 31), node.proxy.global_id);
}

test "an id is reused only after remove_id" {
    var rig = try Rig.initWith(.{ .get_registry = false });
    defer rig.deinit();
    try rig.skipHandshake();
    var buf: [64]u8 = undefined;

    const first = try rig.remote.createObject("adapter", .node, &.{});
    try testing.expectEqual(@as(u32, 2), first.id);
    try first.destroy();
    try testing.expect(first.zombie);
    const second = try rig.remote.createObject("adapter", .node, &.{});
    try testing.expectEqual(@as(u32, 3), second.id);

    try rig.server.send(0, 4, ints(&buf, &.{2}), &.{});
    try rig.remote.dispatch();
    const third = try rig.remote.createObject("adapter", .node, &.{});
    try testing.expectEqual(@as(u32, 2), third.id);

    var created = try rig.server.expect(0, 6);
    created.deinit(tgpa);
    var destroy = try rig.server.expect(0, 7);
    defer destroy.deinit(tgpa);
    var it = try fieldsOf(destroy.body);
    try testing.expectEqual(@as(i32, 2), try nextInt(&it));
}

test "add_mem stores the fd and remove_mem closes it" {
    var rig = try Rig.initWith(.{ .get_registry = false });
    defer rig.deinit();
    try rig.skipHandshake();
    var buf: [128]u8 = undefined;

    var pair: [2]std.os.linux.fd_t = undefined;
    const rc = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC, 0, &pair);
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
    defer _ = std.os.linux.close(pair[1]);

    var b = Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(9);
    try b.id(2);
    try b.fd(0);
    try b.int(3);
    b.end(f);
    try rig.server.send(0, 6, b.bytesWritten(), &.{pair[0]});
    _ = std.os.linux.close(pair[0]);
    try rig.remote.dispatch();

    const entry = rig.remote.mem.get(9).?;
    try testing.expectEqual(@as(u32, 2), entry.type);
    try testing.expectEqual(@as(u32, 3), entry.flags);
    try testing.expect(entry.fd >= 0);

    try rig.server.send(0, 7, ints(&buf, &.{9}), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(?MemPool.Entry, null), rig.remote.mem.get(9));
    var one: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), std.os.linux.read(pair[1], &one, 1));
}

test "a truncated body is a protocol error and the connection stays usable" {
    var rig = try Rig.initWith(.{ .get_registry = false });
    defer rig.deinit();
    try rig.skipHandshake();
    var buf: [64]u8 = undefined;

    _ = try rig.remote.getRegistry();
    try rig.server.send(2, 0, ints(&buf, &.{31}), &.{});
    try testing.expectError(error.Protocol, rig.remote.dispatch());
    try testing.expectEqual(@as(u64, 1), rig.remote.stats.bad);

    try rig.server.send(0, 2, ints(&buf, &.{ 1, 2 }), &.{});
    try rig.remote.dispatch();
    var get = try rig.server.expect(0, 5);
    get.deinit(tgpa);
    var pong = try rig.server.expect(0, 3);
    defer pong.deinit(tgpa);
    var it = try fieldsOf(pong.body);
    try testing.expectEqual(@as(i32, 1), try nextInt(&it));
    try testing.expectEqual(@as(i32, 2), try nextInt(&it));
}

test "a message for an unknown id is counted and skipped" {
    var rig = try Rig.initWith(.{ .get_registry = false });
    defer rig.deinit();
    try rig.skipHandshake();
    var buf: [64]u8 = undefined;

    try rig.server.send(9, 0, ints(&buf, &.{1}), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(u64, 1), rig.remote.stats.dropped);
    try testing.expectEqual(@as(u64, 0), rig.remote.stats.bad);
}

test "a core error for a proxy goes to its on_error and the core listener" {
    var rig = try Rig.initWith(.{ .get_registry = false });
    defer rig.deinit();
    try rig.skipHandshake();
    var buf: [128]u8 = undefined;

    var rec: Rec = .{};
    rig.remote.listener = .{ .ctx = &rec, .func = Rec.onCore };
    const reg = try rig.remote.getRegistry();
    reg.listener = .{ .ctx = &rec, .func = Rec.onRegistry };

    var b = Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(2);
    try b.int(5);
    try b.int(-2);
    try b.string("boom");
    b.end(f);
    try rig.server.send(0, 3, b.bytesWritten(), &.{});
    try rig.remote.dispatch();

    try testing.expectEqual(@as(u32, 1), rec.errors);
    try testing.expectEqual(@as(u32, 2), rec.err_id);
    try testing.expectEqual(@as(i32, -2), rec.err_res);
    try testing.expect(rec.err_message_ok);
    try testing.expectEqual(@as(u32, 1), rec.reg_errors);
    try testing.expectEqual(@as(i32, 5), rec.reg_err_seq);
    try testing.expectEqual(@as(i32, -2), rec.reg_err_res);
    try testing.expect(rec.reg_err_message_ok);
    try testing.expectEqual(@as(u64, 0), rig.remote.stats.dropped);
}

test "a failed handshake frees the connection once" {
    var server = try FakeServer.init(tgpa);
    const client_fd = server.client_fd;
    _ = std.os.linux.close(server.server_fd);
    server.server_fd = -1;
    defer server.deinit();
    try testing.expectError(error.Disconnected, Remote.fromFd(tgpa, client_fd, .{ .app_name = "x" }));
    // The client end is closed already.
    try testing.expectEqual(std.os.linux.E.BADF, std.os.linux.errno(std.os.linux.fcntl(client_fd, std.os.linux.F.GETFD, 0)));
}

test "remove_id before destroy frees at once and sends nothing" {
    var rig = try Rig.initWith(.{ .get_registry = false });
    defer rig.deinit();
    try rig.skipHandshake();
    var buf: [64]u8 = undefined;

    const p = try rig.remote.createObject("adapter", .node, &.{});
    try testing.expectEqual(@as(u32, 2), p.id);
    try rig.remote.dispatch();
    var created = try rig.server.expect(0, 6);
    created.deinit(tgpa);

    try rig.server.send(0, 4, ints(&buf, &.{2}), &.{});
    try rig.remote.dispatch();
    try testing.expect(p.removed);
    try testing.expect(!p.zombie);
    try p.destroy();
    try rig.remote.dispatch();
    try expectQuiet(&rig.server, 100);
    try testing.expect(rig.remote.slots.items[2] == .free);
    const next = try rig.remote.createObject("adapter", .node, &.{});
    try testing.expectEqual(@as(u32, 2), next.id);
}

test "a zombie proxy gets no events" {
    var rig = try Rig.initWith(.{ .get_registry = false });
    defer rig.deinit();
    try rig.skipHandshake();
    var buf: [256]u8 = undefined;

    var rec: Rec = .{};
    const reg = try rig.remote.getRegistry();
    reg.listener = .{ .ctx = &rec, .func = Rec.onRegistry };
    try reg.proxy.destroy();
    try testing.expect(reg.proxy.zombie);

    try rig.server.send(2, 0, globalBody(&buf, 31, "PipeWire:Interface:Node", 3), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 0), rec.globals);
    try testing.expectEqual(@as(u64, 1), rig.remote.stats.dropped);
}

test "bound_props sets the global id and keeps the props" {
    var rig = try Rig.initWith(.{ .get_registry = false });
    defer rig.deinit();
    try rig.skipHandshake();
    var buf: [256]u8 = undefined;

    const reg = try rig.remote.getRegistry();
    const node = try reg.bind(31, Node, null);
    var b = Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(3);
    try b.int(31);
    try b.dict(&.{.{ "node.name", "x" }});
    b.end(f);
    try rig.server.send(0, 8, b.bytesWritten(), &.{});
    try rig.remote.dispatch();

    try testing.expectEqual(@as(?u32, 31), node.proxy.global_id);
    try testing.expectEqualStrings("x", node.proxy.bound_props.?.dict().get("node.name").?);
}

fn socketPath(buf: *[108]u8, sub_path: []const u8, name: []const u8) [:0]const u8 {
    const s = std.fmt.bufPrint(buf[0..107], ".zig-cache/tmp/{s}/{s}", .{ sub_path, name }) catch unreachable;
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

fn bindSocket(p: [:0]const u8, do_listen: bool) !linux.fd_t {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const sock: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(sock);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..p.len], p);
    const len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + p.len + 1);
    if (linux.errno(linux.bind(sock, @ptrCast(&addr), len)) != .SUCCESS) return error.BindFailed;
    if (do_listen and linux.errno(linux.listen(sock, 4)) != .SUCCESS) return error.ListenFailed;
    return sock;
}

fn acceptServer(listener: linux.fd_t) !FakeServer {
    const rc = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.AcceptFailed;
    return .{ .gpa = tgpa, .client_fd = -1, .server_fd = @intCast(rc) };
}

fn expectHello(listener: linux.fd_t) !void {
    var server = try acceptServer(listener);
    defer server.deinit();
    var hello = try server.expect(0, 1);
    hello.deinit(tgpa);
}

test "connect resolves the socket in PIPEWIRE_RUNTIME_DIR" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [108]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;
    var buf: [108]u8 = undefined;
    const listener = try bindSocket(socketPath(&buf, &tmp.sub_path, "pipewire-0"), true);
    defer _ = linux.close(listener);

    const Env = struct {
        dir: []const u8,
        pub fn get(self: @This(), key: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, key, "PIPEWIRE_RUNTIME_DIR")) self.dir else null;
        }
    };
    const remote = try Remote.connect(tgpa, Env{ .dir = dir }, .{ .app_name = "t" });
    defer remote.deinit();
    try expectHello(listener);
}

test "connectPaths uses the fallback when the primary is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [108]u8 = undefined;
    var buf2: [108]u8 = undefined;
    const missing = socketPath(&buf, &tmp.sub_path, "missing");
    const live = socketPath(&buf2, &tmp.sub_path, "live");
    const listener = try bindSocket(live, true);
    defer _ = linux.close(listener);

    const remote = try Remote.connectPaths(tgpa, missing, live, .{ .app_name = "t" });
    defer remote.deinit();
    try expectHello(listener);
}

test "connectPaths uses the fallback when the primary is stale" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [108]u8 = undefined;
    var buf2: [108]u8 = undefined;
    const stale_path = socketPath(&buf, &tmp.sub_path, "stale");
    const live = socketPath(&buf2, &tmp.sub_path, "live");
    const stale = try bindSocket(stale_path, false);
    defer _ = linux.close(stale);
    const listener = try bindSocket(live, true);
    defer _ = linux.close(listener);

    const remote = try Remote.connectPaths(tgpa, stale_path, live, .{ .app_name = "t" });
    defer remote.deinit();
    try expectHello(listener);
}

test "connectPaths gives the original error when primary equals fallback" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [108]u8 = undefined;
    const missing = socketPath(&buf, &tmp.sub_path, "missing");
    try testing.expectError(error.FileNotFound, Remote.connectPaths(tgpa, missing, missing, .{ .app_name = "t" }));
    try testing.expectError(error.FileNotFound, Remote.connectPaths(tgpa, missing, null, .{ .app_name = "t" }));
}

test "remove_id before destroy tells the listener" {
    var rig = try Rig.initWith(.{ .get_registry = false });
    defer rig.deinit();
    try rig.skipHandshake();
    var buf: [64]u8 = undefined;

    var rec: Rec = .{};
    const reg = try rig.remote.getRegistry();
    reg.listener = .{ .ctx = &rec, .func = Rec.onRegistry };
    try rig.server.send(0, 4, ints(&buf, &.{@intCast(reg.proxy.id)}), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 1), rec.proxy_removed);
    try testing.expect(reg.proxy.removed);

    // The proxy of a destroy that is in flight is a zombie and gets no notice.
    const node = try rig.remote.createObject("adapter", .node, &.{});
    try node.destroy();
    try rig.server.send(0, 4, ints(&buf, &.{@intCast(node.id)}), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 1), rec.proxy_removed);
}

const Nested = struct {
    dispatch_err: ?anyerror = null,
    roundtrip_err: ?anyerror = null,

    fn onRegistry(ctx: ?*anyopaque, registry: *Registry, event: Registry.Event) void {
        const self: *Nested = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .global => {
                registry.proxy.remote.dispatch() catch |err| {
                    self.dispatch_err = err;
                };
                registry.proxy.remote.roundtrip(10) catch |err| {
                    self.roundtrip_err = err;
                };
            },
            else => {},
        }
    }
};

test "dispatch and roundtrip called from a listener give Reentrant" {
    var rig = try Rig.initWith(.{ .get_registry = false });
    defer rig.deinit();
    try rig.skipHandshake();
    var buf: [256]u8 = undefined;

    var nested: Nested = .{};
    const reg = try rig.remote.getRegistry();
    reg.listener = .{ .ctx = &nested, .func = Nested.onRegistry };
    try rig.server.send(2, 0, globalBody(&buf, 31, "PipeWire:Interface:Node", 3), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(?anyerror, error.Reentrant), nested.dispatch_err);
    try testing.expectEqual(@as(?anyerror, error.Reentrant), nested.roundtrip_err);

    // The flag is clear again and the connection works.
    try testing.expect(!rig.remote.dispatching);
    try rig.server.send(0, 1, ints(&buf, &.{ 0, 5 }), &.{});
    try rig.remote.dispatch();
}

test "a flush that fails after a protocol error is counted" {
    var rig = try Rig.initWith(.{ .get_registry = false });
    defer rig.deinit();
    try rig.skipHandshake();
    var buf: [64]u8 = undefined;

    _ = try rig.remote.getRegistry();
    try rig.remote.flush();
    var get = try rig.server.expect(0, 5);
    get.deinit(tgpa);
    // The ping queues a pong. The truncated event after it is a protocol error.
    try rig.server.send(0, 2, ints(&buf, &.{ 1, 2 }), &.{});
    try rig.server.send(2, 0, ints(&buf, &.{31}), &.{});
    _ = linux.close(rig.server.server_fd);
    rig.server.server_fd = -1;
    try testing.expectError(error.Protocol, rig.remote.dispatch());
    try testing.expectEqual(@as(u64, 1), rig.remote.stats.flush_failures);
}

const SyncRec = struct {
    order: [4]i32 = undefined,
    n: usize = 0,
    dones: u32 = 0,

    fn onWaiter(ctx: ?*anyopaque, remote: *Remote, seq: i32) void {
        _ = remote;
        const self: *SyncRec = @ptrCast(@alignCast(ctx.?));
        self.order[self.n] = seq;
        self.n += 1;
    }

    fn onCore(ctx: ?*anyopaque, remote: *Remote, event: Remote.CoreEvent) void {
        _ = remote;
        const self: *SyncRec = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .done => self.dones += 1,
            else => {},
        }
    }
};

test "sync waiters run on their own done and the listener still sees it" {
    var rig = try Rig.initWith(.{ .get_registry = false });
    defer rig.deinit();
    try rig.skipHandshake();
    var rec: SyncRec = .{};
    rig.remote.listener = .{ .ctx = &rec, .func = SyncRec.onCore };
    var a: SyncWaiter = .{ .ctx = &rec, .func = SyncRec.onWaiter };
    var b: SyncWaiter = .{ .ctx = &rec, .func = SyncRec.onWaiter };
    var c: SyncWaiter = .{ .ctx = &rec, .func = SyncRec.onWaiter };
    try rig.remote.syncFor(&a);
    try rig.remote.syncFor(&b);
    try rig.remote.syncFor(&c);
    try testing.expect(a.seq != b.seq and b.seq != c.seq);
    rig.remote.cancelSync(&c);
    rig.remote.cancelSync(&c);

    var buf: [64]u8 = undefined;
    try rig.server.send(0, 1, ints(&buf, &.{ 0, b.seq }), &.{});
    try rig.remote.dispatch();
    try testing.expectEqualSlices(i32, &.{b.seq}, rec.order[0..rec.n]);
    try testing.expectEqual(@as(u32, 1), rec.dones);

    // A done for the cancelled waiter and a repeated done call nobody.
    try rig.server.send(0, 1, ints(&buf, &.{ 0, c.seq }), &.{});
    try rig.server.send(0, 1, ints(&buf, &.{ 0, b.seq }), &.{});
    try rig.server.send(0, 1, ints(&buf, &.{ 0, a.seq }), &.{});
    try rig.remote.dispatch();
    try testing.expectEqualSlices(i32, &.{ b.seq, a.seq }, rec.order[0..rec.n]);
    try testing.expectEqual(@as(u32, 4), rec.dones);
    try testing.expect(rig.remote.waiters == null);
}
