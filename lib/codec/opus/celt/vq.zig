//! CELT pulse vector coding and normalisation, ported from libopus celt/vq.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const range = @import("../range.zig");
const cwrs = @import("cwrs.zig");

pub const Spread = enum(u2) { none = 0, light = 1, normal = 2, aggressive = 3 };

/// The most dimensions of one pulse vector. This is the widest band at LM 3.
pub const max_dim = 176;

fn cosNorm(x: f32) f32 {
    return @floatCast(@cos((0.5 * std.math.pi) * @as(f64, x)));
}

fn rotate1(x: []f32, stride: usize, c: f32, s: f32) void {
    const len = x.len;
    const ms = -s;
    var i: usize = 0;
    while (i + stride < len) : (i += 1) {
        const x1 = x[i];
        const x2 = x[i + stride];
        x[i + stride] = c * x2 + s * x1;
        x[i] = c * x1 + ms * x2;
    }
    if (len < 2 * stride + 1) return;
    i = len - 2 * stride - 1;
    while (true) {
        const x1 = x[i];
        const x2 = x[i + stride];
        x[i + stride] = c * x2 + s * x1;
        x[i] = c * x1 + ms * x2;
        if (i == 0) break;
        i -= 1;
    }
}

/// Rotates blocks of `x` against each other to spread the pulses (exp_rotation).
/// `dir` is -1 when decoding.
pub fn expRotation(x: []f32, dir: i32, stride: usize, k: u32, spread: Spread) void {
    const len = x.len;
    if (2 * k >= len or spread == .none) return;
    const factors = [3]u32{ 15, 10, 5 };
    const factor = factors[@backingInt(spread) - 1];
    const gain: f32 = @as(f32, @floatFromInt(len)) / @as(f32, @floatFromInt(len + factor * k));
    const theta: f32 = 0.5 * (gain * gain);
    const c = cosNorm(theta);
    const s = cosNorm(1.0 - theta);
    var stride2: usize = 0;
    if (len >= 8 * stride) {
        stride2 = 1;
        while ((stride2 * stride2 + stride2) * stride + (stride >> 2) < len) stride2 += 1;
    }
    const block = len / stride;
    for (0..stride) |i| {
        const b = x[i * block ..][0..block];
        if (dir < 0) {
            if (stride2 != 0) rotate1(b, stride2, s, c);
            rotate1(b, 1, c, s);
        } else {
            rotate1(b, 1, c, -s);
            if (stride2 != 0) rotate1(b, stride2, s, -c);
        }
    }
}

/// Scales `x` to the norm `gain` (renormalise_vector).
pub fn renormaliseVector(x: []f32, gain: f32) void {
    var sum: f32 = 0;
    for (x) |v| sum += v * v;
    const e: f32 = 1e-15 + sum;
    const g: f32 = (1.0 / @sqrt(e)) * gain;
    for (x) |*v| v.* = g * v.*;
}

fn collapseMask(iy: []const i32, b: u32) u32 {
    if (b <= 1) return 1;
    const n0 = iy.len / b;
    var mask: u32 = 0;
    for (0..b) |i| {
        var tmp: i32 = 0;
        for (iy[i * n0 ..][0..n0]) |v| tmp |= v;
        if (tmp != 0) mask |= @as(u32, 1) << @intCast(i);
    }
    return mask;
}

/// Reads a pulse vector of `x.len` dimensions and `k` pulses, scales it to the norm `gain` and
/// spreads it. Returns the collapse mask of the `b` blocks (alg_unquant).
pub fn algUnquant(x: []f32, k: u32, spread: Spread, b: u32, dec: *range.Decoder, gain: f32) cwrs.Error!u32 {
    std.debug.assert(k > 0 and x.len > 1 and x.len <= max_dim);
    var iy: [max_dim]i32 = undefined;
    const y = iy[0..x.len];
    const yy = try cwrs.decode(dec, y, k);
    const g: f32 = (1.0 / @sqrt(@as(f32, @floatFromInt(yy)))) * gain;
    for (x, y) |*o, v| o.* = @as(f32, @floatFromInt(v)) * g;
    expRotation(x, -1, b, k, spread);
    return collapseMask(y, b);
}

/// Turns a float into an integer, with NaN as 0 and values beyond the range clamped.
pub fn floorInt(v: f64) i32 {
    if (!(v == v)) return 0;
    return @intFromFloat(std.math.clamp(@floor(v), -2.0e9, 2.0e9));
}

/// atan(x) * 2/pi for x from 0 to 1.
fn atanNorm(x: f32) f32 {
    const x_sq = x * x;
    return 0.636619772367581 * (x + x * x_sq * (-3.3331659436225891113281250000e-01 +
        x_sq * (1.99627041816711425781250000000e-01 +
            x_sq * (-1.3976582884788513183593750000e-01 +
                x_sq * (9.79423448443412780761718750000e-02 +
                    x_sq * (-5.7773590087890625000000000000e-02 +
                        x_sq * (2.30401363223791122436523437500e-02 +
                            x_sq * (-4.3554059229791164398193359375e-03))))))));
}

fn atan2pNorm(y: f32, x: f32) f32 {
    if (x * x + y * y < 1e-18) return 0;
    if (y < x) return atanNorm(y / x);
    return 1.0 - atanNorm(x / y);
}

/// The angle between the mid and the side of two vectors, from 0 for mid only to 2^30 for
/// side only (stereo_itheta). With `stereo` the vectors are left and right, else they are the
/// mid and the side.
pub fn stereoItheta(x: []const f32, y: []const f32, stereo: bool) i32 {
    var emid: f32 = 0;
    var eside: f32 = 0;
    if (stereo) {
        for (x, y) |a, b| {
            const m = a + b;
            const s = a - b;
            emid += m * m;
            eside += s * s;
        }
    } else {
        for (x, y) |a, b| {
            emid += a * a;
            eside += b * b;
        }
    }
    const mid = @sqrt(emid);
    const side = @sqrt(eside);
    return floorInt(0.5 + 65536.0 * 16384.0 * atan2pNorm(side, mid));
}

/// Finds the integer vector `iy` of `k` pulses that is closest in direction to `x` (op_pvq_search).
/// `x` holds its absolute values afterwards.
fn pvqSearch(x: []f32, iy: []i32, k: u32) void {
    const n = x.len;
    var y: [max_dim]f32 = undefined;
    var signx: [max_dim]bool = undefined;
    for (x, 0..) |*v, j| {
        signx[j] = v.* < 0;
        v.* = @abs(v.*);
        iy[j] = 0;
        y[j] = 0;
    }
    var xy: f32 = 0;
    var yy: f32 = 0;
    var pulses_left: i32 = @intCast(k);
    if (k > n >> 1) {
        var sum: f32 = 0;
        for (x) |v| sum += v;
        if (!(sum > 1e-15 and sum < 64)) {
            x[0] = 1.0;
            @memset(x[1..], 0);
            sum = 1.0;
        }
        const rcp = (@as(f32, @floatFromInt(k)) + 0.8) * (1.0 / sum);
        for (0..n) |j| {
            iy[j] = floorInt(rcp * x[j]);
            y[j] = @floatFromInt(iy[j]);
            yy += y[j] * y[j];
            xy += x[j] * y[j];
            y[j] *= 2;
            pulses_left -= iy[j];
        }
    }
    if (pulses_left > @as(i32, @intCast(n)) + 3) {
        const tmp: f32 = @floatFromInt(pulses_left);
        yy += tmp * tmp;
        yy += tmp * y[0];
        iy[0] += pulses_left;
        pulses_left = 0;
    }
    var i: i32 = 0;
    while (i < pulses_left) : (i += 1) {
        var best_id: usize = 0;
        yy += 1;
        var rxy = xy + x[0];
        var ryy = yy + y[0];
        rxy = rxy * rxy;
        var best_den = ryy;
        var best_num = rxy;
        for (1..n) |j| {
            rxy = xy + x[j];
            ryy = yy + y[j];
            rxy = rxy * rxy;
            if (best_den * rxy > ryy * best_num) {
                best_den = ryy;
                best_num = rxy;
                best_id = j;
            }
        }
        xy += x[best_id];
        yy += y[best_id];
        y[best_id] += 2;
        iy[best_id] += 1;
    }
    for (iy[0..n], signx[0..n]) |*v, s| {
        if (s) v.* = -v.*;
    }
}

/// Writes a pulse vector of `k` pulses for `x`, which the call spreads and rounds (alg_quant).
/// Returns the collapse mask of the `b` blocks.
pub fn algQuant(x: []f32, k: u32, spread: Spread, b: u32, enc: *range.Encoder) u32 {
    std.debug.assert(k > 0 and x.len > 1 and x.len <= max_dim);
    expRotation(x, 1, b, k, spread);
    var iy: [max_dim]i32 = undefined;
    const y = iy[0..x.len];
    pvqSearch(x, y, k);
    cwrs.encode(enc, y, k);
    return collapseMask(y, b);
}

const testing = std.testing;

test "renormalise gives the requested norm" {
    var x = [_]f32{ 3, 4, 0, 12 };
    renormaliseVector(&x, 2.0);
    var e: f32 = 0;
    for (x) |v| e += v * v;
    try testing.expectApproxEqAbs(@as(f32, 4.0), e, 1e-5);
}

test "rotation keeps the norm" {
    var x: [32]f32 = undefined;
    for (&x, 0..) |*v, i| v.* = @floatFromInt(i % 5);
    var y = x;
    expRotation(&y, -1, 1, 2, .normal);
    var e0: f32 = 0;
    var e1: f32 = 0;
    for (x, y) |a, b| {
        e0 += a * a;
        e1 += b * b;
    }
    try testing.expectApproxEqAbs(e0, e1, 1e-3);
}

test "collapse mask marks blocks with pulses" {
    const iy = [_]i32{ 0, 0, 1, 0, 0, 0, 0, -2 };
    try testing.expectEqual(@as(u32, 0b1010), collapseMask(&iy, 4));
    try testing.expectEqual(@as(u32, 1), collapseMask(&iy, 1));
}

test "alg unquant makes a unit vector" {
    var buf = [_]u8{ 0x5A, 0x33, 0x91, 0xC4, 0x07, 0x68, 0xEE, 0x12 };
    var dec = range.Decoder.init(&buf);
    var x: [8]f32 = undefined;
    const m = try algUnquant(&x, 3, .normal, 1, &dec, 1.0);
    try testing.expectEqual(@as(u32, 1), m);
    var e: f32 = 0;
    for (x) |v| e += v * v;
    try testing.expectApproxEqAbs(@as(f32, 1.0), e, 1e-5);
}

test "the stereo angle runs from mid only to side only" {
    const one = [_]f32{ 1, 1 };
    const zero = [_]f32{ 0, 0 };
    try testing.expectEqual(@as(i32, 0), stereoItheta(&one, &zero, false));
    try testing.expectEqual(@as(i32, 1 << 30), stereoItheta(&zero, &one, false));
    try testing.expectEqual(@as(i32, 0), stereoItheta(&zero, &zero, false));
    // Equal energy is a quarter turn, which is 2^29 and the polynomial misses it by a few units.
    try testing.expectApproxEqAbs(@as(f32, 1 << 29), @as(f32, @floatFromInt(stereoItheta(&one, &one, false))), 256);
    // Left and right: the same signal in both is mid only.
    try testing.expectEqual(@as(i32, 0), stereoItheta(&one, &one, true));
    const neg = [_]f32{ -1, -1 };
    try testing.expectEqual(@as(i32, 1 << 30), stereoItheta(&one, &neg, true));
}

test "pvq search gives k pulses along the vector" {
    var rng: @import("../test_util.zig").Xorshift = .{ .s = 21 };
    for (0..200) |_| {
        const n: usize = 2 + rng.next() % 40;
        const k: u32 = @intCast(n + rng.next() % 30);
        var x: [max_dim]f32 = undefined;
        for (x[0..n]) |*v| v.* = @as(f32, @floatFromInt(@as(i32, @bitCast(rng.next())) >> 8)) / 8388608.0;
        renormaliseVector(x[0..n], 1.0);
        var iy: [max_dim]i32 = undefined;
        var abs = x;
        pvqSearch(abs[0..n], iy[0..n], k);
        var pulses: u32 = 0;
        var dot_xy: f32 = 0;
        var yy: f32 = 0;
        for (x[0..n], iy[0..n]) |a, p| {
            pulses += @abs(p);
            if (p != 0) try testing.expect((a < 0) == (p < 0));
            dot_xy += a * @as(f32, @floatFromInt(p));
            yy += @as(f32, @floatFromInt(p)) * @as(f32, @floatFromInt(p));
        }
        try testing.expectEqual(k, pulses);
        // With at least one pulse for each dimension the pulses point in about the direction of the vector.
        try testing.expect(dot_xy / @sqrt(yy) > 0.9);
    }
}

test "alg quant and alg unquant agree on the pulses" {
    var rng: @import("../test_util.zig").Xorshift = .{ .s = 8 };
    for (0..100) |_| {
        const n: usize = 4 + rng.next() % 30;
        const k: u32 = @intCast(n + rng.next() % 12);
        if (!cwrs.inDomain(@intCast(n), k)) continue;
        const blocks: u32 = if (n % 4 == 0 and rng.next() % 2 == 0) 4 else 1;
        const spread: Spread = @fromBackingInt(@intCast(rng.next() % 4));
        var x: [max_dim]f32 = undefined;
        for (x[0..n]) |*v| v.* = @as(f32, @floatFromInt(@as(i32, @bitCast(rng.next())) >> 8)) / 8388608.0;
        renormaliseVector(x[0..n], 1.0);
        var buf: [64]u8 = undefined;
        var enc = range.Encoder.init(&buf);
        var work = x;
        const mask_enc = algQuant(work[0..n], k, spread, blocks, &enc);
        enc.done();
        var dec = range.Decoder.init(&buf);
        var out: [max_dim]f32 = undefined;
        const mask_dec = try algUnquant(out[0..n], k, spread, blocks, &dec, 1.0);
        try testing.expectEqual(mask_enc, mask_dec);
        var dot_xy: f32 = 0;
        for (x[0..n], out[0..n]) |a, b| dot_xy += a * b;
        try testing.expect(dot_xy > 0.8);
    }
}
