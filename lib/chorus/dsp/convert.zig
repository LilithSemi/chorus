//! Conversion between sample formats and f32.
const std = @import("std");
const Format = @import("../Format.zig");

pub const Dither = struct {
    prng: std.Random.DefaultPrng,

    pub fn init(seed: u64) Dither {
        return .{ .prng = .init(seed) };
    }
};

fn scale(sample: Format.Sample) f64 {
    return switch (sample) {
        .u8 => 128.0,
        .s16 => 32768.0,
        .s24 => 8388608.0,
        .s32 => 2147483648.0,
        .f32, .f64 => unreachable,
    };
}

/// src.len must be dst.len * sample.bytes().
pub fn toF32(sample: Format.Sample, src: []const u8, dst: []f32) void {
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
            d.* = @floatCast(@as(f64, @floatFromInt(v)) / 2147483648.0);
        },
        .f32 => for (dst, 0..) |*d, i| {
            d.* = @bitCast(std.mem.readInt(u32, src[i * 4 ..][0..4], .little));
        },
        .f64 => for (dst, 0..) |*d, i| {
            const v: f64 = @bitCast(std.mem.readInt(u64, src[i * 8 ..][0..8], .little));
            d.* = @floatCast(v);
        },
    }
}

/// dst.len must be src.len * sample.bytes(). Dither applies to u8, s16 and s24 only.
pub fn fromF32(sample: Format.Sample, src: []const f32, dst: []u8, dither: ?*Dither) void {
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
            const v: i64 = quantize(sample, x, dither);
            d.* = @intCast(v + 128);
        },
        .s16 => for (src, 0..) |x, i| {
            const v: i16 = @intCast(quantize(sample, x, dither));
            std.mem.writeInt(i16, dst[i * 2 ..][0..2], v, .little);
        },
        .s24 => for (src, 0..) |x, i| {
            const v: i24 = @intCast(quantize(sample, x, dither));
            std.mem.writeInt(i24, dst[i * 3 ..][0..3], v, .little);
        },
        .s32 => for (src, 0..) |x, i| {
            const v: i32 = @intCast(quantize(sample, x, dither));
            std.mem.writeInt(i32, dst[i * 4 ..][0..4], v, .little);
        },
    }
}

/// Gives the signed integer level of `x` for an integer format.
fn quantize(sample: Format.Sample, x: f32, dither: ?*Dither) i64 {
    if (std.math.isNan(x)) return 0;
    const s = scale(sample);
    var v: f64 = @as(f64, x) * s;
    if (sample != .s32) {
        if (dither) |d| {
            const random = d.prng.random();
            const r1 = random.float(f32);
            const r2 = random.float(f32);
            v += r1 - r2;
        }
    }
    return @intFromFloat(std.math.clamp(@round(v), -s, s - 1.0));
}

/// Writes the zero level of the format: 0x80 for u8, 0 for the rest.
pub fn silence(sample: Format.Sample, dst: []u8) void {
    @memset(dst, if (sample == .u8) 0x80 else 0);
}

test "s16 survives a round trip exactly" {
    const values = [_]i16{ -32768, -1, 0, 1, 32767 };
    var bytes: [values.len * 2]u8 = undefined;
    for (values, 0..) |v, i| std.mem.writeInt(i16, bytes[i * 2 ..][0..2], v, .little);
    var floats: [values.len]f32 = undefined;
    toF32(.s16, &bytes, &floats);
    try std.testing.expectEqual(@as(f32, -1.0), floats[0]);
    var back: [bytes.len]u8 = undefined;
    fromF32(.s16, &floats, &back, null);
    try std.testing.expectEqualSlices(u8, &bytes, &back);
}

test "s24 sign extends from bit 23" {
    const bytes = [_]u8{ 0x00, 0x00, 0x80, 0xff, 0xff, 0x7f };
    var floats: [2]f32 = undefined;
    toF32(.s24, &bytes, &floats);
    try std.testing.expectEqual(@as(f32, -1.0), floats[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 8388607.0 / 8388608.0), floats[1], 1e-7);
}

test "u8 128 is the zero level" {
    var floats: [1]f32 = undefined;
    toF32(.u8, &.{128}, &floats);
    try std.testing.expectEqual(@as(f32, 0.0), floats[0]);
    var bytes: [3]u8 = undefined;
    silence(.u8, &bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x80 }, &bytes);
}

test "integer output clamps values outside -1 to 1" {
    var bytes: [4]u8 = undefined;
    fromF32(.s16, &.{ 1.5, -1.5 }, &bytes, null);
    try std.testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, bytes[0..2], .little));
    try std.testing.expectEqual(@as(i16, -32768), std.mem.readInt(i16, bytes[2..4], .little));
}

test "NaN becomes silence in integer output" {
    var bytes: [2]u8 = undefined;
    fromF32(.s16, &.{std.math.nan(f32)}, &bytes, null);
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, &bytes, .little));
}

test "dither moves s16 output by at most one step and keeps the mean" {
    var src: [1000]f32 = undefined;
    @memset(&src, 0.25);
    var bytes: [src.len * 2]u8 = undefined;
    var dither: Dither = .init(1);
    fromF32(.s16, &src, &bytes, &dither);
    var sum: i64 = 0;
    var differs = false;
    for (0..src.len) |i| {
        const v = std.mem.readInt(i16, bytes[i * 2 ..][0..2], .little);
        try std.testing.expect(v >= 8191 and v <= 8193);
        if (v != 8192) differs = true;
        sum += v;
    }
    try std.testing.expect(differs);
    const mean = @as(f64, @floatFromInt(sum)) / src.len;
    try std.testing.expectApproxEqAbs(@as(f64, 8192.0), mean, 0.1);
}

test "f32 survives a round trip bit for bit" {
    const src = [_]f32{ 0.1, -0.7, 1.0, 3.5 };
    var bytes: [16]u8 = undefined;
    fromF32(.f32, &src, &bytes, null);
    var back: [4]f32 = undefined;
    toF32(.f32, &bytes, &back);
    try std.testing.expectEqualSlices(f32, &src, &back);
}

test "u8 output maps -1, 0 and 1 to 0x00, 0x80 and 0xff" {
    var bytes: [4]u8 = undefined;
    fromF32(.u8, &.{ 0, 1.0, -1.0, 2.0 }, &bytes, null);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0xff, 0x00, 0xff }, &bytes);
}

test "s24 output writes little endian full scale values" {
    var bytes: [6]u8 = undefined;
    fromF32(.s24, &.{ 1.0, -1.0 }, &bytes, null);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0x7f, 0x00, 0x00, 0x80 }, &bytes);
}
