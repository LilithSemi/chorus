//! Linear prediction helpers for the FLAC encoder.
//!
//! The windows, the Levinson-Durbin recursion, the coefficient quantizer and the
//! order estimate follow libFLAC, with f64 math.
const std = @import("std");
const testing = std.testing;

pub const max_order = 32;
pub const max_fixed_order = 4;
pub const min_precision = 5;
pub const max_precision = 15;

/// Tukey window with the taper fraction `p`, as libFLAC builds it.
pub fn tukey(window: []f64, p: f64) void {
    @memset(window, 1.0);
    const len = window.len;
    const taper: i64 = @as(i64, @intFromFloat(p / 2.0 * @as(f64, @floatFromInt(len)))) - 1;
    if (taper <= 0) return;
    const np: usize = @intCast(taper);
    const denom: f64 = @floatFromInt(np);
    for (0..np + 1) |n| {
        const c = @cos(std.math.pi * @as(f64, @floatFromInt(n)) / denom);
        window[n] = 0.5 - 0.5 * c;
        window[len - np - 1 + n] = 0.5 + 0.5 * c;
    }
}

pub fn applyWindow(out: []f64, signal: []const i32, window: []const f64) void {
    for (out, signal, window) |*o, s, w| o.* = @as(f64, @floatFromInt(s)) * w;
}

/// Windows a stretch of `2 * part` samples that starts at `shift`. The first `part`
/// samples use the start of `window` and the others use its end. Returns false when
/// the stretch does not fit in the block.
pub fn applyPartial(out: []f64, signal: []const i32, window: []const f64, part: usize, shift: usize) bool {
    const len = signal.len;
    if (part + shift >= len) return false;
    for (0..part) |i| out[i] = @as(f64, @floatFromInt(signal[shift + i])) * window[i];
    var i = @min(part, len - part - shift);
    var j = len - part;
    while (j < len) : ({
        i += 1;
        j += 1;
    }) out[i] = @as(f64, @floatFromInt(signal[shift + i])) * window[j];
    if (i < len) out[i] = 0.0;
    return true;
}

/// out[lag] is the sum of data[i] * data[i - lag].
pub fn autocorrelation(data: []const f64, out: []f64) void {
    for (out, 0..) |*o, lag| {
        var sum: f64 = 0.0;
        if (lag < data.len) {
            for (data[lag..], data[0 .. data.len - lag]) |a, b| sum += a * b;
        }
        o.* = sum;
    }
}

pub const Levinson = struct {
    /// coefs[i][0..i + 1] are the predictor coefficients of order i + 1.
    coefs: [max_order][max_order]f64 = undefined,
    /// err[i] is the prediction error power at order i + 1.
    err: [max_order]f64 = undefined,
    /// The number of orders that were computed.
    orders: usize = 0,
};

/// Solves the normal equations for the orders 1 to `max`. `autoc` holds `max + 1` lags
/// and `autoc[0]` must not be 0.
pub fn levinson(autoc: []const f64, max: usize, out: *Levinson) void {
    std.debug.assert(max >= 1 and max <= max_order and autoc.len > max and autoc[0] != 0.0);
    var lpc: [max_order]f64 = undefined;
    var err = autoc[0];
    out.orders = max;
    for (0..max) |i| {
        var r = -autoc[i + 1];
        for (0..i) |j| r -= lpc[j] * autoc[i - j];
        r /= err;
        lpc[i] = r;
        for (0..i >> 1) |j| {
            const tmp = lpc[j];
            lpc[j] += r * lpc[i - 1 - j];
            lpc[i - 1 - j] += r * tmp;
        }
        if (i & 1 == 1) lpc[i >> 1] += lpc[i >> 1] * r;
        err *= 1.0 - r * r;
        for (0..i + 1) |j| out.coefs[i][j] = -lpc[j];
        out.err[i] = err;
        if (err == 0.0) {
            out.orders = i + 1;
            return;
        }
    }
}

/// Expected bits of a residual sample for an error power over `samples` samples.
pub fn expectedBits(err: f64, samples: usize) f64 {
    if (err < 0.0) return 1e32;
    if (err == 0.0) return 0.0;
    const scale = 0.5 / @as(f64, @floatFromInt(samples));
    const bits = 0.5 * @log2(scale * err);
    return @max(bits, 0.0);
}

/// The order with the fewest estimated bits. `overhead` is the cost of one
/// coefficient and one warm-up sample in bits.
pub fn bestOrder(err: []const f64, samples: usize, overhead: usize) usize {
    var best: usize = 1;
    var best_bits = std.math.floatMax(f64);
    for (err, 1..) |e, order| {
        const bits = expectedBits(e, samples) * @as(f64, @floatFromInt(samples - order)) +
            @as(f64, @floatFromInt(order * overhead));
        if (bits < best_bits) {
            best = order;
            best_bits = bits;
        }
    }
    return best;
}

/// Quantizes predictor coefficients to `precision` bits including the sign.
/// Returns the shift, or null when the coefficients cannot be represented.
pub fn quantize(coefs: []const f64, precision: u8, out: []i32) ?u8 {
    const bits: u5 = @intCast(precision - 1);
    const qmax: i32 = (@as(i32, 1) << bits) - 1;
    const qmin: i32 = -qmax - 1;
    var cmax: f64 = 0.0;
    for (coefs) |c| cmax = @max(cmax, @abs(c));
    if (cmax <= 0.0 or !std.math.isFinite(cmax)) return null;
    const log2cmax: i32 = std.math.frexp(cmax).exponent - 1;
    var shift: i32 = @as(i32, bits) - log2cmax - 1;
    if (shift > 15) shift = 15 else if (shift < -16) return null;
    const scale: f64 = if (shift >= 0)
        @floatFromInt(@as(u32, 1) << @intCast(shift))
    else
        1.0 / @as(f64, @floatFromInt(@as(u32, 1) << @intCast(-shift)));
    var err: f64 = 0.0;
    for (coefs, out[0..coefs.len]) |c, *q| {
        err += c * scale;
        const r: i32 = @intFromFloat(std.math.clamp(@round(err), @as(f64, @floatFromInt(qmin)), @as(f64, @floatFromInt(qmax))));
        err -= @floatFromInt(r);
        q.* = r;
    }
    return @intCast(@max(shift, 0));
}

/// Writes the residual of the LPC predictor for the samples from index `coefs.len` on.
/// Returns false when a residual does not fit in 31 bits plus sign.
pub fn residual(signal: []const i32, coefs: []const i32, shift: u8, out: []i32) bool {
    const order = coefs.len;
    const s: u6 = @intCast(shift);
    for (order..signal.len) |i| {
        var sum: i64 = 0;
        for (coefs, 0..) |c, j| sum += @as(i64, c) * signal[i - 1 - j];
        const r = @as(i64, signal[i]) - (sum >> s);
        if (r >= std.math.maxInt(i32) or r <= std.math.minInt(i32)) return false;
        out[i - order] = @intCast(r);
    }
    return true;
}

/// Writes the residual of the fixed predictor for the samples from index `order` on.
pub fn fixedResidual(signal: []const i32, order: usize, out: []i32) void {
    for (order..signal.len) |i| {
        const x = signal[i];
        out[i - order] = switch (order) {
            0 => x,
            1 => x - signal[i - 1],
            2 => x - 2 * signal[i - 1] + signal[i - 2],
            3 => x - 3 * signal[i - 1] + 3 * signal[i - 2] - signal[i - 3],
            4 => x - 4 * signal[i - 1] + 6 * signal[i - 2] - 4 * signal[i - 3] + signal[i - 4],
            else => unreachable,
        };
    }
}

pub const FixedChoice = struct {
    order: usize,
    /// Estimated bits per residual sample at the chosen order.
    bits: f64,
};

/// Picks the fixed order with the smallest sum of absolute residuals over the
/// samples from index 4 on. Lower orders win ties. `signal.len` must be above 4.
pub fn bestFixed(signal: []const i32) FixedChoice {
    var total: [5]u64 = @splat(0);
    for (max_fixed_order..signal.len) |i| {
        const x = signal[i];
        const a = signal[i - 1];
        const b = signal[i - 2];
        const c = signal[i - 3];
        const d = signal[i - 4];
        const e1 = x - a;
        const e2 = e1 - (a - b);
        const e3 = e2 - (a - 2 * b + c);
        const e4 = e3 - (a - 3 * b + 3 * c - d);
        total[0] += @abs(x);
        total[1] += @abs(e1);
        total[2] += @abs(e2);
        total[3] += @abs(e3);
        total[4] += @abs(e4);
    }
    const order: usize = if (total[0] <= @min(@min(total[1], total[2]), @min(total[3], total[4])))
        0
    else if (total[1] <= @min(total[2], @min(total[3], total[4])))
        1
    else if (total[2] <= @min(total[3], total[4]))
        2
    else if (total[3] <= total[4])
        3
    else
        4;
    const count: f64 = @floatFromInt(signal.len - max_fixed_order);
    const bits: f64 = if (total[order] > 0) @log2(std.math.ln2 * @as(f64, @floatFromInt(total[order])) / count) else 0.0;
    return .{ .order = order, .bits = bits };
}

test "tukey window tapers the ends and is flat in the middle" {
    var w: [100]f64 = undefined;
    tukey(&w, 0.5);
    try testing.expectEqual(@as(f64, 0.0), w[0]);
    try testing.expectEqual(@as(f64, 0.0), w[99]);
    try testing.expectEqual(@as(f64, 1.0), w[50]);
    try testing.expectApproxEqAbs(@as(f64, 0.5), w[12], 0.02);
    for (0..50) |i| try testing.expectApproxEqAbs(w[i], w[99 - i], 1e-12);
    var rect: [8]f64 = undefined;
    tukey(&rect, 0.0001);
    try testing.expectEqualSlices(f64, &@as([8]f64, @splat(1.0)), &rect);
}

test "autocorrelation sums products at each lag" {
    const data = [_]f64{ 1, 2, 3, 4 };
    var out: [5]f64 = undefined;
    autocorrelation(&data, &out);
    try testing.expectEqualSlices(f64, &.{ 30, 20, 11, 4, 0 }, &out);
}

test "partial windows cover the start and the end of the window" {
    var window: [8]f64 = undefined;
    for (&window, 0..) |*w, i| w.* = @floatFromInt(i + 1);
    const signal = [_]i32{ 10, 10, 10, 10, 10, 10, 10, 10 };
    var out: [8]f64 = undefined;
    try testing.expect(applyPartial(&out, &signal, &window, 2, 3));
    try testing.expectEqualSlices(f64, &.{ 10, 20, 70, 80, 0 }, out[0..5]);
    try testing.expect(!applyPartial(&out, &signal, &window, 4, 4));
}

test "levinson finds the coefficients of a first order process" {
    var autoc: [4]f64 = undefined;
    for (&autoc, 0..) |*a, i| a.* = std.math.pow(f64, 0.5, @floatFromInt(i));
    var lev: Levinson = .{};
    levinson(&autoc, 3, &lev);
    try testing.expectEqual(@as(usize, 3), lev.orders);
    try testing.expectApproxEqAbs(@as(f64, 0.5), lev.coefs[0][0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.75), lev.err[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), lev.coefs[2][0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), lev.coefs[2][1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), lev.coefs[2][2], 1e-12);
    try testing.expectEqual(@as(usize, 1), bestOrder(lev.err[0..3], 4096, 20));
}

test "quantize scales to the precision and feeds the error forward" {
    var q: [3]i32 = undefined;
    try testing.expectEqual(@as(?u8, 4), quantize(&.{0.5}, 5, &q));
    try testing.expectEqual(@as(i32, 8), q[0]);
    try testing.expectEqual(@as(?u8, 3), quantize(&.{ 1.5, -0.75 }, 5, &q));
    try testing.expectEqualSlices(i32, &.{ 12, -6 }, q[0..2]);
    try testing.expectEqual(@as(?u8, null), quantize(&.{ 0.0, 0.0 }, 8, &q));
    try testing.expectEqual(@as(?u8, 0), quantize(&.{ 100000.0, 3.0 }, 10, &q));
    try testing.expectEqualSlices(i32, &.{ 391, 0 }, q[0..2]);
    try testing.expectEqual(@as(?u8, 15), quantize(&.{0.00001}, 15, &q));
    try testing.expectEqual(@as(i32, 0), q[0]);
}

test "lpc and fixed residuals follow the predictor equations" {
    const signal = [_]i32{ 1, 4, 9, 16, 25, 36, 49 };
    var out: [7]i32 = undefined;
    fixedResidual(&signal, 2, &out);
    try testing.expectEqualSlices(i32, &.{ 2, 2, 2, 2, 2 }, out[0..5]);
    fixedResidual(&signal, 3, &out);
    try testing.expectEqualSlices(i32, &.{ 0, 0, 0, 0 }, out[0..4]);
    try testing.expect(residual(&signal, &.{ 2, -1 }, 0, &out));
    try testing.expectEqualSlices(i32, &.{ 2, 2, 2, 2, 2 }, out[0..5]);
    try testing.expect(residual(&signal, &.{ 8, 4 }, 2, &out));
    try testing.expectEqualSlices(i32, &.{ 0, -6, -16, -30, -48 }, out[0..5]);
    const big = [_]i32{ std.math.maxInt(i32), std.math.minInt(i32) + 1, 0 };
    try testing.expect(!residual(&big, &.{1}, 0, &out));
}

test "the fixed order choice prefers the lowest order on ties" {
    const ramp = [_]i32{ 0, 3, 6, 9, 12, 15, 18, 21 };
    const choice = bestFixed(&ramp);
    try testing.expectEqual(@as(usize, 2), choice.order);
    try testing.expectEqual(@as(f64, 0.0), choice.bits);
    const flat = [_]i32{ 5, 5, 5, 5, 5, 5, 5 };
    try testing.expectEqual(@as(usize, 1), bestFixed(&flat).order);
    const quad = [_]i32{ 0, 1, 4, 9, 16, 25, 36, 49, 64 };
    try testing.expectEqual(@as(usize, 3), bestFixed(&quad).order);
}
