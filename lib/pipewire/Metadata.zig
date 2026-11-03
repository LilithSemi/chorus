//! A bound Metadata object.
const std = @import("std");
const pod = @import("pod.zig");
const Connection = @import("Connection.zig");
const Proxy = @import("Proxy.zig");
const Remote = @import("Remote.zig");

const Metadata = @This();

proxy: Proxy,
listener: ?Listener = null,

pub const interface: Proxy.Interface = .metadata;

pub const Property = struct {
    subject: u32,
    key: ?[]const u8,
    type: ?[]const u8,
    value: ?[]const u8,
};

/// A null value removes the key. A null key removes every key of the subject. The strings
/// borrow the message bytes and are valid only during the listener call.
/// New variants may be added. Switch with an `else` arm.
pub const Event = union(enum) {
    removed,
    property: Property,
    @"error": Proxy.ErrorInfo,
};

pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, metadata: *Metadata, event: Event) void,
};

/// Forwards a core error for this metadata to the listener. The listener may destroy the
/// metadata, so nothing touches it afterwards.
pub fn onError(proxy: *Proxy, err: Proxy.ErrorInfo) void {
    const self: *Metadata = @fieldParentPtr("proxy", proxy);
    if (self.listener) |l| l.func(l.ctx, self, .{ .@"error" = err });
}

/// Tells the listener that the server removed the object. The listener may destroy it.
pub fn onRemoved(proxy: *Proxy) void {
    const self: *Metadata = @fieldParentPtr("proxy", proxy);
    if (self.listener) |l| l.func(l.ctx, self, .removed);
}

pub fn handle(proxy: *Proxy, msg: Connection.Message) Remote.HandleError!void {
    const self: *Metadata = @fieldParentPtr("proxy", proxy);
    var a = try Proxy.args(msg);
    const event: Event = switch (msg.opcode) {
        0 => .{ .property = .{
            .subject = try a.uint(),
            .key = try a.optString(),
            .type = try a.optString(),
            .value = try a.optString(),
        } },
        else => {
            proxy.remote.stats.dropped += 1;
            return;
        },
    };
    if (self.listener) |l| l.func(l.ctx, self, event);
}

/// A null `type` or `value` is sent as None. A null `value` removes the key.
pub fn setProperty(self: *Metadata, subject: u32, key: []const u8, type_: ?[]const u8, value: ?[]const u8) Remote.SendError!void {
    const gpa = self.proxy.remote.gpa;
    const extra = key.len + (if (type_) |t| t.len else 0) + (if (value) |v| v.len else 0);
    const buf = try gpa.alloc(u8, extra + 128);
    defer gpa.free(buf);
    var b = pod.Builder.init(buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(subject));
    try b.string(key);
    try b.string(type_);
    try b.string(value);
    b.end(f);
    try self.proxy.remote.sendBody(self.proxy.id, 1, b.bytesWritten());
}

/// Removes every key of every subject that the client may change.
pub fn clear(self: *Metadata) Remote.SendError!void {
    var buf: [32]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.none();
    b.end(f);
    try self.proxy.remote.sendBody(self.proxy.id, 2, b.bytesWritten());
}

const testing = std.testing;
const Rig = @import("testing/Rig.zig");
const tgpa = Rig.gpa;
const Device = @import("Device.zig");
const Port = @import("Port.zig");
const Link = @import("Link.zig");

const Rec = struct {
    props: u32 = 0,
    errors: u32 = 0,
    subject: u32 = 0,
    key: ?[]const u8 = null,
    value: ?[]const u8 = null,
    key_buf: [64]u8 = undefined,
    value_buf: [64]u8 = undefined,
    key_len: usize = 0,
    value_len: usize = 0,
    type_null: bool = false,
    err_res: i32 = 0,

    fn on(ctx: ?*anyopaque, metadata: *Metadata, event: Event) void {
        _ = metadata;
        const self: *Rec = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .removed => {},
            .property => |p| {
                self.props += 1;
                self.subject = p.subject;
                self.key_len = if (p.key) |k| k.len else 0;
                if (p.key) |k| @memcpy(self.key_buf[0..k.len], k);
                self.value_len = if (p.value) |v| v.len else 0;
                if (p.value) |v| @memcpy(self.value_buf[0..v.len], v);
                self.key = if (p.key != null) self.key_buf[0..self.key_len] else null;
                self.value = if (p.value != null) self.value_buf[0..self.value_len] else null;
                self.type_null = p.type == null;
            },
            .@"error" => |e| {
                self.errors += 1;
                self.err_res = e.res;
            },
        }
    }
};

fn propertyBody(buf: []u8, subject: i32, key: ?[]const u8, ty: ?[]const u8, value: ?[]const u8) []const u8 {
    var b = pod.Builder.init(buf);
    const f = b.beginStruct() catch unreachable;
    b.int(subject) catch unreachable;
    b.string(key) catch unreachable;
    b.string(ty) catch unreachable;
    b.string(value) catch unreachable;
    b.end(f);
    return b.bytesWritten();
}

test "Metadata.property decodes a set key" {
    var rig = try Rig.init();
    defer rig.deinit();
    const md = try rig.bind(Metadata, 90);
    var rec: Rec = .{};
    md.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [256]u8 = undefined;
    const json = "{\"name\":\"sink0\"}";
    try rig.server.send(md.proxy.id, 0, propertyBody(&buf, 0, "default.audio.sink", "Spa:String:JSON", json), &.{});
    try rig.remote.dispatch();

    try testing.expectEqual(@as(u32, 1), rec.props);
    try testing.expectEqual(@as(u32, 0), rec.subject);
    try testing.expectEqualStrings("default.audio.sink", rec.key.?);
    try testing.expect(!rec.type_null);
    try testing.expectEqualStrings(json, rec.value.?);
}

test "Metadata.property with a null value is a removal" {
    var rig = try Rig.init();
    defer rig.deinit();
    const md = try rig.bind(Metadata, 90);
    var rec: Rec = .{};
    md.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [256]u8 = undefined;
    try rig.server.send(md.proxy.id, 0, propertyBody(&buf, 33, "target.node", null, null), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 33), rec.subject);
    try testing.expectEqualStrings("target.node", rec.key.?);
    try testing.expect(rec.type_null);
    try testing.expect(rec.value == null);

    try rig.server.send(md.proxy.id, 0, propertyBody(&buf, 33, null, null, null), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 2), rec.props);
    try testing.expect(rec.key == null);
}

test "Metadata.setProperty sends the four fields" {
    var rig = try Rig.init();
    defer rig.deinit();
    const md = try rig.bind(Metadata, 90);
    try md.setProperty(33, "target.object", "Spa:Id", "44");

    var m = try rig.expectMessage(md.proxy.id, 1);
    defer m.deinit(tgpa);
    var buf: [256]u8 = undefined;
    try testing.expectEqualSlices(u8, propertyBody(&buf, 33, "target.object", "Spa:Id", "44"), m.body);
}

test "Metadata.setProperty with a null type and value" {
    var rig = try Rig.init();
    defer rig.deinit();
    const md = try rig.bind(Metadata, 90);
    try md.setProperty(33, "target.object", null, null);

    var m = try rig.expectMessage(md.proxy.id, 1);
    defer m.deinit(tgpa);
    var buf: [256]u8 = undefined;
    try testing.expectEqualSlices(u8, propertyBody(&buf, 33, "target.object", null, null), m.body);
}

test "Metadata.clear sends a struct with a None" {
    var rig = try Rig.init();
    defer rig.deinit();
    const md = try rig.bind(Metadata, 90);
    try md.clear();

    var m = try rig.expectMessage(md.proxy.id, 2);
    defer m.deinit(tgpa);
    var buf: [32]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.none();
    b.end(f);
    try testing.expectEqualSlices(u8, b.bytesWritten(), m.body);
}

test "a core error for a Metadata reaches its listener" {
    var rig = try Rig.init();
    defer rig.deinit();
    const md = try rig.bind(Metadata, 90);
    var rec: Rec = .{};
    md.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [128]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(md.proxy.id));
    try b.int(1);
    try b.int(-1);
    try b.string("perm");
    b.end(f);
    try rig.server.send(0, 3, b.bytesWritten(), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 1), rec.errors);
    try testing.expectEqual(@as(i32, -1), rec.err_res);
}

fn expectBind(rig: *Rig, ty: []const u8, global: i32, new_id: i32) !void {
    var m = try rig.server.expect(rig.registry.proxy.id, 1);
    defer m.deinit(tgpa);
    const parsed = try pod.Pod.parse(m.body);
    var it = try parsed.pod.structIter();
    try testing.expectEqual(global, try (try it.next()).?.int());
    try testing.expectEqualStrings(ty, (try (try it.next()).?.string()).?);
    try testing.expectEqual(@as(i32, 3), try (try it.next()).?.int());
    try testing.expectEqual(new_id, try (try it.next()).?.int());
}

test "Registry.bind works for Device, Port, Link and Metadata" {
    var rig = try Rig.init();
    defer rig.deinit();
    const device = try rig.registry.bind(40, Device, null);
    const port = try rig.registry.bind(50, Port, null);
    const link = try rig.registry.bind(70, Link, null);
    const md = try rig.registry.bind(90, Metadata, null);
    try rig.remote.dispatch();

    try testing.expectEqual(@as(u32, 3), device.proxy.id);
    try testing.expectEqual(@as(u32, 4), port.proxy.id);
    try testing.expectEqual(@as(u32, 5), link.proxy.id);
    try testing.expectEqual(@as(u32, 6), md.proxy.id);
    try expectBind(&rig, "PipeWire:Interface:Device", 40, 3);
    try expectBind(&rig, "PipeWire:Interface:Port", 50, 4);
    try expectBind(&rig, "PipeWire:Interface:Link", 70, 5);
    try expectBind(&rig, "PipeWire:Interface:Metadata", 90, 6);

    var buf: [64]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(6);
    try b.int(90);
    b.end(f);
    try rig.server.send(0, 5, b.bytesWritten(), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(?u32, 90), md.proxy.global_id);
}
