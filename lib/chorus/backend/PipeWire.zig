//! The PipeWire backend. A `wireplumber.Graph` on one `pipewire.Remote` feeds the Mixer. The
//! controls of the Mixer go out as requests, and the answers of the server update the Mixer.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const pipewire = @import("pipewire");
const wireplumber = @import("wireplumber");
const Format = @import("../Format.zig");
const Mixer = @import("../Mixer.zig");
const Pipeline = @import("../Pipeline.zig");
const Stream = @import("../Stream.zig");
const Backend = @import("Backend.zig");
const map = @import("pipewire/map.zig");
const rt = @import("pipewire/rt.zig");
const inChild = @import("pipewire/child.zig").inChild;
const PipeWire = @This();

const Remote = pipewire.Remote;
const DataLoop = pipewire.DataLoop;
const Graph = wireplumber.Graph;
const Control = wireplumber.Control;

const log = std.log.scoped(.chorus_pipewire);

pub const kind: Backend.Kind = .pipewire;

pub const Stats = struct {
    /// Changes of the Graph that did not reach the Mixer.
    apply_failed: u64 = 0,
    /// Dispatch calls that failed with a protocol error and went on.
    dispatch_errors: u64 = 0,
    /// Failed iterations of the data loop when it has no thread.
    loop_errors: u64 = 0,
};

const Error = Mixer.Error || error{OwnNode};

pub const Options = struct {
    /// The remote name. PIPEWIRE_REMOTE in `Context.Options.environ` wins over it. With no
    /// environment the socket is `/run/user/<uid>/pipewire-0`, and when that does not connect,
    /// `/run/pipewire/pipewire-0`.
    path: ?[:0]const u8 = null,
    /// Already connected sockets, one for each connect, that the backend takes instead of
    /// connecting. Mainly for tests.
    connected_fds: []const i32 = &.{},
    /// Extra props for the nodes of the Chorus streams.
    stream_props: []const [2][]const u8 = &.{},
    /// Asks for realtime scheduling of the audio thread. The promotion also lowers RLIMIT_RTTIME,
    /// and that limit applies to the whole process.
    realtime: bool = true,
    rt: rt.Options = .{},
};

/// Frames of one interleave pass. A larger cycle runs in several passes.
const scratch_frames = 8192;
const min_period_frames = 64;
const max_period_frames = 8192;
const default_rate = 48000;
/// A promotion allocates about 3.3 KiB in total.
const promote_buffer_bytes = 64 * 1024;

const RtState = Backend.Realtime;

/// The state of one Chorus stream in this backend. The loop thread reads `stream` and the
/// scratch. It reads `stream.negotiated` only while `active` is true.
const Entry = struct {
    owner: *PipeWire,
    stream: *Stream,
    pw: *pipewire.Stream,
    scratch: []f32,
    channels: usize,
    /// True between startStream and stopStream. stopStream waits until the loop thread has
    /// left the process callback, so nothing touches `stream` after it returns.
    active: std.atomic.Value(bool) = .init(false),
    /// The graph rate of the latest cycle. Zero before the first cycle.
    rate_seen: std.atomic.Value(u32) = .init(0),
    /// Set by the loop thread when a draining stream has played its latency in silence. The
    /// loop thread wakes `fd()` when the value changes from false.
    drain_done: std.atomic.Value(bool) = .init(false),
    /// Set by the loop thread when it sees a stopped stream that is still active. The loop
    /// thread wakes `fd()` when the value changes from false.
    stop_seen: std.atomic.Value(bool) = .init(false),
    /// Loop thread only.
    rate_last: u32 = 0,
    /// Loop thread only. Frames of the current drain.
    silent_frames: u64 = 0,
    /// Control thread only. True after the server removed the node or failed the stream.
    failed: bool = false,
};

gpa: std.mem.Allocator,
io: std.Io,
mixer: *Mixer,
app_name: []const u8,
environ: ?*const std.process.Environ.Map,
options: Options,
connected_next: usize = 0,
stats: Stats = .{},
loop: *DataLoop,
remote: ?*Remote = null,
graph: ?*Graph = null,
entries: std.ArrayList(*Entry) = .empty,
rt_state: std.atomic.Value(RtState) = .init(.pending),
rt_thread: ?std.Thread = null,
bus_path: ?[:0]u8 = null,
/// The memory of the promotion thread. The app thread frees it after the join.
promote_buf: ?[]u8 = null,
/// Promotions that failed for lack of memory in `promote_buf`.
rt_oom: std.atomic.Value(u32) = .init(0),
/// An epoll that watches the Remote socket and `wake_fd`. With no loop thread, it watches the
/// epoll of the data loop as well.
wait_fd: i32 = -1,
/// An eventfd that the loop thread writes when it leaves work for `dispatch`.
wake_fd: i32 = -1,
/// Wake writes that found the eventfd full.
wake_full: std.atomic.Value(u32) = .init(0),

const vtable: Backend.VTable = .{
    .deinit = deinitImpl,
    .dispatch = dispatchImpl,
    .reconnect = reconnectImpl,
    .realtime = realtimeImpl,
    .fd = fdImpl,
    .timeoutMs = timeoutMsImpl,
    .capabilities = capabilitiesImpl,
    .openStream = openStreamImpl,
    .closeStream = closeStreamImpl,
    .startStream = startStreamImpl,
    .stopStream = stopStreamImpl,
    .setDefault = setDefaultImpl,
    .setVolume = setVolumeImpl,
    .setMute = setMuteImpl,
    .moveStream = moveStreamImpl,
    .setProfile = setProfileImpl,
    .setPort = setPortImpl,
};

pub fn create(ictx: Backend.InitContext, options: Options) Backend.ConnectError!Backend {
    const self = try ictx.gpa.create(PipeWire);
    errdefer ictx.gpa.destroy(self);
    const loop = DataLoop.init(ictx.gpa, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BackendUnavailable,
    };
    errdefer loop.deinit();
    self.* = .{
        .gpa = ictx.gpa,
        .io = ictx.io,
        .mixer = ictx.mixer,
        .app_name = ictx.app_name,
        .environ = ictx.environ,
        .options = options,
        .loop = loop,
    };
    try self.attach();
    errdefer self.detach();
    try self.startPromotion();
    return .{ .ptr = self, .vtable = &vtable, .kind = kind };
}

/// The address of the system bus in the environment, when it names a socket path. An abstract
/// socket gets a leading '@'.
fn busPathOf(gpa: std.mem.Allocator, address: []const u8) error{OutOfMemory}!?[:0]u8 {
    const path_prefix = "unix:path=";
    const abstract_prefix = "unix:abstract=";
    const abstract = std.mem.startsWith(u8, address, abstract_prefix);
    if (!abstract and !std.mem.startsWith(u8, address, path_prefix)) return null;
    const rest = address[if (abstract) abstract_prefix.len else path_prefix.len..];
    const end = std.mem.indexOfAny(u8, rest, ",;") orelse rest.len;
    if (end == 0) return null;
    const buf = try gpa.allocSentinel(u8, end + @intFromBool(abstract), 0);
    if (abstract) buf[0] = '@';
    @memcpy(buf[@intFromBool(abstract)..], rest[0..end]);
    return buf;
}

/// Promotion blocks on the system bus, so it runs on its own thread. `realtime` gives false
/// until it has finished.
fn startPromotion(self: *PipeWire) error{OutOfMemory}!void {
    if (comptime builtin.single_threaded) {
        self.rt_state.store(.no, .release);
        return;
    }
    if (!self.options.realtime or self.loop.thread == null) {
        self.rt_state.store(.no, .release);
        return;
    }
    if (self.options.rt.bus_path == null) {
        if (self.environ) |env| {
            if (env.get("DBUS_SYSTEM_BUS_ADDRESS")) |address| {
                self.bus_path = try busPathOf(self.gpa, address);
            }
        }
    }
    // The helper thread must not use the allocator of the application.
    const buffer = try self.gpa.alloc(u8, promote_buffer_bytes);
    self.rt_thread = std.Thread.spawn(.{}, promote, .{ self, buffer }) catch |err| {
        self.gpa.free(buffer);
        log.warn("the realtime thread did not start: {s}", .{@errorName(err)});
        self.rt_state.store(.no, .release);
        return;
    };
    self.promote_buf = buffer;
}

fn promote(self: *PipeWire, buffer: []u8) void {
    var tid = self.loop.thread_id.load(.acquire);
    var waited: u32 = 0;
    while (tid == 0 and waited < 1000) : (waited += 1) {
        var ts: linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = linux.nanosleep(&ts, null);
        tid = self.loop.thread_id.load(.acquire);
    }
    if (tid == 0) {
        self.rt_state.store(.no, .release);
        return;
    }
    var options = self.options.rt;
    if (options.bus_path == null) options.bus_path = self.bus_path;
    options.oom_count = &self.rt_oom;
    var fba: std.heap.FixedBufferAllocator = .init(buffer);
    const result = rt.promote(fba.allocator(), self.io, @intCast(tid), options);
    self.rt_state.store(if (result == .failed) .no else .yes, .release);
}

/// The environment when the application gives none. It names the runtime directory of the user
/// and nothing else.
const DefaultEnv = struct {
    buf: [32]u8 = undefined,
    len: usize = 0,

    fn init(uid: u32) DefaultEnv {
        var self: DefaultEnv = .{};
        const text = std.fmt.bufPrint(&self.buf, "/run/user/{d}", .{uid}) catch unreachable;
        self.len = text.len;
        return self;
    }

    pub fn get(self: *const DefaultEnv, key: []const u8) ?[]const u8 {
        if (!std.mem.eql(u8, key, "XDG_RUNTIME_DIR")) return null;
        return self.buf[0..self.len];
    }
};

fn connectRemote(self: *PipeWire) Backend.ConnectError!*Remote {
    const remote_options: Remote.Options = .{ .app_name = self.app_name, .path = self.options.path };
    if (self.connected_next < self.options.connected_fds.len) {
        const sock = self.options.connected_fds[self.connected_next];
        self.connected_next += 1;
        return Remote.fromFd(self.gpa, sock, remote_options) catch |err| return mapConnect(err);
    }
    const result = if (self.environ) |env|
        Remote.connect(self.gpa, pipewire.path.ProcessEnv{ .map = env }, remote_options)
    else
        Remote.connect(self.gpa, DefaultEnv.init(linux.getuid()), remote_options);
    return result catch |err| mapConnect(err);
}

fn mapConnect(err: Remote.ConnectError) Backend.ConnectError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BackendUnavailable,
    };
}

/// Connects and starts a new Graph.
fn attach(self: *PipeWire) Backend.ConnectError!void {
    const remote = try self.connectRemote();
    errdefer remote.deinit();
    try self.buildWait(remote);
    errdefer self.closeWait();
    const graph = Graph.init(self.gpa, remote, .{ .listener = .{ .ctx = self, .func = onChange } }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BackendUnavailable,
    };
    self.remote = remote;
    self.graph = graph;
}

fn closeWait(self: *PipeWire) void {
    if (self.wait_fd >= 0) _ = linux.close(self.wait_fd);
    if (self.wake_fd >= 0) _ = linux.close(self.wake_fd);
    self.wait_fd = -1;
    self.wake_fd = -1;
}

/// Destroys the streams, frees the Graph and the Remote and removes their objects from the
/// Mixer. The Chorus streams stay and Context attaches them again after a reconnect.
fn detach(self: *PipeWire) void {
    while (self.entries.items.len > 0) self.destroyEntry(self.entries.items[self.entries.items.len - 1]);
    if (self.graph) |graph| graph.deinit();
    self.graph = null;
    self.closeWait();
    if (self.remote) |remote| remote.deinit();
    self.remote = null;
    const mixer = self.mixer;
    while (mixer.streams().len > 0) mixer.removeStream(mixer.streams()[0].id);
    while (mixer.endpoints().len > 0) mixer.removeEndpoint(mixer.endpoints()[0].id);
    while (mixer.cards().len > 0) mixer.removeCard(mixer.cards()[0].id);
}

fn onChange(ctx: ?*anyopaque, graph: *Graph, change: Graph.Change) void {
    const self: *PipeWire = @ptrCast(@alignCast(ctx.?));
    self.apply(graph, change) catch |err| {
        self.stats.apply_failed += 1;
        log.warn("the mixer missed a change: {s}", .{@errorName(err)});
    };
}

fn apply(self: *PipeWire, graph: *Graph, change: Graph.Change) map.Error!void {
    const mixer = self.mixer;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    switch (change) {
        .card_added, .card_changed => |gid| {
            const c = graph.card(gid) orelse return;
            try mixer.putCard(try map.card(arena.allocator(), c.*));
        },
        .card_removed => |gid| mixer.removeCard(map.mixerId(gid)),
        .endpoint_added, .endpoint_changed => |gid| {
            const e = graph.endpoint(gid) orelse return;
            try mixer.putEndpoint(try map.endpoint(arena.allocator(), e.*));
        },
        .endpoint_removed => |gid| mixer.removeEndpoint(map.mixerId(gid)),
        .stream_added, .stream_changed => |gid| {
            const s = graph.stream(gid) orelse return;
            try mixer.putStream(try map.stream(s.*));
        },
        .stream_removed => |gid| mixer.removeStream(map.mixerId(gid)),
        .default_changed => |k| {
            const default = graph.defaultEndpoint(k);
            mixer.putDefault(switch (k) {
                .sink => .sink,
                .source => .source,
            }, if (default) |gid| map.mixerId(gid) else null);
        },
        else => {},
    }
}

fn from(ptr: *anyopaque) *PipeWire {
    return @ptrCast(@alignCast(ptr));
}

fn entryOf(stream: *Stream) ?*Entry {
    return @ptrCast(@alignCast(stream.backend_data orelse return null));
}

fn deinitImpl(ptr: *anyopaque) void {
    const self = from(ptr);
    self.detach();
    if (self.rt_thread) |t| t.join();
    if (self.promote_buf) |buffer| self.gpa.free(buffer);
    self.loop.deinit();
    self.entries.deinit(self.gpa);
    if (self.bus_path) |p| self.gpa.free(p);
    self.gpa.destroy(self);
}

fn dispatchImpl(ptr: *anyopaque) Backend.DispatchError!Backend.Event {
    const self = from(ptr);
    const remote = self.remote orelse return .none;
    var wakes: u64 = 0;
    _ = linux.read(self.wake_fd, std.mem.asBytes(&wakes), 8);
    remote.dispatch() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Disconnected => {
            self.detach();
            return .disconnected;
        },
        // The next dispatch goes on with the next message.
        error.Protocol, error.Unexpected, error.Reentrant => {
            self.stats.dispatch_errors += 1;
            log.warn("dispatch failed: {s}", .{@errorName(err)});
        },
    };
    if (self.loop.thread == null) self.loop.iterate(0) catch |err| self.noteLoopError(err);
    self.pump();
    return .none;
}

/// Counts a failed iteration of the data loop. Only the first one is logged.
fn noteLoopError(self: *PipeWire, err: DataLoop.Error) void {
    if (self.stats.loop_errors == 0) log.warn("data loop failed: {s}", .{@errorName(err)});
    self.stats.loop_errors += 1;
}

/// Reads what the loop thread left for the control side.
fn pump(self: *PipeWire) void {
    for (self.entries.items) |entry| {
        const stream = entry.stream;
        const rate = entry.rate_seen.load(.acquire);
        const native = stream.negotiated.native;
        if (rate != 0 and rate != native.rate and stream.pending_native == null and entry.active.load(.acquire)) {
            var next = native;
            next.rate = rate;
            stream.pending_native = .{ .native = next, .period_frames = stream.negotiated.period_frames };
        }
        if (entry.drain_done.swap(false, .acq_rel)) {
            stream.drained();
            if (stream.state() == .stopped) self.deactivate(entry, true);
        }
        // The callback of the app ended the stream, and the node runs until this stop.
        if (stream.state() == .stopped and entry.active.load(.acquire)) self.deactivate(entry, true);
    }
}

fn reconnectImpl(ptr: *anyopaque) Backend.ConnectError!void {
    const self = from(ptr);
    if (self.remote != null) return;
    try self.attach();
}

fn realtimeImpl(ptr: *anyopaque) Backend.Realtime {
    return from(ptr).rt_state.load(.acquire);
}

fn timeoutMsImpl(ptr: *anyopaque) ?u32 {
    _ = ptr;
    return null;
}

fn fdImpl(ptr: *anyopaque) ?i32 {
    const self = from(ptr);
    if (self.remote == null or self.wait_fd < 0) return null;
    return self.wait_fd;
}

/// Makes the eventfd for the loop thread and the epoll that wakes for the Remote, the eventfd
/// and, with no loop thread, the data loop.
fn buildWait(self: *PipeWire, remote: *Remote) Backend.ConnectError!void {
    const wake_rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
    if (linux.errno(wake_rc) != .SUCCESS) return error.BackendUnavailable;
    const wake_fd: i32 = @intCast(wake_rc);
    errdefer _ = linux.close(wake_fd);
    const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.BackendUnavailable;
    const wait: i32 = @intCast(rc);
    errdefer _ = linux.close(wait);
    const watched = [_]i32{ remote.fd(), wake_fd, self.loop.epfd };
    for (watched[0..if (self.loop.thread == null) 3 else 2]) |fd| {
        var ev: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .fd = fd } };
        if (linux.errno(linux.epoll_ctl(wait, linux.EPOLL.CTL_ADD, fd, &ev)) != .SUCCESS) return error.BackendUnavailable;
    }
    self.wait_fd = wait;
    self.wake_fd = wake_fd;
}

/// Makes `fd()` readable. Only the loop thread calls it, and it never blocks. With no loop
/// thread the data loop is already in the wait set.
fn wake(self: *PipeWire) void {
    if (self.loop.thread == null or self.wake_fd < 0) return;
    const one: u64 = 1;
    const rc = linux.write(self.wake_fd, std.mem.asBytes(&one), 8);
    if (linux.errno(rc) == .AGAIN) _ = self.wake_full.fetchAdd(1, .monotonic);
}

fn capabilitiesImpl(ptr: *anyopaque) Mixer.Capabilities {
    _ = ptr;
    return .all;
}

fn roleName(role: Stream.Role) []const u8 {
    return switch (role) {
        .media => "Music",
        .ui => "Event",
        .game => "Game",
        .communication => "Communication",
        .notification => "Notification",
        .alarm => "Alarm",
    };
}

fn mapCreate(err: pipewire.Stream.CreateError) Stream.OpenError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidChannels => error.UnsupportedFormat,
        else => error.Disconnected,
    };
}

fn openStreamImpl(ptr: *anyopaque, stream: *Stream) Stream.OpenError!Backend.Negotiated {
    const self = from(ptr);
    const remote = self.remote orelse return error.Disconnected;
    const graph = self.graph orelse return error.Disconnected;
    if (entryOf(stream)) |old| self.destroyEntry(old);

    const options = stream.options;
    const count: usize = options.format.channels.count;
    var positions: [Format.max_channels]pipewire.spa.AudioChannel = undefined;
    for (options.format.channels.slice(), positions[0..count]) |p, *out| out.* = map.toChannel(p);

    var rate = graph.graphRate() orelse default_rate;
    if (rate < Format.min_rate or rate > Format.max_rate) rate = default_rate;

    var serial: [24]u8 = undefined;
    var target: ?[]const u8 = null;
    var monitor = false;
    if (options.device) |device| {
        // After a reconnect the ids are new and the graph can be empty, so the name is the key.
        if (stream.backend_target.name()) |name| {
            target = name;
            monitor = stream.backend_target.monitor;
        } else {
            const endpoint = graph.endpoint(map.graphId(device)) orelse return error.UnknownDevice;
            if (options.direction == .playback and endpoint.kind != .sink) return error.UnknownDevice;
            target = std.fmt.bufPrint(&serial, "{d}", .{endpoint.serial}) catch unreachable;
            monitor = options.direction == .capture and endpoint.kind == .sink;
            stream.backend_target.set(endpoint.name, monitor);
        }
    }

    const props = try self.gpa.alloc([2][]const u8, self.options.stream_props.len + 1);
    defer self.gpa.free(props);
    @memcpy(props[0..self.options.stream_props.len], self.options.stream_props);
    var props_len = self.options.stream_props.len;
    if (monitor) {
        props[props_len] = .{ "stream.capture.sink", "true" };
        props_len += 1;
    }
    const entry = try self.gpa.create(Entry);
    errdefer self.gpa.destroy(entry);
    const scratch = try self.gpa.alloc(f32, scratch_frames * count);
    errdefer self.gpa.free(scratch);
    try self.entries.ensureUnusedCapacity(self.gpa, 1);
    entry.* = .{ .owner = self, .stream = stream, .pw = undefined, .scratch = scratch, .channels = count };
    const pw = pipewire.Stream.create(remote, self.loop, .{
        .direction = switch (options.direction) {
            .playback => .playback,
            .capture => .capture,
        },
        .name = self.app_name,
        .channels = positions[0..count],
        .rate = rate,
        .latency_frames = options.latency_frames,
        .role = roleName(options.role),
        .target = target,
        .props = props[0..props_len],
        .process = .{ .ctx = entry, .func = onProcess },
        .listener = .{ .ctx = entry, .func = onEvent },
    }) catch |err| return mapCreate(err);
    entry.pw = pw;
    errdefer pw.destroy();
    pw.setActive(false) catch |err| return mapCreate(err);
    remote.flush() catch |err| return mapCreate(err);

    self.entries.appendAssumeCapacity(entry);
    stream.backend_data = entry;
    stream.pending_native = null;
    return .{
        .native = .{ .sample = .f32, .rate = rate, .channels = options.format.channels },
        .period_frames = std.math.clamp(options.latency_frames, min_period_frames, max_period_frames),
    };
}

fn destroyEntry(self: *PipeWire, entry: *Entry) void {
    entry.active.store(false, .release);
    entry.pw.destroy();
    const i = std.mem.indexOfScalar(*Entry, self.entries.items, entry).?;
    _ = self.entries.swapRemove(i);
    entry.stream.backend_data = null;
    entry.stream.pending_native = null;
    self.gpa.free(entry.scratch);
    self.gpa.destroy(entry);
}

fn closeStreamImpl(ptr: *anyopaque, stream: *Stream) void {
    const entry = entryOf(stream) orelse return;
    from(ptr).destroyEntry(entry);
}

fn startStreamImpl(ptr: *anyopaque, stream: *Stream) Stream.StartError!void {
    const self = from(ptr);
    const remote = self.remote orelse return error.Disconnected;
    const entry = entryOf(stream) orelse return error.Disconnected;
    if (entry.failed) return error.Disconnected;
    entry.drain_done.store(false, .release);
    entry.stop_seen.store(false, .release);
    entry.active.store(true, .release);
    if (stream.pending_native != null) return;
    entry.pw.setActive(true) catch |err| {
        entry.active.store(false, .release);
        log.warn("the stream did not start: {s}", .{@errorName(err)});
        return error.Disconnected;
    };
    remote.flush() catch |err| log.warn("the start was not sent: {s}", .{@errorName(err)});
}

fn stopStreamImpl(ptr: *anyopaque, stream: *Stream) void {
    const self = from(ptr);
    const entry = entryOf(stream) orelse return;
    self.deactivate(entry, stream.pending_native == null);
}

fn waitForLoop(ctx: *anyopaque) void {
    _ = ctx;
}

/// Returns after the loop thread has left the process callback of the entry. A stream with a
/// pending native format is only swapping its pipeline. The server keeps the node active then,
/// and startStream does not send the start again.
fn deactivate(self: *PipeWire, entry: *Entry, send: bool) void {
    entry.active.store(false, .release);
    self.loop.invoke(entry, waitForLoop);
    if (entry.failed or !send) return;
    entry.pw.setActive(false) catch |err| log.warn("the stream did not stop: {s}", .{@errorName(err)});
    if (self.remote) |remote| remote.flush() catch |err| log.warn("the stop was not sent: {s}", .{@errorName(err)});
}

fn silence(channels: []const []f32) void {
    for (channels) |ch| @memset(ch, 0);
}

/// Runs on the loop thread. It does not allocate, block or call the control functions.
fn onProcess(ctx: ?*anyopaque, pw: *pipewire.Stream, buffers: pipewire.Stream.Buffers) void {
    _ = pw;
    const entry: *Entry = @ptrCast(@alignCast(ctx.?));
    const stream = entry.stream;
    const playback = stream.options.direction == .playback;
    const n = entry.channels;
    if (!entry.active.load(.acquire) or buffers.channels.len != n) {
        entry.silent_frames = 0;
        if (playback) silence(buffers.channels);
        return;
    }
    if (buffers.rate != entry.rate_last) {
        entry.rate_last = buffers.rate;
        entry.rate_seen.store(buffers.rate, .release);
        entry.owner.wake();
    }
    if (buffers.rate != stream.negotiated.native.rate) {
        if (playback) silence(buffers.channels);
        return;
    }
    const draining = stream.state() == .draining;
    const frames = @min(buffers.frames, buffers.channels[0].len);
    var offset: usize = 0;
    while (offset < frames) {
        const count = @min(frames - offset, scratch_frames);
        const samples = entry.scratch[0 .. count * n];
        if (playback) {
            stream.render(std.mem.sliceAsBytes(samples));
            for (buffers.channels, 0..) |ch, c| {
                for (ch[offset..][0..count], 0..) |*out, i| out.* = samples[i * n + c];
            }
        } else {
            for (buffers.channels, 0..) |ch, c| {
                for (ch[offset..][0..count], 0..) |v, i| samples[i * n + c] = v;
            }
            stream.capture(std.mem.sliceAsBytes(samples));
        }
        offset += count;
    }
    if (stream.state() == .stopped and !entry.stop_seen.swap(true, .acq_rel)) entry.owner.wake();
    if (draining) {
        entry.silent_frames += frames;
        if (entry.silent_frames >= stream.options.latency_frames and !entry.drain_done.swap(true, .acq_rel)) entry.owner.wake();
    } else {
        entry.silent_frames = 0;
    }
}

/// Runs on the control thread, inside `Remote.dispatch`.
fn onEvent(ctx: ?*anyopaque, pw: *pipewire.Stream, event: pipewire.Stream.Event) void {
    _ = pw;
    const entry: *Entry = @ptrCast(@alignCast(ctx.?));
    const gone = switch (event) {
        .removed => true,
        .state => |s| s == .failed,
        else => false,
    };
    if (!gone or entry.failed) return;
    entry.failed = true;
    entry.active.store(false, .release);
    _ = entry.stream.markDisconnected();
}

/// A request that cannot be sent is reported as unsupported, except for a lack of memory.
fn mapControl(err: Control.Error) Error {
    return switch (err) {
        error.UnknownObject => error.UnknownObject,
        error.OwnNode => error.OwnNode,
        error.InvalidIndex => error.InvalidIndex,
        error.InvalidVolume => error.InvalidVolume,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unsupported,
    };
}

/// Sends the queued request now.
fn flush(remote: *Remote) Error!void {
    remote.flush() catch |err| return mapControl(err);
}

/// The Mixer has no error for a node that this client owns. An own stream with a backend entry
/// goes to its own controls, so this error means an own node with no entry. It becomes unsupported.
fn edge(result: Error!void) Mixer.Error!void {
    return result catch |err| switch (err) {
        error.OwnNode => error.Unsupported,
        else => |e| e,
    };
}

fn setDefault(ptr: *anyopaque, k: Mixer.Kind, endpoint_id: Mixer.Id) Error!void {
    const self = from(ptr);
    const graph = self.graph orelse return error.Unsupported;
    Control.setDefault(graph, switch (k) {
        .sink => .sink,
        .source => .source,
    }, map.graphId(endpoint_id)) catch |err| return mapControl(err);
    try flush(self.remote.?);
}

fn controlTarget(target: Mixer.Target) Control.Target {
    return switch (target) {
        .endpoint => |target_id| .{ .endpoint = map.graphId(target_id) },
        .stream => |target_id| .{ .stream = map.graphId(target_id) },
    };
}

fn mapSend(err: pipewire.Stream.SendError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unsupported,
    };
}

/// The entry of a stream that this client exports. Null when the target is not a stream, or
/// not one of ours. Error when the node is ours and has no entry. That happens when the graph
/// still lists the node after the entry is gone. The edge maps it to unsupported.
fn ownEntry(self: *PipeWire, graph: *Graph, target: Mixer.Target) error{OwnNode}!?*Entry {
    const stream_id = switch (target) {
        .stream => |stream_id| map.graphId(stream_id),
        .endpoint => return null,
    };
    if (!graph.ownsStream(stream_id)) return null;
    for (self.entries.items) |entry| {
        if (entry.pw.nodeId() == stream_id) return entry;
    }
    return error.OwnNode;
}

fn setVolume(ptr: *anyopaque, target: Mixer.Target, values: []const f32) Error!void {
    const self = from(ptr);
    const graph = self.graph orelse return error.Unsupported;
    if (try self.ownEntry(graph, target)) |entry| {
        entry.pw.setControls(.{ .channel_volumes = values }) catch |err| return mapSend(err);
        return flush(self.remote.?);
    }
    Control.setVolume(graph, controlTarget(target), values) catch |err| return mapControl(err);
    try flush(self.remote.?);
}

fn setMute(ptr: *anyopaque, target: Mixer.Target, mute: bool) Error!void {
    const self = from(ptr);
    const graph = self.graph orelse return error.Unsupported;
    if (try self.ownEntry(graph, target)) |entry| {
        entry.pw.setControls(.{ .mute = mute }) catch |err| return mapSend(err);
        return flush(self.remote.?);
    }
    Control.setMute(graph, controlTarget(target), mute) catch |err| return mapControl(err);
    try flush(self.remote.?);
}

fn moveStream(ptr: *anyopaque, stream_id: Mixer.Id, endpoint_id: Mixer.Id) Error!void {
    const self = from(ptr);
    const graph = self.graph orelse return error.Unsupported;
    Control.moveStream(graph, map.graphId(stream_id), map.graphId(endpoint_id)) catch |err| return mapControl(err);
    try flush(self.remote.?);
}

fn setProfile(ptr: *anyopaque, card_id: Mixer.Id, index: u32) Error!void {
    const self = from(ptr);
    const graph = self.graph orelse return error.Unsupported;
    Control.setProfile(graph, map.graphId(card_id), index) catch |err| return mapControl(err);
    try flush(self.remote.?);
}

fn setPort(ptr: *anyopaque, endpoint_id: Mixer.Id, index: u32) Error!void {
    const self = from(ptr);
    const graph = self.graph orelse return error.Unsupported;
    Control.setPort(graph, map.graphId(endpoint_id), index) catch |err| return mapControl(err);
    try flush(self.remote.?);
}

fn setDefaultImpl(ptr: *anyopaque, k: Mixer.Kind, endpoint_id: Mixer.Id) Mixer.Error!void {
    return edge(setDefault(ptr, k, endpoint_id));
}

fn setVolumeImpl(ptr: *anyopaque, target: Mixer.Target, values: []const f32) Mixer.Error!void {
    return edge(setVolume(ptr, target, values));
}

fn setMuteImpl(ptr: *anyopaque, target: Mixer.Target, mute: bool) Mixer.Error!void {
    return edge(setMute(ptr, target, mute));
}

fn moveStreamImpl(ptr: *anyopaque, stream_id: Mixer.Id, endpoint_id: Mixer.Id) Mixer.Error!void {
    return edge(moveStream(ptr, stream_id, endpoint_id));
}

fn setProfileImpl(ptr: *anyopaque, card_id: Mixer.Id, index: u32) Mixer.Error!void {
    return edge(setProfile(ptr, card_id, index));
}

fn setPortImpl(ptr: *anyopaque, endpoint_id: Mixer.Id, index: u32) Mixer.Error!void {
    return edge(setPort(ptr, endpoint_id, index));
}

const testing = std.testing;
const tgpa = testing.allocator;
const pod = pipewire.pod;
const FakeServer = pipewire.testing.FakeServer;
const support = wireplumber.testing;
const Context = @import("../Context.zig");
const path = pipewire.path;

fn id(n: u32) Mixer.Id {
    return @fromBackingInt(n);
}

const Harness = struct {
    ctx: *Context,
    f: support.Fixture,
    md: support.Bind,
    fds: [2]i32,
    spare: FakeServer,
    spare_used: bool = false,

    fn init(self: *Harness) !void {
        var server = try FakeServer.init(tgpa);
        errdefer server.deinit();
        self.spare = try FakeServer.init(tgpa);
        errdefer self.spare.deinit();
        self.spare_used = false;
        self.fds = .{ server.client_fd, self.spare.client_fd };
        self.ctx = try Context.init(tgpa, testing.io, .{
            .app_name = "test",
            .backend = .pipewire,
            .pipewire_backend = .{ .connected_fds = &self.fds, .realtime = false },
        });
        errdefer self.ctx.deinit();
        const be = self.ctx.backend.as(PipeWire).?;
        self.f = .{
            .rig = .{ .server = server, .remote = be.remote.?, .registry = be.graph.?.registry },
            .graph = be.graph.?,
            .rec = .{},
        };
        _ = try self.ctx.dispatch();
        try self.f.rig.skipHandshake();
        var m = try self.f.rig.server.expect(0, 5);
        m.deinit(tgpa);
        try self.f.populate();
        try support.fillCard(&self.f, self.f.bindOf(40));
        self.md = try self.f.bindMetadata(60, "default");
        try self.f.defaultName(self.md, "default.audio.sink", "alsa_output.test");
    }

    fn deinit(self: *Harness) void {
        self.ctx.deinit();
        self.f.rig.server.deinit();
        if (!self.spare_used) {
            _ = std.os.linux.close(self.spare.client_fd);
            self.spare.deinit();
        }
    }

    fn expectParam(self: *Harness, bind: support.Bind, param_id: u32, spec: anytype) !void {
        var m = try self.f.rig.server.expect(bind.new_id, 3);
        defer m.deinit(tgpa);
        try expectParamBody(m.body, param_id, spec);
    }
};

fn expectParamBody(body: []const u8, param_id: u32, spec: anytype) !void {
    var buf: [512]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const s = try b.beginStruct();
    try b.id(param_id);
    try b.int(0);
    try spec(&b);
    b.end(s);
    try testing.expectEqualSlices(u8, b.bytesWritten(), body);
}

test "the mixer lists the card, the endpoints and the stream of the registry" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const m = h.ctx.mixer();

    try testing.expectEqual(@as(usize, 1), m.cards().len);
    const card = m.card(id(40)).?;
    try testing.expectEqualStrings("alsa_card.test", card.name);
    try testing.expectEqualStrings("Test Card", card.description);
    try testing.expectEqual(@as(usize, 2), card.profiles.len);
    try testing.expectEqualStrings("HiFi", card.profiles[1].name);
    try testing.expectEqual(@as(?u32, 1), card.active_profile);

    try testing.expectEqual(@as(usize, 2), m.endpoints().len);
    const sink = m.endpoint(id(41)).?;
    try testing.expectEqual(Mixer.Kind.sink, sink.kind);
    try testing.expectEqual(@as(?Mixer.Id, id(40)), sink.card);
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.5 }, sink.volume.slice());
    try testing.expect(!sink.mute);
    try testing.expectEqual(@as(usize, 2), sink.ports.len);
    try testing.expectEqualStrings("speaker", sink.ports[0].name);
    try testing.expectEqual(@as(u32, 6), sink.ports[1].index);
    try testing.expectEqual(@as(?u32, 5), sink.active_port);
    try testing.expectEqual(Mixer.Kind.source, m.endpoint(id(42)).?.kind);

    try testing.expectEqual(@as(usize, 1), m.streams().len);
    const s = m.stream(id(43)).?;
    try testing.expectEqual(Pipeline.Direction.playback, s.direction);
    try testing.expectEqualStrings("player", s.app_name);
    try testing.expectEqualStrings("Song", s.name);
    try testing.expectEqual(@as(?Mixer.Id, id(41)), s.endpoint);

    try testing.expectEqual(@as(?Mixer.Id, id(41)), m.default(.sink));
    try testing.expectEqual(@as(?Mixer.Id, null), m.default(.source));
}

test "setVolume on a sink sends the route of the card" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.ctx.mixer().setVolume(.{ .endpoint = id(41) }, .{ .channels = &.{ 0.25, 0.5 } });
    try h.expectParam(h.f.bindOf(40), 13, struct {
        fn build(b: *pod.Builder) !void {
            try wireplumber.params.buildRoute(b, 5, 3, .{ .channel_volumes = &.{ 0.25, 0.5 } }, true);
        }
    }.build);
    try h.ctx.mixer().setMute(.{ .endpoint = id(41) }, true);
    try h.expectParam(h.f.bindOf(40), 13, struct {
        fn build(b: *pod.Builder) !void {
            try wireplumber.params.buildRoute(b, 5, 3, .{ .mute = true }, true);
        }
    }.build);
}

test "setVolume on an app stream sends props to its node" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.f.param(h.f.bindOf(43), 2, 0, support.PropsSpec{ .volumes = &.{ 0.75, 0.75 }, .mute = false });
    try h.f.commit();
    try testing.expectEqualSlices(f32, &.{ 0.75, 0.75 }, h.ctx.mixer().stream(id(43)).?.volume.slice());
    try h.ctx.mixer().setVolume(.{ .stream = id(43) }, .{ .channels = &.{0.5} });
    try h.expectParam(h.f.bindOf(43), 2, struct {
        fn build(b: *pod.Builder) !void {
            try wireplumber.params.buildProps(b, .{ .channel_volumes = &.{ 0.5, 0.5 } });
        }
    }.build);
}

test "setDefault writes the metadata" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.ctx.mixer().setDefault(.source, id(42));
    var m = try h.f.rig.server.expect(h.md.new_id, 1);
    defer m.deinit(tgpa);
    var buf: [512]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const s = try b.beginStruct();
    try b.int(0);
    try b.string("default.configured.audio.source");
    try b.string("Spa:String:JSON");
    try b.string("{\"name\":\"alsa_input.test\"}");
    b.end(s);
    try testing.expectEqualSlices(u8, b.bytesWritten(), m.body);
}

test "the mixer follows removals and the default" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.f.globalRemove(43);
    try h.f.removeId(43);
    try testing.expectEqual(@as(usize, 0), h.ctx.mixer().streams().len);
    try h.f.globalRemove(41);
    try h.f.removeId(41);
    try testing.expect(h.ctx.mixer().endpoint(id(41)) == null);
    try testing.expectEqual(@as(?Mixer.Id, null), h.ctx.mixer().default(.sink));
}

test "fd is the wait set of the connection" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try expectFd(h.ctx);
    try testing.expect(h.ctx.info().backend == .pipewire);
    try testing.expectEqual(Context.Realtime.no, h.ctx.info().realtime);
}

test "info reports the realtime state of the promotion" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const be = h.ctx.backend.as(PipeWire).?;
    be.rt_state.store(.pending, .release);
    try testing.expectEqual(Context.Realtime.pending, h.ctx.info().realtime);
    be.rt_state.store(.yes, .release);
    try testing.expectEqual(Context.Realtime.yes, h.ctx.info().realtime);
    be.rt_state.store(.no, .release);
    try testing.expectEqual(Context.Realtime.no, h.ctx.info().realtime);
}

const Counter = struct {
    n: usize = 0,

    fn listener(self: *Counter) Mixer.Listener {
        return .{ .ctx = self, .func = count };
    }

    fn count(ctx: ?*anyopaque, mixer: *const Mixer, change: Mixer.Change) void {
        _ = mixer;
        _ = change;
        const self: *Counter = @ptrCast(@alignCast(ctx.?));
        self.n += 1;
    }
};

test "the teardown of the context does not call the mixer listeners" {
    var h: Harness = undefined;
    try h.init();
    var counter: Counter = .{};
    try h.ctx.mixer().listen(counter.listener());
    try testing.expect(h.ctx.mixer().endpoints().len > 0);
    h.ctx.deinit();
    h.f.rig.server.deinit();
    if (!h.spare_used) {
        _ = std.os.linux.close(h.spare.client_fd);
        h.spare.deinit();
    }
    try testing.expectEqual(@as(usize, 0), counter.n);
}

test "a closed server gives disconnected and empties the mixer" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = std.os.linux.shutdown(h.f.rig.server.server_fd, std.os.linux.SHUT.RDWR);
    try testing.expectEqual(Context.Event.disconnected, try h.ctx.dispatch());
    try testing.expectEqual(@as(?i32, null), h.ctx.fd());
    try testing.expectEqual(@as(usize, 0), h.ctx.mixer().endpoints().len);
    try testing.expectEqual(@as(usize, 0), h.ctx.mixer().cards().len);
    try testing.expectEqual(@as(usize, 0), h.ctx.mixer().streams().len);
    try testing.expectEqual(Context.Event.none, try h.ctx.dispatch());
}

test "a stream with no known channels has no volume control" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try testing.expectEqual(@as(u8, 0), h.ctx.mixer().stream(id(43)).?.volume.count);
    try testing.expectError(error.Unsupported, h.ctx.mixer().setVolume(.{ .stream = id(43) }, .{ .channels = &.{0.5} }));
}

test "a node of this client is unsupported at the edge" {
    try testing.expectEqual(error.OwnNode, mapControl(error.OwnNode));
    try testing.expectError(error.Unsupported, edge(error.OwnNode));
    try testing.expectError(error.UnknownObject, edge(mapControl(error.UnknownObject)));
    try testing.expectError(error.Unsupported, edge(mapControl(error.NoSpace)));
    try edge({});
}

test "a bad message is counted and dispatch goes on" {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const be = h.ctx.backend.as(PipeWire).?;
    try testing.expectEqual(@as(u64, 0), be.stats.dispatch_errors);
    try h.f.rig.server.send(h.f.graph.registryId(), 0, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &.{});
    try testing.expectEqual(Context.Event.none, try h.ctx.dispatch());
    try testing.expectEqual(@as(u64, 1), be.stats.dispatch_errors);
}

test "a change that cannot reach the mixer is counted" {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const be = h.ctx.backend.as(PipeWire).?;
    var failing = testing.FailingAllocator.init(tgpa, .{ .fail_index = 0 });
    be.gpa = failing.allocator();
    defer be.gpa = tgpa;
    try h.f.param(h.f.bindOf(40), 12, 3, support.RouteSpec{ .index = 8, .name = "line", .profiles = &.{1}, .devices = &.{3} });
    try h.f.commit();
    try testing.expect(be.stats.apply_failed > 0);
}

test "failed iterations of the data loop are counted and logged once" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    const be = h.ctx.backend.as(PipeWire).?;
    be.noteLoopError(error.Unexpected);
    be.noteLoopError(error.Unexpected);
    try testing.expectEqual(@as(u64, 2), be.stats.loop_errors);
}

test "a second connect takes the second socket and shows only the new objects" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = std.os.linux.shutdown(h.f.rig.server.server_fd, std.os.linux.SHUT.RDWR);
    try testing.expectEqual(Context.Event.disconnected, try h.ctx.dispatch());
    try testing.expectEqual(@as(usize, 0), h.ctx.mixer().endpoints().len);

    try h.ctx.reconnect();
    const be = h.ctx.backend.as(PipeWire).?;
    h.f.rig.server.deinit();
    h.f.rig.server = h.spare;
    h.spare_used = true;
    h.f.rig.remote = be.remote.?;
    h.f.graph = be.graph.?;
    h.f.rig.registry = be.graph.?.registry;
    _ = try h.ctx.dispatch();
    try h.f.rig.skipHandshake();
    var m = try h.f.rig.server.expect(0, 5);
    m.deinit(tgpa);
    try h.f.addNode(51, "Audio/Sink", "other_sink");
    const md = try h.f.bindMetadata(61, "default");
    try h.f.defaultName(md, "default.audio.sink", "other_sink");

    const mixer = h.ctx.mixer();
    try testing.expectEqual(@as(usize, 1), mixer.endpoints().len);
    try testing.expect(mixer.endpoint(id(41)) == null);
    try testing.expect(mixer.endpoint(id(51)) != null);
    try testing.expectEqual(@as(usize, 0), mixer.cards().len);
    try testing.expectEqual(@as(usize, 0), mixer.streams().len);
    try testing.expectEqual(@as(?Mixer.Id, id(51)), mixer.default(.sink));
    try expectFd(h.ctx);
}

test "the default environment names the runtime directory of the user" {
    const env = DefaultEnv.init(1000);
    try testing.expectEqualStrings("/run/user/1000", env.get("XDG_RUNTIME_DIR").?);
    try testing.expect(env.get("PIPEWIRE_REMOTE") == null);
    var buf: [108]u8 = undefined;
    try testing.expectEqualStrings("/run/user/1000/pipewire-0", try path.resolve(&buf, env, null));
    try testing.expectEqualStrings("/run/user/1000/other", try path.resolve(&buf, env, "other"));
}

const pwh = pipewire.testing.stream_harness;
const shm = pipewire.shm;

const stereo_f32: Format = .{ .sample = .f32, .rate = 48000, .channels = .stereo };

/// A stereo callback. Playback writes 0.5 left and -0.5 right. Capture keeps the first frame.
const Tone = struct {
    status: Stream.Status = .@"continue",
    calls: usize = 0,
    heard: [2]f32 = .{ 0, 0 },

    fn callback(self: *Tone) Stream.Callback {
        return .{ .ctx = self, .func = run };
    }

    fn run(ctx: ?*anyopaque, stream: *Stream, buffer: Stream.Buffer) Stream.Status {
        const self: *Tone = @ptrCast(@alignCast(ctx.?));
        const samples = std.mem.bytesAsSlice(f32, buffer.bytes);
        switch (stream.options.direction) {
            .playback => {
                var i: usize = 0;
                while (i + 1 < samples.len) : (i += 2) {
                    samples[i] = 0.5;
                    samples[i + 1] = -0.5;
                }
            },
            .capture => if (samples.len >= 2) {
                self.heard = .{ samples[0], samples[1] };
            },
        }
        self.calls += 1;
        return self.status;
    }
};

/// The stream harness of the pipewire module on the stream that the backend made.
const Wire = struct {
    host: *Harness,
    h: pwh.Harness,

    fn init(host: *Harness, s: *Stream) !Wire {
        var self: Wire = .{
            .host = host,
            .h = .attach(&host.f.rig, host.ctx.backend.as(PipeWire).?.loop, entryOf(s).?.pw),
        };
        try self.h.skipCreate();
        return self;
    }

    fn deinit(self: *Wire) void {
        self.h.release(&self.host.f.rig);
    }

    fn driver(self: *Wire, capture: bool) !pwh.Driver {
        try self.h.rig.remote.dispatch();
        const session = if (capture) try self.h.runCaptureSession() else try self.h.runSession();
        const d = pwh.Driver.init(&self.h, session);
        d.activation.bits = shm.pending_sync_bit | shm.activation_version_bit;
        return d;
    }

    /// Reads server messages until one for object `object_id` with `opcode`.
    fn next(self: *Wire, object_id: u32, opcode: u8) !pipewire.testing.FakeServer.OwnedMessage {
        try self.h.rig.remote.dispatch();
        for (0..16) |_| {
            var m = try self.h.rig.server.readMessage();
            if (m.id == object_id and m.opcode == opcode) return m;
            m.deinit(tgpa);
        }
        return error.NotFound;
    }

    fn nextNode(self: *Wire, opcode: u8) !pipewire.testing.FakeServer.OwnedMessage {
        return self.next(self.h.node_id, opcode);
    }
};

fn expectPort(d: *pwh.Driver, port: usize, value: f32, frames: usize) !void {
    for (d.samples(port, 0)[0..frames]) |s| try testing.expectEqual(value, s);
}

test "a playback cycle interleaves and splits into the ports" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback(), .latency_frames = 64 });
    var wire = try Wire.init(&h, s);
    defer wire.deinit();
    var d = try wire.driver(false);
    try s.start();

    try d.cycle(&wire.h, 4, 256, 48000);
    try expectPort(&d, 0, 0.5, 256);
    try expectPort(&d, 1, -0.5, 256);
    try testing.expectEqual(@as(usize, 4), tone.calls);
    try testing.expectEqual(@as(u64, 256), s.stats().frames);
    try testing.expectEqual(shm.ActivationStatus.finished, d.status());
}

test "a capture cycle interleaves the ports for the callback" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{ .direction = .capture, .format = stereo_f32, .callback = tone.callback(), .latency_frames = 64 });
    var wire = try Wire.init(&h, s);
    defer wire.deinit();
    var d = try wire.driver(true);
    try s.start();
    @memset(d.samples(0, 1), 0.25);
    @memset(d.samples(1, 1), -0.25);
    for (0..2) |port| {
        d.chunk(port, 1).* = .{ .offset = 0, .size = 1024, .stride = 4, .flags = 0 };
        d.consumerSlot(port, 6).* = .{ .status = 2, .buffer_id = 1 };
    }

    try d.cycle(&wire.h, 6, 256, 48000);
    try testing.expectEqualSlices(f32, &.{ 0.25, -0.25 }, &tone.heard);
    try testing.expectEqual(@as(usize, 4), tone.calls);
}

test "a stopped stream writes silence and does not call the app" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback(), .latency_frames = 64 });
    var wire = try Wire.init(&h, s);
    defer wire.deinit();
    var d = try wire.driver(false);
    try s.start();
    try d.cycle(&wire.h, 4, 64, 48000);
    try testing.expectEqual(@as(usize, 1), tone.calls);

    s.stop();
    @memset(d.samples(0, 1), 0.75);
    @memset(d.samples(1, 1), 0.75);
    try d.wake(.triggered, 5, 64, 48000);
    try d.settle(&wire.h);
    try testing.expectEqual(@as(usize, 1), tone.calls);
    try testing.expectEqual(@as(f32, 0), d.samples(0, 1)[0]);
}

test "a rate that differs from the negotiated rate gives silence and a pending format" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback(), .latency_frames = 64 });
    var wire = try Wire.init(&h, s);
    defer wire.deinit();
    var d = try wire.driver(false);
    try s.start();
    @memset(d.samples(0, 0), 0.75);
    @memset(d.samples(1, 0), 0.75);

    try d.cycle(&wire.h, 4, 256, 44100);
    try testing.expectEqual(@as(usize, 0), tone.calls);
    try expectPort(&d, 0, 0, 256);
    try expectPort(&d, 1, 0, 256);
    try testing.expectEqual(@as(?Backend.Negotiated, null), s.pending_native);

    _ = try h.ctx.backend.dispatch();
    const pending = s.pending_native.?;
    try testing.expectEqual(@as(u32, 44100), pending.native.rate);
    try testing.expectEqual(Format.Sample.f32, pending.native.sample);
    try testing.expect(pending.native.channels.eql(stereo_f32.channels));
    try testing.expectEqual(@as(u32, 64), pending.period_frames);

    // Context swaps the pipeline and the stream goes on at the new rate.
    s.pending_native = null;
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 44100), s.nativeFormat().rate);
    try testing.expectEqual(Stream.State.running, s.state());
    try d.cycle(&wire.h, 6, 256, 44100);
    try testing.expect(tone.calls > 0);
}

test "dispatch swaps the pipeline when the graph rate changes" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback(), .latency_frames = 64 });
    var wire = try Wire.init(&h, s);
    defer wire.deinit();
    var d = try wire.driver(false);
    try s.start();
    try d.cycle(&wire.h, 4, 256, 96000);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 96000), s.nativeFormat().rate);
    try testing.expectEqual(@as(?Backend.Negotiated, null), s.pending_native);
    try testing.expectEqual(Stream.State.running, s.state());
}

test "a draining stream is drained after the latency has played" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{ .status = .drain };
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback(), .latency_frames = 512 });
    var wire = try Wire.init(&h, s);
    defer wire.deinit();
    var d = try wire.driver(false);
    try s.start();

    try d.cycle(&wire.h, 4, 256, 48000);
    try testing.expectEqual(Stream.State.draining, s.state());
    try d.cycle(&wire.h, 5, 256, 48000);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.draining, s.state());
    try d.cycle(&wire.h, 6, 256, 48000);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.stopped, s.state());
    try testing.expectEqual(@as(usize, 1), tone.calls);
    try testing.expect(!entryOf(s).?.active.load(.acquire));
}

test "the volume of an own stream goes to its controls" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback() });
    var wire = try Wire.init(&h, s);
    defer wire.deinit();
    _ = try wire.driver(false);
    const pw = entryOf(s).?.pw;
    try testing.expectEqual(@as(?u32, 50), pw.nodeId());
    try h.ctx.mixer().putStream(.{ .id = id(50), .direction = .playback, .app_name = "test", .name = "test", .volume = .init(&.{ 1, 1 }) });

    try h.ctx.mixer().setVolume(.{ .stream = id(50) }, .{ .channels = &.{ 0.25, 0.5 } });
    try testing.expectEqualSlices(f32, &.{ 0.25, 0.5 }, pw.controls.channel_volumes[0..2]);
    var update = try wire.nextNode(2);
    update.deinit(tgpa);

    try h.ctx.mixer().setMute(.{ .stream = id(50) }, true);
    try testing.expect(pw.controls.mute);
}

test "a stream that another client owns still goes to the session" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.f.param(h.f.bindOf(43), 2, 0, support.PropsSpec{ .volumes = &.{ 0.75, 0.75 }, .mute = false });
    try h.f.commit();
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback() });
    var wire = try Wire.init(&h, s);
    defer wire.deinit();
    _ = try wire.driver(false);
    const pw = entryOf(s).?.pw;
    try h.ctx.mixer().setVolume(.{ .stream = id(43) }, .{ .channels = &.{0.5} });
    try testing.expectEqual(@as(f32, 1), pw.controls.channel_volumes[0]);
    var m = try wire.next(h.f.bindOf(43).new_id, 3);
    defer m.deinit(tgpa);
    try expectParamBody(m.body, 2, struct {
        fn build(b: *pod.Builder) !void {
            try wireplumber.params.buildProps(b, .{ .channel_volumes = &.{ 0.5, 0.5 } });
        }
    }.build);
}

test "the endpoint, the role and the name reach the node" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{
        .direction = .playback,
        .format = stereo_f32,
        .callback = tone.callback(),
        .device = id(41),
        .role = .game,
        .latency_frames = 100,
    });
    try h.f.rig.remote.dispatch();
    var created = try h.f.rig.server.expect(0, 6);
    defer created.deinit(tgpa);
    for ([_][]const u8{ "target.object", "141", "media.role", "Game", "node.name", "test", "Stream/Output/Audio" }) |text| {
        try testing.expect(std.mem.indexOf(u8, created.body, text) != null);
    }
    try testing.expectEqual(@as(u32, 100), s.negotiated.period_frames);
    try testing.expect(s.nativeFormat().eql(.{ .sample = .f32, .rate = 48000, .channels = .stereo }));
}

test "the period is limited and the rate follows the graph" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{};
    const small = try h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback(), .latency_frames = 1 });
    try testing.expectEqual(@as(u32, 64), small.negotiated.period_frames);
    const big = try h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback(), .latency_frames = 100000 });
    try testing.expectEqual(@as(u32, 8192), big.negotiated.period_frames);
}

test "an unknown device is refused" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{};
    try testing.expectError(error.UnknownDevice, h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback(), .device = id(99) }));
    try testing.expectEqual(@as(usize, 0), h.ctx.backend.as(PipeWire).?.entries.items.len);
}

/// Reads server messages until a create_object request on the core.
fn nextCreate(h: *Harness) !FakeServer.OwnedMessage {
    try h.f.rig.remote.dispatch();
    for (0..16) |_| {
        var m = try h.f.rig.server.readMessage();
        if (m.id == 0 and m.opcode == 6) return m;
        m.deinit(tgpa);
    }
    return error.NotFound;
}

test "a playback stream needs a sink and a capture stream takes any endpoint" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{};
    try testing.expectError(error.UnknownDevice, h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback(), .device = id(42) }));
    const be = h.ctx.backend.as(PipeWire).?;
    try testing.expectEqual(@as(usize, 0), be.entries.items.len);

    const source = try h.ctx.openStream(.{ .direction = .capture, .format = stereo_f32, .callback = tone.callback(), .device = id(42) });
    var created = try nextCreate(&h);
    try testing.expect(std.mem.indexOf(u8, created.body, "stream.capture.sink") == null);
    created.deinit(tgpa);
    try testing.expect(!source.backend_target.monitor);

    const monitor = try h.ctx.openStream(.{ .direction = .capture, .format = stereo_f32, .callback = tone.callback(), .device = id(41) });
    try h.f.rig.remote.dispatch();
    created = try nextCreate(&h);
    defer created.deinit(tgpa);
    try testing.expect(std.mem.indexOf(u8, created.body, "stream.capture.sink") != null);
    try testing.expect(monitor.backend_target.monitor);
}

test "a reconnect reattaches a stream by the name of its device" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback(), .device = id(41) });
    try testing.expectEqualStrings("alsa_output.test", s.backend_target.name().?);
    _ = std.os.linux.shutdown(h.f.rig.server.server_fd, std.os.linux.SHUT.RDWR);
    try testing.expectEqual(Context.Event.disconnected, try h.ctx.dispatch());
    try testing.expect(!s.attached);

    try h.ctx.reconnect();
    try testing.expect(s.attached);
    const be = h.ctx.backend.as(PipeWire).?;
    h.f.rig.server.deinit();
    h.f.rig.server = h.spare;
    h.spare_used = true;
    h.f.rig.remote = be.remote.?;
    h.f.graph = be.graph.?;
    h.f.rig.registry = be.graph.?.registry;
    _ = try h.ctx.dispatch();
    try h.f.rig.skipHandshake();
    var m = try h.f.rig.server.expect(0, 5);
    m.deinit(tgpa);
    var created = try nextCreate(&h);
    defer created.deinit(tgpa);
    try testing.expect(std.mem.indexOf(u8, created.body, "target.object") != null);
    try testing.expect(std.mem.indexOf(u8, created.body, "alsa_output.test") != null);
    try testing.expect(std.mem.indexOf(u8, created.body, "stream.capture.sink") == null);
}

test "a device name that is too long is not kept" {
    var target: Stream.Target = .{};
    target.set("sink", true);
    try testing.expectEqualStrings("sink", target.name().?);
    try testing.expect(target.monitor);
    const long: [256]u8 = @splat('x');
    target.set(&long, false);
    try testing.expect(target.name() == null);
}

test "a removed node stops the stream and the connection goes on" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback() });
    var wire = try Wire.init(&h, s);
    defer wire.deinit();
    _ = try wire.driver(false);
    try s.start();
    try testing.expectEqual(Stream.State.running, s.state());

    var buf: [32]u8 = undefined;
    var b = pipewire.pod.Builder.init(&buf);
    const f = try b.beginStruct();
    try b.int(@bitCast(wire.h.node_id));
    b.end(f);
    try wire.h.rig.server.send(0, 4, b.bytesWritten(), &.{});
    try testing.expectEqual(Context.Event.none, try h.ctx.dispatch());
    try testing.expectEqual(Stream.State.stopped, s.state());
    try testing.expectError(error.Disconnected, s.start());
    try testing.expectEqual(@as(usize, 2), h.ctx.mixer().endpoints().len);
    s.close();
}

test "a lost connection destroys the entries and the streams stay" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback() });
    try s.start();
    _ = std.os.linux.shutdown(h.f.rig.server.server_fd, std.os.linux.SHUT.RDWR);
    try testing.expectEqual(Context.Event.disconnected, try h.ctx.dispatch());
    try testing.expectEqual(Stream.State.stopped, s.state());
    try testing.expectEqual(@as(usize, 0), h.ctx.backend.as(PipeWire).?.entries.items.len);
    try testing.expect(s.backend_data == null);
}

test "closing a stream frees its entry" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback() });
    const be = h.ctx.backend.as(PipeWire).?;
    try testing.expectEqual(@as(usize, 1), be.entries.items.len);
    s.close();
    try testing.expectEqual(@as(usize, 0), be.entries.items.len);
}

test "the system bus address gives the socket path" {
    const a = (try busPathOf(tgpa, "unix:path=/run/dbus/system_bus_socket,guid=abc")).?;
    defer tgpa.free(a);
    try testing.expectEqualStrings("/run/dbus/system_bus_socket", a);
    const b = (try busPathOf(tgpa, "unix:abstract=/tmp/bus;unix:path=/x")).?;
    defer tgpa.free(b);
    try testing.expectEqualStrings("@/tmp/bus", b);
    try testing.expect((try busPathOf(tgpa, "tcp:host=x")) == null);
    try testing.expect((try busPathOf(tgpa, "unix:path=")) == null);
}

fn waitSettled(be: *PipeWire) void {
    var waited: u32 = 0;
    while (be.rt_state.load(.acquire) == .pending and waited < 5000) : (waited += 1) {
        var ts: linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = linux.nanosleep(&ts, null);
    }
}

/// The allocations that the app allocator served up to the end of the promotion.
fn allocationsOf(env: *const std.process.Environ.Map, realtime: bool) !usize {
    var server = try FakeServer.init(tgpa);
    defer server.deinit();
    var counting = testing.FailingAllocator.init(tgpa, .{});
    const fds = [_]i32{server.client_fd};
    const ctx = try Context.init(counting.allocator(), testing.io, .{
        .app_name = "test",
        .backend = .pipewire,
        .environ = env,
        .pipewire_backend = .{ .connected_fds = &fds, .realtime = realtime },
    });
    defer ctx.deinit();
    waitSettled(ctx.backend.as(PipeWire).?);
    return counting.alloc_index;
}

fn promotionCase() !void {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    var server = try FakeServer.init(tgpa);
    defer server.deinit();
    var env: std.process.Environ.Map = .init(tgpa);
    defer env.deinit();
    try env.put("DBUS_SYSTEM_BUS_ADDRESS", "unix:path=/nonexistent/chorus-bus");
    // The bus path and the promotion buffer are the only extra allocations of the app allocator.
    const without = try allocationsOf(&env, false);
    try testing.expectEqual(without + 2, try allocationsOf(&env, true));

    const fds = [_]i32{server.client_fd};
    const ctx = try Context.init(tgpa, testing.io, .{
        .app_name = "test",
        .backend = .pipewire,
        .environ = &env,
        .pipewire_backend = .{ .connected_fds = &fds, .realtime = true },
    });
    defer ctx.deinit();
    const be = ctx.backend.as(PipeWire).?;
    try testing.expectEqualStrings("/nonexistent/chorus-bus", be.bus_path.?);
    try testing.expectEqual(@as(usize, 64 * 1024), be.promote_buf.?.len);
    waitSettled(be);
    // A machine that allows the direct path promotes the thread of the forked child only.
    if (be.rt_state.load(.acquire) == .yes) {
        try testing.expectEqual(Context.Realtime.yes, ctx.info().realtime);
        return;
    }
    try testing.expectEqual(RtState.no, be.rt_state.load(.acquire));
    try testing.expectEqual(Context.Realtime.no, ctx.info().realtime);
}

test "realtime promotion runs on its own thread and reports failure" {
    try inChild(promotionCase);
}

test "a graph rate that is not valid stops the stream and is not asked again" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback(), .latency_frames = 64 });
    var wire = try Wire.init(&h, s);
    defer wire.deinit();
    var d = try wire.driver(false);
    try s.start();
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    try d.cycle(&wire.h, 4, 256, 500);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.stopped, s.state());
    var expected_buf: [32]u8 = undefined;
    var eb = pipewire.pod.Builder.init(&expected_buf);
    const es = try eb.beginStruct();
    try eb.boolean(false);
    eb.end(es);
    var seen_stop = false;
    for (0..4) |_| {
        var m = wire.nextNode(4) catch break;
        defer m.deinit(tgpa);
        if (std.mem.eql(u8, m.body, eb.bytesWritten())) seen_stop = true;
    }
    try testing.expect(seen_stop);
    try testing.expectEqual(@as(u32, 48000), s.nativeFormat().rate);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(?Backend.Negotiated, null), s.pending_native);
    try testing.expectEqual(Stream.State.stopped, s.state());
}

fn ready(fd: i32) bool {
    var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    return linux.poll(&pfd, 1, 0) == 1;
}

const Eventfd = struct {
    fd: i32,

    fn drain(ctx: *anyopaque) void {
        const self: *Eventfd = @ptrCast(@alignCast(ctx));
        var value: u64 = 0;
        _ = linux.read(self.fd, std.mem.asBytes(&value), 8);
    }
};

test "without a loop thread fd wakes for the data loop and for the remote" {
    if (!builtin.single_threaded) return error.SkipZigTest;
    var server = try FakeServer.init(tgpa);
    defer server.deinit();
    const fds = [_]i32{server.client_fd};
    const ctx = try Context.init(tgpa, testing.io, .{
        .app_name = "test",
        .backend = .pipewire,
        .pipewire_backend = .{ .connected_fds = &fds, .realtime = false },
    });
    defer ctx.deinit();
    const be = ctx.backend.as(PipeWire).?;
    const wait = ctx.fd().?;
    try testing.expect(wait != be.remote.?.fd());
    _ = try ctx.dispatch();
    try testing.expect(!ready(wait));

    const rc = linux.eventfd(0, linux.EFD.CLOEXEC);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    var source: Eventfd = .{ .fd = @intCast(rc) };
    defer _ = linux.close(source.fd);
    try be.loop.addSource(source.fd, &source, Eventfd.drain);
    defer be.loop.removeSource(source.fd);
    const one: u64 = 1;
    _ = linux.write(source.fd, std.mem.asBytes(&one), 8);
    try testing.expect(ready(wait));
    _ = try ctx.dispatch();
    try testing.expect(!ready(wait));

    var buf: [64]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const s = try b.beginStruct();
    try b.int(0);
    try b.int(0);
    b.end(s);
    try server.send(0, 1, b.bytesWritten(), &.{});
    var waited: u32 = 0;
    while (!ready(wait) and waited < 200) : (waited += 1) {
        var ts: linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = linux.nanosleep(&ts, null);
    }
    try testing.expect(ready(wait));
    _ = try ctx.dispatch();
    try testing.expect(!ready(wait));
}

fn expectFd(ctx: *Context) !void {
    const be = ctx.backend.as(PipeWire).?;
    try testing.expect(be.wait_fd >= 0);
    try testing.expect(be.wake_fd >= 0);
    try testing.expectEqual(@as(?i32, be.wait_fd), ctx.fd());
    try testing.expect(be.wait_fd != be.remote.?.fd());
}

fn waitReadable(fd: i32, ms: i32) bool {
    var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    return linux.poll(&pfd, 1, ms) == 1;
}

/// Dispatches until the wait descriptor is quiet.
fn settleFd(ctx: *Context) !void {
    for (0..8) |_| {
        _ = try ctx.dispatch();
        if (!ready(ctx.fd().?)) return;
    }
    return error.NotQuiet;
}

test "a drain on the loop thread wakes fd and one dispatch stops the stream" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{ .status = .drain };
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback(), .latency_frames = 512 });
    var wire = try Wire.init(&h, s);
    defer wire.deinit();
    var d = try wire.driver(false);
    try s.start();
    try settleFd(h.ctx);
    const wait = h.ctx.fd().?;

    // The first cycle reports the graph rate. The rate is the negotiated one, so nothing changes.
    try d.cycle(&wire.h, 4, 256, 48000);
    try settleFd(h.ctx);
    try d.cycle(&wire.h, 5, 256, 48000);
    try testing.expect(!waitReadable(wait, 50));
    try d.cycle(&wire.h, 6, 256, 48000);
    try testing.expect(waitReadable(wait, 1000));
    try testing.expectEqual(Stream.State.draining, s.state());
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.stopped, s.state());
    try testing.expect(!ready(wait));
}

test "a rate change on the loop thread wakes fd and one dispatch moves the format" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo_f32, .callback = tone.callback(), .latency_frames = 64 });
    var wire = try Wire.init(&h, s);
    defer wire.deinit();
    var d = try wire.driver(false);
    try s.start();
    try settleFd(h.ctx);
    const wait = h.ctx.fd().?;

    try d.cycle(&wire.h, 4, 256, 96000);
    try testing.expect(waitReadable(wait, 1000));
    try testing.expectEqual(@as(u32, 48000), s.nativeFormat().rate);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 96000), s.nativeFormat().rate);
    try testing.expect(!ready(wait));
    try d.cycle(&wire.h, 5, 256, 96000);
    try testing.expect(!waitReadable(wait, 50));
}

fn sawNodeStop(wire: *Wire) !bool {
    var expected_buf: [32]u8 = undefined;
    var eb = pipewire.pod.Builder.init(&expected_buf);
    const es = try eb.beginStruct();
    try eb.boolean(false);
    eb.end(es);
    var seen = false;
    for (0..4) |_| {
        var m = wire.nextNode(4) catch break;
        defer m.deinit(tgpa);
        if (std.mem.eql(u8, m.body, eb.bytesWritten())) seen = true;
    }
    return seen;
}

const StopRun = struct {
    h: Harness,
    tone: Tone,
    wire: Wire,
    d: pwh.Driver,
    s: *Stream,
    wait: i32,

    /// Starts a stream, runs one cycle and then lets the callback return `.stop`.
    fn begin(self: *StopRun, direction: Stream.Direction) !void {
        try self.h.init();
        errdefer self.h.deinit();
        self.tone = .{};
        self.s = try self.h.ctx.openStream(.{ .direction = direction, .format = stereo_f32, .callback = self.tone.callback(), .latency_frames = 64 });
        self.wire = try Wire.init(&self.h, self.s);
        errdefer self.wire.deinit();
        self.d = try self.wire.driver(direction == .capture);
        try self.s.start();
        try settleFd(self.h.ctx);
        self.wait = self.h.ctx.fd().?;
        // The first cycle reports the graph rate and wakes fd for that reason.
        try self.d.cycle(&self.wire.h, 4, 256, 48000);
        try settleFd(self.h.ctx);
        try testing.expectEqual(Stream.State.running, self.s.state());
        self.tone.status = .stop;
    }

    fn end(self: *StopRun) void {
        self.wire.deinit();
        self.h.deinit();
    }
};

fn wakeCount(be: *PipeWire) u64 {
    var count: u64 = 0;
    _ = linux.read(be.wake_fd, std.mem.asBytes(&count), 8);
    return count;
}

fn stopCase(direction: Stream.Direction) !void {
    if (builtin.single_threaded) return error.SkipZigTest;
    var r: StopRun = undefined;
    try r.begin(direction);
    defer r.end();
    const be = r.h.ctx.backend.as(PipeWire).?;
    const before = r.tone.calls;
    try r.d.cycle(&r.wire.h, 5, 256, 48000);
    try testing.expect(waitReadable(r.wait, 1000));
    try r.d.cycle(&r.wire.h, 6, 256, 48000);
    try testing.expectEqual(Stream.State.stopped, r.s.state());
    try testing.expectEqual(@as(u64, 1), wakeCount(be));
    _ = try r.h.ctx.dispatch();
    try testing.expect(!ready(r.wait));
    try testing.expect(try sawNodeStop(&r.wire));
    try testing.expect(!entryOf(r.s).?.active.load(.acquire));
    try testing.expectEqual(before + 1, r.tone.calls);
    try r.d.cycle(&r.wire.h, 7, 256, 48000);
    try testing.expectEqual(before + 1, r.tone.calls);
    try testing.expect(!waitReadable(r.wait, 50));
}

test "a playback callback that returns stop wakes fd once and one dispatch stops the node" {
    try stopCase(.playback);
}

test "a capture callback that returns stop wakes fd once and one dispatch stops the node" {
    try stopCase(.capture);
}

test "a start between the wake of a callback stop and the dispatch keeps the node running" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var r: StopRun = undefined;
    try r.begin(.playback);
    defer r.end();
    const before = r.tone.calls;
    try r.d.cycle(&r.wire.h, 5, 256, 48000);
    try testing.expect(waitReadable(r.wait, 1000));
    try testing.expectEqual(Stream.State.stopped, r.s.state());
    r.tone.status = .@"continue";
    try r.s.start();
    _ = try r.h.ctx.dispatch();
    try testing.expect(!try sawNodeStop(&r.wire));
    try testing.expect(entryOf(r.s).?.active.load(.acquire));
    try testing.expectEqual(Stream.State.running, r.s.state());
    try r.d.cycle(&r.wire.h, 6, 256, 48000);
    try testing.expect(r.tone.calls > before + 1);
}
