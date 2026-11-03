//! One audio stream on a PipeWire server. It exports a node with DSP ports, one mono F32P
//! port for each channel, and runs the realtime cycle on a `DataLoop`.
//!
//! The control side runs on the thread that drives the `Remote`. It maps the memory the server
//! sends and keeps it in a model. After every change it builds a new `Rt`, which the data loop
//! thread reads, and swaps it in with `DataLoop.invoke`. The loop thread never sees a half
//! update. Destroy a stream before the `Remote` it uses.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const spa = @import("spa.zig");
const pod = @import("pod.zig");
const shm = @import("shm.zig");
const Proxy = @import("Proxy.zig");
const Remote = @import("Remote.zig");
const MemPool = @import("MemPool.zig");
const DataLoop = @import("DataLoop.zig");
const ClientNode = @import("ClientNode.zig");
const param_set = @import("stream/params.zig");

const Stream = @This();

pub const Direction = enum { playback, capture };
pub const State = enum { connecting, paused, streaming, failed, closed };

pub const Buffers = struct {
    /// position.clock.duration of this cycle.
    frames: u32,
    /// The graph rate, position.clock.rate.denom. It can change from one cycle to the next. The
    /// callback handles that without allocation.
    rate: u32,
    /// One slice for each port, `frames` long. Playback writes them and capture reads them.
    channels: []const []f32,
};

/// `func` runs on the data loop thread. It must not block, allocate or call `Stream` or
/// `Remote` functions. A playback callback writes the samples in `channels`. A capture
/// callback reads them.
pub const Process = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, stream: *Stream, buffers: Buffers) void,
};

/// The message of an error is valid only during the call. A core error does not change the
/// state. The backend decides whether it is fatal.
/// New variants may be added. Switch with an `else` arm.
pub const Event = union(enum) {
    removed,
    state: State,
    @"error": struct { res: i32, message: []const u8 },
    node_id: u32,
    /// The server set the volume or mute. `channel_volumes` is valid only during the call.
    props: struct { volume: f32, mute: bool, channel_volumes: []const f32 },
};

/// The listener may call `destroy`.
pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, stream: *Stream, event: Event) void,
};

pub const Options = struct {
    direction: Direction,
    name: []const u8,
    /// 1 to 64 channels. Each one gets a port.
    channels: []const spa.AudioChannel,
    /// The node.rate hint.
    rate: u32 = 48000,
    /// The node.latency hint, in frames.
    latency_frames: u32 = 1024,
    /// media.role
    role: ?[]const u8 = null,
    /// target.object
    target: ?[]const u8 = null,
    autoconnect: bool = true,
    props: []const [2][]const u8 = &.{},
    process: Process,
    listener: ?Listener = null,
};

/// Counters of the cycle. The loop thread writes them and any thread may read them. They are 32
/// bit and wrap.
pub const Stats = struct {
    /// Cycles that called the process callback.
    cycles: std.atomic.Value(u32) = .init(0),
    /// Cycles that finished without the callback, because the position area or the ports were
    /// missing.
    skipped: std.atomic.Value(u32) = .init(0),
    /// Wakeups that the server counted but the node did not see.
    missed: std.atomic.Value(u32) = .init(0),
    /// Ports that got a scratch slice in a cycle, because their data was missing.
    port_gaps: std.atomic.Value(u32) = .init(0),
    /// Eventfd writes that failed when the node woke a peer.
    trigger_failures: std.atomic.Value(u32) = .init(0),
    /// Messages to the server that could not be queued, and that nothing else reports.
    send_failures: std.atomic.Value(u32) = .init(0),
    /// Latency params that the server set on the node. They are accepted and not applied.
    latency_ignored: std.atomic.Value(u32) = .init(0),
};

pub const SendError = Remote.SendError;
pub const CreateError = SendError || error{InvalidChannels};

const max_buffers = param_set.max_buffers;
const scratch_frames = 8192;
const enomem = -12;
const einval = -22;
const eio = -5;
const enotsup = -95;

fn Map(comptime T: type) type {
    return struct { ptr: *T, mapping: MemPool.Mapping };
}

/// A node that the server wants us to wake after a cycle.
pub const Target = struct {
    id: u32,
    fd: linux.fd_t,
    activation: *shm.NodeActivation,
};

pub const Io = union(enum) {
    none,
    plain: *shm.IoBuffers,
    async: *shm.IoAsyncBuffers,
};

pub const RtBuffer = struct {
    chunk: *shm.Chunk,
    data: [*]f32,
    /// In bytes.
    maxsize: u32,
};

pub const RtMix = struct {
    id: u32,
    io: Io,
    buffers: []const RtBuffer,
};

pub const RtPort = struct {
    /// The buffers of an output port. They do not depend on the mix.
    buffers: []const RtBuffer,
    mixes: []const RtMix,
};

/// What the data loop thread reads. Only `invoke` callbacks write it.
pub const Rt = struct {
    activation: ?*shm.NodeActivation = null,
    position: ?*shm.IoPosition = null,
    targets: []const Target = &.{},
    ports: []const RtPort = &.{},
    /// Zeros for a port that has no data, `scratch_frames` for each port.
    scratch: []f32 = &.{},
    /// The gain of each channel at the end of the next cycle.
    gain: [spa.max_channels]f32 = @splat(1),
};

/// The volume and mute that the server set on the node.
const Controls = struct {
    volume: f32 = 1,
    mute: bool = false,
    soft_mute: bool = false,
    channel_volumes: [spa.max_channels]f32 = @splat(1),
    soft_volumes: [spa.max_channels]f32 = @splat(1),
    have_soft: bool = false,
};

const TargetModel = struct { rt: Target, mapping: MemPool.Mapping };

const BufferModel = struct {
    rt: RtBuffer,
    mapping: MemPool.Mapping,
    data_mapping: ?MemPool.Mapping = null,
};

const BufferSet = struct {
    items: std.ArrayList(BufferModel) = .empty,
};

const MixModel = struct {
    id: u32,
    io: Io = .none,
    io_mapping: ?MemPool.Mapping = null,
    buffers: BufferSet = .{},
};

const PortModel = struct {
    format_ok: bool = false,
    buffers: BufferSet = .{},
    mixes: std.ArrayList(MixModel) = .empty,
};

gpa: std.mem.Allocator,
remote: *Remote,
loop: *DataLoop,
node: *ClientNode,
direction: Direction,
process: Process,
listener: ?Listener,
channels: [spa.max_channels]spa.AudioChannel,
n_channels: usize,
rate: u32,

state_: State = .connecting,
controls: Controls = .{},
/// Toggles with every Props change, so that readers of the node params look again.
props_serial: bool = false,
want_active: bool = true,
active_sent: bool = false,
fallback_id: ?u32 = null,
announced_id: ?u32 = null,

/// The eventfd the server writes to wake the node. The data loop thread reads it too.
readfd: linux.fd_t = -1,
activation: ?Map(shm.NodeActivation) = null,
clock: ?Map(shm.IoClock) = null,
position: ?Map(shm.IoPosition) = null,
targets: std.ArrayList(TargetModel) = .empty,
ports: []PortModel = &.{},
/// Mappings that the data loop thread may still use until the next swap.
garbage: std.ArrayList(MemPool.Mapping) = .empty,

rt: Rt = .{},
/// The next output buffer of each port. Only the loop thread uses it.
cursor: [spa.max_channels]u32 = @splat(0),
/// The gain at the end of the last cycle. Only the loop thread uses it.
gain_prev: [spa.max_channels]f32 = @splat(1),
stats: Stats = .{},
/// True while `readfd` is in the loop. Only `invoke` callbacks write it.
source_on: bool = false,

busy: u32 = 0,
dead: bool = false,
torn_down: bool = false,

/// Sends the node and its ports to the server. The stream is active unless `setActive(false)`
/// is called.
pub fn create(remote: *Remote, loop: *DataLoop, options: Options) CreateError!*Stream {
    const n = options.channels.len;
    if (n == 0 or n > spa.max_channels) return error.InvalidChannels;
    const gpa = remote.gpa;

    const self = try gpa.create(Stream);
    errdefer gpa.destroy(self);
    const ports = try gpa.alloc(PortModel, n);
    errdefer gpa.free(ports);
    @memset(ports, .{});
    self.* = .{
        .gpa = gpa,
        .remote = remote,
        .loop = loop,
        .node = undefined,
        .direction = options.direction,
        .process = options.process,
        .listener = options.listener,
        .channels = undefined,
        .n_channels = n,
        .rate = options.rate,
        .ports = ports,
    };
    @memcpy(self.channels[0..n], options.channels);

    const props = try gpa.alloc([2][]const u8, 10 + options.props.len);
    defer gpa.free(props);
    var rate_buf: [24]u8 = undefined;
    var latency_buf: [32]u8 = undefined;
    const rate = std.fmt.bufPrint(&rate_buf, "1/{d}", .{options.rate}) catch unreachable;
    const latency = std.fmt.bufPrint(&latency_buf, "{d}/{d}", .{ options.latency_frames, options.rate }) catch unreachable;
    const playback = options.direction == .playback;
    var count: usize = 0;
    const fixed = [_][2][]const u8{
        .{ "media.class", if (playback) "Stream/Output/Audio" else "Stream/Input/Audio" },
        .{ "media.type", "Audio" },
        .{ "media.category", if (playback) "Playback" else "Capture" },
        .{ "node.name", options.name },
        .{ "node.rate", rate },
        .{ "node.latency", latency },
        .{ "node.autoconnect", if (options.autoconnect) "true" else "false" },
        .{ "node.async", "true" },
    };
    for (fixed) |kv| {
        props[count] = kv;
        count += 1;
    }
    if (options.role) |role| {
        props[count] = .{ "media.role", role };
        count += 1;
    }
    if (options.target) |target| {
        props[count] = .{ "target.object", target };
        count += 1;
    }
    for (options.props) |kv| {
        props[count] = kv;
        count += 1;
    }

    const node = try remote.createObjectAs(ClientNode, .client_node, "client-node", props[0..count]);
    self.node = node;
    node.listener = .{ .ctx = self, .func = onNodeEvent };
    errdefer {
        node.listener = null;
        node.proxy.destroy() catch remote.release(&node.proxy);
    }

    try self.sendNodeUpdate(.{ .flags = true, .props = true, .params = true }, props[0..count]);
    for (0..n) |i| try self.sendPortUpdate(i, false);
    return self;
}

/// Sends the node params and the node info. The server replaces the whole list of params with
/// each update.
fn sendNodeUpdate(self: *Stream, mask: ClientNode.NodeInfoMask, props: []const [2][]const u8) SendError!void {
    const dir = self.ownDirection();
    const chans = self.channels[0..self.n_channels];
    const playback = self.direction == .playback;
    const c = &self.controls;
    var params: param_set.Params = .{};
    const no_space = error.NoSpace;
    params.push(param_set.buildNodeFormat(params.rest(), .enum_format, self.rate, chans) catch return no_space);
    params.push(param_set.buildEnumPortConfig(params.rest(), dir) catch return no_space);
    params.push(param_set.buildPortConfig(params.rest(), dir, chans) catch return no_space);
    params.push(param_set.buildLatency(params.rest(), .input) catch return no_space);
    params.push(param_set.buildLatency(params.rest(), .output) catch return no_space);
    params.push(param_set.buildProps(params.rest(), .{
        .volume = c.volume,
        .mute = c.mute,
        .soft_mute = c.soft_mute,
        .channel_volumes = c.channel_volumes[0..self.n_channels],
        .soft_volumes = c.soft_volumes[0..self.n_channels],
    }) catch return no_space);
    const info_params = [_]ClientNode.ParamInfo{
        .{ .id = .enum_format, .flags = .{ .serial = true, .read = true } },
        .{ .id = .format, .flags = .{ .serial = true, .write = true } },
        .{ .id = .enum_port_config, .flags = .{ .serial = true, .read = true } },
        .{ .id = .port_config, .flags = .{ .serial = true, .read = true, .write = true } },
        .{ .id = .latency, .flags = .{ .read = true, .write = true } },
        .{ .id = .props, .flags = .{ .serial = self.props_serial, .read = true, .write = true } },
    };
    try self.node.update(.{ .params = true, .info = true }, params.items[0..params.n], .{
        .max_input_ports = spa.id_invalid,
        .max_output_ports = spa.id_invalid,
        .change_mask = mask,
        .flags = .{ .rt = true, .out_port_config = playback, .in_port_config = !playback },
        .props = props,
        .params = &info_params,
    });
}

/// Starts or stops the scheduling of the node. Before the server sends the transport the
/// request is kept and sent with it.
pub fn setActive(self: *Stream, active: bool) SendError!void {
    self.want_active = active;
    if (self.torn_down or self.activation == null) return;
    if (self.active_sent == active) return;
    try self.node.setActive(active);
    self.active_sent = active;
}

/// Stops the stream, tells the server and frees the stream. The listener gets `closed`
/// first. Do not call it from the process callback.
pub fn destroy(self: *Stream) void {
    if (self.torn_down) return;
    self.torn_down = true;
    if (self.state_ != .closed) {
        self.state_ = .closed;
        self.emit(.{ .state = .closed });
    }

    var stop: Stop = .{ .stream = self };
    self.loop.invoke(&stop, applyStop);
    freeRt(self.gpa, stop.old);

    if (!self.node.proxy.removed) {
        self.node.setActive(false) catch self.countSendFailure();
    }
    self.node.listener = null;
    self.node.proxy.destroy() catch self.remote.release(&self.node.proxy);
    self.listener = null;
    self.releaseAll();
    if (self.busy == 0) self.gpa.destroy(self) else self.dead = true;
}

pub fn state(self: *const Stream) State {
    return self.state_;
}

/// The global id of the node, when the server has told it. Before bound_props arrives this is the
/// id of the first set_activation, when there is one.
pub fn nodeId(self: *const Stream) ?u32 {
    return self.node.proxy.global_id orelse self.fallback_id;
}

fn emit(self: *Stream, event: Event) void {
    if (self.listener) |l| l.func(l.ctx, self, event);
}

/// The listener may destroy the stream, so call this last.
fn setState(self: *Stream, next: State) void {
    if (self.state_ == next or self.state_ == .closed) return;
    if (self.state_ == .failed and next != .closed) return;
    self.state_ = next;
    self.emit(.{ .state = next });
}

fn countSendFailure(self: *Stream) void {
    _ = self.stats.send_failures.fetchAdd(1, .monotonic);
}

fn sendCoreError(self: *Stream, res: i32, message: []const u8) void {
    var buf: [320]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = b.beginStruct() catch return;
    b.int(@bitCast(self.node.proxy.id)) catch return;
    b.int(@bitCast(self.node.last_seq)) catch return;
    b.int(res) catch return;
    b.string(message[0..@min(message.len, 200)]) catch return;
    b.end(f);
    self.remote.sendBody(0, 4, b.bytesWritten()) catch self.countSendFailure();
}

/// Tells the server, stops the cycle and gives the listener the error and the new state. The
/// listener may destroy the stream, so call this last.
fn fail(self: *Stream, res: i32, message: []const u8) void {
    if (self.state_ == .failed or self.state_ == .closed) return;
    self.sendCoreError(res, message);
    var stop_req: Pause = .{ .stream = self };
    self.loop.invoke(&stop_req, applyPause);
    self.setState(.failed);
    if (self.torn_down) return;
    self.emit(.{ .@"error" = .{ .res = res, .message = message } });
}

fn failNoMemory(self: *Stream) void {
    self.fail(enomem, "out of memory");
}

// Changes of the rt state. Each runs on the loop thread, inside invoke.

const Swap = struct { stream: *Stream, rt: Rt };

fn applySwap(ctx: *anyopaque) void {
    const swap: *Swap = @ptrCast(@alignCast(ctx));
    const old = swap.stream.rt;
    swap.stream.rt = swap.rt;
    swap.rt = old;
}

const Start = struct { stream: *Stream, err: ?DataLoop.Error = null };

fn applyStart(ctx: *anyopaque) void {
    const req: *Start = @ptrCast(@alignCast(ctx));
    const self = req.stream;
    const act = self.rt.activation orelse return;
    @atomicStore(shm.ActivationStatus, &act.status, .finished, .release);
    if (self.source_on) return;
    self.loop.addSource(self.readfd, self, onReadable) catch |err| {
        req.err = err;
        return;
    };
    self.source_on = true;
}

const Pause = struct { stream: *Stream };

fn applyPause(ctx: *anyopaque) void {
    const req: *Pause = @ptrCast(@alignCast(ctx));
    const self = req.stream;
    if (self.rt.activation) |act| {
        _ = @atomicRmw(shm.ActivationStatus, &act.status, .Xchg, .inactive, .acq_rel);
    }
    if (self.source_on) {
        self.loop.removeSource(self.readfd);
        self.source_on = false;
    }
}

const Stop = struct { stream: *Stream, old: Rt = .{} };

fn applyStop(ctx: *anyopaque) void {
    const req: *Stop = @ptrCast(@alignCast(ctx));
    const self = req.stream;
    if (self.source_on) {
        self.loop.removeSource(self.readfd);
        self.source_on = false;
    }
    req.old = self.rt;
    self.rt = .{};
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// One wakeup of the node, on the loop thread. It reads only `rt`.
fn onReadable(ctx: *anyopaque) void {
    const self: *Stream = @ptrCast(@alignCast(ctx));
    var count: u64 = undefined;
    const rc = linux.read(self.readfd, std.mem.asBytes(&count), @sizeOf(u64));
    if (linux.errno(rc) != .SUCCESS or rc != @sizeOf(u64)) return;
    if (count > 1) _ = self.stats.missed.fetchAdd(@truncate(count - 1), .monotonic);

    const rt = &self.rt;
    const act = rt.activation orelse return;
    if (count > 1) _ = @atomicRmw(u32, &act.xrun_count, .Add, @truncate(count - 1), .monotonic);
    if (@cmpxchgStrong(shm.ActivationStatus, &act.status, .triggered, .awake, .acquire, .monotonic) != null) return;
    shm.store64(&act.awake_time, nowNs());
    _ = @atomicRmw(u32, &act.bits, .And, ~@as(u32, shm.pending_sync_bit), .acq_rel);

    if (self.runPorts(rt)) {
        _ = self.stats.cycles.fetchAdd(1, .monotonic);
    } else {
        _ = self.stats.skipped.fetchAdd(1, .monotonic);
    }

    @atomicStore(i32, &act.state[0].status, shm.status_need_data | shm.status_have_data, .release);
    const finish = nowNs();
    shm.store64(&act.finish_time, finish);
    // A node that was paused during the cycle is not awake any more and wakes nobody.
    if (@cmpxchgStrong(shm.ActivationStatus, &act.status, .awake, .finished, .release, .monotonic) != null) return;
    self.triggerPeers(act, rt.targets, finish);
}

/// Counts down the pending value of each target and wakes the ones that reach zero. An async
/// node on a server with `server_version` 1 or more wakes nobody.
fn triggerPeers(self: *Stream, act: *shm.NodeActivation, targets: []const Target, nsec: u64) void {
    const version = @atomicLoad(u32, &act.server_version, .monotonic);
    const flags = @atomicLoad(u32, &act.flags, .monotonic);
    if (version >= 1 and flags & shm.activation_flag_async != 0) return;
    for (targets) |t| {
        const left = @atomicRmw(i32, &t.activation.state[0].pending, .Sub, 1, .acq_rel) - 1;
        if (left != 0) continue;
        if (version >= 1) {
            const idle = shm.ActivationStatus.not_triggered;
            if (@cmpxchgStrong(shm.ActivationStatus, &t.activation.status, idle, .triggered, .acq_rel, .monotonic) != null) continue;
        } else {
            @atomicStore(shm.ActivationStatus, &t.activation.status, .triggered, .seq_cst);
        }
        shm.store64(&t.activation.signal_time, nsec);
        const one = std.mem.toBytes(@as(u64, 1));
        const rc = linux.write(t.fd, &one, one.len);
        if (linux.errno(rc) != .SUCCESS or rc != one.len) {
            _ = self.stats.trigger_failures.fetchAdd(1, .monotonic);
        }
    }
}

/// Writes `src` times a gain that moves in a straight line from `from` to `to`. The last sample
/// has the gain `to`.
fn scaleInto(dst: []f32, src: []const f32, from: f32, to: f32) void {
    std.debug.assert(dst.len == src.len);
    if (dst.len == 0) return;
    const last = dst.len - 1;
    const step = (to - from) / @as(f32, @floatFromInt(dst.len));
    var g = from;
    for (dst[0..last], src[0..last]) |*d, s| {
        g += step;
        d.* = s * g;
    }
    dst[last] = src[last] * to;
}

/// The io slot of this cycle. `side` is 1 for the producer of a port and 0 for the consumer.
fn slotOf(io: Io, side: u32, cycle: u32) ?*shm.IoBuffers {
    return switch (io) {
        .none => null,
        .plain => |p| p,
        .async => |a| &a.buffers[side ^ (cycle & 1)],
    };
}

/// The mix that carries the data of a port: the first one that has an io area.
fn firstMix(port: RtPort) ?RtMix {
    for (port.mixes) |mix| {
        if (mix.io != .none) return mix;
    }
    return null;
}

/// Calls the process callback. A port that has no io area, buffer or valid data gets a scratch
/// slice of zeros and counts in `stats.port_gaps`. Returns false only when the position is
/// missing. The shared memory is read once for each value.
fn runPorts(self: *Stream, rt: *const Rt) bool {
    const position = rt.position orelse return false;
    const n = rt.ports.len;
    if (n != self.n_channels or rt.scratch.len != n * scratch_frames) return false;
    const duration = shm.load64(&position.clock.duration);
    const rate = @atomicLoad(u32, &position.clock.rate.denom, .monotonic);
    const cycle = @atomicLoad(u32, &position.clock.cycle, .monotonic);
    const playback = self.direction == .playback;

    var frames: usize = @min(duration, scratch_frames);
    var slots: [spa.max_channels]?*shm.IoBuffers = @splat(null);
    var chosen: [spa.max_channels]?u32 = @splat(null);
    // Capture only: the first sample and the number of samples of the checked chunk.
    var first: [spa.max_channels]usize = undefined;
    var avail: [spa.max_channels]usize = undefined;

    for (rt.ports, 0..) |port, i| {
        const mix = firstMix(port);
        if (mix) |m| slots[i] = slotOf(m.io, if (playback) 1 else 0, cycle);
        if (playback) {
            if (slots[i] != null and port.buffers.len > 0) {
                const id = self.cursor[i] % @as(u32, @intCast(port.buffers.len));
                chosen[i] = id;
                frames = @min(frames, port.buffers[id].maxsize / @sizeOf(f32));
            }
        } else if (slots[i]) |slot| {
            if (@atomicLoad(i32, &slot.status, .acquire) != shm.status_have_data) continue;
            const id = @atomicLoad(u32, &slot.buffer_id, .monotonic);
            if (id >= mix.?.buffers.len) continue;
            const buf = mix.?.buffers[id];
            const offset = @atomicLoad(u32, &buf.chunk.offset, .monotonic);
            const size = @atomicLoad(u32, &buf.chunk.size, .monotonic);
            if (offset % @sizeOf(f32) != 0 or offset > buf.maxsize) continue;
            chosen[i] = id;
            first[i] = offset / @sizeOf(f32);
            avail[i] = @min(size, buf.maxsize - offset) / @sizeOf(f32);
            frames = @min(frames, avail[i]);
        }
    }

    var slices: [spa.max_channels][]f32 = undefined;
    for (rt.ports, 0..) |port, i| {
        if (chosen[i]) |id| {
            if (playback) {
                slices[i] = port.buffers[id].data[0..frames];
            } else {
                const src = (firstMix(port).?.buffers[id].data + first[i])[0..frames];
                if (rt.gain[i] == 1 and self.gain_prev[i] == 1) {
                    slices[i] = src;
                } else {
                    // The buffer may have other readers, so the gain goes to a copy.
                    const copy = rt.scratch[i * scratch_frames ..][0..frames];
                    scaleInto(copy, src, self.gain_prev[i], rt.gain[i]);
                    slices[i] = copy;
                }
            }
        } else {
            const scratch = rt.scratch[i * scratch_frames ..][0..frames];
            @memset(scratch, 0);
            slices[i] = scratch;
            _ = self.stats.port_gaps.fetchAdd(1, .monotonic);
        }
    }
    self.process.func(self.process.ctx, self, .{
        .frames = @intCast(frames),
        .rate = rate,
        .channels = slices[0..n],
    });
    if (playback) {
        for (0..n) |i| {
            if (chosen[i] == null or (rt.gain[i] == 1 and self.gain_prev[i] == 1)) continue;
            scaleInto(slices[i], slices[i], self.gain_prev[i], rt.gain[i]);
        }
    }
    self.gain_prev = rt.gain;

    for (rt.ports, 0..) |port, i| {
        if (playback) {
            const id = chosen[i] orelse continue;
            const chunk = port.buffers[id].chunk;
            @atomicStore(u32, &chunk.offset, 0, .monotonic);
            @atomicStore(u32, &chunk.size, @intCast(frames * @sizeOf(f32)), .monotonic);
            @atomicStore(i32, &chunk.stride, @sizeOf(f32), .monotonic);
            @atomicStore(i32, &chunk.flags, 0, .monotonic);
            for (port.mixes) |mix| {
                const slot = slotOf(mix.io, 1, cycle) orelse continue;
                @atomicStore(u32, &slot.buffer_id, id, .monotonic);
                @atomicStore(i32, &slot.status, shm.status_have_data, .release);
            }
            self.cursor[i] = id +% 1;
        } else if (slots[i]) |slot| {
            @atomicStore(i32, &slot.status, shm.status_need_data, .release);
        }
    }
    return true;
}

fn freeRt(gpa: std.mem.Allocator, rt: Rt) void {
    gpa.free(rt.targets);
    for (rt.ports) |port| {
        gpa.free(port.buffers);
        for (port.mixes) |mix| gpa.free(mix.buffers);
        gpa.free(port.mixes);
    }
    gpa.free(rt.ports);
    gpa.free(rt.scratch);
}

fn buffersToRt(gpa: std.mem.Allocator, set: BufferSet) error{OutOfMemory}![]const RtBuffer {
    const out = try gpa.alloc(RtBuffer, set.items.items.len);
    for (set.items.items, out) |item, *o| o.* = item.rt;
    return out;
}

fn buildRt(self: *Stream) error{OutOfMemory}!Rt {
    const gpa = self.gpa;
    var rt: Rt = .{
        .activation = if (self.activation) |m| m.ptr else null,
        .position = if (self.position) |m| m.ptr else null,
        .gain = gainOf(&self.controls, self.n_channels),
    };
    errdefer freeRt(gpa, rt);

    const targets = try gpa.alloc(Target, self.targets.items.len);
    for (self.targets.items, targets) |t, *o| o.* = t.rt;
    rt.targets = targets;

    const ports = try gpa.alloc(RtPort, self.ports.len);
    for (ports) |*p| p.* = .{ .buffers = &.{}, .mixes = &.{} };
    rt.ports = ports;
    rt.scratch = try gpa.alloc(f32, ports.len * scratch_frames);
    @memset(rt.scratch, 0);
    for (self.ports, ports) |model, *out| {
        out.buffers = try buffersToRt(gpa, model.buffers);
        const mixes = try gpa.alloc(RtMix, model.mixes.items.len);
        for (mixes) |*m| m.* = .{ .id = 0, .io = .none, .buffers = &.{} };
        out.mixes = mixes;
        for (model.mixes.items, mixes) |mm, *om| {
            om.* = .{ .id = mm.id, .io = mm.io, .buffers = try buffersToRt(gpa, mm.buffers) };
        }
    }
    return rt;
}

/// Gives the loop thread the new state of the model, and then drops what it used before.
fn publish(self: *Stream) void {
    const new = self.buildRt() catch return self.failNoMemory();
    var swap: Swap = .{ .stream = self, .rt = new };
    self.loop.invoke(&swap, applySwap);
    freeRt(self.gpa, swap.rt);
    for (self.garbage.items) |m| m.unmap();
    self.garbage.clearRetainingCapacity();
}

/// The most mappings that one handler can discard: every mapping of the model.
fn mappingCount(self: *const Stream) usize {
    var n: usize = 3 + self.targets.items.len;
    for (self.ports) |port| {
        n += port.buffers.items.items.len * 2;
        for (port.mixes.items) |mix| n += 1 + mix.buffers.items.items.len * 2;
    }
    return n;
}

/// Makes room in the garbage list for everything that a handler can discard, so that `discard`
/// cannot fail after the model changed.
fn reserveGarbage(self: *Stream) error{OutOfMemory}!void {
    try self.garbage.ensureTotalCapacity(self.gpa, self.garbage.items.len + self.mappingCount());
}

/// Keeps `m` mapped until the next `publish`. The caller reserved the room with `reserveGarbage`.
fn discard(self: *Stream, m: MemPool.Mapping) void {
    std.debug.assert(self.garbage.items.len < self.garbage.capacity);
    self.garbage.appendAssumeCapacity(m);
}

fn discardSet(self: *Stream, set: *BufferSet) void {
    for (set.items.items) |item| {
        self.discard(item.mapping);
        if (item.data_mapping) |m| self.discard(m);
    }
    set.items.clearRetainingCapacity();
}

fn releaseAll(self: *Stream) void {
    const gpa = self.gpa;
    if (self.activation) |m| m.mapping.unmap();
    if (self.clock) |m| m.mapping.unmap();
    if (self.position) |m| m.mapping.unmap();
    for (self.targets.items) |t| {
        closeFd(t.rt.fd);
        t.mapping.unmap();
    }
    self.targets.deinit(gpa);
    for (self.ports) |*port| {
        releaseSet(gpa, &port.buffers);
        for (port.mixes.items) |*mix| {
            if (mix.io_mapping) |m| m.unmap();
            releaseSet(gpa, &mix.buffers);
        }
        port.mixes.deinit(gpa);
    }
    gpa.free(self.ports);
    for (self.garbage.items) |m| m.unmap();
    self.garbage.deinit(gpa);
    closeFd(self.readfd);
    self.readfd = -1;
}

fn releaseSet(gpa: std.mem.Allocator, set: *BufferSet) void {
    for (set.items.items) |item| {
        item.mapping.unmap();
        if (item.data_mapping) |m| m.unmap();
    }
    set.items.deinit(gpa);
}

fn closeFd(fd: linux.fd_t) void {
    if (fd >= 0) _ = linux.close(fd);
}

// Events of the node. They run on the thread of the Remote.

fn onNodeEvent(ctx: ?*anyopaque, node: *ClientNode, ev: ClientNode.Event) void {
    _ = node;
    const self: *Stream = @ptrCast(@alignCast(ctx.?));
    self.busy += 1;
    self.handleEvent(ev);
    if (!self.torn_down) self.refreshNodeId();
    self.busy -= 1;
    if (self.dead and self.busy == 0) self.gpa.destroy(self);
}

/// Emits the global id once, from bound_props. The id of the first set_activation is only a
/// stand in for `nodeId`, so it is never emitted.
fn refreshNodeId(self: *Stream) void {
    const id = self.node.proxy.global_id orelse return;
    if (self.announced_id == id) return;
    self.announced_id = id;
    self.emit(.{ .node_id = id });
}

fn handleEvent(self: *Stream, ev: ClientNode.Event) void {
    if (self.state_ == .failed) {
        switch (ev) {
            .@"error", .removed => {},
            else => {
                ClientNode.closeEventFds(ev);
                return;
            },
        }
    }
    self.reserveGarbage() catch {
        ClientNode.closeEventFds(ev);
        return self.failNoMemory();
    };
    switch (ev) {
        .transport => |t| self.onTransport(t.readfd, t.writefd, t.mem_id, t.offset, t.size),
        .set_activation => |a| self.onSetActivation(a.node_id, a.signalfd, a.mem_id, a.offset, a.size),
        .set_io => |s| self.onSetIo(s.id, s.mem_id, s.offset, s.size),
        .port_set_mix_info => |m| self.onMixInfo(m.direction, m.port_id, m.mix_id, m.peer_id),
        .port_set_param => |p| self.onPortSetParam(p.direction, p.port_id, p.id, p.param),
        .port_use_buffers => |u| self.onUseBuffers(u),
        .port_set_io => |p| self.onPortSetIo(p.direction, p.port_id, p.mix_id, p.id, p.mem_id, p.offset, p.size),
        .command => |c| self.onCommand(c),
        .add_port, .remove_port => self.sendCoreError(enotsup, "the ports cannot change"),
        .set_param => |p| self.onNodeSetParam(p.id, p.param),
        .event => {},
        .removed => self.onNodeRemoved(),
        .bound => {},
        .@"error" => |e| self.emit(.{ .@"error" = .{ .res = e.res, .message = e.message } }),
    }
}

const MapError = error{BadArea};

fn mapArea(self: *Stream, comptime T: type, mem_id: u32, offset: u32, size: u32) MapError!Map(T) {
    if (size < @sizeOf(T) or offset % @alignOf(T) != 0) return error.BadArea;
    const got = self.remote.mem.mapAs(T, mem_id, offset) catch return error.BadArea;
    return .{ .ptr = @alignCast(got.ptr), .mapping = got.mapping };
}

fn onTransport(self: *Stream, readfd: linux.fd_t, writefd: linux.fd_t, mem_id: u32, offset: u32, size: u32) void {
    closeFd(writefd);
    const act = self.mapArea(shm.NodeActivation, mem_id, offset, size) catch {
        closeFd(readfd);
        return self.fail(einval, "the transport memory is not usable");
    };
    @atomicStore(u32, &act.ptr.client_version, 1, .release);

    // A new transport replaces the old one. The cycle stops until the next Start.
    var stop_req: Pause = .{ .stream = self };
    self.loop.invoke(&stop_req, applyPause);
    closeFd(self.readfd);
    self.readfd = readfd;
    var old_targets = self.targets;
    self.targets = .empty;
    if (self.activation) |old| {
        // The old transport takes its targets and io areas with it.
        self.discard(old.mapping);
        for (old_targets.items) |t| self.discard(t.mapping);
        if (self.clock) |m| self.discard(m.mapping);
        if (self.position) |m| self.discard(m.mapping);
        self.clock = null;
        self.position = null;
    } else {
        self.targets = old_targets;
        old_targets = .empty;
    }
    self.activation = act;
    self.publish();
    self.syncDriverId();
    for (old_targets.items) |t| closeFd(t.rt.fd);
    old_targets.deinit(self.gpa);
    if (self.torn_down or self.state_ == .failed) return;

    if (self.want_active) {
        self.node.setActive(true) catch return self.fail(eio, "cannot activate the node");
        self.active_sent = true;
    }
    switch (self.state_) {
        .connecting, .streaming => self.setState(.paused),
        else => {},
    }
}

fn onSetActivation(self: *Stream, node_id: u32, signalfd: linux.fd_t, mem_id: u32, offset: u32, size: u32) void {
    // The first entry is the node itself, and it comes before the global id is known.
    if (self.fallback_id == null) self.fallback_id = node_id;

    var found: ?usize = null;
    for (self.targets.items, 0..) |t, i| {
        if (t.rt.id == node_id) found = i;
    }
    if (mem_id == spa.id_invalid) {
        closeFd(signalfd);
        if (found) |i| {
            const old = self.targets.swapRemove(i);
            closeFd(old.rt.fd);
            self.discard(old.mapping);
            self.publish();
        }
        return;
    }

    const act = self.mapArea(shm.NodeActivation, mem_id, offset, size) catch {
        closeFd(signalfd);
        return self.fail(einval, "the activation memory is not usable");
    };
    if (signalfd < 0) {
        act.mapping.unmap();
        return self.fail(einval, "the activation has no signal fd");
    }
    const entry: TargetModel = .{ .rt = .{ .id = node_id, .fd = signalfd, .activation = act.ptr }, .mapping = act.mapping };
    if (found) |i| {
        const old = self.targets.items[i];
        closeFd(old.rt.fd);
        self.discard(old.mapping);
        self.targets.items[i] = entry;
    } else {
        self.targets.append(self.gpa, entry) catch {
            closeFd(signalfd);
            act.mapping.unmap();
            return self.failNoMemory();
        };
    }
    self.publish();
}

fn onSetIo(self: *Stream, io: spa.IoType, mem_id: u32, offset: u32, size: u32) void {
    switch (io) {
        .clock => self.setArea(shm.IoClock, &self.clock, mem_id, offset, size),
        .position => {
            self.setArea(shm.IoPosition, &self.position, mem_id, offset, size);
            self.syncDriverId();
        },
        else => {},
    }
}

/// Tells the server which driver the node follows. The server skips the node until the
/// activation holds the clock id of the position area.
fn syncDriverId(self: *Stream) void {
    const act = self.activation orelse return;
    const pos = self.position orelse return;
    const id = @atomicLoad(u32, &pos.ptr.clock.id, .monotonic);
    @atomicStore(u32, &act.ptr.active_driver_id, id, .release);
}

fn setArea(self: *Stream, comptime T: type, slot: *?Map(T), mem_id: u32, offset: u32, size: u32) void {
    var next: ?Map(T) = null;
    if (mem_id != spa.id_invalid) {
        next = self.mapArea(T, mem_id, offset, size) catch return self.fail(einval, "the io memory is not usable");
    }
    if (slot.*) |old| self.discard(old.mapping);
    slot.* = next;
    self.publish();
}

fn ownDirection(self: *const Stream) spa.Direction {
    return if (self.direction == .playback) .output else .input;
}

/// The index of a port of this stream, or null after an answer to the server.
fn findPort(self: *Stream, direction: spa.Direction, port_id: u32) ?usize {
    if (direction == self.ownDirection() and port_id < self.n_channels) return port_id;
    self.sendCoreError(einval, "no such port");
    return null;
}

fn findMix(port: *PortModel, id: u32) ?*MixModel {
    for (port.mixes.items) |*m| {
        if (m.id == id) return m;
    }
    return null;
}

fn ensureMix(self: *Stream, port: *PortModel, id: u32) error{OutOfMemory}!*MixModel {
    if (findMix(port, id)) |m| return m;
    const m = try port.mixes.addOne(self.gpa);
    m.* = .{ .id = id };
    return m;
}

fn removeMix(self: *Stream, port: *PortModel, id: u32) void {
    for (port.mixes.items, 0..) |*m, i| {
        if (m.id != id) continue;
        if (m.io_mapping) |map| self.discard(map);
        self.discardSet(&m.buffers);
        m.buffers.items.deinit(self.gpa);
        _ = port.mixes.swapRemove(i);
        return;
    }
}

fn onMixInfo(self: *Stream, direction: spa.Direction, port_id: u32, mix_id: u32, peer_id: u32) void {
    const index = self.findPort(direction, port_id) orelse return;
    const port = &self.ports[index];
    if (peer_id == spa.id_invalid) {
        self.removeMix(port, mix_id);
    } else {
        _ = self.ensureMix(port, mix_id) catch return self.failNoMemory();
    }
    self.publish();
}

/// True for `{audio, dsp, F32P}`. Choices count with their first value.
fn isDspFormat(param: pod.Pod) bool {
    const obj = param.object() catch return false;
    if (obj.object_type != @backingInt(spa.ObjectType.format)) return false;
    var media_type: ?u32 = null;
    var subtype: ?u32 = null;
    var format: ?u32 = null;
    var it = obj.props();
    while (it.next() catch return false) |prop| {
        if (prop.value.type == .choice) {
            const choice = prop.value.choice() catch return false;
            if (choice.kind != .none) return false;
        }
        const value = prop.value.unwrap() catch return false;
        const slot: *?u32 = switch (prop.key) {
            @backingInt(spa.FormatKey.media_type) => &media_type,
            @backingInt(spa.FormatKey.media_subtype) => &subtype,
            @backingInt(spa.FormatKey.audio_format) => &format,
            else => continue,
        };
        slot.* = value.id() catch return false;
    }
    return media_type == @backingInt(spa.MediaType.audio) and
        subtype == @backingInt(spa.MediaSubtype.dsp) and
        format == @backingInt(spa.AudioFormat.f32p);
}

/// Clamps a volume to 0 to 10. A NaN counts as 1.
fn cleanVolume(v: f32) f32 {
    if (std.math.isNan(v)) return 1;
    return std.math.clamp(v, 0, 10);
}

fn readVolumes(dst: []f32, value: pod.Pod) pod.Error!void {
    const array = try (try value.unwrap()).array();
    if (array.child_type != .float) return error.WrongType;
    var it = array.items();
    for (dst) |*d| {
        const item = it.next() orelse break;
        d.* = cleanVolume(try item.float());
    }
}

/// Reads the volume and mute values of a Props param into `c`. A value that is absent stays.
fn readProps(c: *Controls, n_channels: usize, param: pod.Pod) pod.Error!void {
    const obj = try param.object();
    if (obj.object_type != @backingInt(spa.ObjectType.props)) return error.WrongType;
    var saw_soft = false;
    var saw_channel = false;
    var it = obj.props();
    while (try it.next()) |prop| {
        switch (prop.key) {
            @backingInt(spa.PropKey.volume) => c.volume = cleanVolume(try (try prop.value.unwrap()).float()),
            @backingInt(spa.PropKey.mute) => c.mute = try (try prop.value.unwrap()).boolean(),
            @backingInt(spa.PropKey.soft_mute) => c.soft_mute = try (try prop.value.unwrap()).boolean(),
            @backingInt(spa.PropKey.channel_volumes) => {
                try readVolumes(c.channel_volumes[0..n_channels], prop.value);
                saw_channel = true;
            },
            @backingInt(spa.PropKey.soft_volumes) => {
                try readVolumes(c.soft_volumes[0..n_channels], prop.value);
                saw_soft = true;
            },
            else => {},
        }
    }
    // Soft volumes win until a message sets only the channel volumes, as audioconvert does.
    if (saw_soft) c.have_soft = true else if (saw_channel) c.have_soft = false;
}

/// The gain of each channel. Soft volumes replace the channel volumes when the server set them.
fn gainOf(c: *const Controls, n_channels: usize) [spa.max_channels]f32 {
    var gain: [spa.max_channels]f32 = @splat(1);
    const volumes = if (c.have_soft) &c.soft_volumes else &c.channel_volumes;
    for (gain[0..n_channels], volumes[0..n_channels]) |*g, v| {
        g.* = if (c.mute or c.soft_mute) 0 else c.volume * v;
    }
    return gain;
}

const SetGain = struct { stream: *Stream, gain: [spa.max_channels]f32 };

fn applySetGain(ctx: *anyopaque) void {
    const req: *SetGain = @ptrCast(@alignCast(ctx));
    req.stream.rt.gain = req.gain;
}

fn onProps(self: *Stream, param: pod.Pod) void {
    var next = self.controls;
    readProps(&next, self.n_channels, param) catch return self.sendCoreError(einval, "bad props");
    self.applyControls(next) catch self.fail(eio, "cannot send the props");
}

/// Keeps `next`, gives the new gain to the data loop, tells the server and the listener.
fn applyControls(self: *Stream, next: Controls) SendError!void {
    self.controls = next;
    var req: SetGain = .{ .stream = self, .gain = gainOf(&next, self.n_channels) };
    self.loop.invoke(&req, applySetGain);
    self.props_serial = !self.props_serial;
    try self.sendNodeUpdate(.{ .params = true }, &.{});
    self.emit(.{ .props = .{
        .volume = next.volume,
        .mute = next.mute,
        .channel_volumes = self.controls.channel_volumes[0..self.n_channels],
    } });
}

pub const ControlSet = struct {
    volume: ?f32 = null,
    mute: ?bool = null,
    channel_volumes: ?[]const f32 = null,
};

/// Sets the volume and mute of the stream the way a Props param from the server does: the
/// values are clamped, the data loop gets the gain, the server gets the new Props and the
/// listener gets `Event.props`. A server cannot set a Props param on the node of this stream
/// through the same `Remote`, see `Node.setParam`, so use this for the volume of own stream.
pub fn setControls(self: *Stream, set: ControlSet) SendError!void {
    if (self.torn_down) return;
    var next = self.controls;
    if (set.volume) |v| next.volume = cleanVolume(v);
    if (set.mute) |m| next.mute = m;
    if (set.channel_volumes) |vs| {
        for (next.channel_volumes[0..self.n_channels], 0..) |*d, i| {
            if (i < vs.len) d.* = cleanVolume(vs[i]);
        }
        next.have_soft = false;
    }
    try self.applyControls(next);
}

fn onNodeSetParam(self: *Stream, id: spa.ParamType, param: ?pod.Pod) void {
    switch (id) {
        .port_config => if (param) |p| {
            if (!self.isOwnPortConfig(p)) return self.sendCoreError(enotsup, "unsupported port config");
            self.reannouncePorts() catch self.fail(eio, "cannot announce the ports");
        },
        .format => if (param) |p| {
            if (rawChannels(p) != self.n_channels) self.sendCoreError(enotsup, "unsupported format");
        },
        .props => if (param) |p| self.onProps(p),
        .latency => _ = self.stats.latency_ignored.fetchAdd(1, .monotonic),
        else => self.sendCoreError(enotsup, "unsupported node param"),
    }
}

/// Drops the formats, buffers and mixes of the ports, then removes the ports and adds them
/// again. The server waits for the new ports after a PortConfig.
fn reannouncePorts(self: *Stream) SendError!void {
    for (self.ports) |*port| {
        port.format_ok = false;
        self.discardSet(&port.buffers);
        while (port.mixes.items.len > 0) self.removeMix(port, port.mixes.items[0].id);
    }
    self.publish();
    if (self.torn_down or self.state_ == .failed) return;
    for (0..self.n_channels) |i| try self.node.portUpdate(self.ownDirection(), @intCast(i), .{}, &.{}, null);
    for (0..self.n_channels) |i| try self.sendPortUpdate(i, false);
}

/// The channel count of a raw audio Format object, or 0.
fn rawChannels(param: pod.Pod) usize {
    const obj = param.object() catch return 0;
    if (obj.object_type != @backingInt(spa.ObjectType.format)) return 0;
    var subtype: ?u32 = null;
    var channels: ?i32 = null;
    var it = obj.props();
    while (it.next() catch return 0) |prop| {
        const value = prop.value.unwrap() catch return 0;
        switch (prop.key) {
            @backingInt(spa.FormatKey.media_subtype) => subtype = value.id() catch return 0,
            @backingInt(spa.FormatKey.audio_channels) => channels = value.int() catch return 0,
            else => {},
        }
    }
    if (subtype != @backingInt(spa.MediaSubtype.raw)) return 0;
    const n = channels orelse return 0;
    return if (n > 0) @intCast(n) else 0;
}

/// True for a dsp mode PortConfig in our direction, with no control port, whose
/// format has the channels of this stream. WirePlumber asks for monitor ports. The stream has none and the request is accepted.
fn isOwnPortConfig(self: *const Stream, param: pod.Pod) bool {
    const obj = param.object() catch return false;
    if (obj.object_type != @backingInt(spa.ObjectType.param_port_config)) return false;
    var mode: ?u32 = null;
    var direction: ?u32 = null;
    var channels: usize = 0;
    var it = obj.props();
    while (it.next() catch return false) |prop| {
        const value = prop.value.unwrap() catch return false;
        switch (prop.key) {
            @backingInt(spa.ParamPortConfigKey.direction) => direction = value.id() catch return false,
            @backingInt(spa.ParamPortConfigKey.mode) => mode = value.id() catch return false,
            @backingInt(spa.ParamPortConfigKey.control) => {
                if (value.boolean() catch return false) return false;
            },
            @backingInt(spa.ParamPortConfigKey.format) => channels = rawChannels(prop.value),
            else => {},
        }
    }
    return mode == @backingInt(spa.PortConfigMode.dsp) and
        direction == @backingInt(self.ownDirection()) and
        channels == self.n_channels;
}

fn onPortSetParam(self: *Stream, direction: spa.Direction, port_id: u32, id: spa.ParamType, param: ?pod.Pod) void {
    if (id != .format) return;
    const index = self.findPort(direction, port_id) orelse return;
    const port = &self.ports[index];
    if (param) |p| {
        if (!isDspFormat(p)) return self.fail(einval, "unsupported format");
    }
    port.format_ok = param != null;
    // A new format clears the buffers of the port.
    self.discardSet(&port.buffers);
    for (port.mixes.items) |*m| self.discardSet(&m.buffers);
    self.publish();
    if (self.torn_down or self.state_ == .failed or param == null) return;
    self.sendPortUpdate(index, true) catch self.fail(eio, "cannot answer the format");
}

const BufferError = error{ Invalid, Unsupported };

/// Maps one buffer of port_use_buffers. The chunk follows the metas at the start of the
/// range. The samples are at `data_id` inside the range, or in another block.
fn mapBuffer(self: *Stream, b: ClientNode.Buffer) BufferError!BufferModel {
    if (b.n_datas != 1) return error.Unsupported;
    const d = b.datas[0];
    const chunk_end = std.math.add(u32, b.metas_size, @sizeOf(shm.Chunk)) catch return error.Invalid;
    if (chunk_end > b.size) return error.Invalid;
    if ((@as(u64, b.offset) + b.metas_size) % @alignOf(shm.Chunk) != 0) return error.Invalid;

    const pool = &self.remote.mem;
    const m = pool.map(b.mem_id, b.offset, b.size, true) catch return error.Invalid;
    errdefer m.unmap();
    const chunk: *shm.Chunk = @ptrCast(@alignCast(m.ptr + b.metas_size));

    switch (d.type) {
        .mem_ptr => {
            if (d.data_id > b.size or d.max_size > b.size - d.data_id) return error.Invalid;
            if ((@as(u64, b.offset) + d.data_id) % @alignOf(f32) != 0) return error.Invalid;
            const data: [*]f32 = @ptrCast(@alignCast(m.ptr + d.data_id));
            return .{ .rt = .{ .chunk = chunk, .data = data, .maxsize = d.max_size }, .mapping = m };
        },
        .mem_id => {
            if (d.map_offset % @alignOf(f32) != 0) return error.Invalid;
            const dm = pool.map(d.data_id, d.map_offset, d.max_size, true) catch return error.Invalid;
            const data: [*]f32 = @ptrCast(@alignCast(dm.ptr));
            return .{ .rt = .{ .chunk = chunk, .data = data, .maxsize = d.max_size }, .mapping = m, .data_mapping = dm };
        },
        else => return error.Unsupported,
    }
}

fn onUseBuffers(self: *Stream, u: ClientNode.UseBuffers) void {
    const index = self.findPort(u.direction, u.port_id) orelse return;
    if (u.flags & spa.node_buffers_flag_alloc != 0) return self.fail(enotsup, "buffer allocation by the client is not supported");
    if (u.buffers.left > 0 and !self.ports[index].format_ok) return self.fail(einval, "buffers before the format");

    var built: std.ArrayList(BufferModel) = .empty;
    var it = u.buffers;
    while (it.next() catch null) |b| {
        if (built.items.len >= max_buffers) {
            unmapAll(&built, self.gpa);
            return self.fail(einval, "too many buffers");
        }
        const item = self.mapBuffer(b) catch |err| {
            unmapAll(&built, self.gpa);
            return switch (err) {
                error.Invalid => self.fail(einval, "the buffer memory is not usable"),
                error.Unsupported => self.fail(enotsup, "only one memory data plane is supported"),
            };
        };
        built.append(self.gpa, item) catch {
            unmapItem(item);
            unmapAll(&built, self.gpa);
            return self.failNoMemory();
        };
    }

    const port = &self.ports[index];
    const set: *BufferSet = if (self.direction == .playback)
        &port.buffers
    else
        &(self.ensureMix(port, u.mix_id) catch {
            unmapAll(&built, self.gpa);
            return self.failNoMemory();
        }).buffers;
    self.discardSet(set);
    set.items.deinit(self.gpa);
    set.items = built;
    self.publish();
}

fn unmapItem(item: BufferModel) void {
    item.mapping.unmap();
    if (item.data_mapping) |m| m.unmap();
}

fn unmapAll(list: *std.ArrayList(BufferModel), gpa: std.mem.Allocator) void {
    for (list.items) |item| unmapItem(item);
    list.deinit(gpa);
}

fn onPortSetIo(self: *Stream, direction: spa.Direction, port_id: u32, mix_id: u32, io: spa.IoType, mem_id: u32, offset: u32, size: u32) void {
    if (io != .buffers and io != .async_buffers) return;
    const index = self.findPort(direction, port_id) orelse return;
    const port = &self.ports[index];

    if (mem_id == spa.id_invalid) {
        const mix = findMix(port, mix_id) orelse return;
        if (mix.io_mapping) |m| self.discard(m);
        mix.io = .none;
        mix.io_mapping = null;
        return self.publish();
    }

    var next: Io = undefined;
    var mapping: MemPool.Mapping = undefined;
    if (io == .buffers) {
        const area = self.mapArea(shm.IoBuffers, mem_id, offset, size) catch return self.fail(einval, "the io memory is not usable");
        next = .{ .plain = area.ptr };
        mapping = area.mapping;
    } else {
        const area = self.mapArea(shm.IoAsyncBuffers, mem_id, offset, size) catch return self.fail(einval, "the io memory is not usable");
        next = .{ .async = area.ptr };
        mapping = area.mapping;
    }
    const mix = self.ensureMix(port, mix_id) catch {
        mapping.unmap();
        return self.failNoMemory();
    };
    if (mix.io_mapping) |m| self.discard(m);
    mix.io = next;
    mix.io_mapping = mapping;
    self.publish();
}

fn onCommand(self: *Stream, command: pod.Pod) void {
    const obj = command.object() catch return self.sendCoreError(einval, "bad command");
    if (obj.object_type != @backingInt(spa.ObjectType.command_node)) return self.sendCoreError(einval, "bad command");
    const id: spa.NodeCommand = @fromBackingInt(obj.object_id);
    switch (id) {
        .start => self.start(),
        .pause, .@"suspend" => self.pause(),
        else => {
            var buf: [48]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "unhandled command {d}", .{obj.object_id}) catch "unhandled command";
            self.sendCoreError(enotsup, text);
        },
    }
}

fn start(self: *Stream) void {
    if (self.activation == null or self.readfd < 0) return self.sendCoreError(eio, "no transport");
    var req: Start = .{ .stream = self };
    self.loop.invoke(&req, applyStart);
    if (req.err != null) return self.fail(eio, "cannot watch the node fd");
    self.setState(.streaming);
}

fn pause(self: *Stream) void {
    var req: Pause = .{ .stream = self };
    self.loop.invoke(&req, applyPause);
    if (self.state_ == .streaming) self.setState(.paused);
}

/// The server removed the node. The cycle stops and the stream fails.
fn onNodeRemoved(self: *Stream) void {
    var req: Pause = .{ .stream = self };
    self.loop.invoke(&req, applyPause);
    if (self.state_ == .closed) return;
    self.emit(.removed);
    if (self.torn_down) return;
    self.setState(.failed);
}

fn sendPortUpdate(self: *Stream, index: usize, with_format: bool) SendError!void {
    var params: param_set.Params = .{};
    const no_space = error.NoSpace;
    params.push(param_set.buildFormat(params.rest(), .enum_format) catch return no_space);
    if (with_format) params.push(param_set.buildFormat(params.rest(), .format) catch return no_space);
    params.push(param_set.buildBuffers(params.rest()) catch return no_space);
    params.push(param_set.buildIo(params.rest(), .buffers, @sizeOf(shm.IoBuffers)) catch return no_space);
    params.push(param_set.buildIo(params.rest(), .async_buffers, @sizeOf(shm.IoAsyncBuffers)) catch return no_space);
    params.push(param_set.buildLatency(params.rest(), .input) catch return no_space);
    params.push(param_set.buildLatency(params.rest(), .output) catch return no_space);

    const dir = self.ownDirection();
    const prefix = if (dir == .output) "output_" else "input_";
    var channel_buf: [16]u8 = undefined;
    const channel = param_set.channelName(&channel_buf, self.channels[index]);
    // A channel that an earlier port has too gets the port number in its name.
    var duplicate = false;
    for (self.channels[0..index]) |c| {
        if (c == self.channels[index]) duplicate = true;
    }
    var name_buf: [48]u8 = undefined;
    const name = (if (duplicate)
        std.fmt.bufPrint(&name_buf, "{s}{s}_{d}", .{ prefix, channel, index })
    else
        std.fmt.bufPrint(&name_buf, "{s}{s}", .{ prefix, channel })) catch return error.NoSpace;
    var id_buf: [12]u8 = undefined;
    const port_id = std.fmt.bufPrint(&id_buf, "{d}", .{index}) catch unreachable;

    const props = [_][2][]const u8{
        .{ "format.dsp", "32 bit float mono audio" },
        .{ "audio.channel", channel },
        .{ "port.name", name },
        .{ "port.id", port_id },
    };
    const info_params = [_]ClientNode.ParamInfo{
        .{ .id = .enum_format, .flags = .{ .read = true } },
        .{ .id = .buffers, .flags = .{ .read = true } },
        .{ .id = .io, .flags = .{ .read = true } },
        .{ .id = .format, .flags = if (with_format) .{ .read = true, .write = true } else .{ .write = true } },
        .{ .id = .latency, .flags = .{ .read = true, .write = true } },
    };
    try self.node.portUpdate(dir, @intCast(index), .{ .params = true, .info = true }, params.items[0..params.n], .{
        .change_mask = .{ .flags = true, .rate = true, .props = true, .params = true },
        .flags = .{ .no_ref = true },
        .rate = .{ .num = 0, .denom = 1 },
        .props = &props,
        .params = &info_params,
    });
}

const testing = std.testing;
const harness = @import("stream/harness.zig");
const Rig = @import("testing/Rig.zig");
const FakeServer = @import("testing/FakeServer.zig");
const tgpa = Rig.gpa;
const Harness = harness.Harness;
const act_size = harness.act_size;
const openFds = harness.openFds;
const fdClosed = harness.fdClosed;
const fieldsOf = harness.fieldsOf;
const nextInt = harness.nextInt;
const expectQuiet = harness.expectQuiet;
const expectCoreError = harness.expectCoreError;
const bump = @import("testing/util.zig").bump;
const hasCount = @import("testing/util.zig").hasCount;
const hasCountAndRestore = @import("testing/util.zig").hasCountAndRestore;
const Builder = pod.Builder;

test "create sends the node, its props and one port per channel" {
    var h: Harness = undefined;
    try h.setup(.{ .target = "alsa_output.test", .role = "Music" });
    defer h.deinit();
    try testing.expectEqual(State.connecting, h.stream.state());
    try testing.expectEqual(@as(?u32, null), h.stream.nodeId());

    var c = try h.rig.expectMessage(0, 6);
    defer c.deinit(tgpa);
    var cit = try fieldsOf(c.body);
    try testing.expectEqualStrings("client-node", (try (try cit.next()).?.string()).?);
    try testing.expectEqualStrings("PipeWire:Interface:ClientNode", (try (try cit.next()).?.string()).?);
    try testing.expectEqual(@as(i32, 6), try nextInt(&cit));
    const props = try pod.Dict.parse((try cit.next()).?);
    try testing.expectEqual(@as(i32, @bitCast(h.node_id)), try nextInt(&cit));
    try testing.expectEqualStrings("Stream/Output/Audio", props.get("media.class").?);
    try testing.expectEqualStrings("Audio", props.get("media.type").?);
    try testing.expectEqualStrings("Playback", props.get("media.category").?);
    try testing.expectEqualStrings("Music", props.get("media.role").?);
    try testing.expectEqualStrings("true", props.get("node.autoconnect").?);
    try testing.expectEqualStrings("true", props.get("node.async").?);
    try testing.expectEqualStrings("chorus-test", props.get("node.name").?);
    try testing.expectEqualStrings("alsa_output.test", props.get("target.object").?);
    try testing.expectEqualStrings("1/48000", props.get("node.rate").?);
    try testing.expectEqualStrings("1024/48000", props.get("node.latency").?);

    var u = try h.rig.server.expect(h.node_id, 2);
    defer u.deinit(tgpa);
    var uit = try fieldsOf(u.body);
    try testing.expectEqual(@as(i32, 3), try nextInt(&uit));
    try testing.expectEqual(@as(i32, 6), try nextInt(&uit));

    const node_format = (try uit.next()).?.object();
    try testing.expectEqual(@backingInt(spa.ParamType.enum_format), (try node_format).object_id);
    var ef = (try node_format).props();
    try testing.expectEqual(@as(u32, 1), try (try ef.next()).?.value.id());
    try testing.expectEqual(@as(u32, 1), try (try ef.next()).?.value.id());
    try testing.expectEqual(@as(u32, 518), try (try ef.next()).?.value.id());
    try testing.expectEqual(@as(i32, 48000), try (try ef.next()).?.value.int());
    try testing.expectEqual(@as(i32, 2), try (try ef.next()).?.value.int());
    const position = try (try ef.next()).?.value.array();
    try testing.expectEqual(@as(usize, 2), position.count());
    var pos_it = position.items();
    try testing.expectEqual(@as(u32, 3), try pos_it.next().?.id());
    try testing.expectEqual(@as(u32, 4), try pos_it.next().?.id());

    const enum_config = try (try uit.next()).?.object();
    try testing.expectEqual(@backingInt(spa.ParamType.enum_port_config), enum_config.object_id);
    var ec = enum_config.props();
    const ec_dir = try (try ec.next()).?.value.choice();
    try testing.expectEqual(spa.ChoiceType.none, ec_dir.kind);
    var ec_dir_values = ec_dir.values();
    try testing.expectEqual(@as(u32, 1), try ec_dir_values.next().?.id());
    const ec_mode = try (try ec.next()).?.value.choice();
    try testing.expectEqual(spa.ChoiceType.@"enum", ec_mode.kind);
    try testing.expectEqual(@as(usize, 2), ec_mode.count());
    var ec_mode_values = ec_mode.values();
    try testing.expectEqual(@as(u32, 3), try ec_mode_values.next().?.id());

    const config = try (try uit.next()).?.object();
    try testing.expectEqual(@backingInt(spa.ParamType.port_config), config.object_id);
    var pc = config.props();
    _ = try pc.next();
    try testing.expectEqual(@as(u32, 3), try (try pc.next()).?.value.id());
    try testing.expectEqual(false, try (try pc.next()).?.value.boolean());
    try testing.expectEqual(false, try (try pc.next()).?.value.boolean());
    try testing.expectEqual(@as(usize, 2), rawChannels((try pc.next()).?.value));
    _ = try uit.next();
    _ = try uit.next();
    try expectProps(try uit.next(), &.{ 1, 1 }, false, &.{ 1, 1 }, false, 1);

    var info = try (try uit.next()).?.structIter();
    try testing.expectEqual(@as(i32, -1), try nextInt(&info));
    try testing.expectEqual(@as(i32, -1), try nextInt(&info));
    try testing.expectEqual(@as(i64, 7), try (try info.next()).?.long());
    try testing.expectEqual(@as(i64, 17), try (try info.next()).?.long());
    try testing.expectEqual(@as(i32, @intCast(props.len())), try nextInt(&info));

    const names = [2][]const u8{ "FL", "FR" };
    for (names, 0..) |channel, port| {
        var p = try h.rig.server.expect(h.node_id, 3);
        defer p.deinit(tgpa);
        var pit = try fieldsOf(p.body);
        try testing.expectEqual(@as(i32, 1), try nextInt(&pit));
        try testing.expectEqual(@as(i32, @intCast(port)), try nextInt(&pit));
        try testing.expectEqual(@as(i32, 3), try nextInt(&pit));
        try testing.expectEqual(@as(i32, 6), try nextInt(&pit));

        const enum_format = (try pit.next()).?;
        const obj = try enum_format.object();
        try testing.expectEqual(@backingInt(spa.ObjectType.format), obj.object_type);
        try testing.expectEqual(@backingInt(spa.ParamType.enum_format), obj.object_id);
        var values: [3]u32 = undefined;
        var props_it = obj.props();
        for (&values) |*v| v.* = try (try props_it.next()).?.value.id();
        try testing.expectEqual([3]u32{ 1, 2, 518 }, values);
        for (0..5) |_| _ = try pit.next();

        var pinfo = try (try pit.next()).?.structIter();
        try testing.expectEqual(@as(i64, 15), try (try pinfo.next()).?.long());
        try testing.expectEqual(@as(i64, 16), try (try pinfo.next()).?.long());
        try testing.expectEqual(@as(i32, 0), try nextInt(&pinfo));
        try testing.expectEqual(@as(i32, 1), try nextInt(&pinfo));
        const n_items: usize = @intCast(try nextInt(&pinfo));
        var seen: u32 = 0;
        for (0..n_items) |_| {
            const key = (try (try pinfo.next()).?.string()).?;
            const value = (try (try pinfo.next()).?.string()).?;
            if (std.mem.eql(u8, key, "audio.channel")) {
                try testing.expectEqualStrings(channel, value);
                seen += 1;
            } else if (std.mem.eql(u8, key, "port.name")) {
                try testing.expect(std.mem.endsWith(u8, value, channel));
                try testing.expect(std.mem.startsWith(u8, value, "output_"));
                seen += 1;
            } else if (std.mem.eql(u8, key, "port.id")) {
                try testing.expectEqual(@as(u8, '0' + @as(u8, @intCast(port))), value[0]);
                seen += 1;
            } else if (std.mem.eql(u8, key, "format.dsp")) {
                try testing.expectEqualStrings("32 bit float mono audio", value);
                seen += 1;
            }
        }
        try testing.expectEqual(@as(u32, 4), seen);
    }
    try expectQuiet(&h.rig.server, 50);
}

test "a capture stream is an input stream with input ports" {
    var h: Harness = undefined;
    try h.setup(.{ .direction = .capture, .channels = &.{.mono} });
    defer h.deinit();

    var c = try h.rig.expectMessage(0, 6);
    defer c.deinit(tgpa);
    var cit = try fieldsOf(c.body);
    _ = try cit.next();
    _ = try cit.next();
    _ = try cit.next();
    const props = try pod.Dict.parse((try cit.next()).?);
    try testing.expectEqualStrings("Stream/Input/Audio", props.get("media.class").?);
    try testing.expectEqualStrings("Capture", props.get("media.category").?);
    try testing.expectEqual(@as(?[]const u8, null), props.get("target.object"));

    var u = try h.rig.server.expect(h.node_id, 2);
    u.deinit(tgpa);
    var p = try h.rig.server.expect(h.node_id, 3);
    defer p.deinit(tgpa);
    var pit = try fieldsOf(p.body);
    try testing.expectEqual(@as(i32, 0), try nextInt(&pit));
    try testing.expectEqual(@as(i32, 0), try nextInt(&pit));
}

test "the observed session leaves the stream streaming" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    const s = try h.runSession();

    try testing.expectEqual(State.streaming, h.stream.state());
    try testing.expectEqualSlices(State, &.{ .paused, .streaming }, h.rec.seen());
    try testing.expectEqual(@as(?u32, 50), h.stream.nodeId());
    try testing.expectEqualSlices(u32, &.{50}, h.rec.node_ids[0..h.rec.n_ids]);
    try testing.expectEqual(@as(u32, 1), s.mem0.at(shm.NodeActivation, 0).client_version);

    // The own activation entry is gone and the driver is the only target.
    try testing.expectEqual(@as(usize, 1), h.stream.rt.targets.len);
    try testing.expectEqual(@as(u32, 14), h.stream.rt.targets[0].id);

    // The buffers sit at the offsets of the message.
    const rt = h.stream.rt;
    try testing.expectEqual(@as(usize, 2), rt.ports.len);
    try testing.expectEqual(@as(usize, 2), rt.ports[0].buffers.len);
    s.mem2.at(f32, 48).* = 0.75;
    s.mem2.at(f32, 32864).* = -0.5;
    try testing.expectEqual(@as(f32, 0.75), rt.ports[0].buffers[0].data[0]);
    try testing.expectEqual(@as(f32, -0.5), rt.ports[0].buffers[1].data[0]);
    try testing.expectEqual(@as(u32, 32768), rt.ports[0].buffers[1].maxsize);
    s.mem2.at(shm.Chunk, 32816 + 32).size = 1024;
    try testing.expectEqual(@as(u32, 1024), rt.ports[0].buffers[1].chunk.size);
    s.mem4.at(f32, 48).* = 0.25;
    try testing.expectEqual(@as(f32, 0.25), rt.ports[1].buffers[0].data[0]);

    // The io areas and the position are the ones the server gave.
    s.mem3.at(shm.IoAsyncBuffers, 0).buffers[1] = .{ .status = 2, .buffer_id = 1 };
    try testing.expectEqual(@as(i32, 2), rt.ports[0].mixes[0].io.async.buffers[1].status);
    s.mem3.at(shm.IoAsyncBuffers, 16).buffers[0] = .{ .status = 1, .buffer_id = 0 };
    try testing.expectEqual(@as(i32, 1), rt.ports[1].mixes[0].io.async.buffers[0].status);
    s.mem1.at(shm.IoPosition, 560).clock.duration = 256;
    try testing.expectEqual(@as(u64, 256), rt.position.?.clock.duration);
    try testing.expectEqual(@intFromPtr(h.stream.activation.?.ptr), @intFromPtr(rt.activation.?));
    try testing.expectEqual(shm.ActivationStatus.finished, s.mem0.at(shm.NodeActivation, 0).status);

    // The client said set_active(true) after the transport and one port_update after the Format.
    try h.skipCreate();
    var active = try h.rig.server.expect(h.node_id, 4);
    defer active.deinit(tgpa);
    var ait = try fieldsOf(active.body);
    try testing.expectEqual(true, try (try ait.next()).?.boolean());
    for (0..2) |port| {
        var update = try h.rig.server.expect(h.node_id, 3);
        defer update.deinit(tgpa);
        var uit = try fieldsOf(update.body);
        try testing.expectEqual(@as(i32, 1), try nextInt(&uit));
        try testing.expectEqual(@as(i32, @intCast(port)), try nextInt(&uit));
        try testing.expectEqual(@as(i32, 3), try nextInt(&uit));
        const n_params: usize = @intCast(try nextInt(&uit));
        var have_format = false;
        var have_buffers = false;
        for (0..n_params) |_| {
            const o = try (try uit.next()).?.object();
            if (o.object_type == @backingInt(spa.ObjectType.format) and o.object_id == @backingInt(spa.ParamType.format)) {
                var pit = o.props();
                var values: [3]u32 = undefined;
                for (&values) |*v| v.* = try (try pit.next()).?.value.id();
                try testing.expectEqual([3]u32{ 1, 2, 518 }, values);
                have_format = true;
            }
            if (o.object_type == @backingInt(spa.ObjectType.param_buffers)) have_buffers = true;
        }
        try testing.expect(have_format and have_buffers);

        // The info lists Format as READ and WRITE.
        var info = try (try uit.next()).?.structIter();
        _ = try info.next();
        _ = try info.next();
        _ = try nextInt(&info);
        _ = try nextInt(&info);
        const n_items: usize = @intCast(try nextInt(&info));
        for (0..n_items * 2) |_| _ = try info.next();
        const n_info: usize = @intCast(try nextInt(&info));
        var format_flags: ?i32 = null;
        for (0..n_info) |_| {
            const pid = try (try info.next()).?.id();
            const flags = try nextInt(&info);
            if (pid == @backingInt(spa.ParamType.format)) format_flags = flags;
        }
        try testing.expectEqual(@as(?i32, 6), format_flags);
    }
    try expectQuiet(&h.rig.server, 50);
}

test "a Format with F32 interleaved fails the stream and tells the server" {
    const before = openFds();
    {
        var h: Harness = undefined;
        try h.setup(.{});
        defer h.deinit();
        try h.rig.remote.dispatch();
        try h.skipCreate();

        try h.format(1, 0, 1, 283, false);
        try h.rig.remote.dispatch();
        try testing.expectEqual(State.failed, h.stream.state());
        try testing.expectEqualSlices(State, &.{.failed}, h.rec.seen());
        var m = try h.rig.server.expect(0, 4);
        defer m.deinit(tgpa);
        try expectCoreError(m, h.node_id, einval);
        try expectQuiet(&h.rig.server, 50);
    }
    try testing.expectEqual(before, openFds());
}

test "a Format that is not audio gives a failed stream" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();

    try h.format(1, 1, 2, 258, false);
    try h.rig.remote.dispatch();
    try testing.expectEqual(State.failed, h.stream.state());
}

test "a transport with size 100 fails the stream and closes its fds" {
    const before = openFds();
    {
        var h: Harness = undefined;
        try h.setup(.{});
        defer h.deinit();
        try h.rig.remote.dispatch();
        try h.skipCreate();

        const mem0 = try h.memory(4096);
        try h.addMem(0, mem0.fd);
        try h.transport(try h.eventfd(), try h.eventfd(), 0, 0, 100);
        try h.rig.remote.dispatch();
        try testing.expectEqual(State.failed, h.stream.state());
        try testing.expectEqualSlices(State, &.{.failed}, h.rec.seen());
        var m = try h.rig.server.expect(0, 4);
        defer m.deinit(tgpa);
        try expectCoreError(m, h.node_id, einval);
        try expectQuiet(&h.rig.server, 50);
    }
    try testing.expectEqual(before, openFds());
}

test "a transport at a misaligned offset fails the stream" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();

    const mem0 = try h.memory(8192);
    try h.addMem(0, mem0.fd);
    try h.transport(try h.eventfd(), try h.eventfd(), 0, 4, act_size);
    try h.rig.remote.dispatch();
    try testing.expectEqual(State.failed, h.stream.state());
}

test "an unknown command gets Core.error with ENOTSUP" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();

    try h.command(99);
    try h.rig.remote.dispatch();
    var m = try h.rig.server.expect(0, 4);
    defer m.deinit(tgpa);
    try expectCoreError(m, h.node_id, enotsup);
    try testing.expectEqual(State.connecting, h.stream.state());
    try expectQuiet(&h.rig.server, 50);
}

fn sendNodeParam(h: *Harness, id: spa.ParamType, built: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.id(@backingInt(id));
    try b.int(0);
    try @import("info.zig").appendPod(&b, built);
    b.end(f);
    try h.send(1, b.bytesWritten(), &.{});
}

test "a node PortConfig in dsp mode with our channels is accepted" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();

    var buf: [512]u8 = undefined;
    const built = try param_set.buildPortConfig(&buf, .output, &.{ .fl, .fr });
    try sendNodeParam(&h, .port_config, built);
    try h.rig.remote.dispatch();
    // The ports are announced again, so that the server sees the new configuration.
    for (0..2) |port| {
        var p = try h.rig.server.expect(h.node_id, 3);
        defer p.deinit(tgpa);
        var it = try fieldsOf(p.body);
        try testing.expectEqual(@as(i32, 1), try nextInt(&it));
        try testing.expectEqual(@as(i32, @intCast(port)), try nextInt(&it));
        try testing.expectEqual(@as(i32, 0), try nextInt(&it));
    }
    for (0..2) |_| {
        var p = try h.rig.server.expect(h.node_id, 3);
        p.deinit(tgpa);
    }
    try expectQuiet(&h.rig.server, 50);
    try testing.expectEqual(State.connecting, h.stream.state());
}

test "a node PortConfig with other channels gets ENOTSUP" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();

    var buf: [512]u8 = undefined;
    const built = try param_set.buildPortConfig(&buf, .output, &.{ .fl, .fr, .fc });
    try sendNodeParam(&h, .port_config, built);
    try h.rig.remote.dispatch();
    var m = try h.rig.server.expect(0, 4);
    defer m.deinit(tgpa);
    try expectCoreError(m, h.node_id, enotsup);
    try testing.expectEqual(State.connecting, h.stream.state());
}

test "an empty node Props keeps the values and an unknown node param gets ENOTSUP" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();

    var buf: [128]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const o = try b.beginObject(@backingInt(spa.ObjectType.props), @backingInt(spa.ParamType.props));
    b.end(o);
    try sendNodeParam(&h, .props, b.bytesWritten());
    try h.rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 1), h.rec.props_seen);
    try testing.expectEqual(@as(f32, 1), h.rec.props_volume);
    var update = try h.rig.server.expect(h.node_id, 2);
    update.deinit(tgpa);
    try expectQuiet(&h.rig.server, 50);

    try sendNodeParam(&h, .buffers, b.bytesWritten());
    try h.rig.remote.dispatch();
    var m = try h.rig.server.expect(0, 4);
    defer m.deinit(tgpa);
    try expectCoreError(m, h.node_id, enotsup);
    try testing.expectEqual(State.connecting, h.stream.state());
}

test "a node PortConfig in the other direction gets ENOTSUP" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();

    var buf: [512]u8 = undefined;
    const built = try param_set.buildPortConfig(&buf, .input, &.{ .fl, .fr });
    try sendNodeParam(&h, .port_config, built);
    try h.rig.remote.dispatch();
    var m = try h.rig.server.expect(0, 4);
    defer m.deinit(tgpa);
    try expectCoreError(m, h.node_id, enotsup);
    try expectQuiet(&h.rig.server, 50);
}

test "a node Latency param is accepted and counted" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();

    var buf: [256]u8 = undefined;
    const built = try param_set.buildLatency(&buf, .input);
    try sendNodeParam(&h, .latency, built);
    try h.rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 1), h.stream.stats.latency_ignored.load(.monotonic));
    try expectQuiet(&h.rig.server, 50);
}

test "a node PortConfig drops the formats and buffers of the ports" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    const s = try h.runSession();
    _ = s;
    try testing.expect(h.stream.ports[0].format_ok);
    try testing.expectEqual(@as(usize, 2), h.stream.ports[0].buffers.items.items.len);
    try testing.expect(h.stream.ports[0].mixes.items.len > 0);

    var buf: [512]u8 = undefined;
    const built = try param_set.buildPortConfig(&buf, .output, &.{ .fl, .fr });
    try sendNodeParam(&h, .port_config, built);
    try h.rig.remote.dispatch();
    for (h.stream.ports) |port| {
        try testing.expect(!port.format_ok);
        try testing.expectEqual(@as(usize, 0), port.buffers.items.items.len);
        try testing.expectEqual(@as(usize, 0), port.mixes.items.len);
    }
    try testing.expectEqual(@as(?*shm.NodeActivation, h.stream.activation.?.ptr), h.stream.rt.activation);
    for (h.stream.rt.ports) |p| try testing.expectEqual(@as(usize, 0), p.buffers.len);

    try h.format(1, 0, 2, 518, true);
    try h.rig.remote.dispatch();
    try testing.expect(h.stream.ports[0].format_ok);
    try h.useBuffers(1, 0, -1, 2);
    try h.rig.remote.dispatch();
    try testing.expectEqual(@as(usize, 2), h.stream.ports[0].buffers.items.items.len);
    try testing.expectEqual(State.streaming, h.stream.state());
}

test "the activation holds the clock id of the position area" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();

    const mem0 = try h.memory(4096);
    try h.addMem(0, mem0.fd);
    const act = mem0.at(shm.NodeActivation, 0);
    const pos = mem0.at(shm.IoPosition, 560);
    pos.clock.id = 14;
    try h.transport(try h.eventfd(), try h.eventfd(), 0, 0, act_size);
    try h.setIo(7, 0, 560, 1688);
    try h.rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 14), act.active_driver_id);

    pos.clock.id = 21;
    try h.transport(try h.eventfd(), try h.eventfd(), 0, 0, act_size);
    try h.setIo(7, 0, 560, 1688);
    try h.rig.remote.dispatch();
    try testing.expectEqual(@as(u32, 21), act.active_driver_id);
}

test "Pause and Suspend stop the stream and Start runs it again" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    const s = try h.runSession();
    try testing.expectEqual(State.streaming, h.stream.state());

    try h.command(1);
    try h.rig.remote.dispatch();
    try testing.expectEqual(State.paused, h.stream.state());
    try testing.expectEqual(shm.ActivationStatus.inactive, s.mem0.at(shm.NodeActivation, 0).status);

    try h.command(2);
    try h.rig.remote.dispatch();
    try testing.expectEqual(State.streaming, h.stream.state());
    try testing.expectEqual(shm.ActivationStatus.finished, s.mem0.at(shm.NodeActivation, 0).status);

    try h.command(0);
    try h.rig.remote.dispatch();
    try testing.expectEqual(State.paused, h.stream.state());
    try testing.expectEqualSlices(State, &.{ .paused, .streaming, .paused, .streaming, .paused }, h.rec.seen());
}

test "a Core.error for the node is an event and the state stays" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();

    var buf: [128]u8 = undefined;
    var b = Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(h.node_id));
    try b.int(7);
    try b.int(-2);
    try b.string("no target node available");
    b.end(f);
    try h.rig.server.send(0, 3, b.bytesWritten(), &.{});
    try h.rig.remote.dispatch();

    try testing.expectEqual(@as(u32, 1), h.rec.errors);
    try testing.expectEqual(@as(i32, -2), h.rec.err_res);
    try testing.expectEqual(State.connecting, h.stream.state());
    try testing.expectEqual(@as(usize, 0), h.rec.n_states);
}

test "set_active is held back until the transport and then sent once" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.stream.setActive(false);
    try h.stream.setActive(true);
    try h.rig.remote.dispatch();
    try h.skipCreate();
    try expectQuiet(&h.rig.server, 50);

    const mem0 = try h.memory(4096);
    try h.addMem(0, mem0.fd);
    try h.transport(try h.eventfd(), try h.eventfd(), 0, 0, act_size);
    try h.rig.remote.dispatch();
    var on = try h.rig.server.expect(h.node_id, 4);
    on.deinit(tgpa);

    try h.stream.setActive(true);
    try h.stream.setActive(false);
    try h.rig.remote.dispatch();
    var off = try h.rig.server.expect(h.node_id, 4);
    defer off.deinit(tgpa);
    var it = try fieldsOf(off.body);
    try testing.expectEqual(false, try (try it.next()).?.boolean());
    try expectQuiet(&h.rig.server, 50);
}

test "destroy sends set_active(false) and Core.destroy and every fd is closed after remove_id" {
    const before = openFds();
    {
        var h: Harness = undefined;
        try h.setup(.{});
        defer h.deinit();
        try h.rig.remote.dispatch();
        const s = try h.runSession();
        _ = s;
        const readfd = h.stream.readfd;
        const signalfd = h.stream.targets.items[0].rt.fd;
        const mem_fd = h.rig.remote.mem.get(2).?.fd;
        try testing.expect(readfd >= 0 and signalfd >= 0);

        try h.skipCreate();
        var on = try h.rig.server.expect(h.node_id, 4);
        on.deinit(tgpa);
        for (0..2) |_| {
            var pu = try h.rig.server.expect(h.node_id, 3);
            pu.deinit(tgpa);
        }

        h.stream.destroy();
        h.destroyed = true;
        try testing.expectEqualSlices(State, &.{ .paused, .streaming, .closed }, h.rec.seen());
        try h.rig.remote.dispatch();
        var off = try h.rig.server.expect(h.node_id, 4);
        defer off.deinit(tgpa);
        var oit = try fieldsOf(off.body);
        try testing.expectEqual(false, try (try oit.next()).?.boolean());
        var destroy_msg = try h.rig.server.expect(0, 7);
        defer destroy_msg.deinit(tgpa);
        var dit = try fieldsOf(destroy_msg.body);
        try testing.expectEqual(@as(i32, @bitCast(h.node_id)), try nextInt(&dit));
        try expectQuiet(&h.rig.server, 50);

        try testing.expect(fdClosed(readfd));
        try testing.expect(fdClosed(signalfd));
        try testing.expect(!fdClosed(mem_fd));

        var buf: [32]u8 = undefined;
        var b = Builder.init(&buf);
        const f = try b.beginStruct();
        try b.int(@bitCast(h.node_id));
        b.end(f);
        try h.rig.server.send(0, 4, b.bytesWritten(), &.{});
        for (0..5) |i| {
            var rb = Builder.init(&buf);
            const rf = try rb.beginStruct();
            try rb.int(@intCast(i));
            rb.end(rf);
            try h.rig.server.send(0, 7, rb.bytesWritten(), &.{});
        }
        try h.rig.remote.dispatch();
        try testing.expect(fdClosed(mem_fd));
        try testing.expect(h.rig.remote.slots.items[h.node_id] == .free);
    }
    try testing.expectEqual(before, openFds());
}

test "a stream with no channels or too many is refused" {
    var rig = try Rig.init();
    defer rig.deinit();
    const loop = try DataLoop.init(tgpa, .{ .threaded = false });
    defer loop.deinit();
    const none: []const spa.AudioChannel = &.{};
    try testing.expectError(error.InvalidChannels, Stream.create(rig.remote, loop, .{
        .direction = .playback,
        .name = "x",
        .channels = none,
        .process = .{ .ctx = null, .func = harness.noProcess },
    }));
    const many: [spa.max_channels + 1]spa.AudioChannel = @splat(.mono);
    try testing.expectError(error.InvalidChannels, Stream.create(rig.remote, loop, .{
        .direction = .playback,
        .name = "x",
        .channels = &many,
        .process = .{ .ctx = null, .func = harness.noProcess },
    }));
}

test "a listener may destroy the stream from inside an event" {
    const before = openFds();
    {
        var h: Harness = undefined;
        try h.setup(.{});
        defer h.deinit();
        h.rec.destroy_on = .paused;
        try h.rig.remote.dispatch();

        const mem0 = try h.memory(4096);
        try h.addMem(0, mem0.fd);
        try h.transport(try h.eventfd(), try h.eventfd(), 0, 0, act_size);
        try h.setIo(7, 0, 560, 1688);
        try h.rig.remote.dispatch();
        h.destroyed = true;
        try testing.expectEqualSlices(State, &.{ .paused, .closed }, h.rec.seen());
        try testing.expectEqual(@as(u64, 1), h.rig.remote.stats.dropped);
    }
    try testing.expectEqual(before, openFds());
}

test "a listener may destroy the stream from the closed event" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    h.rec.destroy_on = .closed;
    h.stream.destroy();
    h.destroyed = true;
    try testing.expectEqualSlices(State, &.{.closed}, h.rec.seen());
}

test "Start watches the node fd and Pause stops watching it" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    _ = try h.runSession();

    try bump(h.stream.readfd);
    try h.loop.iterate(100);
    try testing.expect(!hasCount(h.stream.readfd));

    try h.command(1);
    try h.rig.remote.dispatch();
    try bump(h.stream.readfd);
    try h.loop.iterate(50);
    try testing.expect(hasCount(h.stream.readfd));
}

test "the observed session works with a loop thread" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.setup(.{ .threaded = true });
    defer h.deinit();
    try h.rig.remote.dispatch();
    const s = try h.runSession();
    try testing.expectEqual(State.streaming, h.stream.state());
    try testing.expectEqual(@as(usize, 2), h.stream.rt.ports.len);
    try testing.expectEqual(shm.ActivationStatus.finished, s.mem0.at(shm.NodeActivation, 0).status);

    try bump(h.stream.readfd);
    var tries: u32 = 0;
    while (hasCountAndRestore(h.stream.readfd) and tries < 200) : (tries += 1) {
        var ts: linux.timespec = .{ .sec = 0, .nsec = 5_000_000 };
        _ = linux.nanosleep(&ts, null);
    }
    try testing.expect(tries < 200);
}

test "a Format with a Choice Enum or Range is not fixed and fails the stream" {
    inline for (.{ spa.ChoiceType.@"enum", spa.ChoiceType.range }) |kind| {
        var h: Harness = undefined;
        try h.setup(.{});
        defer h.deinit();
        try h.rig.remote.dispatch();
        try h.skipCreate();

        try h.formatChoice(1, 0, kind);
        try h.rig.remote.dispatch();
        try testing.expectEqual(State.failed, h.stream.state());
        var m = try h.rig.server.expect(0, 4);
        defer m.deinit(tgpa);
        try expectCoreError(m, h.node_id, einval);
    }
}

test "a Choice None Format is accepted" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();

    try h.formatChoice(1, 0, .none);
    try h.rig.remote.dispatch();
    try testing.expect(h.stream.state() != .failed);
    try testing.expect(h.stream.ports[0].format_ok);
}

test "buffers before an accepted Format fail the stream" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();

    const mem = try h.memory(65632);
    try h.addMem(2, mem.fd);
    try h.useBuffers(1, 0, -1, 2);
    try h.rig.remote.dispatch();
    try testing.expectEqual(State.failed, h.stream.state());
    var m = try h.rig.server.expect(0, 4);
    defer m.deinit(tgpa);
    try expectCoreError(m, h.node_id, einval);
}

test "a new transport drops the old targets and io areas" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    _ = try h.runSession();
    try testing.expectEqual(@as(usize, 1), h.stream.targets.items.len);
    try testing.expect(h.stream.position != null and h.stream.clock != null);

    const mem = try h.memory(4096);
    try h.addMem(5, mem.fd);
    try h.transport(try h.eventfd(), try h.eventfd(), 5, 0, act_size);
    try h.rig.remote.dispatch();
    try testing.expectEqual(@as(usize, 0), h.stream.targets.items.len);
    try testing.expectEqual(@as(usize, 0), h.stream.rt.targets.len);
    try testing.expect(h.stream.position == null and h.stream.clock == null);
    try testing.expect(h.stream.rt.position == null);
    try testing.expectEqual(State.paused, h.stream.state());
}

const Driver = harness.Driver;
const have_data = shm.status_have_data;
const need_data = shm.status_need_data;

fn expectFilled(samples: []const f32, n: usize, value: f32) !void {
    for (samples[0..n]) |s| try testing.expectEqual(value, s);
}

test "a playback cycle fills the buffers and fills the io slots" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    h.probe.write = true;
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    d.activation.bits = shm.pending_sync_bit | shm.activation_version_bit;

    try d.cycle(&h, 4, 256, 48000);
    try testing.expectEqual(@as(u32, 1), h.probe.calls);
    try testing.expectEqual(@as(u32, 256), h.probe.frames);
    try testing.expectEqual(@as(u32, 48000), h.probe.rate);
    try testing.expectEqual(@as(usize, 2), h.probe.n_channels);
    try testing.expectEqual(@as(usize, 256), h.probe.lens[0]);
    try testing.expectEqual(@as(usize, 256), h.probe.lens[1]);
    try expectFilled(d.samples(0, 0), 256, 0.5);
    try expectFilled(d.samples(1, 0), 256, -0.5);
    for (0..2) |port| {
        const c = d.chunk(port, 0).*;
        try testing.expectEqual(shm.Chunk{ .offset = 0, .size = 1024, .stride = 4, .flags = 0 }, c);
        // Cycle 4 is even, so the producer writes the second slot.
        try testing.expectEqual(shm.IoBuffers{ .status = have_data, .buffer_id = 0 }, d.producerSlot(port, 4).*);
    }
    try testing.expectEqual(shm.ActivationStatus.finished, d.status());
    try testing.expectEqual(need_data | have_data, d.activation.state[0].status);
    try testing.expectEqual(@as(u32, shm.activation_version_bit), d.activation.bits);
    try testing.expect(d.activation.awake_time != 0);
    try testing.expect(d.activation.finish_time >= d.activation.awake_time);
    try testing.expectEqual(@as(u32, 1), h.stream.stats.cycles.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), h.stream.stats.skipped.load(.monotonic));

    // The next cycle takes the other buffer and the other slot.
    h.probe.fill = harness.Probe.pair(0.25, -0.25);
    try d.cycle(&h, 5, 128, 48000);
    try testing.expectEqual(@as(u32, 128), h.probe.frames);
    try expectFilled(d.samples(0, 1), 128, 0.25);
    try testing.expectEqual(@as(u32, 512), d.chunk(0, 1).size);
    try testing.expectEqual(shm.IoBuffers{ .status = have_data, .buffer_id = 1 }, d.producerSlot(0, 5).*);
    try testing.expectEqual(@as(u32, 1024), d.chunk(0, 0).size);
    try expectFilled(d.samples(0, 0), 256, 0.5);
}

test "a playback cycle is limited by the buffer size" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    try d.cycle(&h, 0, 100000, 44100);
    try testing.expectEqual(@as(u32, 8192), h.probe.frames);
    try testing.expectEqual(@as(u32, 44100), h.probe.rate);
    try testing.expectEqual(@as(u32, 32768), d.chunk(0, 0).size);
}

test "a capture cycle reads the buffer in the slot and sets NEED_DATA" {
    var h: Harness = undefined;
    try h.setup(.{ .direction = .capture });
    defer h.deinit();
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runCaptureSession());
    for (0..2) |port| {
        @memset(d.samples(port, 1), 0.25);
        d.chunk(port, 1).* = .{ .offset = 0, .size = 1024, .stride = 4, .flags = 0 };
        d.consumerSlot(port, 6).* = .{ .status = have_data, .buffer_id = 1 };
    }

    try d.cycle(&h, 6, 256, 48000);
    try testing.expectEqual(@as(u32, 1), h.probe.calls);
    try testing.expectEqual(@as(u32, 256), h.probe.frames);
    try testing.expectEqual(@as(u32, 48000), h.probe.rate);
    try testing.expectEqual(@as(usize, 2), h.probe.n_channels);
    try testing.expectEqual(@as(f32, 0.25), h.probe.first[0]);
    try testing.expectEqual(@as(f32, 0.25), h.probe.first[1]);
    for (0..2) |port| {
        try testing.expectEqual(need_data, d.consumerSlot(port, 6).status);
    }
    try testing.expectEqual(shm.ActivationStatus.finished, d.status());

    // Without new data the callback gets zeros and the slots end with NEED_DATA.
    try d.cycle(&h, 8, 256, 48000);
    try testing.expectEqual(@as(u32, 2), h.probe.calls);
    try testing.expect(h.probe.silent[0] and h.probe.silent[1]);
    try testing.expectEqual(@as(u32, 2), h.stream.stats.port_gaps.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), h.stream.stats.skipped.load(.monotonic));
    try testing.expectEqual(shm.ActivationStatus.finished, d.status());
}

test "a capture cycle with data on one port gives zeros to the other" {
    var h: Harness = undefined;
    try h.setup(.{ .direction = .capture });
    defer h.deinit();
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runCaptureSession());
    @memset(d.samples(0, 1), 0.25);
    d.chunk(0, 1).* = .{ .offset = 0, .size = 1024, .stride = 4, .flags = 0 };
    d.consumerSlot(0, 2).* = .{ .status = have_data, .buffer_id = 1 };
    d.consumerSlot(1, 2).* = .{ .status = need_data, .buffer_id = 0 };
    try d.cycle(&h, 2, 256, 48000);
    try testing.expectEqual(@as(u32, 1), h.probe.calls);
    try testing.expectEqual(@as(u32, 256), h.probe.frames);
    try testing.expectEqual(@as(usize, 256), h.probe.lens[1]);
    try testing.expectEqual(@as(f32, 0.25), h.probe.first[0]);
    try testing.expect(h.probe.silent[1]);
    try testing.expectEqual(need_data, d.consumerSlot(0, 2).status);
    try testing.expectEqual(need_data, d.consumerSlot(1, 2).status);
    try testing.expectEqual(@as(u32, 1), h.stream.stats.port_gaps.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), h.stream.stats.skipped.load(.monotonic));
}

test "a capture cycle follows the offset and size of the chunk" {
    var h: Harness = undefined;
    try h.setup(.{ .direction = .capture });
    defer h.deinit();
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runCaptureSession());
    for (0..2) |port| {
        @memset(d.samples(port, 0), 0.5);
        d.samples(port, 0)[10] = 0.75;
        d.chunk(port, 0).* = .{ .offset = 40, .size = 400, .stride = 4, .flags = 0 };
        d.consumerSlot(port, 1).* = .{ .status = have_data, .buffer_id = 0 };
    }
    try d.cycle(&h, 1, 256, 48000);
    try testing.expectEqual(@as(u32, 100), h.probe.frames);
    try testing.expectEqual(@as(usize, 100), h.probe.lens[0]);
    try testing.expectEqual(@as(f32, 0.75), h.probe.first[0]);

    // A buffer id that does not exist gives zeros, and both slots end with NEED_DATA.
    d.consumerSlot(0, 3).* = .{ .status = have_data, .buffer_id = 9 };
    d.consumerSlot(1, 3).* = .{ .status = have_data, .buffer_id = 0 };
    try d.cycle(&h, 3, 256, 48000);
    try testing.expectEqual(@as(u32, 2), h.probe.calls);
    try testing.expect(h.probe.silent[0]);
    try testing.expectEqual(@as(f32, 0.75), h.probe.first[1]);
    try testing.expectEqual(@as(u32, 1), h.stream.stats.port_gaps.load(.monotonic));
    try testing.expectEqual(need_data, d.consumerSlot(0, 3).status);
    try testing.expectEqual(need_data, d.consumerSlot(1, 3).status);
    try testing.expectEqual(@as(u32, 0), h.stream.stats.skipped.load(.monotonic));
}

test "a wakeup with status NOT_TRIGGERED calls nothing" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    try d.wake(.not_triggered, 2, 256, 48000);
    try d.settle(&h);
    try testing.expectEqual(@as(u32, 0), h.probe.calls);
    try testing.expectEqual(shm.ActivationStatus.not_triggered, d.status());
    try testing.expect(!hasCount(h.stream.readfd));
    try testing.expectEqual(@as(u32, 0), h.stream.stats.skipped.load(.monotonic));
}

test "a stale readable event with an empty eventfd does nothing" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    @atomicStore(shm.ActivationStatus, &d.activation.status, .triggered, .release);
    onReadable(h.stream);
    try testing.expectEqual(shm.ActivationStatus.triggered, d.status());
    try testing.expectEqual(@as(u32, 0), h.probe.calls);
}

test "missed wakeups are counted" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    const three = std.mem.toBytes(@as(u64, 3));
    try testing.expectEqual(@as(usize, 8), linux.write(h.stream.readfd, &three, three.len));
    @atomicStore(shm.ActivationStatus, &d.activation.status, .triggered, .release);
    onReadable(h.stream);
    try testing.expectEqual(@as(u32, 2), h.stream.stats.missed.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), @atomicLoad(u32, &d.activation.xrun_count, .monotonic));
    try testing.expectEqual(@as(u32, 1), h.probe.calls);
}

test "after Pause the status is INACTIVE and a wakeup calls nothing" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    try d.cycle(&h, 0, 256, 48000);
    try testing.expectEqual(@as(u32, 1), h.probe.calls);

    try h.command(1);
    try h.rig.remote.dispatch();
    try testing.expectEqual(shm.ActivationStatus.inactive, d.status());
    try d.wake(.triggered, 1, 256, 48000);
    try h.loop.iterate(50);
    try testing.expectEqual(@as(u32, 1), h.probe.calls);
    try testing.expectEqual(shm.ActivationStatus.triggered, d.status());
    try testing.expect(hasCount(h.stream.readfd));
}

test "a playback cycle without an io area on one port writes the other port" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    h.probe.write = true;
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    try h.portSetIo(1, 1, 0, 10, -1, 0, 0);
    try h.rig.remote.dispatch();
    d.producerSlot(1, 4).* = .{ .status = 0, .buffer_id = 7 };
    try d.cycle(&h, 4, 256, 48000);
    try testing.expectEqual(@as(u32, 1), h.probe.calls);
    try testing.expectEqual(@as(usize, 256), h.probe.lens[1]);
    try expectFilled(d.samples(0, 0), 256, 0.5);
    try testing.expectEqual(shm.IoBuffers{ .status = have_data, .buffer_id = 0 }, d.producerSlot(0, 4).*);
    try testing.expectEqual(shm.IoBuffers{ .status = 0, .buffer_id = 7 }, d.producerSlot(1, 4).*);
    try testing.expectEqual(@as(u32, 0), d.chunk(1, 0).size);
    try testing.expectEqual(@as(u32, 1), h.stream.stats.port_gaps.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), h.stream.stats.skipped.load(.monotonic));
    try testing.expectEqual(shm.ActivationStatus.finished, d.status());
}

test "a playback cycle on a port with no buffers uses scratch for that port" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    h.probe.write = true;
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    try h.clearBuffers(1, 1, -1);
    try h.rig.remote.dispatch();
    try d.cycle(&h, 0, 256, 48000);
    try testing.expectEqual(@as(u32, 1), h.probe.calls);
    try expectFilled(d.samples(0, 0), 256, 0.5);
    try testing.expectEqual(@as(u32, 1), h.stream.stats.port_gaps.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), h.stream.stats.skipped.load(.monotonic));
    try testing.expectEqual(shm.ActivationStatus.finished, d.status());
}

test "a cycle without a position finishes and counts as skipped" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    try h.setIo(7, -1, 0, 0);
    try h.rig.remote.dispatch();
    try d.cycle(&h, 0, 256, 48000);
    try testing.expectEqual(@as(u32, 0), h.probe.calls);
    try testing.expectEqual(@as(u32, 1), h.stream.stats.skipped.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), h.stream.stats.port_gaps.load(.monotonic));
    try testing.expectEqual(shm.ActivationStatus.finished, d.status());
}

test "the cycle runs on a loop thread" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.setup(.{ .threaded = true });
    defer h.deinit();
    h.probe.write = true;
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    for (0..20) |i| {
        try d.cycle(&h, @intCast(i), 256, 48000);
        try testing.expectEqual(shm.ActivationStatus.finished, d.status());
    }
    try testing.expectEqual(@as(u32, 20), h.probe.calls);
    try testing.expectEqual(@as(f32, 0.5), d.samples(0, 1)[255]);
    try testing.expectEqual(shm.IoBuffers{ .status = have_data, .buffer_id = 1 }, d.producerSlot(0, 19).*);
}

const Peer = struct { fd: linux.fd_t, act: *shm.NodeActivation };

/// Adds a node that the stream wakes after a cycle.
fn addPeer(h: *Harness, id: i32, mem_id: i32, pending: i32) !Peer {
    const mem = try h.memory(4096);
    try h.addMem(mem_id, mem.fd);
    const fd = try h.eventfd();
    try h.setActivation(id, fd, mem_id, 0, act_size);
    try h.rig.remote.dispatch();
    const act = mem.at(shm.NodeActivation, 0);
    act.state[0].pending = pending;
    return .{ .fd = fd, .act = act };
}

test "a sync node wakes the peers whose pending count reaches zero" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    d.activation.server_version = 1;
    const a = try addPeer(&h, 20, 10, 1);
    const b = try addPeer(&h, 21, 11, 2);

    try d.cycle(&h, 0, 256, 48000);
    try testing.expectEqual(shm.ActivationStatus.triggered, a.act.status);
    try testing.expectEqual(@as(i32, 0), a.act.state[0].pending);
    try testing.expect(a.act.signal_time != 0);
    try testing.expect(hasCount(a.fd));
    try testing.expectEqual(shm.ActivationStatus.not_triggered, b.act.status);
    try testing.expectEqual(@as(i32, 1), b.act.state[0].pending);
    try testing.expectEqual(@as(u64, 0), b.act.signal_time);
    try testing.expect(!hasCount(b.fd));
    try testing.expectEqual(@as(u32, 0), h.stream.stats.trigger_failures.load(.monotonic));
}

test "an async node wakes nobody on a v1 server" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    d.activation.server_version = 1;
    d.activation.flags = shm.activation_flag_async;
    const a = try addPeer(&h, 20, 10, 1);

    try d.cycle(&h, 0, 256, 48000);
    try testing.expectEqual(@as(u32, 1), h.probe.calls);
    try testing.expectEqual(@as(i32, 1), a.act.state[0].pending);
    try testing.expectEqual(shm.ActivationStatus.not_triggered, a.act.status);
    try testing.expect(!hasCount(a.fd));
}

test "a v1 server leaves a peer that is not idle alone" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    d.activation.server_version = 1;
    const a = try addPeer(&h, 20, 10, 1);
    a.act.status = .awake;

    try d.cycle(&h, 0, 256, 48000);
    try testing.expectEqual(@as(i32, 0), a.act.state[0].pending);
    try testing.expectEqual(shm.ActivationStatus.awake, a.act.status);
    try testing.expect(!hasCount(a.fd));
}

test "a v0 server gets TRIGGERED stored without a check" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    d.activation.flags = shm.activation_flag_async;
    const a = try addPeer(&h, 20, 10, 1);
    a.act.status = .awake;

    try d.cycle(&h, 0, 256, 48000);
    try testing.expectEqual(shm.ActivationStatus.triggered, a.act.status);
    try testing.expect(a.act.signal_time != 0);
    try testing.expect(hasCount(a.fd));
}

test "a failed eventfd write is counted" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    d.activation.server_version = 1;
    const a = try addPeer(&h, 20, 10, 1);
    const full = std.mem.toBytes(@as(u64, std.math.maxInt(u64) - 1));
    try testing.expectEqual(@as(usize, 8), linux.write(a.fd, &full, full.len));

    try d.cycle(&h, 0, 256, 48000);
    try testing.expectEqual(@as(u32, 1), h.stream.stats.trigger_failures.load(.monotonic));
}

test "a removed node fails the stream and the listener sees both events in order" {
    const before = openFds();
    {
        var h: Harness = undefined;
        try h.setup(.{});
        defer h.deinit();
        try h.rig.remote.dispatch();
        _ = try h.runSession();
        try h.skipCreate();

        var buf: [32]u8 = undefined;
        var b = Builder.init(&buf);
        const f = try b.beginStruct();
        try b.int(@bitCast(h.node_id));
        b.end(f);
        try h.rig.server.send(0, 4, b.bytesWritten(), &.{});
        try h.rig.remote.dispatch();

        try testing.expectEqual(State.failed, h.stream.state());
        try testing.expectEqualSlices(State, &.{ .paused, .streaming, .failed }, h.rec.seen());
        const tags = h.rec.events();
        try testing.expectEqual(std.meta.Tag(Event).removed, tags[tags.len - 2]);
        try testing.expectEqual(std.meta.Tag(Event).state, tags[tags.len - 1]);
        try testing.expectEqual(@as(u32, 1), h.rec.removed);
        try testing.expectEqual(shm.ActivationStatus.inactive, h.stream.activation.?.ptr.status);
        try testing.expect(!h.stream.source_on);
        try testing.expect(h.stream.node.proxy.removed);
    }
    try testing.expectEqual(before, openFds());
}

fn expectProps(param: ?pod.Pod, cv: []const f32, mute: bool, sv: []const f32, soft_mute: bool, volume: f32) !void {
    const obj = try param.?.object();
    try testing.expectEqual(@backingInt(spa.ObjectType.props), obj.object_type);
    try testing.expectEqual(@backingInt(spa.ParamType.props), obj.object_id);
    var it = obj.props();
    const keys = [_]spa.PropKey{ .channel_volumes, .mute, .soft_volumes, .soft_mute, .volume };
    for (keys) |key| {
        const prop = (try it.next()).?;
        try testing.expectEqual(@backingInt(key), prop.key);
        switch (key) {
            .channel_volumes, .soft_volumes => {
                const want = if (key == .channel_volumes) cv else sv;
                const array = try prop.value.array();
                try testing.expectEqual(spa.Type.float, array.child_type);
                try testing.expectEqual(want.len, array.count());
                var items = array.items();
                for (want) |w| try testing.expectEqual(w, try items.next().?.float());
            },
            .mute => try testing.expectEqual(mute, try prop.value.boolean()),
            .soft_mute => try testing.expectEqual(soft_mute, try prop.value.boolean()),
            else => try testing.expectEqual(volume, try prop.value.float()),
        }
    }
    try testing.expect((try it.next()) == null);
}

const PropsSet = struct {
    volume: ?f32 = null,
    mute: ?bool = null,
    soft_mute: ?bool = null,
    channel_volumes: ?[]const f32 = null,
    soft_volumes: ?[]const f32 = null,
};

fn sendProps(h: *Harness, set: PropsSet) !void {
    var buf: [1024]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const o = try b.beginObject(@backingInt(spa.ObjectType.props), @backingInt(spa.ParamType.props));
    if (set.volume) |v| {
        try b.prop(@backingInt(spa.PropKey.volume), .{});
        try b.float(v);
    }
    if (set.mute) |v| {
        try b.prop(@backingInt(spa.PropKey.mute), .{});
        try b.boolean(v);
    }
    if (set.soft_mute) |v| {
        try b.prop(@backingInt(spa.PropKey.soft_mute), .{});
        try b.boolean(v);
    }
    if (set.channel_volumes) |vs| {
        try b.prop(@backingInt(spa.PropKey.channel_volumes), .{});
        const a = try b.beginArray();
        for (vs) |v| try b.float(v);
        b.end(a);
    }
    if (set.soft_volumes) |vs| {
        try b.prop(@backingInt(spa.PropKey.soft_volumes), .{});
        const a = try b.beginArray();
        for (vs) |v| try b.float(v);
        b.end(a);
    }
    b.end(o);
    try sendNodeParam(h, .props, b.bytesWritten());
    try h.rig.remote.dispatch();
}

test "node Props change the gain of the next cycle with a ramp" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    h.probe.write = true;
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    try h.skipCreate();

    try sendProps(&h, .{ .channel_volumes = &.{ 0.5, 0.25 } });
    try testing.expectEqual(@as(f32, 0.5), h.stream.rt.gain[0]);
    try testing.expectEqual(@as(f32, 0.25), h.stream.rt.gain[1]);

    try d.cycle(&h, 0, 256, 48000);
    const first = d.samples(0, 0);
    try testing.expectEqual(@as(f32, 0.25), first[255]);
    try testing.expect(first[0] > 0.25 and first[0] < 0.5);
    try testing.expect(first[100] > first[200]);
    try testing.expectEqual(@as(f32, -0.125), d.samples(1, 0)[255]);

    try d.cycle(&h, 1, 256, 48000);
    try expectFilled(d.samples(0, 1), 256, 0.25);
    try expectFilled(d.samples(1, 1), 256, -0.125);
}

test "node Props mute gives zeros and unmute brings the samples back" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    h.probe.write = true;
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());

    try sendProps(&h, .{ .mute = true });
    try d.cycle(&h, 0, 256, 48000);
    try testing.expectEqual(@as(f32, 0), d.samples(0, 0)[255]);
    try testing.expect(d.samples(0, 0)[0] > 0.4);
    try d.cycle(&h, 1, 256, 48000);
    try expectFilled(d.samples(0, 1), 256, 0);
    try expectFilled(d.samples(1, 1), 256, 0);

    try sendProps(&h, .{ .mute = false });
    try d.cycle(&h, 2, 256, 48000);
    try d.cycle(&h, 3, 256, 48000);
    try expectFilled(d.samples(0, 1), 256, 0.5);

    try sendProps(&h, .{ .soft_mute = true });
    try d.cycle(&h, 4, 256, 48000);
    try d.cycle(&h, 5, 256, 48000);
    try expectFilled(d.samples(0, 1), 256, 0);
}

test "node Props gains: soft volumes replace channel volumes, volume multiplies, values are clamped" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();

    try sendProps(&h, .{ .volume = 0.5, .channel_volumes = &.{ 1, 0.5 } });
    try testing.expectEqual(@as(f32, 0.5), h.stream.rt.gain[0]);
    try testing.expectEqual(@as(f32, 0.25), h.stream.rt.gain[1]);

    try sendProps(&h, .{ .soft_volumes = &.{ 0.5, 0.5 } });
    try testing.expectEqual(@as(f32, 0.25), h.stream.rt.gain[0]);
    try testing.expectEqual(@as(f32, 0.25), h.stream.rt.gain[1]);

    try sendProps(&h, .{ .volume = 1, .soft_volumes = &.{ 40, std.math.nan(f32) } });
    try testing.expectEqual(@as(f32, 10), h.stream.rt.gain[0]);
    try testing.expectEqual(@as(f32, 1), h.stream.rt.gain[1]);

    try sendProps(&h, .{ .volume = -3 });
    try testing.expectEqual(@as(f32, 0), h.stream.rt.gain[0]);
    try testing.expectEqual(@as(u32, 4), h.rec.props_seen);
    try testing.expectEqual(@as(f32, 0), h.rec.props_volume);
}

test "node Props are sent back to the server and reach the listener" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();

    try sendProps(&h, .{ .volume = 0.75, .mute = true, .channel_volumes = &.{ 0.5, 0.25 } });
    try testing.expectEqual(@as(u32, 1), h.rec.props_seen);
    try testing.expectEqual(@as(f32, 0.75), h.rec.props_volume);
    try testing.expectEqual(true, h.rec.props_mute);
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.25 }, h.rec.props_cv[0..h.rec.props_n]);

    var u = try h.rig.server.expect(h.node_id, 2);
    defer u.deinit(tgpa);
    var uit = try fieldsOf(u.body);
    try testing.expectEqual(@as(i32, 3), try nextInt(&uit));
    try testing.expectEqual(@as(i32, 6), try nextInt(&uit));
    for (0..5) |_| _ = try uit.next();
    try expectProps(try uit.next(), &.{ 0.5, 0.25 }, true, &.{ 1, 1 }, false, 0.75);

    var info = try (try uit.next()).?.structIter();
    _ = try nextInt(&info);
    _ = try nextInt(&info);
    try testing.expectEqual(@as(i64, 4), try (try info.next()).?.long());
    _ = try info.next();
    try testing.expectEqual(@as(i32, 0), try nextInt(&info));
    try testing.expectEqual(@as(i32, 6), try nextInt(&info));
    var props_flags: ?i32 = null;
    for (0..6) |_| {
        const pid = try (try info.next()).?.id();
        const flags = try nextInt(&info);
        if (pid == @backingInt(spa.ParamType.props)) props_flags = flags;
    }
    try testing.expectEqual(@as(?i32, 7), props_flags);

    // The next change flips the serial bit.
    try sendProps(&h, .{ .mute = false });
    var second = try h.rig.server.expect(h.node_id, 2);
    defer second.deinit(tgpa);
    var uit2 = try fieldsOf(second.body);
    _ = try nextInt(&uit2);
    _ = try nextInt(&uit2);
    for (0..5) |_| _ = try uit2.next();
    try expectProps(try uit2.next(), &.{ 0.5, 0.25 }, false, &.{ 1, 1 }, false, 0.75);
    var info2 = try (try uit2.next()).?.structIter();
    for (0..4) |_| _ = try info2.next();
    _ = try nextInt(&info2);
    _ = try nextInt(&info2);
    var flags2: ?i32 = null;
    for (0..6) |_| {
        const pid = try (try info2.next()).?.id();
        const flags = try nextInt(&info2);
        if (pid == @backingInt(spa.ParamType.props)) flags2 = flags;
    }
    try testing.expectEqual(@as(?i32, 6), flags2);
}

test "node Props with a bad value get EINVAL and keep the old values" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();

    var buf: [128]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const o = try b.beginObject(@backingInt(spa.ObjectType.props), @backingInt(spa.ParamType.props));
    try b.prop(@backingInt(spa.PropKey.volume), .{});
    try b.int(3);
    b.end(o);
    try sendNodeParam(&h, .props, b.bytesWritten());
    try h.rig.remote.dispatch();
    var m = try h.rig.server.expect(0, 4);
    defer m.deinit(tgpa);
    try expectCoreError(m, h.node_id, einval);
    try testing.expectEqual(@as(f32, 1), h.stream.controls.volume);
    try testing.expectEqual(@as(u32, 0), h.rec.props_seen);
    try expectQuiet(&h.rig.server, 50);
}

test "node Props scale a capture copy and leave the shared buffer alone" {
    var h: Harness = undefined;
    try h.setup(.{ .direction = .capture });
    defer h.deinit();
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runCaptureSession());
    try sendProps(&h, .{ .channel_volumes = &.{ 0.5, 0.5 } });

    for (0..2) |cycle| {
        const number: u32 = @intCast(cycle * 2);
        for (0..2) |port| {
            @memset(d.samples(port, 1), 0.25);
            d.chunk(port, 1).* = .{ .offset = 0, .size = 1024, .stride = 4, .flags = 0 };
            d.consumerSlot(port, number).* = .{ .status = have_data, .buffer_id = 1 };
        }
        try d.cycle(&h, number, 256, 48000);
    }
    try testing.expectEqual(@as(f32, 0.125), h.probe.first[0]);
    try testing.expectEqual(@as(f32, 0.125), h.probe.first[1]);
    try expectFilled(d.samples(0, 1), 256, 0.25);
    try testing.expectEqual(@as(u32, 0), h.stream.stats.port_gaps.load(.monotonic));
}

test "a stream with the most channels still fits its node update" {
    var h: Harness = undefined;
    const channels: [spa.max_channels]spa.AudioChannel = @splat(.mono);
    try h.setup(.{ .channels = &channels });
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();
    try testing.expectEqual(@as(usize, spa.max_channels), h.stream.n_channels);
}

test "a failed garbage reservation fails the stream before the model changes" {
    var failing = std.testing.FailingAllocator.init(tgpa, .{});
    var h: Harness = undefined;
    try h.setup(.{ .allocator = failing.allocator() });
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();

    failing.fail_index = failing.alloc_index;
    try h.setIo(7, -1, 0, 0);
    try h.rig.remote.dispatch();
    try testing.expectEqual(State.failed, h.stream.state());
    try testing.expectEqual(@as(i32, enomem), h.rec.err_res);
    try testing.expectEqual(@as(usize, 0), h.stream.garbage.capacity);
    var m = try h.rig.server.expect(0, 4);
    defer m.deinit(tgpa);
    try expectCoreError(m, h.node_id, enomem);
    try testing.expectEqual(@as(u32, 0), h.stream.stats.send_failures.load(.monotonic));
}

test "a failed core error send is counted" {
    var failing = std.testing.FailingAllocator.init(tgpa, .{});
    var h: Harness = undefined;
    try h.setup(.{ .allocator = failing.allocator() });
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();

    try h.command(99);
    try h.rig.remote.dispatch();
    var first = try h.rig.server.expect(0, 4);
    first.deinit(tgpa);
    try testing.expectEqual(@as(u32, 0), h.stream.stats.send_failures.load(.monotonic));

    // Nothing flushes the queue, so it grows until an allocation fails.
    const text: [200]u8 = @splat('x');
    var sent: usize = 0;
    while (h.stream.stats.send_failures.load(.monotonic) == 0 and sent < 1000) : (sent += 1) {
        failing.fail_index = failing.alloc_index;
        h.stream.sendCoreError(einval, &text);
    }
    try testing.expectEqual(@as(u32, 1), h.stream.stats.send_failures.load(.monotonic));
    try testing.expect(sent < 1000);
}

test "the fallback id is for nodeId only and node_id is emitted once, from bound_props" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();

    const mem0 = try h.memory(4096);
    try h.addMem(0, mem0.fd);
    try h.setActivation(50, try h.eventfd(), 0, 0, act_size);
    try h.rig.remote.dispatch();
    try testing.expectEqual(@as(?u32, 50), h.stream.nodeId());
    try testing.expectEqual(@as(usize, 0), h.rec.n_ids);

    try h.boundProps(61);
    try h.rig.remote.dispatch();
    try testing.expectEqual(@as(?u32, 61), h.stream.nodeId());
    try testing.expectEqualSlices(u32, &.{61}, h.rec.node_ids[0..h.rec.n_ids]);

    try h.boundProps(61);
    try h.rig.remote.dispatch();
    try testing.expectEqual(@as(usize, 1), h.rec.n_ids);
}

test "setControls runs the path of an incoming Props" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    h.probe.write = true;
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    try h.skipCreate();

    try h.stream.setControls(.{ .volume = 0.5, .mute = false, .channel_volumes = &.{ 1, 40 } });
    try testing.expectEqual(@as(u32, 1), h.rec.props_seen);
    try testing.expectEqual(@as(f32, 0.5), h.rec.props_volume);
    try testing.expectEqualSlices(f32, &.{ 1, 10 }, h.rec.props_cv[0..h.rec.props_n]);
    try testing.expectEqual(@as(f32, 0.5), h.stream.rt.gain[0]);
    try testing.expectEqual(@as(f32, 5), h.stream.rt.gain[1]);

    try h.rig.remote.dispatch();
    var active = try h.rig.server.expect(h.node_id, 4);
    active.deinit(tgpa);
    for (0..2) |_| {
        var pu = try h.rig.server.expect(h.node_id, 3);
        pu.deinit(tgpa);
    }
    var u = try h.rig.server.expect(h.node_id, 2);
    defer u.deinit(tgpa);
    var uit = try fieldsOf(u.body);
    _ = try nextInt(&uit);
    _ = try nextInt(&uit);
    for (0..5) |_| _ = try uit.next();
    try expectProps(try uit.next(), &.{ 1, 10 }, false, &.{ 1, 1 }, false, 0.5);

    try h.stream.setControls(.{ .mute = true });
    try d.cycle(&h, 0, 256, 48000);
    try d.cycle(&h, 1, 256, 48000);
    try expectFilled(d.samples(0, 1), 256, 0);
    try testing.expectEqual(@as(u32, 2), h.rec.props_seen);
    try testing.expectEqual(true, h.rec.props_mute);
}

test "channel volumes alone switch off the soft volumes" {
    var h: Harness = undefined;
    try h.setup(.{});
    defer h.deinit();
    try h.rig.remote.dispatch();
    try h.skipCreate();

    try sendProps(&h, .{ .soft_volumes = &.{ 0.5, 0.5 } });
    try testing.expectEqual(@as(f32, 0.5), h.stream.rt.gain[0]);
    try sendProps(&h, .{ .channel_volumes = &.{ 0.25, 0.25 } });
    try testing.expectEqual(@as(f32, 0.25), h.stream.rt.gain[0]);
    try testing.expectEqual(@as(f32, 0.25), h.stream.rt.gain[1]);

    // Both in one message: the soft volumes win.
    try sendProps(&h, .{ .soft_volumes = &.{ 0.75, 0.75 }, .channel_volumes = &.{ 0.1, 0.1 } });
    try testing.expectEqual(@as(f32, 0.75), h.stream.rt.gain[0]);
}

fn pauseInProcess(ctx: ?*anyopaque, _: *Stream, _: Buffers) void {
    const act: *shm.NodeActivation = @ptrCast(@alignCast(ctx.?));
    @atomicStore(shm.ActivationStatus, &act.status, .inactive, .release);
}

test "a node that was paused during the cycle wakes nobody" {
    var h: Harness = undefined;
    try h.setup(.{ .process = .{ .ctx = null, .func = pauseInProcess } });
    defer h.deinit();
    try h.rig.remote.dispatch();
    var d = Driver.init(&h, try h.runSession());
    h.stream.process.ctx = d.activation;
    d.activation.server_version = 1;
    const a = try addPeer(&h, 20, 10, 1);

    try d.cycle(&h, 0, 256, 48000);
    try testing.expectEqual(shm.ActivationStatus.inactive, d.status());
    try testing.expectEqual(@as(i32, 1), a.act.state[0].pending);
    try testing.expectEqual(shm.ActivationStatus.not_triggered, a.act.status);
    try testing.expect(!hasCount(a.fd));
}
