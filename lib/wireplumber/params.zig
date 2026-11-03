//! Decoding and building of the Route, Profile and Props params of a card or a node.
//! The decoders check every length of the server data.
const std = @import("std");
const pipewire = @import("pipewire");

const pod = pipewire.pod;
const spa = pipewire.spa;

pub const max_channels = 64;
/// The most items that an array of a param may hold.
pub const max_items = 1024;

pub const VolumeError = pod.Error || error{TooMany};
pub const DecodeError = VolumeError || error{ OutOfMemory, MissingField };
pub const BuildError = pod.Builder.Error || error{TooMany};

pub const Availability = enum(u32) {
    unknown = 0,
    no = 1,
    yes = 2,
    _,
};

pub const Direction = enum { input, output, unknown };

/// The volume part of a Props object. A field that the object lacks keeps its default.
pub const Volume = struct {
    channel_volumes: [max_channels]f32 = @splat(0),
    count: u8 = 0,
    mute: bool = false,
    volume: f32 = 1.0,
    has_channel_volumes: bool = false,
    has_mute: bool = false,

    pub fn channels(self: *const Volume) []const f32 {
        return self.channel_volumes[0..self.count];
    }

    /// True when the object has both `mute` and `channelVolumes`. Only then a mixer can use it.
    pub fn complete(self: *const Volume) bool {
        return self.has_channel_volumes and self.has_mute;
    }

    /// Reads a Props object.
    pub fn decode(p: pod.Pod) VolumeError!Volume {
        const obj = try p.object();
        if (obj.object_type != @backingInt(spa.ObjectType.props)) return error.WrongType;
        var out: Volume = .{};
        var props = obj.props();
        while (try props.next()) |prop| {
            const key: spa.PropKey = @fromBackingInt(prop.key);
            switch (key) {
                .volume => out.volume = try (try prop.value.unwrap()).float(),
                .mute => {
                    out.mute = try (try prop.value.unwrap()).boolean();
                    out.has_mute = true;
                },
                .channel_volumes => {
                    out.count = try floats(prop.value, &out.channel_volumes);
                    out.has_channel_volumes = true;
                },
                else => {},
            }
        }
        return out;
    }
};

fn floats(p: pod.Pod, out: *[max_channels]f32) VolumeError!u8 {
    const arr = try p.array();
    if (arr.count() > max_channels) return error.TooMany;
    if (arr.count() > 0 and arr.child_type != .float) return error.WrongType;
    var it = arr.items();
    var n: u8 = 0;
    while (it.next()) |item| : (n += 1) out[n] = try item.float();
    return n;
}

fn ints(arena: std.mem.Allocator, p: pod.Pod) DecodeError![]const u32 {
    const arr = try p.array();
    if (arr.count() > max_items) return error.TooMany;
    if (arr.count() > 0 and arr.child_type != .int) return error.WrongType;
    const out = try arena.alloc(u32, arr.count());
    var it = arr.items();
    for (out) |*slot| slot.* = try nonNegative(try it.next().?.int());
    return out;
}

fn nonNegative(v: i32) pod.Error!u32 {
    if (v < 0) return error.BadPod;
    return @intCast(v);
}

fn text(arena: std.mem.Allocator, p: pod.Pod) DecodeError![]const u8 {
    const s = (try p.string()) orelse return "";
    return arena.dupe(u8, s);
}

fn availability(p: pod.Pod) pod.Error!Availability {
    return @fromBackingInt(try p.id());
}

fn direction(p: pod.Pod) pod.Error!Direction {
    return switch (try p.id()) {
        @backingInt(spa.Direction.input) => .input,
        @backingInt(spa.Direction.output) => .output,
        else => .unknown,
    };
}

/// A Route param: an entry of EnumRoute or a current Route.
pub const Route = struct {
    index: u32,
    direction: Direction = .unknown,
    /// Only a current Route has a device.
    device: ?u32 = null,
    name: []const u8 = "",
    description: []const u8 = "",
    priority: i32 = 0,
    available: Availability = .unknown,
    /// Profile indexes of the port. Null means the key is missing and every profile fits.
    profiles: ?[]const u32 = null,
    devices: []const u32 = &.{},
    volume: ?Volume = null,

    /// Strings and lists are copied into `arena`.
    pub fn decode(arena: std.mem.Allocator, p: pod.Pod) DecodeError!Route {
        const obj = try p.object();
        if (obj.object_type != @backingInt(spa.ObjectType.param_route)) return error.WrongType;
        var out: Route = .{ .index = 0 };
        var have_index = false;
        var props = obj.props();
        while (try props.next()) |prop| {
            const key: spa.ParamRouteKey = @fromBackingInt(prop.key);
            const v = prop.value;
            switch (key) {
                .index => {
                    out.index = try nonNegative(try v.int());
                    have_index = true;
                },
                .direction => out.direction = try direction(v),
                .device => out.device = try nonNegative(try v.int()),
                .name => out.name = try text(arena, v),
                .description => out.description = try text(arena, v),
                .priority => out.priority = try v.int(),
                .available => out.available = try availability(v),
                .profiles => out.profiles = try ints(arena, v),
                .devices => out.devices = try ints(arena, v),
                .props => out.volume = try Volume.decode(v),
                else => {},
            }
        }
        if (!have_index) return error.MissingField;
        return out;
    }

    pub fn clone(self: Route, arena: std.mem.Allocator) error{OutOfMemory}!Route {
        var out = self;
        out.name = try arena.dupe(u8, self.name);
        out.description = try arena.dupe(u8, self.description);
        if (self.profiles) |ps| out.profiles = try arena.dupe(u32, ps);
        out.devices = try arena.dupe(u32, self.devices);
        return out;
    }
};

/// A Profile param: an entry of EnumProfile or the current Profile.
pub const Profile = struct {
    index: u32,
    name: []const u8 = "",
    description: []const u8 = "",
    priority: i32 = 0,
    available: Availability = .unknown,

    pub fn decode(arena: std.mem.Allocator, p: pod.Pod) DecodeError!Profile {
        const obj = try p.object();
        if (obj.object_type != @backingInt(spa.ObjectType.param_profile)) return error.WrongType;
        var out: Profile = .{ .index = 0 };
        var have_index = false;
        var props = obj.props();
        while (try props.next()) |prop| {
            const key: spa.ParamProfileKey = @fromBackingInt(prop.key);
            const v = prop.value;
            switch (key) {
                .index => {
                    out.index = try nonNegative(try v.int());
                    have_index = true;
                },
                .name => out.name = try text(arena, v),
                .description => out.description = try text(arena, v),
                .priority => out.priority = try v.int(),
                .available => out.available = try availability(v),
                else => {},
            }
        }
        if (!have_index) return error.MissingField;
        return out;
    }

    pub fn clone(self: Profile, arena: std.mem.Allocator) error{OutOfMemory}!Profile {
        var out = self;
        out.name = try arena.dupe(u8, self.name);
        out.description = try arena.dupe(u8, self.description);
        return out;
    }
};

/// The items of one param id of one object. An arena owns the items.
pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();

        arena: std.heap.ArenaAllocator,
        items: std.ArrayList(T) = .empty,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .arena = .init(gpa) };
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        /// Copies `value` into the list. `value` stays with the caller.
        pub fn append(self: *Self, value: T) error{OutOfMemory}!void {
            const a = self.arena.allocator();
            try self.items.append(a, try value.clone(a));
        }

        pub fn clear(self: *Self) void {
            _ = self.arena.reset(.retain_capacity);
            self.items = .empty;
        }
    };
}

/// Changes of a Props object to send. A field that is null stays out of the object.
pub const Change = struct {
    channel_volumes: ?[]const f32 = null,
    mute: ?bool = null,
};

fn writeProps(b: *pod.Builder, change: Change) BuildError!void {
    const o = try b.beginObject(@backingInt(spa.ObjectType.props), @backingInt(spa.ParamType.props));
    if (change.channel_volumes) |vols| {
        if (vols.len > max_channels) return error.TooMany;
        try b.prop(@backingInt(spa.PropKey.channel_volumes), .{});
        const a = try b.beginArray();
        for (vols) |v| try b.float(v);
        b.end(a);
    }
    if (change.mute) |m| {
        try b.prop(@backingInt(spa.PropKey.mute), .{});
        try b.boolean(m);
    }
    b.end(o);
}

/// Writes a Props object for `Node.setParam`.
pub fn buildProps(b: *pod.Builder, change: Change) BuildError!void {
    try writeProps(b, change);
}

/// Writes a Route object for `Device.setParam`. `props` is the volume to set together with
/// the port.
pub fn buildRoute(b: *pod.Builder, at: u32, device: u32, props: ?Change, save: bool) BuildError!void {
    const o = try b.beginObject(@backingInt(spa.ObjectType.param_route), @backingInt(spa.ParamType.route));
    try b.prop(@backingInt(spa.ParamRouteKey.index), .{});
    try b.int(@bitCast(at));
    try b.prop(@backingInt(spa.ParamRouteKey.device), .{});
    try b.int(@bitCast(device));
    if (props) |change| {
        try b.prop(@backingInt(spa.ParamRouteKey.props), .{});
        try writeProps(b, change);
    }
    try b.prop(@backingInt(spa.ParamRouteKey.save), .{});
    try b.boolean(save);
    b.end(o);
}

/// Writes a Profile object for `Device.setParam`.
pub fn buildProfile(b: *pod.Builder, at: u32, save: bool) BuildError!void {
    const o = try b.beginObject(@backingInt(spa.ObjectType.param_profile), @backingInt(spa.ParamType.profile));
    try b.prop(@backingInt(spa.ParamProfileKey.index), .{});
    try b.int(@bitCast(at));
    try b.prop(@backingInt(spa.ParamProfileKey.save), .{});
    try b.boolean(save);
    b.end(o);
}

const testing = std.testing;

fn parse(bytes: []const u8) !pod.Pod {
    return (try pod.Pod.parse(bytes)).pod;
}

test "buildRoute and Route.decode round trip" {
    var buf: [256]u8 = undefined;
    var b = pod.Builder.init(&buf);
    try buildRoute(&b, 7, 3, .{ .channel_volumes = &.{ 0.25, 0.5 }, .mute = true }, true);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try Route.decode(arena.allocator(), try parse(b.bytesWritten()));
    try testing.expectEqual(@as(u32, 7), r.index);
    try testing.expectEqual(@as(?u32, 3), r.device);
    const v = r.volume.?;
    try testing.expect(v.complete());
    try testing.expectEqualSlices(f32, &.{ 0.25, 0.5 }, v.channels());
    try testing.expect(v.mute);
}

test "buildRoute without props and buildProfile round trip" {
    var buf: [256]u8 = undefined;
    var b = pod.Builder.init(&buf);
    try buildRoute(&b, 1, 0, null, false);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try Route.decode(arena.allocator(), try parse(b.bytesWritten()));
    try testing.expectEqual(@as(?Volume, null), r.volume);

    b = pod.Builder.init(&buf);
    try buildProfile(&b, 4, true);
    const p = try Profile.decode(arena.allocator(), try parse(b.bytesWritten()));
    try testing.expectEqual(@as(u32, 4), p.index);
}

test "buildProps writes only the fields that are set" {
    var buf: [256]u8 = undefined;
    var b = pod.Builder.init(&buf);
    try buildProps(&b, .{ .mute = false });
    const v = try Volume.decode(try parse(b.bytesWritten()));
    try testing.expect(v.has_mute);
    try testing.expect(!v.has_channel_volumes);
    try testing.expect(!v.complete());

    b = pod.Builder.init(&buf);
    try buildProps(&b, .{ .channel_volumes = &.{0.75} });
    const w = try Volume.decode(try parse(b.bytesWritten()));
    try testing.expect(w.has_channel_volumes);
    try testing.expect(!w.has_mute);
    try testing.expectEqualSlices(f32, &.{0.75}, w.channels());
}

test "buildProps refuses more channels than the limit" {
    var buf: [1024]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const many: [max_channels + 1]f32 = @splat(0.5);
    try testing.expectError(error.TooMany, buildProps(&b, .{ .channel_volumes = &many }));
}

test "Volume.decode refuses more channels than the limit" {
    var buf: [1024]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const o = try b.beginObject(@backingInt(spa.ObjectType.props), @backingInt(spa.ParamType.props));
    try b.prop(@backingInt(spa.PropKey.channel_volumes), .{});
    const a = try b.beginArray();
    for (0..max_channels + 1) |_| try b.float(1.0);
    b.end(a);
    b.end(o);
    try testing.expectError(error.TooMany, Volume.decode(try parse(b.bytesWritten())));
}

test "Volume.decode reads a volume choice and skips soft volumes" {
    var buf: [512]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const o = try b.beginObject(@backingInt(spa.ObjectType.props), @backingInt(spa.ParamType.props));
    try b.prop(@backingInt(spa.PropKey.volume), .{});
    const c = try b.beginChoice(.none, 0);
    try b.float(0.5);
    b.end(c);
    try b.prop(@backingInt(spa.PropKey.soft_volumes), .{});
    const a = try b.beginArray();
    try b.float(1.0);
    try b.float(0.75);
    b.end(a);
    b.end(o);
    const v = try Volume.decode(try parse(b.bytesWritten()));
    try testing.expectEqual(@as(f32, 0.5), v.volume);
    try testing.expect(!v.complete());
}

test "a channelVolumes array of ints is the wrong type" {
    var buf: [256]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const o = try b.beginObject(@backingInt(spa.ObjectType.props), @backingInt(spa.ParamType.props));
    try b.prop(@backingInt(spa.PropKey.channel_volumes), .{});
    const a = try b.beginArray();
    try b.int(1);
    b.end(a);
    b.end(o);
    try testing.expectError(error.WrongType, Volume.decode(try parse(b.bytesWritten())));
}

test "Route.decode errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;

    var b = pod.Builder.init(&buf);
    const o = try b.beginObject(@backingInt(spa.ObjectType.param_route), @backingInt(spa.ParamType.route));
    try b.prop(@backingInt(spa.ParamRouteKey.name), .{});
    try b.string("x");
    b.end(o);
    try testing.expectError(error.MissingField, Route.decode(arena.allocator(), try parse(b.bytesWritten())));

    b = pod.Builder.init(&buf);
    const p = try b.beginObject(@backingInt(spa.ObjectType.param_route), @backingInt(spa.ParamType.route));
    try b.prop(@backingInt(spa.ParamRouteKey.index), .{});
    try b.int(-1);
    b.end(p);
    try testing.expectError(error.BadPod, Route.decode(arena.allocator(), try parse(b.bytesWritten())));

    b = pod.Builder.init(&buf);
    try b.int(4);
    try testing.expectError(error.WrongType, Route.decode(arena.allocator(), try parse(b.bytesWritten())));

    b = pod.Builder.init(&buf);
    try buildProfile(&b, 1, false);
    try testing.expectError(error.WrongType, Route.decode(arena.allocator(), try parse(b.bytesWritten())));
}

test "a List appends and clears" {
    var list: List(Profile) = .init(testing.allocator);
    defer list.deinit();
    try list.append(.{ .index = 10, .name = "a" });
    try list.append(.{ .index = 11, .name = "b" });
    try testing.expectEqual(@as(usize, 2), list.items.items.len);
    try testing.expectEqualStrings("b", list.items.items[1].name);
    list.clear();
    try testing.expectEqual(@as(usize, 0), list.items.items.len);
    try list.append(.{ .index = 12, .name = "c" });
    try testing.expectEqualStrings("c", list.items.items[0].name);
}

test "a missing profiles key is null and an empty array is empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var b = pod.Builder.init(&buf);
    var o = try b.beginObject(@backingInt(spa.ObjectType.param_route), @backingInt(spa.ParamType.route));
    try b.prop(@backingInt(spa.ParamRouteKey.index), .{});
    try b.int(1);
    b.end(o);
    const none = try Route.decode(arena.allocator(), try parse(b.bytesWritten()));
    try testing.expectEqual(@as(?[]const u32, null), none.profiles);

    b = pod.Builder.init(&buf);
    o = try b.beginObject(@backingInt(spa.ObjectType.param_route), @backingInt(spa.ParamType.route));
    try b.prop(@backingInt(spa.ParamRouteKey.index), .{});
    try b.int(1);
    try b.prop(@backingInt(spa.ParamRouteKey.profiles), .{});
    const a = try b.beginArray();
    b.end(a);
    b.end(o);
    const empty = try Route.decode(arena.allocator(), try parse(b.bytesWritten()));
    try testing.expectEqual(@as(usize, 0), empty.profiles.?.len);
}
