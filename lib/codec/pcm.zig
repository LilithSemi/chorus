//! Little endian PCM sample conversion shared by the container formats.
const std = @import("std");
const testing = std.testing;

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
        return self == .f32 or self == .f64;
    }
};

fn scale(sample: Sample) f64 {
    return switch (sample) {
        .u8 => 128.0,
        .s16 => 32768.0,
        .s24 => 8388608.0,
        .s32 => 2147483648.0,
        .f32, .f64 => unreachable,
    };
}

/// The biggest f32 below 1.0. Decoded samples stay in [-1, `max_below_one`].
pub const max_below_one: f32 = 0x1.fffffep-1;

/// Maps NaN to 0 and clamps to [-1, `max_below_one`].
pub fn clampUnit(x: f32) f32 {
    if (std.math.isNan(x)) return 0;
    return std.math.clamp(x, -1.0, max_below_one);
}

/// `src.len` must be `dst.len * sample.bytes()`. Integers scale by 2^(bits-1). The output is
/// finite and in [-1, 1): full scale positive integers give `max_below_one`, NaN gives 0,
/// and floats outside the range are clamped.
pub fn toF32(sample: Sample, src: []const u8, dst: []f32) void {
    std.debug.assert(src.len == dst.len * sample.bytes());
    switch (sample) {
        .u8 => for (dst, src) |*d, b| {
            d.* = (@as(f32, @floatFromInt(b)) - 128.0) / 128.0;
        },
        .s16 => for (dst, 0..) |*d, i| {
            const v = std.mem.readInt(i16, src[i * 2 ..][0..2], .little);
            d.* = @as(f32, @floatFromInt(v)) / 32768.0;
        },
        .s24 => for (dst, 0..) |*d, i| {
            const v = std.mem.readInt(i24, src[i * 3 ..][0..3], .little);
            d.* = @as(f32, @floatFromInt(v)) / 8388608.0;
        },
        .s32 => for (dst, 0..) |*d, i| {
            const v = std.mem.readInt(i32, src[i * 4 ..][0..4], .little);
            d.* = clampUnit(@floatCast(@as(f64, @floatFromInt(v)) / 2147483648.0));
        },
        .f32 => for (dst, 0..) |*d, i| {
            d.* = clampUnit(@bitCast(std.mem.readInt(u32, src[i * 4 ..][0..4], .little)));
        },
        .f64 => for (dst, 0..) |*d, i| {
            const v: f64 = @bitCast(std.mem.readInt(u64, src[i * 8 ..][0..8], .little));
            d.* = clampUnit(@floatCast(v));
        },
    }
}

/// `dst.len` must be `src.len * sample.bytes()`. Integer output rounds and clamps.
pub fn fromF32(sample: Sample, src: []const f32, dst: []u8) void {
    std.debug.assert(dst.len == src.len * sample.bytes());
    switch (sample) {
        .f32 => for (src, 0..) |x, i| {
            std.mem.writeInt(u32, dst[i * 4 ..][0..4], @bitCast(x), .little);
        },
        .f64 => for (src, 0..) |x, i| {
            const v: f64 = x;
            std.mem.writeInt(u64, dst[i * 8 ..][0..8], @bitCast(v), .little);
        },
        .u8 => for (src, dst) |x, *d| {
            d.* = @intCast(quantize(x, scale(sample)) + 128);
        },
        .s16 => for (src, 0..) |x, i| {
            const v: i16 = @intCast(quantize(x, scale(sample)));
            std.mem.writeInt(i16, dst[i * 2 ..][0..2], v, .little);
        },
        .s24 => for (src, 0..) |x, i| {
            const v: i24 = @intCast(quantize(x, scale(sample)));
            std.mem.writeInt(i24, dst[i * 3 ..][0..3], v, .little);
        },
        .s32 => for (src, 0..) |x, i| {
            const v: i32 = @intCast(quantize(x, scale(sample)));
            std.mem.writeInt(i32, dst[i * 4 ..][0..4], v, .little);
        },
    }
}

/// Rounds `x * full` to an integer and clamps it to [-full, full - 1]. NaN gives 0.
pub fn quantize(x: f32, full: f64) i64 {
    if (std.math.isNan(x)) return 0;
    const v: f64 = @as(f64, x) * full;
    return @intFromFloat(std.math.clamp(@round(v), -full, full - 1.0));
}

test "integer samples convert with the 2^(bits-1) scale" {
    var f: [2]f32 = undefined;
    toF32(.u8, &.{ 0, 192 }, &f);
    try testing.expectEqualSlices(f32, &.{ -1.0, 0.5 }, &f);
    toF32(.s16, &.{ 0x00, 0x80, 0x00, 0x40 }, &f);
    try testing.expectEqualSlices(f32, &.{ -1.0, 0.5 }, &f);
    toF32(.s24, &.{ 0, 0, 0x80, 0, 0, 0x40 }, &f);
    try testing.expectEqualSlices(f32, &.{ -1.0, 0.5 }, &f);
    toF32(.s32, &.{ 0, 0, 0, 0x80, 0, 0, 0, 0x40 }, &f);
    try testing.expectEqualSlices(f32, &.{ -1.0, 0.5 }, &f);
}

test "decoded samples are finite and in [-1, 1)" {
    var f: [2]f32 = undefined;
    toF32(.s32, &.{ 0xff, 0xff, 0xff, 0x7f, 0, 0, 0, 0x80 }, &f);
    try testing.expectEqual(max_below_one, f[0]);
    try testing.expectEqual(@as(f32, -1.0), f[1]);
    toF32(.s24, &.{ 0xff, 0xff, 0x7f, 0, 0, 0x80 }, &f);
    try testing.expectEqual(@as(f32, 1.0 - 0x1p-23), f[0]);
    try testing.expectEqual(@as(f32, -1.0), f[1]);
    toF32(.u8, &.{ 255, 0 }, &f);
    try testing.expectEqual(@as(f32, 127.0 / 128.0), f[0]);
    try testing.expectEqual(@as(f32, -1.0), f[1]);

    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const floats = [_]f32{ nan, inf, -inf, 1.0, -1.0, 2.5, -3.0, 0.25, -0.0, 0x1.fffffep-1 };
    const want = [_]f32{ 0.0, max_below_one, -1.0, max_below_one, -1.0, max_below_one, -1.0, 0.25, -0.0, max_below_one };
    var bytes32: [floats.len * 4]u8 = undefined;
    for (floats, 0..) |x, i| std.mem.writeInt(u32, bytes32[i * 4 ..][0..4], @bitCast(x), .little);
    var got: [floats.len]f32 = undefined;
    toF32(.f32, &bytes32, &got);
    try testing.expectEqualSlices(f32, &want, &got);

    const doubles = [_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), 1.0, 1e300, 0.99999999999, -2.0, 0.5 };
    const want64 = [_]f32{ 0.0, max_below_one, -1.0, max_below_one, max_below_one, max_below_one, -1.0, 0.5 };
    var bytes64: [doubles.len * 8]u8 = undefined;
    for (doubles, 0..) |x, i| std.mem.writeInt(u64, bytes64[i * 8 ..][0..8], @bitCast(x), .little);
    var got64: [doubles.len]f32 = undefined;
    toF32(.f64, &bytes64, &got64);
    try testing.expectEqualSlices(f32, &want64, &got64);
}

test "output clamps, rounds and maps NaN to silence" {
    var b: [6]u8 = undefined;
    fromF32(.s16, &.{ 1.5, -1.5, std.math.nan(f32) }, &b);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0x7f, 0x00, 0x80, 0, 0 }, &b);
    var u: [2]u8 = undefined;
    fromF32(.u8, &.{ 1.0, -1.0 }, &u);
    try testing.expectEqualSlices(u8, &.{ 255, 0 }, &u);
}

test "values match the chorus dsp.convert tests" {
    const values = [_]i16{ -32768, -1, 0, 1, 32767 };
    var bytes: [values.len * 2]u8 = undefined;
    for (values, 0..) |v, i| std.mem.writeInt(i16, bytes[i * 2 ..][0..2], v, .little);
    var floats: [values.len]f32 = undefined;
    toF32(.s16, &bytes, &floats);
    try testing.expectEqual(@as(f32, -1.0), floats[0]);
    var back: [bytes.len]u8 = undefined;
    fromF32(.s16, &floats, &back);
    try testing.expectEqualSlices(u8, &bytes, &back);

    var f2: [2]f32 = undefined;
    toF32(.s24, &.{ 0x00, 0x00, 0x80, 0xff, 0xff, 0x7f }, &f2);
    try testing.expectEqual(@as(f32, -1.0), f2[0]);
    try testing.expectApproxEqAbs(@as(f32, 8388607.0 / 8388608.0), f2[1], 1e-7);

    var z: [1]f32 = undefined;
    toF32(.u8, &.{128}, &z);
    try testing.expectEqual(@as(f32, 0.0), z[0]);

    var clamp: [4]u8 = undefined;
    fromF32(.s16, &.{ 1.5, -1.5 }, &clamp);
    try testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, clamp[0..2], .little));
    try testing.expectEqual(@as(i16, -32768), std.mem.readInt(i16, clamp[2..4], .little));

    var nan: [2]u8 = undefined;
    fromF32(.s16, &.{std.math.nan(f32)}, &nan);
    try testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, &nan, .little));
}
