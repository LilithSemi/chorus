//! A backend with no audio system. It renders into memory when the application calls dispatch.
const std = @import("std");
const Format = @import("../Format.zig");
const Mixer = @import("../Mixer.zig");
const Stream = @import("../Stream.zig");
const Backend = @import("Backend.zig");
const Null = @This();

pub const kind: Backend.Kind = .null;

pub const Options = struct {
    /// Native format for every stream. Null means the stream's own format.
    native: ?Format = null,
    period_frames: u32 = 256,
    /// Frames that each dispatch renders (or takes) per stream. Null means `period_frames`.
    render_frames: ?u32 = null,
    capabilities: Mixer.Capabilities = .all,
    /// What `timeoutMs` reports. Null means the period of the running playback streams, or null when none runs.
    timeout_ms: ?u32 = null,
    /// False renders each period and drops it, so `output` stays empty.
    keep_output: bool = true,
};

const Entry = struct {
    stream: *Stream,
    output: std.ArrayList(u8) = .empty,
    input: std.ArrayList(u8) = .empty,

    fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        self.output.deinit(gpa);
        self.input.deinit(gpa);
    }
};

gpa: std.mem.Allocator,
mixer: *Mixer,
options: Options,
entries: std.ArrayList(Entry) = .empty,
last_id: u32 = 0,
connected: bool = true,
disconnect_pending: bool = false,

const vtable: Backend.VTable = .{
    .deinit = deinitImpl,
    .dispatch = dispatchImpl,
    .reconnect = reconnectImpl,
    .realtime = realtimeImpl,
    .fd = fdImpl,
    .timeoutMs = timeoutMsImpl,
    .capabilities = capabilitiesImpl,
    .openStream = openStreamImpl,
    .closeStream = closeStreamImpl,
    .startStream = startStreamImpl,
    .stopStream = stopStreamImpl,
    .setDefault = setDefaultImpl,
    .setVolume = setVolumeImpl,
    .setMute = setMuteImpl,
    .moveStream = moveStreamImpl,
    .setProfile = setProfileImpl,
    .setPort = setPortImpl,
};

pub fn create(ictx: Backend.InitContext, options: Options) Backend.ConnectError!Backend {
    const self = try ictx.gpa.create(Null);
    self.* = .{ .gpa = ictx.gpa, .mixer = ictx.mixer, .options = options };
    return .{ .ptr = self, .vtable = &vtable, .kind = kind };
}

/// Gives ids 1, 2, 3 and so on.
pub fn newId(self: *Null) Mixer.Id {
    self.last_id += 1;
    return @fromBackingInt(self.last_id);
}

/// All native bytes rendered for the stream so far.
pub fn output(self: *Null, stream: *Stream) []const u8 {
    const entry = self.find(stream) orelse return &.{};
    return entry.output.items;
}

pub fn clearOutput(self: *Null, stream: *Stream) void {
    const entry = self.find(stream) orelse return;
    entry.output.clearRetainingCapacity();
}

pub fn feedInput(self: *Null, stream: *Stream, bytes: []const u8) error{OutOfMemory}!void {
    const entry = self.find(stream) orelse return;
    try entry.input.appendSlice(self.gpa, bytes);
}

/// Changes the native format that later openStream calls give.
pub fn setNative(self: *Null, native: ?Format) void {
    self.options.native = native;
}

/// The next dispatch returns `.disconnected`.
pub fn disconnect(self: *Null) void {
    self.disconnect_pending = true;
}

fn find(self: *Null, stream: *Stream) ?*Entry {
    for (self.entries.items) |*entry| {
        if (entry.stream == stream) return entry;
    }
    return null;
}

fn from(ptr: *anyopaque) *Null {
    return @ptrCast(@alignCast(ptr));
}

fn deinitImpl(ptr: *anyopaque) void {
    const self = from(ptr);
    for (self.entries.items) |*entry| entry.deinit(self.gpa);
    self.entries.deinit(self.gpa);
    self.gpa.destroy(self);
}

fn dispatchImpl(ptr: *anyopaque) Backend.DispatchError!Backend.Event {
    const self = from(ptr);
    if (self.disconnect_pending) {
        self.disconnect_pending = false;
        self.connected = false;
        for (self.entries.items) |*entry| entry.deinit(self.gpa);
        self.entries.clearRetainingCapacity();
        return .disconnected;
    }
    if (!self.connected) return .none;
    for (self.entries.items) |*entry| {
        const stream = entry.stream;
        const native = stream.negotiated.native;
        const period = (self.options.render_frames orelse stream.negotiated.period_frames) * native.frameBytes();
        const was_draining = stream.state() == .draining;
        switch (stream.state()) {
            .running, .draining => {},
            else => continue,
        }
        switch (stream.options.direction) {
            .playback => {
                if (!self.options.keep_output) entry.output.clearRetainingCapacity();
                const old_len = entry.output.items.len;
                try entry.output.resize(self.gpa, old_len + period);
                stream.render(entry.output.items[old_len..]);
            },
            .capture => if (entry.input.items.len >= period) {
                stream.capture(entry.input.items[0..period]);
                entry.input.replaceRangeAssumeCapacity(0, period, &.{});
            },
        }
        if (was_draining) stream.drained();
    }
    return .none;
}

fn reconnectImpl(ptr: *anyopaque) Backend.ConnectError!void {
    from(ptr).connected = true;
}

fn realtimeImpl(ptr: *anyopaque) Backend.Realtime {
    _ = ptr;
    return .no;
}

fn timeoutMsImpl(ptr: *anyopaque) ?u32 {
    const self = from(ptr);
    if (self.options.timeout_ms) |ms| return ms;
    var best: ?u32 = null;
    for (self.entries.items) |*entry| {
        const stream = entry.stream;
        if (stream.options.direction != .playback) continue;
        switch (stream.state()) {
            .running, .draining => {},
            else => continue,
        }
        const frames = self.options.render_frames orelse stream.negotiated.period_frames;
        const ms: u32 = @intCast(@max(1, @as(u64, frames) * 1000 / stream.negotiated.native.rate));
        best = if (best) |b| @min(b, ms) else ms;
    }
    return best;
}

fn fdImpl(ptr: *anyopaque) ?i32 {
    _ = ptr;
    return null;
}

fn capabilitiesImpl(ptr: *anyopaque) Mixer.Capabilities {
    return from(ptr).options.capabilities;
}

fn openStreamImpl(ptr: *anyopaque, stream: *Stream) Stream.OpenError!Backend.Negotiated {
    const self = from(ptr);
    if (!self.connected) return error.Disconnected;
    if (self.find(stream) == null) try self.entries.append(self.gpa, .{ .stream = stream });
    return .{
        .native = self.options.native orelse stream.options.format,
        .period_frames = self.options.period_frames,
    };
}

fn closeStreamImpl(ptr: *anyopaque, stream: *Stream) void {
    const self = from(ptr);
    for (self.entries.items, 0..) |*entry, i| {
        if (entry.stream == stream) {
            entry.deinit(self.gpa);
            _ = self.entries.orderedRemove(i);
            return;
        }
    }
}

fn startStreamImpl(ptr: *anyopaque, stream: *Stream) Stream.StartError!void {
    _ = ptr;
    _ = stream;
}

fn stopStreamImpl(ptr: *anyopaque, stream: *Stream) void {
    _ = ptr;
    _ = stream;
}

fn setDefaultImpl(ptr: *anyopaque, k: Mixer.Kind, id: Mixer.Id) Mixer.Error!void {
    from(ptr).mixer.putDefault(k, id);
}

fn setVolumeImpl(ptr: *anyopaque, target: Mixer.Target, values: []const f32) Mixer.Error!void {
    const mixer = from(ptr).mixer;
    switch (target) {
        .endpoint => |id| {
            var value = (mixer.endpoint(id) orelse return error.UnknownObject).*;
            value.volume = try .initChecked(values);
            try mixer.putEndpoint(value);
        },
        .stream => |id| {
            var value = (mixer.stream(id) orelse return error.UnknownObject).*;
            value.volume = try .initChecked(values);
            try mixer.putStream(value);
        },
    }
}

fn setMuteImpl(ptr: *anyopaque, target: Mixer.Target, mute: bool) Mixer.Error!void {
    const mixer = from(ptr).mixer;
    switch (target) {
        .endpoint => |id| {
            var value = (mixer.endpoint(id) orelse return error.UnknownObject).*;
            value.mute = mute;
            try mixer.putEndpoint(value);
        },
        .stream => |id| {
            var value = (mixer.stream(id) orelse return error.UnknownObject).*;
            value.mute = mute;
            try mixer.putStream(value);
        },
    }
}

fn moveStreamImpl(ptr: *anyopaque, stream_id: Mixer.Id, endpoint_id: Mixer.Id) Mixer.Error!void {
    const mixer = from(ptr).mixer;
    var value = (mixer.stream(stream_id) orelse return error.UnknownObject).*;
    value.endpoint = endpoint_id;
    try mixer.putStream(value);
}

fn setProfileImpl(ptr: *anyopaque, card_id: Mixer.Id, index: u32) Mixer.Error!void {
    const mixer = from(ptr).mixer;
    var value = (mixer.card(card_id) orelse return error.UnknownObject).*;
    value.active_profile = index;
    try mixer.putCard(value);
}

fn setPortImpl(ptr: *anyopaque, endpoint_id: Mixer.Id, index: u32) Mixer.Error!void {
    const mixer = from(ptr).mixer;
    var value = (mixer.endpoint(endpoint_id) orelse return error.UnknownObject).*;
    value.active_port = index;
    try mixer.putEndpoint(value);
}
