//! Helpers for the tests of `Stream`: a stream on a fake server and the messages the server sends.
const std = @import("std");
const linux = std.os.linux;
const spa = @import("../spa.zig");
const pod = @import("../pod.zig");
const shm = @import("../shm.zig");
const Rig = @import("../testing/Rig.zig");
const FakeServer = @import("../testing/FakeServer.zig");
const DataLoop = @import("../DataLoop.zig");
const Stream = @import("../Stream.zig");

const State = Stream.State;
const Direction = Stream.Direction;
const Buffers = Stream.Buffers;
const testing = std.testing;
const tgpa = Rig.gpa;
const util = @import("../testing/util.zig");

pub const openFds = util.openFds;
pub const fdClosed = util.fdClosed;
pub const fieldsOf = util.fieldsOf;
pub const nextInt = util.nextInt;
pub const expectQuiet = util.expectQuiet;
pub const expectCoreError = util.expectCoreError;
const Builder = pod.Builder;

pub const act_size = 2312;

pub const Rec = struct {
    states: [16]State = undefined,
    n_states: usize = 0,
    errors: u32 = 0,
    err_res: i32 = 0,
    node_ids: [4]u32 = undefined,
    n_ids: usize = 0,
    destroy_on: ?State = null,
    removed: u32 = 0,
    props_seen: u32 = 0,
    props_volume: f32 = 0,
    props_mute: bool = false,
    props_n: usize = 0,
    props_cv: [spa.max_channels]f32 = undefined,
    order: [32]std.meta.Tag(Stream.Event) = undefined,
    n_order: usize = 0,

    pub fn on(ctx: ?*anyopaque, stream: *Stream, event: Stream.Event) void {
        const self: *Rec = @ptrCast(@alignCast(ctx.?));
        self.order[self.n_order] = std.meta.activeTag(event);
        self.n_order += 1;
        switch (event) {
            .removed => self.removed += 1,
            .state => |s| {
                self.states[self.n_states] = s;
                self.n_states += 1;
                if (self.destroy_on == s) stream.destroy();
            },
            .@"error" => |e| {
                self.errors += 1;
                self.err_res = e.res;
            },
            .node_id => |id| {
                self.node_ids[self.n_ids] = id;
                self.n_ids += 1;
            },
            .props => |p| {
                self.props_seen += 1;
                self.props_volume = p.volume;
                self.props_mute = p.mute;
                self.props_n = p.channel_volumes.len;
                @memcpy(self.props_cv[0..p.channel_volumes.len], p.channel_volumes);
            },
        }
    }

    pub fn events(self: *const Rec) []const std.meta.Tag(Stream.Event) {
        return self.order[0..self.n_order];
    }

    pub fn seen(self: *const Rec) []const State {
        return self.states[0..self.n_states];
    }
};

/// A process callback that records what it got. Playback fills channel `i` with `fill[i]`.
pub const Probe = struct {
    calls: u32 = 0,
    frames: u32 = 0,
    rate: u32 = 0,
    n_channels: usize = 0,
    lens: [spa.max_channels]usize = @splat(0),
    /// The first sample of each channel in the last call.
    first: [spa.max_channels]f32 = @splat(0),
    fill: [spa.max_channels]f32 = pair(0.5, -0.5),
    write: bool = false,
    /// True when the channel was all zeros in the last call.
    silent: [spa.max_channels]bool = @splat(false),

    pub fn pair(left: f32, right: f32) [spa.max_channels]f32 {
        var v: [spa.max_channels]f32 = @splat(0);
        v[0] = left;
        v[1] = right;
        return v;
    }

    pub fn process(ctx: ?*anyopaque, stream: *Stream, buffers: Buffers) void {
        _ = stream;
        const self: *Probe = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.frames = buffers.frames;
        self.rate = buffers.rate;
        self.n_channels = buffers.channels.len;
        for (buffers.channels, 0..) |ch, i| {
            self.lens[i] = ch.len;
            self.silent[i] = std.mem.allEqual(f32, ch, 0);
            self.first[i] = if (ch.len > 0) ch[0] else 0;
            if (self.write) @memset(ch, self.fill[i]);
        }
    }
};

pub fn noProcess(ctx: ?*anyopaque, stream: *Stream, buffers: Buffers) void {
    _ = ctx;
    _ = stream;
    _ = buffers;
}

pub const Shared = struct {
    fd: linux.fd_t,
    bytes: []align(std.heap.page_size_min) u8,

    pub fn at(self: Shared, comptime T: type, offset: usize) *T {
        return @ptrCast(@alignCast(self.bytes[offset..].ptr));
    }
};

pub const Harness = struct {
    rig: Rig,
    loop: *DataLoop,
    stream: *Stream,
    node_id: u32,
    rec: Rec = .{},
    fds: [24]linux.fd_t = undefined,
    n_fds: usize = 0,
    maps: [8]Shared = undefined,
    n_maps: usize = 0,
    probe: Probe = .{},
    destroyed: bool = false,

    pub const Setup = struct {
        direction: Direction = .playback,
        channels: []const spa.AudioChannel = &.{ .fl, .fr },
        target: ?[]const u8 = null,
        role: ?[]const u8 = null,
        threaded: bool = false,
        allocator: std.mem.Allocator = Rig.gpa,
        /// Replaces the recording callback.
        process: ?Stream.Process = null,
    };

    pub fn setup(self: *Harness, s: Setup) !void {
        self.* = .{ .rig = try Rig.initWith(.{ .allocator = s.allocator }), .loop = undefined, .stream = undefined, .node_id = 0 };
        errdefer self.rig.deinit();
        self.loop = try DataLoop.init(tgpa, .{ .threaded = s.threaded });
        errdefer self.loop.deinit();
        self.stream = try Stream.create(self.rig.remote, self.loop, .{
            .direction = s.direction,
            .name = "chorus-test",
            .channels = s.channels,
            .role = s.role,
            .target = s.target,
            .process = s.process orelse .{ .ctx = &self.probe, .func = Probe.process },
            .listener = .{ .ctx = &self.rec, .func = Rec.on },
        });
        self.node_id = self.stream.node.proxy.id;
    }

    pub fn deinit(self: *Harness) void {
        if (!self.destroyed) self.stream.destroy();
        self.freeResources();
        self.loop.deinit();
        self.rig.deinit();
    }

    fn freeResources(self: *Harness) void {
        for (self.maps[0..self.n_maps]) |m| _ = linux.munmap(m.bytes.ptr, m.bytes.len);
        for (self.fds[0..self.n_fds]) |fd| _ = linux.close(fd);
        self.n_maps = 0;
        self.n_fds = 0;
    }

    /// Wraps a stream that someone else made, on the rig of `rig`. The caller must not use
    /// `rig` until `release`.
    pub fn attach(rig: *const Rig, loop: *DataLoop, stream: *Stream) Harness {
        return .{ .rig = rig.*, .loop = loop, .stream = stream, .node_id = stream.node.proxy.id };
    }

    /// Hands the rig back and frees the memory and fds of the session. The stream and the
    /// loop stay.
    pub fn release(self: *Harness, rig: *Rig) void {
        self.freeResources();
        rig.* = self.rig;
    }

    pub fn own(self: *Harness, fd: linux.fd_t) linux.fd_t {
        self.fds[self.n_fds] = fd;
        self.n_fds += 1;
        return fd;
    }

    pub fn eventfd(self: *Harness) !linux.fd_t {
        return self.own(try util.newEventfd());
    }

    /// A memfd of `size` bytes that the test also maps.
    pub fn memory(self: *Harness, size: usize) !Shared {
        const rc = linux.memfd_create("chorus-test", 0);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
        const fd = self.own(@intCast(rc));
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(fd, @intCast(size))));
        const addr = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(addr));
        const shared: Shared = .{ .fd = fd, .bytes = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(addr))[0..size] };
        self.maps[self.n_maps] = shared;
        self.n_maps += 1;
        return shared;
    }

    pub fn send(self: *Harness, opcode: u8, body: []const u8, fds: []const linux.fd_t) !void {
        try self.rig.server.send(self.node_id, opcode, body, fds);
    }

    pub fn addMem(self: *Harness, id: i32, fd: linux.fd_t) !void {
        var buf: [128]u8 = undefined;
        var b = Builder.init(&buf);
        const f = try b.beginStruct();
        try b.int(id);
        try b.id(2);
        try b.fd(0);
        try b.int(3);
        b.end(f);
        try self.rig.server.send(0, 6, b.bytesWritten(), &.{fd});
    }

    pub fn boundProps(self: *Harness, global: i32) !void {
        var buf: [128]u8 = undefined;
        var b = Builder.init(&buf);
        const f = try b.beginStruct();
        try b.int(@bitCast(self.node_id));
        try b.int(global);
        try b.dict(&.{.{ "object.serial", "57" }});
        b.end(f);
        try self.rig.server.send(0, 8, b.bytesWritten(), &.{});
    }

    pub fn setActivation(self: *Harness, node: i32, fd: linux.fd_t, mem: i32, offset: i32, size: i32) !void {
        var buf: [128]u8 = undefined;
        var b = Builder.init(&buf);
        const f = try b.beginStruct();
        try b.int(node);
        try b.fd(if (fd >= 0) 0 else -1);
        try b.int(mem);
        try b.int(offset);
        try b.int(size);
        b.end(f);
        try self.send(10, b.bytesWritten(), if (fd >= 0) &.{fd} else &.{});
    }

    pub fn transport(self: *Harness, read: linux.fd_t, write: linux.fd_t, mem: i32, offset: i32, size: i32) !void {
        var buf: [128]u8 = undefined;
        var b = Builder.init(&buf);
        const f = try b.beginStruct();
        try b.fd(0);
        try b.fd(1);
        try b.int(mem);
        try b.int(offset);
        try b.int(size);
        b.end(f);
        try self.send(0, b.bytesWritten(), &.{ read, write });
    }

    pub fn setIo(self: *Harness, io_type: u32, mem: i32, offset: i32, size: i32) !void {
        var buf: [128]u8 = undefined;
        var b = Builder.init(&buf);
        const f = try b.beginStruct();
        try b.id(io_type);
        try b.int(mem);
        try b.int(offset);
        try b.int(size);
        b.end(f);
        try self.send(2, b.bytesWritten(), &.{});
    }

    pub fn mixInfo(self: *Harness, direction: i32, port: i32, mix: i32, peer: i32) !void {
        var buf: [128]u8 = undefined;
        var b = Builder.init(&buf);
        const f = try b.beginStruct();
        for ([_]i32{ direction, port, mix, peer }) |v| try b.int(v);
        try b.dict(&.{});
        b.end(f);
        try self.send(11, b.bytesWritten(), &.{});
    }

    /// Sends port_set_param(Format). With `wrap` every value is a Choice None, as the server does.
    pub fn format(self: *Harness, direction: i32, port: i32, subtype: u32, audio_format: u32, wrap: bool) !void {
        var buf: [256]u8 = undefined;
        var b = Builder.init(&buf);
        const f = try b.beginStruct();
        try b.int(direction);
        try b.int(port);
        try b.id(@backingInt(spa.ParamType.format));
        try b.int(0);
        const o = try b.beginObject(@backingInt(spa.ObjectType.format), @backingInt(spa.ParamType.format));
        const keys = [3]spa.FormatKey{ .media_type, .media_subtype, .audio_format };
        const vals = [3]u32{ 1, subtype, audio_format };
        for (keys, vals) |k, v| {
            try b.prop(@backingInt(k), .{});
            if (wrap) {
                const c = try b.beginChoice(.none, 0);
                try b.id(v);
                b.end(c);
            } else {
                try b.id(v);
            }
        }
        b.end(o);
        b.end(f);
        try self.send(7, b.bytesWritten(), &.{});
    }

    /// Sends port_set_param(Format) whose audio format is a Choice of `kind` with two values.
    pub fn formatChoice(self: *Harness, direction: i32, port: i32, kind: spa.ChoiceType) !void {
        var buf: [256]u8 = undefined;
        var b = Builder.init(&buf);
        const f = try b.beginStruct();
        try b.int(direction);
        try b.int(port);
        try b.id(@backingInt(spa.ParamType.format));
        try b.int(0);
        const o = try b.beginObject(@backingInt(spa.ObjectType.format), @backingInt(spa.ParamType.format));
        try b.prop(@backingInt(spa.FormatKey.media_type), .{});
        try b.id(1);
        try b.prop(@backingInt(spa.FormatKey.media_subtype), .{});
        try b.id(2);
        try b.prop(@backingInt(spa.FormatKey.audio_format), .{});
        const c = try b.beginChoice(kind, 0);
        try b.id(518);
        try b.id(518);
        b.end(c);
        b.end(o);
        b.end(f);
        try self.send(7, b.bytesWritten(), &.{});
    }

    pub fn useBuffers(self: *Harness, direction: i32, port: i32, mix: i32, mem: i32) !void {
        var buf: [512]u8 = undefined;
        var b = Builder.init(&buf);
        const f = try b.beginStruct();
        for ([_]i32{ direction, port, mix, 0, 2 }) |v| try b.int(v);
        const offsets = [2]i32{ 0, 32816 };
        for (offsets) |off| {
            for ([_]i32{ mem, off, 32816, 1 }) |v| try b.int(v);
            try b.id(1);
            try b.int(32);
            try b.int(1);
            try b.id(1);
            try b.int(48);
            try b.int(3);
            try b.int(off + 48);
            try b.int(32768);
        }
        b.end(f);
        try self.send(8, b.bytesWritten(), &.{});
    }

    /// Sends port_use_buffers with no buffers, which clears the buffers of the port.
    pub fn clearBuffers(self: *Harness, direction: i32, port: i32, mix: i32) !void {
        var buf: [128]u8 = undefined;
        var b = Builder.init(&buf);
        const f = try b.beginStruct();
        for ([_]i32{ direction, port, mix, 0, 0 }) |v| try b.int(v);
        b.end(f);
        try self.send(8, b.bytesWritten(), &.{});
    }

    pub fn portSetIo(self: *Harness, direction: i32, port: i32, mix: i32, io_type: u32, mem: i32, offset: i32, size: i32) !void {
        var buf: [128]u8 = undefined;
        var b = Builder.init(&buf);
        const f = try b.beginStruct();
        for ([_]i32{ direction, port, mix }) |v| try b.int(v);
        try b.id(io_type);
        for ([_]i32{ mem, offset, size }) |v| try b.int(v);
        b.end(f);
        try self.send(9, b.bytesWritten(), &.{});
    }

    pub fn command(self: *Harness, id: u32) !void {
        var buf: [128]u8 = undefined;
        var b = Builder.init(&buf);
        const f = try b.beginStruct();
        const o = try b.beginObject(@backingInt(spa.ObjectType.command_node), id);
        b.end(o);
        b.end(f);
        try self.send(4, b.bytesWritten(), &.{});
    }

    pub const Session = struct { mem0: Shared, mem1: Shared, mem2: Shared, mem3: Shared, mem4: Shared };

    /// The server side of the observed session up to command Start.
    pub fn runSession(self: *Harness) !Session {
        return self.runSessionFor(1);
    }

    /// The same session for a capture stream. The ports are inputs and their buffers belong to mix 0.
    pub fn runCaptureSession(self: *Harness) !Session {
        return self.runSessionFor(0);
    }

    fn runSessionFor(self: *Harness, dir: i32) !Session {
        const mix: i32 = if (dir == 1) -1 else 0;
        const own_id = 50;
        const driver_id = 14;
        const mem0 = try self.memory(4096);
        try self.addMem(0, mem0.fd);
        try self.setActivation(own_id, try self.eventfd(), 0, 0, act_size);
        try self.boundProps(own_id);
        try self.transport(try self.eventfd(), try self.eventfd(), 0, 0, act_size);
        try self.setIo(3, 0, 560, 160);
        try self.setIo(7, 0, 560, 1688);
        try self.rig.remote.dispatch();

        try self.mixInfo(dir, 0, 0, 15);
        try self.mixInfo(dir, 1, 0, 16);
        const mem1 = try self.memory(4096);
        try self.addMem(1, mem1.fd);
        try self.setActivation(driver_id, try self.eventfd(), 1, 0, act_size);
        try self.format(dir, 0, 2, 518, true);
        try self.format(dir, 1, 2, 518, true);
        try self.rig.remote.dispatch();

        const mem2 = try self.memory(65632);
        try self.addMem(2, mem2.fd);
        try self.useBuffers(dir, 0, mix, 2);
        try self.setActivation(own_id, -1, -1, 0, 0);
        try self.setIo(7, 1, 560, 1688);
        const mem3 = try self.memory(4096);
        try self.addMem(3, mem3.fd);
        try self.portSetIo(dir, 0, 0, 10, 3, 0, 16);
        const mem4 = try self.memory(65632);
        try self.addMem(4, mem4.fd);
        try self.useBuffers(dir, 1, mix, 4);
        try self.portSetIo(dir, 1, 0, 10, 3, 16, 16);
        try self.command(2);
        try self.rig.remote.dispatch();
        return .{ .mem0 = mem0, .mem1 = mem1, .mem2 = mem2, .mem3 = mem3, .mem4 = mem4 };
    }

    pub fn expectNode(self: *Harness, opcode: u8) !FakeServer.OwnedMessage {
        return self.rig.expectMessage(self.node_id, opcode);
    }

    /// Reads create_object, update and one port_update per channel.
    pub fn skipCreate(self: *Harness) !void {
        var c = try self.rig.expectMessage(0, 6);
        c.deinit(tgpa);
        var u = try self.expectNode(2);
        u.deinit(tgpa);
        for (self.stream.channels[0..self.stream.n_channels]) |_| {
            var p = try self.rig.server.expect(self.node_id, 3);
            p.deinit(tgpa);
        }
    }
};

/// Acts as the driver of the graph. It wakes the node the way the server does and gives access
/// to the buffers and io areas of a session from `Harness.runSession` or `runCaptureSession`.
pub const Driver = struct {
    session: Harness.Session,
    /// The activation of the node under test.
    activation: *shm.NodeActivation,
    /// The position of the driver node.
    position: *shm.IoPosition,
    readfd: linux.fd_t,

    /// Bytes between two buffers in the memory of a port.
    pub const buffer_stride = 32816;

    pub fn init(h: *const Harness, s: Harness.Session) Driver {
        return .{
            .session = s,
            .activation = s.mem0.at(shm.NodeActivation, 0),
            .position = s.mem1.at(shm.IoPosition, 560),
            .readfd = h.stream.readfd,
        };
    }

    /// Writes the timing of a cycle, sets the status of the node and rings its eventfd.
    pub fn wake(self: *Driver, to: shm.ActivationStatus, number: u32, duration: u64, rate: u32) !void {
        shm.store64(&self.position.clock.duration, duration);
        @atomicStore(u32, &self.position.clock.rate.denom, rate, .monotonic);
        @atomicStore(u32, &self.position.clock.cycle, number, .monotonic);
        @atomicStore(i32, &self.activation.state[0].pending, 1, .monotonic);
        @atomicStore(shm.ActivationStatus, &self.activation.status, to, .release);
        const one = std.mem.toBytes(@as(u64, 1));
        try testing.expectEqual(@as(usize, 8), linux.write(self.readfd, &one, one.len));
    }

    pub fn status(self: *const Driver) shm.ActivationStatus {
        return @atomicLoad(shm.ActivationStatus, &self.activation.status, .acquire);
    }

    /// Runs the loop until the node has handled the wakeup. A loop with no thread runs one
    /// iteration and a loop with a thread is awaited.
    pub fn settle(self: *Driver, h: *Harness) !void {
        if (h.loop.thread == null) return h.loop.iterate(100);
        for (0..1000) |_| {
            var pfd = [1]linux.pollfd{.{ .fd = self.readfd, .events = linux.POLL.IN, .revents = 0 }};
            const drained = linux.poll(&pfd, 1, 0) == 0;
            const st = self.status();
            if (drained and st != .triggered and st != .awake) return;
            var ts: linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
            _ = linux.nanosleep(&ts, null);
        }
        return error.Timeout;
    }

    /// One full cycle: wake with TRIGGERED and wait until the node is done.
    pub fn cycle(self: *Driver, h: *Harness, number: u32, duration: u64, rate: u32) !void {
        try self.wake(.triggered, number, duration, rate);
        try self.settle(h);
    }

    fn io(self: *const Driver, port: usize) *shm.IoAsyncBuffers {
        return self.session.mem3.at(shm.IoAsyncBuffers, 16 * port);
    }

    /// The slot that a producer writes in cycle `number`.
    pub fn producerSlot(self: *const Driver, port: usize, number: u32) *shm.IoBuffers {
        return &self.io(port).buffers[1 ^ (number & 1)];
    }

    /// The slot that a consumer reads in cycle `number`.
    pub fn consumerSlot(self: *const Driver, port: usize, number: u32) *shm.IoBuffers {
        return &self.io(port).buffers[number & 1];
    }

    fn memoryOf(self: *const Driver, port: usize) Shared {
        return if (port == 0) self.session.mem2 else self.session.mem4;
    }

    pub fn chunk(self: *const Driver, port: usize, id: usize) *shm.Chunk {
        return self.memoryOf(port).at(shm.Chunk, buffer_stride * id + 32);
    }

    /// The 8192 samples of a buffer.
    pub fn samples(self: *const Driver, port: usize, id: usize) []f32 {
        const first = self.memoryOf(port).at(f32, buffer_stride * id + 48);
        return @as([*]f32, @ptrCast(first))[0..8192];
    }
};
