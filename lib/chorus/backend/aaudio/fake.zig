//! A fake libaaudio for tests. The functions of the table carry no context, so the builder calls
//! find the active Fake through a thread local pointer. Every other call finds it through its handle.
const std = @import("std");
const builtin = @import("builtin");
const aaudio = @import("api.zig");

threadlocal var active: ?*Fake = null;

/// What a test sees of one builder, and of the stream it opened.
pub const Config = struct {
    direction: i32 = aaudio.Direction.output,
    format: i32 = aaudio.Format.unspecified,
    rate: i32 = aaudio.unspecified,
    channels: i32 = aaudio.unspecified,
    mask: u32 = 0,
    device: i32 = aaudio.unspecified,
    usage: i32 = 0,
    content: i32 = 0,
    preset: i32 = 0,
    performance: i32 = 0,
    sharing: i32 = -1,
    data: ?aaudio.DataCallback = null,
    data_user: ?*anyopaque = null,
    err: ?aaudio.ErrorCallback = null,
    err_user: ?*anyopaque = null,
};

pub const Counts = struct {
    builders: u32 = 0,
    deleted: u32 = 0,
    opens: u32 = 0,
    starts: u32 = 0,
    stops: u32 = 0,
    waits: u32 = 0,
    closes: u32 = 0,
    buffer_sets: u32 = 0,
    /// The waits with a zero timeout.
    polls: u32 = 0,
};

pub const Call = enum { open, close };

const Builder = struct { fake: *Fake, config: Config = .{} };

pub const FakeStream = struct {
    fake: *Fake,
    config: Config,
    /// What the stream reports about itself.
    rate: i32,
    channels: i32,
    format: i32,
    /// The state of the service. The client state follows it only through `waitForStateChange` and
    /// the data callback, as in the real library.
    state: std.atomic.Value(i32) = .init(aaudio.State.open),
    client: std.atomic.Value(i32) = .init(aaudio.State.open),
    xruns: std.atomic.Value(i32) = .init(0),
    buffer_size: i32 = 0,
    callback_active: std.atomic.Value(u32) = .init(0),
    callback_thread: std.atomic.Value(u32) = .init(0),

    pub fn handle(self: *FakeStream) *aaudio.AStream {
        return @ptrCast(self);
    }

    fn frameBytes(self: *const FakeStream) usize {
        const sample: usize = if (self.format == aaudio.Format.pcm_i16) 2 else 4;
        return sample * @as(usize, @intCast(self.channels));
    }

    /// Runs the data callback once with all of `buf`. Gives null when the stream is not started.
    pub fn callOnce(self: *FakeStream, buf: []u8) ?i32 {
        if (self.state.load(.acquire) != aaudio.State.started) return null;
        const callback = self.config.data.?;
        const frames: i32 = @intCast(buf.len / self.frameBytes());
        self.callback_thread.store(threadId(), .seq_cst);
        self.callback_active.store(1, .seq_cst);
        defer self.callback_active.store(0, .seq_cst);
        self.client.store(self.state.load(.acquire), .release);
        return callback(self.handle(), self.config.data_user, buf.ptr, frames);
    }

    /// Runs the data callback whatever the state is.
    pub fn callForced(self: *FakeStream, buf: []u8) i32 {
        const callback = self.config.data.?;
        const frames: i32 = @intCast(buf.len / self.frameBytes());
        return callback(self.handle(), self.config.data_user, buf.ptr, frames);
    }

    /// Disconnects the stream and runs the error callback on the calling thread.
    pub fn fireError(self: *FakeStream, code: aaudio.Result) void {
        self.state.store(aaudio.State.disconnected, .release);
        self.client.store(aaudio.State.disconnected, .release);
        const callback = self.config.err orelse return;
        callback(self.handle(), self.config.err_user, code);
    }

    /// Ends a stop that `hold_stopping` keeps open.
    pub fn completeStop(self: *FakeStream) void {
        _ = self.state.cmpxchgStrong(aaudio.State.stopping, aaudio.State.stopped, .acq_rel, .acquire);
    }
};

/// Runs data callbacks on a thread, or inline in a single threaded build.
pub const Pump = struct {
    thread: ?std.Thread = null,

    pub fn start(self: *Pump, stream: *FakeStream, buf: []u8, calls: u32) std.Thread.SpawnError!void {
        if (builtin.single_threaded) {
            run(stream, buf, calls);
            return;
        }
        self.thread = try std.Thread.spawn(.{}, run, .{ stream, buf, calls });
    }

    pub fn join(self: *Pump) void {
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    fn run(stream: *FakeStream, buf: []u8, calls: u32) void {
        for (0..calls) |_| _ = stream.callOnce(buf);
    }
};

pub const Fake = struct {
    gpa: std.mem.Allocator,
    /// Tests can clear the optional fields before they give the table to the backend.
    table: aaudio.Api,
    rate: i32 = 48000,
    burst: i32 = 192,
    capacity: i32 = 1536,
    /// Channel count that streams report instead of the requested one.
    channels: ?i32 = null,
    i16_only: bool = false,
    /// Sample format that streams report instead of the one they got.
    format: ?i32 = null,
    /// Result of the next `open_failures` opens.
    open_result: aaudio.Result = aaudio.ResultCode.ok,
    open_failures: u32 = 0,
    /// Makes `requestStop` of a playback stream stop in STOPPING until `completeStop`.
    hold_stopping: bool = false,
    /// Result of `requestStop` when it is not OK.
    stop_result: aaudio.Result = aaudio.ResultCode.ok,
    /// Makes `requestStop` disconnect the stream with no error callback, as a route change does.
    disconnect_on_stop: bool = false,
    /// Runs the error callback of a new stream with this code before `openStream` returns.
    fire_on_open: ?aaudio.Result = null,
    /// The opens and closes in the order they happened.
    log: [16]Call = undefined,
    log_len: usize = 0,
    streams: std.ArrayList(*FakeStream) = .empty,
    counts: Counts = .{},
    /// The configuration of the last builder that reached `openStream`.
    last: Config = .{},
    /// Formats that the opens asked for, in order.
    tried: [8]i32 = @splat(0),
    /// Control calls that ran while the callback ran on the same thread.
    violations: u32 = 0,

    pub fn init(self: *Fake, gpa: std.mem.Allocator) void {
        self.* = .{ .gpa = gpa, .table = fake_table };
        active = self;
    }

    pub fn deinit(self: *Fake) void {
        std.debug.assert(self.streams.items.len == 0);
        std.debug.assert(self.counts.builders == self.counts.deleted);
        std.debug.assert(self.violations == 0);
        self.streams.deinit(self.gpa);
        active = null;
    }

    fn note(self: *Fake, call: Call) void {
        if (self.log_len < self.log.len) self.log[self.log_len] = call;
        self.log_len += 1;
    }

    /// The opens and closes so far.
    pub fn calls(self: *const Fake) []const Call {
        return self.log[0..@min(self.log_len, self.log.len)];
    }

    pub fn failOpens(self: *Fake, result: aaudio.Result, count: u32) void {
        self.open_result = result;
        self.open_failures = count;
    }

    /// The streams that are open now.
    pub fn live(self: *const Fake) []const *FakeStream {
        return self.streams.items;
    }
};

fn threadId() u32 {
    return @intCast(std.Thread.getCurrentId());
}

fn guard(stream: *FakeStream) void {
    if (stream.callback_active.load(.seq_cst) == 1 and stream.callback_thread.load(.seq_cst) == threadId()) {
        stream.fake.violations += 1;
    }
}

fn streamOf(handle: *aaudio.AStream) *FakeStream {
    return @ptrCast(@alignCast(handle));
}

fn builderOf(handle: *aaudio.StreamBuilder) *Builder {
    return @ptrCast(@alignCast(handle));
}

fn createStreamBuilder(out: *?*aaudio.StreamBuilder) callconv(.c) aaudio.Result {
    const fake = active.?;
    const builder = fake.gpa.create(Builder) catch return aaudio.ResultCode.no_memory;
    builder.* = .{ .fake = fake };
    fake.counts.builders += 1;
    out.* = @ptrCast(builder);
    return aaudio.ResultCode.ok;
}

fn deleteBuilder(handle: *aaudio.StreamBuilder) callconv(.c) aaudio.Result {
    const builder = builderOf(handle);
    builder.fake.counts.deleted += 1;
    builder.fake.gpa.destroy(builder);
    return aaudio.ResultCode.ok;
}

fn setDeviceId(handle: *aaudio.StreamBuilder, value: i32) callconv(.c) void {
    builderOf(handle).config.device = value;
}

fn setDirection(handle: *aaudio.StreamBuilder, value: i32) callconv(.c) void {
    builderOf(handle).config.direction = value;
}

fn setSampleRate(handle: *aaudio.StreamBuilder, value: i32) callconv(.c) void {
    builderOf(handle).config.rate = value;
}

fn setChannelCount(handle: *aaudio.StreamBuilder, value: i32) callconv(.c) void {
    builderOf(handle).config.channels = value;
}

fn setFormat(handle: *aaudio.StreamBuilder, value: i32) callconv(.c) void {
    builderOf(handle).config.format = value;
}

fn setSharingMode(handle: *aaudio.StreamBuilder, value: i32) callconv(.c) void {
    builderOf(handle).config.sharing = value;
}

fn setPerformanceMode(handle: *aaudio.StreamBuilder, value: i32) callconv(.c) void {
    builderOf(handle).config.performance = value;
}

fn setDataCallback(handle: *aaudio.StreamBuilder, callback: ?aaudio.DataCallback, user: ?*anyopaque) callconv(.c) void {
    const builder = builderOf(handle);
    builder.config.data = callback;
    builder.config.data_user = user;
}

fn setErrorCallback(handle: *aaudio.StreamBuilder, callback: ?aaudio.ErrorCallback, user: ?*anyopaque) callconv(.c) void {
    const builder = builderOf(handle);
    builder.config.err = callback;
    builder.config.err_user = user;
}

fn setUsage(handle: *aaudio.StreamBuilder, value: i32) callconv(.c) void {
    builderOf(handle).config.usage = value;
}

fn setContentType(handle: *aaudio.StreamBuilder, value: i32) callconv(.c) void {
    builderOf(handle).config.content = value;
}

fn setInputPreset(handle: *aaudio.StreamBuilder, value: i32) callconv(.c) void {
    builderOf(handle).config.preset = value;
}

fn setChannelMask(handle: *aaudio.StreamBuilder, value: u32) callconv(.c) void {
    builderOf(handle).config.mask = value;
}

fn openStream(handle: *aaudio.StreamBuilder, out: *?*aaudio.AStream) callconv(.c) aaudio.Result {
    const builder = builderOf(handle);
    const fake = builder.fake;
    const config = builder.config;
    if (fake.counts.opens < fake.tried.len) fake.tried[fake.counts.opens] = config.format;
    fake.counts.opens += 1;
    fake.note(.open);
    fake.last = config;
    if (fake.open_failures > 0) {
        fake.open_failures -= 1;
        return fake.open_result;
    }
    if (fake.i16_only and config.format == aaudio.Format.pcm_float) return aaudio.ResultCode.invalid_format;
    const stream = fake.gpa.create(FakeStream) catch return aaudio.ResultCode.no_memory;
    stream.* = .{
        .fake = fake,
        .config = config,
        .rate = fake.rate,
        .channels = fake.channels orelse config.channels,
        .format = fake.format orelse if (fake.i16_only) aaudio.Format.pcm_i16 else config.format,
    };
    fake.streams.append(fake.gpa, stream) catch {
        fake.gpa.destroy(stream);
        return aaudio.ResultCode.no_memory;
    };
    out.* = stream.handle();
    if (fake.fire_on_open) |code| stream.fireError(code);
    return aaudio.ResultCode.ok;
}

fn requestStart(handle: *aaudio.AStream) callconv(.c) aaudio.Result {
    const stream = streamOf(handle);
    guard(stream);
    stream.fake.counts.starts += 1;
    if (stream.state.load(.acquire) == aaudio.State.disconnected) return aaudio.ResultCode.disconnected;
    stream.state.store(aaudio.State.started, .release);
    stream.client.store(aaudio.State.starting, .release);
    return aaudio.ResultCode.ok;
}

fn requestStop(handle: *aaudio.AStream) callconv(.c) aaudio.Result {
    const stream = streamOf(handle);
    guard(stream);
    stream.fake.counts.stops += 1;
    if (stream.fake.stop_result != aaudio.ResultCode.ok) return stream.fake.stop_result;
    if (stream.fake.disconnect_on_stop) {
        stream.state.store(aaudio.State.disconnected, .release);
        stream.client.store(aaudio.State.disconnected, .release);
        return aaudio.ResultCode.disconnected;
    }
    if (stream.state.load(.acquire) == aaudio.State.disconnected) return aaudio.ResultCode.disconnected;
    const hold = stream.fake.hold_stopping and stream.config.direction == aaudio.Direction.output;
    stream.state.store(if (hold) aaudio.State.stopping else aaudio.State.stopped, .release);
    stream.client.store(aaudio.State.stopping, .release);
    return aaudio.ResultCode.ok;
}

fn close(handle: *aaudio.AStream) callconv(.c) aaudio.Result {
    const stream = streamOf(handle);
    guard(stream);
    const fake = stream.fake;
    fake.counts.closes += 1;
    fake.note(.close);
    const i = std.mem.indexOfScalar(*FakeStream, fake.streams.items, stream).?;
    _ = fake.streams.orderedRemove(i);
    fake.gpa.destroy(stream);
    return aaudio.ResultCode.ok;
}

fn getState(handle: *aaudio.AStream) callconv(.c) i32 {
    return streamOf(handle).client.load(.acquire);
}

fn waitForStateChange(handle: *aaudio.AStream, from: i32, next: ?*i32, timeout_ns: i64) callconv(.c) aaudio.Result {
    const stream = streamOf(handle);
    guard(stream);
    stream.fake.counts.waits += 1;
    if (timeout_ns == 0) stream.fake.counts.polls += 1;
    const now = stream.state.load(.acquire);
    stream.client.store(now, .release);
    if (now == from) return aaudio.ResultCode.timeout;
    if (next) |n| n.* = now;
    return aaudio.ResultCode.ok;
}

fn getSampleRate(handle: *aaudio.AStream) callconv(.c) i32 {
    return streamOf(handle).rate;
}

fn getChannelCount(handle: *aaudio.AStream) callconv(.c) i32 {
    return streamOf(handle).channels;
}

fn getFormat(handle: *aaudio.AStream) callconv(.c) i32 {
    return streamOf(handle).format;
}

fn getFramesPerBurst(handle: *aaudio.AStream) callconv(.c) i32 {
    return streamOf(handle).fake.burst;
}

fn getBufferCapacityInFrames(handle: *aaudio.AStream) callconv(.c) i32 {
    return streamOf(handle).fake.capacity;
}

fn setBufferSizeInFrames(handle: *aaudio.AStream, frames: i32) callconv(.c) aaudio.Result {
    const stream = streamOf(handle);
    stream.fake.counts.buffer_sets += 1;
    stream.buffer_size = frames;
    return frames;
}

fn getXRunCount(handle: *aaudio.AStream) callconv(.c) i32 {
    return streamOf(handle).xruns.load(.monotonic);
}

const fake_table: aaudio.Api = .{
    .createStreamBuilder = createStreamBuilder,
    .deleteBuilder = deleteBuilder,
    .setDeviceId = setDeviceId,
    .setDirection = setDirection,
    .setSampleRate = setSampleRate,
    .setChannelCount = setChannelCount,
    .setFormat = setFormat,
    .setSharingMode = setSharingMode,
    .setPerformanceMode = setPerformanceMode,
    .setDataCallback = setDataCallback,
    .setErrorCallback = setErrorCallback,
    .openStream = openStream,
    .requestStart = requestStart,
    .requestStop = requestStop,
    .close = close,
    .getState = getState,
    .waitForStateChange = waitForStateChange,
    .getSampleRate = getSampleRate,
    .getChannelCount = getChannelCount,
    .getFormat = getFormat,
    .getFramesPerBurst = getFramesPerBurst,
    .getBufferCapacityInFrames = getBufferCapacityInFrames,
    .setBufferSizeInFrames = setBufferSizeInFrames,
    .getXRunCount = getXRunCount,
    .setUsage = setUsage,
    .setContentType = setContentType,
    .setInputPreset = setInputPreset,
    .setChannelMask = setChannelMask,
};
