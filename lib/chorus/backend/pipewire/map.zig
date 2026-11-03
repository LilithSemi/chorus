//! Conversions between the wireplumber model and the Mixer model.
const std = @import("std");
const pipewire = @import("pipewire");
const wireplumber = @import("wireplumber");
const Format = @import("../../Format.zig");
const Mixer = @import("../../Mixer.zig");

const Graph = wireplumber.Graph;
const AudioChannel = pipewire.spa.AudioChannel;

pub const Error = error{ OutOfMemory, InvalidVolume };

const unknown_raw: u8 = 0xff;

/// A position that has no Chorus name.
pub const unknown_position: Format.Position = @fromBackingInt(unknown_raw);

const aux_count = 64;

pub fn mixerId(id: Graph.Id) Mixer.Id {
    return @fromBackingInt(id);
}

pub fn graphId(id: Mixer.Id) Graph.Id {
    return @backingInt(id);
}

pub fn toChannel(position: Format.Position) AudioChannel {
    return switch (position) {
        .mono => .mono,
        .front_left => .fl,
        .front_right => .fr,
        .front_center => .fc,
        .lfe => .lfe,
        .rear_left => .rl,
        .rear_right => .rr,
        .side_left => .sl,
        .side_right => .sr,
        _ => {
            const raw: u32 = @backingInt(position);
            if (raw >= Format.aux_base and raw < Format.aux_base + aux_count) return .aux(raw - Format.aux_base);
            return .unknown;
        },
    };
}

pub fn fromChannel(channel: AudioChannel) Format.Position {
    return switch (channel) {
        .mono => .mono,
        .fl => .front_left,
        .fr => .front_right,
        .fc => .front_center,
        .lfe => .lfe,
        .rl => .rear_left,
        .rr => .rear_right,
        .sl => .side_left,
        .sr => .side_right,
        else => {
            const raw: u32 = @backingInt(channel);
            if (raw >= AudioChannel.aux_first and raw < AudioChannel.aux_first + aux_count) {
                return .aux(@intCast(raw - AudioChannel.aux_first));
            }
            return unknown_position;
        },
    };
}

/// The result points into `arena`.
pub fn card(arena: std.mem.Allocator, c: Graph.Card) Error!Mixer.Card {
    const profiles = try arena.alloc(Mixer.Profile, c.profiles.len);
    for (c.profiles, profiles) |p, *out| {
        out.* = .{ .index = p.index, .name = p.name, .description = p.description, .available = p.available };
    }
    return .{
        .id = mixerId(c.id),
        .name = c.name,
        .description = c.description,
        .profiles = profiles,
        .active_profile = c.active_profile,
    };
}

/// The result points into `arena`. Volumes are the linear channel volumes of the server.
pub fn endpoint(arena: std.mem.Allocator, e: Graph.Endpoint) Error!Mixer.Endpoint {
    const ports = try arena.alloc(Mixer.Port, e.ports.len);
    for (e.ports, ports) |p, *out| {
        out.* = .{ .index = p.index, .name = p.name, .description = p.description, .available = p.available };
    }
    return .{
        .id = mixerId(e.id),
        .kind = switch (e.kind) {
            .sink => .sink,
            .source => .source,
        },
        .name = e.name,
        .description = e.description,
        .card = if (e.card) |c| mixerId(c) else null,
        .volume = try .initChecked(e.volume.channels()),
        .mute = e.volume.mute,
        .ports = ports,
        .active_port = e.active_port,
    };
}

/// A capture stream that records a sink monitor has no target in the graph. Its endpoint is
/// null.
pub fn stream(s: Graph.AppStream) Error!Mixer.AppStream {
    return .{
        .id = mixerId(s.id),
        .direction = switch (s.direction) {
            .playback => .playback,
            .capture => .capture,
        },
        .app_name = s.app_name,
        .name = s.media_name,
        .endpoint = if (s.target) |t| mixerId(t) else null,
        .volume = try .initChecked(s.volume.channels()),
        .mute = s.volume.mute,
    };
}

test "every position survives a round trip" {
    const named = [_]Format.Position{
        .mono,      .front_left, .front_right, .front_center, .lfe,
        .rear_left, .rear_right, .side_left,   .side_right,   .aux(0),
        .aux(5),    .aux(63),
    };
    for (named) |p| try std.testing.expectEqual(p, fromChannel(toChannel(p)));
}

test "positions use the PipeWire channel values" {
    try std.testing.expectEqual(AudioChannel.fl, toChannel(.front_left));
    try std.testing.expectEqual(AudioChannel.sr, toChannel(.side_right));
    try std.testing.expectEqual(@as(u32, 0x1005), @backingInt(toChannel(.aux(5))));
    try std.testing.expectEqual(Format.Position.aux(5), fromChannel(AudioChannel.aux(5)));
}

test "channels without a Chorus name map to an unknown position" {
    try std.testing.expectEqual(unknown_position, fromChannel(.rc));
    try std.testing.expectEqual(unknown_position, fromChannel(.unknown));
    try std.testing.expectEqual(unknown_position, fromChannel(AudioChannel.aux(64)));
    try std.testing.expectEqual(AudioChannel.unknown, toChannel(unknown_position));
    try std.testing.expectEqual(AudioChannel.unknown, toChannel(@fromBackingInt(31)));
}
