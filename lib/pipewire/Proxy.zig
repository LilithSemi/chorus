//! The client side of one object on the server. Interface structs have a `Proxy` as their
//! first field and get back to themselves with `@fieldParentPtr`.
const std = @import("std");
const pod = @import("pod.zig");
const Connection = @import("Connection.zig");
const Remote = @import("Remote.zig");

const Proxy = @This();

remote: *Remote,
id: u32,
interface: Interface,
version: u32,
/// Set by bound_id or bound_props.
global_id: ?u32 = null,
/// The global id that `Registry.bind` asked for.
bind_id: ?u32 = null,
bound_props: ?OwnedDict = null,
/// `destroy` was called. The proxy is freed when remove_id arrives.
zombie: bool = false,
/// The server removed the object before the client destroyed it.
removed: bool = false,
/// Gets the messages addressed to this id. It does not get core errors, see `on_error`. The
/// handler or a listener it calls may destroy this proxy, so the code must not touch the
/// proxy after the listener returns.
handler: *const fn (proxy: *Proxy, msg: Connection.Message) Remote.HandleError!void,
free: *const fn (proxy: *Proxy) void,
/// Called for a core error that names this id.
on_error: ?*const fn (proxy: *Proxy, info: ErrorInfo) void = null,
/// Called when the server removes the object before `destroy`. The listener may destroy the
/// proxy, so nothing touches it afterwards.
on_removed: ?*const fn (proxy: *Proxy) void = null,
/// Called when bound_props gave the proxy its global id and properties.
on_bound: ?*const fn (proxy: *Proxy) void = null,

pub const ErrorInfo = struct { seq: i32, res: i32, message: []const u8 };

pub const Interface = enum { core, client, registry, node, device, port, link, metadata, client_node };

pub fn typeName(i: Interface) []const u8 {
    return switch (i) {
        .core => "PipeWire:Interface:Core",
        .client => "PipeWire:Interface:Client",
        .registry => "PipeWire:Interface:Registry",
        .node => "PipeWire:Interface:Node",
        .device => "PipeWire:Interface:Device",
        .port => "PipeWire:Interface:Port",
        .link => "PipeWire:Interface:Link",
        .metadata => "PipeWire:Interface:Metadata",
        .client_node => "PipeWire:Interface:ClientNode",
    };
}

pub fn defaultVersion(i: Interface) u32 {
    return switch (i) {
        .core => 4,
        .client_node => 6,
        else => 3,
    };
}

/// A copy of a dict that the message does not own.
pub const OwnedDict = struct {
    n: u32,
    items: []u8,

    pub fn init(gpa: std.mem.Allocator, d: pod.Dict) error{OutOfMemory}!OwnedDict {
        return .{ .n = d.n, .items = try gpa.dupe(u8, d.items) };
    }

    pub fn deinit(self: *OwnedDict, gpa: std.mem.Allocator) void {
        gpa.free(self.items);
        self.* = undefined;
    }

    pub fn dict(self: OwnedDict) pod.Dict {
        return .{ .n = self.n, .items = self.items };
    }
};

/// Sends Core.destroy. After the server answers with remove_id the proxy is freed, so do not
/// use it after that. A proxy that the server removed already is freed at once.
pub fn destroy(self: *Proxy) Remote.SendError!void {
    if (self.zombie) return;
    const remote = self.remote;
    if (self.removed) {
        remote.release(self);
        return;
    }
    var buf: [32]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(self.id));
    b.end(f);
    try remote.sendBody(0, 7, b.bytesWritten());
    self.zombie = true;
}

/// The `free` function for interface struct `T`.
pub fn freeFor(comptime T: type) *const fn (proxy: *Proxy) void {
    return struct {
        fn free(proxy: *Proxy) void {
            const gpa = proxy.remote.gpa;
            const t: *T = @fieldParentPtr("proxy", proxy);
            if (proxy.bound_props) |*p| p.deinit(gpa);
            if (@hasDecl(T, "deinit")) t.deinit();
            gpa.destroy(t);
        }
    }.free;
}

/// The fields of the first pod of a message body, which must be a Struct. A footer is ignored.
pub const Args = struct {
    it: pod.StructIter,

    pub fn next(self: *Args) pod.Error!pod.Pod {
        return (try self.it.next()) orelse error.Truncated;
    }

    pub fn int(self: *Args) pod.Error!i32 {
        return (try self.next()).int();
    }

    pub fn uint(self: *Args) pod.Error!u32 {
        return @bitCast(try self.int());
    }

    pub fn id(self: *Args) pod.Error!u32 {
        return (try self.next()).id();
    }

    pub fn long(self: *Args) pod.Error!i64 {
        return (try self.next()).long();
    }

    /// A None pod gives an empty string.
    pub fn string(self: *Args) pod.Error![]const u8 {
        return (try (try self.next()).string()) orelse "";
    }

    /// A None pod gives null.
    pub fn optString(self: *Args) pod.Error!?[]const u8 {
        return (try self.next()).string();
    }

    /// A None pod gives null.
    pub fn optPod(self: *Args) pod.Error!?pod.Pod {
        const p = try self.next();
        return if (p.type == .none) null else p;
    }

    pub fn dict(self: *Args) pod.Error!pod.Dict {
        return pod.Dict.parse(try self.next());
    }
};

pub fn args(msg: Connection.Message) pod.Error!Args {
    const parsed = try pod.Pod.parse(msg.body);
    return .{ .it = try parsed.pod.structIter() };
}
