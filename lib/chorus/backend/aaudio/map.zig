//! Conversions between Chorus values and AAudio values.
const std = @import("std");
const Format = @import("../../Format.zig");
const Stream = @import("../../Stream.zig");
const api = @import("api.zig");

pub fn usage(role: Stream.Role) i32 {
    return switch (role) {
        .media => api.Usage.media,
        .ui => api.Usage.assistance_sonification,
        .game => api.Usage.game,
        .communication => api.Usage.voice_communication,
        .notification => api.Usage.notification,
        .alarm => api.Usage.alarm,
    };
}

pub fn contentType(role: Stream.Role) i32 {
    return switch (role) {
        .media => api.ContentType.music,
        .communication => api.ContentType.speech,
        .ui, .game, .notification, .alarm => api.ContentType.sonification,
    };
}

pub fn inputPreset(role: Stream.Role) i32 {
    return switch (role) {
        .communication => api.InputPreset.voice_communication,
        .media, .ui, .game, .notification, .alarm => api.InputPreset.voice_recognition,
    };
}

/// The AudioManager stream type constants.
pub const AudioManagerStream = struct {
    pub const voice_call: i32 = 0;
    pub const system: i32 = 1;
    pub const ring: i32 = 2;
    pub const music: i32 = 3;
    pub const alarm: i32 = 4;
    pub const notification: i32 = 5;
};

/// The AudioManager stream type whose volume applies to the role.
pub fn volumeStream(role: Stream.Role) i32 {
    return switch (role) {
        .media, .game => AudioManagerStream.music,
        .ui => AudioManagerStream.system,
        .communication => AudioManagerStream.voice_call,
        .notification => AudioManagerStream.notification,
        .alarm => AudioManagerStream.alarm,
    };
}

pub fn toAAudioFormat(sample: Format.Sample) ?i32 {
    return switch (sample) {
        .s16 => api.Format.pcm_i16,
        .f32 => api.Format.pcm_float,
        .s24 => api.Format.pcm_i24_packed,
        .s32 => api.Format.pcm_i32,
        .u8, .f64 => null,
    };
}

pub fn fromAAudioFormat(format: i32) ?Format.Sample {
    return switch (format) {
        api.Format.pcm_i16 => .s16,
        api.Format.pcm_float => .f32,
        api.Format.pcm_i24_packed => .s24,
        api.Format.pcm_i32 => .s32,
        else => null,
    };
}

const bit_table = [_]struct { position: Format.Position, bit: u32 }{
    .{ .position = .front_left, .bit = api.ChannelMask.front_left },
    .{ .position = .front_right, .bit = api.ChannelMask.front_right },
    .{ .position = .front_center, .bit = api.ChannelMask.front_center },
    .{ .position = .lfe, .bit = api.ChannelMask.low_frequency },
    .{ .position = .rear_left, .bit = api.ChannelMask.back_left },
    .{ .position = .rear_right, .bit = api.ChannelMask.back_right },
    .{ .position = .side_left, .bit = api.ChannelMask.side_left },
    .{ .position = .side_right, .bit = api.ChannelMask.side_right },
};

fn bitOf(position: Format.Position) ?u32 {
    if (position == .mono) return api.ChannelMask.front_left;
    for (bit_table) |row| {
        if (row.position == position) return row.bit;
    }
    return null;
}

/// The mask of a Chorus layout, the OR of the bit of each position. AAudio interleaves in bit order.
/// Null when a position has no AAudio bit or two positions have the same bit.
pub fn maskFromChannels(channels: Format.Channels) ?u32 {
    var mask: u32 = 0;
    for (channels.slice()) |position| {
        const bit = bitOf(position) orelse return null;
        if (mask & bit != 0) return null;
        mask |= bit;
    }
    return mask;
}

/// The layout of the channels of a mask, in the order of its bits.
pub fn channelsFromMask(mask: u32) Format.Channels {
    var positions: [Format.max_channels]Format.Position = undefined;
    var n: usize = 0;
    var bits = bit_table;
    std.mem.sort(@TypeOf(bits[0]), &bits, {}, struct {
        fn less(_: void, x: @TypeOf(bits[0]), y: @TypeOf(bits[0])) bool {
            return x.bit < y.bit;
        }
    }.less);
    for (bits) |row| {
        if (mask & row.bit == 0) continue;
        positions[n] = row.position;
        n += 1;
    }
    return .init(positions[0..n]);
}

/// Index channels: AAudio passes the channels on in order, and no position is known.
pub fn auxChannels(count: u8) Format.Channels {
    var positions: [Format.max_channels]Format.Position = undefined;
    for (positions[0..count], 0..) |*position, i| position.* = .aux(@intCast(i));
    return .init(positions[0..count]);
}

/// The layout that AAudio gives to a channel count for output when the open sets no channel mask,
/// which is the case before API 32. Input and other counts use index channels.
pub fn canonicalChannels(count: u8) Format.Channels {
    switch (count) {
        1 => return .mono,
        2 => return .stereo,
        3 => return .init(&.{ .front_left, .front_right, .front_center }),
        4 => return .init(&.{ .front_left, .front_right, .rear_left, .rear_right }),
        5 => return .init(&.{ .front_left, .front_right, .front_center, .rear_left, .rear_right }),
        6 => return .surround_5_1,
        8 => return .surround_7_1,
        else => return auxChannels(count),
    }
}

/// UNAVAILABLE also means too many streams in the process. The backend refines it when no device was set.
pub fn openError(result: api.Result) Stream.OpenError {
    return switch (result) {
        api.ResultCode.illegal_argument,
        api.ResultCode.invalid_format,
        api.ResultCode.invalid_rate,
        api.ResultCode.out_of_range,
        => error.UnsupportedFormat,
        api.ResultCode.no_memory, api.ResultCode.no_free_handles => error.OutOfMemory,
        api.ResultCode.unavailable => error.UnknownDevice,
        else => error.Disconnected,
    };
}

pub fn startError(result: api.Result) Stream.StartError {
    _ = result;
    return error.Disconnected;
}

test "roles map to usage, content type, preset and volume stream" {
    const t = std.testing;
    const Role = Stream.Role;
    const rows = [_]struct { Role, i32, i32, i32, i32 }{
        .{ .media, 1, 2, 6, 3 },
        .{ .ui, 13, 4, 6, 1 },
        .{ .game, 14, 4, 6, 3 },
        .{ .communication, 2, 1, 7, 0 },
        .{ .notification, 5, 4, 6, 5 },
        .{ .alarm, 4, 4, 6, 4 },
    };
    for (rows) |row| {
        try t.expectEqual(row[1], usage(row[0]));
        try t.expectEqual(row[2], contentType(row[0]));
        try t.expectEqual(row[3], inputPreset(row[0]));
        try t.expectEqual(row[4], volumeStream(row[0]));
    }
    try t.expectEqual(@typeInfo(Role).@"enum".field_names.len, rows.len);
}

test "formats map both ways" {
    const t = std.testing;
    try t.expectEqual(@as(?i32, 1), toAAudioFormat(.s16));
    try t.expectEqual(@as(?i32, 2), toAAudioFormat(.f32));
    try t.expectEqual(@as(?i32, 3), toAAudioFormat(.s24));
    try t.expectEqual(@as(?i32, 4), toAAudioFormat(.s32));
    try t.expectEqual(@as(?i32, null), toAAudioFormat(.u8));
    try t.expectEqual(@as(?i32, null), toAAudioFormat(.f64));
    try t.expectEqual(@as(?Format.Sample, .s16), fromAAudioFormat(1));
    try t.expectEqual(@as(?Format.Sample, .f32), fromAAudioFormat(2));
    try t.expectEqual(@as(?Format.Sample, .s24), fromAAudioFormat(3));
    try t.expectEqual(@as(?Format.Sample, .s32), fromAAudioFormat(4));
    try t.expectEqual(@as(?Format.Sample, null), fromAAudioFormat(0));
    try t.expectEqual(@as(?Format.Sample, null), fromAAudioFormat(5));
    try t.expectEqual(@as(?Format.Sample, null), fromAAudioFormat(-1));
}

test "channel masks follow the Android layouts" {
    const t = std.testing;
    try t.expectEqual(@as(?u32, 0x3), maskFromChannels(.stereo));
    try t.expectEqual(@as(?u32, 0x7), maskFromChannels(.init(&.{ .front_left, .front_right, .front_center })));
    try t.expectEqual(@as(?u32, 0x33), maskFromChannels(.init(&.{ .front_left, .front_right, .rear_left, .rear_right })));
    try t.expectEqual(@as(?u32, 0x3f), maskFromChannels(.surround_5_1));
    try t.expectEqual(@as(?u32, 0x63f), maskFromChannels(.surround_7_1));
    try t.expectEqual(@as(?u32, 0x1), maskFromChannels(.mono));
    try t.expectEqual(@as(?u32, 0x7), maskFromChannels(.init(&.{ .front_right, .front_left, .front_center })));
    try t.expect(channelsFromMask(0x7).eql(.init(&.{ .front_left, .front_right, .front_center })));
    try t.expect(channelsFromMask(0x63f).eql(.surround_7_1));
    try t.expectEqual(@as(?u32, null), maskFromChannels(.init(&.{ .front_left, .front_left })));
    try t.expectEqual(@as(?u32, null), maskFromChannels(.init(&.{ .front_left, .aux(0) })));
}

test "a channel count without a mask has a fixed layout" {
    const t = std.testing;
    try t.expect(canonicalChannels(2).eql(.stereo));
    try t.expect(canonicalChannels(6).eql(.surround_5_1));
    try t.expect(canonicalChannels(8).eql(.surround_7_1));
    try t.expectEqual(@as(u8, 4), canonicalChannels(4).count);
    try t.expectEqual(Format.Position.rear_left, canonicalChannels(4).positions[2]);
    try t.expectEqual(Format.Position.aux(0), canonicalChannels(7).positions[0]);
}

test "result codes map to open and start errors" {
    const t = std.testing;
    const R = api.ResultCode;
    try t.expectEqual(error.Disconnected, openError(R.disconnected));
    try t.expectEqual(error.Disconnected, openError(R.no_service));
    try t.expectEqual(error.UnsupportedFormat, openError(R.illegal_argument));
    try t.expectEqual(error.UnsupportedFormat, openError(R.invalid_format));
    try t.expectEqual(error.UnsupportedFormat, openError(R.invalid_rate));
    try t.expectEqual(error.UnsupportedFormat, openError(R.out_of_range));
    try t.expectEqual(error.OutOfMemory, openError(R.no_memory));
    try t.expectEqual(error.OutOfMemory, openError(R.no_free_handles));
    try t.expectEqual(error.UnknownDevice, openError(R.unavailable));
    try t.expectEqual(error.Disconnected, openError(R.internal));
    try t.expectEqual(error.Disconnected, openError(R.timeout));
    try t.expectEqual(error.Disconnected, startError(R.disconnected));
    try t.expectEqual(error.Disconnected, startError(R.invalid_state));
}
