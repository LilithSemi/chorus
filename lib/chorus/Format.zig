//! Sample format, rate and channel layout of an audio stream.
const std = @import("std");
const Format = @This();

sample: Sample,
rate: u32,
channels: Channels,

pub const max_channels = 8;
pub const min_rate = 1000;
pub const max_rate = 768000;

/// Multi byte samples are little endian. `s24` is three packed bytes.
pub const Sample = enum {
    u8,
    s16,
    s24,
    s32,
    f32,
    f64,

    pub fn bytes(self: Sample) u8 {
        return switch (self) {
            .u8 => 1,
            .s16 => 2,
            .s24 => 3,
            .s32, .f32 => 4,
            .f64 => 8,
        };
    }

    pub fn isFloat(self: Sample) bool {
        return switch (self) {
            .f32, .f64 => true,
            else => false,
        };
    }
};

/// Values from `aux_base` up are PipeWire AUX channels. Other values are unknown positions.
pub const Position = enum(u8) {
    mono,
    front_left,
    front_right,
    front_center,
    lfe,
    rear_left,
    rear_right,
    side_left,
    side_right,
    _,

    pub fn aux(n: u8) Position {
        std.debug.assert(n < 64);
        return @fromBackingInt(aux_base + n);
    }
};

pub const aux_base: u8 = 32;

pub const Channels = struct {
    count: u8,
    /// Unused slots hold `.mono`.
    positions: [max_channels]Position,

    pub const mono: Channels = .init(&.{.mono});
    pub const stereo: Channels = .init(&.{ .front_left, .front_right });
    pub const surround_5_1: Channels = .init(&.{
        .front_left, .front_right, .front_center, .lfe, .rear_left, .rear_right,
    });
    pub const surround_7_1: Channels = .init(&.{
        .front_left, .front_right, .front_center, .lfe,
        .rear_left,  .rear_right,  .side_left,    .side_right,
    });

    pub fn init(positions: []const Position) Channels {
        std.debug.assert(positions.len >= 1 and positions.len <= max_channels);
        var result: Channels = .{
            .count = @intCast(positions.len),
            .positions = @splat(.mono),
        };
        @memcpy(result.positions[0..positions.len], positions);
        return result;
    }

    pub fn slice(self: *const Channels) []const Position {
        return self.positions[0..self.count];
    }

    pub fn indexOf(self: Channels, position: Position) ?u8 {
        for (self.slice(), 0..) |p, i| {
            if (p == position) return @intCast(i);
        }
        return null;
    }

    pub fn eql(a: Channels, b: Channels) bool {
        return a.count == b.count and std.mem.eql(Position, a.slice(), b.slice());
    }
};

pub fn frameBytes(self: Format) usize {
    return @as(usize, self.sample.bytes()) * self.channels.count;
}

pub fn validate(self: Format) error{UnsupportedFormat}!void {
    if (self.rate < min_rate or self.rate > max_rate) return error.UnsupportedFormat;
    if (self.channels.count < 1 or self.channels.count > max_channels) return error.UnsupportedFormat;
}

pub fn eql(a: Format, b: Format) bool {
    return a.sample == b.sample and a.rate == b.rate and a.channels.eql(b.channels);
}

test "sample size matches the wire size" {
    try std.testing.expectEqual(@as(u8, 1), Sample.u8.bytes());
    try std.testing.expectEqual(@as(u8, 2), Sample.s16.bytes());
    try std.testing.expectEqual(@as(u8, 3), Sample.s24.bytes());
    try std.testing.expectEqual(@as(u8, 4), Sample.s32.bytes());
    try std.testing.expectEqual(@as(u8, 4), Sample.f32.bytes());
    try std.testing.expectEqual(@as(u8, 8), Sample.f64.bytes());
    try std.testing.expect(Sample.f32.isFloat());
    try std.testing.expect(!Sample.s32.isFloat());
}

test "stereo is front left then front right" {
    try std.testing.expectEqualSlices(
        Position,
        &.{ .front_left, .front_right },
        Channels.stereo.slice(),
    );
}

test "5.1 and 7.1 use the PipeWire channel order" {
    try std.testing.expectEqualSlices(
        Position,
        &.{ .front_left, .front_right, .front_center, .lfe, .rear_left, .rear_right },
        Channels.surround_5_1.slice(),
    );
    try std.testing.expectEqual(@as(u8, 8), Channels.surround_7_1.count);
    try std.testing.expectEqual(Position.side_right, Channels.surround_7_1.slice()[7]);
}

test "frame size is sample size times channel count" {
    const f: Format = .{ .sample = .s24, .rate = 48000, .channels = .surround_5_1 };
    try std.testing.expectEqual(@as(usize, 18), f.frameBytes());
}

test "indexOf finds a position and gives null for a missing one" {
    try std.testing.expectEqual(@as(?u8, 2), Channels.surround_5_1.indexOf(.front_center));
    try std.testing.expectEqual(@as(?u8, null), Channels.stereo.indexOf(.lfe));
}

test "formats are equal only when sample, rate and layout are equal" {
    const a: Format = .{ .sample = .f32, .rate = 48000, .channels = .stereo };
    var b = a;
    try std.testing.expect(a.eql(b));
    b.rate = 44100;
    try std.testing.expect(!a.eql(b));
    b = a;
    b.channels = Channels.init(&.{ .front_right, .front_left });
    try std.testing.expect(!a.eql(b));
}

test "validate accepts only rates from 1000 to 768000" {
    var f: Format = .{ .sample = .s16, .rate = 999, .channels = .stereo };
    try std.testing.expectError(error.UnsupportedFormat, f.validate());
    f.rate = 1000;
    try f.validate();
    f.rate = 768000;
    try f.validate();
    f.rate = 768001;
    try std.testing.expectError(error.UnsupportedFormat, f.validate());
}

test "validate rejects a layout with no channels or too many" {
    var f: Format = .{ .sample = .s16, .rate = 48000, .channels = .stereo };
    f.channels.count = 0;
    try std.testing.expectError(error.UnsupportedFormat, f.validate());
    f.channels.count = max_channels + 1;
    try std.testing.expectError(error.UnsupportedFormat, f.validate());
}
