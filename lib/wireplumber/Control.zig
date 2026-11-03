//! The control operations of a session manager client: default devices, volume, mute, stream
//! moves, profiles and ports. Each call only sends a request. The model of the `Graph` changes
//! when the server answers.
const std = @import("std");
const pipewire = @import("pipewire");
const Graph = @import("Graph.zig");
const json = @import("json.zig");
const params = @import("params.zig");

const pod = pipewire.pod;

pub const Error = error{
    UnknownObject,
    Unsupported,
    OwnNode,
    InvalidIndex,
    InvalidVolume,
    NoSpace,
} || pipewire.Remote.SendError;

pub const Target = union(enum) { endpoint: Graph.Id, stream: Graph.Id };

/// Asks for the default endpoint. WirePlumber picks the effective default from this request.
pub fn setDefault(graph: *Graph, kind: Graph.EndpointKind, endpoint: Graph.Id) Error!void {
    const e = graph.endpoint(endpoint) orelse return error.UnknownObject;
    if (e.kind != kind or e.name.len == 0) return error.UnknownObject;
    const md = graph.defaultMetadata() orelse return error.Unsupported;
    var buf: [1024]u8 = undefined;
    const value = try json.nameValue(&buf, e.name);
    const key = switch (kind) {
        .sink => "default.configured.audio.sink",
        .source => "default.configured.audio.source",
    };
    try md.setProperty(0, key, "Spa:String:JSON", value);
}

/// Sets linear channel volumes. One value goes to every channel. Otherwise there is one value
/// for each channel that the server reports.
pub fn setVolume(graph: *Graph, target: Target, channel_volumes: []const f32) Error!void {
    const checked = try check(graph, target);
    const known = checked.channels;
    if (channel_volumes.len == 0 or channel_volumes.len > params.max_channels) return error.InvalidVolume;
    for (channel_volumes) |v| {
        if (!std.math.isFinite(v) or v < 0) return error.InvalidVolume;
    }
    if (known > params.max_channels) return error.InvalidVolume;
    var expanded: [params.max_channels]f32 = undefined;
    var vols = channel_volumes;
    if (known > 0) {
        if (channel_volumes.len == 1) {
            @memset(expanded[0..known], channel_volumes[0]);
            vols = expanded[0..known];
        } else if (channel_volumes.len != known) {
            return error.InvalidVolume;
        }
    }
    try write(graph, checked, .{ .channel_volumes = vols });
}

pub fn setMute(graph: *Graph, target: Target, mute: bool) Error!void {
    const checked = try check(graph, target);
    try write(graph, checked, .{ .mute = mute });
}

/// Moves a stream with the `target.object` and `target.node` keys of the `default` metadata.
/// The `node.dont-move` property of the stream is not checked here. The backend decides.
/// A stream of this remote may move too, because metadata does not touch its node.
pub fn moveStream(graph: *Graph, stream: Graph.Id, endpoint: Graph.Id) Error!void {
    const s = graph.stream(stream) orelse return error.UnknownObject;
    const e = graph.endpoint(endpoint) orelse return error.UnknownObject;
    const fits: Graph.EndpointKind = switch (s.direction) {
        .playback => .sink,
        .capture => .source,
    };
    if (e.kind != fits or e.serial == 0) return error.UnknownObject;
    const md = graph.defaultMetadata() orelse return error.Unsupported;
    var buf: [24]u8 = undefined;
    const serial = std.fmt.bufPrint(&buf, "{d}", .{e.serial}) catch return error.NoSpace;
    try md.setProperty(stream, "target.object", "Spa:Id", serial);
    const id = std.fmt.bufPrint(&buf, "{d}", .{e.id}) catch return error.NoSpace;
    try md.setProperty(stream, "target.node", "Spa:Id", id);
}

pub fn setProfile(graph: *Graph, card: Graph.Id, index: u32) Error!void {
    const c = graph.card(card) orelse return error.UnknownObject;
    const device = graph.deviceProxy(card) orelse return error.UnknownObject;
    for (c.profiles) |p| {
        if (p.index != index) continue;
        var buf: [128]u8 = undefined;
        var b = pod.Builder.init(&buf);
        params.buildProfile(&b, index, true) catch |err| return mapBuild(err);
        return device.setParam(.profile, 0, b.bytesWritten());
    }
    return error.InvalidIndex;
}

pub fn setPort(graph: *Graph, endpoint: Graph.Id, index: u32) Error!void {
    const e = graph.endpoint(endpoint) orelse return error.UnknownObject;
    const card = e.card orelse return error.Unsupported;
    const device_index = e.profile_device orelse return error.Unsupported;
    const device = graph.deviceProxy(card) orelse return error.UnknownObject;
    for (e.ports) |p| {
        if (p.index != index) continue;
        var buf: [128]u8 = undefined;
        var b = pod.Builder.init(&buf);
        params.buildRoute(&b, index, device_index, null, true) catch |err| return mapBuild(err);
        return device.setParam(.route, 0, b.bytesWritten());
    }
    return error.InvalidIndex;
}

/// A target that `check` found.
const Checked = struct {
    /// The channel count that the model knows. It is 0 when unknown.
    channels: usize,
    object: union(enum) { stream: Graph.Id, endpoint: *const Graph.Endpoint },
};

/// Checks that the target exists and has a volume.
fn check(graph: *const Graph, target: Target) Error!Checked {
    switch (target) {
        .stream => |id| {
            if (graph.ownsStream(id)) return error.OwnNode;
            const s = graph.stream(id) orelse return error.UnknownObject;
            return .{ .channels = s.volume.count, .object = .{ .stream = id } };
        },
        .endpoint => |id| {
            const e = graph.endpoint(id) orelse return error.UnknownObject;
            if (e.volume_source == .none) return error.Unsupported;
            return .{
                .channels = if (e.volume.count > 0) e.volume.count else e.channels,
                .object = .{ .endpoint = e },
            };
        },
    }
}

fn write(graph: *Graph, checked: Checked, change: params.Change) Error!void {
    var buf: [1024]u8 = undefined;
    var b = pod.Builder.init(&buf);
    switch (checked.object) {
        .stream => |id| {
            const node = graph.nodeProxy(id) orelse return error.UnknownObject;
            try buildProps(&b, change);
            try node.setParam(.props, 0, b.bytesWritten());
        },
        .endpoint => |e| switch (e.volume_source) {
            .none => return error.Unsupported,
            .route => {
                const index = graph.volumeRoute(e.id) orelse return error.Unsupported;
                const device = graph.deviceProxy(e.card orelse return error.Unsupported) orelse return error.UnknownObject;
                try buildRoute(&b, index, e.profile_device orelse return error.Unsupported, change);
                try device.setParam(.route, 0, b.bytesWritten());
            },
            .props => {
                const node = graph.nodeProxy(e.id) orelse return error.UnknownObject;
                try buildProps(&b, change);
                try node.setParam(.props, 0, b.bytesWritten());
            },
        },
    }
}

fn buildProps(b: *pod.Builder, change: params.Change) Error!void {
    params.buildProps(b, change) catch |err| return mapBuild(err);
}

fn buildRoute(b: *pod.Builder, index: u32, device: u32, change: params.Change) Error!void {
    params.buildRoute(b, index, device, change, true) catch |err| return mapBuild(err);
}

fn mapBuild(err: params.BuildError) Error {
    return switch (err) {
        error.NoSpace => error.NoSpace,
        error.TooMany => error.InvalidVolume,
    };
}

const testing = std.testing;
const tgpa = testing.allocator;
const support = @import("testing.zig");
const Fixture = support.Fixture;
const Bind = support.Bind;

/// A card with a sink 41 on the Route path, a source 42 and a stream 43 on the sink, plus the
/// `default` metadata as global 60.
fn setup(f: *Fixture) !Bind {
    try f.populate();
    try support.fillCard(f, f.bindOf(40));
    return f.bindMetadata(60, "default");
}

fn expectMetadata(f: *Fixture, md: Bind, subject: u32, key: []const u8, ty: []const u8, value: []const u8) !void {
    var m = try f.rig.expectMessage(md.new_id, 1);
    defer m.deinit(tgpa);
    var buf: [512]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const s = try b.beginStruct();
    try b.int(@bitCast(subject));
    try b.string(key);
    try b.string(ty);
    try b.string(value);
    b.end(s);
    try testing.expectEqualSlices(u8, b.bytesWritten(), m.body);
}

fn expectParam(f: *Fixture, bind: Bind, id: u32, spec: anytype) !void {
    var m = try f.rig.expectMessage(bind.new_id, 3);
    defer m.deinit(tgpa);
    var buf: [512]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const s = try b.beginStruct();
    try b.id(id);
    try b.int(0);
    try spec(&b);
    b.end(s);
    try testing.expectEqualSlices(u8, b.bytesWritten(), m.body);
}

const RouteVolume = struct {
    volumes: []const f32 = &.{},
    mute: ?bool = null,

    fn build(self: RouteVolume, b: *pod.Builder) !void {
        try params.buildRoute(b, 5, 3, .{
            .channel_volumes = if (self.volumes.len > 0) self.volumes else null,
            .mute = self.mute,
        }, true);
    }
};

test "setDefault writes the configured name of the sink" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const md = try setup(&f);
    try setDefault(f.graph, .sink, 41);
    try expectMetadata(&f, md, 0, "default.configured.audio.sink", "Spa:String:JSON", "{\"name\":\"alsa_output.test\"}");
    try setDefault(f.graph, .source, 42);
    try expectMetadata(&f, md, 0, "default.configured.audio.source", "Spa:String:JSON", "{\"name\":\"alsa_input.test\"}");

    try testing.expectError(error.UnknownObject, setDefault(f.graph, .source, 41));
    try testing.expectError(error.UnknownObject, setDefault(f.graph, .sink, 999));
}

test "setDefault without the default metadata is unsupported" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    try testing.expectError(error.Unsupported, setDefault(f.graph, .sink, 41));
}

test "setVolume on the route path sends a Route with the volumes and save" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try setup(&f);
    const dev = f.bindOf(40);

    try setVolume(f.graph, .{ .endpoint = 41 }, &.{ 0.25, 0.5 });
    try expectParam(&f, dev, 13, struct {
        fn build(b: *pod.Builder) !void {
            try (RouteVolume{ .volumes = &.{ 0.25, 0.5 } }).build(b);
        }
    }.build);

    // One value goes to both channels.
    try setVolume(f.graph, .{ .endpoint = 41 }, &.{0.125});
    try expectParam(&f, dev, 13, struct {
        fn build(b: *pod.Builder) !void {
            try (RouteVolume{ .volumes = &.{ 0.125, 0.125 } }).build(b);
        }
    }.build);

    // The model keeps the old value until the server answers.
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.5 }, f.graph.endpoint(41).?.volume.channels());
}

test "setVolume on the props path sends Props to the node" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try setup(&f);
    try f.addNode(50, "Audio/Sink", "plain");
    try f.param(f.bindOf(50), 2, 0, support.PropsSpec{ .volumes = &.{ 0.2, 0.4 }, .mute = false });
    try f.commit();
    const bind = f.bindOf(50);

    try setVolume(f.graph, .{ .endpoint = 50 }, &.{ 0.3, 0.6 });
    try expectParam(&f, bind, 2, struct {
        fn build(b: *pod.Builder) !void {
            try params.buildProps(b, .{ .channel_volumes = &.{ 0.3, 0.6 } });
        }
    }.build);

    try setMute(f.graph, .{ .endpoint = 50 }, true);
    try expectParam(&f, bind, 2, struct {
        fn build(b: *pod.Builder) !void {
            try params.buildProps(b, .{ .mute = true });
        }
    }.build);
}

test "setMute on the route path sends only the mute" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try setup(&f);
    try setMute(f.graph, .{ .endpoint = 41 }, true);
    try expectParam(&f, f.bindOf(40), 13, struct {
        fn build(b: *pod.Builder) !void {
            try (RouteVolume{ .mute = true }).build(b);
        }
    }.build);
}

test "setVolume on a stream sends Props to its node" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try setup(&f);
    try setVolume(f.graph, .{ .stream = 43 }, &.{0.5});
    try expectParam(&f, f.bindOf(43), 2, struct {
        fn build(b: *pod.Builder) !void {
            try params.buildProps(b, .{ .channel_volumes = &.{0.5} });
        }
    }.build);
}

test "volume checks" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try setup(&f);
    const nan = std.math.nan(f32);
    try testing.expectError(error.InvalidVolume, setVolume(f.graph, .{ .endpoint = 41 }, &.{nan}));
    try testing.expectError(error.InvalidVolume, setVolume(f.graph, .{ .endpoint = 41 }, &.{std.math.inf(f32)}));
    try testing.expectError(error.InvalidVolume, setVolume(f.graph, .{ .endpoint = 41 }, &.{-0.5}));
    try testing.expectError(error.InvalidVolume, setVolume(f.graph, .{ .endpoint = 41 }, &.{}));
    // The sink has two channels.
    try testing.expectError(error.InvalidVolume, setVolume(f.graph, .{ .endpoint = 41 }, &.{ 0.1, 0.2, 0.3 }));
    try testing.expectError(error.UnknownObject, setVolume(f.graph, .{ .endpoint = 999 }, &.{0.5}));
    try testing.expectError(error.UnknownObject, setMute(f.graph, .{ .stream = 999 }, true));
    // The source has no volume that a mixer can use.
    try testing.expectError(error.Unsupported, setMute(f.graph, .{ .endpoint = 42 }, true));
    try pipewire.testing.util.expectQuiet(&f.rig.server, 50);
}

test "an exported stream gives OwnNode" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try setup(&f);

    const exported = try f.rig.remote.createObjectAs(pipewire.ClientNode, .client_node, "client-node", &.{});
    var created = try f.rig.expectMessage(0, 6);
    created.deinit(tgpa);
    var buf: [64]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const s = try b.beginStruct();
    try b.int(@bitCast(exported.proxy.id));
    try b.int(43);
    try b.dict(&.{});
    b.end(s);
    try f.rig.server.send(0, 8, b.bytesWritten(), &.{});
    try f.rig.remote.dispatch();

    try testing.expectError(error.OwnNode, setVolume(f.graph, .{ .stream = 43 }, &.{0.5}));
    try testing.expectError(error.OwnNode, setMute(f.graph, .{ .stream = 43 }, true));
    try pipewire.testing.util.expectQuiet(&f.rig.server, 50);
}

test "moveStream writes target.object and target.node" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const md = try setup(&f);
    try f.addNode(50, "Audio/Sink", "other");

    // A node without a serial cannot be a target.
    try testing.expectError(error.UnknownObject, moveStream(f.graph, 43, 50));
    try pipewire.testing.util.expectQuiet(&f.rig.server, 50);

    try moveStream(f.graph, 43, 41);
    try expectMetadata(&f, md, 43, "target.object", "Spa:Id", "141");
    try expectMetadata(&f, md, 43, "target.node", "Spa:Id", "41");
}

test "moveStream on an exported stream writes metadata and no param" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const md = try setup(&f);

    const exported = try f.rig.remote.createObjectAs(pipewire.ClientNode, .client_node, "client-node", &.{});
    var created = try f.rig.expectMessage(0, 6);
    created.deinit(tgpa);
    var buf: [64]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const s = try b.beginStruct();
    try b.int(@bitCast(exported.proxy.id));
    try b.int(43);
    try b.dict(&.{});
    b.end(s);
    try f.rig.server.send(0, 8, b.bytesWritten(), &.{});
    try f.rig.remote.dispatch();
    try testing.expect(f.graph.ownsStream(43));

    try moveStream(f.graph, 43, 41);
    try expectMetadata(&f, md, 43, "target.object", "Spa:Id", "141");
    try expectMetadata(&f, md, 43, "target.node", "Spa:Id", "41");
    try pipewire.testing.util.expectQuiet(&f.rig.server, 50);
}

test "moveStream checks the direction" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try setup(&f);
    try f.global(70, "PipeWire:Interface:Node", &.{
        .{ "media.class", "Stream/Input/Audio" },
        .{ "object.serial", "170" },
        .{ "node.name", "recorder" },
    });
    const bind = try f.readBind();
    try f.nodeInfo(bind, 0b11111, &.{.{ "node.name", "recorder" }});
    try testing.expectEqual(Graph.Direction.capture, f.graph.stream(70).?.direction);

    try testing.expectError(error.UnknownObject, moveStream(f.graph, 70, 41));
    try testing.expectError(error.UnknownObject, moveStream(f.graph, 43, 42));
    try testing.expectError(error.UnknownObject, moveStream(f.graph, 999, 41));
    try testing.expectError(error.UnknownObject, moveStream(f.graph, 43, 999));
    try pipewire.testing.util.expectQuiet(&f.rig.server, 50);

    try moveStream(f.graph, 70, 42);
}

test "setProfile sends the index and save" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try setup(&f);
    try setProfile(f.graph, 40, 0);
    try expectParam(&f, f.bindOf(40), 9, struct {
        fn build(b: *pod.Builder) !void {
            try params.buildProfile(b, 0, true);
        }
    }.build);
    try testing.expectError(error.InvalidIndex, setProfile(f.graph, 40, 9));
    try testing.expectError(error.UnknownObject, setProfile(f.graph, 41, 0));
    try pipewire.testing.util.expectQuiet(&f.rig.server, 50);
}

test "setPort sends the route index, the device and save" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try setup(&f);
    try setPort(f.graph, 41, 6);
    try expectParam(&f, f.bindOf(40), 13, struct {
        fn build(b: *pod.Builder) !void {
            try params.buildRoute(b, 6, 3, null, true);
        }
    }.build);
    // Route 7 belongs to another device.
    try testing.expectError(error.InvalidIndex, setPort(f.graph, 41, 7));
    try testing.expectError(error.UnknownObject, setPort(f.graph, 999, 5));
    try pipewire.testing.util.expectQuiet(&f.rig.server, 50);
}

test "a node without a name is not a default" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try setup(&f);
    try f.global(50, "PipeWire:Interface:Node", &.{.{ "media.class", "Audio/Sink" }});
    const bind = try f.readBind();
    try f.nodeInfo(bind, 0b11111, &.{});
    try testing.expectError(error.UnknownObject, setDefault(f.graph, .sink, 50));
    try pipewire.testing.util.expectQuiet(&f.rig.server, 50);
}

test "a long node name gives NoSpace" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try setup(&f);
    const name: [1100]u8 = @splat('n');
    try f.addNode(50, "Audio/Sink", &name);
    try testing.expectError(error.NoSpace, setDefault(f.graph, .sink, 50));
    try pipewire.testing.util.expectQuiet(&f.rig.server, 50);
}

test "a props volume needs one value or one for each channel" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try setup(&f);
    try f.addNode(50, "Audio/Sink", "plain");
    try f.param(f.bindOf(50), 2, 0, support.PropsSpec{ .volumes = &.{ 0.2, 0.4 }, .mute = false });
    try f.commit();
    try testing.expectError(error.InvalidVolume, setVolume(f.graph, .{ .endpoint = 50 }, &.{ 0.1, 0.2, 0.3 }));
    try pipewire.testing.util.expectQuiet(&f.rig.server, 50);
}

test "a channel count above the limit is unknown" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try setup(&f);
    try f.global(50, "PipeWire:Interface:Node", &.{ .{ "media.class", "Audio/Sink" }, .{ "node.name", "wide" } });
    const bind = try f.readBind();
    try f.nodeInfo(bind, 0b11111, &.{ .{ "node.name", "wide" }, .{ "audio.channels", "100" } });
    try testing.expectEqual(@as(u32, 0), f.graph.endpoint(50).?.channels);
    try testing.expectEqual(@as(u64, 1), f.graph.stats.bad_params);

    // Props with two channels make the volume usable, and one value fills those two.
    try f.param(bind, 2, 0, support.PropsSpec{ .volumes = &.{ 0.2, 0.4 }, .mute = false });
    try f.commit();
    try setVolume(f.graph, .{ .endpoint = 50 }, &.{0.5});
    try expectParam(&f, bind, 2, struct {
        fn build(b: *pod.Builder) !void {
            try params.buildProps(b, .{ .channel_volumes = &.{ 0.5, 0.5 } });
        }
    }.build);
}

test "a card whose proxy is gone gives UnknownObject" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try setup(&f);
    try f.globalRemove(40);
    try testing.expectEqual(@as(?*pipewire.Device, null), f.graph.deviceProxy(40));
    try testing.expectError(error.UnknownObject, setPort(f.graph, 41, 5));
    try testing.expectError(error.UnknownObject, setProfile(f.graph, 40, 0));
    try pipewire.testing.util.expectQuiet(&f.rig.server, 50);
}
