//! A bound Port object.
const std = @import("std");
const spa = @import("spa.zig");
const pod = @import("pod.zig");
const Connection = @import("Connection.zig");
const Proxy = @import("Proxy.zig");
const Remote = @import("Remote.zig");
const info = @import("info.zig");

const Port = @This();

proxy: Proxy,
listener: ?Listener = null,

pub const interface: Proxy.Interface = .port;

pub const ChangeMask = packed struct(u64) {
    props: bool = false,
    params: bool = false,
    _padding: u62 = 0,
};

pub const Info = struct {
    id: u32,
    direction: spa.Direction,
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
    func: *const fn (ctx: ?*anyopaque, port: *Port, event: Event) void,
};

/// Forwards a core error for this port to the listener. The listener may destroy the port,
/// so nothing touches it afterwards.
pub fn onError(proxy: *Proxy, err: Proxy.ErrorInfo) void {
    const self: *Port = @fieldParentPtr("proxy", proxy);
    if (self.listener) |l| l.func(l.ctx, self, .{ .@"error" = err });
}

/// Tells the listener that the server removed the object. The listener may destroy it.
pub fn onRemoved(proxy: *Proxy) void {
    const self: *Port = @fieldParentPtr("proxy", proxy);
    if (self.listener) |l| l.func(l.ctx, self, .removed);
}

pub fn handle(proxy: *Proxy, msg: Connection.Message) Remote.HandleError!void {
    const self: *Port = @fieldParentPtr("proxy", proxy);
    var a = try Proxy.args(msg);
    const event: Event = switch (msg.opcode) {
        0 => .{ .info = .{
            .id = try a.uint(),
            .direction = @fromBackingInt(try a.uint()),
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

pub fn subscribeParams(self: *Port, ids: []const spa.ParamType) Remote.SendError!void {
    try info.subscribeParams(&self.proxy, ids);
}

/// `filter` is a whole pod or null.
pub fn enumParams(self: *Port, seq: i32, id: spa.ParamType, index: u32, num: u32, filter: ?[]const u8) Remote.SendError!void {
    try info.enumParams(&self.proxy, seq, id, index, num, filter);
}

const testing = std.testing;
const Rig = @import("testing/Rig.zig");
const tgpa = Rig.gpa;

const Rec = struct {
    infos: u32 = 0,
    params_seen: u32 = 0,
    errors: u32 = 0,
    id: u32 = 0,
    direction: spa.Direction = .input,
    mask: u64 = 0,
    channel_ok: bool = false,
    n_params: u32 = 0,
    p0_id: spa.ParamType = .invalid,
    p1_flags: u32 = 0,
    param_id: spa.ParamType = .invalid,
    seq: i32 = 0,
    err_res: i32 = 0,

    fn on(ctx: ?*anyopaque, port: *Port, event: Event) void {
        _ = port;
        const self: *Rec = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .removed => {},
            .info => |i| {
                self.infos += 1;
                self.id = i.id;
                self.direction = i.direction;
                self.mask = @bitCast(i.change_mask);
                self.channel_ok = std.mem.eql(u8, i.props.get("audio.channel") orelse "", "FL");
                self.n_params = i.params.len();
                var it = i.params.iterator();
                self.p0_id = (it.next() catch unreachable).?.id;
                self.p1_flags = @bitCast((it.next() catch unreachable).?.flags);
            },
            .param => |p| {
                self.params_seen += 1;
                self.param_id = p.id;
                self.seq = p.seq;
            },
            .@"error" => |e| {
                self.errors += 1;
                self.err_res = e.res;
            },
        }
    }
};

test "Port.info decodes the direction, props and params" {
    var rig = try Rig.init();
    defer rig.deinit();
    const port = try rig.bind(Port, 50);
    var rec: Rec = .{};
    port.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [256]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(50);
    try b.int(1);
    try b.long(3);
    try b.dict(&.{.{ "audio.channel", "FL" }});
    const pf = try b.beginStruct();
    try b.int(2);
    try b.id(3);
    try b.int(2);
    try b.id(4);
    try b.int(6);
    b.end(pf);
    b.end(f);
    try rig.server.send(port.proxy.id, 0, b.bytesWritten(), &.{});
    try rig.remote.dispatch();

    try testing.expectEqual(@as(u32, 1), rec.infos);
    try testing.expectEqual(@as(u32, 50), rec.id);
    try testing.expectEqual(spa.Direction.output, rec.direction);
    try testing.expectEqual(@as(u64, 3), rec.mask);
    try testing.expect(rec.channel_ok);
    try testing.expectEqual(@as(u32, 2), rec.n_params);
    try testing.expectEqual(spa.ParamType.enum_format, rec.p0_id);
    try testing.expectEqual(@as(u32, 6), rec.p1_flags);
}

test "Port.param carries the seq and id" {
    var rig = try Rig.init();
    defer rig.deinit();
    const port = try rig.bind(Port, 50);
    var rec: Rec = .{};
    port.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [256]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(12);
    try b.id(4);
    try b.int(0);
    try b.int(1);
    const o = try b.beginObject(@backingInt(spa.ObjectType.format), @backingInt(spa.ParamType.format));
    b.end(o);
    b.end(f);
    try rig.server.send(port.proxy.id, 1, b.bytesWritten(), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 1), rec.params_seen);
    try testing.expectEqual(@as(i32, 12), rec.seq);
    try testing.expectEqual(spa.ParamType.format, rec.param_id);
}

test "Port.subscribeParams and enumParams send their requests" {
    var rig = try Rig.init();
    defer rig.deinit();
    const port = try rig.bind(Port, 50);
    try port.subscribeParams(&.{.format});
    try port.enumParams(3, .enum_format, 0, 0, null);

    var m1 = try rig.expectMessage(port.proxy.id, 1);
    defer m1.deinit(tgpa);
    var buf: [128]u8 = undefined;
    var b = pod.Builder.init(&buf);
    var f = try b.beginStruct();
    const a = try b.beginArray();
    try b.id(4);
    b.end(a);
    b.end(f);
    try testing.expectEqualSlices(u8, b.bytesWritten(), m1.body);

    var m2 = try rig.server.expect(port.proxy.id, 2);
    defer m2.deinit(tgpa);
    b = pod.Builder.init(&buf);
    f = try b.beginStruct();
    try b.int(3);
    try b.id(3);
    try b.int(0);
    try b.int(0);
    try b.none();
    b.end(f);
    try testing.expectEqualSlices(u8, b.bytesWritten(), m2.body);
}

test "a core error for a Port reaches its listener" {
    var rig = try Rig.init();
    defer rig.deinit();
    const port = try rig.bind(Port, 50);
    var rec: Rec = .{};
    port.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [128]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(port.proxy.id));
    try b.int(1);
    try b.int(-2);
    try b.string("gone");
    b.end(f);
    try rig.server.send(0, 3, b.bytesWritten(), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 1), rec.errors);
    try testing.expectEqual(@as(i32, -2), rec.err_res);
}
