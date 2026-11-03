//! Tests through the Chorus API against the real PipeWire daemon and WirePlumber. Each test skips
//! when they are missing. Every node that a test creates carries the no_restore props, so no state
//! is saved.
const std = @import("std");
const linux = std.os.linux;
const pipewire = @import("pipewire");
const Format = @import("../../Format.zig");
const Mixer = @import("../../Mixer.zig");
const Stream = @import("../../Stream.zig");
const Context = @import("../../Context.zig");
const PipeWire = @import("../PipeWire.zig");
const Backend = @import("../Backend.zig");
const Player = @import("../../Player.zig");
const Recorder = @import("../../Recorder.zig");
const codec = @import("codec");

const live = pipewire.testing.live;
const Live = live.Live;

const gpa = std.testing.allocator;
const stereo: Format = .{ .sample = .f32, .rate = 48000, .channels = .stereo };

/// A constant signal for playback, and the peak for capture.
const Signal = struct {
    value: f32 = 0.5,
    peak: std.atomic.Value(u32) = .init(0),

    fn callback(self: *Signal) Stream.Callback {
        return .{ .ctx = self, .func = run };
    }

    fn run(ctx: ?*anyopaque, stream: *Stream, buffer: Stream.Buffer) Stream.Status {
        const self: *Signal = @ptrCast(@alignCast(ctx.?));
        const samples = std.mem.bytesAsSlice(f32, buffer.bytes);
        switch (stream.options.direction) {
            .playback => @memset(samples, self.value),
            .capture => {
                var peak: f32 = @bitCast(self.peak.load(.monotonic));
                for (samples) |v| peak = @max(peak, @abs(v));
                self.peak.store(@bitCast(peak), .monotonic);
            },
        }
        return .@"continue";
    }

    fn peakValue(self: *const Signal) f32 {
        return @bitCast(self.peak.load(.monotonic));
    }
};

/// The Context under test, a side connection for the temporary sinks, and the sinks.
const Rig = struct {
    env: std.process.Environ.Map,
    side: *Live,
    ctx: *Context,
    sinks: [2]?*pipewire.Proxy = .{ null, null },
    names: [2][64]u8 = undefined,
    name_lens: [2]usize = .{ 0, 0 },

    fn open(self: *Rig, sink_count: usize) !void {
        return self.openWith(sink_count, false);
    }

    fn openWith(self: *Rig, sink_count: usize, realtime: bool) !void {
        self.* = .{ .env = try std.testing.environ.createMap(gpa), .side = undefined, .ctx = undefined };
        errdefer self.env.deinit();
        self.side = try Live.open();
        errdefer self.side.close();
        try self.side.remote.roundtrip(2000);
        try live.requireWirePlumber(self.side);
        for (self.sinks[0..sink_count], 0..) |*slot, i| {
            const name = live.sinkName(&self.names[i], if (i == 0) "a" else "b");
            self.name_lens[i] = name.len;
            slot.* = try live.makeSink(self.side, name);
        }
        errdefer for (self.sinks) |sink| if (sink) |s| live.destroyOrPanic(s);
        try self.side.remote.flush();
        self.ctx = try Context.init(gpa, std.testing.io, .{
            .app_name = "chorus-live-test",
            .environ = &self.env,
            .pipewire_backend = .{ .stream_props = &live.no_restore, .realtime = realtime },
        });
    }

    fn close(self: *Rig) void {
        self.ctx.deinit();
        for (self.sinks) |sink| if (sink) |s| live.destroyOrPanic(s);
        self.side.remote.flush() catch |err| std.debug.panic("flush failed: {t}", .{err});
        self.side.remote.roundtrip(2000) catch |err| std.debug.panic("roundtrip failed: {t}", .{err});
        self.side.close();
        self.env.deinit();
    }

    fn sinkName(self: *const Rig, i: usize) []const u8 {
        return self.names[i][0..self.name_lens[i]];
    }

    fn endpointId(self: *Rig, i: usize) ?Mixer.Id {
        for (self.ctx.mixer().endpoints()) |e| {
            if (std.mem.eql(u8, e.name, self.sinkName(i))) return e.id;
        }
        return null;
    }

    /// Handles the messages of both connections until `done` returns true or `ms` pass.
    fn pump(self: *Rig, ms: i64, ctx: anytype, comptime done: fn (@TypeOf(ctx), *Rig) bool) !bool {
        const deadline = live.nowMs() + ms;
        while (true) {
            try self.side.remote.dispatch();
            _ = try self.ctx.dispatch();
            if (done(ctx, self)) return true;
            if (live.nowMs() >= deadline) return false;
            var pfd = [2]linux.pollfd{
                .{ .fd = self.side.remote.fd(), .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = self.ctx.fd() orelse -1, .events = linux.POLL.IN, .revents = 0 },
            };
            // Only the wait matters. The next loop dispatches both sides whatever woke it.
            _ = linux.poll(&pfd, 2, 5);
        }
    }

    fn hasSinks(count: usize, self: *Rig) bool {
        for (0..count) |i| if (self.endpointId(i) == null) return false;
        return true;
    }

    fn waitSinks(self: *Rig, count: usize) !void {
        const found = try self.pump(3000, count, hasSinks);
        try std.testing.expect(found);
    }

    fn ownStream(self: *Rig, direction: Stream.Direction) ?Mixer.AppStream {
        for (self.ctx.mixer().streams()) |s| {
            if (s.direction == direction and std.mem.eql(u8, s.app_name, "chorus-live-test")) return s;
        }
        return null;
    }
};

fn open(signal: *Signal, rig: *Rig, direction: Stream.Direction, device: Mixer.Id) !*Stream {
    return rig.ctx.openStream(.{
        .direction = direction,
        .format = stereo,
        .device = device,
        .callback = signal.callback(),
    });
}

fn isRunning(stream: *Stream, _: *Rig) bool {
    return stream.state() == .running;
}

fn rendered(stream: *Stream, _: *Rig) bool {
    return stream.stats().frames > 4800;
}

const Where = struct { Stream.Direction, Mixer.Id };

fn listedOn(args: Where, rig: *Rig) bool {
    const s = rig.ownStream(args[0]) orelse return false;
    return s.endpoint != null and s.endpoint.? == args[1];
}

fn halfVolume(_: void, rig: *Rig) bool {
    const s = rig.ownStream(.playback) orelse return false;
    const v = s.volume.slice();
    if (v.len == 0) return false;
    for (v) |x| if (@abs(x - 0.5) > 0.01) return false;
    return true;
}

fn peaked(signal: *const Signal, _: *Rig) bool {
    return signal.peakValue() > 0.05;
}

fn realtimeSettled(_: void, rig: *Rig) bool {
    const be = rig.ctx.backend.as(PipeWire).?;
    return be.rt_state.load(.acquire) != .pending;
}

test "live: auto picks the PipeWire backend and lists the temporary sinks" {
    const saved_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_level;
    var rig: Rig = undefined;
    try rig.openWith(2, true);
    defer rig.close();
    try std.testing.expectEqual(Backend.Kind.pipewire, rig.ctx.info().backend);
    try rig.waitSinks(2);
    const a = rig.ctx.mixer().endpoint(rig.endpointId(0).?).?;
    try std.testing.expectEqual(Mixer.Kind.sink, a.kind);
    // From a shell with no logind session, RTKit refuses and the thread stays normal.
    const settled = try rig.pump(5000, {}, realtimeSettled);
    try std.testing.expect(settled);
    const expected: Context.Realtime = if (rig.ctx.backend.as(PipeWire).?.rt_state.load(.acquire) == .yes) .yes else .no;
    try std.testing.expectEqual(expected, rig.ctx.info().realtime);
}

test "live: a playback stream runs on a sink, takes a volume and moves" {
    var rig: Rig = undefined;
    try rig.open(2);
    defer rig.close();
    try rig.waitSinks(2);
    const first = rig.endpointId(0).?;
    const second = rig.endpointId(1).?;

    var signal: Signal = .{};
    const stream = try open(&signal, &rig, .playback, first);
    try stream.start();
    try std.testing.expect(try rig.pump(3000, stream, isRunning));
    try std.testing.expect(try rig.pump(3000, stream, rendered));
    try std.testing.expect(stream.stats().frames > 4800);
    try std.testing.expect(try rig.pump(3000, Where{ .playback, first }, listedOn));

    const own = rig.ownStream(.playback).?;
    try rig.ctx.mixer().setVolume(.{ .stream = own.id }, .{ .channels = &.{0.5} });
    try std.testing.expect(try rig.pump(2000, {}, halfVolume));

    try rig.ctx.mixer().moveStream(own.id, second);
    try std.testing.expect(try rig.pump(3000, Where{ .playback, second }, listedOn));
}

test "live: a capture stream hears the monitor of a sink" {
    var rig: Rig = undefined;
    try rig.open(1);
    defer rig.close();
    try rig.waitSinks(1);
    const sink = rig.endpointId(0).?;

    var tone: Signal = .{};
    const playback = try open(&tone, &rig, .playback, sink);
    try playback.start();
    try std.testing.expect(try rig.pump(3000, playback, isRunning));

    var heard: Signal = .{};
    const capture = try open(&heard, &rig, .capture, sink);
    try capture.start();
    try std.testing.expect(try rig.pump(5000, &heard, peaked));
    try std.testing.expect(heard.peakValue() > 0.05);
}

fn sineWav(gpa_: std.mem.Allocator, frames: usize) ![]u8 {
    const samples = try gpa_.alloc(f32, frames * 2);
    defer gpa_.free(samples);
    for (0..frames) |i| {
        const v = 0.5 * @sin(@as(f32, @floatFromInt(i)) * 0.06);
        samples[i * 2] = v;
        samples[i * 2 + 1] = v;
    }
    var aw: std.Io.Writer.Allocating = .init(gpa_);
    errdefer aw.deinit();
    var enc: codec.Encoder = try .init(gpa_, &aw.writer, .{ .wav = .{ .sample = .f32 } }, .{ .rate = 48000, .channels = 2 });
    defer enc.deinit();
    try enc.write(samples);
    try enc.finish();
    return aw.toOwnedSlice();
}

fn playerIdle(player: *Player, _: *Rig) bool {
    return player.stats().active_voices == 0;
}

fn linked(stream: *Stream, _: *Rig) bool {
    return stream.stats().frames > 0;
}

fn recorded(recorder: *Recorder, _: *Rig) bool {
    return recorder.stats().frames_written >= 12000;
}

test "live: a Player sound is heard on the monitor of a sink" {
    var rig: Rig = undefined;
    try rig.open(1);
    defer rig.close();
    try rig.waitSinks(1);
    const sink = rig.endpointId(0).?;

    var heard: Signal = .{};
    const capture = try open(&heard, &rig, .capture, sink);
    try capture.start();
    try std.testing.expect(try rig.pump(3000, capture, isRunning));
    try std.testing.expect(try rig.pump(5000, capture, linked));

    const player = try Player.init(rig.ctx, .{ .device = sink });
    defer player.deinit();
    const bytes = try sineWav(gpa, 48000 / 2);
    defer gpa.free(bytes);
    const sound = try player.load(.{ .bytes = bytes }, .{});
    _ = try player.play(sound, .{});
    try std.testing.expect(try rig.pump(5000, &heard, peaked));
    try std.testing.expect(heard.peakValue() > 0.05);
    try std.testing.expect(try rig.pump(5000, player, playerIdle));
    try std.testing.expectEqual(@as(u32, 0), player.stats().rejected_commands);
}

test "live: a streamed Player voice is heard on the monitor of a sink" {
    var rig: Rig = undefined;
    try rig.open(1);
    defer rig.close();
    try rig.waitSinks(1);
    const sink = rig.endpointId(0).?;

    var heard: Signal = .{};
    const capture = try open(&heard, &rig, .capture, sink);
    try capture.start();
    try std.testing.expect(try rig.pump(3000, capture, isRunning));
    try std.testing.expect(try rig.pump(5000, capture, linked));

    const player = try Player.init(rig.ctx, .{ .device = sink });
    defer player.deinit();
    const bytes = try sineWav(gpa, 48000 / 2);
    defer gpa.free(bytes);
    _ = try player.stream(.{ .bytes = bytes }, .{});
    try std.testing.expect(try rig.pump(5000, &heard, peaked));
    try std.testing.expect(try rig.pump(5000, player, playerIdle));
    try std.testing.expectEqual(@as(u32, 0), player.stats().rejected_commands);
}

test "live: a Recorder writes the monitor of a sink into a WAV file" {
    var rig: Rig = undefined;
    try rig.open(1);
    defer rig.close();
    try rig.waitSinks(1);
    const sink = rig.endpointId(0).?;

    var tone: Signal = .{};
    const playback = try open(&tone, &rig, .playback, sink);
    try playback.start();
    try std.testing.expect(try rig.pump(3000, playback, isRunning));

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const recorder = try Recorder.init(rig.ctx, &aw.writer, .{
        .format = stereo,
        .device = sink,
        .encode = .{ .wav = .{ .sample = .f32 } },
    });
    defer recorder.deinit();
    try recorder.start();
    try std.testing.expect(try rig.pump(5000, recorder, recorded));
    try recorder.finish();
    const written = recorder.stats().frames_written;
    try std.testing.expect(written >= 12000);

    var dec: codec.Decoder = try .init(gpa, .{ .bytes = aw.written() }, .auto);
    defer dec.deinit();
    try std.testing.expectEqual(@as(u32, 48000), dec.info().rate);
    try std.testing.expectEqual(@as(u8, 2), dec.info().channels);
    var frames: u64 = 0;
    var peak: f32 = 0;
    var buf: [1024]f32 = undefined;
    while (true) {
        const n = try dec.read(&buf);
        if (n == 0) break;
        frames += n;
        for (buf[0 .. n * 2]) |v| peak = @max(peak, @abs(v));
    }
    try std.testing.expectEqual(written, frames);
    try std.testing.expect(peak > 0.05);
}

/// Returns `.stop` once `limit` callbacks have run.
const Stopper = struct {
    limit: u32 = 100,
    calls: std.atomic.Value(u32) = .init(0),

    fn callback(self: *Stopper) Stream.Callback {
        return .{ .ctx = self, .func = run };
    }

    fn run(ctx: ?*anyopaque, stream: *Stream, buffer: Stream.Buffer) Stream.Status {
        const self: *Stopper = @ptrCast(@alignCast(ctx.?));
        if (stream.options.direction == .playback) @memset(buffer.bytes, 0);
        const n = self.calls.fetchAdd(1, .monotonic) + 1;
        return if (n >= self.limit) .stop else .@"continue";
    }
};

fn nodeState(stream: *Stream, rig: *Rig) ?pipewire.Stream.State {
    const be = rig.ctx.backend.as(PipeWire).?;
    for (be.entries.items) |e| {
        if (e.stream == stream) return e.pw.state();
    }
    return null;
}

fn nodeStreaming(stream: *Stream, rig: *Rig) bool {
    return nodeState(stream, rig) == .streaming;
}

fn nodePaused(stream: *Stream, rig: *Rig) bool {
    return nodeState(stream, rig) == .paused;
}

fn stopLive(direction: Stream.Direction) !void {
    var rig: Rig = undefined;
    try rig.open(1);
    defer rig.close();
    try rig.waitSinks(1);
    const sink = rig.endpointId(0).?;

    var tone: Signal = .{};
    var stopper: Stopper = .{};
    var stream: *Stream = undefined;
    switch (direction) {
        .playback => stream = try rig.ctx.openStream(.{ .direction = .playback, .format = stereo, .device = sink, .callback = stopper.callback() }),
        .capture => {
            const other = try open(&tone, &rig, .playback, sink);
            try other.start();
            try std.testing.expect(try rig.pump(3000, other, isRunning));
            stream = try rig.ctx.openStream(.{ .direction = .capture, .format = stereo, .device = sink, .callback = stopper.callback() });
        },
    }
    try stream.start();
    try std.testing.expect(try rig.pump(3000, stream, nodeStreaming));
    const stopped = try rig.pump(5000, stream, isStopped);
    try std.testing.expect(stopped);
    try std.testing.expect(stopper.calls.load(.monotonic) >= stopper.limit);
    try std.testing.expect(try rig.pump(5000, stream, nodePaused));
}

fn isStopped(stream: *Stream, _: *Rig) bool {
    return stream.state() == .stopped;
}

test "live: a playback callback that returns stop pauses the node" {
    try stopLive(.playback);
}

test "live: a capture callback that returns stop pauses the node" {
    try stopLive(.capture);
}
