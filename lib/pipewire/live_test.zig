//! Tests against the real PipeWire daemon. Each test skips when no daemon answers.
const std = @import("std");
const pod = @import("pod.zig");
const spa = @import("spa.zig");
const DataLoop = @import("DataLoop.zig");
const Stream = @import("Stream.zig");
const Node = @import("Node.zig");
const Builder = pod.Builder;
const shared = @import("testing/live.zig");
const Live = shared.Live;
const pump = shared.pump;
const pumpBoth = shared.pumpBoth;
const sinkName = shared.sinkName;
const requireWirePlumber = shared.requireWirePlumber;
const no_restore = shared.no_restore;
const makeSink = shared.makeSink;
const destroyOrPanic = shared.destroyOrPanic;

const gpa = std.testing.allocator;

const NodeWait = struct {
    live: *Live,
    name: []const u8,
    fn found(self: NodeWait) bool {
        return self.live.findNode(self.name) != null;
    }
};

const RemovedWait = struct {
    live: *Live,
    id: u32,
    fn gone(self: RemovedWait) bool {
        return self.live.wasRemoved(self.id);
    }
};

test "the daemon answers a roundtrip and lists the core" {
    const live = try Live.open();
    defer live.close();
    try live.remote.roundtrip(2000);
    try live.remote.roundtrip(2000);
    try std.testing.expect(live.core_name != null);
    try std.testing.expect(live.core_name.?.len > 0);
    try std.testing.expect(live.core_globals >= 1);
}

test "a temporary null sink appears in the registry and goes away" {
    const live = try Live.open();
    defer live.close();
    var name_buf: [64]u8 = undefined;
    const name = sinkName(&name_buf, "sink");

    const sink = try makeSink(live, name);
    var destroyed = false;
    defer if (!destroyed) destroyOrPanic(sink);
    try live.remote.roundtrip(2000);
    try live.remote.roundtrip(2000);
    const id = live.findNode(name) orelse return error.SinkNotListed;

    destroyed = true;
    try sink.destroy();
    try live.remote.roundtrip(2000);
    try std.testing.expect(try pump(live, null, 2000, RemovedWait{ .live = live, .id = id }, RemovedWait.gone));
    try std.testing.expectEqual(@as(u32, 0), live.lost);
}

const Audio = struct {
    frames: std.atomic.Value(u32) = .init(0),
    bad_rate: std.atomic.Value(u32) = .init(0),
    peak_milli: std.atomic.Value(u32) = .init(0),
    phase: f32 = 0,
};

fn playProcess(ctx: ?*anyopaque, _: *Stream, b: Stream.Buffers) void {
    const a: *Audio = @ptrCast(@alignCast(ctx.?));
    if (b.rate == 0) {
        _ = a.bad_rate.fetchAdd(1, .monotonic);
        return;
    }
    const step = 2.0 * std.math.pi * 440.0 / @as(f32, @floatFromInt(b.rate));
    for (0..b.frames) |i| {
        const s = 0.1 * @sin(a.phase);
        a.phase += step;
        if (a.phase > 2.0 * std.math.pi) a.phase -= 2.0 * std.math.pi;
        for (b.channels) |ch| ch[i] = s;
    }
    _ = a.frames.fetchAdd(b.frames, .monotonic);
}

fn captureProcess(ctx: ?*anyopaque, _: *Stream, b: Stream.Buffers) void {
    const a: *Audio = @ptrCast(@alignCast(ctx.?));
    if (b.rate == 0) _ = a.bad_rate.fetchAdd(1, .monotonic);
    var peak: f32 = 0;
    for (b.channels) |ch| for (ch[0..b.frames]) |s| {
        peak = @max(peak, @abs(s));
    };
    const milli: u32 = @intFromFloat(@min(peak, 4.0) * 1000.0);
    _ = a.peak_milli.fetchMax(milli, .monotonic);
    _ = a.frames.fetchAdd(b.frames, .monotonic);
}

const StreamWatch = struct {
    state: std.atomic.Value(u32) = .init(@backingInt(Stream.State.connecting)),
    props_seen: std.atomic.Value(u32) = .init(0),
    volume0_milli: std.atomic.Value(u32) = .init(0),
    muted: std.atomic.Value(bool) = .init(false),

    fn onEvent(ctx: ?*anyopaque, _: *Stream, event: Stream.Event) void {
        const self: *StreamWatch = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .state => |s| self.state.store(@backingInt(s), .monotonic),
            .props => |p| {
                self.volume0_milli.store(@intFromFloat(p.channel_volumes[0] * 1000), .monotonic);
                self.muted.store(p.mute, .monotonic);
                _ = self.props_seen.fetchAdd(1, .monotonic);
            },
            else => {},
        }
    }

    fn current(self: *const StreamWatch) Stream.State {
        return @fromBackingInt(@intCast(self.state.load(.monotonic)));
    }
};

const PlayWait = struct {
    watch: *const StreamWatch,
    audio: *const Audio,
    fn ready(self: PlayWait) bool {
        return self.watch.current() == .streaming and self.audio.frames.load(.monotonic) > 4800;
    }
};

const CaptureWait = struct {
    audio: *const Audio,
    fn heard(self: CaptureWait) bool {
        return self.audio.peak_milli.load(.monotonic) > 50;
    }
};

const stereo = [_]spa.AudioChannel{ .fl, .fr };

test "a playback stream gets linked and processes audio" {
    const live = try Live.open();
    defer live.close();
    var name_buf: [64]u8 = undefined;
    const name = sinkName(&name_buf, "play");

    try live.remote.roundtrip(2000);
    try live.remote.roundtrip(2000);
    try requireWirePlumber(live);

    const sink = try makeSink(live, name);
    defer destroyOrPanic(sink);
    try live.remote.roundtrip(2000);

    const loop = try DataLoop.init(gpa, .{});
    defer loop.deinit();
    var audio: Audio = .{};
    var watch: StreamWatch = .{};
    const stream = try Stream.create(live.remote, loop, .{
        .direction = .playback,
        .name = "chorus-live-playback",
        .channels = &stereo,
        .target = name,
        .props = &no_restore,
        .process = .{ .ctx = &audio, .func = playProcess },
        .listener = .{ .ctx = &watch, .func = StreamWatch.onEvent },
    });
    defer stream.destroy();

    const ok = try pump(live, loop, 3000, PlayWait{ .watch = &watch, .audio = &audio }, PlayWait.ready);
    if (!ok or live.core_errors != 0) {
        std.debug.print("state={s} frames={d} core_errors={d} last={s}\n", .{
            @tagName(watch.current()), audio.frames.load(.monotonic), live.core_errors, live.errorText(),
        });
        std.debug.print("cycles={d} skipped={d} missed={d} gaps={d}\n", .{
            stream.stats.cycles.load(.monotonic), stream.stats.skipped.load(.monotonic), stream.stats.missed.load(.monotonic), stream.stats.port_gaps.load(.monotonic),
        });
    }
    try std.testing.expectEqual(Stream.State.streaming, watch.current());
    try std.testing.expect(audio.frames.load(.monotonic) > 4800);
    try std.testing.expectEqual(@as(u32, 0), audio.bad_rate.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), live.core_errors);
}

test "a capture stream reads from the sink monitor" {
    const live = try Live.open();
    defer live.close();
    var name_buf: [64]u8 = undefined;
    const name = sinkName(&name_buf, "cap");

    try live.remote.roundtrip(2000);
    try live.remote.roundtrip(2000);
    try requireWirePlumber(live);

    const sink = try makeSink(live, name);
    defer destroyOrPanic(sink);
    try live.remote.roundtrip(2000);

    const loop = try DataLoop.init(gpa, .{});
    defer loop.deinit();
    var play_audio: Audio = .{};
    var play_watch: StreamWatch = .{};
    const playback = try Stream.create(live.remote, loop, .{
        .direction = .playback,
        .name = "chorus-live-playback",
        .channels = &stereo,
        .target = name,
        .props = &no_restore,
        .process = .{ .ctx = &play_audio, .func = playProcess },
        .listener = .{ .ctx = &play_watch, .func = StreamWatch.onEvent },
    });
    defer playback.destroy();

    var cap_audio: Audio = .{};
    var cap_watch: StreamWatch = .{};
    const capture = try Stream.create(live.remote, loop, .{
        .direction = .capture,
        .name = "chorus-live-capture",
        .channels = &stereo,
        .target = name,
        .props = &(no_restore ++ [_][2][]const u8{.{ "stream.capture.sink", "true" }}),
        .process = .{ .ctx = &cap_audio, .func = captureProcess },
        .listener = .{ .ctx = &cap_watch, .func = StreamWatch.onEvent },
    });
    defer capture.destroy();

    const ok = try pump(live, loop, 3000, CaptureWait{ .audio = &cap_audio }, CaptureWait.heard);
    if (!ok) {
        std.debug.print("play={s} cap={s} cap_frames={d} peak_milli={d} core_errors={d} last={s}\n", .{
            @tagName(play_watch.current()),
            @tagName(cap_watch.current()),
            cap_audio.frames.load(.monotonic),
            cap_audio.peak_milli.load(.monotonic),
            live.core_errors,
            live.errorText(),
        });
    }
    try std.testing.expect(ok);
    try std.testing.expect(cap_audio.peak_milli.load(.monotonic) > 50);
    try std.testing.expectEqual(Stream.State.streaming, play_watch.current());
    try std.testing.expectEqual(@as(u32, 0), live.core_errors);
}

/// Records the first channel volume of the Props params that a Node proxy reports.
const VolumeRead = struct {
    seq: i32 = 0,
    hit: bool = false,
    volume0_milli: u32 = 0,

    fn on(ctx: ?*anyopaque, _: *Node, event: Node.Event) void {
        const self: *VolumeRead = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .param => |p| {
                if (p.id != .props or p.seq != self.seq) return;
                const obj = p.param.object() catch return;
                var it = obj.props();
                while (it.next() catch return) |prop| {
                    if (prop.key != @backingInt(spa.PropKey.channel_volumes)) continue;
                    const array = (prop.value.unwrap() catch return).array() catch return;
                    var items = array.items();
                    const first = items.next() orelse return;
                    self.volume0_milli = @intFromFloat((first.float() catch return) * 1000 + 0.5);
                    self.hit = true;
                }
            },
            else => {},
        }
    }
};

const Volume500 = struct {
    watch: *const StreamWatch,
    fn seen(self: Volume500) bool {
        return self.watch.volume0_milli.load(.monotonic) == 500;
    }
};

const BothFound = struct {
    a: *Live,
    b: *Live,
    name: []const u8,
    fn found(self: BothFound) bool {
        return self.a.findNode(self.name) != null and self.b.findNode(self.name) != null;
    }
};

const ReadHit = struct {
    read: *const VolumeRead,
    fn hit(self: ReadHit) bool {
        return self.read.hit;
    }
};

test "a volume set from a second connection reaches the stream and reads back" {
    const live = try Live.open();
    defer live.close();
    try live.remote.roundtrip(2000);
    try live.remote.roundtrip(2000);
    try requireWirePlumber(live);
    const other = try Live.open();
    defer other.close();

    const loop = try DataLoop.init(gpa, .{});
    defer loop.deinit();
    var audio: Audio = .{};
    var watch: StreamWatch = .{};
    const stream = try Stream.create(live.remote, loop, .{
        .direction = .playback,
        .name = "chorus-live-volume",
        .channels = &stereo,
        .autoconnect = false,
        .props = &no_restore,
        .process = .{ .ctx = &audio, .func = playProcess },
        .listener = .{ .ctx = &watch, .func = StreamWatch.onEvent },
    });
    defer stream.destroy();

    const both = BothFound{ .a = live, .b = other, .name = "chorus-live-volume" };
    try std.testing.expect(try pumpBoth(live, other, 3000, both, BothFound.found));
    const id = live.findNode("chorus-live-volume").?;

    // The exporting connection cannot set a param on its own node.
    const own = try live.registry.bind(id, Node, null);
    defer destroyOrPanic(&own.proxy);
    try std.testing.expectError(error.OwnNode, own.setParam(.props, 0, ""));

    const node = try other.registry.bind(other.findNode("chorus-live-volume").?, Node, null);
    defer destroyOrPanic(&node.proxy);
    var read: VolumeRead = .{ .seq = 77 };
    node.listener = .{ .ctx = &read, .func = VolumeRead.on };

    var buf: [256]u8 = undefined;
    var b = Builder.init(&buf);
    const o = try b.beginObject(@backingInt(spa.ObjectType.props), @backingInt(spa.ParamType.props));
    try b.prop(@backingInt(spa.PropKey.channel_volumes), .{});
    const a = try b.beginArray();
    try b.float(0.5);
    try b.float(0.5);
    b.end(a);
    b.end(o);
    try node.setParam(.props, 0, b.bytesWritten());
    try std.testing.expect(try pumpBoth(live, other, 3000, Volume500{ .watch = &watch }, Volume500.seen));

    try node.enumParams(77, .props, 0, 0, null);
    try std.testing.expect(try pumpBoth(live, other, 3000, ReadHit{ .read = &read }, ReadHit.hit));
    try std.testing.expectEqual(@as(u32, 500), read.volume0_milli);
    try std.testing.expectEqual(@as(u32, 0), live.core_errors);
    try std.testing.expectEqual(@as(u32, 0), other.core_errors);
}
