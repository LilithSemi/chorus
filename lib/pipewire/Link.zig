//! A bound Link object.
const std = @import("std");
const spa = @import("spa.zig");
const pod = @import("pod.zig");
const Connection = @import("Connection.zig");
const Proxy = @import("Proxy.zig");
const Remote = @import("Remote.zig");

const Link = @This();

proxy: Proxy,
listener: ?Listener = null,

pub const interface: Proxy.Interface = .link;

/// Wire value of the link state. A value that is not listed still decodes.
pub const State = enum(i32) {
    @"error" = -2,
    unlinked = -1,
    init = 0,
    negotiating = 1,
    allocating = 2,
    paused = 3,
    active = 4,
    _,
};

pub const ChangeMask = packed struct(u64) {
    state: bool = false,
    format: bool = false,
    props: bool = false,
    _padding: u61 = 0,
};

pub const Info = struct {
    id: u32,
    output_node_id: u32,
    output_port_id: u32,
    input_node_id: u32,
    input_port_id: u32,
    change_mask: ChangeMask,
    state: State,
    @"error": ?[]const u8,
    format: ?pod.Pod,
    props: pod.Dict,
};

/// The strings, the format pod and the dict borrow the message bytes. They are valid only
/// during the listener call.
/// New variants may be added. Switch with an `else` arm.
pub const Event = union(enum) {
    removed,
    info: Info,
    @"error": Proxy.ErrorInfo,
};

pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, link: *Link, event: Event) void,
};

/// Forwards a core error for this link to the listener. The listener may destroy the link,
/// so nothing touches it afterwards.
pub fn onError(proxy: *Proxy, err: Proxy.ErrorInfo) void {
    const self: *Link = @fieldParentPtr("proxy", proxy);
    if (self.listener) |l| l.func(l.ctx, self, .{ .@"error" = err });
}

/// Tells the listener that the server removed the object. The listener may destroy it.
pub fn onRemoved(proxy: *Proxy) void {
    const self: *Link = @fieldParentPtr("proxy", proxy);
    if (self.listener) |l| l.func(l.ctx, self, .removed);
}

pub fn handle(proxy: *Proxy, msg: Connection.Message) Remote.HandleError!void {
    const self: *Link = @fieldParentPtr("proxy", proxy);
    var a = try Proxy.args(msg);
    const event: Event = switch (msg.opcode) {
        0 => .{ .info = .{
            .id = try a.uint(),
            .output_node_id = try a.uint(),
            .output_port_id = try a.uint(),
            .input_node_id = try a.uint(),
            .input_port_id = try a.uint(),
            .change_mask = @bitCast(try a.long()),
            .state = @fromBackingInt(@intCast(try a.int())),
            .@"error" = try a.optString(),
            .format = try a.optPod(),
            .props = try a.dict(),
        } },
        else => {
            proxy.remote.stats.dropped += 1;
            return;
        },
    };
    if (self.listener) |l| l.func(l.ctx, self, event);
}

const testing = std.testing;
const Rig = @import("testing/Rig.zig");

const Rec = struct {
    infos: u32 = 0,
    errors: u32 = 0,
    id: u32 = 0,
    out_node: u32 = 0,
    out_port: u32 = 0,
    in_node: u32 = 0,
    in_port: u32 = 0,
    mask: u64 = 0,
    state: State = .init,
    error_text_null: bool = true,
    format_null: bool = false,
    format_type: spa.Type = .none,
    prio_ok: bool = false,
    err_res: i32 = 0,

    fn on(ctx: ?*anyopaque, link: *Link, event: Event) void {
        _ = link;
        const self: *Rec = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .removed => {},
            .info => |i| {
                self.infos += 1;
                self.id = i.id;
                self.out_node = i.output_node_id;
                self.out_port = i.output_port_id;
                self.in_node = i.input_node_id;
                self.in_port = i.input_port_id;
                self.mask = @bitCast(i.change_mask);
                self.state = i.state;
                self.error_text_null = i.@"error" == null;
                self.format_null = i.format == null;
                if (i.format) |p| self.format_type = p.type;
                self.prio_ok = std.mem.eql(u8, i.props.get("link.output.node") orelse "", "60");
            },
            .@"error" => |e| {
                self.errors += 1;
                self.err_res = e.res;
            },
        }
    }
};

fn linkBody(buf: []u8, state: i32, err: ?[]const u8, with_format: bool) []const u8 {
    var b = pod.Builder.init(buf);
    const f = b.beginStruct() catch unreachable;
    for ([_]i32{ 70, 60, 61, 80, 81 }) |v| b.int(v) catch unreachable;
    b.long(0b111) catch unreachable;
    b.int(state) catch unreachable;
    b.string(err) catch unreachable;
    if (with_format) {
        const o = b.beginObject(@backingInt(spa.ObjectType.format), @backingInt(spa.ParamType.format)) catch unreachable;
        b.end(o);
    } else b.none() catch unreachable;
    b.dict(&.{.{ "link.output.node", "60" }}) catch unreachable;
    b.end(f);
    return b.bytesWritten();
}

test "Link.info with a null format" {
    var rig = try Rig.init();
    defer rig.deinit();
    const link = try rig.bind(Link, 70);
    var rec: Rec = .{};
    link.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [256]u8 = undefined;
    try rig.server.send(link.proxy.id, 0, linkBody(&buf, 1, null, false), &.{});
    try rig.remote.dispatch();

    try testing.expectEqual(@as(u32, 1), rec.infos);
    try testing.expectEqual(@as(u32, 70), rec.id);
    try testing.expectEqual(@as(u32, 60), rec.out_node);
    try testing.expectEqual(@as(u32, 61), rec.out_port);
    try testing.expectEqual(@as(u32, 80), rec.in_node);
    try testing.expectEqual(@as(u32, 81), rec.in_port);
    try testing.expectEqual(@as(u64, 0b111), rec.mask);
    try testing.expectEqual(State.negotiating, rec.state);
    try testing.expect(rec.error_text_null);
    try testing.expect(rec.format_null);
    try testing.expect(rec.prio_ok);
}

test "Link.info with a format and an error state" {
    var rig = try Rig.init();
    defer rig.deinit();
    const link = try rig.bind(Link, 70);
    var rec: Rec = .{};
    link.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [256]u8 = undefined;
    try rig.server.send(link.proxy.id, 0, linkBody(&buf, -2, "no format", true), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(State.@"error", rec.state);
    try testing.expect(!rec.error_text_null);
    try testing.expect(!rec.format_null);
    try testing.expectEqual(spa.Type.object, rec.format_type);
}

test "a core error for a Link reaches its listener" {
    var rig = try Rig.init();
    defer rig.deinit();
    const link = try rig.bind(Link, 70);
    var rec: Rec = .{};
    link.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [128]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(link.proxy.id));
    try b.int(1);
    try b.int(-32);
    try b.string("pipe");
    b.end(f);
    try rig.server.send(0, 3, b.bytesWritten(), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 1), rec.errors);
    try testing.expectEqual(@as(i32, -32), rec.err_res);
}
