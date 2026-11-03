//! Conversions between Chorus values and CoreAudio values.
const std = @import("std");
const Mixer = @import("../../Mixer.zig");
const api = @import("api.zig");

/// What an OSStatus means for the backend. The caller turns it into the error set of its function.
pub const Failure = error{
    Unsupported,
    OutOfMemory,
    Disconnected,
    UnknownObject,
    UnknownDevice,
    UnsupportedFormat,
    PermissionDenied,
    /// The maximum frames per slice of the unit is too small for the period.
    TooManyFrames,
    /// The client rate of an input unit differs from the device rate.
    RateMismatch,
    /// The backend made a call with a wrong argument or in a wrong state.
    BadCall,
    /// A status that the backend does not know.
    Unexpected,
};

/// Gives null for success and the failure for every other status.
pub fn failure(status: api.OSStatus) ?Failure {
    const s = api.Status;
    return switch (status) {
        s.ok => null,
        s.unimplemented, s.unknown_property, s.illegal_operation, s.unsupported_operation => error.Unsupported,
        s.param, s.bad_property_size => error.BadCall,
        s.unit_invalid_property, s.unit_invalid_parameter, s.unit_invalid_element => error.BadCall,
        s.unit_uninitialized, s.unit_invalid_scope, s.unit_property_not_writable => error.BadCall,
        s.unit_property_not_in_use, s.unit_initialized => error.BadCall,
        s.mem_full, s.component_too_many_instances => error.OutOfMemory,
        s.not_running, s.unspecified, s.not_ready => error.Disconnected,
        s.unit_no_connection, s.unit_failed_initialization, s.component_instance_invalidated => error.Disconnected,
        s.bad_object => error.UnknownObject,
        s.bad_device, s.bad_stream => error.UnknownDevice,
        s.unsupported_format, s.unit_format_not_supported, s.unit_invalid_property_value => error.UnsupportedFormat,
        s.permissions, s.unit_unauthorized, s.component_not_permitted => error.PermissionDenied,
        s.unit_too_many_frames => error.TooManyFrames,
        s.unit_cannot_do_in_current_context => error.RateMismatch,
        else => error.Unexpected,
    };
}

pub fn check(status: api.OSStatus) Failure!void {
    if (failure(status)) |err| return err;
}

/// The four ASCII bytes of a status that is a four character code, for logs. Null for other values.
pub fn statusText(status: api.OSStatus) ?[4]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, @bitCast(status), .big);
    for (bytes) |byte| {
        if (byte < 0x20 or byte > 0x7e) return null;
    }
    return bytes;
}

/// The client format of every stream: 32 bit float, interleaved, one frame per packet.
/// `channels` is 1 to 65535.
pub fn f32Interleaved(rate: f64, channels: u32) api.AudioStreamBasicDescription {
    std.debug.assert(channels > 0 and channels <= std.math.maxInt(u16));
    return .{
        .mSampleRate = rate,
        .mFormatID = api.format_linear_pcm,
        .mFormatFlags = api.FormatFlag.is_float | api.FormatFlag.is_packed,
        .mBytesPerPacket = 4 * channels,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 4 * channels,
        .mChannelsPerFrame = channels,
        .mBitsPerChannel = 32,
    };
}

/// True when the format is linear PCM with 32 bit float samples in one interleaved buffer.
pub fn isF32Interleaved(asbd: api.AudioStreamBasicDescription) bool {
    const wanted = api.FormatFlag.is_float | api.FormatFlag.is_packed;
    return asbd.mFormatID == api.format_linear_pcm and
        asbd.mFormatFlags & (wanted | api.FormatFlag.is_non_interleaved | api.FormatFlag.is_big_endian) == wanted and
        asbd.mBitsPerChannel == 32 and
        asbd.mFramesPerPacket == 1 and
        asbd.mBytesPerFrame == 4 *% asbd.mChannelsPerFrame;
}

/// Linear amplitude of a level in decibels.
pub fn dbToLinear(db: f32) f32 {
    return std.math.pow(f32, 10.0, db / 20.0);
}

/// Level in decibels of a linear amplitude, clamped to the range of the control.
/// Zero and negative amplitudes give the lowest level.
pub fn linearToDb(linear: f32, range: api.AudioValueRange) f32 {
    const low: f32 = @floatCast(range.mMinimum);
    const high: f32 = @floatCast(range.mMaximum);
    if (!(linear > 0)) return low;
    return std.math.clamp(20.0 * std.math.log10(linear), low, high);
}

/// Mixer ids for the two directions of one device. A device with both gets two endpoints.
pub fn endpointId(device: api.AudioObjectID, is_source: bool) ?Mixer.Id {
    if (device > std.math.maxInt(u32) >> 2) return null;
    return @fromBackingInt(@intCast(device << 1 | @intFromBool(is_source)));
}

pub const Endpoint = struct { device: api.AudioObjectID, is_source: bool };

pub fn endpointParts(id: Mixer.Id) Endpoint {
    const raw = @backingInt(id);
    return .{ .device = raw >> 1, .is_source = raw & 1 != 0 };
}

test "every status row maps to its failure" {
    const t = std.testing;
    const s = api.Status;
    const rows = [_]struct { status: api.OSStatus, want: ?Failure }{
        .{ .status = s.ok, .want = null },
        .{ .status = -4, .want = error.Unsupported },
        .{ .status = -50, .want = error.BadCall },
        .{ .status = -108, .want = error.OutOfMemory },
        .{ .status = 0x73746f70, .want = error.Disconnected },
        .{ .status = 0x77686174, .want = error.Disconnected },
        .{ .status = 0x77686f3f, .want = error.Unsupported },
        .{ .status = 0x2173697a, .want = error.BadCall },
        .{ .status = 0x6e6f7065, .want = error.Unsupported },
        .{ .status = 0x216f626a, .want = error.UnknownObject },
        .{ .status = 0x21646576, .want = error.UnknownDevice },
        .{ .status = 0x21737472, .want = error.UnknownDevice },
        .{ .status = 0x756e6f70, .want = error.Unsupported },
        .{ .status = 0x6e726479, .want = error.Disconnected },
        .{ .status = 0x21646174, .want = error.UnsupportedFormat },
        .{ .status = 0x21686f67, .want = error.PermissionDenied },
        .{ .status = -10879, .want = error.BadCall },
        .{ .status = -10878, .want = error.BadCall },
        .{ .status = -10877, .want = error.BadCall },
        .{ .status = -10876, .want = error.Disconnected },
        .{ .status = -10875, .want = error.Disconnected },
        .{ .status = -10874, .want = error.TooManyFrames },
        .{ .status = -10868, .want = error.UnsupportedFormat },
        .{ .status = -10867, .want = error.BadCall },
        .{ .status = -10866, .want = error.BadCall },
        .{ .status = -10865, .want = error.BadCall },
        .{ .status = -10863, .want = error.RateMismatch },
        .{ .status = -10851, .want = error.UnsupportedFormat },
        .{ .status = -10850, .want = error.BadCall },
        .{ .status = -10849, .want = error.BadCall },
        .{ .status = -10847, .want = error.PermissionDenied },
        .{ .status = -66748, .want = error.PermissionDenied },
        .{ .status = -66750, .want = error.OutOfMemory },
        .{ .status = -66749, .want = error.Disconnected },
        .{ .status = 12345, .want = error.Unexpected },
    };
    for (rows) |row| {
        try t.expectEqual(row.want, failure(row.status));
    }
}

test "check returns the failure as an error" {
    try std.testing.expectError(error.Disconnected, check(api.Status.not_ready));
    try check(0);
}

test "a four character status prints as text" {
    const t = std.testing;
    try t.expectEqualStrings("!dev", &statusText(api.Status.bad_device).?);
    try t.expectEqual(@as(?[4]u8, null), statusText(-10879));
    try t.expectEqual(@as(?[4]u8, null), statusText(0));
}

test "the f32 interleaved format fills every field" {
    const t = std.testing;
    const asbd = f32Interleaved(48000, 2);
    try t.expectEqual(@as(f64, 48000), asbd.mSampleRate);
    try t.expectEqual(@as(u32, 0x6c70636d), asbd.mFormatID);
    try t.expectEqual(@as(u32, 0x9), asbd.mFormatFlags);
    try t.expectEqual(@as(u32, 8), asbd.mBytesPerPacket);
    try t.expectEqual(@as(u32, 1), asbd.mFramesPerPacket);
    try t.expectEqual(@as(u32, 8), asbd.mBytesPerFrame);
    try t.expectEqual(@as(u32, 2), asbd.mChannelsPerFrame);
    try t.expectEqual(@as(u32, 32), asbd.mBitsPerChannel);
    try t.expectEqual(@as(u32, 0), asbd.mReserved);
    try t.expect(isF32Interleaved(asbd));
    var planar = asbd;
    planar.mFormatFlags |= api.FormatFlag.is_non_interleaved;
    try t.expect(!isF32Interleaved(planar));
    var wide = f32Interleaved(44100, 6);
    try t.expectEqual(@as(u32, 24), wide.mBytesPerFrame);
    wide.mBitsPerChannel = 16;
    try t.expect(!isF32Interleaved(wide));
}

test "decibels and linear values round trip" {
    const t = std.testing;
    const range: api.AudioValueRange = .{ .mMinimum = -63.5, .mMaximum = 0 };
    try t.expectApproxEqAbs(@as(f32, 1.0), dbToLinear(0), 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.5), dbToLinear(-6.0206), 1e-4);
    try t.expectApproxEqAbs(@as(f32, 0.1), dbToLinear(-20), 1e-6);
    const levels = [_]f32{ -60, -30, -10, -1 };
    for (levels) |db| {
        try t.expectApproxEqAbs(db, linearToDb(dbToLinear(db), range), 1e-3);
    }
    try t.expectEqual(@as(f32, -63.5), linearToDb(0, range));
    try t.expectEqual(@as(f32, -63.5), linearToDb(-1, range));
    try t.expectEqual(@as(f32, -63.5), linearToDb(1e-9, range));
    try t.expectEqual(@as(f32, 0), linearToDb(4, range));
    try t.expectEqual(@as(f32, -63.5), linearToDb(std.math.nan(f32), range));
}

test "endpoint ids pack the device and the direction" {
    const t = std.testing;
    const sink = endpointId(71, false).?;
    const source = endpointId(71, true).?;
    try t.expectEqual(@as(u32, 142), @backingInt(sink));
    try t.expectEqual(@as(u32, 143), @backingInt(source));
    try t.expectEqual(Endpoint{ .device = 71, .is_source = false }, endpointParts(sink));
    try t.expectEqual(Endpoint{ .device = 71, .is_source = true }, endpointParts(source));
    const top = std.math.maxInt(u32) >> 2;
    try t.expectEqual(Endpoint{ .device = top, .is_source = true }, endpointParts(endpointId(top, true).?));
    try t.expectEqual(@as(?Mixer.Id, null), endpointId(top + 1, false));
}
