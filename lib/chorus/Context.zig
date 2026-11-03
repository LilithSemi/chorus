//! The connection of an application to an audio system.
const std = @import("std");
const builtin = @import("builtin");
const Format = @import("Format.zig");
const Mixer = @import("Mixer.zig");
const Pipeline = @import("Pipeline.zig");
const Stream = @import("Stream.zig");
const Backend = @import("backend/Backend.zig");
const Null = @import("backend/Null.zig");
const AAudio = @import("backend/AAudio.zig");
const CoreAudio = @import("backend/CoreAudio.zig");
const Web = @import("backend/Web.zig");
const PipeWire = if (Backend.pipewire_enabled) @import("backend/PipeWire.zig") else struct {
    pub const Options = struct {};
};
const Context = @This();

const log = std.log.scoped(.chorus);

gpa: std.mem.Allocator,
io: std.Io,
backend: Backend,
app_name: []u8,
mixer_state: Mixer,
stream_list: std.ArrayList(*Stream),
disconnected: bool = false,
pump_list: std.ArrayList(Pump) = .empty,

pub const BackendChoice = enum { auto, pipewire, coreaudio, aaudio, web, null };

pub const Options = struct {
    app_name: []const u8,
    /// The process environment, for the variables that a backend reads, such as PIPEWIRE_REMOTE.
    /// When null, a backend uses its defaults. It must stay valid for the life of the Context,
    /// because `reconnect` reads it again.
    environ: ?*const std.process.Environ.Map = null,
    backend: BackendChoice = .auto,
    null_backend: Null.Options = .{},
    pipewire_backend: PipeWire.Options = .{},
    aaudio_backend: AAudio.Options = .{},
    coreaudio_backend: CoreAudio.Options = .{},
    web_backend: Web.Options = .{},
};

pub const Event = Backend.Event;
pub const Realtime = Backend.Realtime;
pub const Info = struct { backend: Backend.Kind, realtime: Realtime };
pub const InitError = error{ OutOfMemory, BackendUnavailable, Canceled };
pub const ReconnectError = error{ OutOfMemory, BackendUnavailable, UnsupportedFormat, UnknownDevice, Disconnected, PermissionDenied, Canceled };

pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) InitError!*Context {
    const self = try gpa.create(Context);
    errdefer gpa.destroy(self);
    const app_name = try gpa.dupe(u8, options.app_name);
    errdefer gpa.free(app_name);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .backend = undefined,
        .app_name = app_name,
        .mixer_state = .init(gpa),
        .stream_list = .empty,
    };
    errdefer self.mixer_state.deinit();
    const ictx: Backend.InitContext = .{ .gpa = gpa, .io = io, .mixer = &self.mixer_state, .app_name = app_name, .environ = options.environ };
    self.backend = switch (options.backend) {
        .auto => try connectAuto(ictx, options),
        .pipewire => try connect(ictx, options, .pipewire),
        .coreaudio => try connect(ictx, options, .coreaudio),
        .aaudio => try connect(ictx, options, .aaudio),
        .web => try connect(ictx, options, .web),
        .null => try connect(ictx, options, .null),
    };
    self.mixer_state.backend = self.backend;
    return self;
}

fn connectAuto(ictx: Backend.InitContext, options: Options) InitError!Backend {
    for (Backend.order) |k| {
        if (!Backend.compiled(k)) continue;
        var tried = options;
        // A fallback to Null has no listener for the output, so it drops the bytes.
        tried.null_backend.keep_output = false;
        return connect(ictx, if (k == .null) tried else options, k) catch |err| switch (err) {
            error.BackendUnavailable => continue,
            error.OutOfMemory, error.Canceled => return err,
        };
    }
    return error.BackendUnavailable;
}

fn connect(ictx: Backend.InitContext, options: Options, k: Backend.Kind) InitError!Backend {
    return switch (k) {
        .null => Null.create(ictx, options.null_backend),
        .pipewire => if (Backend.pipewire_enabled) PipeWire.create(ictx, options.pipewire_backend) else error.BackendUnavailable,
        .aaudio => if (Backend.aaudio_enabled) AAudio.create(ictx, options.aaudio_backend) else error.BackendUnavailable,
        .web => if (Backend.web_enabled or options.web_backend.api != null) Web.create(ictx, options.web_backend) else error.BackendUnavailable,
        .coreaudio => if (Backend.coreaudio_enabled or options.coreaudio_backend.api != null) CoreAudio.create(ictx, options.coreaudio_backend) else error.BackendUnavailable,
    };
}

pub fn deinit(self: *Context) void {
    std.debug.assert(self.pump_list.items.len == 0);
    self.mixer_state.unlistenAll();
    while (self.stream_list.items.len > 0) self.closeStream(self.stream_list.items[self.stream_list.items.len - 1]);
    self.stream_list.deinit(self.gpa);
    self.pump_list.deinit(self.gpa);
    self.backend.deinit();
    self.mixer_state.deinit();
    self.gpa.free(self.app_name);
    self.gpa.destroy(self);
}

/// A function that `dispatch` calls on the app thread. It is for Player and Recorder.
pub const Pump = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque) void,
    /// Milliseconds until the pump has work again, or null when it has none. See `timeoutMs`.
    timeout: ?*const fn (ctx: ?*anyopaque) ?u32 = null,
};

/// Registers a pump. `dispatch` runs every pump in order, before the backend work and so before
/// the render pass of a backend that renders in `dispatch`. It runs also when no backend event is
/// pending. The render path cannot wake the app, so a pump does not make `fd` readable. An app that
/// waits on `fd` also waits for `timeoutMs`. This is for Player and Recorder. App thread only.
pub fn addPump(self: *Context, pump: Pump) error{OutOfMemory}!void {
    try self.pump_list.append(self.gpa, pump);
}

/// Removes the pump that was added with the same `ctx` and `func`. A pump can remove itself.
pub fn removePump(self: *Context, pump: Pump) void {
    for (self.pump_list.items, 0..) |item, i| {
        if (item.ctx == pump.ctx and item.func == pump.func) {
            _ = self.pump_list.orderedRemove(i);
            return;
        }
    }
}

/// The longest time in milliseconds that an app can wait before it calls `dispatch`, or null when
/// neither a pump nor the backend needs a call. An app that polls `fd` passes this as the poll
/// timeout and calls `dispatch` when `fd` is readable or the timeout ends. 0 means call it now.
/// Read it again just before each wait, because calls such as `Player.stream` and
/// `Player.setPaused` change it. App thread only.
pub fn timeoutMs(self: *const Context) ?u32 {
    var best: ?u32 = self.backend.timeoutMs();
    for (self.pump_list.items) |pump| {
        const ms = (pump.timeout orelse continue)(pump.ctx) orelse continue;
        best = if (best) |b| @min(b, ms) else ms;
    }
    return best;
}

fn runPumps(self: *Context) void {
    var i: usize = 0;
    while (i < self.pump_list.items.len) {
        const pump = self.pump_list.items[i];
        pump.func(pump.ctx);
        if (i < self.pump_list.items.len and self.pump_list.items[i].func == pump.func and self.pump_list.items[i].ctx == pump.ctx) i += 1;
    }
}

pub fn dispatch(self: *Context) Backend.DispatchError!Event {
    for (self.stream_list.items) |stream| stream.foldStats();
    self.runPumps();
    const event = try self.backend.dispatch();
    if (event == .disconnected) {
        self.disconnected = true;
        for (self.stream_list.items) |stream| {
            const was_active = stream.markDisconnected();
            stream.resume_on_reconnect = stream.resume_on_reconnect or was_active;
            stream.attached = false;
        }
    }
    var first: ?error{OutOfMemory} = null;
    if (event != .disconnected) {
        for (self.stream_list.items) |stream| {
            self.renegotiate(stream) catch |err| {
                first = first orelse err;
            };
        }
    }
    self.notifyStates();
    if (first) |err| return err;
    return event;
}

/// Applies `pending_native` of the stream. The backend stops the stream first, so the audio
/// thread is out of the old pipeline when it is replaced. The backend sees `pending_native`
/// during the stop and the start, and keeps the audio system out of the swap.
fn renegotiate(self: *Context, stream: *Stream) error{OutOfMemory}!void {
    const next = stream.pending_native orelse return;
    if (!stream.attached) {
        stream.pending_native = null;
        return;
    }
    checkNegotiated(next) catch {
        stream.pending_native = null;
        if (comptime !builtin.cpu.arch.isWasm()) log.warn("the backend asked for a native format that is not valid, rate {d}", .{next.native.rate});
        _ = stream.markDisconnected();
        self.backend.stopStream(stream);
        return;
    };
    defer stream.pending_native = null;
    const started = switch (stream.state()) {
        .running, .draining => true,
        .idle, .stopped => false,
    };
    self.backend.stopStream(stream);
    defer if (started) self.backend.startStream(stream) catch {
        _ = stream.markDisconnected();
    };
    const pipeline = try self.buildPipeline(stream, next);
    stream.pipeline.deinit(self.gpa);
    stream.pipeline = pipeline;
    stream.negotiated = next;
}

fn notifyStates(self: *Context) void {
    var i: usize = 0;
    while (i < self.stream_list.items.len) : (i += 1) {
        const stream = self.stream_list.items[i];
        const now = stream.state();
        if (now == stream.last_state) continue;
        stream.last_state = now;
        if (stream.options.on_state) |listener| listener.func(listener.ctx, stream, now);
    }
}

/// Does nothing unless the last dispatch gave `.disconnected`. A failed call can be repeated.
/// The Mixer ids of the old connection are not valid after it. Streams with a device keep it.
/// Stream volume and mute of the web backend go back to their defaults.
pub fn reconnect(self: *Context) ReconnectError!void {
    if (!self.disconnected) return;
    try self.backend.reconnect();
    for (self.stream_list.items) |stream| {
        if (!stream.attached) try self.reattach(stream);
    }
    for (self.stream_list.items) |stream| {
        if (!stream.resume_on_reconnect) continue;
        try stream.start();
        stream.resume_on_reconnect = false;
    }
    self.disconnected = false;
}

fn reattach(self: *Context, stream: *Stream) ReconnectError!void {
    const negotiated = try self.backend.openStream(stream);
    checkNegotiated(negotiated) catch |err| {
        self.backend.closeStream(stream);
        return err;
    };
    stream.pending_native = null;
    const old = stream.negotiated;
    if (!old.native.eql(negotiated.native) or old.period_frames != negotiated.period_frames) {
        const pipeline = self.buildPipeline(stream, negotiated) catch |err| {
            self.backend.closeStream(stream);
            _ = stream.markDisconnected();
            return err;
        };
        stream.pipeline.deinit(self.gpa);
        stream.pipeline = pipeline;
        stream.negotiated = negotiated;
    }
    stream.attached = true;
}

pub fn openStream(self: *Context, options: Stream.Options) Stream.OpenError!*Stream {
    const stream = try self.gpa.create(Stream);
    errdefer self.gpa.destroy(stream);
    stream.* = .{
        .context = self,
        .options = options,
        .negotiated = undefined,
        .pipeline = undefined,
    };
    try options.format.validate();
    const negotiated = try self.backend.openStream(stream);
    errdefer self.backend.closeStream(stream);
    try checkNegotiated(negotiated);
    stream.negotiated = negotiated;
    stream.attached = true;
    stream.pipeline = try self.buildPipeline(stream, stream.negotiated);
    errdefer stream.pipeline.deinit(self.gpa);
    try self.stream_list.append(self.gpa, stream);
    return stream;
}

pub fn closeStream(self: *Context, stream: *Stream) void {
    const i = std.mem.indexOfScalar(*Stream, self.stream_list.items, stream) orelse return;
    _ = self.stream_list.orderedRemove(i);
    if (stream.attached) self.backend.closeStream(stream);
    stream.pipeline.deinit(self.gpa);
    self.gpa.destroy(stream);
}

/// A file descriptor that becomes readable when `dispatch` has work, or null. Poll it, and call
/// `dispatch` when it is readable. Do not read from it. It can change after `reconnect`.
/// It covers the messages of the audio system, and the end of a drain and a change of the
/// graph rate, also when the audio thread finds them. It does not cover pumps such as a streaming
/// Player. Wait for `timeoutMs` as well.
pub fn fd(self: *const Context) ?i32 {
    return self.backend.fd();
}

pub fn mixer(self: *Context) *Mixer {
    return &self.mixer_state;
}

pub fn info(self: *const Context) Info {
    return .{ .backend = self.backend.kind, .realtime = self.backend.realtime() };
}

fn checkNegotiated(negotiated: Backend.Negotiated) error{UnsupportedFormat}!void {
    try negotiated.native.validate();
    if (negotiated.period_frames < 1 or negotiated.period_frames > Backend.max_period_frames) return error.UnsupportedFormat;
}

fn buildPipeline(self: *Context, stream: *Stream, negotiated: Backend.Negotiated) error{OutOfMemory}!Pipeline {
    return .init(self.gpa, .{
        .direction = stream.options.direction,
        .user = stream.options.format,
        .native = negotiated.native,
        .max_frames = negotiated.period_frames,
        .quality = stream.options.quality,
    });
}

const Source = struct {
    value: f32 = 0.5,
    status: Stream.Status = .@"continue",
    calls: usize = 0,
    seen: f32 = 0,

    fn callback(self: *Source) Stream.Callback {
        return .{ .ctx = self, .func = run };
    }

    fn run(ctx: ?*anyopaque, stream: *Stream, buffer: Stream.Buffer) Stream.Status {
        const self: *Source = @ptrCast(@alignCast(ctx.?));
        const samples = std.mem.bytesAsSlice(f32, buffer.bytes);
        switch (stream.options.direction) {
            .playback => for (samples) |*v| {
                v.* = self.value;
            },
            .capture => if (samples.len > 0) {
                self.seen = samples[samples.len - 1];
            },
        }
        self.calls += 1;
        return self.status;
    }
};

const mono_f32: Format = .{ .sample = .f32, .rate = 48000, .channels = .mono };

fn testContext(options: Null.Options) !*Context {
    return Context.init(std.testing.allocator, std.testing.io, .{ .app_name = "test", .backend = .null, .null_backend = options });
}

test "auto falls back to the null backend when the first one is unavailable" {
    if (Backend.aaudio_enabled or Backend.coreaudio_enabled) return error.SkipZigTest;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const pipewire_backend: PipeWire.Options = if (Backend.pipewire_enabled)
        .{ .path = "chorus-no-such-remote" }
    else
        .{};
    const ctx = try Context.init(std.testing.allocator, std.testing.io, .{ .app_name = "test", .environ = &env, .pipewire_backend = pipewire_backend });
    defer ctx.deinit();
    try std.testing.expectEqual(Backend.Kind.null, ctx.info().backend);
    try std.testing.expectEqual(Realtime.no, ctx.info().realtime);
}

test "a fallback to the null backend renders and drops the output" {
    if (Backend.aaudio_enabled or Backend.coreaudio_enabled) return error.SkipZigTest;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const pipewire_backend: PipeWire.Options = if (Backend.pipewire_enabled)
        .{ .path = "chorus-no-such-remote" }
    else
        .{};
    const ctx = try Context.init(std.testing.allocator, std.testing.io, .{
        .app_name = "test",
        .environ = &env,
        .pipewire_backend = pipewire_backend,
        .null_backend = .{ .period_frames = 64 },
    });
    defer ctx.deinit();
    if (ctx.info().backend != .null) return error.SkipZigTest;
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try s.start();
    for (0..100) |_| _ = try ctx.dispatch();
    try std.testing.expectEqual(@as(u64, 6400), s.stats().frames);
    try std.testing.expect(ctx.backend.as(Null).?.output(s).len <= 64 * 4);
}

test "the null backend asks for a call each period while a playback stream runs" {
    const ctx = try testContext(.{ .period_frames = 480 });
    defer ctx.deinit();
    var src: Source = .{};
    var rec: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    const c = try ctx.openStream(.{ .direction = .capture, .format = mono_f32, .callback = rec.callback() });
    try c.start();
    try std.testing.expectEqual(@as(?u32, null), ctx.timeoutMs());
    try s.start();
    try std.testing.expectEqual(@as(?u32, 10), ctx.timeoutMs());
    s.stop();
    try std.testing.expectEqual(@as(?u32, null), ctx.timeoutMs());
}

test "a backend that is not compiled in is unavailable" {
    if (Backend.web_enabled) return error.SkipZigTest;
    try std.testing.expectError(
        error.BackendUnavailable,
        Context.init(std.testing.allocator, std.testing.io, .{ .app_name = "test", .backend = .web }),
    );
}

test "a running playback stream renders one period per dispatch" {
    const ctx = try testContext(.{ .period_frames = 64 });
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try s.start();
    _ = try ctx.dispatch();
    _ = try ctx.dispatch();
    const n = ctx.backend.as(Null).?;
    const out = std.mem.bytesAsSlice(f32, n.output(s));
    try std.testing.expectEqual(@as(usize, 128), out.len);
    try std.testing.expectEqual(@as(f32, 0.5), out[127]);
    try std.testing.expectEqual(@as(u64, 128), s.stats().frames);
}

test "an idle stream renders nothing" {
    const ctx = try testContext(.{});
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    _ = try ctx.dispatch();
    try std.testing.expectEqual(@as(usize, 0), ctx.backend.as(Null).?.output(s).len);
    try std.testing.expectEqual(@as(usize, 0), src.calls);
}

test "the stream converts to the native format of the backend" {
    const native: Format = .{ .sample = .s16, .rate = 48000, .channels = .stereo };
    const ctx = try testContext(.{ .native = native, .period_frames = 16 });
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try std.testing.expect(s.nativeFormat().eql(native));
    try s.start();
    _ = try ctx.dispatch();
    const out = ctx.backend.as(Null).?.output(s);
    try std.testing.expectEqual(@as(usize, 16 * 4), out.len);
    const last = std.mem.readInt(i16, out[out.len - 2 ..][0..2], .little);
    try std.testing.expect(last >= 16383 and last <= 16385);
}

test "drain stops the stream one period later" {
    const ctx = try testContext(.{ .period_frames = 8 });
    defer ctx.deinit();
    var src: Source = .{ .status = .drain };
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try s.start();
    _ = try ctx.dispatch();
    try std.testing.expectEqual(Stream.State.draining, s.state());
    _ = try ctx.dispatch();
    try std.testing.expectEqual(Stream.State.stopped, s.state());
    const out = std.mem.bytesAsSlice(f32, ctx.backend.as(Null).?.output(s));
    try std.testing.expectEqual(@as(f32, 0.5), out[7]);
    try std.testing.expectEqual(@as(f32, 0), out[8]);
    try std.testing.expectEqual(@as(usize, 1), src.calls);
}

test "a stop status stops at once and renders silence" {
    const ctx = try testContext(.{ .period_frames = 8 });
    defer ctx.deinit();
    var src: Source = .{ .status = .stop };
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try s.start();
    _ = try ctx.dispatch();
    try std.testing.expectEqual(Stream.State.stopped, s.state());
    for (std.mem.bytesAsSlice(f32, ctx.backend.as(Null).?.output(s))) |v| try std.testing.expectEqual(@as(f32, 0), v);
}

test "capture gives fed audio to the callback" {
    const ctx = try testContext(.{ .period_frames = 4 });
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .capture, .format = mono_f32, .callback = src.callback() });
    try s.start();
    const n = ctx.backend.as(Null).?;
    var bytes: [4 * 4]u8 = undefined;
    for (std.mem.bytesAsSlice(f32, &bytes)) |*v| v.* = 0.75;
    try n.feedInput(s, &bytes);
    _ = try ctx.dispatch();
    try std.testing.expectEqual(@as(f32, 0.75), src.seen);
    try std.testing.expectEqual(@as(usize, 1), src.calls);
}

test "a draining capture stream stops with no input" {
    const ctx = try testContext(.{ .period_frames = 4 });
    defer ctx.deinit();
    var src: Source = .{ .status = .drain };
    const s = try ctx.openStream(.{ .direction = .capture, .format = mono_f32, .callback = src.callback() });
    try s.start();
    const n = ctx.backend.as(Null).?;
    const bytes: [4 * 4]u8 = @splat(0);
    try n.feedInput(s, &bytes);
    _ = try ctx.dispatch();
    try std.testing.expectEqual(Stream.State.draining, s.state());
    _ = try ctx.dispatch();
    try std.testing.expectEqual(Stream.State.stopped, s.state());
}

test "disconnect stops streams and reconnect starts the running ones again" {
    const ctx = try testContext(.{ .period_frames = 8 });
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try s.start();
    const n = ctx.backend.as(Null).?;
    n.disconnect();
    try std.testing.expectEqual(Event.disconnected, try ctx.dispatch());
    try std.testing.expectEqual(Stream.State.stopped, s.state());
    try ctx.reconnect();
    try std.testing.expectEqual(Stream.State.running, s.state());
    _ = try ctx.dispatch();
    try std.testing.expectEqual(@as(usize, 8 * 4), n.output(s).len);
}

fn addSink(n: *Null, m: *Mixer) !Mixer.Id {
    const id = n.newId();
    var ports = [_]Mixer.Port{
        .{ .index = 0, .name = "speaker", .description = "Speaker" },
        .{ .index = 1, .name = "headphones", .description = "Headphones" },
    };
    try m.putEndpoint(.{ .id = id, .kind = .sink, .name = "out", .description = "Out", .volume = .init(&.{ 1, 1 }), .ports = &ports, .active_port = 0 });
    return id;
}

test "one volume value applies to every channel" {
    const ctx = try testContext(.{});
    defer ctx.deinit();
    const id = try addSink(ctx.backend.as(Null).?, ctx.mixer());
    try ctx.mixer().setVolume(.{ .endpoint = id }, .{ .channels = &.{0.3} });
    try std.testing.expectEqualSlices(f32, &.{ 0.3, 0.3 }, ctx.mixer().endpoint(id).?.volume.slice());
}

test "bad volume values are rejected" {
    const ctx = try testContext(.{});
    defer ctx.deinit();
    const id = try addSink(ctx.backend.as(Null).?, ctx.mixer());
    const m = ctx.mixer();
    try std.testing.expectError(error.InvalidVolume, m.setVolume(.{ .endpoint = id }, .{ .channels = &.{-0.1} }));
    try std.testing.expectError(error.InvalidVolume, m.setVolume(.{ .endpoint = id }, .{ .channels = &.{std.math.nan(f32)} }));
    try std.testing.expectError(error.InvalidVolume, m.setVolume(.{ .endpoint = id }, .{ .channels = &.{ 1, 1, 1 } }));
}

test "a sink cannot be the default source" {
    const ctx = try testContext(.{});
    defer ctx.deinit();
    const id = try addSink(ctx.backend.as(Null).?, ctx.mixer());
    try std.testing.expectError(error.UnknownObject, ctx.mixer().setDefault(.source, id));
    try ctx.mixer().setDefault(.sink, id);
    try std.testing.expectEqual(@as(?Mixer.Id, id), ctx.mixer().default(.sink));
}

test "setPort changes the active port and rejects unknown ports" {
    const ctx = try testContext(.{});
    defer ctx.deinit();
    const id = try addSink(ctx.backend.as(Null).?, ctx.mixer());
    try ctx.mixer().setPort(id, 1);
    try std.testing.expectEqual(@as(?u32, 1), ctx.mixer().endpoint(id).?.active_port);
    try std.testing.expectError(error.InvalidIndex, ctx.mixer().setPort(id, 5));
}

test "moveStream sends a playback stream to a sink" {
    const ctx = try testContext(.{});
    defer ctx.deinit();
    const n = ctx.backend.as(Null).?;
    const sink_id = try addSink(n, ctx.mixer());
    const stream_id = n.newId();
    try ctx.mixer().putStream(.{ .id = stream_id, .direction = .playback, .app_name = "music", .name = "song", .volume = .init(&.{ 1, 1 }) });
    try ctx.mixer().moveStream(stream_id, sink_id);
    try std.testing.expectEqual(@as(?Mixer.Id, sink_id), ctx.mixer().stream(stream_id).?.endpoint);
}

test "an operation the backend cannot do is unsupported" {
    var caps: Mixer.Capabilities = .all;
    caps.profiles = false;
    const ctx = try testContext(.{ .capabilities = caps });
    defer ctx.deinit();
    const n = ctx.backend.as(Null).?;
    const id = n.newId();
    try ctx.mixer().putCard(.{ .id = id, .name = "card", .description = "Card" });
    try std.testing.expectError(error.Unsupported, ctx.mixer().setProfile(id, 0));
}

test "reconnect rebuilds the pipeline when the native format changes" {
    const ctx = try testContext(.{ .period_frames = 16 });
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try s.start();
    const n = ctx.backend.as(Null).?;
    const native: Format = .{ .sample = .s16, .rate = 48000, .channels = .stereo };
    n.setNative(native);
    n.disconnect();
    _ = try ctx.dispatch();
    try ctx.reconnect();
    try std.testing.expect(s.nativeFormat().eql(native));
    _ = try ctx.dispatch();
    const out = n.output(s);
    try std.testing.expectEqual(@as(usize, 16 * 4), out.len);
    const last = std.mem.readInt(i16, out[out.len - 2 ..][0..2], .little);
    try std.testing.expect(last >= 16383 and last <= 16385);
}

test "an idle stream stays idle across a reconnect" {
    const ctx = try testContext(.{});
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    const n = ctx.backend.as(Null).?;
    n.disconnect();
    _ = try ctx.dispatch();
    try ctx.reconnect();
    try std.testing.expectEqual(Stream.State.idle, s.state());
    _ = try ctx.dispatch();
    try std.testing.expectEqual(@as(usize, 0), n.output(s).len);
    try std.testing.expectEqual(@as(usize, 0), src.calls);
}

test "reconnect without a disconnect does not render a stream twice" {
    const ctx = try testContext(.{ .period_frames = 8 });
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try s.start();
    try ctx.reconnect();
    _ = try ctx.dispatch();
    try std.testing.expectEqual(@as(usize, 8 * 4), ctx.backend.as(Null).?.output(s).len);
}

test "start during drain makes the stream run again" {
    const ctx = try testContext(.{ .period_frames = 8 });
    defer ctx.deinit();
    var src: Source = .{ .status = .drain };
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try s.start();
    _ = try ctx.dispatch();
    try std.testing.expectEqual(Stream.State.draining, s.state());
    src.status = .@"continue";
    try s.start();
    try std.testing.expectEqual(Stream.State.running, s.state());
    _ = try ctx.dispatch();
    try std.testing.expectEqual(Stream.State.running, s.state());
    const out = std.mem.bytesAsSlice(f32, ctx.backend.as(Null).?.output(s));
    try std.testing.expectEqual(@as(f32, 0.5), out[8]);
    try std.testing.expectEqual(@as(f32, 0.5), out[15]);
}

test "a stop from the app wins over the callback" {
    const ctx = try testContext(.{ .period_frames = 8 });
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    var buf: [8 * 4]u8 align(4) = undefined;
    try s.start();
    s.stop();
    s.render(&buf);
    try std.testing.expectEqual(Stream.State.stopped, s.state());
    for (std.mem.bytesAsSlice(f32, &buf)) |v| try std.testing.expectEqual(@as(f32, 0), v);
    try std.testing.expectEqual(@as(usize, 0), src.calls);

    try s.start();
    src.status = .stop;
    s.render(&buf);
    try std.testing.expectEqual(Stream.State.stopped, s.state());

    try s.start();
    src.status = .drain;
    s.render(&buf);
    try std.testing.expectEqual(Stream.State.draining, s.state());
}

test "a buffer larger than the period is rendered in chunks" {
    const native: Format = .{ .sample = .s16, .rate = 48000, .channels = .stereo };
    const ctx = try testContext(.{ .native = native, .period_frames = 64, .render_frames = 200 });
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try s.start();
    _ = try ctx.dispatch();
    const out = ctx.backend.as(Null).?.output(s);
    try std.testing.expectEqual(@as(usize, 800), out.len);
    const last = std.mem.readInt(i16, out[out.len - 2 ..][0..2], .little);
    try std.testing.expect(last >= 16383 and last <= 16385);
    try std.testing.expectEqual(@as(u64, 200), s.stats().frames);
}

test "a bad user format is rejected" {
    const ctx = try testContext(.{});
    defer ctx.deinit();
    var src: Source = .{};
    var zero_rate = mono_f32;
    zero_rate.rate = 0;
    try std.testing.expectError(error.UnsupportedFormat, ctx.openStream(.{ .direction = .playback, .format = zero_rate, .callback = src.callback() }));
    var no_channels = mono_f32;
    no_channels.channels = .{ .count = 0, .positions = @splat(.mono) };
    try std.testing.expectError(error.UnsupportedFormat, ctx.openStream(.{ .direction = .playback, .format = no_channels, .callback = src.callback() }));
}

test "a backend period of zero is rejected without a leak" {
    const ctx = try testContext(.{ .period_frames = 0 });
    defer ctx.deinit();
    var src: Source = .{};
    try std.testing.expectError(error.UnsupportedFormat, ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() }));
    try std.testing.expectEqual(@as(usize, 0), ctx.backend.as(Null).?.entries.items.len);
}

test "a ten channel endpoint takes one volume value for all channels" {
    const ctx = try testContext(.{});
    defer ctx.deinit();
    const n = ctx.backend.as(Null).?;
    const id = n.newId();
    try ctx.mixer().putEndpoint(.{ .id = id, .kind = .sink, .name = "out", .description = "Out", .volume = .init(&@as([10]f32, @splat(1))) });
    try ctx.mixer().setVolume(.{ .endpoint = id }, .{ .channels = &.{0.5} });
    try std.testing.expectEqualSlices(f32, &@as([10]f32, @splat(0.5)), ctx.mixer().endpoint(id).?.volume.slice());
}

test "an endpoint with no channels has no volume control" {
    const ctx = try testContext(.{});
    defer ctx.deinit();
    const n = ctx.backend.as(Null).?;
    const id = n.newId();
    try ctx.mixer().putEndpoint(.{ .id = id, .kind = .sink, .name = "out", .description = "Out", .volume = .init(&.{}) });
    try std.testing.expectError(error.Unsupported, ctx.mixer().setVolume(.{ .endpoint = id }, .{ .channels = &.{0.5} }));
}

test "volume data from a backend is checked against the channel limit" {
    const too_many: [Mixer.max_channels + 1]f32 = @splat(1);
    try std.testing.expectError(error.InvalidVolume, Mixer.Volume.initChecked(&too_many));
    const ok = try Mixer.Volume.initChecked(too_many[0..Mixer.max_channels]);
    try std.testing.expectEqual(@as(u8, 64), ok.count);
}

test "a second disconnect keeps the resume flag" {
    const ctx = try testContext(.{ .period_frames = 8 });
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try s.start();
    const n = ctx.backend.as(Null).?;
    n.disconnect();
    try std.testing.expectEqual(Event.disconnected, try ctx.dispatch());
    n.disconnect();
    try std.testing.expectEqual(Event.disconnected, try ctx.dispatch());
    try ctx.reconnect();
    try std.testing.expectEqual(Stream.State.running, s.state());
    try std.testing.expectEqual(@as(usize, 1), n.entries.items.len);
}

test "a failed reconnect can be repeated without duplicate entries" {
    const ctx = try testContext(.{ .period_frames = 8 });
    defer ctx.deinit();
    var src: Source = .{};
    const a = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    const b = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try a.start();
    try b.start();
    const n = ctx.backend.as(Null).?;
    n.disconnect();
    _ = try ctx.dispatch();
    n.setNative(.{ .sample = .s16, .rate = 48000, .channels = .{ .count = 0, .positions = @splat(.mono) } });
    try std.testing.expectError(error.UnsupportedFormat, ctx.reconnect());
    try std.testing.expectEqual(@as(usize, 0), n.entries.items.len);
    try std.testing.expect(!a.attached);
    n.setNative(null);
    try ctx.reconnect();
    try std.testing.expectEqual(@as(usize, 2), n.entries.items.len);
    try std.testing.expectEqual(Stream.State.running, a.state());
    try std.testing.expectEqual(Stream.State.running, b.state());
}

const States = struct {
    list: [8]Stream.State = undefined,
    len: usize = 0,

    fn listener(self: *States) Stream.StateListener {
        return .{ .ctx = self, .func = record };
    }

    fn record(ctx: ?*anyopaque, stream: *Stream, state: Stream.State) void {
        _ = stream;
        const self: *States = @ptrCast(@alignCast(ctx.?));
        self.list[self.len] = state;
        self.len += 1;
    }
};

test "the app hears when a drained stream stops" {
    const ctx = try testContext(.{ .period_frames = 8 });
    defer ctx.deinit();
    var src: Source = .{ .status = .drain };
    var states: States = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback(), .on_state = states.listener() });
    try s.start();
    for (0..4) |_| _ = try ctx.dispatch();
    try std.testing.expectEqualSlices(Stream.State, &.{ .draining, .stopped }, states.list[0..states.len]);
}

test "a restart plays no audio from before the stop" {
    const native: Format = .{ .sample = .f32, .rate = 44100, .channels = .mono };
    const ctx = try testContext(.{ .native = native, .period_frames = 64 });
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try s.start();
    for (0..4) |_| _ = try ctx.dispatch();
    s.stop();
    src.value = 0;
    try s.start();
    const n = ctx.backend.as(Null).?;
    const before = n.output(s).len;
    _ = try ctx.dispatch();
    const out = std.mem.bytesAsSlice(f32, n.output(s)[before..]);
    try std.testing.expectEqual(@as(usize, 64), out.len);
    for (out) |v| try std.testing.expectEqual(@as(f32, 0), v);
}

test "a pending native format swaps the pipeline and the stream keeps running" {
    const ctx = try testContext(.{ .period_frames = 16 });
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try s.start();
    _ = try ctx.dispatch();
    const native: Format = .{ .sample = .s16, .rate = 48000, .channels = .stereo };
    s.pending_native = .{ .native = native, .period_frames = 8 };
    _ = try ctx.dispatch();
    try std.testing.expect(s.nativeFormat().eql(native));
    try std.testing.expectEqual(@as(u32, 8), s.negotiated.period_frames);
    try std.testing.expectEqual(@as(?Backend.Negotiated, null), s.pending_native);
    try std.testing.expectEqual(Stream.State.running, s.state());

    const n = ctx.backend.as(Null).?;
    n.clearOutput(s);
    _ = try ctx.dispatch();
    const out = n.output(s);
    try std.testing.expectEqual(@as(usize, 8 * 4), out.len);
    const last = std.mem.readInt(i16, out[out.len - 2 ..][0..2], .little);
    try std.testing.expect(last >= 16383 and last <= 16385);
}

test "a pending native format keeps an idle stream idle" {
    const ctx = try testContext(.{ .period_frames = 16 });
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    const native: Format = .{ .sample = .f32, .rate = 44100, .channels = .mono };
    s.pending_native = .{ .native = native, .period_frames = 32 };
    _ = try ctx.dispatch();
    try std.testing.expect(s.nativeFormat().eql(native));
    try std.testing.expectEqual(Stream.State.idle, s.state());
    try std.testing.expectEqual(@as(?Backend.Negotiated, null), s.pending_native);
    try std.testing.expectEqual(@as(usize, 0), ctx.backend.as(Null).?.output(s).len);
}

test "a pending native format that is not valid stops the stream once" {
    const saved_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_level;
    const ctx = try testContext(.{ .period_frames = 16 });
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try s.start();
    s.pending_native = .{ .native = .{ .sample = .f32, .rate = 0, .channels = .mono }, .period_frames = 16 };
    _ = try ctx.dispatch();
    try std.testing.expectEqual(@as(u32, 48000), s.nativeFormat().rate);
    try std.testing.expectEqual(@as(?Backend.Negotiated, null), s.pending_native);
    try std.testing.expectEqual(Stream.State.stopped, s.state());
    _ = try ctx.dispatch();
    try std.testing.expectEqual(@as(?Backend.Negotiated, null), s.pending_native);
}

test "a failed renegotiation does not leave a later stream pending" {
    const ctx = try testContext(.{ .period_frames = 16 });
    defer ctx.deinit();
    var src: Source = .{};
    const a = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    const b = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try a.start();
    try b.start();
    const native: Format = .{ .sample = .f32, .rate = 44100, .channels = .mono };
    a.pending_native = .{ .native = native, .period_frames = 32 };
    b.pending_native = .{ .native = native, .period_frames = 32 };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    ctx.gpa = failing.allocator();
    defer ctx.gpa = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, ctx.dispatch());
    try std.testing.expectEqual(@as(?Backend.Negotiated, null), a.pending_native);
    try std.testing.expectEqual(@as(?Backend.Negotiated, null), b.pending_native);
    try std.testing.expectEqual(Stream.State.running, a.state());
    try std.testing.expectEqual(Stream.State.running, b.state());
    try std.testing.expectEqual(@as(u32, 48000), a.nativeFormat().rate);
}

const PumpLog = struct {
    calls: u32 = 0,
    frames_seen: u64 = 0,
    stream: ?*Stream = null,
    ctx: ?*Context = null,
    remove_self: bool = false,

    fn pump(ptr: ?*anyopaque) void {
        const self: *PumpLog = @ptrCast(@alignCast(ptr.?));
        self.calls += 1;
        if (self.stream) |s| self.frames_seen = s.stats().frames;
        if (self.remove_self) self.ctx.?.removePump(.{ .ctx = self, .func = pump });
    }
};

test "pumps run on every dispatch, also with no stream" {
    const ctx = try testContext(.{});
    defer ctx.deinit();
    var log_a: PumpLog = .{};
    var log_b: PumpLog = .{};
    try ctx.addPump(.{ .ctx = &log_a, .func = PumpLog.pump });
    var a_added = true;
    defer if (a_added) ctx.removePump(.{ .ctx = &log_a, .func = PumpLog.pump });
    try ctx.addPump(.{ .ctx = &log_b, .func = PumpLog.pump });
    defer ctx.removePump(.{ .ctx = &log_b, .func = PumpLog.pump });
    _ = try ctx.dispatch();
    _ = try ctx.dispatch();
    try std.testing.expectEqual(@as(u32, 2), log_a.calls);
    try std.testing.expectEqual(@as(u32, 2), log_b.calls);
    ctx.removePump(.{ .ctx = &log_a, .func = PumpLog.pump });
    a_added = false;
    _ = try ctx.dispatch();
    try std.testing.expectEqual(@as(u32, 2), log_a.calls);
    try std.testing.expectEqual(@as(u32, 3), log_b.calls);
}

test "a pump runs before the render pass of the same dispatch" {
    const ctx = try testContext(.{ .period_frames = 64 });
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    try s.start();
    var log_a: PumpLog = .{ .stream = s };
    try ctx.addPump(.{ .ctx = &log_a, .func = PumpLog.pump });
    defer ctx.removePump(.{ .ctx = &log_a, .func = PumpLog.pump });
    _ = try ctx.dispatch();
    try std.testing.expectEqual(@as(u64, 0), log_a.frames_seen);
    try std.testing.expectEqual(@as(u64, 64), s.stats().frames);
    _ = try ctx.dispatch();
    try std.testing.expectEqual(@as(u64, 64), log_a.frames_seen);
}

test "a pump can remove itself and the next pump still runs" {
    const ctx = try testContext(.{});
    defer ctx.deinit();
    var first: PumpLog = .{ .ctx = ctx, .remove_self = true };
    var second: PumpLog = .{};
    try ctx.addPump(.{ .ctx = &first, .func = PumpLog.pump });
    try ctx.addPump(.{ .ctx = &second, .func = PumpLog.pump });
    defer ctx.removePump(.{ .ctx = &second, .func = PumpLog.pump });
    _ = try ctx.dispatch();
    _ = try ctx.dispatch();
    try std.testing.expectEqual(@as(u32, 1), first.calls);
    try std.testing.expectEqual(@as(u32, 2), second.calls);
}

test "stream totals stay right when the 32 bit counters wrap" {
    const ctx = try testContext(.{ .period_frames = 64 });
    defer ctx.deinit();
    var src: Source = .{};
    const s = try ctx.openStream(.{ .direction = .playback, .format = mono_f32, .callback = src.callback() });
    const start: u32 = std.math.maxInt(u32) - 31;
    s.frames_total.store(start, .monotonic);
    s.frames_seen = start;
    s.frames_base = start;
    s.xrun_total.store(std.math.maxInt(u32), .monotonic);
    s.xruns_seen = std.math.maxInt(u32);
    s.xruns_base = std.math.maxInt(u32);
    try s.start();
    _ = try ctx.dispatch();
    try std.testing.expectEqual(@as(u64, start) + 64, s.stats().frames);
    _ = try ctx.dispatch();
    s.noteXrun();
    try std.testing.expectEqual(@as(u64, start) + 128, s.stats().frames);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u32)) + 1, s.stats().xruns);
    try std.testing.expect(s.stats().frames > std.math.maxInt(u32));
}

const Timeout = struct {
    ms: ?u32,

    fn hint(ptr: ?*anyopaque) ?u32 {
        const self: *Timeout = @ptrCast(@alignCast(ptr.?));
        return self.ms;
    }

    fn none(ptr: ?*anyopaque) void {
        _ = ptr;
    }
};

test "timeoutMs is the smallest hint of the pumps" {
    const ctx = try testContext(.{});
    defer ctx.deinit();
    try std.testing.expectEqual(@as(?u32, null), ctx.timeoutMs());
    var a: Timeout = .{ .ms = null };
    var b: Timeout = .{ .ms = 40 };
    var c: Timeout = .{ .ms = 25 };
    var plain: PumpLog = .{};
    try ctx.addPump(.{ .ctx = &plain, .func = PumpLog.pump });
    defer ctx.removePump(.{ .ctx = &plain, .func = PumpLog.pump });
    try ctx.addPump(.{ .ctx = &a, .func = Timeout.none, .timeout = Timeout.hint });
    defer ctx.removePump(.{ .ctx = &a, .func = Timeout.none });
    try std.testing.expectEqual(@as(?u32, null), ctx.timeoutMs());
    try ctx.addPump(.{ .ctx = &b, .func = Timeout.none, .timeout = Timeout.hint });
    defer ctx.removePump(.{ .ctx = &b, .func = Timeout.none });
    try std.testing.expectEqual(@as(?u32, 40), ctx.timeoutMs());
    try ctx.addPump(.{ .ctx = &c, .func = Timeout.none, .timeout = Timeout.hint });
    defer ctx.removePump(.{ .ctx = &c, .func = Timeout.none });
    try std.testing.expectEqual(@as(?u32, 25), ctx.timeoutMs());
    c.ms = 0;
    try std.testing.expectEqual(@as(?u32, 0), ctx.timeoutMs());
}

test "timeoutMs takes the smaller of the backend hint and the pump hints" {
    const ctx = try testContext(.{ .timeout_ms = 30 });
    defer ctx.deinit();
    try std.testing.expectEqual(@as(?u32, 30), ctx.timeoutMs());
    var pump_hint: Timeout = .{ .ms = 50 };
    try ctx.addPump(.{ .ctx = &pump_hint, .func = Timeout.none, .timeout = Timeout.hint });
    defer ctx.removePump(.{ .ctx = &pump_hint, .func = Timeout.none });
    try std.testing.expectEqual(@as(?u32, 30), ctx.timeoutMs());
    pump_hint.ms = 10;
    try std.testing.expectEqual(@as(?u32, 10), ctx.timeoutMs());
    pump_hint.ms = null;
    try std.testing.expectEqual(@as(?u32, 30), ctx.timeoutMs());
}

test "auto never picks the aaudio backend off Android" {
    if (Backend.aaudio_enabled) return error.SkipZigTest;
    try std.testing.expect(!Backend.compiled(.aaudio));
    if (Backend.coreaudio_enabled) return error.SkipZigTest;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const pipewire_backend: PipeWire.Options = if (Backend.pipewire_enabled)
        .{ .path = "chorus-no-such-remote" }
    else
        .{};
    const ctx = try Context.init(std.testing.allocator, std.testing.io, .{ .app_name = "test", .environ = &env, .pipewire_backend = pipewire_backend });
    defer ctx.deinit();
    try std.testing.expect(!Backend.compiled(.aaudio));
    try std.testing.expectEqual(Backend.Kind.null, ctx.info().backend);
    try std.testing.expectError(
        error.BackendUnavailable,
        Context.init(std.testing.allocator, std.testing.io, .{ .app_name = "test", .backend = .aaudio }),
    );
}
