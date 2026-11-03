//! The model of cards, endpoints and application streams of a system, with controls.
const std = @import("std");
const Format = @import("Format.zig");
const Pipeline = @import("Pipeline.zig");
const Backend = @import("backend/Backend.zig");
const Mixer = @This();

/// An id names an object of the current connection. After a reconnect the objects get new ids,
/// so read them again.
pub const Id = enum(u32) { _ };
pub const Kind = enum { sink, source };

pub const max_channels = 64;
/// Largest volume value that setVolume accepts.
pub const max_volume: f32 = 10;

pub const Volume = struct {
    count: u8 = 0,
    values: [max_channels]f32 = @splat(0),

    pub fn init(values: []const f32) Volume {
        std.debug.assert(values.len <= max_channels);
        var self: Volume = .{ .count = @intCast(values.len) };
        @memcpy(self.values[0..values.len], values);
        return self;
    }

    /// For data that comes from a backend.
    pub fn initChecked(values: []const f32) error{InvalidVolume}!Volume {
        if (values.len > max_channels) return error.InvalidVolume;
        return .init(values);
    }

    pub fn slice(self: *const Volume) []const f32 {
        return self.values[0..self.count];
    }
};

pub const Port = struct { index: u32, name: []const u8, description: []const u8, available: bool = true };
pub const Profile = struct { index: u32, name: []const u8, description: []const u8, available: bool = true };

pub const Card = struct {
    id: Id,
    name: []const u8,
    description: []const u8,
    profiles: []const Profile = &.{},
    active_profile: ?u32 = null,
};

pub const Endpoint = struct {
    id: Id,
    kind: Kind,
    name: []const u8,
    description: []const u8,
    card: ?Id = null,
    volume: Volume,
    mute: bool = false,
    ports: []const Port = &.{},
    active_port: ?u32 = null,
};

pub const AppStream = struct {
    id: Id,
    direction: Pipeline.Direction,
    app_name: []const u8,
    name: []const u8,
    endpoint: ?Id = null,
    volume: Volume,
    mute: bool = false,
};

pub const Capabilities = struct {
    set_default: bool = false,
    endpoint_volume: bool = false,
    stream_volume: bool = false,
    app_streams: bool = false,
    move_stream: bool = false,
    profiles: bool = false,
    ports: bool = false,

    pub const none: Capabilities = .{};
    pub const all: Capabilities = .{
        .set_default = true,
        .endpoint_volume = true,
        .stream_volume = true,
        .app_streams = true,
        .move_stream = true,
        .profiles = true,
        .ports = true,
    };
};

pub const Target = union(enum) { endpoint: Id, stream: Id };
pub const Levels = struct { channels: []const f32 };

pub const Change = union(enum) {
    card_added: Id,
    card_changed: Id,
    card_removed: Id,
    endpoint_added: Id,
    endpoint_changed: Id,
    endpoint_removed: Id,
    stream_added: Id,
    stream_changed: Id,
    stream_removed: Id,
    default_changed: Kind,
};

pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, mixer: *const Mixer, change: Change) void,
};

pub const Error = error{ Unsupported, UnknownObject, InvalidVolume, InvalidIndex, OutOfMemory };

/// Items with one arena each. The arena owns the strings and slices of the item.
fn Table(comptime T: type) type {
    return struct {
        const Self = @This();

        items: std.ArrayList(T) = .empty,
        arenas: std.ArrayList(std.heap.ArenaAllocator) = .empty,

        fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            for (self.arenas.items) |arena| arena.deinit();
            self.arenas.deinit(gpa);
            self.items.deinit(gpa);
        }

        fn find(self: *const Self, id: Id) ?usize {
            for (self.items.items, 0..) |item, i| {
                if (item.id == id) return i;
            }
            return null;
        }

        /// Returns true when the item is new.
        fn put(self: *Self, gpa: std.mem.Allocator, value: T) error{OutOfMemory}!bool {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            errdefer arena.deinit();
            const copy = try deepCopy(T, arena.allocator(), value);
            if (self.find(value.id)) |i| {
                self.arenas.items[i].deinit();
                self.arenas.items[i] = arena;
                self.items.items[i] = copy;
                return false;
            }
            try self.items.ensureUnusedCapacity(gpa, 1);
            try self.arenas.ensureUnusedCapacity(gpa, 1);
            self.items.appendAssumeCapacity(copy);
            self.arenas.appendAssumeCapacity(arena);
            return true;
        }

        fn remove(self: *Self, id: Id) bool {
            const i = self.find(id) orelse return false;
            self.arenas.items[i].deinit();
            _ = self.arenas.orderedRemove(i);
            _ = self.items.orderedRemove(i);
            return true;
        }
    };
}

fn deepCopy(comptime T: type, arena: std.mem.Allocator, value: T) error{OutOfMemory}!T {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) return value;
            const out = try arena.alloc(p.child, value.len);
            for (value, out) |src, *dst| dst.* = try deepCopy(p.child, arena, src);
            return out;
        },
        .optional => |o| return if (value) |v| try deepCopy(o.child, arena, v) else null,
        .@"struct" => |s| {
            var out = value;
            inline for (s.field_names, s.field_types) |name, field_type| {
                @field(out, name) = try deepCopy(field_type, arena, @field(value, name));
            }
            return out;
        },
        else => return value,
    }
}

gpa: std.mem.Allocator,
/// Context sets it after the backend starts.
backend: ?Backend = null,
card_table: Table(Card) = .{},
endpoint_table: Table(Endpoint) = .{},
stream_table: Table(AppStream) = .{},
listeners: std.ArrayList(Listener) = .empty,
defaults: [2]?Id = .{ null, null },

pub fn init(gpa: std.mem.Allocator) Mixer {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Mixer) void {
    self.card_table.deinit(self.gpa);
    self.endpoint_table.deinit(self.gpa);
    self.stream_table.deinit(self.gpa);
    self.listeners.deinit(self.gpa);
}

pub fn cards(self: *const Mixer) []const Card {
    return self.card_table.items.items;
}

pub fn endpoints(self: *const Mixer) []const Endpoint {
    return self.endpoint_table.items.items;
}

pub fn streams(self: *const Mixer) []const AppStream {
    return self.stream_table.items.items;
}

pub fn card(self: *const Mixer, id: Id) ?*const Card {
    const i = self.card_table.find(id) orelse return null;
    return &self.card_table.items.items[i];
}

pub fn endpoint(self: *const Mixer, id: Id) ?*const Endpoint {
    const i = self.endpoint_table.find(id) orelse return null;
    return &self.endpoint_table.items.items[i];
}

pub fn stream(self: *const Mixer, id: Id) ?*const AppStream {
    const i = self.stream_table.find(id) orelse return null;
    return &self.stream_table.items.items[i];
}

pub fn default(self: *const Mixer, kind: Kind) ?Id {
    return self.defaults[@backingInt(kind)];
}

pub fn capabilities(self: *const Mixer) Capabilities {
    const backend = self.backend orelse return .none;
    return backend.capabilities();
}

pub fn listen(self: *Mixer, listener: Listener) error{OutOfMemory}!void {
    try self.listeners.append(self.gpa, listener);
}

/// Removes the first listener with the same ctx and func.
pub fn unlisten(self: *Mixer, listener: Listener) void {
    for (self.listeners.items, 0..) |item, i| {
        if (item.ctx == listener.ctx and item.func == listener.func) {
            _ = self.listeners.orderedRemove(i);
            return;
        }
    }
}

/// Removes every listener. `Context.deinit` calls it before the backend empties the Mixer, so
/// no listener sees the removals of the teardown.
pub fn unlistenAll(self: *Mixer) void {
    self.listeners.clearRetainingCapacity();
}

fn notify(self: *Mixer, change: Change) void {
    var i: usize = 0;
    while (i < self.listeners.items.len) {
        const listener = self.listeners.items[i];
        listener.func(listener.ctx, self, change);
        // A listener may remove itself. Then the next one moved to index i.
        const removed = i >= self.listeners.items.len or
            self.listeners.items[i].ctx != listener.ctx or self.listeners.items[i].func != listener.func;
        if (!removed) i += 1;
    }
}

pub fn setDefault(self: *Mixer, kind: Kind, id: Id) Error!void {
    const backend = try self.supported(.set_default);
    const ep = self.endpoint(id) orelse return error.UnknownObject;
    if (ep.kind != kind) return error.UnknownObject;
    try backend.setDefault(kind, id);
}

/// Gives `Unsupported` when the target has no volume, as with an endpoint of zero channels.
pub fn setVolume(self: *Mixer, target: Target, levels: Levels) Error!void {
    const backend = try self.supported(capabilityOf(target));
    const channels = try self.channelCount(target);
    const values = levels.channels;
    // An endpoint or a stream with no known channels has no volume to set.
    if (channels == 0) return error.Unsupported;
    if (values.len != 1 and values.len != channels) return error.InvalidVolume;
    for (values) |v| {
        if (!std.math.isFinite(v) or v < 0 or v > max_volume) return error.InvalidVolume;
    }
    if (values.len == 1) {
        var expanded: [max_channels]f32 = undefined;
        @memset(expanded[0..channels], values[0]);
        try backend.setVolume(target, expanded[0..channels]);
    } else {
        try backend.setVolume(target, values);
    }
}

pub fn setMute(self: *Mixer, target: Target, mute: bool) Error!void {
    const backend = try self.supported(capabilityOf(target));
    _ = try self.channelCount(target);
    try backend.setMute(target, mute);
}

pub fn moveStream(self: *Mixer, stream_id: Id, endpoint_id: Id) Error!void {
    const backend = try self.supported(.move_stream);
    const s = self.stream(stream_id) orelse return error.UnknownObject;
    const ep = self.endpoint(endpoint_id) orelse return error.UnknownObject;
    const wanted: Kind = switch (s.direction) {
        .playback => .sink,
        .capture => .source,
    };
    if (ep.kind != wanted) return error.UnknownObject;
    try backend.moveStream(stream_id, endpoint_id);
}

pub fn setProfile(self: *Mixer, card_id: Id, index: u32) Error!void {
    const backend = try self.supported(.profiles);
    const c = self.card(card_id) orelse return error.UnknownObject;
    for (c.profiles) |p| {
        if (p.index == index) return backend.setProfile(card_id, index);
    }
    return error.InvalidIndex;
}

pub fn setPort(self: *Mixer, endpoint_id: Id, index: u32) Error!void {
    const backend = try self.supported(.ports);
    const ep = self.endpoint(endpoint_id) orelse return error.UnknownObject;
    for (ep.ports) |p| {
        if (p.index == index) return backend.setPort(endpoint_id, index);
    }
    return error.InvalidIndex;
}

const Capability = std.meta.FieldEnum(Capabilities);

fn capabilityOf(target: Target) Capability {
    return switch (target) {
        .endpoint => .endpoint_volume,
        .stream => .stream_volume,
    };
}

fn supported(self: *const Mixer, needed: Capability) Error!Backend {
    const backend = self.backend orelse return error.Unsupported;
    const caps = backend.capabilities();
    const ok = switch (needed) {
        inline else => |tag| @field(caps, @tagName(tag)),
    };
    if (!ok) return error.Unsupported;
    return backend;
}

fn channelCount(self: *const Mixer, target: Target) Error!usize {
    return switch (target) {
        .endpoint => |id| (self.endpoint(id) orelse return error.UnknownObject).volume.count,
        .stream => |id| (self.stream(id) orelse return error.UnknownObject).volume.count,
    };
}

pub fn putCard(self: *Mixer, value: Card) error{OutOfMemory}!void {
    const added = try self.card_table.put(self.gpa, value);
    self.notify(if (added) .{ .card_added = value.id } else .{ .card_changed = value.id });
}

pub fn putEndpoint(self: *Mixer, value: Endpoint) error{OutOfMemory}!void {
    const added = try self.endpoint_table.put(self.gpa, value);
    self.notify(if (added) .{ .endpoint_added = value.id } else .{ .endpoint_changed = value.id });
}

pub fn putStream(self: *Mixer, value: AppStream) error{OutOfMemory}!void {
    const added = try self.stream_table.put(self.gpa, value);
    self.notify(if (added) .{ .stream_added = value.id } else .{ .stream_changed = value.id });
}

pub fn removeCard(self: *Mixer, id: Id) void {
    if (self.card_table.remove(id)) self.notify(.{ .card_removed = id });
}

pub fn removeEndpoint(self: *Mixer, id: Id) void {
    if (!self.endpoint_table.remove(id)) return;
    self.notify(.{ .endpoint_removed = id });
    for ([_]Kind{ .sink, .source }) |kind| {
        if (self.default(kind) == id) self.putDefault(kind, null);
    }
}

pub fn removeStream(self: *Mixer, id: Id) void {
    if (self.stream_table.remove(id)) self.notify(.{ .stream_removed = id });
}

pub fn putDefault(self: *Mixer, kind: Kind, id: ?Id) void {
    const slot = &self.defaults[@backingInt(kind)];
    if (slot.* == id) return;
    slot.* = id;
    self.notify(.{ .default_changed = kind });
}

pub fn cubicToLinear(x: f32) f32 {
    return x * x * x;
}

pub fn linearToCubic(v: f32) f32 {
    return std.math.cbrt(v);
}

const Events = struct {
    list: [16]Change = undefined,
    len: usize = 0,

    fn listener(self: *Events) Listener {
        return .{ .ctx = self, .func = record };
    }

    fn record(ctx: ?*anyopaque, mixer: *const Mixer, change: Change) void {
        _ = mixer;
        const self: *Events = @ptrCast(@alignCast(ctx.?));
        self.list[self.len] = change;
        self.len += 1;
    }
};

fn sink(id: u32, name: []const u8) Endpoint {
    return .{ .id = @fromBackingInt(@intCast(id)), .kind = .sink, .name = name, .description = name, .volume = .init(&.{ 1, 1 }) };
}

test "putEndpoint keeps its own copy of the strings" {
    var mixer: Mixer = .init(std.testing.allocator);
    defer mixer.deinit();
    var name = "speakers".*;
    try mixer.putEndpoint(sink(1, &name));
    name[0] = 'X';
    try std.testing.expectEqualStrings("speakers", mixer.endpoint(@fromBackingInt(@intCast(1))).?.name);
}

test "putEndpoint with a known id replaces it and reports a change" {
    var mixer: Mixer = .init(std.testing.allocator);
    defer mixer.deinit();
    var events: Events = .{};
    try mixer.listen(events.listener());
    try mixer.putEndpoint(sink(1, "a"));
    try mixer.putEndpoint(mixer.endpoint(@fromBackingInt(@intCast(1))).?.*);
    try std.testing.expectEqual(@as(usize, 1), mixer.endpoints().len);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(Change{ .endpoint_added = @fromBackingInt(@intCast(1)) }, events.list[0]);
    try std.testing.expectEqual(Change{ .endpoint_changed = @fromBackingInt(@intCast(1)) }, events.list[1]);
    try std.testing.expectEqualStrings("a", mixer.endpoint(@fromBackingInt(@intCast(1))).?.name);
}

test "removing the default sink clears the default" {
    var mixer: Mixer = .init(std.testing.allocator);
    defer mixer.deinit();
    try mixer.putEndpoint(sink(1, "a"));
    mixer.putDefault(.sink, @fromBackingInt(@intCast(1)));
    var events: Events = .{};
    try mixer.listen(events.listener());
    mixer.removeEndpoint(@fromBackingInt(@intCast(1)));
    try std.testing.expectEqual(@as(?Id, null), mixer.default(.sink));
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(Change{ .endpoint_removed = @fromBackingInt(@intCast(1)) }, events.list[0]);
    try std.testing.expectEqual(Change{ .default_changed = .sink }, events.list[1]);
}

test "putDefault reports only a real change" {
    var mixer: Mixer = .init(std.testing.allocator);
    defer mixer.deinit();
    var events: Events = .{};
    try mixer.listen(events.listener());
    mixer.putDefault(.source, @fromBackingInt(@intCast(4)));
    mixer.putDefault(.source, @fromBackingInt(@intCast(4)));
    try std.testing.expectEqual(@as(usize, 1), events.len);
}

test "unlisten stops events" {
    var mixer: Mixer = .init(std.testing.allocator);
    defer mixer.deinit();
    var events: Events = .{};
    try mixer.listen(events.listener());
    mixer.unlisten(events.listener());
    try mixer.putEndpoint(sink(1, "a"));
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "controls with no backend are unsupported" {
    var mixer: Mixer = .init(std.testing.allocator);
    defer mixer.deinit();
    try mixer.putEndpoint(sink(1, "a"));
    try std.testing.expectError(error.Unsupported, mixer.setMute(.{ .endpoint = @fromBackingInt(@intCast(1)) }, true));
}

test "cubic volume helpers are inverses" {
    try std.testing.expectEqual(@as(f32, 0.125), cubicToLinear(0.5));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), linearToCubic(cubicToLinear(0.5)), 1e-6);
}

test "card profiles are deep copied" {
    var mixer: Mixer = .init(std.testing.allocator);
    defer mixer.deinit();
    var profiles = [_]Profile{.{ .index = 0, .name = "a2dp", .description = "High fidelity" }};
    try mixer.putCard(.{ .id = @fromBackingInt(@intCast(9)), .name = "bt", .description = "Headset", .profiles = &profiles, .active_profile = 0 });
    profiles[0].index = 7;
    try std.testing.expectEqual(@as(u32, 0), mixer.card(@fromBackingInt(@intCast(9))).?.profiles[0].index);
}

test "a listener can remove itself and the next listener still runs" {
    var mixer: Mixer = .init(std.testing.allocator);
    defer mixer.deinit();
    const Once = struct {
        calls: usize = 0,

        fn listener(self: *@This()) Listener {
            return .{ .ctx = self, .func = run };
        }

        fn run(ctx: ?*anyopaque, m: *const Mixer, change: Change) void {
            _ = change;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            const mutable: *Mixer = @constCast(m);
            mutable.unlisten(self.listener());
        }
    };
    var first: Once = .{};
    var events: Events = .{};
    try mixer.listen(first.listener());
    try mixer.listen(events.listener());
    try mixer.putEndpoint(sink(1, "a"));
    try mixer.putEndpoint(sink(2, "b"));
    try std.testing.expectEqual(@as(usize, 1), first.calls);
    try std.testing.expectEqual(@as(usize, 2), events.len);
}

test "unlistenAll stops every listener" {
    var mixer: Mixer = .init(std.testing.allocator);
    defer mixer.deinit();
    var a: Events = .{};
    var b: Events = .{};
    try mixer.listen(a.listener());
    try mixer.listen(b.listener());
    mixer.unlistenAll();
    try mixer.putEndpoint(sink(1, "a"));
    try std.testing.expectEqual(@as(usize, 0), a.len);
    try std.testing.expectEqual(@as(usize, 0), b.len);
}
