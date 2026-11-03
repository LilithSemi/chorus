//! A bound Node object.
const std = @import("std");
const spa = @import("spa.zig");
const pod = @import("pod.zig");
const Connection = @import("Connection.zig");
const Proxy = @import("Proxy.zig");
const Remote = @import("Remote.zig");
const info = @import("info.zig");
const ClientNode = @import("ClientNode.zig");

const Node = @This();

proxy: Proxy,
listener: ?Listener = null,

pub const interface: Proxy.Interface = .node;

/// Wire value of the node state. A value that is not listed still decodes.
pub const State = enum(u32) {
    @"error" = 0xffffffff,
    creating = 0,
    suspended = 1,
    idle = 2,
    running = 3,
    _,
};

pub const ChangeMask = packed struct(u64) {
    input_ports: bool = false,
    output_ports: bool = false,
    state: bool = false,
    props: bool = false,
    params: bool = false,
    _padding: u59 = 0,
};

pub const Info = struct {
    id: u32,
    max_input_ports: u32,
    max_output_ports: u32,
    change_mask: ChangeMask,
    n_input_ports: u32,
    n_output_ports: u32,
    state: State,
    @"error": ?[]const u8,
    props: pod.Dict,
    params: info.ParamList,
};

/// The strings, the dict, the params list and the param pod borrow the message bytes. They
/// are valid only during the listener call.
/// New variants may be added. Switch with an `else` arm.
pub const Event = union(enum) {
    removed,
    info: Info,
    param: info.ParamEvent,
    @"error": Proxy.ErrorInfo,
};

pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, node: *Node, event: Event) void,
};

/// Forwards a core error for this node to the listener. The listener may destroy the node,
/// so nothing touches it afterwards.
pub fn onError(proxy: *Proxy, err: Proxy.ErrorInfo) void {
    const self: *Node = @fieldParentPtr("proxy", proxy);
    if (self.listener) |l| l.func(l.ctx, self, .{ .@"error" = err });
}

/// Tells the listener that the server removed the object. The listener may destroy it.
pub fn onRemoved(proxy: *Proxy) void {
    const self: *Node = @fieldParentPtr("proxy", proxy);
    if (self.listener) |l| l.func(l.ctx, self, .removed);
}

pub fn handle(proxy: *Proxy, msg: Connection.Message) Remote.HandleError!void {
    const self: *Node = @fieldParentPtr("proxy", proxy);
    var a = try Proxy.args(msg);
    const event: Event = switch (msg.opcode) {
        0 => .{ .info = .{
            .id = try a.uint(),
            .max_input_ports = try a.uint(),
            .max_output_ports = try a.uint(),
            .change_mask = @bitCast(try a.long()),
            .n_input_ports = try a.uint(),
            .n_output_ports = try a.uint(),
            .state = @fromBackingInt(try a.id()),
            .@"error" = try a.optString(),
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

pub fn subscribeParams(self: *Node, ids: []const spa.ParamType) Remote.SendError!void {
    try info.subscribeParams(&self.proxy, ids);
}

/// `filter` is a whole pod or null.
pub fn enumParams(self: *Node, seq: i32, id: spa.ParamType, index: u32, num: u32, filter: ?[]const u8) Remote.SendError!void {
    try info.enumParams(&self.proxy, seq, id, index, num, filter);
}

pub const SetParamError = Remote.SendError || error{OwnNode};

/// `param` is a whole pod. A node that this `Remote` exports through a `ClientNode` gives
/// `error.OwnNode`. The server asks the exporting client to handle the param and stops reading
/// from that client until it answers, so a set from the same connection never finishes. Use a
/// second `Remote`, or `Stream.setControls` for a stream.
pub fn setParam(self: *Node, id: spa.ParamType, flags: u32, param: []const u8) SetParamError!void {
    const global = self.proxy.global_id orelse self.proxy.bind_id;
    if (global) |g| {
        if (self.proxy.remote.exportsNode(g)) return error.OwnNode;
    }
    try info.setParam(&self.proxy, id, flags, param);
}

/// `command` is a whole pod.
pub fn sendCommand(self: *Node, command: []const u8) Remote.SendError!void {
    try info.sendPod(&self.proxy, 4, command);
}

const testing = std.testing;
const Rig = @import("testing/Rig.zig");
const tgpa = Rig.gpa;
const util = @import("testing/util.zig");
const fieldsOf = util.fieldsOf;
const expectQuiet = util.expectQuiet;

const Rec = struct {
    infos: u32 = 0,
    params_seen: u32 = 0,
    errors: u32 = 0,
    id: u32 = 0,
    max_in: u32 = 0,
    max_out: u32 = 0,
    mask: u64 = 0,
    state: State = .creating,
    error_text_null: bool = false,
    name_ok: bool = false,
    n_params: u32 = 0,
    p0_id: spa.ParamType = .invalid,
    p0_flags: u32 = 0,
    p1_id: spa.ParamType = .invalid,
    p1_flags: u32 = 0,
    seq: i32 = 0,
    param_id: spa.ParamType = .invalid,
    index: u32 = 0,
    next: u32 = 0,
    vol0: f32 = 0,
    vol1: f32 = 0,
    n_vol: usize = 0,
    err_res: i32 = 0,

    fn on(ctx: ?*anyopaque, node: *Node, event: Event) void {
        _ = node;
        const self: *Rec = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .removed => {},
            .info => |i| {
                self.infos += 1;
                self.id = i.id;
                self.max_in = i.max_input_ports;
                self.max_out = i.max_output_ports;
                self.mask = @bitCast(i.change_mask);
                self.state = i.state;
                self.error_text_null = i.@"error" == null;
                self.name_ok = std.mem.eql(u8, i.props.get("node.name") orelse "", "dummy");
                self.n_params = i.params.len();
                var it = i.params.iterator();
                const p0 = (it.next() catch unreachable).?;
                const p1 = (it.next() catch unreachable).?;
                self.p0_id = p0.id;
                self.p0_flags = @bitCast(p0.flags);
                self.p1_id = p1.id;
                self.p1_flags = @bitCast(p1.flags);
            },
            .param => |p| {
                self.params_seen += 1;
                self.seq = p.seq;
                self.param_id = p.id;
                self.index = p.index;
                self.next = p.next;
                const obj = p.param.object() catch unreachable;
                var props = obj.props();
                while (props.next() catch unreachable) |prop| {
                    if (prop.key != @backingInt(spa.PropKey.channel_volumes)) continue;
                    const arr = prop.value.array() catch unreachable;
                    self.n_vol = arr.count();
                    var vals = arr.items();
                    self.vol0 = (vals.next().?).float() catch unreachable;
                    self.vol1 = (vals.next().?).float() catch unreachable;
                }
            },
            .@"error" => |e| {
                self.errors += 1;
                self.err_res = e.res;
            },
        }
    }
};

fn writeVolumes(b: *pod.Builder) !void {
    const o = try b.beginObject(@backingInt(spa.ObjectType.props), @backingInt(spa.ParamType.props));
    try b.prop(@backingInt(spa.PropKey.channel_volumes), .{});
    const a = try b.beginArray();
    try b.float(0.5);
    try b.float(0.25);
    b.end(a);
    b.end(o);
}

fn volumesPod(buf: []u8) []const u8 {
    var b = pod.Builder.init(buf);
    writeVolumes(&b) catch unreachable;
    return b.bytesWritten();
}

test "Node.info decodes ports, state, props and two params" {
    var rig = try Rig.init();
    defer rig.deinit();
    const node = try rig.bind(Node, 30);
    var rec: Rec = .{};
    node.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [512]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(30);
    try b.int(2);
    try b.int(4);
    try b.long(0b11111);
    try b.int(1);
    try b.int(3);
    try b.id(1);
    try b.string(null);
    try b.dict(&.{ .{ "node.name", "dummy" }, .{ "media.class", "Audio/Sink" } });
    const pf = try b.beginStruct();
    try b.int(2);
    try b.id(1);
    try b.int(2);
    try b.id(2);
    try b.int(6);
    b.end(pf);
    b.end(f);
    try rig.server.send(node.proxy.id, 0, b.bytesWritten(), &.{});
    try rig.remote.dispatch();

    try testing.expectEqual(@as(u32, 1), rec.infos);
    try testing.expectEqual(@as(u32, 30), rec.id);
    try testing.expectEqual(@as(u32, 2), rec.max_in);
    try testing.expectEqual(@as(u32, 4), rec.max_out);
    try testing.expectEqual(@as(u64, 0b11111), rec.mask);
    try testing.expectEqual(State.suspended, rec.state);
    try testing.expect(rec.error_text_null);
    try testing.expect(rec.name_ok);
    try testing.expectEqual(@as(u32, 2), rec.n_params);
    try testing.expectEqual(spa.ParamType.prop_info, rec.p0_id);
    try testing.expectEqual(@as(u32, 2), rec.p0_flags);
    try testing.expectEqual(spa.ParamType.props, rec.p1_id);
    try testing.expectEqual(@as(u32, 6), rec.p1_flags);
}

test "Node.info with the error state decodes as error" {
    var rig = try Rig.init();
    defer rig.deinit();
    const node = try rig.bind(Node, 30);
    var rec: Rec = .{};
    node.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [512]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    for ([_]i32{ 30, 0, 0 }) |v| try b.int(v);
    try b.long(0);
    try b.int(0);
    try b.int(0);
    try b.id(0xffffffff);
    try b.string("broken");
    try b.dict(&.{});
    const pf = try b.beginStruct();
    try b.int(2);
    try b.id(1);
    try b.int(0);
    try b.id(2);
    try b.int(0);
    b.end(pf);
    b.end(f);
    try rig.server.send(node.proxy.id, 0, b.bytesWritten(), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(State.@"error", rec.state);
    try testing.expect(!rec.error_text_null);
}

test "Node.param decodes channelVolumes as an array of floats" {
    var rig = try Rig.init();
    defer rig.deinit();
    const node = try rig.bind(Node, 30);
    var rec: Rec = .{};
    node.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [256]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(1);
    try b.id(2);
    try b.int(0);
    try b.int(1);
    try writeVolumes(&b);
    b.end(f);
    try rig.server.send(node.proxy.id, 1, b.bytesWritten(), &.{});
    try rig.remote.dispatch();

    try testing.expectEqual(@as(u32, 1), rec.params_seen);
    try testing.expectEqual(@as(i32, 1), rec.seq);
    try testing.expectEqual(spa.ParamType.props, rec.param_id);
    try testing.expectEqual(@as(u32, 0), rec.index);
    try testing.expectEqual(@as(u32, 1), rec.next);
    try testing.expectEqual(@as(usize, 2), rec.n_vol);
    try testing.expectEqual(@as(f32, 0.5), rec.vol0);
    try testing.expectEqual(@as(f32, 0.25), rec.vol1);
}

test "Node.info with a truncated params list is a protocol error" {
    var rig = try Rig.init();
    defer rig.deinit();
    const node = try rig.bind(Node, 30);
    var rec: Rec = .{};
    node.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [256]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    for ([_]i32{ 30, 0, 0 }) |v| try b.int(v);
    try b.long(0);
    try b.int(0);
    try b.int(0);
    try b.id(1);
    try b.string(null);
    try b.dict(&.{});
    const pf = try b.beginStruct();
    try b.int(3);
    try b.id(1);
    try b.int(0);
    b.end(pf);
    b.end(f);
    try rig.server.send(node.proxy.id, 0, b.bytesWritten(), &.{});
    try testing.expectError(error.Protocol, rig.remote.dispatch());
    try testing.expectEqual(@as(u32, 0), rec.infos);
    try testing.expectEqual(@as(u64, 1), rig.remote.stats.bad);
}

test "Node.subscribeParams sends an array of ids" {
    var rig = try Rig.init();
    defer rig.deinit();
    const node = try rig.bind(Node, 30);
    try node.subscribeParams(&.{ .props, .route });

    var m = try rig.expectMessage(node.proxy.id, 1);
    defer m.deinit(tgpa);
    var buf: [64]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    const a = try b.beginArray();
    try b.id(2);
    try b.id(13);
    b.end(a);
    b.end(f);
    try testing.expectEqualSlices(u8, b.bytesWritten(), m.body);
}

test "Node.enumParams sends the request with and without a filter" {
    var rig = try Rig.init();
    defer rig.deinit();
    const node = try rig.bind(Node, 30);
    var pbuf: [128]u8 = undefined;
    const filter = volumesPod(&pbuf);
    try node.enumParams(7, .props, 0, 0, null);
    try node.enumParams(8, .props, 2, 5, filter);

    var m1 = try rig.expectMessage(node.proxy.id, 2);
    defer m1.deinit(tgpa);
    var buf: [256]u8 = undefined;
    var b = pod.Builder.init(&buf);
    var f = try b.beginStruct();
    try b.int(7);
    try b.id(2);
    try b.int(0);
    try b.int(0);
    try b.none();
    b.end(f);
    try testing.expectEqualSlices(u8, b.bytesWritten(), m1.body);

    var m2 = try rig.server.expect(node.proxy.id, 2);
    defer m2.deinit(tgpa);
    b = pod.Builder.init(&buf);
    f = try b.beginStruct();
    try b.int(8);
    try b.id(2);
    try b.int(2);
    try b.int(5);
    try writeVolumes(&b);
    b.end(f);
    try testing.expectEqualSlices(u8, b.bytesWritten(), m2.body);
}

test "Node.setParam sends the id, flags and pod" {
    var rig = try Rig.init();
    defer rig.deinit();
    const node = try rig.bind(Node, 30);
    var pbuf: [128]u8 = undefined;
    const param = volumesPod(&pbuf);
    try node.setParam(.props, 0, param);

    var m = try rig.expectMessage(node.proxy.id, 3);
    defer m.deinit(tgpa);
    var buf: [256]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.id(2);
    try b.int(0);
    try writeVolumes(&b);
    b.end(f);
    try testing.expectEqualSlices(u8, b.bytesWritten(), m.body);
}

test "Node.sendCommand sends the command pod" {
    var rig = try Rig.init();
    defer rig.deinit();
    const node = try rig.bind(Node, 30);
    var cbuf: [64]u8 = undefined;
    var cb = pod.Builder.init(&cbuf);
    const o = try cb.beginObject(@backingInt(spa.ObjectType.command_node), @backingInt(spa.NodeCommand.pause));
    cb.end(o);
    try node.sendCommand(cb.bytesWritten());

    var m = try rig.expectMessage(node.proxy.id, 4);
    defer m.deinit(tgpa);
    var it = try fieldsOf(m.body);
    const cmd = (try it.next()).?;
    const obj = try cmd.object();
    try testing.expectEqual(@backingInt(spa.ObjectType.command_node), obj.object_type);
    try testing.expectEqual(@backingInt(spa.NodeCommand.pause), obj.object_id);
    try testing.expect((try it.next()) == null);
}

test "a core error for a Node reaches its listener" {
    var rig = try Rig.init();
    defer rig.deinit();
    const node = try rig.bind(Node, 30);
    var rec: Rec = .{};
    node.listener = .{ .ctx = &rec, .func = Rec.on };

    var buf: [128]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(node.proxy.id));
    try b.int(1);
    try b.int(-1);
    try b.string("denied");
    b.end(f);
    try rig.server.send(0, 3, b.bytesWritten(), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 1), rec.errors);
    try testing.expectEqual(@as(i32, -1), rec.err_res);
}

test "setParam on a node that this remote exports gives OwnNode" {
    var rig = try Rig.init();
    defer rig.deinit();
    const exported = try rig.remote.createObjectAs(ClientNode, .client_node, "client-node", &.{});
    var created = try rig.expectMessage(0, 6);
    created.deinit(tgpa);

    var buf: [64]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(exported.proxy.id));
    try b.int(40);
    try b.dict(&.{});
    b.end(f);
    try rig.server.send(0, 8, b.bytesWritten(), &.{});
    try rig.remote.dispatch();
    try testing.expectEqual(@as(?u32, 40), exported.proxy.global_id);

    var pbuf: [64]u8 = undefined;
    var pb = pod.Builder.init(&pbuf);
    const o = try pb.beginObject(@backingInt(spa.ObjectType.props), @backingInt(spa.ParamType.props));
    pb.end(o);

    const own = try rig.bind(Node, 40);
    try testing.expectError(error.OwnNode, own.setParam(.props, 0, pb.bytesWritten()));
    try rig.remote.dispatch();
    try expectQuiet(&rig.server, 50);

    const other = try rig.bind(Node, 41);
    try other.setParam(.props, 0, pb.bytesWritten());
    try rig.remote.dispatch();
    var sent = try rig.server.expect(other.proxy.id, 3);
    sent.deinit(tgpa);
}
