//! The registry object. It reports the globals of the server.
const std = @import("std");
const pod = @import("pod.zig");
const Connection = @import("Connection.zig");
const Proxy = @import("Proxy.zig");
const Remote = @import("Remote.zig");

const Registry = @This();

proxy: Proxy,
listener: ?Listener = null,

pub const interface: Proxy.Interface = .registry;

/// Strings and the dict are valid only during the call.
/// New variants may be added. Switch with an `else` arm.
pub const Event = union(enum) {
    removed,
    global: struct { id: u32, permissions: u32, type: []const u8, version: u32, props: pod.Dict },
    global_remove: u32,
    @"error": Proxy.ErrorInfo,
};

pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, registry: *Registry, event: Event) void,
};

/// Forwards a core error for this registry to the listener. The listener may destroy the
/// registry, so nothing touches it afterwards.
pub fn onError(proxy: *Proxy, info: Proxy.ErrorInfo) void {
    const self: *Registry = @fieldParentPtr("proxy", proxy);
    if (self.listener) |l| l.func(l.ctx, self, .{ .@"error" = info });
}

/// Tells the listener that the server removed the object. The listener may destroy it.
pub fn onRemoved(proxy: *Proxy) void {
    const self: *Registry = @fieldParentPtr("proxy", proxy);
    if (self.listener) |l| l.func(l.ctx, self, .removed);
}

pub fn handle(proxy: *Proxy, msg: Connection.Message) Remote.HandleError!void {
    const self: *Registry = @fieldParentPtr("proxy", proxy);
    var a = try Proxy.args(msg);
    const event: Event = switch (msg.opcode) {
        0 => .{ .global = .{
            .id = try a.uint(),
            .permissions = try a.uint(),
            .type = try a.string(),
            .version = try a.uint(),
            .props = try a.dict(),
        } },
        1 => .{ .global_remove = try a.uint() },
        else => {
            proxy.remote.stats.dropped += 1;
            return;
        },
    };
    if (self.listener) |l| l.func(l.ctx, self, event);
}

/// `T` is an interface struct such as `Node`. It has `interface` and `proxy`.
pub fn bind(self: *Registry, global_id: u32, comptime T: type, version: ?u32) Remote.SendError!*T {
    const remote = self.proxy.remote;
    const v = version orelse Proxy.defaultVersion(T.interface);
    const t = try remote.newProxy(T, T.interface, v);
    errdefer remote.release(&t.proxy);
    t.proxy.bind_id = global_id;

    var buf: [256]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(global_id));
    try b.string(Proxy.typeName(T.interface));
    try b.int(@bitCast(v));
    try b.int(@bitCast(t.proxy.id));
    b.end(f);
    try remote.sendBody(self.proxy.id, 1, b.bytesWritten());
    return t;
}

pub fn destroyGlobal(self: *Registry, global_id: u32) Remote.SendError!void {
    var buf: [32]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(global_id));
    b.end(f);
    try self.proxy.remote.sendBody(self.proxy.id, 2, b.bytesWritten());
}
