//! Pitch search and linear prediction for the CELT concealment, ported from libopus
//! celt/pitch.c and celt/celt_lpc.c (float build). libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const tables = @import("tables.zig");

pub const lpc_order = 24;
/// The most samples that `autocorr` takes.
pub const max_autocorr = 1024;

/// `xcorr[i]` is the sum of `x[j] * y[i + j]`.
pub fn pitchXcorr(x: []const f32, y: []const f32, xcorr: []f32) void {
    for (xcorr, 0..) |*out, i| {
        var sum: f32 = 0;
        for (x, y[i..][0..x.len]) |a, b| sum += a * b;
        out.* = sum;
    }
}

/// Autocorrelation of `x[0..n]` for lags 0 to `lag`. With `overlap` set, the first and the last
/// `overlap` samples are faded with `window`.
pub fn autocorr(x: []const f32, ac: []f32, window: []const f32, overlap: usize, lag: usize, n: usize) void {
    std.debug.assert(n > lag and n <= max_autocorr and ac.len > lag);
    var xx: [max_autocorr]f32 = undefined;
    var xptr = x[0..n];
    if (overlap != 0) {
        @memcpy(xx[0..n], x[0..n]);
        for (0..overlap) |i| {
            xx[i] = x[i] * window[i];
            xx[n - i - 1] = x[n - i - 1] * window[i];
        }
        xptr = xx[0..n];
    }
    const fast_n = n - lag;
    pitchXcorr(xptr[0..fast_n], xptr, ac[0 .. lag + 1]);
    for (0..lag + 1) |k| {
        var d: f32 = 0;
        for (k + fast_n..n) |i| d += xptr[i] * xptr[i - k];
        ac[k] += d;
    }
}

/// The LPC coefficients of order `lpc.len` from the autocorrelation `ac`.
pub fn lpcFromAutocorr(lpc: []f32, ac: []const f32) void {
    const p = lpc.len;
    @memset(lpc, 0);
    var err = ac[0];
    if (!(ac[0] > 1e-10)) return;
    for (0..p) |i| {
        var rr: f32 = 0;
        for (0..i) |j| rr += lpc[j] * ac[i - j];
        rr += ac[i + 1];
        const r = -(rr / err);
        lpc[i] = r;
        for (0..(i + 1) >> 1) |j| {
            const tmp1 = lpc[j];
            const tmp2 = lpc[i - 1 - j];
            lpc[j] = tmp1 + r * tmp2;
            lpc[i - 1 - j] = tmp2 + r * tmp1;
        }
        err = err - (r * r) * err;
        if (err <= 0.001 * ac[0]) break;
    }
}

/// Runs the FIR filter with the coefficients `num` over `buf[off .. off + y.len]`. It reads
/// `num.len` samples of history before `off`.
pub fn fir(buf: []const f32, off: usize, num: []const f32, y: []f32) void {
    const ord = num.len;
    std.debug.assert(off >= ord);
    for (y, 0..) |*out, i| {
        var sum = buf[off + i];
        for (0..ord) |j| sum += num[ord - 1 - j] * buf[off + i + j - ord];
        out.* = sum;
    }
}

/// The all pole filter `1 / A(z)` over `x` in place. `mem` holds the last outputs, newest first.
/// The length of `x` is a multiple of 4.
pub fn iir(x: []f32, den: *const [lpc_order]f32, mem: *const [lpc_order]f32) void {
    const ord = lpc_order;
    std.debug.assert(x.len % 4 == 0 and x.len <= 960 + 120);
    var rden: [ord]f32 = undefined;
    for (0..ord) |i| rden[i] = den[ord - 1 - i];
    var y: [960 + 120 + ord]f32 = @splat(0);
    for (0..ord) |i| y[i] = -mem[ord - 1 - i];
    var i: usize = 0;
    while (i < x.len) : (i += 4) {
        var sum: [4]f32 = x[i..][0..4].*;
        for (0..4) |k| {
            for (0..ord) |j| sum[k] += rden[j] * y[i + k + j];
        }
        y[i + ord] = -sum[0];
        x[i] = sum[0];
        sum[1] += y[i + ord] * den[0];
        y[i + ord + 1] = -sum[1];
        x[i + 1] = sum[1];
        sum[2] += y[i + ord + 1] * den[0];
        sum[2] += y[i + ord] * den[1];
        y[i + ord + 2] = -sum[2];
        x[i + 2] = sum[2];
        sum[3] += y[i + ord + 2] * den[0];
        sum[3] += y[i + ord + 1] * den[1];
        sum[3] += y[i + ord] * den[2];
        y[i + ord + 3] = -sum[3];
        x[i + 3] = sum[3];
    }
}

fn firFive(x: []f32, num: *const [5]f32) void {
    var mem: [5]f32 = @splat(0);
    for (x) |*v| {
        var sum = v.*;
        for (0..5) |k| sum += num[k] * mem[k];
        mem[4] = mem[3];
        mem[3] = mem[2];
        mem[2] = mem[1];
        mem[1] = mem[0];
        mem[0] = v.*;
        v.* = sum;
    }
}

/// Low passes and halves the rate of the last `x_lp.len` pairs of samples of the channels
/// `mem`, for the pitch search.
pub fn downsample(mem: []const []const f32, x_lp: []f32) void {
    const len = x_lp.len;
    const x0 = mem[0];
    x_lp[0] = 0.25 * x0[1] + 0.5 * x0[0];
    for (1..len) |i| x_lp[i] = 0.25 * x0[2 * i - 1] + 0.25 * x0[2 * i + 1] + 0.5 * x0[2 * i];
    if (mem.len == 2) {
        const x1 = mem[1];
        x_lp[0] += 0.25 * x1[1] + 0.5 * x1[0];
        for (1..len) |i| x_lp[i] += 0.25 * x1[2 * i - 1] + 0.25 * x1[2 * i + 1] + 0.5 * x1[2 * i];
    }
    var ac: [5]f32 = undefined;
    autocorr(x_lp, &ac, &.{}, 0, 4, len);
    ac[0] *= 1.0001;
    for (1..5) |i| {
        const f: f32 = @floatFromInt(i);
        ac[i] -= ac[i] * (0.008 * f) * (0.008 * f);
    }
    var lpc: [4]f32 = undefined;
    lpcFromAutocorr(&lpc, &ac);
    var tmp: f32 = 1.0;
    for (&lpc) |*c| {
        tmp = 0.9 * tmp;
        c.* = c.* * tmp;
    }
    const c1: f32 = 0.8;
    const lpc2 = [5]f32{
        lpc[0] + 0.8,
        lpc[1] + c1 * lpc[0],
        lpc[2] + c1 * lpc[1],
        lpc[3] + c1 * lpc[2],
        c1 * lpc[3],
    };
    firFive(x_lp, &lpc2);
}

fn findBestPitch(xcorr: []const f32, y: []const f32, len: usize, max_pitch: usize) [2]usize {
    var syy: f32 = 1;
    var best_num: [2]f32 = .{ -1, -1 };
    var best_den: [2]f32 = .{ 0, 0 };
    var best_pitch: [2]usize = .{ 0, 1 };
    for (0..len) |j| syy += y[j] * y[j];
    for (0..max_pitch) |i| {
        if (xcorr[i] > 0) {
            var xcorr16 = xcorr[i];
            xcorr16 *= 1e-12;
            const num = xcorr16 * xcorr16;
            if (num * best_den[1] > best_num[1] * syy) {
                if (num * best_den[0] > best_num[0] * syy) {
                    best_num[1] = best_num[0];
                    best_den[1] = best_den[0];
                    best_pitch[1] = best_pitch[0];
                    best_num[0] = num;
                    best_den[0] = syy;
                    best_pitch[0] = i;
                } else {
                    best_num[1] = num;
                    best_den[1] = syy;
                    best_pitch[1] = i;
                }
            }
        }
        syy += y[i + len] * y[i + len] - y[i] * y[i];
        syy = @max(1, syy);
    }
    return best_pitch;
}

/// The pitch lag in `[0, max_pitch]` of `x_lp[0 .. len / 2]` inside `y`, at the rate of the
/// samples. `len / 4` and `(len + max_pitch) / 4` must be exact.
pub fn search(x_lp: []const f32, y: []const f32, comptime len: usize, comptime max_pitch: usize) usize {
    const lag = len + max_pitch;
    var x_lp4: [len >> 2]f32 = undefined;
    var y_lp4: [lag >> 2]f32 = undefined;
    var xcorr: [max_pitch >> 1]f32 = undefined;
    for (&x_lp4, 0..) |*v, j| v.* = x_lp[2 * j];
    for (&y_lp4, 0..) |*v, j| v.* = y[2 * j];

    pitchXcorr(&x_lp4, &y_lp4, xcorr[0 .. max_pitch >> 2]);
    var best = findBestPitch(&xcorr, &y_lp4, len >> 2, max_pitch >> 2);

    for (0..max_pitch >> 1) |i| {
        xcorr[i] = 0;
        const d0 = @abs(@as(i64, @intCast(i)) - 2 * @as(i64, @intCast(best[0])));
        const d1 = @abs(@as(i64, @intCast(i)) - 2 * @as(i64, @intCast(best[1])));
        if (d0 <= 2 or d1 <= 2) {
            var sum: f32 = 0;
            for (x_lp[0 .. len >> 1], y[i..][0 .. len >> 1]) |a, b| sum += a * b;
            xcorr[i] = @max(-1, sum);
        }
    }
    best = findBestPitch(&xcorr, y, len >> 1, max_pitch >> 1);

    var offset: i32 = 0;
    if (best[0] > 0 and best[0] < (max_pitch >> 1) - 1) {
        const a = xcorr[best[0] - 1];
        const b = xcorr[best[0]];
        const c = xcorr[best[0] + 1];
        if (c - a > 0.7 * (b - a)) {
            offset = 1;
        } else if (a - c > 0.7 * (b - c)) {
            offset = -1;
        }
    }
    return @intCast(2 * @as(i32, @intCast(best[0])) - offset);
}

/// The shortest period of the comb filter.
pub const comb_min_period = 15;
/// The longest period of the comb filter.
pub const comb_max_period = 1024;
const comb_overlap = 120;

/// The comb filter (comb_filter). It reads `x` from `x_pos` and writes `y` from `y_pos`, `len`
/// samples. The filter reads `x` up to `t + 2` samples before `x_pos`. When `y` and `x` are the
/// same samples the filter runs in place and reads its own output. A change of period or gain
/// fades over `overlap` samples, which is 0 or 120.
pub fn combFilter(
    y: []f32,
    y_pos: usize,
    x: []const f32,
    x_pos: usize,
    t0_in: i32,
    t1_in: i32,
    len: usize,
    g0: f32,
    g1: f32,
    tapset0: u32,
    tapset1: u32,
    overlap: usize,
) void {
    std.debug.assert(overlap == 0 or overlap == comb_overlap);
    const in_place = @intFromPtr(y.ptr + y_pos) == @intFromPtr(x.ptr + x_pos);
    if (g0 == 0 and g1 == 0) {
        if (!in_place) @memcpy(y[y_pos..][0..len], x[x_pos..][0..len]);
        return;
    }
    const t0: usize = @intCast(@max(t0_in, comb_min_period));
    const t1: usize = @intCast(@max(t1_in, comb_min_period));
    const g = &tables.comb_gains;
    const g00 = g0 * g[tapset0][0];
    const g01 = g0 * g[tapset0][1];
    const g02 = g0 * g[tapset0][2];
    const g10 = g1 * g[tapset1][0];
    const g11 = g1 * g[tapset1][1];
    const g12 = g1 * g[tapset1][2];
    const w = &tables.window120;
    var ov: usize = overlap;
    if (g0 == g1 and t0 == t1 and tapset0 == tapset1) ov = 0;
    var i: usize = 0;
    while (i < ov) : (i += 1) {
        const p = x_pos + i;
        const f = w[i] * w[i];
        const a = 1.0 - f;
        y[y_pos + i] = x[p] +
            (a * g00) * x[p - t0] +
            (a * g01) * (x[p - t0 + 1] + x[p - t0 - 1]) +
            (a * g02) * (x[p - t0 + 2] + x[p - t0 - 2]) +
            (f * g10) * x[p - t1] +
            (f * g11) * (x[p - t1 + 1] + x[p - t1 - 1]) +
            (f * g12) * (x[p - t1 + 2] + x[p - t1 - 2]);
    }
    if (g1 == 0) {
        if (!in_place) @memcpy(y[y_pos + i ..][0 .. len - i], x[x_pos + i ..][0 .. len - i]);
        return;
    }
    while (i < len) : (i += 1) {
        const p = x_pos + i;
        y[y_pos + i] = x[p] +
            g10 * x[p - t1] +
            g11 * (x[p - t1 + 1] + x[p - t1 - 1]) +
            g12 * (x[p - t1 + 2] + x[p - t1 - 2]);
    }
}

const second_check = [16]u32{ 0, 0, 3, 2, 3, 2, 5, 2, 3, 2, 3, 2, 5, 2, 3, 2 };

fn pitchGain(xy: f32, xx: f32, yy: f32) f32 {
    return xy / @sqrt(1 + xx * yy);
}

/// Checks the pitch period `t0` for a period that is a fraction of it (remove_doubling). `x` is
/// the signal at half the rate, `maxperiod` samples of history followed by `n` samples at the
/// full rate. Returns the pitch gain and updates `t0`.
pub fn removeDoubling(x: []const f32, maxperiod_in: usize, minperiod_in: usize, n_in: usize, t0_: *i32, prev_period_in: i32, prev_gain: f32) f32 {
    const minperiod0: i32 = @intCast(minperiod_in);
    const maxperiod: i32 = @intCast(maxperiod_in / 2);
    const minperiod: i32 = @intCast(minperiod_in / 2);
    const prev_period: i32 = @divTrunc(prev_period_in, 2);
    const n = n_in / 2;
    const base: usize = @intCast(maxperiod);
    t0_.* = @divTrunc(t0_.*, 2);
    if (t0_.* >= maxperiod) t0_.* = maxperiod - 1;
    var t: i32 = t0_.*;
    const t0 = t;

    var yy_lookup: [comb_max_period / 2 + 1]f32 = undefined;
    var xx: f32 = 0;
    var xy: f32 = 0;
    for (0..n) |j| {
        xx += x[base + j] * x[base + j];
        xy += x[base + j] * x[base + j - @as(usize, @intCast(t0))];
    }
    yy_lookup[0] = xx;
    var yy = xx;
    for (1..@as(usize, @intCast(maxperiod)) + 1) |i| {
        yy = yy + x[base - i] * x[base - i] - x[base + n - i] * x[base + n - i];
        yy_lookup[i] = @max(0, yy);
    }
    yy = yy_lookup[@intCast(t0)];
    var best_xy = xy;
    var best_yy = yy;
    var g = pitchGain(xy, xx, yy);
    const g0 = g;
    var k: u32 = 2;
    while (k <= 15) : (k += 1) {
        const ki: i32 = @intCast(k);
        const t1: i32 = @divTrunc(2 * t0 + ki, 2 * ki);
        if (t1 < minperiod) break;
        var t1b: i32 = undefined;
        if (k == 2) {
            t1b = if (t1 + t0 > maxperiod) t0 else t0 + t1;
        } else {
            t1b = @divTrunc(2 * @as(i32, @intCast(second_check[k])) * t0 + ki, 2 * ki);
        }
        var xy1: f32 = 0;
        var xy2: f32 = 0;
        for (0..n) |j| {
            xy1 += x[base + j] * x[base + j - @as(usize, @intCast(t1))];
            xy2 += x[base + j] * x[base + j - @as(usize, @intCast(t1b))];
        }
        xy = 0.5 * (xy1 + xy2);
        yy = 0.5 * (yy_lookup[@intCast(t1)] + yy_lookup[@intCast(t1b)]);
        const g1 = pitchGain(xy, xx, yy);
        var cont: f32 = 0;
        if (@abs(t1 - prev_period) <= 1) {
            cont = prev_gain;
        } else if (@abs(t1 - prev_period) <= 2 and 5 * ki * ki < t0) {
            cont = 0.5 * prev_gain;
        }
        var thresh = @max(0.3, 0.7 * g0 - cont);
        if (t1 < 3 * minperiod) {
            thresh = @max(0.4, 0.85 * g0 - cont);
        } else if (t1 < 2 * minperiod) {
            thresh = @max(0.5, 0.9 * g0 - cont);
        }
        if (g1 > thresh) {
            best_xy = xy;
            best_yy = yy;
            t = t1;
            g = g1;
        }
    }
    best_xy = @max(0, best_xy);
    var pg: f32 = if (best_yy <= best_xy) 1.0 else best_xy / (best_yy + 1);

    var xcorr: [3]f32 = undefined;
    for (0..3) |kk| {
        var s: f32 = 0;
        const lag: usize = @intCast(t + @as(i32, @intCast(kk)) - 1);
        for (0..n) |j| s += x[base + j] * x[base + j - lag];
        xcorr[kk] = s;
    }
    var offset: i32 = 0;
    if ((xcorr[2] - xcorr[0]) > 0.7 * (xcorr[1] - xcorr[0])) {
        offset = 1;
    } else if ((xcorr[0] - xcorr[2]) > 0.7 * (xcorr[1] - xcorr[2])) {
        offset = -1;
    }
    if (pg > g) pg = g;
    t0_.* = 2 * t + offset;
    if (t0_.* < minperiod0) t0_.* = minperiod0;
    return pg;
}

const testing = std.testing;

test "levinson recursion finds the one pole predictor" {
    var ac: [25]f32 = undefined;
    for (&ac, 0..) |*v, k| v.* = 1000.0 * std.math.pow(f32, 0.9, @floatFromInt(k));
    var lpc: [24]f32 = undefined;
    lpcFromAutocorr(&lpc, &ac);
    try testing.expectApproxEqAbs(@as(f32, -0.9), lpc[0], 1e-5);
    for (lpc[1..]) |v| try testing.expectApproxEqAbs(@as(f32, 0), v, 1e-4);
    var silent: [25]f32 = @splat(0);
    lpcFromAutocorr(&lpc, &silent);
    for (lpc) |v| try testing.expectEqual(@as(f32, 0), v);
}

test "the all pole filter undoes the FIR filter" {
    var rng: @import("../test_util.zig").Xorshift = .{ .s = 99 };
    var lpc: [lpc_order]f32 = @splat(0);
    lpc[0] = -1.2;
    lpc[1] = 0.5;
    lpc[5] = -0.1;
    var x: [lpc_order + 360]f32 = undefined;
    for (&x) |*v| v.* = @as(f32, @floatFromInt(rng.next() >> 20)) - 2048;
    var res: [360]f32 = undefined;
    fir(&x, lpc_order, &lpc, &res);
    var back = res;
    var mem: [lpc_order]f32 = undefined;
    for (&mem, 0..) |*m, i| m.* = x[lpc_order - 1 - i];
    iir(&back, &lpc, &mem);
    for (back, x[lpc_order..]) |got, want| try testing.expectApproxEqAbs(want, got, 0.05);
}

test "the pitch search finds the period of a tone" {
    var lp: [1024]f32 = undefined;
    for (&lp, 0..) |*v, i| {
        const t: f32 = @floatFromInt(i);
        v.* = @sin(t * 2.0 * std.math.pi / 85.0) + 0.5 * @sin(t * 4.0 * std.math.pi / 85.0);
    }
    const found = search(lp[360..], &lp, 1328, 620);
    // The signal has 85 samples per period at the half rate, so 170 at 48 kHz. The result is
    // 720 minus a lag in 48 kHz samples, and every multiple of the period fits the tone.
    const lag = 720 - found;
    try testing.expect((lag + 2) % 170 <= 4);
}

test "the encoder comb filter and the decoder comb filter undo each other" {
    var rng: @import("../test_util.zig").Xorshift = .{ .s = 17 };
    var x: [comb_max_period + 400]f32 = undefined;
    for (&x) |*v| v.* = @as(f32, @floatFromInt(@as(i32, @bitCast(rng.next())) >> 12));
    for ([_]u32{ 0, 1, 2 }) |tapset| {
        var filtered = x;
        // The encoder subtracts the echoes, with the unfiltered samples as the source.
        combFilter(&filtered, comb_max_period, &x, comb_max_period, 100, 100, 400, -0.5, -0.5, tapset, tapset, 0);
        var restored = filtered;
        // The decoder adds them back in place from the samples that it restored already.
        combFilter(&restored, comb_max_period, &restored, comb_max_period, 100, 100, 400, 0.5, 0.5, tapset, tapset, 0);
        for (x[comb_max_period..], restored[comb_max_period..]) |a, b| try testing.expectApproxEqAbs(a, b, 0.5);
    }
}

test "a fraction of the period is found for a tone" {
    var x: [512 + 480]f32 = undefined;
    for (&x, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / 85.0);
    // The signal repeats every 85 samples at half the rate, 170 at the full rate.
    var t0: i32 = 340;
    const gain = removeDoubling(&x, comb_max_period, comb_min_period, 960, &t0, 0, 0);
    try testing.expect(@abs(t0 - 170) <= 2);
    try testing.expect(gain > 0.9);
    t0 = 170;
    _ = removeDoubling(&x, comb_max_period, comb_min_period, 960, &t0, 0, 0);
    try testing.expect(@abs(t0 - 170) <= 2);
}
