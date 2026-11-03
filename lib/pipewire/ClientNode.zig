//! The ClientNode object. The client exports its own node with it, and the server sends the
//! events that drive the node.
const std = @import("std");
const linux = std.os.linux;
const spa = @import("spa.zig");
const pod = @import("pod.zig");
const Connection = @import("Connection.zig");
const Proxy = @import("Proxy.zig");
const Remote = @import("Remote.zig");
const Node = @import("Node.zig");
const info_util = @import("info.zig");

const ClientNode = @This();

proxy: Proxy,
listener: ?Listener = null,
/// The seq of the message that is handled now.
last_seq: u32 = 0,

pub const interface: Proxy.Interface = .client_node;

pub const max_datas = 4;

pub const UpdateMask = packed struct(u32) {
    params: bool = false,
    info: bool = false,
    _padding: u30 = 0,
};

pub const NodeInfoMask = packed struct(u64) {
    flags: bool = false,
    props: bool = false,
    params: bool = false,
    _padding: u61 = 0,
};

pub const PortInfoMask = packed struct(u64) {
    flags: bool = false,
    rate: bool = false,
    props: bool = false,
    params: bool = false,
    _padding: u60 = 0,
};

pub const ParamInfo = struct {
    id: spa.ParamType,
    flags: spa.ParamInfoFlags,
};

pub const NodeInfo = struct {
    max_input_ports: u32,
    max_output_ports: u32,
    change_mask: NodeInfoMask,
    flags: spa.NodeFlags,
    /// Sent only with the props bit.
    props: []const [2][]const u8 = &.{},
    /// Sent only with the params bit.
    params: []const ParamInfo = &.{},
};

pub const PortInfo = struct {
    change_mask: PortInfoMask,
    flags: spa.PortFlags,
    rate: spa.Fraction,
    props: []const [2][]const u8 = &.{},
    params: []const ParamInfo = &.{},
};

/// One data plane of a buffer that the client allocated. `fd_index` is the place of the fd in
/// the `fds` argument of `portBuffers`.
pub const PortBufferData = struct {
    type: spa.DataType,
    fd_index: i64,
    flags: spa.DataFlags,
    map_offset: u32,
    max_size: u32,
};

pub const Data = struct {
    type: spa.DataType,
    data_id: u32,
    flags: spa.DataFlags,
    map_offset: u32,
    max_size: u32,
};

pub const Buffer = struct {
    mem_id: u32,
    offset: u32,
    size: u32,
    /// The bytes of all metas, each one rounded up to 8.
    metas_size: u32,
    n_datas: u32,
    datas: [max_datas]Data,
};

/// The buffers of a port_use_buffers event. Read them during the listener call. `handle` has
/// read the whole list before the call, so `next` does not fail there.
pub const BufferIter = struct {
    args: Proxy.Args,
    left: u32,

    pub fn next(self: *BufferIter) pod.Error!?Buffer {
        if (self.left == 0) return null;
        self.left -= 1;
        const a = &self.args;
        var buffer: Buffer = .{
            .mem_id = try a.uint(),
            .offset = try a.uint(),
            .size = try a.uint(),
            .metas_size = 0,
            .n_datas = 0,
            .datas = undefined,
        };
        const n_metas = try a.uint();
        for (0..n_metas) |_| {
            _ = try a.id();
            const meta_size = try a.uint();
            const rounded = std.math.add(u32, meta_size, 7) catch return error.BadPod;
            buffer.metas_size = std.math.add(u32, buffer.metas_size, rounded & ~@as(u32, 7)) catch return error.BadPod;
        }
        buffer.n_datas = try a.uint();
        if (buffer.n_datas > max_datas) return error.BadPod;
        for (buffer.datas[0..buffer.n_datas]) |*d| d.* = .{
            .type = @fromBackingInt(try a.id()),
            .data_id = try a.uint(),
            .flags = @bitCast(try a.uint()),
            .map_offset = try a.uint(),
            .max_size = try a.uint(),
        };
        return buffer;
    }
};

pub const UseBuffers = struct {
    direction: spa.Direction,
    port_id: u32,
    mix_id: u32,
    flags: u32,
    buffers: BufferIter,
};

/// The fds of an event belong to the listener, which closes them. A node with no listener
/// closes them. The pods, dicts and buffers borrow the message and are valid only during the
/// call.
/// New variants may be added. Switch with an `else` arm.
pub const Event = union(enum) {
    removed,
    /// The server told the global id of the node.
    bound: u32,
    transport: struct { readfd: linux.fd_t, writefd: linux.fd_t, mem_id: u32, offset: u32, size: u32 },
    set_param: struct { id: spa.ParamType, flags: u32, param: ?pod.Pod },
    set_io: struct { id: spa.IoType, mem_id: u32, offset: u32, size: u32 },
    event: pod.Pod,
    command: pod.Pod,
    add_port: struct { direction: spa.Direction, port_id: u32, props: pod.Dict },
    remove_port: struct { direction: spa.Direction, port_id: u32 },
    port_set_param: struct { direction: spa.Direction, port_id: u32, id: spa.ParamType, flags: u32, param: ?pod.Pod },
    port_use_buffers: UseBuffers,
    port_set_io: struct { direction: spa.Direction, port_id: u32, mix_id: u32, id: spa.IoType, mem_id: u32, offset: u32, size: u32 },
    set_activation: struct { node_id: u32, signalfd: linux.fd_t, mem_id: u32, offset: u32, size: u32 },
    port_set_mix_info: struct { direction: spa.Direction, port_id: u32, mix_id: u32, peer_id: u32, props: pod.Dict },
    @"error": Proxy.ErrorInfo,
};

pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, node: *ClientNode, event: Event) void,
};

/// Forwards a core error for this node to the listener. The listener may destroy the node,
/// so nothing touches it afterwards.
pub fn onError(proxy: *Proxy, err: Proxy.ErrorInfo) void {
    const self: *ClientNode = @fieldParentPtr("proxy", proxy);
    if (self.listener) |l| l.func(l.ctx, self, .{ .@"error" = err });
}

fn takeFd(conn: *Connection, msg: Connection.Message, index: i64) error{Protocol}!linux.fd_t {
    if (index == -1) return -1;
    if (index < 0 or index >= msg.fds.len) return error.Protocol;
    return conn.takeFd(msg, @intCast(index)) catch error.Protocol;
}

fn closeFd(fd: linux.fd_t) void {
    if (fd >= 0) _ = linux.close(fd);
}

/// Closes the fds of an event that nobody took.
pub fn closeEventFds(ev: Event) void {
    switch (ev) {
        .transport => |t| {
            closeFd(t.readfd);
            closeFd(t.writefd);
        },
        .set_activation => |a| closeFd(a.signalfd),
        else => {},
    }
}

/// Tells the listener that the server removed the object. The listener may destroy it.
pub fn onRemoved(proxy: *Proxy) void {
    const self: *ClientNode = @fieldParentPtr("proxy", proxy);
    if (self.listener) |l| l.func(l.ctx, self, .removed);
}

/// Tells the listener the global id of the node.
pub fn onBound(proxy: *Proxy) void {
    const self: *ClientNode = @fieldParentPtr("proxy", proxy);
    const id = proxy.global_id orelse return;
    if (self.listener) |l| l.func(l.ctx, self, .{ .bound = id });
}

pub fn handle(proxy: *Proxy, msg: Connection.Message) Remote.HandleError!void {
    const self: *ClientNode = @fieldParentPtr("proxy", proxy);
    self.last_seq = msg.seq;
    const conn = &proxy.remote.conn;
    var a = try Proxy.args(msg);
    const ev: Event = switch (msg.opcode) {
        0 => blk: {
            const read_index = try (try a.next()).fd();
            const write_index = try (try a.next()).fd();
            const mem_id = try a.uint();
            const offset = try a.uint();
            const size = try a.uint();
            const readfd = try takeFd(conn, msg, read_index);
            const writefd = takeFd(conn, msg, write_index) catch |err| {
                closeFd(readfd);
                return err;
            };
            break :blk .{ .transport = .{ .readfd = readfd, .writefd = writefd, .mem_id = mem_id, .offset = offset, .size = size } };
        },
        1 => .{ .set_param = .{
            .id = @fromBackingInt(try a.id()),
            .flags = try a.uint(),
            .param = try a.optPod(),
        } },
        2 => .{ .set_io = .{
            .id = @fromBackingInt(try a.id()),
            .mem_id = try a.uint(),
            .offset = try a.uint(),
            .size = try a.uint(),
        } },
        3 => .{ .event = try a.next() },
        4 => .{ .command = try a.next() },
        5 => .{ .add_port = .{
            .direction = @fromBackingInt(try a.uint()),
            .port_id = try a.uint(),
            .props = try a.dict(),
        } },
        6 => .{ .remove_port = .{
            .direction = @fromBackingInt(try a.uint()),
            .port_id = try a.uint(),
        } },
        7 => .{ .port_set_param = .{
            .direction = @fromBackingInt(try a.uint()),
            .port_id = try a.uint(),
            .id = @fromBackingInt(try a.id()),
            .flags = try a.uint(),
            .param = try a.optPod(),
        } },
        8 => .{ .port_use_buffers = .{
            .direction = @fromBackingInt(try a.uint()),
            .port_id = try a.uint(),
            .mix_id = try a.uint(),
            .flags = try a.uint(),
            .buffers = .{ .left = try a.uint(), .args = a },
        } },
        9 => .{ .port_set_io = .{
            .direction = @fromBackingInt(try a.uint()),
            .port_id = try a.uint(),
            .mix_id = try a.uint(),
            .id = @fromBackingInt(try a.id()),
            .mem_id = try a.uint(),
            .offset = try a.uint(),
            .size = try a.uint(),
        } },
        10 => blk: {
            const node_id = try a.uint();
            const fd_index = try (try a.next()).fd();
            const mem_id = try a.uint();
            const offset = try a.uint();
            const size = try a.uint();
            const signalfd = try takeFd(conn, msg, fd_index);
            break :blk .{ .set_activation = .{ .node_id = node_id, .signalfd = signalfd, .mem_id = mem_id, .offset = offset, .size = size } };
        },
        11 => .{ .port_set_mix_info = .{
            .direction = @fromBackingInt(try a.uint()),
            .port_id = try a.uint(),
            .mix_id = try a.uint(),
            .peer_id = try a.uint(),
            .props = try a.dict(),
        } },
        else => {
            proxy.remote.stats.dropped += 1;
            return;
        },
    };
    if (ev == .port_use_buffers) {
        // A bad buffer list is a protocol error here, so the listener can read it without errors.
        var check = ev.port_use_buffers.buffers;
        while (try check.next() != null) {}
    }
    if (self.listener) |l| l.func(l.ctx, self, ev) else closeEventFds(ev);
}

/// Binds a Node proxy to this node.
pub fn getNode(self: *ClientNode, version: ?u32) Remote.SendError!*Node {
    const remote = self.proxy.remote;
    const v = version orelse Proxy.defaultVersion(.node);
    const node = try remote.newProxy(Node, .node, v);
    errdefer remote.release(&node.proxy);
    var buf: [48]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(v));
    try b.int(@bitCast(node.proxy.id));
    b.end(f);
    try remote.sendBody(self.proxy.id, 1, b.bytesWritten());
    return node;
}

fn propsSize(props: []const [2][]const u8) usize {
    var n: usize = 0;
    for (props) |kv| n += kv[0].len + kv[1].len + 32;
    return n;
}

fn writeProps(b: *pod.Builder, props: []const [2][]const u8) pod.Builder.Error!void {
    try b.int(@intCast(props.len));
    for (props) |kv| {
        try b.string(kv[0]);
        try b.string(kv[1]);
    }
}

fn writeParamInfos(b: *pod.Builder, params: []const ParamInfo) pod.Builder.Error!void {
    try b.int(@intCast(params.len));
    for (params) |p| {
        try b.id(@backingInt(p.id));
        try b.int(@bitCast(p.flags));
    }
}

/// Updates the node. Each of `params` is a whole pod. `info` is sent only when the mask has
/// the info bit.
pub fn update(self: *ClientNode, mask: UpdateMask, params: []const []const u8, info: ?NodeInfo) Remote.SendError!void {
    const remote = self.proxy.remote;
    var size: usize = 256;
    for (params) |p| size += p.len + 16;
    if (info) |i| size += propsSize(i.props) + i.params.len * 32;
    const buf = try remote.gpa.alloc(u8, size);
    defer remote.gpa.free(buf);

    var b = pod.Builder.init(buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(mask));
    try b.int(@intCast(params.len));
    for (params) |p| try info_util.appendPod(&b, p);
    if (info) |i| {
        const s = try b.beginStruct();
        try b.int(@bitCast(i.max_input_ports));
        try b.int(@bitCast(i.max_output_ports));
        try b.long(@bitCast(i.change_mask));
        try b.long(@as(u32, @bitCast(i.flags)));
        try writeProps(&b, if (i.change_mask.props) i.props else &.{});
        try writeParamInfos(&b, if (i.change_mask.params) i.params else &.{});
        b.end(s);
    } else {
        try b.none();
    }
    b.end(f);
    try remote.sendBody(self.proxy.id, 2, b.bytesWritten());
}

/// Updates one port. A mask with no bit removes the port. `info` is written whole, whatever
/// its change mask says.
pub fn portUpdate(self: *ClientNode, direction: spa.Direction, port_id: u32, mask: UpdateMask, params: []const []const u8, info: ?PortInfo) Remote.SendError!void {
    const remote = self.proxy.remote;
    var size: usize = 256;
    for (params) |p| size += p.len + 16;
    if (info) |i| size += propsSize(i.props) + i.params.len * 32;
    const buf = try remote.gpa.alloc(u8, size);
    defer remote.gpa.free(buf);

    var b = pod.Builder.init(buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(@backingInt(direction)));
    try b.int(@bitCast(port_id));
    try b.int(@bitCast(mask));
    try b.int(@intCast(params.len));
    for (params) |p| try info_util.appendPod(&b, p);
    if (info) |i| {
        const s = try b.beginStruct();
        try b.long(@bitCast(i.change_mask));
        try b.long(@as(u32, @bitCast(i.flags)));
        try b.int(@bitCast(i.rate.num));
        try b.int(@bitCast(i.rate.denom));
        try writeProps(&b, i.props);
        try writeParamInfos(&b, i.params);
        b.end(s);
    } else {
        try b.none();
    }
    b.end(f);
    try remote.sendBody(self.proxy.id, 3, b.bytesWritten());
}

/// Starts or stops the scheduling of the node.
pub fn setActive(self: *ClientNode, active: bool) Remote.SendError!void {
    var buf: [32]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.boolean(active);
    b.end(f);
    try self.proxy.remote.sendBody(self.proxy.id, 4, b.bytesWritten());
}

/// `event` is a whole pod.
pub fn event(self: *ClientNode, event_pod: []const u8) Remote.SendError!void {
    try info_util.sendPod(&self.proxy, 5, event_pod);
}

/// Answers a port_use_buffers event that asked the client to allocate. Each entry of `buffers`
/// lists the data planes of one buffer. The fd of a plane is `fds[fd_index]`.
pub fn portBuffers(self: *ClientNode, direction: spa.Direction, port_id: u32, mix_id: u32, buffers: []const []const PortBufferData, fds: []const linux.fd_t) Remote.SendError!void {
    const remote = self.proxy.remote;
    var size: usize = 256;
    for (buffers) |datas| size += 16 + datas.len * 80;
    const buf = try remote.gpa.alloc(u8, size);
    defer remote.gpa.free(buf);

    var b = pod.Builder.init(buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(@backingInt(direction)));
    try b.int(@bitCast(port_id));
    try b.int(@bitCast(mix_id));
    try b.int(@intCast(buffers.len));
    for (buffers) |datas| {
        try b.int(@intCast(datas.len));
        for (datas) |d| {
            try b.id(@backingInt(d.type));
            try b.fd(d.fd_index);
            try b.int(@bitCast(d.flags));
            try b.int(@bitCast(d.map_offset));
            try b.int(@bitCast(d.max_size));
        }
    }
    b.end(f);
    try remote.sendBodyFds(self.proxy.id, 6, b.bytesWritten(), fds);
}

const testing = std.testing;
const Rig = @import("testing/Rig.zig");
const tgpa = Rig.gpa;
const util = @import("testing/util.zig");
const newEventfd = util.newEventfd;
const fieldsOf = util.fieldsOf;
const nextInt = util.nextInt;
const Builder = pod.Builder;

const Rec = struct {
    events: u32 = 0,
    readfd: linux.fd_t = -1,
    writefd: linux.fd_t = -1,
    transport_ints: [3]u32 = @splat(0),
    act_node: u32 = 0,
    act_fd: linux.fd_t = -2,
    act_mem: u32 = 0,
    n_buffers: u32 = 0,
    buf_mem: [2]u32 = @splat(0),
    buf_metas_size: [2]u32 = @splat(0),
    buf_data_id: [2]u32 = @splat(0),
    buf_maxsize: [2]u32 = @splat(0),
    buf_data_type: [2]u32 = @splat(0),
    command_id: u32 = 0,
    err_res: i32 = 0,
    use_mix: u32 = 0,

    fn on(ctx: ?*anyopaque, node: *ClientNode, ev: Event) void {
        _ = node;
        const self: *Rec = @ptrCast(@alignCast(ctx.?));
        self.events += 1;
        switch (ev) {
            .transport => |t| {
                self.readfd = t.readfd;
                self.writefd = t.writefd;
                self.transport_ints = .{ t.mem_id, t.offset, t.size };
            },
            .set_activation => |a| {
                self.act_node = a.node_id;
                self.act_fd = a.signalfd;
                self.act_mem = a.mem_id;
            },
            .port_use_buffers => |u| {
                var it = u.buffers;
                self.use_mix = u.mix_id;
                while (it.next() catch unreachable) |b| {
                    const i = self.n_buffers;
                    self.buf_mem[i] = b.mem_id;
                    self.buf_metas_size[i] = b.metas_size;
                    self.buf_data_id[i] = b.datas[0].data_id;
                    self.buf_maxsize[i] = b.datas[0].max_size;
                    self.buf_data_type[i] = @backingInt(b.datas[0].type);
                    self.n_buffers += 1;
                }
            },
            .command => |c| self.command_id = (c.object() catch unreachable).object_id,
            .@"error" => |e| self.err_res = e.res,
            else => {},
        }
    }
};

fn newNode(rig: *Rig, rec: *Rec) !*ClientNode {
    const node = try rig.remote.createObjectAs(ClientNode, .client_node, "client-node", &.{});
    node.listener = .{ .ctx = rec, .func = Rec.on };
    try rig.remote.dispatch();
    var m = try rig.server.expect(0, 6);
    m.deinit(tgpa);
    return node;
}

test "transport gives both fds and the memory range" {
    var rig = try Rig.init();
    defer rig.deinit();
    var rec: Rec = .{};
    const node = try newNode(&rig, &rec);
    defer node.listener = null;
    const a = try newEventfd();
    defer _ = linux.close(a);
    const b = try newEventfd();
    defer _ = linux.close(b);

    var buf: [128]u8 = undefined;
    var bl = Builder.init(&buf);
    const f = try bl.beginStruct();
    try bl.fd(0);
    try bl.fd(1);
    try bl.int(0);
    try bl.int(16);
    try bl.int(2312);
    bl.end(f);
    try rig.server.send(node.proxy.id, 0, bl.bytesWritten(), &.{ a, b });
    try rig.remote.dispatch();

    defer _ = linux.close(rec.readfd);
    defer _ = linux.close(rec.writefd);
    try testing.expectEqual(@as(u32, 1), rec.events);
    try testing.expect(rec.readfd >= 0 and rec.readfd != a and rec.readfd != b);
    try testing.expect(rec.writefd >= 0 and rec.writefd != rec.readfd);
    try testing.expectEqual([3]u32{ 0, 16, 2312 }, rec.transport_ints);
}

test "set_activation with fd -1 and no memory removes a target" {
    var rig = try Rig.init();
    defer rig.deinit();
    var rec: Rec = .{};
    const node = try newNode(&rig, &rec);
    defer node.listener = null;

    var buf: [128]u8 = undefined;
    var bl = Builder.init(&buf);
    const f = try bl.beginStruct();
    try bl.int(19);
    try bl.fd(-1);
    try bl.int(-1);
    try bl.int(0);
    try bl.int(0);
    bl.end(f);
    try rig.server.send(node.proxy.id, 10, bl.bytesWritten(), &.{});
    try rig.remote.dispatch();

    try testing.expectEqual(@as(u32, 19), rec.act_node);
    try testing.expectEqual(@as(linux.fd_t, -1), rec.act_fd);
    try testing.expectEqual(spa.id_invalid, rec.act_mem);
}

test "an fd index past the message fds is a protocol error" {
    var rig = try Rig.init();
    defer rig.deinit();
    var rec: Rec = .{};
    const node = try newNode(&rig, &rec);
    defer node.listener = null;

    var buf: [128]u8 = undefined;
    var bl = Builder.init(&buf);
    const f = try bl.beginStruct();
    try bl.int(19);
    try bl.fd(3);
    try bl.int(0);
    try bl.int(0);
    try bl.int(2312);
    bl.end(f);
    try rig.server.send(node.proxy.id, 10, bl.bytesWritten(), &.{});
    try testing.expectError(error.Protocol, rig.remote.dispatch());
    try testing.expectEqual(@as(u32, 0), rec.events);
}

test "port_use_buffers decodes the buffers of the observed session" {
    var rig = try Rig.init();
    defer rig.deinit();
    var rec: Rec = .{};
    const node = try newNode(&rig, &rec);
    defer node.listener = null;

    var buf: [512]u8 = undefined;
    var bl = Builder.init(&buf);
    const f = try bl.beginStruct();
    for ([_]i32{ 1, 0, -1, 0, 2 }) |v| try bl.int(v);
    const offsets = [2]i32{ 0, 32816 };
    const mapoffsets = [2]i32{ 48, 32864 };
    for (offsets, mapoffsets) |off, map_off| {
        for ([_]i32{ 2, off, 32816, 1 }) |v| try bl.int(v);
        try bl.id(1);
        try bl.int(32);
        try bl.int(1);
        try bl.id(1);
        try bl.int(48);
        try bl.int(3);
        try bl.int(map_off);
        try bl.int(32768);
    }
    bl.end(f);
    try rig.server.send(node.proxy.id, 8, bl.bytesWritten(), &.{});
    try rig.remote.dispatch();

    try testing.expectEqual(@as(u32, 2), rec.n_buffers);
    try testing.expectEqual(spa.id_invalid, rec.use_mix);
    try testing.expectEqual([2]u32{ 2, 2 }, rec.buf_mem);
    try testing.expectEqual([2]u32{ 32, 32 }, rec.buf_metas_size);
    try testing.expectEqual([2]u32{ 48, 48 }, rec.buf_data_id);
    try testing.expectEqual([2]u32{ 32768, 32768 }, rec.buf_maxsize);
    try testing.expectEqual([2]u32{ 1, 1 }, rec.buf_data_type);
}

test "port_use_buffers with too few fields is a protocol error" {
    var rig = try Rig.init();
    defer rig.deinit();
    var rec: Rec = .{};
    const node = try newNode(&rig, &rec);
    defer node.listener = null;

    var buf: [256]u8 = undefined;
    var bl = Builder.init(&buf);
    const f = try bl.beginStruct();
    for ([_]i32{ 1, 0, -1, 0, 2, 2, 0, 100, 0, 1 }) |v| try bl.int(v);
    bl.end(f);
    try rig.server.send(node.proxy.id, 8, bl.bytesWritten(), &.{});
    try testing.expectError(error.Protocol, rig.remote.dispatch());
}

test "command, error and unknown events reach the listener or the drop counter" {
    var rig = try Rig.init();
    defer rig.deinit();
    var rec: Rec = .{};
    const node = try newNode(&rig, &rec);
    defer node.listener = null;

    var buf: [128]u8 = undefined;
    var bl = Builder.init(&buf);
    const f = try bl.beginStruct();
    const o = try bl.beginObject(@backingInt(spa.ObjectType.command_node), 2);
    bl.end(o);
    bl.end(f);
    try rig.server.send(node.proxy.id, 4, bl.bytesWritten(), &.{});

    bl = Builder.init(&buf);
    const e = try bl.beginStruct();
    try bl.int(@bitCast(node.proxy.id));
    try bl.int(7);
    try bl.int(-2);
    try bl.string("no target node available");
    bl.end(e);
    try rig.server.send(0, 3, bl.bytesWritten(), &.{});

    bl = Builder.init(&buf);
    const u = try bl.beginStruct();
    try bl.int(0);
    bl.end(u);
    try rig.server.send(node.proxy.id, 99, bl.bytesWritten(), &.{});
    try rig.remote.dispatch();

    try testing.expectEqual(@as(u32, 2), rec.command_id);
    try testing.expectEqual(@as(i32, -2), rec.err_res);
    try testing.expectEqual(@as(u32, 2), rec.events);
    try testing.expectEqual(@as(u64, 1), rig.remote.stats.dropped);
}

test "setActive and event send one pod each" {
    var rig = try Rig.init();
    defer rig.deinit();
    var rec: Rec = .{};
    const node = try newNode(&rig, &rec);
    defer node.listener = null;

    try node.setActive(true);
    var event_buf: [32]u8 = undefined;
    var eb = Builder.init(&event_buf);
    const o = try eb.beginObject(@backingInt(spa.ObjectType.event_node), @backingInt(spa.NodeEvent.request_process));
    eb.end(o);
    try node.event(eb.bytesWritten());

    var a = try rig.expectMessage(node.proxy.id, 4);
    defer a.deinit(tgpa);
    var ait = try fieldsOf(a.body);
    try testing.expectEqual(true, try (try ait.next()).?.boolean());

    var m = try rig.server.expect(node.proxy.id, 5);
    defer m.deinit(tgpa);
    var mit = try fieldsOf(m.body);
    const p = (try mit.next()).?;
    try testing.expectEqual(spa.ObjectType.event_node, @as(spa.ObjectType, @fromBackingInt(@intCast((try p.object()).object_type))));
    try testing.expectEqual(@as(u32, 3), (try p.object()).object_id);
}

test "update writes the inline info struct only with the info bit" {
    var rig = try Rig.init();
    defer rig.deinit();
    var rec: Rec = .{};
    const node = try newNode(&rig, &rec);
    defer node.listener = null;

    var pbuf: [32]u8 = undefined;
    var pb = Builder.init(&pbuf);
    try pb.int(5);
    try node.update(.{ .params = true }, &.{pb.bytesWritten()}, null);
    try node.update(.{ .info = true }, &.{}, .{
        .max_input_ports = spa.id_invalid,
        .max_output_ports = 4,
        .change_mask = .{ .flags = true, .props = true },
        .flags = .{ .rt = true },
        .props = &.{.{ "node.name", "x" }},
        .params = &.{.{ .id = .enum_format, .flags = .{ .read = true } }},
    });

    var m1 = try rig.expectMessage(node.proxy.id, 2);
    defer m1.deinit(tgpa);
    var it1 = try fieldsOf(m1.body);
    try testing.expectEqual(@as(i32, 1), try nextInt(&it1));
    try testing.expectEqual(@as(i32, 1), try nextInt(&it1));
    try testing.expectEqual(@as(i32, 5), try nextInt(&it1));
    try testing.expectEqual(spa.Type.none, (try it1.next()).?.type);
    try testing.expectEqual(@as(?pod.Pod, null), try it1.next());

    var m2 = try rig.server.expect(node.proxy.id, 2);
    defer m2.deinit(tgpa);
    var it2 = try fieldsOf(m2.body);
    try testing.expectEqual(@as(i32, 2), try nextInt(&it2));
    try testing.expectEqual(@as(i32, 0), try nextInt(&it2));
    var info = try (try it2.next()).?.structIter();
    try testing.expectEqual(@as(i32, -1), try nextInt(&info));
    try testing.expectEqual(@as(i32, 4), try nextInt(&info));
    try testing.expectEqual(@as(i64, 3), try (try info.next()).?.long());
    try testing.expectEqual(@as(i64, 1), try (try info.next()).?.long());
    try testing.expectEqual(@as(i32, 1), try nextInt(&info));
    try testing.expectEqualStrings("node.name", (try (try info.next()).?.string()).?);
    try testing.expectEqualStrings("x", (try (try info.next()).?.string()).?);
    try testing.expectEqual(@as(i32, 0), try nextInt(&info));
}

test "portUpdate writes the port info without checking the mask" {
    var rig = try Rig.init();
    defer rig.deinit();
    var rec: Rec = .{};
    const node = try newNode(&rig, &rec);
    defer node.listener = null;

    try node.portUpdate(.output, 3, .{ .info = true }, &.{}, .{
        .change_mask = .{ .flags = true, .rate = true, .props = true, .params = true },
        .flags = .{ .no_ref = true },
        .rate = .{ .num = 0, .denom = 1 },
        .props = &.{.{ "port.name", "output_FL" }},
        .params = &.{.{ .id = .format, .flags = .{ .read = true, .write = true } }},
    });
    try node.portUpdate(.input, 0, .{}, &.{}, null);

    var m = try rig.expectMessage(node.proxy.id, 3);
    defer m.deinit(tgpa);
    var it = try fieldsOf(m.body);
    try testing.expectEqual(@as(i32, 1), try nextInt(&it));
    try testing.expectEqual(@as(i32, 3), try nextInt(&it));
    try testing.expectEqual(@as(i32, 2), try nextInt(&it));
    try testing.expectEqual(@as(i32, 0), try nextInt(&it));
    var info = try (try it.next()).?.structIter();
    try testing.expectEqual(@as(i64, 15), try (try info.next()).?.long());
    try testing.expectEqual(@as(i64, 16), try (try info.next()).?.long());
    try testing.expectEqual(@as(i32, 0), try nextInt(&info));
    try testing.expectEqual(@as(i32, 1), try nextInt(&info));
    try testing.expectEqual(@as(i32, 1), try nextInt(&info));
    try testing.expectEqualStrings("port.name", (try (try info.next()).?.string()).?);
    try testing.expectEqualStrings("output_FL", (try (try info.next()).?.string()).?);
    try testing.expectEqual(@as(i32, 1), try nextInt(&info));
    try testing.expectEqual(@as(u32, 4), try (try info.next()).?.id());
    try testing.expectEqual(@as(i32, 6), try nextInt(&info));

    var rm = try rig.server.expect(node.proxy.id, 3);
    defer rm.deinit(tgpa);
    var rit = try fieldsOf(rm.body);
    try testing.expectEqual(@as(i32, 0), try nextInt(&rit));
    try testing.expectEqual(@as(i32, 0), try nextInt(&rit));
    try testing.expectEqual(@as(i32, 0), try nextInt(&rit));
    try testing.expectEqual(@as(i32, 0), try nextInt(&rit));
    try testing.expectEqual(spa.Type.none, (try rit.next()).?.type);
}

test "portBuffers sends the fds with the message" {
    var rig = try Rig.init();
    defer rig.deinit();
    var rec: Rec = .{};
    const node = try newNode(&rig, &rec);
    defer node.listener = null;
    const fd = try newEventfd();
    defer _ = linux.close(fd);

    const datas = [_]ClientNode.PortBufferData{.{ .type = .mem_fd, .fd_index = 0, .flags = .{ .readable = true, .writable = true }, .map_offset = 0, .max_size = 4096 }};
    try node.portBuffers(.output, 1, 0, &.{&datas}, &.{fd});
    try rig.remote.dispatch();

    var m = try rig.server.expect(node.proxy.id, 6);
    defer m.deinit(tgpa);
    try testing.expectEqual(@as(u32, 1), m.n_fds);
    var it = try fieldsOf(m.body);
    for ([_]i32{ 1, 1, 0, 1, 1 }) |want| try testing.expectEqual(want, try nextInt(&it));
    try testing.expectEqual(@as(u32, 2), try (try it.next()).?.id());
    try testing.expectEqual(@as(i64, 0), try (try it.next()).?.fd());
    try testing.expectEqual(@as(i32, 3), try nextInt(&it));
    try testing.expectEqual(@as(i32, 0), try nextInt(&it));
    try testing.expectEqual(@as(i32, 4096), try nextInt(&it));
}

test "getNode binds a Node proxy to the client node" {
    var rig = try Rig.init();
    defer rig.deinit();
    var rec: Rec = .{};
    const node = try newNode(&rig, &rec);
    defer node.listener = null;

    const bound = try node.getNode(null);
    try testing.expectEqual(@as(u32, 4), bound.proxy.id);
    var m = try rig.expectMessage(node.proxy.id, 1);
    defer m.deinit(tgpa);
    var it = try fieldsOf(m.body);
    try testing.expectEqual(@as(i32, 3), try nextInt(&it));
    try testing.expectEqual(@as(i32, 4), try nextInt(&it));
}

test "portBuffers with 32 buffers of one plane fits" {
    var rig = try Rig.init();
    defer rig.deinit();
    var rec: Rec = .{};
    const node = try newNode(&rig, &rec);
    defer node.listener = null;
    const fd = try newEventfd();
    defer _ = linux.close(fd);

    const datas = [_]ClientNode.PortBufferData{.{ .type = .mem_fd, .fd_index = 0, .flags = .{ .readable = true }, .map_offset = 0, .max_size = 4096 }};
    var buffers: [32][]const ClientNode.PortBufferData = undefined;
    for (&buffers) |*b| b.* = &datas;
    try node.portBuffers(.output, 0, 0, &buffers, &.{fd});
    try rig.remote.dispatch();
    var m = try rig.server.expect(node.proxy.id, 6);
    m.deinit(tgpa);
}
