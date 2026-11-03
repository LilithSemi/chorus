//! Mixing and soft clipping for audio buffers.
const std = @import("std");

pub const clip_threshold: f32 = 0.9;

/// dst[i] += src[i] * gain. Uses @Vector(8, f32) with a scalar tail.
pub fn accumulate(dst: []f32, src: []const f32, gain: f32) void {
    std.debug.assert(dst.len == src.len);
    const V = @Vector(8, f32);
    const g: V = @splat(gain);
    var i: usize = 0;
    while (i + 8 <= dst.len) : (i += 8) {
        const d: V = dst[i..][0..8].*;
        const s: V = src[i..][0..8].*;
        dst[i..][0..8].* = d + s * g;
    }
    while (i < dst.len) : (i += 1) dst[i] += src[i] * gain;
}

/// Linear below clip_threshold. Above it: sign * (t + (1 - t) * tanh((|x| - t) / (1 - t))).
pub fn softClip(buf: []f32) void {
    const t = clip_threshold;
    const knee = 1 - t;
    for (buf) |*x| {
        const a = @abs(x.*);
        if (a <= t) continue;
        const shaped = t + knee * std.math.tanh((a - t) / knee);
        x.* = std.math.copysign(shaped, x.*);
    }
}

test "accumulate adds the scaled source, tail included" {
    var dst: [19]f32 = @splat(1);
    var src: [19]f32 = undefined;
    for (&src, 0..) |*v, i| v.* = @floatFromInt(i);
    accumulate(&dst, &src, 0.5);
    for (dst, 0..) |v, i| try std.testing.expectEqual(1 + @as(f32, @floatFromInt(i)) * 0.5, v);
}

test "soft clip leaves quiet samples alone" {
    var buf = [_]f32{ 0.5, -0.5, 0.9 };
    softClip(&buf);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, -0.5, 0.9 }, &buf);
}

test "soft clip never goes above full scale and keeps the sign" {
    var buf = [_]f32{ 10, -10, 1.0 };
    softClip(&buf);
    try std.testing.expect(buf[0] <= 1 and buf[0] > 0.99);
    try std.testing.expectEqual(-buf[0], buf[1]);
    try std.testing.expect(buf[2] > 0.9 and buf[2] < buf[0]);
}
