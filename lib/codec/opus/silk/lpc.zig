//! LPC code ported from libopus silk/NLSF2A.c, LPC_fit.c, LPC_inv_pred_gain.c and bwexpander.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const m = @import("macros.zig");
const tables = @import("tables.zig");

pub const max_order = 16;

const qa = 16;
const max_stabilize_iterations = 16;

/// Chirp for an `i32` filter.
pub fn bwexpander32(ar: []i32, chirp_in: i32) void {
    var chirp = chirp_in;
    const cm1 = chirp -% 65536;
    for (ar[0 .. ar.len - 1]) |*a| {
        a.* = m.smulww(chirp, a.*);
        chirp +%= m.rshiftRound(chirp *% cm1, 16);
    }
    const last = &ar[ar.len - 1];
    last.* = m.smulww(chirp, last.*);
}

/// Chirp for an `i16` filter.
pub fn bwexpander(ar: []i16, chirp_in: i32) void {
    var chirp = chirp_in;
    const cm1 = chirp -% 65536;
    for (ar[0 .. ar.len - 1]) |*a| {
        a.* = m.trunc16(m.rshiftRound(chirp *% a.*, 16));
        chirp +%= m.rshiftRound(chirp *% cm1, 16);
    }
    const last = &ar[ar.len - 1];
    last.* = m.trunc16(m.rshiftRound(chirp *% last.*, 16));
}

/// Limits the Q17 coefficients so that they fit in Q12 `i16`.
fn lpcFit(out: []i16, a_qin: []i32) void {
    const qin_qout = 5;
    var idx: usize = 0;
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        var maxabs: i32 = 0;
        for (a_qin, 0..) |v, k| {
            const absval = if (v < 0) 0 -| v else v;
            if (absval > maxabs) {
                maxabs = absval;
                idx = k;
            }
        }
        maxabs = m.rshiftRound(maxabs, qin_qout);
        if (maxabs <= std.math.maxInt(i16)) break;
        maxabs = @min(maxabs, 163838);
        const num = (maxabs - std.math.maxInt(i16)) << 14;
        const den = (maxabs *% @as(i32, @intCast(idx + 1))) >> 2;
        const chirp = 65470 - m.div32(num, den);
        bwexpander32(a_qin, chirp);
    }
    if (i == 10) {
        for (a_qin, out) |*v, *o| {
            o.* = @intCast(m.sat16(m.rshiftRound(v.*, qin_qout)));
            v.* = @as(i32, o.*) << qin_qout;
        }
    } else {
        for (a_qin, out) |v, *o| o.* = m.trunc16(m.rshiftRound(v, qin_qout));
    }
}

fn mulFracQ(a: i32, b: i32, q: u6) i32 {
    return @truncate(m.rshiftRound64(m.smull(a, b), q));
}

/// Inverse prediction gain in Q30, or 0 when the filter is unstable.
pub fn inversePredGain(a_q12: []const i16) i32 {
    const a_limit = 16773022;
    var a: [max_order]i32 = undefined;
    const order = a_q12.len;
    var dc: i32 = 0;
    for (a_q12, 0..) |v, k| {
        dc += v;
        a[k] = @as(i32, v) << 12;
    }
    if (dc >= 4096) return 0;
    var inv_gain: i32 = 1 << 30;
    var k: usize = order - 1;
    while (k > 0) : (k -= 1) {
        if (a[k] > a_limit or a[k] < -a_limit) return 0;
        const rc_q31 = -(a[k] << 7);
        const rc_mult1 = (@as(i32, 1) << 30) -% m.smmul(rc_q31, rc_q31);
        inv_gain = m.smmul(inv_gain, rc_mult1) << 2;
        if (inv_gain < 107374) return 0;
        const mult2q: u6 = @intCast(32 - m.clz(if (rc_mult1 < 0) 0 -| rc_mult1 else rc_mult1));
        const rc_mult2 = m.inverse32VarQ(rc_mult1, @as(i32, mult2q) + 30);
        for (0..(k + 1) >> 1) |n| {
            const tmp1 = a[n];
            const tmp2 = a[k - n - 1];
            const x = m.rshiftRound64(m.smull(m.subSat32(tmp1, mulFracQ(tmp2, rc_q31, 31)), rc_mult2), mult2q);
            if (x > std.math.maxInt(i32) or x < std.math.minInt(i32)) return 0;
            a[n] = @intCast(x);
            const y = m.rshiftRound64(m.smull(m.subSat32(tmp2, mulFracQ(tmp1, rc_q31, 31)), rc_mult2), mult2q);
            if (y > std.math.maxInt(i32) or y < std.math.minInt(i32)) return 0;
            a[k - n - 1] = @intCast(y);
        }
    }
    if (a[0] > a_limit or a[0] < -a_limit) return 0;
    const rc_q31 = -(a[0] << 7);
    const rc_mult1 = (@as(i32, 1) << 30) -% m.smmul(rc_q31, rc_q31);
    inv_gain = m.smmul(inv_gain, rc_mult1) << 2;
    if (inv_gain < 107374) return 0;
    return inv_gain;
}

fn findPoly(out: []i32, c_lsf: []const i32, start: usize, dd: usize) void {
    out[0] = 1 << qa;
    out[1] = -c_lsf[start];
    for (1..dd) |k| {
        const f = c_lsf[start + 2 * k];
        out[k + 1] = (out[k - 1] << 1) -% @as(i32, @truncate(m.rshiftRound64(m.smull(f, out[k]), qa)));
        var n = k;
        while (n > 1) : (n -= 1) {
            out[n] +%= out[n - 2] -% @as(i32, @truncate(m.rshiftRound64(m.smull(f, out[n - 1]), qa)));
        }
        out[1] -%= f;
    }
}

const ordering16 = [16]u8{ 0, 15, 8, 7, 4, 11, 12, 3, 2, 13, 10, 5, 6, 9, 14, 1 };
const ordering10 = [10]u8{ 0, 9, 6, 3, 4, 5, 8, 1, 2, 7 };

/// Converts NLSF values in Q15 to LPC coefficients in Q12. The order is 10 or 16.
pub fn nlsf2a(a_q12: []i16, nlsf: []const i16) void {
    const d = nlsf.len;
    std.debug.assert(d == 10 or d == 16);
    const ordering: []const u8 = if (d == 16) &ordering16 else &ordering10;
    var cos_lsf: [max_order]i32 = undefined;
    for (nlsf, 0..) |v, k| {
        const f_int: usize = @intCast(std.math.clamp(@as(i32, v) >> 8, 0, 127));
        const f_frac = @as(i32, v) - (@as(i32, @intCast(f_int)) << 8);
        const cos_val: i32 = tables.lsf_cos_tab_fix_q12[f_int];
        const delta = @as(i32, tables.lsf_cos_tab_fix_q12[f_int + 1]) - cos_val;
        cos_lsf[ordering[k]] = m.rshiftRound((cos_val << 8) +% delta *% f_frac, 20 - qa);
    }
    const dd = d >> 1;
    var p: [max_order / 2 + 1]i32 = undefined;
    var q: [max_order / 2 + 1]i32 = undefined;
    findPoly(&p, cos_lsf[0..d], 0, dd);
    findPoly(&q, cos_lsf[0..d], 1, dd);
    var a32: [max_order]i32 = undefined;
    for (0..dd) |k| {
        const ptmp = p[k + 1] +% p[k];
        const qtmp = q[k + 1] -% q[k];
        a32[k] = 0 -% qtmp -% ptmp;
        a32[d - k - 1] = qtmp -% ptmp;
    }
    lpcFit(a_q12[0..d], a32[0..d]);
    var i: u5 = 0;
    while (inversePredGain(a_q12[0..d]) == 0 and i < max_stabilize_iterations) : (i += 1) {
        bwexpander32(a32[0..d], 65536 - (@as(i32, 2) << i));
        for (a32[0..d], a_q12[0..d]) |v, *o| o.* = m.trunc16(m.rshiftRound(v, qa + 1 - 12));
    }
}

/// Whitens `input` with the Q12 filter `b`. The first `b.len` outputs are zero.
/// `input[ix]` is the sample that `output[ix]` replaces and `input` holds `b.len` earlier samples.
pub fn analysisFilter(output: []i16, input: []const i16, b: []const i16) void {
    const d = b.len;
    const len = output.len;
    for (output[0..d]) |*o| o.* = 0;
    for (d..len) |ix| {
        var acc = m.smulbb(input[ix - 1], b[0]);
        for (1..d) |j| acc = m.smlabb(acc, input[ix - 1 - j], b[j]);
        acc = (@as(i32, input[ix]) << 12) -% acc;
        output[ix] = @intCast(m.sat16(m.rshiftRound(acc, 12)));
    }
}

const testing = std.testing;
const test_util = @import("../test_util.zig");

const Xs = test_util.Xorshift;
const fnv = test_util.fnv;

test "bandwidth expansion gives the libopus taps" {
    var a32 = [_]i32{ 4096, 4096, 4096, 4096 };
    bwexpander32(&a32, 62259);
    try testing.expectEqualSlices(i32, &.{ 3891, 3696, 3511, 3336 }, &a32);
    var a16 = [_]i16{ 4095, -4097, 4096, 12345 };
    bwexpander(&a16, 62259);
    try testing.expectEqualSlices(i16, &.{ 3890, -3698, 3512, 10055 }, &a16);
}

test "nlsf2a and the stability check give the libopus values" {
    var rng: Xs = .{};
    var h: u32 = 2166136261;
    var hg: u32 = 2166136261;
    for (0..2000) |t| {
        const d: usize = if (t & 1 == 1) 16 else 10;
        var nlsf: [16]i16 = undefined;
        var acc: i32 = 0;
        const spread: u32 = if (t % 5 == 0) 200 else if (t % 7 == 0) 1500 else 3000;
        for (nlsf[0..d]) |*v| {
            acc += @intCast(1 + rng.next() % spread);
            acc = @min(acc, 32767);
            v.* = @intCast(acc);
        }
        var a: [16]i16 = undefined;
        nlsf2a(a[0..d], nlsf[0..d]);
        for (a[0..d]) |v| h = fnv(h, @as(u16, @bitCast(v)));
        const g = inversePredGain(a[0..d]);
        hg = fnv(hg, @bitCast(g));
        if (t == 3) {
            try testing.expectEqualSlices(i16, &.{ 14755, -26522, 32744, -31801, 25857, -18051, 10926, -5759, 2636, -1033, 335, -84, 14, -1, 0, 0 }, &a);
            try testing.expectEqual(@as(i32, 3601772), g);
        }
        if (t == 4) {
            try testing.expectEqualSlices(i16, &.{ 16127, -29410, 32734, -24645, 13121, -5004, 1350, -246, 27, -1 }, a[0..10]);
            try testing.expectEqual(@as(i32, 1041432), g);
        }
    }
    try testing.expectEqual(@as(u32, 755768294), h);
    try testing.expectEqual(@as(u32, 1438922053), hg);
}

test "the analysis filter gives the libopus residual" {
    var rng: Xs = .{};
    // Skip the draws that the C harness spent on the nlsf vectors.
    var skip: usize = 0;
    var s2: Xs = .{};
    for (0..2000) |t| {
        const d: usize = if (t & 1 == 1) 16 else 10;
        const spread: u32 = if (t % 5 == 0) 200 else if (t % 7 == 0) 1500 else 3000;
        var acc: i32 = 0;
        for (0..d) |_| {
            acc += @intCast(1 + s2.next() % spread);
            acc = @min(acc, 32767);
            skip += 1;
        }
    }
    for (0..skip) |_| _ = rng.next();
    var in: [100]i16 = undefined;
    var b: [16]i16 = undefined;
    for (&in) |*v| v.* = @intCast(@as(i32, @intCast(rng.next() % 20000)) - 10000);
    for (&b) |*v| v.* = @intCast(@as(i32, @intCast(rng.next() % 8000)) - 4000);
    try testing.expectEqual(@as(i16, -2257), in[0]);
    var out: [100]i16 = undefined;
    analysisFilter(&out, &in, &b);
    var h: u32 = 2166136261;
    for (out) |v| h = fnv(h, @as(u16, @bitCast(v)));
    try testing.expectEqual(@as(u32, 2140550014), h);
    try testing.expectEqual(@as(i16, 8755), out[40]);
    try testing.expectEqual(@as(i16, 1820), out[99]);
    analysisFilter(&out, &in, b[0..10]);
    h = 2166136261;
    for (out) |v| h = fnv(h, @as(u16, @bitCast(v)));
    try testing.expectEqual(@as(u32, 2525442469), h);
}
