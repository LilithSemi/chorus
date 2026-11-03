//! Tests of the CoreAudio backend with the fake CoreAudio.
const std = @import("std");
const builtin = @import("builtin");
const Format = @import("../../Format.zig");
const Mixer = @import("../../Mixer.zig");
const Stream = @import("../../Stream.zig");
const Context = @import("../../Context.zig");
const Backend = @import("../Backend.zig");
const CoreAudio = @import("../CoreAudio.zig");
const ca = @import("api.zig");
const map = @import("map.zig");
const permission = @import("permission.zig");
const Wake = @import("wake.zig");
const Fake = @import("fake.zig");
const testing = std.testing;

/// The fake needs the wake pipe, which wasi and the browser do not have.
pub const usable = Wake.available;
pub const threaded = !builtin.single_threaded;

pub const stereo: Format = .{ .sample = .f32, .rate = 48000, .channels = .stereo };

pub const Double = struct {
    value: permission.Status,

    pub fn source(self: *Double) permission.Source {
        return .{ .ptr = self, .statusFn = status };
    }

    fn status(ptr: *anyopaque) permission.Status {
        const self: *Double = @ptrCast(@alignCast(ptr));
        return self.value;
    }
};

pub const Tone = struct {
    value: f32 = 0.25,
    status: Stream.Status = .@"continue",
    calls: std.atomic.Value(u32) = .init(0),
    seen: f32 = 0,
    entered: std.atomic.Value(u32) = .init(0),
    release: std.atomic.Value(u32) = .init(1),

    pub fn callback(self: *Tone) Stream.Callback {
        return .{ .ctx = self, .func = run };
    }

    fn run(ctx: ?*anyopaque, stream: *Stream, buffer: Stream.Buffer) Stream.Status {
        const self: *Tone = @ptrCast(@alignCast(ctx.?));
        const samples = std.mem.bytesAsSlice(f32, buffer.bytes);
        switch (stream.options.direction) {
            .playback => @memset(samples, self.value),
            .capture => self.seen = samples[samples.len - 1],
        }
        self.entered.store(1, .release);
        while (self.release.load(.acquire) == 0) std.atomic.spinLoopHint();
        _ = self.calls.fetchAdd(1, .monotonic);
        return self.status;
    }
};

pub const Harness = struct {
    fake: Fake,
    perm: Double = .{ .value = .authorized },
    ctx: *Context,

    pub fn begin(self: *Harness) void {
        self.* = .{ .fake = .init(testing.allocator), .ctx = undefined };
        self.fake.addDevice(.{ .id = 71 });
    }

    pub fn attach(self: *Harness, options: CoreAudio.Options) !void {
        var opts = options;
        opts.api = self.fake.binding();
        opts.permission = self.perm.source();
        self.ctx = try Context.init(testing.allocator, testing.io, .{
            .app_name = "test",
            .backend = .coreaudio,
            .coreaudio_backend = opts,
        });
    }

    pub fn init(self: *Harness, options: CoreAudio.Options) !void {
        self.begin();
        errdefer self.fake.deinit();
        try self.attach(options);
    }

    /// A microphone with the id 72. It becomes the default input.
    pub fn addMic(self: *Harness) void {
        self.fake.addDevice(.{ .id = 72, .out_channels = 0, .in_channels = 2 });
    }

    pub fn deinit(self: *Harness) void {
        self.ctx.deinit();
        const clean = self.fake.unitCount() == 0 and self.fake.listenerCount() == 0 and
            self.fake.bad_uses == 0 and self.fake.violations.load(.monotonic) == 0 and self.fake.strings_live == 0;
        self.fake.deinit();
        if (!clean) @panic("the backend left a unit or a listener behind, or called the HAL from a listener or an IO callback");
    }

    pub fn backend(self: *Harness) *CoreAudio {
        return self.ctx.backend.as(CoreAudio).?;
    }

    pub fn open(self: *Harness, direction: Stream.Direction, tone: *Tone) !*Stream {
        return self.ctx.openStream(.{ .direction = direction, .format = stereo, .callback = tone.callback() });
    }

    pub fn openOn(self: *Harness, direction: Stream.Direction, tone: *Tone, device: ca.AudioObjectID) !*Stream {
        return self.ctx.openStream(.{
            .direction = direction,
            .format = stereo,
            .callback = tone.callback(),
            .device = map.endpointId(device, direction == .capture).?,
        });
    }

    pub fn waitFor(self: *Harness, stream: *Stream, state: Stream.State) !void {
        for (0..2000) |_| {
            _ = try self.ctx.dispatch();
            if (stream.state() == state) return;
            try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
        }
        return error.Timeout;
    }
};

fn expectSamples(bytes: []const u8, value: f32) !void {
    for (std.mem.bytesAsSlice(f32, bytes)) |v| try testing.expectEqual(value, v);
}

test "playback opens a HALOutput unit with the f32 client format" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .latency_frames = 256 });
    try testing.expect(s.nativeFormat().eql(stereo));
    try testing.expectEqual(@as(u32, 256), s.negotiated.period_frames);
    const u = h.fake.unit(0);
    try testing.expectEqual(@as(ca.AudioObjectID, 71), u.device);
    const client = u.client_out.?;
    try testing.expect(map.isF32Interleaved(client));
    try testing.expectEqual(@as(f64, 48000), client.mSampleRate);
    try testing.expectEqual(@as(u32, 2), client.mChannelsPerFrame);
    try testing.expect(u.render.inputProc != null);
    try testing.expect(u.initialized and !u.running);
    try testing.expectEqual(@as(u32, 256), u.mfps);
    try testing.expectEqual(@as(u32, 256), h.fake.device(71).fsiz);
    const f = &h.fake;
    try testing.expect(f.position(.component_new, 0).? < f.position(.set_device, 0).?);
    try testing.expect(f.position(.set_device, 0).? < f.position(.set_format, 0).?);
    try testing.expect(f.position(.set_format, 0).? < f.position(.set_callback, 0).?);
    try testing.expect(f.position(.set_callback, 0).? < f.position(.initialize, 0).?);
    try testing.expectEqual(@as(usize, 7), f.objectListenerCount());
    try testing.expectEqual(@as(usize, 2), f.unitListenerCount());
    try testing.expectEqual(@as(u32, 1), f.run_loop_sets);
    try testing.expectEqual(@as(usize, 1), h.ctx.mixer().streams().len);
}

test "the buffer size follows the range of the device and the read back" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.device(71).fsiz_max = 128;
    h.fake.device(71).fsiz_min = 64;
    var tone: Tone = .{};
    const high = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .latency_frames = 512 });
    try testing.expectEqual(@as(u32, 128), high.negotiated.period_frames);
    try testing.expectEqual(@as(u32, 128), h.fake.device(71).fsiz);
    const low = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .latency_frames = 16 });
    try testing.expectEqual(@as(u32, 64), low.negotiated.period_frames);
    h.fake.fsiz_forced = 100;
    const forced = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .latency_frames = 96 });
    try testing.expectEqual(@as(u32, 100), forced.negotiated.period_frames);
}

test "a unit with too few frames per slice fails the open and leaves nothing" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.mfps_override = 64;
    var tone: Tone = .{};
    try testing.expectError(error.UnsupportedFormat, h.open(.playback, &tone));
    try testing.expectEqual(@as(usize, 0), h.fake.unitCount());
    try testing.expectEqual(@as(u32, 1), h.fake.count(.dispose));
    try testing.expectEqual(@as(usize, 0), h.ctx.mixer().streams().len);
    try testing.expectEqual(@as(usize, 4), h.fake.listenerCount());
}

test "the render callback fills the buffer and a stopped stream gets silence" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    const u = h.fake.unit(0);
    try testing.expect(u.running);
    var buf: [96 * 8]u8 = undefined;
    try testing.expectEqual(ca.Status.ok, u.callRender(&buf));
    try expectSamples(&buf, 0.25);
    try testing.expect(!u.silent());
    try testing.expectEqual(@as(u64, 96), s.stats().frames);
    try testing.expectEqual(@as(u32, 1), tone.calls.load(.monotonic));
    s.stop();
    try testing.expect(!u.running);
    @memset(&buf, 0x55);
    try testing.expectEqual(ca.Status.ok, u.callRender(&buf));
    try expectSamples(&buf, 0);
    try testing.expect(u.silent());
    try testing.expectEqual(@as(u32, 1), tone.calls.load(.monotonic));
    try s.start();
    try testing.expectEqual(@as(u32, 2), h.fake.count(.start));
    try testing.expectEqual(ca.Status.ok, u.callRender(&buf));
    try expectSamples(&buf, 0.25);
}

test "a render buffer smaller than the request is filled by whole frames" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    var buf: [10 * 8 + 5]u8 = @splat(0x55);
    try testing.expectEqual(ca.Status.ok, h.fake.unit(0).callRender(buf[0 .. 10 * 8]));
    try expectSamples(buf[0 .. 10 * 8], 0.25);
    try testing.expectEqual(@as(u8, 0x55), buf[80]);
    try testing.expectEqual(@as(u64, 10), s.stats().frames);
}

test "the first callback reads the thread policy once" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try testing.expectEqual(Backend.Realtime.pending, h.ctx.info().realtime);
    try s.start();
    var buf: [32 * 8]u8 = undefined;
    _ = h.fake.unit(0).callRender(&buf);
    _ = h.fake.unit(0).callRender(&buf);
    try testing.expectEqual(Backend.Realtime.yes, h.ctx.info().realtime);
    try testing.expectEqual(@as(u32, 1), h.fake.thread_policy_calls);
    try testing.expectEqual(@as(u32, 0), h.fake.violations.load(.monotonic));
    h.fake.realtime_policy = false;
    h.backend().rt.store(0, .release);
    _ = h.fake.unit(0).callRender(&buf);
    try testing.expectEqual(Backend.Realtime.no, h.ctx.info().realtime);
}

test "capture enables the input bus and gives the audio to the user" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.addMic();
    var tone: Tone = .{};
    const s = try h.open(.capture, &tone);
    const u = h.fake.unit(0);
    try testing.expectEqual(@as(u32, 1), u.enable_in);
    try testing.expectEqual(@as(u32, 0), u.enable_out);
    try testing.expectEqual(@as(ca.AudioObjectID, 72), u.device);
    try testing.expect(map.isF32Interleaved(u.client_in.?));
    try testing.expect(u.input.inputProc != null);
    try testing.expectEqual(@as(?ca.AURenderCallback, null), u.render.inputProc);
    try s.start();
    try testing.expectEqual(ca.Status.ok, u.callInput(64));
    const last = h.fake.last_render;
    try testing.expectEqual(@as(u32, 64), last.frames);
    try testing.expectEqual(@as(u32, 1), last.bus);
    try testing.expectEqual(@as(u32, 64 * 8), last.bytes);
    try testing.expectEqual(@as(u32, 2), last.channels);
    try testing.expectEqual(@as(u32, 1), last.buffers);
    try testing.expectEqual(@as(f32, 0.5), tone.seen);
    try testing.expectEqual(@as(u64, 64), s.stats().frames);
    s.stop();
    h.fake.capture_value = 0.75;
    try testing.expectEqual(ca.Status.ok, u.callInput(32));
    try testing.expectEqual(@as(u32, 32), h.fake.last_render.frames);
    try testing.expectEqual(@as(f32, 0.5), tone.seen);
    try testing.expectEqual(@as(u32, 1), tone.calls.load(.monotonic));
    try testing.expectEqual(ca.Status.unit_too_many_frames, u.callInput(1 << 20));
}

test "capture with no default input device fails the open" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    try testing.expectEqual(@as(ca.AudioObjectID, 0), h.fake.default_in);
    try testing.expectError(error.UnknownDevice, h.open(.capture, &tone));
    try testing.expectEqual(@as(u32, 0), h.fake.count(.component_new));
    try testing.expectEqual(@as(usize, 0), h.ctx.mixer().streams().len);
}

test "capture on a device with no input channels fails and frees the unit" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    h.fake.default_in = 71;
    try testing.expectError(error.UnknownDevice, h.open(.capture, &tone));
    try testing.expectEqual(@as(u32, 1), h.fake.count(.component_new));
    try testing.expectEqual(@as(u32, 1), h.fake.count(.dispose));
    try testing.expectEqual(@as(usize, 0), h.fake.unitCount());
    try testing.expectError(error.UnknownDevice, h.openOn(.capture, &tone, 71));
    try testing.expectEqual(@as(usize, 0), h.fake.unitCount());
}

test "capture needs the permission of the user" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.addMic();
    var tone: Tone = .{};
    for ([_]permission.Status{ .denied, .restricted }) |blocked| {
        h.perm.value = blocked;
        try testing.expectError(error.PermissionDenied, h.open(.capture, &tone));
        try testing.expectEqual(@as(u32, 0), h.fake.count(.component_new));
    }
    for ([_]permission.Status{ .authorized, .not_determined, .unknown }) |allowed| {
        h.perm.value = allowed;
        const s = try h.open(.capture, &tone);
        s.close();
    }
    h.perm.value = .denied;
    const playback = try h.open(.playback, &tone);
    playback.close();
}

test "an explicit device that does not exist or has the wrong direction fails" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    try testing.expectError(error.UnknownDevice, h.openOn(.playback, &tone, 99));
    const wrong_direction = [_]struct { direction: Stream.Direction, source: bool }{
        .{ .direction = .playback, .source = true },
        .{ .direction = .capture, .source = false },
    };
    for (wrong_direction) |row| {
        try testing.expectError(error.UnknownDevice, h.ctx.openStream(.{
            .direction = row.direction,
            .format = stereo,
            .callback = tone.callback(),
            .device = map.endpointId(71, row.source).?,
        }));
    }
    try testing.expectEqual(@as(u32, 0), h.fake.count(.component_new));
}

test "a playback stream with no default output fails the open" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.default_out = 0;
    var tone: Tone = .{};
    try testing.expectError(error.UnknownDevice, h.open(.playback, &tone));
    try testing.expectEqual(@as(u32, 0), h.fake.count(.component_new));
}

test "open errors map to stream errors and leave no unit" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    h.fake.fail_new = ca.Status.mem_full;
    try testing.expectError(error.OutOfMemory, h.open(.playback, &tone));
    h.fake.fail_new = ca.Status.bad_device;
    try testing.expectError(error.UnknownDevice, h.open(.playback, &tone));
    h.fake.fail_new = ca.Status.component_not_permitted;
    try testing.expectError(error.PermissionDenied, h.open(.playback, &tone));
    h.fake.fail_new = null;
    h.fake.fail_initialize_times = 1;
    try testing.expectError(error.Disconnected, h.open(.playback, &tone));
    try testing.expectEqual(@as(usize, 0), h.fake.unitCount());
    try testing.expectEqual(@as(u32, 1), h.fake.count(.component_new));
    try testing.expectEqual(@as(u32, 1), h.fake.count(.dispose));
    try testing.expectEqual(@as(usize, 4), h.fake.listenerCount());
    h.fake.device(71).rate = 0;
    try testing.expectError(error.UnsupportedFormat, h.open(.playback, &tone));
    h.fake.device(71).rate = 48000;
    const s = try h.open(.playback, &tone);
    s.close();
}

test "a start that the unit refuses leaves the stream stopped" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    h.fake.fail_start = ca.Status.unspecified;
    try testing.expectError(error.Disconnected, s.start());
    try testing.expectEqual(Stream.State.idle, s.state());
    h.fake.fail_start = null;
    try s.start();
    try testing.expect(h.fake.unit(0).running);
}

test "the backend does not exist without the frameworks or the component" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    defer h.fake.deinit();
    h.fake.no_component = true;
    try testing.expectError(error.BackendUnavailable, h.attach(.{}));
    try testing.expectEqual(@as(usize, 0), h.fake.listenerCount());
    if (builtin.os.tag != .macos) {
        const options: Context.Options = .{ .app_name = "test", .backend = .coreaudio };
        try testing.expectError(error.BackendUnavailable, Context.init(testing.allocator, testing.io, options));
    }
}

test "the automatic order tries CoreAudio first on macOS" {
    if (builtin.os.tag == .macos) {
        try testing.expectEqualSlices(Backend.Kind, &.{ .coreaudio, .null }, Backend.order);
    }
    try testing.expectEqual(Backend.coreaudio_enabled, Backend.compiled(.coreaudio));
}

test "stop returns after the render callback has left" {
    if (comptime !usable or !threaded) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{ .release = .init(0) };
    const s = try h.open(.playback, &tone);
    try s.start();
    const Pump = struct {
        fn run(unit: *Fake.Unit) void {
            var buf: [64 * 8]u8 = undefined;
            _ = unit.callRender(&buf);
        }
    };
    const pump = try std.Thread.spawn(.{}, Pump.run, .{h.fake.unit(0)});
    while (tone.entered.load(.acquire) == 0) std.atomic.spinLoopHint();
    const Stopper = struct {
        stream: *Stream,
        tone: *Tone,
        begun: std.atomic.Value(u32) = .init(0),
        calls_at_return: u32 = 0,

        fn run(self: *@This()) void {
            self.begun.store(1, .release);
            self.stream.stop();
            self.calls_at_return = self.tone.calls.load(.acquire);
        }
    };
    var stopper: Stopper = .{ .stream = s, .tone = &tone };
    const thread = try std.Thread.spawn(.{}, Stopper.run, .{&stopper});
    while (stopper.begun.load(.acquire) == 0) std.atomic.spinLoopHint();
    try std.Io.sleep(testing.io, .fromMilliseconds(20), .awake);
    tone.release.store(1, .release);
    pump.join();
    thread.join();
    try testing.expectEqual(@as(u32, 1), stopper.calls_at_return);
    try testing.expectEqual(@as(u32, 1), h.fake.count(.stop));
}

test "a default output change reopens a stream that has no device" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.addDevice(.{ .id = 73, .rate = 44100 });
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    _ = try h.ctx.dispatch();
    try testing.expect(!h.backend().wake.pending());
    h.fake.setDefaultOut(73);
    try testing.expect(h.backend().wake.pending());
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    _ = try h.ctx.dispatch();
    try testing.expect(!h.backend().wake.pending());
    try testing.expectEqual(@as(u32, 44100), s.nativeFormat().rate);
    try testing.expectEqual(@as(usize, 1), h.fake.unitCount());
    const u = h.fake.unit(0);
    try testing.expectEqual(@as(ca.AudioObjectID, 73), u.device);
    try testing.expect(u.running);
    try testing.expectEqual(@as(u32, 2), h.fake.count(.component_new));
    try testing.expectEqual(@as(u32, 2), h.fake.count(.start));
    try testing.expectEqual(@as(?Backend.Negotiated, null), s.pending_native);
    try testing.expectEqual(@as(f64, 44100), u.client_out.?.mSampleRate);
    try testing.expectEqual(@as(usize, 7), h.fake.objectListenerCount());
    var buf: [64 * 8]u8 = undefined;
    try testing.expectEqual(ca.Status.ok, u.callRender(&buf));
}

test "a default change to a device with the same format keeps the pipeline" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.addDevice(.{ .id = 73 });
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    const before = s.negotiated;
    try s.start();
    h.fake.setDefaultOut(73);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(before.native.rate, s.negotiated.native.rate);
    try testing.expectEqual(@as(?Backend.Negotiated, null), s.pending_native);
    try testing.expectEqual(@as(ca.AudioObjectID, 73), h.fake.unit(0).device);
    try testing.expect(h.fake.unit(0).running);
    try testing.expectEqual(Stream.State.running, s.state());
    var buf: [48 * 8]u8 = undefined;
    _ = h.fake.unit(0).callRender(&buf);
    try expectSamples(&buf, 0.25);
}

test "an idle stream reopens on the new default and stays idle" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.addDevice(.{ .id = 73 });
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    h.fake.setDefaultOut(73);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(ca.AudioObjectID, 73), h.fake.unit(0).device);
    try testing.expect(!h.fake.unit(0).running);
    try testing.expectEqual(@as(u32, 0), h.fake.count(.start));
    try s.start();
    try testing.expect(h.fake.unit(0).running);
}

test "a default input change reopens a capture stream with no device" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.addMic();
    h.fake.addDevice(.{ .id = 74, .out_channels = 0, .in_channels = 1, .rate = 44100 });
    var tone: Tone = .{};
    const s = try h.open(.capture, &tone);
    try s.start();
    h.fake.setDefaultOut(71);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 1), h.fake.count(.component_new));
    h.fake.setDefaultIn(74);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 44100), s.nativeFormat().rate);
    const u = h.fake.unit(0);
    try testing.expectEqual(@as(ca.AudioObjectID, 74), u.device);
    try testing.expectEqual(@as(u32, 1), u.enable_in);
    try testing.expect(u.running);
    try testing.expectEqual(ca.Status.ok, u.callInput(32));
}

test "the unit that the HAL moves to the default makes a stream with no device reopen" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.addDevice(.{ .id = 73 });
    h.fake.default_out = 73;
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    try testing.expectEqual(@as(ca.AudioObjectID, 73), h.fake.unit(0).device);
    h.fake.removeDevice(73);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(ca.AudioObjectID, 71), h.fake.unit(0).device);
    try testing.expect(h.fake.unit(0).running);
    try testing.expectEqual(Stream.State.running, s.state());
    try testing.expectEqual(@as(usize, 1), h.fake.unitCount());
    try testing.expectEqual(@as(u32, 2), h.fake.count(.component_new));
}

test "a stream with a device does not follow the default" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.addDevice(.{ .id = 73 });
    var tone: Tone = .{};
    const s = try h.openOn(.playback, &tone, 73);
    try s.start();
    h.fake.setDefaultOut(73);
    h.fake.setDefaultOut(71);
    h.fake.setRate(71, 44100);
    h.fake.device(71).rate = 48000;
    h.fake.setListed(71, true);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 1), h.fake.count(.component_new));
    try testing.expectEqual(@as(ca.AudioObjectID, 73), h.fake.unit(0).device);
    try testing.expectEqual(Stream.State.running, s.state());
}

test "an explicit device that leaves stops the stream and does not move it to the default" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.addDevice(.{ .id = 73 });
    var tone: Tone = .{};
    const s = try h.openOn(.playback, &tone, 73);
    try s.start();
    h.fake.removeDevice(73);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.stopped, s.state());
    try testing.expectEqual(@as(usize, 0), h.fake.unitCount());
    try testing.expectEqual(@as(u32, 1), h.fake.count(.component_new));
    try testing.expectError(error.Disconnected, s.start());
    try testing.expectEqual(@as(u32, 1), h.fake.count(.component_new));
}

test "an explicit device is gone when its unit moves, it dies or dev# drops it" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.addDevice(.{ .id = 73 });
    var tone: Tone = .{};
    const moved = try h.openOn(.playback, &tone, 73);
    try moved.start();
    h.fake.moveUnit(h.fake.unit(0), 71);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.stopped, moved.state());
    try testing.expectEqual(@as(usize, 0), h.fake.unitCount());
    const dead = try h.openOn(.playback, &tone, 73);
    try dead.start();
    h.fake.setAlive(73, false);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.stopped, dead.state());
    h.fake.setAlive(73, true);
    const unlisted = try h.openOn(.playback, &tone, 73);
    try unlisted.start();
    h.fake.setListed(73, false);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.stopped, unlisted.state());
    try testing.expectEqual(@as(usize, 0), h.fake.unitCount());
}

test "an explicit device that stays alive ignores events that name it" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.addDevice(.{ .id = 73 });
    var tone: Tone = .{};
    const s = try h.openOn(.playback, &tone, 73);
    try s.start();
    h.fake.moveUnit(h.fake.unit(0), 73);
    h.fake.setAlive(73, true);
    h.fake.setListed(73, true);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.running, s.state());
    try testing.expectEqual(@as(usize, 1), h.fake.unitCount());
}

test "a rate change of the device reopens the stream with the new rate" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.fake.setRate(71, 44100);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 44100), s.nativeFormat().rate);
    try testing.expect(h.fake.unit(0).running);
    const fixed = try h.openOn(.playback, &tone, 71);
    try fixed.start();
    h.fake.setRate(71, 48000);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 48000), fixed.nativeFormat().rate);
    try testing.expectEqual(@as(u32, 48000), s.nativeFormat().rate);
    try testing.expectEqual(Stream.State.running, fixed.state());
}

test "a failed reopen is tried again and the stream runs when it works" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{ .reopen_retry_ms = 1, .reopen_tries = 5 });
    defer h.deinit();
    h.fake.addDevice(.{ .id = 73 });
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.fake.fail_initialize_times = 2;
    h.fake.setDefaultOut(73);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(usize, 0), h.fake.unitCount());
    try testing.expect(h.ctx.timeoutMs() != null);
    for (0..2000) |_| {
        if (h.fake.unitCount() == 1) break;
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
        _ = try h.ctx.dispatch();
    }
    try testing.expectEqual(@as(usize, 1), h.fake.unitCount());
    try testing.expectEqual(@as(ca.AudioObjectID, 73), h.fake.unit(0).device);
    try testing.expect(h.fake.unit(0).running);
    try testing.expectEqual(Stream.State.running, s.state());
}

test "a stream that cannot reopen stops and starts again on the next default" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{ .reopen_retry_ms = 1, .reopen_tries = 2 });
    defer h.deinit();
    h.fake.addDevice(.{ .id = 73 });
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.fake.fail_initialize_times = 1000;
    h.fake.setDefaultOut(73);
    try h.waitFor(s, .stopped);
    try testing.expectEqual(@as(usize, 0), h.fake.unitCount());
    try testing.expectEqual(@as(?u32, null), h.ctx.timeoutMs());
    h.fake.fail_initialize_times = 0;
    h.fake.setDefaultOut(71);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(usize, 1), h.fake.unitCount());
    try testing.expectEqual(Stream.State.stopped, s.state());
    try s.start();
    try testing.expect(h.fake.unit(0).running);
    try testing.expectEqual(@as(ca.AudioObjectID, 71), h.fake.unit(0).device);
}

test "a start after the reopen gave up opens the unit again" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{ .reopen_retry_ms = 1, .reopen_tries = 0 });
    defer h.deinit();
    h.fake.addDevice(.{ .id = 73 });
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    h.fake.setDefaultOut(0);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(usize, 0), h.fake.unitCount());
    try testing.expectError(error.Disconnected, s.start());
    h.fake.setDefaultOut(73);
    try s.start();
    try testing.expectEqual(@as(ca.AudioObjectID, 73), h.fake.unit(0).device);
    try testing.expect(h.fake.unit(0).running);
}

test "a coreaudiod restart stops every unit and reports a disconnect" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const running = try h.open(.playback, &tone);
    const idle = try h.open(.playback, &tone);
    try running.start();
    h.fake.restartService();
    try testing.expectEqual(Backend.Event.disconnected, try h.ctx.dispatch());
    try testing.expectEqual(@as(usize, 0), h.fake.unitCount());
    try testing.expectEqual(@as(usize, 0), h.fake.listenerCount());
    try testing.expectEqual(@as(u32, 1), h.fake.count(.stop));
    try testing.expectEqual(Stream.State.stopped, running.state());
    try testing.expectEqual(Stream.State.idle, idle.state());
    try testing.expectEqual(@as(usize, 0), h.ctx.mixer().streams().len);
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    try testing.expectError(error.Disconnected, h.open(.playback, &tone));
    try h.ctx.reconnect();
    try testing.expectEqual(@as(usize, 2), h.fake.unitCount());
    try testing.expectEqual(@as(usize, 4 + 3 * 2), h.fake.objectListenerCount());
    try testing.expectEqual(@as(u32, 4), h.fake.count(.component_new));
    try testing.expectEqual(Stream.State.running, running.state());
    var runs: usize = 0;
    for (0..2) |i| {
        if (h.fake.unit(i).running) runs += 1;
    }
    try testing.expectEqual(@as(usize, 1), runs);
}

test "listeners only set bits and wake the pipe, also from another thread" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.addDevice(.{ .id = 73 });
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    const fd = h.ctx.fd().?;
    try testing.expect(fd >= 0);
    _ = try h.ctx.dispatch();
    try testing.expect(!h.backend().wake.pending());
    if (threaded) {
        const Firer = struct {
            fn run(fake: *Fake) void {
                for (0..50) |_| {
                    fake.setDefaultOut(73);
                    fake.setAlive(71, true);
                    fake.setRate(71, 48000);
                    fake.setListed(73, true);
                }
            }
        };
        const thread = try std.Thread.spawn(.{}, Firer.run, .{&h.fake});
        thread.join();
    } else {
        h.fake.setDefaultOut(73);
    }
    try testing.expect(h.backend().wake.pending());
    try testing.expect(h.backend().sys_dirty.load(.acquire) != 0);
    _ = try h.ctx.dispatch();
    // The new unit started, so its listeners ran once more.
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 0), h.backend().sys_dirty.load(.acquire));
    try testing.expect(!h.backend().wake.pending());
    try testing.expectEqual(@as(ca.AudioObjectID, 73), h.fake.unit(0).device);
    try testing.expectEqual(@as(u32, 0), h.fake.violations.load(.monotonic));
}

test "a draining stream stops its unit after the audio has played" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.device(71).fsiz = 64;
    var tone: Tone = .{ .status = .drain };
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .latency_frames = 64 });
    try s.start();
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(?u32, null), h.ctx.timeoutMs());
    try testing.expect(!h.backend().wake.pending());
    var buf: [64 * 8]u8 = undefined;
    _ = h.fake.unit(0).callRender(&buf);
    try testing.expectEqual(Stream.State.draining, s.state());
    // The audio thread woke the app once for the drain.
    try testing.expect(h.backend().wake.pending());
    try testing.expectEqual(@as(?u32, 10), h.ctx.timeoutMs());
    _ = try h.ctx.dispatch();
    const wait = h.ctx.timeoutMs().?;
    try testing.expect(wait >= 1 and wait <= 4);
    try h.waitFor(s, .stopped);
    try testing.expect(!h.fake.unit(0).running);
    try testing.expectEqual(@as(?u32, null), h.ctx.timeoutMs());
    try s.start();
    try testing.expect(h.fake.unit(0).running);
}

test "a user callback that stops the stream stops the unit on the next dispatch" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{ .status = .stop };
    const s = try h.open(.playback, &tone);
    try s.start();
    var buf: [32 * 8]u8 = undefined;
    _ = h.fake.unit(0).callRender(&buf);
    try testing.expectEqual(Stream.State.stopped, s.state());
    try testing.expect(h.fake.unit(0).running);
    // The audio thread woke the app once, and a second callback does not write again.
    try testing.expect(h.backend().wake.pending());
    h.backend().wake.drain();
    _ = h.fake.unit(0).callRender(&buf);
    try testing.expect(!h.backend().wake.pending());
    _ = try h.ctx.dispatch();
    try testing.expect(!h.fake.unit(0).running);
    try testing.expectEqual(@as(u32, 1), h.fake.count(.stop));
}

test "a close stops the unit, removes the listeners and then frees the unit" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    s.close();
    const f = &h.fake;
    const stop = f.position(.stop, 0).?;
    try testing.expect(stop < f.position(.remove_unit_listener, 0).?);
    try testing.expect(f.position(.remove_unit_listener, 1).? < f.position(.uninitialize, 0).?);
    try testing.expect(f.position(.remove_object_listener, 1).? < f.position(.uninitialize, 0).?);
    try testing.expect(f.position(.uninitialize, 0).? < f.position(.dispose, 0).?);
    try testing.expectEqual(@as(usize, 0), f.unitListenerCount());
    try testing.expectEqual(@as(usize, 4), f.objectListenerCount());
    try testing.expectEqual(@as(usize, 0), h.ctx.mixer().streams().len);
}

test "deinit removes the system listeners before the backend is freed" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    try testing.expectEqual(@as(usize, 7), h.fake.objectListenerCount());
    h.ctx.deinit();
    try testing.expectEqual(@as(usize, 0), h.fake.listenerCount());
    try testing.expectEqual(@as(usize, 0), h.fake.unitCount());
    try testing.expectEqual(@as(u32, 0), h.fake.bad_uses);
    try testing.expectEqual(@as(u32, 7), h.fake.count(.remove_object_listener));
    try testing.expectEqual(@as(u32, 2), h.fake.count(.remove_unit_listener));
    h.fake.deinit();
}

test "a unit listener that runs after the stream closed touches only the backend" {
    if (comptime !usable or !threaded) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    _ = try h.ctx.dispatch();
    h.fake.unit_gate.store(1, .release);
    const Firer = struct {
        fn run(fake: *Fake, unit: *Fake.Unit) void {
            fake.moveUnit(unit, 71);
        }
    };
    const thread = try std.Thread.spawn(.{}, Firer.run, .{ &h.fake, h.fake.unit(0) });
    while (h.fake.unit_gate_entered.load(.acquire) == 0) std.atomic.spinLoopHint();
    // The removal of a unit listener does not wait, so the entry is freed while the call is on its way.
    s.close();
    try testing.expectEqual(@as(usize, 0), h.fake.unitListenerCount());
    h.fake.unit_gate.store(0, .release);
    thread.join();
    try testing.expect(h.backend().sys_dirty.load(.acquire) != 0);
    _ = try h.ctx.dispatch();
}

test "deinit waits for a unit listener call that runs" {
    if (comptime !usable or !threaded) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    const backend = h.backend();
    backend.unit_calls.store(1, .release);
    const Closer = struct {
        fn run(ctx: *Context, done: *std.atomic.Value(u32)) void {
            ctx.deinit();
            done.store(1, .release);
        }
    };
    var done: std.atomic.Value(u32) = .init(0);
    const thread = try std.Thread.spawn(.{}, Closer.run, .{ h.ctx, &done });
    try std.Io.sleep(testing.io, .fromMilliseconds(30), .awake);
    try testing.expectEqual(@as(u32, 0), done.load(.acquire));
    backend.unit_calls.store(0, .release);
    thread.join();
    try testing.expectEqual(@as(u32, 1), done.load(.acquire));
    h.fake.deinit();
}

test "a reopen whose start fails frees the unit, retries and gives up" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{ .reopen_retry_ms = 1, .reopen_tries = 2 });
    defer h.deinit();
    h.fake.addDevice(.{ .id = 73 });
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.fake.fail_start = ca.Status.unspecified;
    h.fake.setDefaultOut(73);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(usize, 0), h.fake.unitCount());
    try testing.expect(h.ctx.timeoutMs() != null);
    try h.waitFor(s, .stopped);
    try testing.expectEqual(@as(usize, 0), h.fake.unitCount());
    try testing.expectEqual(@as(?u32, null), h.ctx.timeoutMs());
    h.fake.fail_start = null;
    try s.start();
    try testing.expect(h.fake.unit(0).running);
    try testing.expectEqual(@as(ca.AudioObjectID, 73), h.fake.unit(0).device);
}

test "the drain lasts for the latency of the device" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const device = h.fake.device(71);
    device.fsiz = 64;
    device.latency = 4800;
    device.safety = 480;
    device.stream_latency = 480;
    var tone: Tone = .{ .status = .drain };
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .latency_frames = 64 });
    try s.start();
    var buf: [64 * 8]u8 = undefined;
    _ = h.fake.unit(0).callRender(&buf);
    _ = try h.ctx.dispatch();
    // 64 + 5760 + 64 frames at 48000 Hz is 123 ms.
    const wait = h.ctx.timeoutMs().?;
    try testing.expect(wait >= 100 and wait <= 123);
    try testing.expectEqual(Stream.State.draining, s.state());
    try testing.expect(h.fake.unit(0).running);
}

test "overloads of the device count as xruns" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.fake.setOverload(71);
    h.fake.setOverload(71);
    h.fake.setOverload(71);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u64, 3), s.stats().xruns);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u64, 3), s.stats().xruns);
}

test "start and stop run the IsRunning listeners and change nothing else" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    _ = try h.ctx.dispatch();
    try s.start();
    try testing.expect(h.backend().wake.pending());
    _ = try h.ctx.dispatch();
    s.stop();
    try testing.expect(h.backend().wake.pending());
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 1), h.fake.count(.component_new));
    try testing.expectEqual(Stream.State.stopped, s.state());
}

test "auto falls back to the null backend when CoreAudio has no component" {
    if (comptime !usable) return error.SkipZigTest;
    if (!Backend.coreaudio_enabled) return error.SkipZigTest;
    var fake: Fake = .init(testing.allocator);
    defer fake.deinit();
    fake.no_component = true;
    const ctx = try Context.init(testing.allocator, testing.io, .{ .app_name = "test", .coreaudio_backend = .{ .api = fake.binding() } });
    defer ctx.deinit();
    try testing.expectEqual(Backend.Kind.null, ctx.info().backend);
}

test "a start while draining makes the next drain wake the app and last in full" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.device(71).fsiz = 64;
    h.fake.device(71).latency = 4800;
    var tone: Tone = .{ .status = .drain };
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .latency_frames = 64 });
    try s.start();
    _ = try h.ctx.dispatch();
    var buf: [64 * 8]u8 = undefined;
    _ = h.fake.unit(0).callRender(&buf);
    try testing.expect(h.backend().wake.pending());
    _ = try h.ctx.dispatch();
    // The start gives no backend call, so only the audio thread can tell the app about the next drain.
    try s.start();
    try testing.expectEqual(@as(?u32, null), h.ctx.timeoutMs());
    _ = h.fake.unit(0).callRender(&buf);
    try testing.expectEqual(Stream.State.draining, s.state());
    try testing.expect(h.backend().wake.pending());
    _ = try h.ctx.dispatch();
    const wait = h.ctx.timeoutMs().?;
    try testing.expect(wait >= 50 and wait <= 123);
}

test "a second drain does not end at the deadline of the first" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.device(71).fsiz = 64;
    h.fake.device(71).latency = 4800;
    var tone: Tone = .{ .status = .drain };
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .latency_frames = 64 });
    try s.start();
    _ = try h.ctx.dispatch();
    var buf: [64 * 8]u8 = undefined;
    _ = h.fake.unit(0).callRender(&buf);
    _ = try h.ctx.dispatch();
    const first = h.ctx.timeoutMs().?;
    try std.Io.sleep(testing.io, .fromMilliseconds(first - 5), .awake);
    tone.status = .@"continue";
    try s.start();
    _ = h.fake.unit(0).callRender(&buf);
    tone.status = .drain;
    try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    _ = h.fake.unit(0).callRender(&buf);
    try testing.expectEqual(Stream.State.draining, s.state());
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.draining, s.state());
    try testing.expect(h.fake.unit(0).running);
    try testing.expect(h.ctx.timeoutMs().? > 50);
}

test "stream ids never equal endpoint ids" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.addDevice(.{ .id = 2, .in_channels = 2, .name = "Other", .uid = "other-device" });
    h.fake.setListed(2, true);
    _ = try h.ctx.dispatch();
    var tone: Tone = .{};
    for (0..4) |_| _ = try h.open(.playback, &tone);
    try testing.expectEqual(@as(usize, 4), h.ctx.mixer().streams().len);
    try testing.expect(h.ctx.mixer().endpoint(map.endpointId(2, false).?) != null);
    for (h.ctx.mixer().streams()) |app| {
        for (h.ctx.mixer().endpoints()) |end| try testing.expect(app.id != end.id);
    }
    try testing.expectEqual(@as(?Mixer.Id, null), map.endpointId(1 << 30, false));
}

test "a default change moves the endpoint of the Mixer stream" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.addDevice(.{ .id = 73 });
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    _ = try h.ctx.dispatch();
    try testing.expectEqual(map.endpointId(71, false).?, h.ctx.mixer().streams()[0].endpoint.?);
    h.fake.setDefaultOut(73);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(map.endpointId(73, false).?, h.ctx.mixer().streams()[0].endpoint.?);
}

test "a failed read of the unit device keeps an explicit stream" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.addDevice(.{ .id = 73 });
    var tone: Tone = .{};
    const s = try h.openOn(.playback, &tone, 73);
    try s.start();
    h.fake.fail_current_device = true;
    s.stop();
    try s.start();
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.running, s.state());
    try testing.expectEqual(@as(usize, 1), h.fake.unitCount());
}

test "a failed read of the unit device does not make a default stream reopen again and again" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.fake.fail_current_device = true;
    s.stop();
    try s.start();
    for (0..3) |_| _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.running, s.state());
    try testing.expectEqual(@as(u32, 1), h.fake.count(.component_new));
}

test "a scan that cannot read dev# runs again" {
    if (comptime !usable) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const sink = map.endpointId(71, false).?;
    try testing.expect(h.ctx.mixer().endpoint(sink) != null);
    h.fake.fail_devices_reads = 1;
    h.fake.setListed(71, false);
    _ = try h.ctx.dispatch();
    try testing.expect(h.ctx.mixer().endpoint(sink) != null);
    try testing.expect(h.backend().wake.pending());
    _ = try h.ctx.dispatch();
    try testing.expect(h.ctx.mixer().endpoint(sink) == null);
}
