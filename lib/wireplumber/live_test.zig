//! Tests against the real PipeWire daemon and WirePlumber. Each test skips when they are missing.
//! Every node that a test creates carries the no_restore props, so no state is saved.
const std = @import("std");
const pipewire = @import("pipewire");
const Graph = @import("Graph.zig");
const Control = @import("Control.zig");

const live = pipewire.testing.live;
const Live = live.Live;
const DataLoop = pipewire.DataLoop;
const Stream = pipewire.Stream;
const makeSink = live.makeSink;
const sinkName = live.sinkName;
const destroyOrPanic = live.destroyOrPanic;
const no_restore = live.no_restore;

const gpa = std.testing.allocator;

/// Waits for both connections.
fn pump(pair: Pair, ms: i64, ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool) !bool {
    return live.pumpBoth(pair.graph_conn, pair.owner, ms, ctx, done);
}

/// Like `pump`, and it runs the data loop of a test stream that has no thread.
fn pumpWithLoop(pair: Pair, loop: *DataLoop, ms: i64, ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool) !bool {
    const deadline = live.nowMs() + ms;
    while (true) {
        if (loop.thread == null) try loop.iterate(0);
        if (try pump(pair, 5, ctx, done)) return true;
        if (live.nowMs() >= deadline) return false;
    }
}

fn findEndpoint(graph: *const Graph, name: []const u8) ?Graph.Endpoint {
    for (graph.endpoints()) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

fn findStream(graph: *const Graph, app: []const u8) ?Graph.AppStream {
    for (graph.streams()) |s| if (std.mem.eql(u8, s.app_name, app)) return s;
    return null;
}

/// Opens the graph connection and the connection that owns the test objects.
const Pair = struct {
    graph_conn: *Live,
    owner: *Live,
    graph_ptr: *Graph,

    fn open() !Pair {
        const owner = try Live.open();
        errdefer owner.close();
        const graph_conn = try Live.open();
        errdefer graph_conn.close();
        const graph_ptr = try Graph.init(gpa, graph_conn.remote, .{});
        errdefer graph_ptr.deinit();
        try owner.remote.roundtrip(2000);
        try graph_conn.remote.roundtrip(2000);
        return .{ .graph_conn = graph_conn, .owner = owner, .graph_ptr = graph_ptr };
    }

    fn close(self: Pair) void {
        self.graph_ptr.deinit();
        self.graph_conn.close();
        self.owner.close();
    }

    fn graph(self: Pair) *Graph {
        return self.graph_ptr;
    }
};

const EndpointWait = struct {
    pair: Pair,
    name: []const u8,
    fn seen(self: EndpointWait) bool {
        const e = findEndpoint(self.pair.graph(), self.name) orelse return false;
        return e.volume_source == .props and e.volume.count == 2;
    }
};

const VolumeWait = struct {
    pair: Pair,
    name: []const u8,
    value: f32,
    fn seen(self: VolumeWait) bool {
        const e = findEndpoint(self.pair.graph(), self.name) orelse return false;
        return e.volume.count == 2 and e.volume.channel_volumes[0] == self.value and e.volume.channel_volumes[1] == self.value;
    }
};

test "the graph lists a temporary sink with its volume" {
    const pair = try Pair.open();
    defer pair.close();
    var name_buf: [64]u8 = undefined;
    const name = sinkName(&name_buf, "list");

    const sink = try makeSink(pair.owner, name);
    defer destroyOrPanic(sink);
    try std.testing.expect(try pump(pair, 2000, EndpointWait{ .pair = pair, .name = name }, EndpointWait.seen));
    const e = findEndpoint(pair.graph(), name).?;
    try std.testing.expectEqual(Graph.EndpointKind.sink, e.kind);
    try std.testing.expectEqual(@as(u32, 2), e.channels);
    try std.testing.expectEqual(Graph.VolumeSource.props, e.volume_source);
}

test "endpoint volume on a temporary sink round trips" {
    const pair = try Pair.open();
    defer pair.close();
    var name_buf: [64]u8 = undefined;
    const name = sinkName(&name_buf, "volume");

    const sink = try makeSink(pair.owner, name);
    defer destroyOrPanic(sink);
    try std.testing.expect(try pump(pair, 2000, EndpointWait{ .pair = pair, .name = name }, EndpointWait.seen));
    const id = findEndpoint(pair.graph(), name).?.id;

    try Control.setVolume(pair.graph(), .{ .endpoint = id }, &.{0.25});
    try std.testing.expect(try pump(pair, 2000, VolumeWait{ .pair = pair, .name = name, .value = 0.25 }, VolumeWait.seen));
    const e = pair.graph().endpoint(id).?;
    try std.testing.expectEqual(@as(u8, 2), e.volume.count);
    try std.testing.expectEqual(@as(f32, 0.25), e.volume.channel_volumes[0]);
    try std.testing.expectEqual(@as(f32, 0.25), e.volume.channel_volumes[1]);
}

const stereo = [_]pipewire.spa.AudioChannel{ .fl, .fr };

fn silence(_: ?*anyopaque, _: *Stream, b: Stream.Buffers) void {
    for (b.channels) |ch| @memset(ch[0..b.frames], 0);
}

const StreamTarget = struct {
    pair: Pair,
    app: []const u8,
    target: Graph.Id,
    fn onTarget(self: StreamTarget) bool {
        const s = findStream(self.pair.graph(), self.app) orelse return false;
        return s.target != null and s.target.? == self.target;
    }
};

test "a test stream moves between two temporary sinks" {
    const pair = try Pair.open();
    defer pair.close();
    // Moves need the session manager. Without it the test skips.
    if (!pair.owner.wireplumber) return error.SkipZigTest;
    var a_buf: [64]u8 = undefined;
    var b_buf: [64]u8 = undefined;
    const name_a = sinkName(&a_buf, "move-a");
    const name_b = sinkName(&b_buf, "move-b");

    const sink_a = try makeSink(pair.owner, name_a);
    defer destroyOrPanic(sink_a);
    const sink_b = try makeSink(pair.owner, name_b);
    defer destroyOrPanic(sink_b);
    try std.testing.expect(try pump(pair, 2000, EndpointWait{ .pair = pair, .name = name_a }, EndpointWait.seen));
    try std.testing.expect(try pump(pair, 2000, EndpointWait{ .pair = pair, .name = name_b }, EndpointWait.seen));
    const id_a = findEndpoint(pair.graph(), name_a).?.id;
    const id_b = findEndpoint(pair.graph(), name_b).?.id;

    const loop = try DataLoop.init(gpa, .{});
    defer loop.deinit();
    const app = "chorus-wp-live-stream";
    const stream = try Stream.create(pair.owner.remote, loop, .{
        .direction = .playback,
        .name = app,
        .channels = &stereo,
        .target = name_a,
        .props = &no_restore,
        .process = .{ .ctx = null, .func = silence },
    });
    defer stream.destroy();

    try std.testing.expect(try pumpWithLoop(pair, loop, 3000, StreamTarget{ .pair = pair, .app = app, .target = id_a }, StreamTarget.onTarget));
    const sid = findStream(pair.graph(), app).?.id;
    try Control.moveStream(pair.graph(), sid, id_b);
    try std.testing.expect(try pumpWithLoop(pair, loop, 3000, StreamTarget{ .pair = pair, .app = app, .target = id_b }, StreamTarget.onTarget));
    try std.testing.expectEqual(id_b, pair.graph().stream(sid).?.target.?);
}
