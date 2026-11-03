//! Floating point signal processing of the SILK encoder, ported from libopus silk/float/.
//! libopus is BSD 3 clause, see LICENSE-libopus.
//! The C code mixes float and double arithmetic. Each expression here keeps the C types.
const std = @import("std");

/// The largest LPC order of the analysis functions.
pub const max_order_lpc = 24;

/// Rounds to the nearest integer, ties to even, like the SSE conversion. A value out of range
/// gives the smallest integer.
pub fn float2int(x: f32) i32 {
    if (!(x > -2147483648.0 and x < 2147483648.0)) return std.math.minInt(i32);
    const t = @trunc(x);
    const d = @abs(x - t);
    var r = t;
    if (d > 0.5) {
        r = t + std.math.copysign(@as(f32, 1.0), x);
    } else if (d == 0.5) {
        const half = t * 0.5;
        if (half != @trunc(half)) r = t + std.math.copysign(@as(f32, 1.0), x);
    }
    return @intFromFloat(r);
}

pub fn float2short(x: f32) i16 {
    return @intCast(std.math.clamp(float2int(x), -32768, 32767));
}

pub fn sigmoid(x: f32) f32 {
    return @floatCast(1.0 / (1.0 + @exp(-@as(f64, x))));
}

pub fn log2(x: f64) f32 {
    return @floatCast(3.32192809488736 * std.math.log10(x));
}

/// Sum of squares as double.
pub fn energy(data: []const f32) f64 {
    var result: f64 = 0;
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 4) {
        const a = @as(f64, data[i]) * data[i];
        const b = @as(f64, data[i + 1]) * data[i + 1];
        const c = @as(f64, data[i + 2]) * data[i + 2];
        const d = @as(f64, data[i + 3]) * data[i + 3];
        result += a + b + c + d;
    }
    while (i < data.len) : (i += 1) result += @as(f64, data[i]) * data[i];
    return result;
}

/// Inner product of two vectors as double. The length is that of `a`.
pub fn innerProduct(a: []const f32, b: []const f32) f64 {
    var result: f64 = 0;
    var i: usize = 0;
    while (i + 3 < a.len) : (i += 4) {
        const p0 = @as(f64, a[i]) * b[i];
        const p1 = @as(f64, a[i + 1]) * b[i + 1];
        const p2 = @as(f64, a[i + 2]) * b[i + 2];
        const p3 = @as(f64, a[i + 3]) * b[i + 3];
        result += p0 + p1 + p2 + p3;
    }
    while (i < a.len) : (i += 1) result += @as(f64, a[i]) * b[i];
    return result;
}

pub fn autocorrelation(results: []f32, input: []const f32, correlation_count: usize) void {
    const count = @min(correlation_count, input.len);
    for (0..count) |i| {
        results[i] = @floatCast(innerProduct(input[0 .. input.len - i], input[i..]));
    }
}

pub fn bwexpander(ar: []f32, chirp: f32) void {
    var cfac = chirp;
    for (ar[0 .. ar.len - 1]) |*a| {
        a.* *= cfac;
        cfac *= chirp;
    }
    ar[ar.len - 1] *= cfac;
}

/// Reflection coefficients from the autocorrelation. Returns the residual energy.
pub fn schur(refl_coef: []f32, auto_corr: []const f32, order: usize) f32 {
    var c: [max_order_lpc + 1][2]f64 = undefined;
    for (0..order + 1) |k| {
        c[k][0] = auto_corr[k];
        c[k][1] = auto_corr[k];
    }
    for (0..order) |k| {
        const tiny: f32 = 1e-9;
        const den: f64 = @max(c[0][1], @as(f64, tiny));
        const rc_tmp = -c[k + 1][0] / den;
        refl_coef[k] = @floatCast(rc_tmp);
        for (0..order - k) |n| {
            const ctmp1 = c[n + k + 1][0];
            const ctmp2 = c[n][1];
            c[n + k + 1][0] = ctmp1 + ctmp2 * rc_tmp;
            c[n][1] = ctmp2 + ctmp1 * rc_tmp;
        }
    }
    return @floatCast(c[0][1]);
}

/// Step up from reflection coefficients to prediction coefficients.
pub fn k2a(a: []f32, rc: []const f32, order: usize) void {
    for (0..order) |k| {
        const rck = rc[k];
        for (0..(k + 1) >> 1) |n| {
            const tmp1 = a[n];
            const tmp2 = a[k - n - 1];
            a[n] = tmp1 + tmp2 * rck;
            a[k - n - 1] = tmp2 + tmp1 * rck;
        }
        a[k] = -rck;
    }
}

/// Sine window of length `length` (a multiple of 4). `win_type` 1 rises, 2 falls.
pub fn applySineWindow(px_win: []f32, px: []const f32, win_type: u32, length: usize) void {
    const pi: f32 = 3.1415926536;
    const freq: f32 = pi / @as(f32, @floatFromInt(length + 1));
    const c: f32 = 2.0 - freq * freq;
    var s0: f32 = undefined;
    var s1: f32 = undefined;
    if (win_type < 2) {
        s0 = 0.0;
        s1 = freq;
    } else {
        s0 = 1.0;
        s1 = 0.5 * c;
    }
    var k: usize = 0;
    while (k < length) : (k += 4) {
        px_win[k] = px[k] * 0.5 * (s0 + s1);
        px_win[k + 1] = px[k + 1] * s1;
        s0 = c * s1 - s0;
        px_win[k + 2] = px[k + 2] * 0.5 * (s1 + s0);
        px_win[k + 3] = px[k + 3] * s0;
        s1 = c * s0 - s1;
    }
}

/// Autocorrelation on a warped frequency axis. `order` is even.
pub fn warpedAutocorrelation(corr: []f32, input: []const f32, warping: f32, order: usize) void {
    var state: [max_order_lpc + 1]f64 = @splat(0);
    var c: [max_order_lpc + 1]f64 = @splat(0);
    const w: f64 = warping;
    for (input) |sample| {
        var tmp1: f64 = sample;
        var i: usize = 0;
        while (i < order) : (i += 2) {
            const tmp2 = state[i] + w * state[i + 1] - w * tmp1;
            state[i] = tmp1;
            c[i] += state[0] * tmp1;
            tmp1 = state[i + 1] + w * state[i + 2] - w * tmp2;
            state[i + 1] = tmp2;
            c[i + 1] += state[0] * tmp2;
        }
        state[order] = tmp1;
        c[order] += state[0] * tmp1;
    }
    for (0..order + 1) |i| corr[i] = @floatCast(c[i]);
}

/// Modified Burg analysis over `nb_subfr` stacked subframes of `subfr_length` samples, each
/// with `d` preceding samples. Returns the residual energy.
pub fn burgModified(a_out: []f32, x: []const f32, min_inv_gain: f32, subfr_length: usize, nb_subfr: usize, d: usize) f32 {
    const cond_fac: f32 = 1e-5;
    var c_first_row: [max_order_lpc]f64 = @splat(0);
    var c_last_row: [max_order_lpc]f64 = undefined;
    var caf: [max_order_lpc + 1]f64 = undefined;
    var cab: [max_order_lpc + 1]f64 = undefined;
    var af: [max_order_lpc]f64 = undefined;
    const min_inv: f64 = min_inv_gain;
    var c0: f64 = energy(x[0 .. nb_subfr * subfr_length]);
    for (0..nb_subfr) |s| {
        const x_ptr = x[s * subfr_length ..];
        for (1..d + 1) |n| {
            c_first_row[n - 1] += innerProduct(x_ptr[0 .. subfr_length - n], x_ptr[n..]);
        }
    }
    c_last_row = c_first_row;
    const tiny: f32 = 1e-9;
    const init: f64 = c0 + @as(f64, cond_fac) * c0 + @as(f64, tiny);
    cab[0] = init;
    caf[0] = init;
    var inv_gain: f64 = 1.0;
    var reached_max_gain = false;
    var n: usize = 0;
    while (n < d) : (n += 1) {
        for (0..nb_subfr) |s| {
            const x_ptr = x[s * subfr_length ..];
            var tmp1: f64 = x_ptr[n];
            var tmp2: f64 = x_ptr[subfr_length - n - 1];
            for (0..n) |k| {
                c_first_row[k] -= x_ptr[n] * x_ptr[n - k - 1];
                c_last_row[k] -= x_ptr[subfr_length - n - 1] * x_ptr[subfr_length - n + k];
                const atmp = af[k];
                tmp1 += x_ptr[n - k - 1] * atmp;
                tmp2 += x_ptr[subfr_length - n + k] * atmp;
            }
            for (0..n + 1) |k| {
                caf[k] -= tmp1 * x_ptr[n - k];
                cab[k] -= tmp2 * x_ptr[subfr_length - n + k - 1];
            }
        }
        var tmp1 = c_first_row[n];
        var tmp2 = c_last_row[n];
        for (0..n) |k| {
            const atmp = af[k];
            tmp1 += c_last_row[n - k - 1] * atmp;
            tmp2 += c_first_row[n - k - 1] * atmp;
        }
        caf[n + 1] = tmp1;
        cab[n + 1] = tmp2;

        var num = cab[n + 1];
        var nrg_b = cab[0];
        var nrg_f = caf[0];
        for (0..n) |k| {
            const atmp = af[k];
            num += cab[n - k] * atmp;
            nrg_b += cab[k + 1] * atmp;
            nrg_f += caf[k + 1] * atmp;
        }
        var rc = -2.0 * num / (nrg_f + nrg_b);
        tmp1 = inv_gain * (1.0 - rc * rc);
        if (tmp1 <= min_inv) {
            rc = @sqrt(1.0 - min_inv / inv_gain);
            if (num > 0) rc = -rc;
            inv_gain = min_inv;
            reached_max_gain = true;
        } else {
            inv_gain = tmp1;
        }
        for (0..(n + 1) >> 1) |k| {
            tmp1 = af[k];
            tmp2 = af[n - k - 1];
            af[k] = tmp1 + rc * tmp2;
            af[n - k - 1] = tmp2 + rc * tmp1;
        }
        af[n] = rc;
        if (reached_max_gain) {
            for (n + 1..d) |k| af[k] = 0.0;
            break;
        }
        for (0..n + 2) |k| {
            tmp1 = caf[k];
            caf[k] += rc * cab[n + 1 - k];
            cab[n + 1 - k] += rc * tmp1;
        }
    }
    var nrg_f: f64 = undefined;
    if (reached_max_gain) {
        for (0..d) |k| a_out[k] = @floatCast(-af[k]);
        for (0..nb_subfr) |s| c0 -= energy(x[s * subfr_length ..][0..d]);
        nrg_f = c0 * inv_gain;
    } else {
        nrg_f = caf[0];
        var tmp1: f64 = 1.0;
        for (0..d) |k| {
            const atmp = af[k];
            nrg_f += caf[k + 1] * atmp;
            tmp1 += atmp * atmp;
            a_out[k] = @floatCast(-atmp);
        }
        nrg_f -= @as(f64, cond_fac) * c0 * tmp1;
    }
    return @floatCast(nrg_f);
}

/// Multiplies a vector by a constant.
pub fn scaleVector(data: []f32, gain: f32) void {
    for (data) |*v| v.* *= gain;
}

/// Copies a vector and multiplies it by a constant.
pub fn scaleCopyVector(out: []f32, in: []const f32, gain: f32) void {
    for (out, in) |*o, v| o.* = gain * v;
}

/// Sorts `a[0..l]` so that the first `k` positions hold the largest values in decreasing
/// order, and writes their original indices to `idx`.
pub fn insertionSortDecreasing(a: []f32, idx: []i32, l: usize, k: usize) void {
    for (0..k) |i| idx[i] = @intCast(i);
    for (1..k) |i| {
        const value = a[i];
        var j: isize = @as(isize, @intCast(i)) - 1;
        while (j >= 0 and value > a[@intCast(j)]) : (j -= 1) {
            a[@intCast(j + 1)] = a[@intCast(j)];
            idx[@intCast(j + 1)] = idx[@intCast(j)];
        }
        a[@intCast(j + 1)] = value;
        idx[@intCast(j + 1)] = @intCast(i);
    }
    for (k..l) |i| {
        const value = a[i];
        if (value > a[k - 1]) {
            var j: isize = @as(isize, @intCast(k)) - 2;
            while (j >= 0 and value > a[@intCast(j)]) : (j -= 1) {
                a[@intCast(j + 1)] = a[@intCast(j)];
                idx[@intCast(j + 1)] = idx[@intCast(j)];
            }
            a[@intCast(j + 1)] = value;
            idx[@intCast(j + 1)] = @intCast(i);
        }
    }
}

/// Whitening filter. `s[ix]` for `ix` in `order..length` becomes `s[ix]` minus the prediction.
/// The first `order` outputs are zero. `r` and `s` have `length` samples.
pub fn lpcAnalysisFilter(r: []f32, pred: []const f32, s: []const f32, order: usize) void {
    const length = r.len;
    for (order..length) |ix| {
        var acc: f32 = s[ix - 1] * pred[0];
        for (1..order) |j| acc += s[ix - 1 - j] * pred[j];
        r[ix] = s[ix] - acc;
    }
    @memset(r[0..order], 0);
}

/// Correlation vector X't, where column `lag` of X starts at `x[order - 1 - lag]`.
pub fn corrVector(x: []const f32, t: []const f32, l: usize, order: usize, xt: []f32) void {
    for (0..order) |lag| {
        xt[lag] = @floatCast(innerProduct(x[order - 1 - lag ..][0..l], t[0..l]));
    }
}

/// Correlation matrix X'X for the columns of lagged copies of `x`.
pub fn corrMatrix(x: []const f32, l: usize, order: usize, xx: []f32) void {
    const p1 = order - 1;
    var energy_v: f64 = energy(x[p1..][0..l]);
    xx[0] = @floatCast(energy_v);
    for (1..order) |j| {
        const a = x[p1 - j];
        const b = x[p1 + l - j];
        energy_v += a * a - b * b;
        xx[j * order + j] = @floatCast(energy_v);
    }
    var p2 = order - 2;
    for (1..order) |lag| {
        energy_v = innerProduct(x[p1..][0..l], x[p2..][0..l]);
        xx[lag * order] = @floatCast(energy_v);
        xx[lag] = @floatCast(energy_v);
        for (1..order - lag) |j| {
            const a = x[p1 - j] * x[p2 - j];
            const b = x[p1 + l - j] * x[p2 + l - j];
            energy_v += a - b;
            xx[(lag + j) * order + j] = @floatCast(energy_v);
            xx[j * order + lag + j] = @floatCast(energy_v);
        }
        if (lag + 1 < order) p2 -= 1;
    }
}

const testing = std.testing;

test "float2int rounds half to even and saturates" {
    try testing.expectEqual(@as(i32, 2), float2int(2.5));
    try testing.expectEqual(@as(i32, 4), float2int(3.5));
    try testing.expectEqual(@as(i32, -2), float2int(-2.5));
    try testing.expectEqual(@as(i32, 0), float2int(0.5));
    try testing.expectEqual(@as(i32, 1), float2int(0.5001));
    try testing.expectEqual(@as(i32, -1), float2int(-0.7));
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), float2int(3e9));
    try testing.expectEqual(@as(i16, 32767), float2short(1e6));
}

test "schur and step up give the prediction filter of a first order process" {
    var ac: [4]f32 = undefined;
    for (&ac, 0..) |*v, i| v.* = 100.0 * std.math.pow(f32, 0.9, @floatFromInt(i));
    var rc: [3]f32 = undefined;
    const nrg = schur(&rc, &ac, 3);
    var a: [3]f32 = undefined;
    k2a(&a, &rc, 3);
    try testing.expectApproxEqAbs(@as(f32, 0.9), a[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.0), a[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 19.0), nrg, 1e-2);
}

test "burg finds the coefficient of a first order process" {
    var x: [3 * 8]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    var s: f32 = 0;
    for (&x) |*v| {
        s = 0.8 * s + (rnd.float(f32) - 0.5);
        v.* = s * 100;
    }
    var a: [2]f32 = undefined;
    _ = burgModified(&a, &x, 1e-4, 8, 3, 2);
    try testing.expect(a[0] > 0.3 and a[0] < 1.1);
}
