//! The device view of the CoreAudio backend. It finds the controls of a device, reads their values
//! into Mixer values and writes Mixer values back. All HAL calls go through `Props`.
const std = @import("std");
const builtin = @import("builtin");
const Mixer = @import("../../Mixer.zig");
const api = @import("api.zig");
const map = @import("map.zig");
const Props = @import("props.zig");

/// Where the volume of a side comes from.
pub const VolumePlan = enum {
    none,
    /// One `vold` per channel, elements 1 to N.
    elements,
    /// One `vold` on element 0 for all channels.
    main,
    /// `vmvc` on element 0, for a device that has no `vold`.
    scalar,
};

pub const MutePlan = enum { none, main, elements };

/// One direction of a device.
pub const Side = struct {
    scope: u32,
    channels: u32,
    volume: VolumePlan = .none,
    mute: MutePlan = .none,
    sources: bool = false,

    /// The channel count of the Mixer volume. It is 0 when the side has no volume.
    pub fn volumeChannels(self: Side) u8 {
        if (self.volume == .none) return 0;
        return @intCast(@min(self.channels, Mixer.max_channels));
    }
};

pub const Info = struct {
    device: api.AudioObjectID,
    uid: []const u8,
    name: []const u8,
    sink: ?Side,
    source: ?Side,
};

pub const Controls = struct {
    volume: Mixer.Volume = .{},
    mute: bool = false,
    ports: []const Mixer.Port = &.{},
    active_port: ?u32 = null,
};

/// A property that the backend listens to.
pub const Address = struct { selector: u32, scope: u32, element: u32 };

pub fn scopeOf(is_source: bool) u32 {
    return if (is_source) api.Scope.input else api.Scope.output;
}

/// The sum of the channels of all streams, from the stream configuration.
fn channelCount(props: Props, gpa: std.mem.Allocator, device: api.AudioObjectID, scope: u32) map.Failure!u32 {
    const bytes = try props.elementList(gpa, u8, device, api.Selector.stream_configuration, scope, api.element_main);
    defer gpa.free(bytes);
    return sumChannels(bytes);
}

fn sumChannels(bytes: []const u8) u32 {
    const head = @offsetOf(api.AudioBufferList, "mBuffers");
    const endian = builtin.cpu.arch.endian();
    if (bytes.len < head) return 0;
    const buffers = std.mem.readInt(u32, bytes[0..4], endian);
    var total: u32 = 0;
    var i: usize = 0;
    while (i < buffers) : (i += 1) {
        const at = head + i * @sizeOf(api.AudioBuffer);
        if (at + 4 > bytes.len) break;
        total +|= std.mem.readInt(u32, bytes[at..][0..4], endian);
    }
    return total;
}

fn volumePlan(props: Props, device: api.AudioObjectID, scope: u32, channels: u32) VolumePlan {
    const S = api.Selector;
    var every = channels > 0;
    var element: u32 = 1;
    while (element <= channels) : (element += 1) {
        if (!props.hasProperty(device, S.volume_decibels, scope, element)) {
            every = false;
            break;
        }
    }
    if (every) return .elements;
    if (props.hasProperty(device, S.volume_decibels, scope, api.element_main)) return .main;
    if (props.hasProperty(device, S.virtual_main_volume, scope, api.element_main)) return .scalar;
    return .none;
}

fn mutePlan(props: Props, device: api.AudioObjectID, scope: u32, channels: u32) MutePlan {
    const S = api.Selector;
    if (props.hasProperty(device, S.mute, scope, api.element_main)) return .main;
    if (channels == 0) return .none;
    var element: u32 = 1;
    while (element <= channels) : (element += 1) {
        if (!props.hasProperty(device, S.mute, scope, element)) return .none;
    }
    return .elements;
}

fn planSide(props: Props, device: api.AudioObjectID, scope: u32, channels: u32) Side {
    const capped = @min(channels, Mixer.max_channels);
    return .{
        .scope = scope,
        .channels = channels,
        .volume = volumePlan(props, device, scope, capped),
        .mute = mutePlan(props, device, scope, capped),
        .sources = props.hasProperty(device, api.Selector.data_sources, scope, api.element_main) and
            props.hasProperty(device, api.Selector.data_source, scope, api.element_main),
    };
}

fn sideOf(props: Props, gpa: std.mem.Allocator, device: api.AudioObjectID, scope: u32) error{OutOfMemory}!?Side {
    const channels = channelCount(props, gpa, device, scope) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (channels == 0) return null;
    return planSide(props, device, scope, channels);
}

/// Reads the identity and the sides of a device. Null means the Mixer does not show it: the device
/// is dead or hidden, has no UID or has no channels. The strings belong to `arena`.
pub fn scanDevice(props: Props, arena: std.mem.Allocator, device: api.AudioObjectID) error{OutOfMemory}!?Info {
    const S = api.Selector;
    const alive = props.objectValue(u32, device, S.is_alive, api.Scope.global) catch return null;
    if (alive == 0) return null;
    const hidden = props.objectValue(u32, device, S.is_hidden, api.Scope.global) catch 0;
    if (hidden != 0) return null;
    const uid = props.objectString(arena, device, S.device_uid, api.Scope.global) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const name = props.objectString(arena, device, S.name, api.Scope.global) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => uid,
    };
    const sink = try sideOf(props, arena, device, api.Scope.output);
    const source = try sideOf(props, arena, device, api.Scope.input);
    if (sink == null and source == null) return null;
    return .{ .device = device, .uid = uid, .name = name, .sink = sink, .source = source };
}

/// The level of one `vold` control as linear amplitude. The lowest level of the range is silence.
fn readLevel(props: Props, device: api.AudioObjectID, scope: u32, element: u32) ?f32 {
    const S = api.Selector;
    const db = props.elementValue(f32, device, S.volume_decibels, scope, element) catch return null;
    const range = props.elementValue(api.AudioValueRange, device, S.volume_range_decibels, scope, element) catch return null;
    if (!std.math.isFinite(db)) return null;
    if (db <= range.mMinimum) return 0;
    return @min(map.dbToLinear(db), Mixer.max_volume);
}

fn readVolume(props: Props, device: api.AudioObjectID, side: Side) Mixer.Volume {
    const count = side.volumeChannels();
    var out: Mixer.Volume = .{ .count = count };
    switch (side.volume) {
        .none => return .{},
        .elements => for (0..count) |i| {
            out.values[i] = readLevel(props, device, side.scope, @intCast(i + 1)) orelse return .{};
        },
        .main => {
            const value = readLevel(props, device, side.scope, api.element_main) orelse return .{};
            @memset(out.values[0..count], value);
        },
        .scalar => {
            const raw = props.elementValue(f32, device, api.Selector.virtual_main_volume, side.scope, api.element_main) catch return .{};
            if (!std.math.isFinite(raw)) return .{};
            @memset(out.values[0..count], Mixer.cubicToLinear(std.math.clamp(raw, 0, 1)));
        },
    }
    return out;
}

fn readMuteAt(props: Props, device: api.AudioObjectID, scope: u32, element: u32) bool {
    const value = props.elementValue(u32, device, api.Selector.mute, scope, element) catch return false;
    return value != 0;
}

fn readMute(props: Props, device: api.AudioObjectID, side: Side) bool {
    switch (side.mute) {
        .none => return false,
        .main => return readMuteAt(props, device, side.scope, api.element_main),
        .elements => {
            const count = @min(side.channels, Mixer.max_channels);
            var element: u32 = 1;
            while (element <= count) : (element += 1) {
                if (!readMuteAt(props, device, side.scope, element)) return false;
            }
            return true;
        },
    }
}

fn portName(arena: std.mem.Allocator, item: u32) error{OutOfMemory}![]const u8 {
    if (map.statusText(@bitCast(item))) |text| return arena.dupe(u8, &text);
    return std.fmt.allocPrint(arena, "{d}", .{item});
}

fn readPorts(props: Props, arena: std.mem.Allocator, device: api.AudioObjectID, side: Side) error{OutOfMemory}!Controls {
    const S = api.Selector;
    var out: Controls = .{};
    if (!side.sources) return out;
    const ids = props.elementList(arena, u32, device, S.data_sources, side.scope, api.element_main) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return out,
    };
    const ports = try arena.alloc(Mixer.Port, ids.len);
    for (ids, ports) |item, *port| {
        const name = try portName(arena, item);
        const description = props.sourceName(arena, device, side.scope, item) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => name,
        };
        port.* = .{ .index = item, .name = name, .description = description };
    }
    out.ports = ports;
    const current = props.elementList(arena, u32, device, S.data_source, side.scope, api.element_main) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return out,
    };
    if (current.len > 0 and std.mem.indexOfScalar(u32, ids, current[0]) != null) out.active_port = current[0];
    return out;
}

/// Reads the volume, the mute and the data sources of a side. A control that does not answer counts as absent.
pub fn readControls(props: Props, arena: std.mem.Allocator, device: api.AudioObjectID, side: Side) error{OutOfMemory}!Controls {
    var out = try readPorts(props, arena, device, side);
    out.volume = readVolume(props, device, side);
    out.mute = readMute(props, device, side);
    return out;
}

pub fn endpoint(info: Info, id: Mixer.Id, is_source: bool, controls: Controls) Mixer.Endpoint {
    return .{
        .id = id,
        .kind = if (is_source) .source else .sink,
        .name = info.uid,
        .description = info.name,
        .volume = controls.volume,
        .mute = controls.mute,
        .ports = controls.ports,
        .active_port = controls.active_port,
    };
}

fn samePorts(a: []const Mixer.Port, b: []const Mixer.Port) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.index != y.index or x.available != y.available) return false;
        if (!std.mem.eql(u8, x.name, y.name) or !std.mem.eql(u8, x.description, y.description)) return false;
    }
    return true;
}

pub fn sameEndpoint(a: Mixer.Endpoint, b: Mixer.Endpoint) bool {
    return a.id == b.id and a.kind == b.kind and a.mute == b.mute and a.active_port == b.active_port and
        a.card == b.card and
        std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.description, b.description) and
        std.mem.eql(f32, a.volume.slice(), b.volume.slice()) and samePorts(a.ports, b.ports);
}

/// Adds the properties of a side that the backend listens to. Only the ones that exist.
pub fn watched(
    props: Props,
    gpa: std.mem.Allocator,
    device: api.AudioObjectID,
    side: Side,
    out: *std.ArrayList(Address),
) error{OutOfMemory}!void {
    const S = api.Selector;
    const count: u32 = @min(side.channels, Mixer.max_channels);
    const first: u32 = if (side.volume == .elements) 1 else 0;
    const last: u32 = if (side.volume == .elements) count else 0;
    var element = first;
    while (side.volume != .none and element <= last) : (element += 1) {
        const selectors: []const u32 = switch (side.volume) {
            .scalar => &.{ S.virtual_main_volume, S.volume_scalar },
            else => &.{ S.volume_decibels, S.volume_scalar },
        };
        for (selectors) |selector| {
            if (props.hasProperty(device, selector, side.scope, element)) {
                try out.append(gpa, .{ .selector = selector, .scope = side.scope, .element = element });
            }
        }
    }
    if (side.mute != .none) {
        const from: u32 = if (side.mute == .elements) 1 else 0;
        const to: u32 = if (side.mute == .elements) count else 0;
        element = from;
        while (element <= to) : (element += 1) {
            try out.append(gpa, .{ .selector = S.mute, .scope = side.scope, .element = element });
        }
    }
    if (side.sources) try out.append(gpa, .{ .selector = S.data_source, .scope = side.scope, .element = api.element_main });
}

/// What the Mixer sees of a failed call.
pub fn mixerError(err: map.Failure) Mixer.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnknownObject, error.UnknownDevice => error.UnknownObject,
        else => error.Unsupported,
    };
}

fn mean(values: []const f32) f32 {
    var sum: f32 = 0;
    for (values) |v| sum += v;
    return sum / @as(f32, @floatFromInt(values.len));
}

fn writeLevel(props: Props, device: api.AudioObjectID, scope: u32, element: u32, linear: f32) Mixer.Error!void {
    const S = api.Selector;
    const range = props.elementValue(api.AudioValueRange, device, S.volume_range_decibels, scope, element) catch |err| {
        return mixerError(err);
    };
    const db = map.linearToDb(linear, range);
    props.setElementValue(f32, device, S.volume_decibels, scope, element, db) catch |err| return mixerError(err);
}

/// Writes the volume. The HAL answers with a change notification, so the Mixer shows the new value later.
/// A device with one control for all channels gets the mean of the values, so a balance is lost.
/// A write per channel can apply partly when the HAL refuses a later channel.
pub fn setVolume(props: Props, device: api.AudioObjectID, side: Side, values: []const f32) Mixer.Error!void {
    if (values.len != side.volumeChannels()) return error.InvalidVolume;
    switch (side.volume) {
        .none => return error.Unsupported,
        .elements => for (values, 0..) |value, i| try writeLevel(props, device, side.scope, @intCast(i + 1), value),
        .main => try writeLevel(props, device, side.scope, api.element_main, mean(values)),
        .scalar => {
            const scalar = std.math.clamp(Mixer.linearToCubic(mean(values)), 0, 1);
            props.setElementValue(f32, device, api.Selector.virtual_main_volume, side.scope, api.element_main, scalar) catch |err| {
                return mixerError(err);
            };
        },
    }
}

pub fn setMute(props: Props, device: api.AudioObjectID, side: Side, mute: bool) Mixer.Error!void {
    const value: u32 = @intFromBool(mute);
    const S = api.Selector;
    switch (side.mute) {
        .none => return error.Unsupported,
        .main => props.setElementValue(u32, device, S.mute, side.scope, api.element_main, value) catch |err| return mixerError(err),
        .elements => {
            const count = @min(side.channels, Mixer.max_channels);
            var element: u32 = 1;
            while (element <= count) : (element += 1) {
                props.setElementValue(u32, device, S.mute, side.scope, element, value) catch |err| return mixerError(err);
            }
        },
    }
}

pub fn setPort(props: Props, device: api.AudioObjectID, side: Side, item: u32) Mixer.Error!void {
    const S = api.Selector;
    if (!side.sources or !props.isSettable(device, S.data_source, side.scope, api.element_main)) return error.Unsupported;
    props.setElementValue(u32, device, S.data_source, side.scope, api.element_main, item) catch |err| return mixerError(err);
}

test "the channels of a stream configuration add up" {
    const t = std.testing;
    const endian = builtin.cpu.arch.endian();
    const head = @offsetOf(api.AudioBufferList, "mBuffers");
    const each = @sizeOf(api.AudioBuffer);
    var bytes: [head + 2 * each]u8 = @splat(0);
    try t.expectEqual(@as(u32, 0), sumChannels(bytes[0..head]));
    std.mem.writeInt(u32, bytes[0..4], 2, endian);
    std.mem.writeInt(u32, bytes[head..][0..4], 2, endian);
    std.mem.writeInt(u32, bytes[head + each ..][0..4], 4, endian);
    try t.expectEqual(@as(u32, 6), sumChannels(&bytes));
    try t.expectEqual(@as(u32, 2), sumChannels(bytes[0 .. head + each]));
    try t.expectEqual(@as(u32, 0), sumChannels(bytes[0..3]));
}
