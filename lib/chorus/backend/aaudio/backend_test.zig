//! Tests of the AAudio backend with the fake AAudio and the fake JNIEnv.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Format = @import("../../Format.zig");
const Mixer = @import("../../Mixer.zig");
const Stream = @import("../../Stream.zig");
const Context = @import("../../Context.zig");
const Backend = @import("../Backend.zig");
const AAudio = @import("../AAudio.zig");
const aaudio = @import("api.zig");
pub const fakes = @import("fake.zig");
const Fake = fakes.Fake;
const fake_jni = @import("fake_jni.zig");
const map = @import("map.zig");
const audio_manager = @import("devices.zig");
const java = @import("jni.zig");
const create = AAudio.create;
const Options = AAudio.Options;
const testing = std.testing;
pub const on_linux = builtin.os.tag == .linux;

/// Options that give up after the first failed reopen.
pub const no_retry: AAudio.Options = .{ .reopen_retry_ms = 1, .reopen_give_up_ms = 1 };

pub const stereo: Format = .{ .sample = .f32, .rate = 48000, .channels = .stereo };

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

    pub fn run(ctx: ?*anyopaque, stream: *Stream, buffer: Stream.Buffer) Stream.Status {
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
    world: fake_jni.Fake,
    ctx: *Context,

    pub fn begin(self: *Harness) void {
        self.fake.init(testing.allocator);
        self.world.init(testing.allocator);
    }

    /// Options that give the backend the fake JavaVM and Context.
    pub fn jni(self: *Harness, options: Options) Options {
        var opts = options;
        opts.java_vm = self.world.vm();
        opts.android_context = self.world.contextObject();
        return opts;
    }

    pub fn attach(self: *Harness, options: Options) !void {
        var opts = options;
        opts.api = &self.fake.table;
        self.ctx = try Context.init(testing.allocator, testing.io, .{ .app_name = "test", .backend = .null });
        errdefer self.ctx.deinit();
        const next = try create(.{
            .gpa = testing.allocator,
            .io = testing.io,
            .mixer = &self.ctx.mixer_state,
            .app_name = self.ctx.app_name,
        }, opts);
        self.ctx.backend.deinit();
        self.ctx.backend = next;
        self.ctx.mixer_state.backend = next;
    }

    pub fn init(self: *Harness, options: Options) !void {
        self.begin();
        errdefer {
            self.world.deinit();
            self.fake.deinit();
        }
        try self.attach(options);
    }

    pub fn deinit(self: *Harness) void {
        self.ctx.deinit();
        const leaked = self.world.dirty();
        self.world.deinit();
        self.fake.deinit();
        if (leaked) @panic("the backend left a JNI reference, frame, exception or misuse behind");
    }

    pub fn backend(self: *Harness) *AAudio {
        return self.ctx.backend.as(AAudio).?;
    }

    pub fn open(self: *Harness, direction: Stream.Direction, tone: *Tone) !*Stream {
        return self.ctx.openStream(.{ .direction = direction, .format = stereo, .callback = tone.callback() });
    }
};

pub fn readable(fd: i32, timeout_ms: i32) bool {
    var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    return linux.poll(&pfd, 1, timeout_ms) == 1;
}

pub fn expectSamples(bytes: []const u8, value: f32) !void {
    for (std.mem.bytesAsSlice(f32, bytes)) |v| try testing.expectEqual(value, v);
}

pub fn wakeCount(be: *AAudio) u64 {
    var count: u64 = 0;
    const rc = linux.read(be.wake_fd, std.mem.asBytes(&count), 8);
    return if (linux.errno(rc) == .SUCCESS) count else 0;
}

const Counter = struct {
    count: usize = 0,

    fn listener(self: *Counter) Mixer.Listener {
        return .{ .ctx = self, .func = record };
    }

    fn record(ctx: ?*anyopaque, mixer: *const Mixer, change: Mixer.Change) void {
        _ = mixer;
        _ = change;
        const self: *Counter = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
    }
};

const usb_id = 22;
const speaker_id = 14;
const mic_id = 9;

fn addDevices(h: *Harness) void {
    h.world.addDevice(.{ .id = usb_id, .type = aaudio.DeviceType.usb_headset, .name = "USB Audio", .sink = true });
    h.world.addDevice(.{ .id = speaker_id, .type = aaudio.DeviceType.builtin_speaker, .name = "Speaker", .sink = true });
    h.world.addDevice(.{ .id = mic_id, .type = aaudio.DeviceType.builtin_mic, .name = "Mic", .source = true });
}

fn initWorld(h: *Harness, options: Options) !void {
    h.begin();
    addDevices(h);
    try h.attach(h.jni(options));
}

fn endpointNamed(mixer: *const Mixer, name: []const u8) ?*const Mixer.Endpoint {
    for (mixer.endpoints()) |*ep| {
        if (std.mem.eql(u8, ep.name, name)) return ep;
    }
    return null;
}

fn idOf(mixer: *const Mixer, name: []const u8) Mixer.Id {
    return endpointNamed(mixer, name).?.id;
}

test "a scan adds an endpoint for each device with its name and description" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    const mixer = h.ctx.mixer();
    try testing.expectEqual(@as(usize, 3), mixer.endpoints().len);
    try testing.expectEqual(@as(usize, 3), h.backend().devices.items.len);
    try testing.expectEqual(@as(u32, 1), h.world.get_devices_calls);
    try testing.expect(endpointNamed(mixer, "default") == null);
    const speaker = endpointNamed(mixer, "builtin_speaker:14").?;
    try testing.expectEqualStrings("Speaker", speaker.description);
    try testing.expectEqual(Mixer.Kind.sink, speaker.kind);
    const usb = endpointNamed(mixer, "usb_headset:22").?;
    try testing.expectEqualStrings("USB Audio", usb.description);
    try testing.expectEqual(Mixer.Kind.sink, usb.kind);
    const mic = endpointNamed(mixer, "builtin_mic:9").?;
    try testing.expectEqualStrings("Mic", mic.description);
    try testing.expectEqual(Mixer.Kind.source, mic.kind);
}

test "the default sink is the speaker and the default source is the microphone" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    const mixer = h.ctx.mixer();
    try testing.expectEqual(@as(?Mixer.Id, idOf(mixer, "builtin_speaker:14")), mixer.default(.sink));
    try testing.expectEqual(@as(?Mixer.Id, idOf(mixer, "builtin_mic:9")), mixer.default(.source));
}

test "the first device of a kind is the default when there is no built in one" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.world.addDevice(.{ .id = 40, .type = aaudio.DeviceType.hdmi, .name = "TV", .sink = true });
    h.world.addDevice(.{ .id = 41, .type = aaudio.DeviceType.usb_device, .name = "Interface", .sink = true, .source = true });
    try h.attach(h.jni(.{}));
    defer h.deinit();
    const mixer = h.ctx.mixer();
    try testing.expectEqual(@as(usize, 3), mixer.endpoints().len);
    try testing.expectEqual(@as(?Mixer.Id, idOf(mixer, "hdmi:40")), mixer.default(.sink));
    const source = mixer.default(.source).?;
    try testing.expectEqual(Mixer.Kind.source, mixer.endpoint(source).?.kind);
    try testing.expectEqualStrings("usb_device:41", mixer.endpoint(source).?.name);
}

test "the route of API 33 chooses the default sink" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    addDevices(&h);
    h.world.has_route_api = true;
    h.world.route = usb_id;
    try h.attach(h.jni(.{}));
    defer h.deinit();
    const mixer = h.ctx.mixer();
    try testing.expectEqual(@as(?Mixer.Id, idOf(mixer, "usb_headset:22")), mixer.default(.sink));
    h.world.addDevice(.{ .id = 99, .type = aaudio.DeviceType.hdmi, .name = "Hidden", .sink = true, .hidden = true });
    h.world.route = 99;
    try h.backend().scan();
    try testing.expectEqual(@as(?Mixer.Id, idOf(mixer, "builtin_speaker:14")), mixer.default(.sink));
    h.world.route = usb_id;
    try h.backend().scan();
    try testing.expectEqual(@as(?Mixer.Id, idOf(mixer, "usb_headset:22")), mixer.default(.sink));
    h.world.route = null;
    try h.backend().scan();
    try testing.expectEqual(@as(?Mixer.Id, idOf(mixer, "builtin_speaker:14")), mixer.default(.sink));
}

test "a second scan changes nothing" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    const mixer = h.ctx.mixer();
    const before = idOf(mixer, "builtin_speaker:14");
    var counter: Counter = .{};
    try mixer.listen(counter.listener());
    try h.backend().scan();
    try h.backend().scan();
    try testing.expectEqual(@as(usize, 0), counter.count);
    try testing.expectEqual(before, idOf(mixer, "builtin_speaker:14"));
    try testing.expectEqual(@as(usize, 3), mixer.endpoints().len);
}

test "a removed device leaves the Mixer and the table" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    const mixer = h.ctx.mixer();
    const usb = idOf(mixer, "usb_headset:22");
    h.world.removeDevice(usb_id);
    try h.backend().scan();
    try testing.expect(mixer.endpoint(usb) == null);
    try testing.expectEqual(@as(usize, 2), mixer.endpoints().len);
    try testing.expectEqual(@as(usize, 2), h.backend().devices.items.len);
    h.world.removeDevice(speaker_id);
    try h.backend().scan();
    try testing.expectEqual(@as(usize, 2), mixer.endpoints().len);
    const sink = mixer.default(.sink).?;
    try testing.expectEqualStrings("default", mixer.endpoint(sink).?.name);
    try testing.expectEqualStrings("Default output", mixer.endpoint(sink).?.description);
    try testing.expectEqual(aaudio.unspecified, h.backend().devices.items[1].android_id);
    h.world.addDevice(.{ .id = 31, .type = aaudio.DeviceType.wired_headset, .name = "Headset", .sink = true });
    try h.backend().scan();
    try testing.expectEqual(@as(usize, 2), mixer.endpoints().len);
    try testing.expectEqual(@as(?Mixer.Id, idOf(mixer, "wired_headset:31")), mixer.default(.sink));
    try testing.expect(mixer.endpoint(sink) == null);
}

test "the default sink carries the volume of the music stream" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    const mixer = h.ctx.mixer();
    const speaker = mixer.endpoint(idOf(mixer, "builtin_speaker:14")).?;
    try testing.expectEqual(@as(u8, 1), speaker.volume.count);
    try testing.expectEqual(@as(f32, 0.125), speaker.volume.values[0]);
    try testing.expectApproxEqAbs(@as(f32, 0.5), Mixer.linearToCubic(speaker.volume.values[0]), 1e-6);
    try testing.expect(!speaker.mute);
    try testing.expectEqual(@as(u8, 0), endpointNamed(mixer, "usb_headset:22").?.volume.count);
    try testing.expectEqual(@as(u8, 0), endpointNamed(mixer, "builtin_mic:9").?.volume.count);
    h.world.volume = 14;
    h.world.muted = true;
    try h.backend().scan();
    const loud = mixer.endpoint(idOf(mixer, "builtin_speaker:14")).?;
    try testing.expectEqual(@as(f32, 1), loud.volume.values[0]);
    try testing.expect(loud.mute);
    try testing.expectEqual(@as(u32, 0), h.world.set_volume_calls);
}

test "the volume moves to the new default sink" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    addDevices(&h);
    h.world.has_route_api = true;
    h.world.route = speaker_id;
    try h.attach(h.jni(.{}));
    defer h.deinit();
    const mixer = h.ctx.mixer();
    h.world.route = usb_id;
    try h.backend().scan();
    try testing.expectEqual(@as(u8, 1), endpointNamed(mixer, "usb_headset:22").?.volume.count);
    try testing.expectEqual(@as(u8, 0), endpointNamed(mixer, "builtin_speaker:14").?.volume.count);
}

test "setVolume writes the index of the music stream" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    const mixer = h.ctx.mixer();
    const sink = mixer.default(.sink).?;
    try mixer.setVolume(.{ .endpoint = sink }, .{ .channels = &.{Mixer.cubicToLinear(0.5)} });
    try testing.expectEqual(@as(i32, 7), h.world.last_volume_index);
    try testing.expectEqual(@as(i32, 0), h.world.last_volume_flags);
    try testing.expectEqual(@as(u32, 1), h.world.set_volume_calls);
    try mixer.setVolume(.{ .endpoint = sink }, .{ .channels = &.{Mixer.cubicToLinear(0.3)} });
    try testing.expectEqual(@as(i32, 4), h.world.last_volume_index);
    try testing.expectEqual(@as(f32, Mixer.cubicToLinear(4.0 / 14.0)), mixer.endpoint(sink).?.volume.values[0]);
    try mixer.setVolume(.{ .endpoint = sink }, .{ .channels = &.{1} });
    try testing.expectEqual(@as(i32, 14), h.world.last_volume_index);
    try mixer.setVolume(.{ .endpoint = sink }, .{ .channels = &.{Mixer.max_volume} });
    try testing.expectEqual(@as(i32, 14), h.world.last_volume_index);
    try mixer.setVolume(.{ .endpoint = sink }, .{ .channels = &.{0} });
    try testing.expectEqual(@as(i32, 0), h.world.last_volume_index);
    try testing.expectEqual(@as(f32, 0), mixer.endpoint(sink).?.volume.values[0]);
}

test "setMute adjusts the music stream" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    const mixer = h.ctx.mixer();
    const sink = mixer.default(.sink).?;
    try mixer.setMute(.{ .endpoint = sink }, true);
    try testing.expect(h.world.muted);
    try testing.expectEqual(@as(i32, -100), h.world.last_adjust);
    try testing.expectEqual(@as(i32, 0), h.world.last_volume_flags);
    try testing.expect(mixer.endpoint(sink).?.mute);
    try testing.expectEqual(@as(f32, 0.125), mixer.endpoint(sink).?.volume.values[0]);
    try mixer.setMute(.{ .endpoint = sink }, false);
    try testing.expect(!h.world.muted);
    try testing.expectEqual(@as(i32, 100), h.world.last_adjust);
    try testing.expect(!mixer.endpoint(sink).?.mute);
    try testing.expectEqual(@as(u32, 2), h.world.adjust_calls);
}

test "a fixed volume refuses the set calls" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    h.world.fixed = true;
    const mixer = h.ctx.mixer();
    const sink = mixer.default(.sink).?;
    try testing.expectError(error.Unsupported, mixer.setVolume(.{ .endpoint = sink }, .{ .channels = &.{0.5} }));
    try testing.expectError(error.Unsupported, mixer.setMute(.{ .endpoint = sink }, true));
    try testing.expectEqual(@as(u32, 0), h.world.set_volume_calls);
    try testing.expectEqual(@as(u32, 0), h.world.adjust_calls);
    try testing.expectEqual(@as(u8, 1), mixer.endpoint(sink).?.volume.count);
}

test "a Java exception while setting the volume gives Unsupported" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    const mixer = h.ctx.mixer();
    const sink = mixer.default(.sink).?;
    h.world.throw_on = .set_stream_volume;
    try testing.expectError(error.Unsupported, mixer.setVolume(.{ .endpoint = sink }, .{ .channels = &.{0.5} }));
    h.world.throw_on = .adjust_stream_volume;
    try testing.expectError(error.Unsupported, mixer.setMute(.{ .endpoint = sink }, true));
    try testing.expect(!h.world.pending);
}

test "only the default sink has a volume" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    const mixer = h.ctx.mixer();
    const usb = idOf(mixer, "usb_headset:22");
    const mic = idOf(mixer, "builtin_mic:9");
    try testing.expectError(error.Unsupported, mixer.setVolume(.{ .endpoint = usb }, .{ .channels = &.{0.5} }));
    try testing.expectError(error.Unsupported, mixer.setVolume(.{ .endpoint = mic }, .{ .channels = &.{0.5} }));
    try testing.expectError(error.Unsupported, mixer.setMute(.{ .endpoint = usb }, true));
    try testing.expectError(error.Unsupported, h.ctx.backend.setMute(.{ .endpoint = mic }, true));
    try testing.expectError(error.Unsupported, h.ctx.backend.setVolume(.{ .stream = usb }, &.{0.5}));
    try testing.expectEqual(@as(u32, 0), h.world.set_volume_calls);
    try testing.expectEqual(@as(u32, 0), h.world.adjust_calls);
}

test "a Java exception in a scan is cleared and the old table stays" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    addDevices(&h);
    h.world.has_route_api = true;
    h.world.route = speaker_id;
    try h.attach(h.jni(.{}));
    defer h.deinit();
    const mixer = h.ctx.mixer();
    const speaker = idOf(mixer, "builtin_speaker:14");
    h.world.removeDevice(usb_id);
    const methods = [_]fake_jni.Method{
        .get_devices,
        .device_id,
        .device_type,
        .is_sink,
        .is_source,
        .product_name,
        .to_string,
        .get_audio_devices_for_attributes,
        .list_size,
        .list_get,
        .get_stream_volume,
        .get_stream_max_volume,
        .is_stream_mute,
    };
    for (methods) |method| {
        h.world.throw_on = method;
        const throws = h.world.throws;
        try testing.expectError(error.JavaException, h.backend().scan());
        try testing.expectEqual(throws + 1, h.world.throws);
        try testing.expect(!h.world.pending);
        try testing.expectEqual(@as(usize, 0), h.world.localsLive());
        try testing.expectEqual(@as(usize, 0), h.world.frameDepth());
        try testing.expectEqual(@as(usize, 3), mixer.endpoints().len);
        try testing.expectEqual(@as(usize, 3), h.backend().devices.items.len);
    }
    h.world.throw_on = null;
    try h.backend().scan();
    try testing.expectEqual(@as(usize, 2), mixer.endpoints().len);
    try testing.expectEqual(speaker, idOf(mixer, "builtin_speaker:14"));
}

test "dispatch counts a failed scan once and tries again later" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    const be = h.backend();
    h.world.removeDevice(usb_id);
    h.world.throw_on = .get_devices;
    be.next_scan_ns = 0;
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    try testing.expectEqual(@as(u32, 1), be.scan_errors);
    try testing.expectEqual(@as(usize, 3), h.ctx.mixer().endpoints().len);
    h.world.throw_on = null;
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    try testing.expectEqual(@as(u32, 1), h.world.get_devices_calls);
    be.next_scan_ns = 0;
    try testing.expectEqual(Backend.Event.none, try h.ctx.dispatch());
    try testing.expectEqual(@as(u32, 2), h.world.get_devices_calls);
    try testing.expectEqual(@as(u32, 1), be.scan_errors);
    try testing.expectEqual(@as(usize, 2), h.ctx.mixer().endpoints().len);
}

test "a failed first scan keeps the default endpoints until a scan works" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    addDevices(&h);
    h.world.throw_on = .get_devices;
    try h.attach(h.jni(.{}));
    defer h.deinit();
    const be = h.backend();
    const mixer = h.ctx.mixer();
    try testing.expectEqual(@as(u32, 1), be.scan_errors);
    try testing.expectEqual(@as(usize, 2), mixer.endpoints().len);
    try testing.expect(mixer.default(.sink) != null);
    h.world.throw_on = null;
    be.next_scan_ns = 0;
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(usize, 3), mixer.endpoints().len);
    try testing.expectEqual(@as(u32, 1), be.scan_errors);
}

test "a failed JNI setup leaves the default endpoints" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    addDevices(&h);
    h.world.throw_on = .get_system_service;
    try h.attach(h.jni(.{}));
    defer h.deinit();
    try testing.expect(h.backend().view == null);
    try testing.expectEqual(@as(usize, 2), h.ctx.mixer().endpoints().len);
    try testing.expect(!h.ctx.backend.capabilities().endpoint_volume);
}

test "capture without the record permission gives PermissionDenied" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    var tone: Tone = .{};
    h.world.permission = &.{-1};
    try testing.expectError(error.PermissionDenied, h.open(.capture, &tone));
    try testing.expectEqual(@as(u32, 0), h.fake.counts.opens);
    try testing.expectEqual(@as(usize, 0), h.ctx.mixer().streams().len);
    _ = try h.open(.playback, &tone);
    h.world.permission = &.{0};
    _ = try h.open(.capture, &tone);
    try testing.expectEqual(@as(u32, 2), h.fake.counts.opens);
}

test "an INTERNAL open error is a denial only when the check says denied" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    var tone: Tone = .{};
    h.fake.failOpens(aaudio.ResultCode.internal, std.math.maxInt(u32));
    h.world.permission = &.{ 0, -1 };
    try testing.expectError(error.PermissionDenied, h.open(.capture, &tone));
    try testing.expectEqual(@as(u32, 2), h.world.permission_calls);
    h.world.permission = &.{0};
    h.world.permission_calls = 0;
    try testing.expectError(error.Disconnected, h.open(.capture, &tone));
    h.world.permission = &.{ 0, -1 };
    h.world.permission_calls = 0;
    try testing.expectError(error.Disconnected, h.open(.playback, &tone));
    try testing.expectEqual(@as(u32, 0), h.world.permission_calls);
}

test "a scan leaves no local reference" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    addDevices(&h);
    h.world.has_route_api = true;
    h.world.route = usb_id;
    try h.attach(h.jni(.{}));
    defer h.deinit();
    const globals = h.world.globalsLive();
    try testing.expectEqual(@as(usize, 4), globals);
    for (0..4) |_| {
        try h.backend().scan();
        try testing.expectEqual(@as(usize, 0), h.world.localsLive());
        try testing.expectEqual(@as(usize, 0), h.world.frameDepth());
        try testing.expectEqual(globals, h.world.globalsLive());
    }
    try h.ctx.mixer().setVolume(.{ .endpoint = h.ctx.mixer().default(.sink).? }, .{ .channels = &.{0.5} });
    try h.ctx.mixer().setMute(.{ .endpoint = h.ctx.mixer().default(.sink).? }, true);
    var tone: Tone = .{};
    _ = try h.open(.capture, &tone);
    try testing.expectEqual(@as(usize, 0), h.world.localsLive());
    try testing.expectEqual(@as(usize, 0), h.world.frameDepth());
}

test "without a JavaVM or a Context the Mixer has only the default endpoints" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    addDevices(&h);
    h.world.permission = &.{-1};
    try h.attach(.{ .java_vm = h.world.vm(), .poll_ms = 10 });
    defer h.deinit();
    const mixer = h.ctx.mixer();
    try testing.expect(h.backend().view == null);
    try testing.expectEqual(@as(usize, 2), mixer.endpoints().len);
    for (mixer.endpoints()) |ep| try testing.expectEqual(@as(u8, 0), ep.volume.count);
    try testing.expect(mixer.default(.sink) != null);
    try testing.expect(mixer.default(.source) != null);
    try testing.expect(!h.ctx.backend.capabilities().endpoint_volume);
    try testing.expectError(error.Unsupported, mixer.setVolume(.{ .endpoint = mixer.default(.sink).? }, .{ .channels = &.{0.5} }));
    try testing.expect(!readable(h.ctx.fd().?, 50));
    try testing.expectEqual(@as(u32, 0), h.world.get_devices_calls);
    var tone: Tone = .{};
    _ = try h.open(.capture, &tone);
    try testing.expectEqual(@as(u32, 0), h.world.permission_calls);
}

test "streams use the devices of a scan" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    const mixer = h.ctx.mixer();
    var tone: Tone = .{};
    const usb = idOf(mixer, "usb_headset:22");
    const speaker = idOf(mixer, "builtin_speaker:14");
    const mic = idOf(mixer, "builtin_mic:9");
    _ = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .device = usb });
    try testing.expectEqual(@as(i32, usb_id), h.fake.last.device);
    _ = try h.ctx.openStream(.{ .direction = .capture, .format = stereo, .callback = tone.callback(), .device = mic });
    try testing.expectEqual(@as(i32, mic_id), h.fake.last.device);
    const free = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback() });
    try free.start();
    try testing.expectEqual(aaudio.unspecified, h.fake.last.device);
    try testing.expectEqual(@as(?Mixer.Id, speaker), mixer.streams()[2].endpoint);
    try mixer.moveStream(mixer.streams()[2].id, usb);
    try testing.expectEqual(@as(i32, usb_id), h.fake.last.device);
    try testing.expectEqual(@as(?Mixer.Id, usb), mixer.streams()[2].endpoint);
    try testing.expectError(error.UnknownObject, mixer.moveStream(mixer.streams()[2].id, mic));
}

test "a stream on the default follows the default and a stream on a gone device falls back" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    addDevices(&h);
    h.world.has_route_api = true;
    h.world.route = speaker_id;
    try h.attach(h.jni(.{}));
    defer h.deinit();
    const mixer = h.ctx.mixer();
    var tone: Tone = .{};
    const free = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback() });
    _ = free;
    const pinned = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .callback = tone.callback(), .device = idOf(mixer, "usb_headset:22") });
    _ = pinned;
    try testing.expectEqual(@as(?Mixer.Id, idOf(mixer, "builtin_speaker:14")), mixer.streams()[0].endpoint);
    h.world.route = usb_id;
    try h.backend().scan();
    try testing.expectEqual(@as(?Mixer.Id, idOf(mixer, "usb_headset:22")), mixer.streams()[0].endpoint);
    h.world.removeDevice(usb_id);
    h.world.route = null;
    try h.backend().scan();
    try testing.expectEqual(@as(?Mixer.Id, idOf(mixer, "builtin_speaker:14")), mixer.streams()[0].endpoint);
    try testing.expectEqual(@as(?Mixer.Id, idOf(mixer, "builtin_speaker:14")), mixer.streams()[1].endpoint);
}

test "the timer scans the devices at the poll time" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{ .poll_ms = 20 });
    defer h.deinit();
    const fd = h.ctx.fd().?;
    h.world.addDevice(.{ .id = 31, .type = aaudio.DeviceType.wired_headset, .name = "Headset", .sink = true });
    try testing.expect(readable(fd, 5000));
    _ = try h.ctx.dispatch();
    try testing.expect(endpointNamed(h.ctx.mixer(), "wired_headset:31") != null);
    try testing.expectEqual(@as(u32, 2), h.world.get_devices_calls);
}

test "a drain tick does not scan and the timer keeps the shorter time" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{ .poll_ms = 100000 });
    defer h.deinit();
    const be = h.backend();
    try testing.expectEqual(@as(u32, 100000), be.timer_ms);
    try expectTimer(be, 100, 0);
    h.fake.hold_stopping = true;
    var tone: Tone = .{ .status = .drain };
    const s = try h.open(.playback, &tone);
    try s.start();
    var buf: [64 * 8]u8 = undefined;
    _ = h.fake.live()[0].callOnce(&buf);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 10), be.timer_ms);
    try expectTimer(be, 0, 10);
    try testing.expect(readable(h.ctx.fd().?, 5000));
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 1), h.world.get_devices_calls);
    h.fake.live()[0].completeStop();
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.stopped, s.state());
    try testing.expectEqual(@as(u32, 100000), be.timer_ms);
    try testing.expectEqual(@as(u32, 1), h.world.get_devices_calls);
    try expectTimer(be, 100, 0);
}

test "a disconnect scans the devices at once" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{ .poll_ms = 100000 });
    defer h.deinit();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.world.removeDevice(usb_id);
    h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 2), h.world.get_devices_calls);
    try testing.expect(endpointNamed(h.ctx.mixer(), "usb_headset:22") == null);
}

test "a poll time of zero turns off the timer scan" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{ .poll_ms = 0 });
    defer h.deinit();
    const be = h.backend();
    try testing.expect(!readable(h.ctx.fd().?, 50));
    be.next_scan_ns = 0;
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 1), h.world.get_devices_calls);
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.fake.live()[0].fireError(aaudio.ResultCode.disconnected);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u32, 2), h.world.get_devices_calls);
}

test "teardown frees the global references and detaches the thread" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    defer h.fake.deinit();
    defer h.world.deinit();
    addDevices(&h);
    h.world.has_route_api = true;
    h.world.attached = false;
    try h.attach(h.jni(.{}));
    try testing.expectEqual(@as(u32, 1), h.world.attach_calls);
    try testing.expectEqual(@as(usize, 4), h.world.globalsLive());
    h.ctx.deinit();
    try testing.expectEqual(@as(usize, 0), h.world.globalsLive());
    try testing.expectEqual(@as(u32, 1), h.world.detach_calls);
    try testing.expect(!h.world.dirty());
}

test "a failed create with JNI leaves no endpoint and no reference" {
    if (!on_linux) return error.SkipZigTest;
    var fake: Fake = undefined;
    fake.init(testing.allocator);
    defer fake.deinit();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var world: fake_jni.Fake = undefined;
        world.init(testing.allocator);
        defer world.deinit();
        world.has_route_api = true;
        world.attached = false;
        world.addDevice(.{ .id = speaker_id, .type = aaudio.DeviceType.builtin_speaker, .name = "Speaker", .sink = true });
        world.addDevice(.{ .id = mic_id, .type = aaudio.DeviceType.builtin_mic, .name = "Mic", .source = true });
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var mixer: Mixer = .init(failing.allocator());
        defer mixer.deinit();
        const created = create(.{
            .gpa = testing.allocator,
            .io = testing.io,
            .mixer = &mixer,
            .app_name = "test",
        }, .{ .api = &fake.table, .java_vm = world.vm(), .android_context = world.contextObject() });
        if (created) |backend| {
            backend.deinit();
            try testing.expectEqual(@as(usize, 2), mixer.endpoints().len);
            try testing.expect(!world.dirty());
            break;
        } else |_| {
            try testing.expectEqual(@as(usize, 0), mixer.endpoints().len);
            try testing.expect(!world.dirty());
            try testing.expectEqual(world.attach_calls, world.detach_calls);
        }
    }
    try testing.expect(fail_index >= 4);
}

/// Checks the interval that the kernel has for the timer.
fn expectTimer(be: *AAudio, sec: isize, ms: isize) !void {
    var spec: linux.itimerspec = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.timerfd_gettime(be.timer_fd, &spec)));
    try testing.expectEqual(sec, @as(isize, @intCast(spec.it_interval.sec)));
    try testing.expectEqual(ms * std.time.ns_per_ms, @as(isize, @intCast(spec.it_interval.nsec)));
}

test "the scan timer has the default poll time of one second" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    try testing.expectEqual(@as(u32, 1000), h.backend().timer_ms);
    try expectTimer(h.backend(), 1, 0);
}

test "a poll time of 2500 ms is a valid interval" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{ .poll_ms = 2500 });
    defer h.deinit();
    try expectTimer(h.backend(), 2, 500);
}

test "the drain timer is gone after a drain when JNI is there" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    const be = h.backend();
    h.fake.hold_stopping = true;
    var tone: Tone = .{ .status = .drain };
    const s = try h.open(.playback, &tone);
    try s.start();
    var buf: [64 * 8]u8 = undefined;
    _ = h.fake.live()[0].callOnce(&buf);
    _ = try h.ctx.dispatch();
    try expectTimer(be, 0, 10);
    h.fake.live()[0].completeStop();
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.stopped, s.state());
    try expectTimer(be, 1, 0);
}

test "the scan timer stops after a disconnect and starts on reconnect" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    const be = h.backend();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.fake.live()[0].fireError(aaudio.ResultCode.no_service);
    try testing.expectEqual(Backend.Event.disconnected, try h.ctx.dispatch());
    try testing.expectEqual(@as(u32, 0), be.timer_ms);
    try expectTimer(be, 0, 0);
    const calls = h.world.get_devices_calls;
    try h.ctx.reconnect();
    try testing.expectEqual(calls + 1, h.world.get_devices_calls);
    try expectTimer(be, 1, 0);
}

test "the app can see why the JNI setup failed" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    h.begin();
    h.world.throw_on = .get_system_service;
    try h.attach(h.jni(.{}));
    defer h.deinit();
    try testing.expectEqual(@as(?java.Error, error.JavaException), h.backend().jniSetupError());
    h.deinit();
    h.begin();
    try h.attach(h.jni(.{}));
    try testing.expectEqual(@as(?java.Error, null), h.backend().jniSetupError());
}

test "a failed read back after a volume write is not an error" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    const mixer = h.ctx.mixer();
    h.world.throw_on = .get_stream_volume;
    try mixer.setVolume(.{ .endpoint = mixer.default(.sink).? }, .{ .channels = &.{0.5} });
    try testing.expectEqual(@as(u32, 1), h.world.set_volume_calls);
    try testing.expect(!h.world.pending);
}

test "a reconnect whose scan fails stays disconnected" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    const be = h.backend();
    var tone: Tone = .{};
    const s = try h.open(.playback, &tone);
    try s.start();
    h.fake.live()[0].fireError(aaudio.ResultCode.no_service);
    try testing.expectEqual(Backend.Event.disconnected, try h.ctx.dispatch());
    h.world.addDevice(.{ .id = 31, .type = aaudio.DeviceType.wired_headset, .name = "Headset", .sink = true });
    const mixer = &h.ctx.mixer_state;
    const gpa = mixer.gpa;
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    mixer.gpa = failing.allocator();
    try testing.expectError(error.OutOfMemory, h.ctx.reconnect());
    mixer.gpa = gpa;
    try testing.expect(!be.connected);
    try expectTimer(be, 0, 0);
    try h.ctx.reconnect();
    try testing.expect(be.connected);
    try testing.expect(endpointNamed(mixer, "wired_headset:31") != null);
}

test "a start while draining makes the next drain wake the app" {
    if (!on_linux) return error.SkipZigTest;
    var h: Harness = undefined;
    try initWorld(&h, .{});
    defer h.deinit();
    h.fake.hold_stopping = true;
    var tone: Tone = .{ .status = .drain };
    const s = try h.open(.playback, &tone);
    try s.start();
    var buf: [64 * 8]u8 = undefined;
    _ = h.fake.live()[0].callOnce(&buf);
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u8, 1), h.backend().entries.items[0].drain_stage);
    // The start gives no backend call. AAudio still runs the callback while it stops.
    try s.start();
    _ = h.fake.live()[0].callForced(&buf);
    try testing.expectEqual(Stream.State.draining, s.state());
    try testing.expectEqual(@as(u64, 1), wakeCount(h.backend()));
    _ = try h.ctx.dispatch();
    try testing.expectEqual(@as(u8, 1), h.backend().entries.items[0].drain_stage);
    h.fake.live()[0].completeStop();
    _ = try h.ctx.dispatch();
    try testing.expectEqual(Stream.State.stopped, s.state());
}
