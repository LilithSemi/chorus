//! Test support for the model and the control calls: a Graph over a fake server.
const std = @import("std");
const pipewire = @import("pipewire");
const Graph = @import("Graph.zig");
const json = @import("json.zig");

const Change = Graph.Change;
const testing = std.testing;
const tgpa = testing.allocator;
const Rig = pipewire.testing.Rig;
const util = pipewire.testing.util;

pub const Rec = struct {
    events: [32]Change = undefined,
    n: usize = 0,
    /// Counts events whose object was not in the model as the event says.
    model_miss: u32 = 0,

    pub fn on(ctx: ?*anyopaque, graph: *Graph, change: Change) void {
        const self: *Rec = @ptrCast(@alignCast(ctx.?));
        self.events[self.n] = change;
        self.n += 1;
        const miss = switch (change) {
            .card_added, .card_changed => |id| graph.card(id) == null,
            .card_removed => |id| graph.card(id) != null,
            .endpoint_added, .endpoint_changed => |id| graph.endpoint(id) == null,
            .endpoint_removed => |id| graph.endpoint(id) != null,
            .stream_added, .stream_changed => |id| graph.stream(id) == null,
            .stream_removed => |id| graph.stream(id) != null,
            .default_changed, .settings_changed => false,
        };
        if (miss) self.model_miss += 1;
    }

    pub fn slice(self: *const Rec) []const Change {
        return self.events[0..self.n];
    }

    pub fn clear(self: *Rec) void {
        self.n = 0;
    }
};

pub const Prop = [2][]const u8;
pub const device_type = "PipeWire:Interface:Device";
pub const node_type = "PipeWire:Interface:Node";
pub const link_type = "PipeWire:Interface:Link";
pub const metadata_type = "PipeWire:Interface:Metadata";

pub const Bind = struct { global: u32, new_id: u32 };

pub const PropsSpec = struct {
    volumes: ?[]const f32 = null,
    mute: ?bool = null,
    /// An object that ends inside a property.
    cut: bool = false,

    pub fn write(self: PropsSpec, b: *pipewire.pod.Builder) !void {
        if (self.cut) {
            const words = [_]u32{ 16, 0xf, 0x40002, 2, 0x10008, 0 };
            @memcpy(b.buf[b.pos..][0..24], std.mem.asBytes(&words));
            b.pos += 24;
            return;
        }
        const o = try b.beginObject(0x40002, 2);
        if (self.volumes) |vols| {
            try b.prop(0x10008, .{});
            const a = try b.beginArray();
            for (vols) |v| try b.float(v);
            b.end(a);
        }
        if (self.mute) |m| {
            try b.prop(0x10004, .{});
            try b.boolean(m);
        }
        b.end(o);
    }
};

pub const RouteSpec = struct {
    index: i32,
    direction: u32 = 1,
    device: ?i32 = null,
    name: []const u8 = "",
    priority: i32 = 0,
    available: u32 = 2,
    profiles: ?[]const i32 = null,
    devices: []const i32 = &.{},
    profile: ?i32 = null,
    props: ?PropsSpec = null,

    pub fn write(self: RouteSpec, b: *pipewire.pod.Builder) !void {
        const o = try b.beginObject(0x40009, 13);
        try b.prop(1, .{});
        try b.int(self.index);
        try b.prop(2, .{});
        try b.id(self.direction);
        if (self.device) |d| {
            try b.prop(3, .{});
            try b.int(d);
        }
        try b.prop(4, .{});
        try b.string(self.name);
        try b.prop(6, .{});
        try b.int(self.priority);
        try b.prop(7, .{});
        try b.id(self.available);
        if (self.profiles) |ps| try ints(b, 9, ps);
        if (self.devices.len > 0) try ints(b, 11, self.devices);
        if (self.profile) |p| {
            try b.prop(12, .{});
            try b.int(p);
        }
        if (self.props) |p| {
            try b.prop(10, .{});
            try p.write(b);
        }
        b.end(o);
    }

    pub fn ints(b: *pipewire.pod.Builder, key: u32, items: []const i32) !void {
        try b.prop(key, .{});
        const a = try b.beginArray();
        for (items) |i| try b.int(i);
        b.end(a);
    }
};

pub const ProfileSpec = struct {
    index: i32,
    name: []const u8 = "",
    description: []const u8 = "",
    available: u32 = 2,

    pub fn write(self: ProfileSpec, b: *pipewire.pod.Builder) !void {
        const o = try b.beginObject(0x40007, 9);
        try b.prop(1, .{});
        try b.int(self.index);
        try b.prop(2, .{});
        try b.string(self.name);
        try b.prop(3, .{});
        try b.string(self.description);
        try b.prop(5, .{});
        try b.id(self.available);
        b.end(o);
    }
};

pub const Fixture = struct {
    rig: Rig,
    graph: *Graph,
    rec: Rec,

    pub fn init(self: *Fixture) !void {
        self.rec = .{};
        self.rig = try Rig.init();
        errdefer self.rig.deinit();
        self.graph = try Graph.init(tgpa, self.rig.remote, .{ .listener = .{ .ctx = &self.rec, .func = Rec.on } });
        errdefer self.graph.deinit();
        try self.rig.remote.dispatch();
        var m = try self.rig.server.expect(0, 5);
        m.deinit(tgpa);
    }

    pub fn deinit(self: *Fixture) void {
        self.graph.deinit();
        self.rig.deinit();
    }

    pub fn global(self: *Fixture, id: u32, ty: []const u8, props: []const Prop) !void {
        var buf: [4096]u8 = undefined;
        var b = pipewire.pod.Builder.init(&buf);
        const f = try b.beginStruct();
        try b.int(@bitCast(id));
        try b.int(0o400);
        try b.string(ty);
        try b.int(3);
        try b.dict(props);
        b.end(f);
        try self.rig.server.send(self.graph.registryId(), 0, b.bytesWritten(), &.{});
        try self.rig.remote.dispatch();
    }

    pub fn globalRemove(self: *Fixture, id: u32) !void {
        var buf: [64]u8 = undefined;
        try self.rig.server.send(self.graph.registryId(), 1, util.ints(&buf, &.{@bitCast(id)}), &.{});
        try self.rig.remote.dispatch();
    }

    pub fn removeId(self: *Fixture, id: u32) !void {
        var buf: [64]u8 = undefined;
        try self.rig.server.send(0, 4, util.ints(&buf, &.{@bitCast(id)}), &.{});
        try self.rig.remote.dispatch();
    }

    /// Reads a bind request. A device or a node also gets a param subscription, and its sync
    /// is answered.
    pub fn readBind(self: *Fixture) !Bind {
        return self.readBindWith(true);
    }

    pub fn readBindWith(self: *Fixture, answer: bool) !Bind {
        var m = try self.rig.server.expect(self.graph.registryId(), 1);
        defer m.deinit(tgpa);
        var it = try util.fieldsOf(m.body);
        const g = try util.nextInt(&it);
        const ty = (try (try it.next()).?.string()).?;
        _ = try util.nextInt(&it);
        const n = try util.nextInt(&it);
        const bind: Bind = .{ .global = @intCast(g), .new_id = @intCast(n) };
        if (std.mem.eql(u8, ty, device_type)) {
            try self.expectSubscribe(bind, &.{ 8, 9, 12, 13 });
            if (answer) try self.commit();
        } else if (std.mem.eql(u8, ty, node_type)) {
            try self.expectSubscribe(bind, &.{2});
            if (answer) try self.commit();
        }
        return bind;
    }

    pub fn expectSubscribe(self: *Fixture, bind: Bind, ids: []const u32) !void {
        var m = try self.rig.server.expect(bind.new_id, 1);
        defer m.deinit(tgpa);
        var buf: [128]u8 = undefined;
        var b = pipewire.pod.Builder.init(&buf);
        const f = try b.beginStruct();
        const a = try b.beginArray();
        for (ids) |i| try b.id(i);
        b.end(a);
        b.end(f);
        try testing.expectEqualSlices(u8, b.bytesWritten(), m.body);
    }

    /// Answers the Core.sync in flight, so the batch commits. Only one sync is in flight at a time.
    pub fn commit(self: *Fixture) !void {
        try self.rig.remote.dispatch();
        var m = try self.rig.server.expect(0, 2);
        defer m.deinit(tgpa);
        var it = try util.fieldsOf(m.body);
        _ = try util.nextInt(&it);
        const seq = try util.nextInt(&it);
        var buf: [64]u8 = undefined;
        try self.rig.server.send(0, 1, util.ints(&buf, &.{ 0, seq }), &.{});
        try self.rig.remote.dispatch();
    }

    /// The bind of a global that the graph tracks.
    pub fn bindOf(self: *Fixture, global_id: u32) Bind {
        return .{ .global = global_id, .new_id = self.graph.proxyId(global_id).? };
    }

    /// Sends one `param` event. `spec` is a `RouteSpec`, `ProfileSpec` or `PropsSpec`.
    pub fn param(self: *Fixture, bind: Bind, id: u32, at: u32, spec: anytype) !void {
        var buf: [4096]u8 = undefined;
        var b = pipewire.pod.Builder.init(&buf);
        const f = try b.beginStruct();
        try b.int(1);
        try b.id(id);
        try b.int(@intCast(at));
        try b.int(@intCast(at + 1));
        try spec.write(&b);
        b.end(f);
        try self.rig.server.send(bind.new_id, 1, b.bytesWritten(), &.{});
        try self.rig.remote.dispatch();
    }

    pub fn deviceInfo(self: *Fixture, bind: Bind, mask: u64, props: []const Prop) !void {
        try self.deviceInfoParams(bind, mask, props, &.{});
    }

    /// `plist` has pairs of a param id and its flags.
    pub fn deviceInfoParams(self: *Fixture, bind: Bind, mask: u64, props: []const Prop, plist: []const [2]u32) !void {
        var buf: [4096]u8 = undefined;
        var b = pipewire.pod.Builder.init(&buf);
        const f = try b.beginStruct();
        try b.int(@bitCast(bind.global));
        try b.long(@bitCast(mask));
        try b.dict(props);
        const pf = try b.beginStruct();
        try b.int(@intCast(plist.len));
        for (plist) |item| {
            try b.id(item[0]);
            try b.int(@bitCast(item[1]));
        }
        b.end(pf);
        b.end(f);
        try self.rig.server.send(bind.new_id, 0, b.bytesWritten(), &.{});
        try self.rig.remote.dispatch();
    }

    pub fn nodeInfo(self: *Fixture, bind: Bind, mask: u64, props: []const Prop) !void {
        var buf: [4096]u8 = undefined;
        var b = pipewire.pod.Builder.init(&buf);
        const f = try b.beginStruct();
        try b.int(@bitCast(bind.global));
        try b.int(0);
        try b.int(0);
        try b.long(@bitCast(mask));
        try b.int(0);
        try b.int(0);
        try b.id(1);
        try b.string(null);
        try b.dict(props);
        const pf = try b.beginStruct();
        try b.int(0);
        b.end(pf);
        b.end(f);
        try self.rig.server.send(bind.new_id, 0, b.bytesWritten(), &.{});
        try self.rig.remote.dispatch();
    }

    pub fn property(self: *Fixture, bind: Bind, subject: u32, key: ?[]const u8, value: ?[]const u8) !void {
        var buf: [512]u8 = undefined;
        var b = pipewire.pod.Builder.init(&buf);
        const f = try b.beginStruct();
        try b.int(@bitCast(subject));
        try b.string(key);
        try b.string(if (value != null) "Spa:String:JSON" else null);
        try b.string(value);
        b.end(f);
        try self.rig.server.send(bind.new_id, 0, b.bytesWritten(), &.{});
        try self.rig.remote.dispatch();
    }

    pub fn defaultName(self: *Fixture, bind: Bind, key: []const u8, name: []const u8) !void {
        var buf: [400]u8 = undefined;
        try self.property(bind, 0, key, try json.nameValue(&buf, name));
    }

    /// A card, a sink, a source and a playback stream linked to the sink.
    pub fn populate(self: *Fixture) !void {
        try self.global(40, device_type, &.{
            .{ "media.class", "Audio/Device" },
            .{ "object.serial", "140" },
            .{ "device.name", "alsa_card.test" },
            .{ "device.description", "Test Card" },
            .{ "device.api", "alsa:acp" },
        });
        try self.global(41, node_type, &.{
            .{ "media.class", "Audio/Sink" },
            .{ "object.serial", "141" },
            .{ "node.name", "alsa_output.test" },
            .{ "node.description", "Test Out" },
            .{ "device.id", "40" },
            .{ "priority.session", "1000" },
        });
        try self.global(42, node_type, &.{
            .{ "media.class", "Audio/Source" },
            .{ "object.serial", "142" },
            .{ "node.name", "alsa_input.test" },
            .{ "node.nick", "Test In" },
            .{ "device.id", "40" },
        });
        try self.global(43, node_type, &.{
            .{ "media.class", "Stream/Output/Audio" },
            .{ "object.serial", "143" },
            .{ "node.name", "player-out" },
            .{ "application.name", "player" },
        });
        try self.global(44, link_type, &.{
            .{ "link.output.node", "43" },
            .{ "link.input.node", "41" },
        });
        const card_bind = try self.readBind();
        const sink_bind = try self.readBind();
        const source_bind = try self.readBind();
        const stream_bind = try self.readBind();
        try testing.expectEqual(@as(u32, 40), card_bind.global);
        try testing.expectEqual(@as(u32, 41), sink_bind.global);
        try testing.expectEqual(@as(u32, 42), source_bind.global);
        try testing.expectEqual(@as(u32, 43), stream_bind.global);
        try util.expectQuiet(&self.rig.server, 50);

        try self.deviceInfo(card_bind, 0b11, &.{
            .{ "device.name", "alsa_card.test" },
            .{ "device.description", "Test Card" },
            .{ "device.api", "alsa:acp" },
            .{ "device.bus", "usb" },
        });
        try self.nodeInfo(sink_bind, 0b11111, &.{
            .{ "node.name", "alsa_output.test" },
            .{ "media.class", "Audio/Sink" },
            .{ "device.id", "40" },
            .{ "card.profile.device", "3" },
            .{ "audio.channels", "2" },
        });
        try self.nodeInfo(source_bind, 0b11111, &.{
            .{ "node.name", "alsa_input.test" },
            .{ "audio.channels", "1" },
        });
        try self.nodeInfo(stream_bind, 0b11111, &.{
            .{ "node.name", "player-out" },
            .{ "media.name", "Song" },
        });
    }

    pub fn addNode(self: *Fixture, id: u32, class: []const u8, name: []const u8) !void {
        try self.global(id, node_type, &.{ .{ "media.class", class }, .{ "node.name", name } });
        const bind = try self.readBind();
        try self.nodeInfo(bind, 0b11111, &.{.{ "node.name", name }});
    }

    pub fn link(self: *Fixture, id: u32, output: []const u8, input: []const u8) !void {
        try self.global(id, link_type, &.{ .{ "link.output.node", output }, .{ "link.input.node", input } });
    }

    pub fn bindMetadata(self: *Fixture, id: u32, name: []const u8) !Bind {
        try self.global(id, metadata_type, &.{.{ "metadata.name", name }});
        const bind = try self.readBind();
        try testing.expectEqual(id, bind.global);
        return bind;
    }
};

/// Gives the card of `populate` two profiles, the second one active, three routes and the
/// current Route of device 3, the device of the sink 41.
pub fn fillCard(f: *Fixture, dev: Bind) !void {
    try f.param(dev, 8, 0, ProfileSpec{ .index = 0, .name = "off", .description = "Off" });
    try f.param(dev, 8, 1, ProfileSpec{ .index = 1, .name = "HiFi", .description = "Hi Fi", .available = 0 });
    try f.param(dev, 9, 0, ProfileSpec{ .index = 1, .name = "HiFi" });
    try f.param(dev, 12, 0, RouteSpec{ .index = 5, .name = "speaker", .profiles = &.{1}, .devices = &.{3} });
    try f.param(dev, 12, 1, RouteSpec{ .index = 6, .name = "headphones", .available = 1, .profiles = &.{ 1, 2 }, .devices = &.{3} });
    try f.param(dev, 12, 2, RouteSpec{ .index = 7, .name = "other", .profiles = &.{1}, .devices = &.{4} });
    try f.param(dev, 13, 3, RouteSpec{
        .index = 5,
        .device = 3,
        .name = "speaker",
        .profile = 1,
        .props = .{ .volumes = &.{ 0.5, 0.5 }, .mute = false },
    });
    try f.commit();
}

pub fn countOf(rec: *const Rec, change: Change) usize {
    var n: usize = 0;
    for (rec.slice()) |c| {
        if (std.meta.eql(c, change)) n += 1;
    }
    return n;
}

/// A sink on the card 40 for the device `device`.
pub fn addCardSink(f: *Fixture, id: u32, device: []const u8) !void {
    var name_buf: [16]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "sink.{d}", .{id});
    try f.global(id, node_type, &.{ .{ "media.class", "Audio/Sink" }, .{ "node.name", name } });
    const bind = try f.readBind();
    try f.nodeInfo(bind, 0b11111, &.{
        .{ "node.name", name },
        .{ "device.id", "40" },
        .{ "card.profile.device", device },
    });
}
