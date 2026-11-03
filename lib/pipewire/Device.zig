//! A bound Device object.
const std = @import("std");
const spa = @import("spa.zig");
const pod = @import("pod.zig");
const Connection = @import("Connection.zig");
const Proxy = @import("Proxy.zig");
const Remote = @import("Remote.zig");
const info = @import("info.zig");

const Device = @This();

proxy: Proxy,
listener: ?Listener = null,

pub const interface: Proxy.Interface = .device;

pub const ChangeMask = packed struct(u64) {
    props: bool = false,
    params: bool = false,
    _padding: u62 = 0,
};

pub const Info = struct {
    id: u32,
    change_mask: ChangeMask,
    props: pod.Dict,
    params: info.ParamList,
};

/// The dict, the params list and the param pod borrow the message bytes. They are valid only
/// during the listener call.
/// New variants may be added. Switch with an `else` arm.
pub const Event = union(enum) {
    removed,
    info: Info,
    param: info.ParamEvent,
    @"error": Proxy.ErrorInfo,
};

pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, device: *Device, event: Event) void,
};

/// Forwards a core error for this device to the listener. The listener may destroy the
/// device, so nothing touches it afterwards.
pub fn onError(proxy: *Proxy, err: Proxy.ErrorInfo) void {
    const self: *Device = @fieldParentPtr("proxy", proxy);
    if (self.listener) |l| l.func(l.ctx, self, .{ .@"error" = err });
}

/// Tells the listener that the server removed the object. The listener may destroy it.
pub fn onRemoved(proxy: *Proxy) void {
    const self: *Device = @fieldParentPtr("proxy", proxy);
    if (self.listener) |l| l.func(l.ctx, self, .removed);
}

pub fn handle(proxy: *Proxy, msg: Connection.Message) Remote.HandleError!void {
    const self: *Device = @fieldParentPtr("proxy", proxy);
    var a = try Proxy.args(msg);
    const event: Event = switch (msg.opcode) {
        0 => .{ .info = .{
            .id = try a.uint(),
            .change_mask = @bitCast(try a.long()),
            .props = try a.dict(),
            .params = try info.readParams(&a),
        } },
        1 => .{ .param = try info.readParam(&a) },
        else => {
            proxy.remote.stats.dropped += 1;
            return;
        },
    };
    if (self.listener) |l| l.func(l.ctx, self, event);
}

pub fn subscribeParams(self: *Device, ids: []const spa.ParamType) Remote.SendError!void {
    try info.subscribeParams(&self.proxy, ids);
}

/// `filter` is a whole pod or null.
pub fn enumParams(self: *Device, seq: i32, id: spa.ParamType, index: u32, num: u32, filter: ?[]const u8) Remote.SendError!void {
    try info.enumParams(&self.proxy, seq, id, index, num, filter);
}

/// `param` is a whole pod.
pub fn setParam(self: *Device, id: spa.ParamType, flags: u32, param: []const u8) Remote.SendError!void {
    try info.setParam(&self.proxy, id, flags, param);
}

const testing = std.testing;
const Rig = @import("testing/Rig.zig");
const tgpa = Rig.gpa;

const Rec = struct {
    infos: u32 = 0,
    params_seen: u32 = 0,
    errors: u32 = 0,
    id: u32 = 0,
    mask: u64 = 0,
    name_ok: bool = false,
    n_params: u32 = 0,
    p0_id: spa.ParamType = .invalid,
    p0_flags: u32 = 0,
    param_id: spa.ParamType = .invalid,
    index: u32 = 0,
    next: u32 = 0,
    route_index: i32 = -1,
    err_res: i32 = 0,

    fn on(ctx: ?*anyopaque, device: *Device, event: Event) void {
        _ = device;
        const self: *Rec = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .removed => {},
            .info => |i| {
                self.infos += 1;
                self.id = i.id;
                self.mask = @bitCast(i.change_mask);
                self.name_ok = std.mem.eql(u8, i.props.get("device.name") orelse "", "alsa");
                self.n_params = i.params.len();
                var it = i.params.iterator();
                const p0 = (it.next() catch unreachable).?;
                self.p0_id = p0.id;
                self.p0_flags = @bitCast(p0.flags);
            },
            .param => |p| {
                self.params_seen += 1;
                self.param_id = p.id;
                self.index = p.index;
                self.next = p.next;
                const obj = p.param.object() catch unreachable;
                var props = obj.props();
                while (props.next() catch unreachable) |prop| {
                    if (prop.key == @backingInt(spa.ParamRouteKey.index)) self.route_index = prop.value.int() catch unreachable;
                }
            },
            .@"error" => |e| {
                self.errors += 1;
                self.err_res = e.res;
            },
        }
    }
};

fn writeRoute(b: *pod.Builder) !void {
    const o = try b.beginObject(@backingInt(spa.ObjectType.param_route), @backingInt(spa.ParamType.route));
    try b.prop(@backingInt(spa.ParamRouteKey.index), .{});
    try b.int(4);
    try b.prop(@backingInt(spa.ParamRouteKey.direction), .{});
    try b.id(@backingInt(spa.Direction.output));
    try b.prop(@backingInt(spa.ParamRouteKey.name), .{});
    try b.string("analog-output");
    b.end(o);
}

test "Device.info decodes the mask, props and params" {
    var rig = try Rig.init();
    defer rig.deinit();
    const device = try rig.bind(Device, 40);
    var rec: Rec = .{};
    device.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [256]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(40);
    try b.long(3);
    try b.dict(&.{.{ "device.name", "alsa" }});
    const pf = try b.beginStruct();
    try b.int(1);
    try b.id(13);
    try b.int(7);
    b.end(pf);
    b.end(f);
    try rig.server.send(device.proxy.id, 0, b.bytesWritten(), &.{});
    try rig.remote.dispatch();

    try testing.expectEqual(@as(u32, 1), rec.infos);
    try testing.expectEqual(@as(u32, 40), rec.id);
    try testing.expectEqual(@as(u64, 3), rec.mask);
    try testing.expect(rec.name_ok);
    try testing.expectEqual(@as(u32, 1), rec.n_params);
    try testing.expectEqual(spa.ParamType.route, rec.p0_id);
    try testing.expectEqual(@as(u32, 7), rec.p0_flags);
}

test "Device.param decodes a Route object" {
    var rig = try Rig.init();
    defer rig.deinit();
    const device = try rig.bind(Device, 40);
    var rec: Rec = .{};
    device.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [256]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(1);
    try b.id(13);
    try b.int(2);
    try b.int(3);
    try writeRoute(&b);
    b.end(f);
    try rig.server.send(device.proxy.id, 1, b.bytesWritten(), &.{});
    try rig.remote.dispatch();

    try testing.expectEqual(@as(u32, 1), rec.params_seen);
    try testing.expectEqual(spa.ParamType.route, rec.param_id);
    try testing.expectEqual(@as(u32, 2), rec.index);
    try testing.expectEqual(@as(u32, 3), rec.next);
    try testing.expectEqual(@as(i32, 4), rec.route_index);
}

test "Device.subscribeParams and enumParams send their requests" {
    var rig = try Rig.init();
    defer rig.deinit();
    const device = try rig.bind(Device, 40);
    try device.subscribeParams(&.{ .enum_route, .route });
    try device.enumParams(9, .enum_route, 1, 2, null);

    var m1 = try rig.expectMessage(device.proxy.id, 1);
    defer m1.deinit(tgpa);
    var buf: [128]u8 = undefined;
    var b = pod.Builder.init(&buf);
    var f = try b.beginStruct();
    const a = try b.beginArray();
    try b.id(12);
    try b.id(13);
    b.end(a);
    b.end(f);
    try testing.expectEqualSlices(u8, b.bytesWritten(), m1.body);

    var m2 = try rig.server.expect(device.proxy.id, 2);
    defer m2.deinit(tgpa);
    b = pod.Builder.init(&buf);
    f = try b.beginStruct();
    try b.int(9);
    try b.id(12);
    try b.int(1);
    try b.int(2);
    try b.none();
    b.end(f);
    try testing.expectEqualSlices(u8, b.bytesWritten(), m2.body);
}

test "Device.setParam sends a Route object byte for byte" {
    var rig = try Rig.init();
    defer rig.deinit();
    const device = try rig.bind(Device, 40);
    var pbuf: [128]u8 = undefined;
    var pb = pod.Builder.init(&pbuf);
    try writeRoute(&pb);
    try device.setParam(.route, 0, pb.bytesWritten());

    var m = try rig.expectMessage(device.proxy.id, 3);
    defer m.deinit(tgpa);
    var buf: [256]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.id(13);
    try b.int(0);
    try writeRoute(&b);
    b.end(f);
    try testing.expectEqualSlices(u8, b.bytesWritten(), m.body);
}

test "a core error for a Device reaches its listener" {
    var rig = try Rig.init();
    defer rig.deinit();
    const device = try rig.bind(Device, 40);
    var rec: Rec = .{};
    device.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [128]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(device.proxy.id));
    try b.int(1);
    try b.int(-13);
    try b.string("denied");
    b.end(f);
    try rig.server.send(0, 3, b.bytesWritten(), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 1), rec.errors);
    try testing.expectEqual(@as(i32, -13), rec.err_res);
}
