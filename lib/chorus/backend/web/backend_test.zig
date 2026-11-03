//! Tests of the web backend with the fake browser.
const std = @import("std");
const builtin = @import("builtin");
const Format = @import("../../Format.zig");
const Mixer = @import("../../Mixer.zig");
const Stream = @import("../../Stream.zig");
const Context = @import("../../Context.zig");
const Backend = @import("../Backend.zig");
const Web = @import("../Web.zig");
const web = @import("api.zig");
const Fake = @import("fake.zig");
const testing = std.testing;

const stereo: Format = .{ .sample = .f32, .rate = 48000, .channels = .stereo };
const mono: Format = .{ .sample = .f32, .rate = 48000, .channels = .mono };

/// Writes a counter into every channel, or `value` when `value` is not zero.
const Tone = struct {
    value: f32 = 0,
    next: f32 = 0,
    calls: u32 = 0,
    drain_at: u32 = 0,
    stop_at: u32 = 0,

    fn callback(self: *Tone) Stream.Callback {
        return .{ .ctx = self, .func = run };
    }

    fn run(ctx: ?*anyopaque, stream: *Stream, buffer: Stream.Buffer) Stream.Status {
        _ = stream;
        const self: *Tone = @ptrCast(@alignCast(ctx.?));
        const count = buffer.format.channels.count;
        const samples = std.mem.bytesAsSlice(f32, buffer.bytes);
        for (0..buffer.frames) |i| {
            const v = if (self.value != 0) self.value else self.next;
            self.next += 1;
            for (0..count) |c| samples[i * count + c] = v;
        }
        self.calls += 1;
        if (self.stop_at != 0 and self.calls >= self.stop_at) return .stop;
        return if (self.drain_at != 0 and self.calls >= self.drain_at) .drain else .@"continue";
    }
};

const Harness = struct {
    fake: Fake,
    ctx: *Context,
    tone: Tone = .{},
    live: bool = false,

    fn begin(self: *Harness) void {
        self.* = .{ .fake = .init(testing.allocator), .ctx = undefined };
    }

    fn init(self: *Harness, options: Web.Options) !void {
        self.begin();
        try self.attach(options);
    }

    fn attach(self: *Harness, options: Web.Options) !void {
        var opts = options;
        opts.api = self.fake.binding();
        self.ctx = try Context.init(testing.allocator, testing.io, .{ .app_name = "test", .backend = .web, .web_backend = opts });
        self.live = true;
    }

    fn deinit(self: *Harness) void {
        if (self.live) self.ctx.deinit();
        self.fake.deinit();
    }

    /// Closes the Context and checks that no handle is left or misused.
    fn finish(self: *Harness) !void {
        self.ctx.deinit();
        self.live = false;
        try testing.expectEqual(@as(usize, 0), self.fake.liveHandles());
        try testing.expectEqual(@as(u32, 0), self.fake.bad_uses);
        try testing.expectEqual(@as(u32, 0), self.fake.bad_releases);
    }

    fn backend(self: *Harness) *Web {
        return self.ctx.backend.as(Web).?;
    }

    fn open(self: *Harness, format: Format) !*Stream {
        return self.ctx.openStream(.{ .direction = .playback, .format = format, .callback = self.tone.callback() });
    }

    /// Sets the clock, then dispatches once.
    fn tick(self: *Harness, time: f64) !Context.Event {
        self.fake.now = time;
        return self.ctx.dispatch();
    }
};

fn whenOf(frame: u64, rate: f64) f64 {
    return @as(f64, @floatFromInt(frame)) / rate;
}

test "the first fill is the lead in chunks, one chunk after now" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.tone.next = 0;
    const s = try h.open(stereo);
    try s.start();
    try testing.expectEqual(Context.Event.none, try h.tick(0));
    const plays = h.fake.plays.items;
    try testing.expectEqual(@as(usize, 3), plays.len);
    for (plays, 0..) |p, i| {
        try testing.expectEqual(@as(u32, 960), p.frames);
        try testing.expectEqual(@as(f32, 48000), p.rate);
        try testing.expectEqual(@as(usize, 2), p.channels.len);
        try testing.expectEqual(whenOf(960 * (i + 1), 48000), p.when);
        try testing.expectEqual(plays[0].gain, p.gain);
    }
    try testing.expectEqual(@as(f32, 0), plays[0].channels[0][0]);
    try testing.expectEqual(@as(f32, 959), plays[0].channels[1][959]);
    try testing.expectEqual(@as(f32, 960), plays[1].channels[0][0]);
    try testing.expectEqual(@as(u32, 3), h.tone.calls);
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 3), h.fake.plays.items.len);
    try testing.expectEqual(@as(u64, 0), s.stats().xruns);
    try h.finish();
}

test "when is exact and contiguous at a rate with a fractional chunk time" {
    var h: Harness = undefined;
    h.begin();
    h.fake.rate = 44100;
    try h.attach(.{});
    defer h.deinit();
    const s = try h.open(.{ .sample = .f32, .rate = 44100, .channels = .stereo });
    try s.start();
    // The clock is not on a frame, as under a reduced timer precision.
    var time: f64 = 0.250005;
    while (time < 0.9) : (time += 0.0137) _ = try h.tick(time);
    const plays = h.fake.plays.items;
    try testing.expect(plays.len > 8);
    const first: u64 = @intFromFloat(@ceil(0.250005 * 44100.0));
    try testing.expectEqual(@as(u64, 11026), first);
    var expected_next: f32 = 0;
    for (plays, 0..) |p, i| {
        try testing.expectEqual(@as(u32, 882), p.frames);
        try testing.expectEqual(whenOf(first + 882 * (i + 1), 44100), p.when);
        try testing.expectEqual(expected_next, p.channels[0][0]);
        expected_next += 882;
    }
    try testing.expectEqual(@as(u64, 0), s.stats().xruns);
    try h.finish();
}

test "a dry queue counts one xrun and restarts one chunk ahead of now" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 3), h.fake.plays.items.len);
    _ = try h.tick(1.0);
    try testing.expectEqual(@as(u64, 1), s.stats().xruns);
    const plays = h.fake.plays.items;
    try testing.expectEqual(whenOf(48000 + 960, 48000), plays[3].when);
    try testing.expectEqual(whenOf(48000 + 960 * 2, 48000), plays[4].when);
    // The lead grew by 40 ms, so the queue holds 120 ms: five chunks from one chunk after now.
    try testing.expectEqual(@as(usize, 8), plays.len);
    _ = try h.tick(1.0);
    try testing.expectEqual(@as(usize, 8), h.fake.plays.items.len);
    try testing.expectEqual(@as(u64, 1), s.stats().xruns);
    try testing.expectEqual(@as(?u32, 1), h.ctx.timeoutMs());
    try h.finish();
}

test "failed plays count one xrun and keep the clock moving" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    h.fake.fail_play = true;
    _ = try h.tick(0);
    try testing.expectEqual(@as(u64, 1), s.stats().xruns);
    try testing.expectEqual(@as(usize, 0), h.fake.plays.items.len);
    try testing.expectEqual(@as(usize, 2), h.fake.liveHandles());
    h.fake.fail_play = false;
    _ = try h.tick(0.02);
    try testing.expectEqual(@as(usize, 1), h.fake.plays.items.len);
    try testing.expectEqual(whenOf(3840, 48000), h.fake.plays.items[0].when);
    try h.finish();
}

test "the lead grows 40 ms per xrun up to 250 ms" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    _ = try h.tick(0);
    const be = h.backend();
    try testing.expectEqual(@as(u32, 80), be.lead_ms);
    const expected = [_]u32{ 120, 160, 200, 240, 250, 250 };
    var time: f64 = 0;
    for (expected, 0..) |lead, i| {
        time += 5;
        _ = try h.tick(time);
        try testing.expectEqual(lead, be.lead_ms);
        try testing.expectEqual(@as(u64, i + 1), s.stats().xruns);
    }
    try h.finish();
}

test "the lead shrinks 20 ms after each 10 quiet seconds down to the least" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    _ = try h.tick(0);
    _ = try h.tick(5);
    _ = try h.tick(10);
    const be = h.backend();
    try testing.expectEqual(@as(u32, 160), be.lead_ms);
    var k: u32 = 1;
    while (k <= 1000) : (k += 1) {
        const quiet = @as(f64, @floatFromInt(k)) * 0.05;
        _ = try h.tick(10 + quiet);
        const steps: u32 = @min(4, @as(u32, @intFromFloat(@floor(quiet / 10.0))));
        try testing.expectEqual(160 - 20 * steps, be.lead_ms);
    }
    try testing.expectEqual(@as(u32, 80), be.lead_ms);
    try testing.expectEqual(@as(u64, 2), s.stats().xruns);
    try h.finish();
}

test "a hidden page queues at least 250 ms" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.is_hidden = true;
    const s = try h.open(stereo);
    try s.start();
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 12), h.fake.plays.items.len);
    try testing.expectEqual(@as(u32, 80), h.backend().lead_ms);
    h.fake.is_hidden = false;
    _ = try h.tick(0.5);
    try testing.expectEqual(@as(u64, 1), s.stats().xruns);
    try h.finish();
}

test "a draining stream becomes stopped when the clock reaches the queue end" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.tone.drain_at = 2;
    const s = try h.open(stereo);
    try s.start();
    _ = try h.tick(0);
    try testing.expectEqual(Stream.State.draining, s.state());
    try testing.expectEqual(@as(usize, 2), h.fake.plays.items.len);
    try testing.expectEqual(@as(u32, 2), h.tone.calls);
    // The queue ends at frame 2880, which is 60 ms.
    _ = try h.tick(0.05);
    try testing.expectEqual(Stream.State.draining, s.state());
    try testing.expectEqual(@as(?u32, 10), h.ctx.timeoutMs());
    _ = try h.tick(0.059);
    try testing.expectEqual(Stream.State.draining, s.state());
    _ = try h.tick(0.0601);
    try testing.expectEqual(Stream.State.stopped, s.state());
    try testing.expectEqual(@as(usize, 2), h.fake.plays.items.len);
    try testing.expectEqual(@as(u64, 0), s.stats().xruns);
    try testing.expectEqual(@as(?u32, null), h.ctx.timeoutMs());
    try testing.expectEqual(@as(usize, 2), h.fake.liveHandles());
    try h.finish();
}

test "a suspended context queues one lead and the wall clock drives the resume retries" {
    var h: Harness = undefined;
    h.begin();
    h.fake.new_state = .suspended;
    h.fake.is_activated = false;
    try h.attach(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    for (0..5) |_| _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 3), h.fake.plays.items.len);
    try testing.expectEqual(@as(usize, 0), h.fake.resumes.items.len);
    try testing.expectEqual(@as(u64, 0), s.stats().xruns);
    h.fake.is_activated = true;
    // The context clock stays at 0 and the resume has no effect.
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 1), h.fake.resumes.items.len);
    const walls = [_]f64{ 1, 500, 999.5 };
    for (walls) |wall| {
        h.fake.wall_ms = wall;
        _ = try h.tick(0);
    }
    try testing.expectEqual(@as(usize, 1), h.fake.resumes.items.len);
    h.fake.wall_ms = 1000;
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 2), h.fake.resumes.items.len);
    try testing.expectEqual(@as(f64, 1000), h.fake.resumes.items[1]);
    h.fake.wall_ms = 2000.5;
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 3), h.fake.resumes.items.len);
    // A context clock that moves while suspended renders nothing and counts no xrun.
    h.fake.wall_ms = 2100;
    _ = try h.tick(1.04);
    h.fake.is_hidden = true;
    _ = try h.tick(2.5);
    try testing.expectEqual(@as(usize, 3), h.fake.plays.items.len);
    try testing.expectEqual(@as(u64, 0), s.stats().xruns);
    try testing.expectEqual(@as(usize, 3), h.fake.resumes.items.len);
    h.fake.ctx_state = .interrupted;
    h.fake.wall_ms = 3001;
    _ = try h.tick(2.5);
    try testing.expectEqual(@as(usize, 4), h.fake.resumes.items.len);
    try testing.expectEqual(@as(usize, 3), h.fake.plays.items.len);
    try h.finish();
}

test "a resume that works lets the context run" {
    var h: Harness = undefined;
    h.begin();
    h.fake.new_state = .suspended;
    h.fake.resume_runs = true;
    try h.attach(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    try testing.expectEqual(@as(usize, 1), h.fake.resumes.items.len);
    try testing.expectEqual(@as(f64, 0), h.fake.resumes.items[0]);
    try testing.expectEqual(web.State.running, h.fake.ctx_state);
    _ = try h.tick(0);
    _ = try h.tick(0.5);
    _ = try h.tick(3.0);
    try testing.expectEqual(@as(usize, 1), h.fake.resumes.items.len);
    try h.finish();
}

test "a suspended context with no active stream is not resumed" {
    var h: Harness = undefined;
    h.begin();
    h.fake.new_state = .suspended;
    try h.attach(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    _ = try h.tick(0);
    _ = try h.tick(5);
    try testing.expectEqual(@as(usize, 0), h.fake.resumes.items.len);
    try testing.expectEqual(@as(usize, 0), h.fake.plays.items.len);
    try testing.expectEqual(Stream.State.idle, s.state());
    try h.finish();
}

test "stop stops every source in flight and start fills again" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    _ = try h.tick(0);
    const plays = h.fake.plays.items;
    try testing.expectEqual(@as(usize, 3), plays.len);
    try testing.expectEqual(@as(usize, 5), h.fake.liveHandles());
    s.stop();
    try testing.expectEqual(@as(usize, 3), h.fake.stops.items.len);
    for (h.fake.stops.items, plays) |stop, p| {
        try testing.expectEqual(p.src, stop.src);
        try testing.expectEqual(@as(f64, 0), stop.when);
    }
    try testing.expectEqual(@as(usize, 2), h.fake.liveHandles());
    _ = try h.tick(0.03);
    try testing.expectEqual(@as(usize, 3), h.fake.plays.items.len);
    try s.start();
    _ = try h.tick(0.03);
    try testing.expectEqual(@as(usize, 6), h.fake.plays.items.len);
    try testing.expectEqual(whenOf(1440 + 960, 48000), h.fake.plays.items[3].when);
    try h.finish();
}

test "finished sources are released and the ring stays small" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    var k: u32 = 0;
    while (k <= 100) : (k += 1) {
        _ = try h.tick(@as(f64, @floatFromInt(k)) * 0.02);
        try testing.expect(h.fake.liveHandles() <= 2 + 5);
    }
    try testing.expect(h.fake.plays.items.len >= 100);
    try testing.expectEqual(@as(u64, 0), s.stats().xruns);
    try testing.expectEqual(@as(u32, 0), h.fake.bad_uses);
    try h.finish();
}

test "a long lead gets a ring that holds it" {
    var h: Harness = undefined;
    try h.init(.{ .lead_ms = 1000 });
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 49), h.fake.plays.items.len);
    try h.finish();
}

test "chunk and rate options set the period and the buffers" {
    var h: Harness = undefined;
    try h.init(.{ .rate = 44100, .chunk_ms = 10, .lead_ms = 40 });
    defer h.deinit();
    try testing.expectEqual(@as(?u32, 44100), h.fake.requested_rate);
    const s = try h.open(stereo);
    try testing.expectEqual(@as(u32, 44100), s.nativeFormat().rate);
    try testing.expectEqual(@as(u32, 441), s.negotiated.period_frames);
    try s.start();
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 3), h.fake.plays.items.len);
    try testing.expectEqual(@as(u32, 441), h.fake.plays.items[0].frames);
    try testing.expectEqual(@as(f32, 44100), h.fake.plays.items[0].rate);
    try testing.expectEqual(whenOf(441, 44100), h.fake.plays.items[0].when);
    try h.finish();
}

test "a stream has one gain node and the mixer shows the sink" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const m = h.ctx.mixer();
    try testing.expectEqual(@as(usize, 1), m.endpoints().len);
    const sink = m.endpoints()[0];
    try testing.expectEqualStrings("default", sink.name);
    try testing.expectEqualStrings("Default output", sink.description);
    try testing.expectEqual(Mixer.Kind.sink, sink.kind);
    try testing.expectEqualSlices(f32, &.{ 1, 1 }, sink.volume.slice());
    try testing.expectEqual(@as(?Mixer.Id, sink.id), m.default(.sink));
    try testing.expectEqual(@as(?Mixer.Id, null), m.default(.source));
    try testing.expectEqual(Mixer.Capabilities{ .stream_volume = true }, m.capabilities());
    try testing.expectEqual(@as(usize, 1), h.fake.liveHandles());
    const a = try h.open(stereo);
    const b = try h.open(mono);
    try testing.expectEqual(@as(usize, 3), h.fake.liveHandles());
    try testing.expectEqual(@as(usize, 2), m.streams().len);
    try testing.expectEqualSlices(f32, &.{ 1, 1 }, m.streams()[0].volume.slice());
    try testing.expectEqualSlices(f32, &.{1}, m.streams()[1].volume.slice());
    try testing.expectEqual(@as(?Mixer.Id, sink.id), m.streams()[0].endpoint);
    try testing.expectEqual(Backend.Kind.web, h.ctx.info().backend);
    try testing.expectEqual(Context.Realtime.no, h.ctx.info().realtime);
    try testing.expectEqual(@as(?i32, null), h.ctx.fd());
    a.close();
    try testing.expectEqual(@as(usize, 2), h.fake.liveHandles());
    try testing.expectEqual(@as(usize, 1), m.streams().len);
    try testing.expectEqual(@as(usize, 1), h.fake.disconnects.items.len);
    b.close();
    try testing.expectEqual(@as(usize, 0), m.streams().len);
    try testing.expectEqual(@as(usize, 1), h.fake.liveHandles());
    try h.finish();
}

test "mono streams are mono and a one channel destination downmixes" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.tone.value = 0.5;
    const a = try h.open(mono);
    try testing.expectEqual(@as(u8, 1), a.nativeFormat().channels.count);
    try a.start();
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 1), h.fake.plays.items[0].channels.len);
    try testing.expectEqual(@as(f32, 0.5), h.fake.plays.items[0].channels[0][7]);
    h.fake.max_channels = 1;
    const b = try h.open(stereo);
    try testing.expectEqual(@as(u8, 1), b.nativeFormat().channels.count);
    try testing.expectEqual(@as(u32, 48000), b.nativeFormat().rate);
    const c = try h.open(.{ .sample = .s16, .rate = 22050, .channels = Format.Channels.surround_5_1 });
    try testing.expectEqual(@as(u8, 1), c.nativeFormat().channels.count);
    try testing.expectEqual(Format.Sample.f32, c.nativeFormat().sample);
    try testing.expectEqual(@as(u32, 48000), c.nativeFormat().rate);
    h.fake.max_channels = 2;
    const d = try h.open(.{ .sample = .s16, .rate = 22050, .channels = Format.Channels.surround_5_1 });
    try testing.expectEqual(@as(u8, 2), d.nativeFormat().channels.count);
    try h.finish();
}

test "capture and unknown devices are refused" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    try testing.expectError(error.UnknownDevice, h.ctx.openStream(.{ .direction = .capture, .format = stereo, .callback = h.tone.callback() }));
    try testing.expectError(error.UnknownDevice, h.ctx.openStream(.{
        .direction = .playback,
        .format = stereo,
        .device = @fromBackingInt(77),
        .callback = h.tone.callback(),
    }));
    const sink = h.ctx.mixer().endpoints()[0].id;
    const s = try h.ctx.openStream(.{ .direction = .playback, .format = stereo, .device = sink, .callback = h.tone.callback() });
    s.close();
    try testing.expectEqual(@as(usize, 1), h.fake.liveHandles());
    try testing.expectEqual(@as(usize, 0), h.ctx.mixer().streams().len);
    try h.finish();
}

test "a failed gain node fails the open and leaks nothing" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.fake.fail_create = true;
    try testing.expectError(error.Disconnected, h.open(stereo));
    try testing.expectEqual(@as(usize, 0), h.ctx.mixer().streams().len);
    try testing.expectEqual(@as(usize, 1), h.fake.liveHandles());
    try h.finish();
}

fn expectLastRamp(fake: *const Fake, gain: u32, value: f32) !void {
    const ramp = fake.ramps.items[fake.ramps.items.len - 1];
    try testing.expectEqual(gain, ramp.gain);
    try testing.expectEqual(value, ramp.value);
    try testing.expectEqual(@as(f64, 0.010), ramp.seconds);
}

test "volume ramps the gain to the largest value and scales the other channels" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.tone.value = 0.5;
    const s = try h.open(stereo);
    try s.start();
    _ = try h.tick(0);
    const gain = h.fake.plays.items[0].gain;
    const id = h.ctx.mixer().streams()[0].id;
    try h.ctx.mixer().setVolume(.{ .stream = id }, .{ .channels = &.{ 0.5, 0.25 } });
    try testing.expectEqual(@as(usize, 1), h.fake.ramps.items.len);
    try expectLastRamp(&h.fake, gain, 0.5);
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.25 }, h.ctx.mixer().stream(id).?.volume.slice());
    _ = try h.tick(0.02);
    const next = h.fake.plays.items[h.fake.plays.items.len - 1];
    try testing.expectEqual(@as(f32, 0.5), next.channels[0][100]);
    try testing.expectEqual(@as(f32, 0.25), next.channels[1][100]);
    try h.ctx.mixer().setVolume(.{ .stream = id }, .{ .channels = &.{0.3} });
    try expectLastRamp(&h.fake, gain, 0.3);
    try testing.expectEqualSlices(f32, &.{ 0.3, 0.3 }, h.ctx.mixer().stream(id).?.volume.slice());
    _ = try h.tick(0.04);
    const last = h.fake.plays.items[h.fake.plays.items.len - 1];
    try testing.expectEqual(@as(f32, 0.5), last.channels[0][5]);
    try testing.expectEqual(@as(f32, 0.5), last.channels[1][5]);
    try h.ctx.mixer().setVolume(.{ .stream = id }, .{ .channels = &.{ 0, 0 } });
    try expectLastRamp(&h.fake, gain, 0);
    try testing.expectError(error.InvalidVolume, h.ctx.mixer().setVolume(.{ .stream = id }, .{ .channels = &.{ 1, 2, 3 } }));
    try testing.expectEqual(@as(usize, 3), h.fake.ramps.items.len);
    try h.finish();
}

test "mute ramps the gain to zero and back to the volume" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    _ = try h.tick(0);
    const gain = h.fake.plays.items[0].gain;
    const id = h.ctx.mixer().streams()[0].id;
    try h.ctx.mixer().setVolume(.{ .stream = id }, .{ .channels = &.{ 0.8, 0.4 } });
    try h.ctx.mixer().setMute(.{ .stream = id }, true);
    try expectLastRamp(&h.fake, gain, 0);
    try testing.expect(h.ctx.mixer().stream(id).?.mute);
    try h.ctx.mixer().setVolume(.{ .stream = id }, .{ .channels = &.{ 0.6, 0.3 } });
    try expectLastRamp(&h.fake, gain, 0);
    try h.ctx.mixer().setMute(.{ .stream = id }, false);
    try expectLastRamp(&h.fake, gain, 0.6);
    try testing.expect(!h.ctx.mixer().stream(id).?.mute);
    try testing.expectEqual(@as(usize, 4), h.fake.ramps.items.len);
    try h.finish();
}

test "controls with no web meaning are unsupported" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    const be = h.ctx.backend;
    const sink = h.ctx.mixer().endpoints()[0].id;
    const id = h.ctx.mixer().streams()[0].id;
    try testing.expectError(error.Unsupported, be.setDefault(.sink, sink));
    try testing.expectError(error.Unsupported, be.setVolume(.{ .endpoint = sink }, &.{ 1, 1 }));
    try testing.expectError(error.Unsupported, be.setMute(.{ .endpoint = sink }, true));
    try testing.expectError(error.Unsupported, be.moveStream(id, sink));
    try testing.expectError(error.Unsupported, be.setProfile(sink, 0));
    try testing.expectError(error.Unsupported, be.setPort(sink, 0));
    try testing.expectError(error.UnknownObject, be.setVolume(.{ .stream = sink }, &.{ 1, 1 }));
    try testing.expectError(error.UnknownObject, be.setMute(.{ .stream = sink }, true));
    try testing.expectError(error.InvalidVolume, be.setVolume(.{ .stream = id }, &.{1}));
    try testing.expectError(error.Unsupported, h.ctx.mixer().setVolume(.{ .endpoint = sink }, .{ .channels = &.{1} }));
    try testing.expectError(error.Unsupported, h.ctx.mixer().setDefault(.sink, sink));
    try testing.expectEqual(@as(usize, 0), h.fake.ramps.items.len);
    s.close();
    try h.finish();
}

test "a closed context gives disconnected and a reconnect makes a new context" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    _ = try h.tick(0);
    const old_sink = h.ctx.mixer().endpoints()[0].id;
    const old_plays = h.fake.plays.items.len;
    h.fake.ctx_state = .closed;
    try testing.expectEqual(Context.Event.disconnected, try h.tick(0.02));
    try testing.expectEqual(Stream.State.stopped, s.state());
    try testing.expect(!s.attached);
    try testing.expectEqual(@as(usize, 0), h.ctx.mixer().endpoints().len);
    try testing.expectEqual(@as(usize, 0), h.ctx.mixer().streams().len);
    try testing.expectEqual(@as(usize, 0), h.fake.liveHandles());
    try testing.expectEqual(@as(u32, 1), h.fake.contexts_created);
    try testing.expectEqual(@as(u32, 0), h.fake.contexts_closed);
    try testing.expectEqual(Context.Event.none, try h.ctx.dispatch());
    try testing.expectEqual(@as(?u32, null), h.ctx.timeoutMs());
    try testing.expectError(error.Disconnected, h.open(stereo));
    h.fake.ctx_state = .running;
    h.fake.rate = 44100;
    h.fake.now = 0;
    try h.ctx.reconnect();
    try testing.expectEqual(@as(u32, 2), h.fake.contexts_created);
    try testing.expect(s.attached);
    try testing.expectEqual(@as(u32, 44100), s.nativeFormat().rate);
    try testing.expectEqual(@as(usize, 1), h.ctx.mixer().endpoints().len);
    try testing.expect(h.ctx.mixer().endpoints()[0].id != old_sink);
    try testing.expectEqual(@as(usize, 1), h.ctx.mixer().streams().len);
    try testing.expectEqual(@as(usize, 2), h.fake.liveHandles());
    try testing.expectEqual(Stream.State.running, s.state());
    _ = try h.tick(0);
    try testing.expectEqual(old_plays + 3, h.fake.plays.items.len);
    const first = h.fake.plays.items[old_plays];
    try testing.expectEqual(@as(f32, 44100), first.rate);
    try testing.expectEqual(@as(u32, 882), first.frames);
    try testing.expectEqual(whenOf(882, 44100), first.when);
    try h.finish();
}

test "the context is closed once on deinit" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 5), h.fake.liveHandles());
    try h.finish();
    try testing.expectEqual(@as(usize, 0), h.fake.liveHandles());
    try testing.expectEqual(@as(u32, 1), h.fake.contexts_closed);
    try testing.expectEqual(@as(usize, 3), h.fake.stops.items.len);
}

test "timeoutMs is the time until the queue needs a refill" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    try testing.expectEqual(@as(?u32, null), h.ctx.timeoutMs());
    const s = try h.open(stereo);
    try testing.expectEqual(@as(?u32, null), h.ctx.timeoutMs());
    try s.start();
    try testing.expectEqual(@as(?u32, 0), h.ctx.timeoutMs());
    _ = try h.tick(0);
    // The queue ends exactly at the lead. One more frame has to pass before a refill.
    try testing.expectEqual(@as(?u32, 1), h.ctx.timeoutMs());
    _ = try h.tick(0.01);
    try testing.expectEqual(@as(?u32, 11), h.ctx.timeoutMs());
    h.fake.now = 0.0105;
    try testing.expectEqual(@as(?u32, 10), h.ctx.timeoutMs());
    h.fake.now = 0.2;
    try testing.expectEqual(@as(?u32, 0), h.ctx.timeoutMs());
    s.stop();
    try testing.expectEqual(@as(?u32, null), h.ctx.timeoutMs());
    try h.finish();
}

test "timeoutMs asks for a poll every chunk while the context is suspended" {
    var h: Harness = undefined;
    h.begin();
    h.fake.new_state = .suspended;
    h.fake.is_activated = false;
    try h.attach(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    _ = try h.tick(0);
    try testing.expectEqual(@as(?u32, 20), h.ctx.timeoutMs());
    try h.finish();
}

test "auto never picks the web backend through a fake on a host target" {
    if (Backend.aaudio_enabled or Backend.web_enabled or Backend.coreaudio_enabled) return error.SkipZigTest;
    var fake: Fake = .init(testing.allocator);
    defer fake.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const PipeWireOptions = @FieldType(Context.Options, "pipewire_backend");
    const pipewire_backend: PipeWireOptions = if (Backend.pipewire_enabled)
        .{ .path = "chorus-no-such-remote" }
    else
        .{};
    const ctx = try Context.init(testing.allocator, testing.io, .{
        .app_name = "test",
        .environ = &env,
        .pipewire_backend = pipewire_backend,
        .web_backend = .{ .api = fake.binding() },
    });
    defer ctx.deinit();
    try testing.expectEqual(Backend.Kind.null, ctx.info().backend);
    try testing.expectEqual(@as(u32, 0), fake.contexts_created);
    try testing.expect(!Backend.compiled(.web));
}

test "the web backend needs a binding on a host target and a working browser" {
    var fake: Fake = .init(testing.allocator);
    defer fake.deinit();
    if (!Backend.web_enabled) {
        try testing.expectError(
            error.BackendUnavailable,
            Context.init(testing.allocator, testing.io, .{ .app_name = "test", .backend = .web }),
        );
    }
    fake.is_available = false;
    try testing.expectError(
        error.BackendUnavailable,
        Context.init(testing.allocator, testing.io, .{ .app_name = "test", .backend = .web, .web_backend = .{ .api = fake.binding() } }),
    );
    fake.is_available = true;
    fake.fail_create = true;
    try testing.expectError(
        error.BackendUnavailable,
        Context.init(testing.allocator, testing.io, .{ .app_name = "test", .backend = .web, .web_backend = .{ .api = fake.binding() } }),
    );
    try testing.expectEqual(@as(usize, 0), fake.liveHandles());
}

test "a hidden page with 10 ms chunks still queues 250 ms" {
    var h: Harness = undefined;
    try h.init(.{ .chunk_ms = 10 });
    defer h.deinit();
    h.fake.is_hidden = true;
    const s = try h.open(stereo);
    try s.start();
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 24), h.fake.plays.items.len);
    try testing.expectEqual(@as(?u32, 125), h.ctx.timeoutMs());
    try h.finish();
}

test "two streams that run dry together raise the lead once" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const a = try h.open(stereo);
    const b = try h.open(stereo);
    try a.start();
    try b.start();
    _ = try h.tick(0);
    _ = try h.tick(1.0);
    try testing.expectEqual(@as(u64, 1), a.stats().xruns);
    try testing.expectEqual(@as(u64, 1), b.stats().xruns);
    try testing.expectEqual(@as(u32, 120), h.backend().lead_ms);
    try h.finish();
}

test "start on a disconnected backend fails" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    h.fake.ctx_state = .closed;
    try testing.expectEqual(Context.Event.disconnected, try h.tick(0));
    try testing.expectError(error.Disconnected, s.start());
    try testing.expectEqual(Stream.State.stopped, s.state());
    try h.finish();
}

test "a rate that is not a number closes the new context and leaks nothing" {
    var fake: Fake = .init(testing.allocator);
    defer fake.deinit();
    fake.rate = std.math.nan(f32);
    try testing.expectError(
        error.BackendUnavailable,
        Context.init(testing.allocator, testing.io, .{ .app_name = "test", .backend = .web, .web_backend = .{ .api = fake.binding() } }),
    );
    try testing.expectEqual(@as(u32, 1), fake.contexts_closed);
    try testing.expectEqual(@as(usize, 0), fake.liveHandles());
    try testing.expectEqual(@as(u32, 0), fake.bad_releases);
}

test "a short lead and a zero chunk are raised" {
    var h: Harness = undefined;
    try h.init(.{ .lead_ms = 30 });
    defer h.deinit();
    try testing.expectEqual(@as(u32, 40), h.backend().lead_ms);
    try testing.expectEqual(@as(u32, 40), h.backend().options.lead_ms);
    const s = try h.open(stereo);
    try testing.expectEqual(@as(u32, 960), s.negotiated.period_frames);
    try h.finish();

    var z: Harness = undefined;
    try z.init(.{ .chunk_ms = 0, .lead_ms = 0 });
    defer z.deinit();
    try testing.expectEqual(@as(u32, 1), z.backend().options.chunk_ms);
    try testing.expectEqual(@as(u32, 2), z.backend().options.lead_ms);
    const t = try z.open(stereo);
    try testing.expectEqual(@as(u32, 48), t.negotiated.period_frames);
    try z.finish();
}

test "a wall clock that is not a number sends no further resume" {
    var h: Harness = undefined;
    h.begin();
    h.fake.new_state = .suspended;
    try h.attach(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    try testing.expectEqual(@as(usize, 1), h.fake.resumes.items.len);
    h.fake.wall_ms = std.math.nan(f64);
    for (0..5) |_| _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 1), h.fake.resumes.items.len);
    try h.finish();
}

test "a callback that returns stop stops the sources in flight" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    h.tone.stop_at = 2;
    const s = try h.open(stereo);
    try s.start();
    _ = try h.tick(0);
    try testing.expectEqual(Stream.State.stopped, s.state());
    try testing.expectEqual(@as(usize, 0), h.fake.stops.items.len);
    _ = try h.tick(0.001);
    try testing.expectEqual(@as(usize, 2), h.fake.plays.items.len);
    try testing.expectEqual(@as(usize, 2), h.fake.stops.items.len);
    for (h.fake.stops.items, h.fake.plays.items) |stop, p| try testing.expectEqual(p.src, stop.src);
    _ = try h.tick(0.002);
    try testing.expectEqual(@as(usize, 2), h.fake.stops.items.len);
    try h.finish();
}

test "a resume inside a user gesture is not held back by an earlier one" {
    var h: Harness = undefined;
    h.begin();
    h.fake.new_state = .suspended;
    try h.attach(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    try testing.expectEqual(@as(usize, 1), h.fake.resumes.items.len);
    h.fake.wall_ms = 100;
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 1), h.fake.resumes.items.len);
    h.fake.is_transient = true;
    h.fake.wall_ms = 150;
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 2), h.fake.resumes.items.len);
    try testing.expectEqual(@as(f64, 150), h.fake.resumes.items[1]);
    h.fake.is_transient = false;
    h.fake.wall_ms = 200;
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 2), h.fake.resumes.items.len);
    h.fake.wall_ms = 1150;
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 3), h.fake.resumes.items.len);
    try h.finish();
}

test "a hidden page gets a longer timeout hint" {
    var h: Harness = undefined;
    try h.init(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    h.fake.is_hidden = true;
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 12), h.fake.plays.items.len);
    // The queue ends at 250 ms. The refill waits until 125 ms are left.
    try testing.expectEqual(@as(?u32, 125), h.ctx.timeoutMs());
    h.fake.now = 0.1;
    try testing.expectEqual(@as(?u32, 36), h.ctx.timeoutMs());
    h.fake.now = 0.2;
    try testing.expectEqual(@as(?u32, 0), h.ctx.timeoutMs());
    h.fake.is_hidden = false;
    try testing.expectEqual(@as(?u32, 0), h.ctx.timeoutMs());
    try h.finish();
}

test "a long user gesture sends one resume and the limit applies after it" {
    var h: Harness = undefined;
    h.begin();
    h.fake.new_state = .suspended;
    try h.attach(.{});
    defer h.deinit();
    const s = try h.open(stereo);
    try s.start();
    try testing.expectEqual(@as(usize, 1), h.fake.resumes.items.len);
    h.fake.is_transient = true;
    for (1..11) |i| {
        h.fake.wall_ms = @floatFromInt(i * 10);
        _ = try h.tick(0);
    }
    try testing.expectEqual(@as(usize, 2), h.fake.resumes.items.len);
    h.fake.wall_ms = 1200;
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 3), h.fake.resumes.items.len);
    h.fake.is_transient = false;
    h.fake.wall_ms = 1300;
    _ = try h.tick(0);
    h.fake.is_transient = true;
    h.fake.wall_ms = 1400;
    _ = try h.tick(0);
    try testing.expectEqual(@as(usize, 4), h.fake.resumes.items.len);
    try h.finish();
}
