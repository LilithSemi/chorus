//! Fixed point macros ported from libopus silk/macros.h, SigProc_FIX.h and Inlines.h.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");

fn lo16(a: i32) i32 {
    return @as(i16, @truncate(a));
}

/// Product of the low 16 bits of both operands.
pub fn smulbb(a: i32, b: i32) i32 {
    return lo16(a) * lo16(b);
}

pub fn smlabb(a: i32, b: i32, c: i32) i32 {
    return a +% smulbb(b, c);
}

/// `(a * low16(b)) >> 16`.
pub fn smulwb(a: i32, b: i32) i32 {
    return @truncate((@as(i64, a) * lo16(b)) >> 16);
}

pub fn smlawb(a: i32, b: i32, c: i32) i32 {
    return a +% smulwb(b, c);
}

/// `(a * b) >> 16`, cut to 32 bits as the C cast does.
pub fn smulww(a: i32, b: i32) i32 {
    return @truncate((@as(i64, a) * b) >> 16);
}

pub fn smlaww(a: i32, b: i32, c: i32) i32 {
    return a +% smulww(b, c);
}

/// `(a * b) >> 32`.
pub fn smmul(a: i32, b: i32) i32 {
    return @truncate((@as(i64, a) * b) >> 32);
}

pub fn smull(a: i32, b: i32) i64 {
    return @as(i64, a) * b;
}

/// Shift right and round to nearest. `s` is at least 1.
pub fn rshiftRound(a: i32, s: u5) i32 {
    std.debug.assert(s >= 1);
    if (s == 1) return (a >> 1) + (a & 1);
    return ((a >> (s - 1)) + 1) >> 1;
}

pub fn rshiftRound64(a: i64, s: u6) i64 {
    std.debug.assert(s >= 1);
    if (s == 1) return (a >> 1) + (a & 1);
    return ((a >> (s - 1)) +% 1) >> 1;
}

pub fn sat16(a: i32) i32 {
    return std.math.clamp(a, -32768, 32767);
}

/// Cut to 16 bits the way a C cast to `opus_int16` does.
pub fn trunc16(a: i32) i16 {
    return @truncate(a);
}

pub fn addSat16(a: i16, b: i16) i16 {
    return @intCast(sat16(@as(i32, a) + b));
}

pub fn addSat32(a: i32, b: i32) i32 {
    return a +| b;
}

pub fn subSat32(a: i32, b: i32) i32 {
    return a -| b;
}

/// Clamp that accepts swapped bounds, as the C macro does.
pub fn limit(a: i32, l1: i32, l2: i32) i32 {
    return if (l1 > l2)
        @max(l2, @min(l1, a))
    else
        @max(l1, @min(l2, a));
}

/// `limit(a, MIN >> s, MAX >> s) << s`.
pub fn lshiftSat32(a: i32, s: u5) i32 {
    const lo = @as(i32, std.math.minInt(i32)) >> s;
    const hi = @as(i32, std.math.maxInt(i32)) >> s;
    return limit(a, lo, hi) << s;
}

/// C division of a 32 bit value, with 0 for a zero divisor and the C wrap for the one overflow.
pub fn div32(a: i32, b: i32) i32 {
    if (b == 0) return 0;
    if (b == -1) return 0 -% a;
    return @divTrunc(a, b);
}

pub fn clz(a: i32) i32 {
    return @clz(@as(u32, @bitCast(a)));
}

fn absSat(a: i32) i32 {
    return if (a < 0) 0 -| a else a;
}

/// Approximates `(a << q) / b`. Both operands must be non zero.
pub fn div32VarQ(a: i32, b: i32, q: i32) i32 {
    const a_headrm = clz(absSat(a)) - 1;
    var a_nrm = a << @intCast(a_headrm & 31);
    const b_headrm = clz(absSat(b)) - 1;
    const b_nrm = b << @intCast(b_headrm & 31);
    const b_inv = div32(std.math.maxInt(i32) >> 2, b_nrm >> 16);
    var result = smulwb(a_nrm, b_inv);
    a_nrm = a_nrm -% (smmul(b_nrm, result) << 3);
    result = smlawb(result, a_nrm, b_inv);
    const lshift = 29 + a_headrm - b_headrm - q;
    if (lshift < 0) return lshiftSat32(result, @intCast(@min(-lshift, 31)));
    if (lshift < 32) return result >> @intCast(lshift);
    return 0;
}

/// Approximates `(1 << q) / b`. `b` must be non zero.
pub fn inverse32VarQ(b: i32, q: i32) i32 {
    const b_headrm = clz(absSat(b)) - 1;
    const b_nrm = b << @intCast(b_headrm & 31);
    const b_inv = div32(std.math.maxInt(i32) >> 2, b_nrm >> 16);
    var result = b_inv << 16;
    const err_q32 = ((@as(i32, 1) << 29) -% smulwb(b_nrm, b_inv)) << 3;
    result = smlaww(result, err_q32, b_inv);
    const lshift = 61 - b_headrm - q;
    if (lshift <= 0) return lshiftSat32(result, @intCast(@min(-lshift, 31)));
    if (lshift < 32) return result >> @intCast(lshift);
    return 0;
}

/// The next value of the linear congruential generator.
pub fn rand(seed: i32) i32 {
    return 907633515 +% seed *% 196314165;
}

/// `2^(x / 128)` with a piece wise parabolic fit. `x` is Q7.
pub fn log2lin(x: i32) i32 {
    if (x < 0) return 0;
    if (x >= 3967) return std.math.maxInt(i32);
    var out: i32 = @as(i32, 1) << @intCast(x >> 7);
    const frac = x & 0x7F;
    const t = smlawb(frac, smulbb(frac, 128 - frac), -174);
    if (x < 2048) {
        out = out +% ((out *% t) >> 7);
    } else {
        out = out +% (out >> 7) *% t;
    }
    return out;
}

/// `(a * (b >> 16)) >> 16`.
pub fn smulwt(a: i32, b: i32) i32 {
    return @truncate((@as(i64, a) * (b >> 16)) >> 16);
}

pub fn smlawt(a: i32, b: i32, c: i32) i32 {
    return a +% smulwt(b, c);
}

pub fn addPosSat32(a: i32, b: i32) i32 {
    const sum = @as(u32, @bitCast(a)) +% @as(u32, @bitCast(b));
    return if (sum & 0x80000000 != 0) std.math.maxInt(i32) else a +% b;
}

fn rotateRight32(a: i32, rot: i32) i32 {
    const x: u32 = @bitCast(a);
    if (rot == 0) return a;
    if (rot < 0) {
        const r: u5 = @intCast(-rot);
        return @bitCast((x << r) | (x >> @intCast(32 - @as(i32, r))));
    }
    const r: u5 = @intCast(rot);
    return @bitCast((x << @intCast(32 - @as(i32, r))) | (x >> r));
}

/// The number of leading zeros and the 7 bits after the leading one.
fn clzFrac(in: i32) struct { lz: i32, frac_q7: i32 } {
    const lz = clz(in);
    return .{ .lz = lz, .frac_q7 = rotateRight32(in, 24 - lz) & 0x7f };
}

/// `128 * log2(x)` with a piece wise parabolic fit, the inverse of `log2lin`.
pub fn lin2log(in: i32) i32 {
    const cf = clzFrac(in);
    const t = smlawb(cf.frac_q7, cf.frac_q7 * (128 - cf.frac_q7), 179);
    return t +% ((31 - cf.lz) << 7);
}

/// Square root with an error below 10 percent for results above 15.
pub fn sqrtApprox(x: i32) i32 {
    if (x <= 0) return 0;
    const cf = clzFrac(x);
    var y: i32 = if (cf.lz & 1 != 0) 32768 else 46214;
    y >>= @intCast(cf.lz >> 1);
    return smlawb(y, y, smulbb(213, cf.frac_q7));
}

pub const Energy = struct { energy: i32, shift: i32 };

/// The energy of `x` shifted right so that it fits in 30 bits (silk_sum_sqr_shift).
pub fn sumSqrShift(x: []const i16) Energy {
    const len: i32 = @intCast(x.len);
    var shift = 31 - clz(len);
    var nrg: u32 = @intCast(len);
    nrg = accumulate(nrg, x, @intCast(shift));
    shift = @max(0, shift + 3 - clz(@bitCast(nrg)));
    nrg = accumulate(0, x, @intCast(shift));
    return .{ .energy = @bitCast(nrg), .shift = shift };
}

fn accumulate(start: u32, x: []const i16, shift: u5) u32 {
    var nrg = start;
    var i: usize = 0;
    while (i + 1 < x.len) : (i += 2) {
        const a: u32 = @bitCast(smulbb(x[i], x[i]));
        const b: u32 = @bitCast(smulbb(x[i + 1], x[i + 1]));
        nrg +%= (a +% b) >> shift;
    }
    if (i < x.len) {
        const a: u32 = @bitCast(smulbb(x[i], x[i]));
        nrg +%= a >> shift;
    }
    return nrg;
}

const testing = std.testing;
const test_util = @import("../test_util.zig");

test "lin2log inverts log2lin and the square root approximation is close" {
    try testing.expectEqual(@as(i32, 0), lin2log(1));
    try testing.expectEqual(@as(i32, 7 * 128), lin2log(128));
    var x: i32 = 1;
    while (x < 1 << 30) : (x = x * 3 + 1) {
        const back = log2lin(lin2log(x));
        const diff = @abs(back - x);
        try testing.expect(diff <= @divTrunc(x, 16) + 1);
    }
    try testing.expectEqual(@as(i32, 0), sqrtApprox(0));
    try testing.expect(@abs(sqrtApprox(1 << 20) - 1024) < 40);
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), addPosSat32(std.math.maxInt(i32), 5));
}

test "16 bit operand macros cut their operands like the C casts" {
    try testing.expectEqual(@as(i32, 100 * -200), smulbb(100, -200));
    // 0x12345 holds 0x2345 in its low 16 bits.
    try testing.expectEqual(@as(i32, 0x2345 * 3), smulbb(0x12345, 3));
    try testing.expectEqual(@as(i32, -32768 * -32768), smulbb(-32768, 0x8000));
    try testing.expectEqual(@as(i32, 7 + 6), smlabb(7, 2, 3));
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), smlabb(std.math.maxInt(i32), 1, 1));
}

const probe = [_]i32{ 0, 1, -1, 12345, -12345, 0x12345, 2147483647, -2147483648, 1 << 30, -(1 << 30), 65536, -65536, 987654321, -123456789, 32768, -32768, 70000 };

fn fnv(h: u32, v: i32) u32 {
    return test_util.fnv(h, @bitCast(v));
}

test "word macros give the C results on edge values" {
    var h: [5]u32 = @splat(2166136261);
    for (probe) |x| {
        for (probe) |y| {
            h[0] = fnv(h[0], smulbb(x, y));
            h[1] = fnv(h[1], smulwb(x, y));
            h[2] = fnv(h[2], smulww(x, y));
            h[3] = fnv(h[3], smmul(x, y));
            h[4] = fnv(h[4], smlawb(x, y, x));
        }
    }
    // The hashes come from the libopus macros compiled with a C compiler.
    try testing.expectEqual(@as(u32, 2928991983), h[0]);
    try testing.expectEqual(@as(u32, 2869648644), h[1]);
    try testing.expectEqual(@as(u32, 2697245548), h[2]);
    try testing.expectEqual(@as(u32, 254889315), h[3]);
    try testing.expectEqual(@as(u32, 477460898), h[4]);
}

fn fnv64(h: u32, v: i64) u32 {
    return fnv(fnv(h, @truncate(v)), @truncate(v >> 32));
}

test "accumulate, saturating and 64 bit macros give the C results" {
    var h: [6]u32 = @splat(2166136261);
    for (probe) |x| {
        for (probe) |y| {
            var k: usize = 0;
            while (k < probe.len) : (k += 3) {
                h[0] = fnv(h[0], smlaww(x, y, probe[k]));
            }
            h[1] = fnv(h[1], addSat32(x, y));
            h[2] = fnv(h[2], subSat32(x, y));
            h[3] = fnv64(h[3], smull(x, y));
        }
    }
    for (probe, 0..) |x, i| {
        const y = probe[(i + 3) % probe.len];
        for (1..41) |s| {
            h[4] = fnv64(h[4], rshiftRound64(@as(i64, x) * y, @intCast(s)));
            h[5] = fnv64(h[5], rshiftRound64((@as(i64, x) << 20) * 977, @intCast(s)));
        }
    }
    // The hashes come from the libopus macros compiled with a C compiler.
    try testing.expectEqual(@as(u32, 4271078282), h[0]);
    try testing.expectEqual(@as(u32, 1101159001), h[1]);
    try testing.expectEqual(@as(u32, 4094092162), h[2]);
    try testing.expectEqual(@as(u32, 2499408153), h[3]);
    try testing.expectEqual(@as(u32, 2703444192), h[4]);
    try testing.expectEqual(@as(u32, 3723425310), h[5]);
}

test "division helpers and log2lin give the C results" {
    var h: [3]u32 = @splat(2166136261);
    for (probe) |x| {
        for (probe) |y| {
            if (x == 0 or y == 0 or x == std.math.minInt(i32) or y == std.math.minInt(i32)) continue;
            h[0] = fnv(h[0], div32VarQ(x, y, 16));
            h[1] = fnv(h[1], div32VarQ(x, y, 24));
            h[2] = fnv(h[2], inverse32VarQ(y, 47));
        }
    }
    try testing.expectEqual(@as(u32, 2906977024), h[0]);
    try testing.expectEqual(@as(u32, 795505834), h[1]);
    try testing.expectEqual(@as(u32, 749357142), h[2]);
    var g: u32 = 2166136261;
    var x: i32 = -5;
    while (x < 4000) : (x += 1) g = fnv(g, log2lin(x));
    try testing.expectEqual(@as(u32, 3602000145), g);
}

test "rounding shifts, saturating shifts and the generator give the C results" {
    try testing.expectEqual(@as(i32, -2), rshiftRound(-5, 1));
    try testing.expectEqual(@as(i32, -1), rshiftRound(-5, 2));
    try testing.expectEqual(@as(i32, 386), rshiftRound(12345, 5));
    try testing.expectEqual(@as(i64, 386), rshiftRound64(12345, 5));
    try testing.expectEqual(@as(i32, 2147483632), lshiftSat32(1000000000, 4));
    try testing.expectEqual(@as(i32, -2147483648), lshiftSat32(-1000000000, 4));
    try testing.expectEqual(@as(i32, 1586015428), rand(123456789));
}

test "limit accepts swapped bounds and the helpers never trap" {
    try testing.expectEqual(@as(i32, 7), limit(7, 10, 5));
    try testing.expectEqual(@as(i32, 10), limit(20, 10, 5));
    try testing.expectEqual(@as(i32, 5), limit(2, 10, 5));
    try testing.expectEqual(@as(i32, 7), limit(7, 5, 10));
    try testing.expectEqual(@as(i32, 0), div32(5, 0));
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), div32(std.math.minInt(i32), -1));
    try testing.expectEqual(@as(i32, -2), div32(-5, 2));
    try testing.expectEqual(@as(i32, 32767), addSat16(32767, 1));
    try testing.expectEqual(@as(i32, 0), div32VarQ(5, 0, 16));
    try testing.expectEqual(@as(i32, 0), inverse32VarQ(0, 47));
}
