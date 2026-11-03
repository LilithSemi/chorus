//! CELT forward and inverse MDCT and the mixed radix FFT under them, ported from libopus
//! celt/mdct.c and celt/kiss_fft.c. libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const tables = @import("tables.zig");

const Cpx = struct { r: f32, i: f32 };

const overlap = 120;
const twiddles: [480]Cpx = blk: {
    var t: [480]Cpx = undefined;
    for (tables.fft_twiddles48000_960, 0..) |v, i| t[i] = .{ .r = v[0], .i = v[1] };
    break :blk t;
};

const Stage = struct { p: u8, m: u8 };

const Plan = struct {
    nfft: usize,
    /// Twiddle stride shift of the transform.
    shift: u3,
    stages: []const Stage,
    bitrev: []const u16,
};

const plans = [4]Plan{
    .{ .nfft = 480, .shift = 0, .stages = &.{ .{ .p = 5, .m = 96 }, .{ .p = 3, .m = 32 }, .{ .p = 4, .m = 8 }, .{ .p = 2, .m = 4 }, .{ .p = 4, .m = 1 } }, .bitrev = &tables.fft_bitrev480 },
    .{ .nfft = 240, .shift = 1, .stages = &.{ .{ .p = 5, .m = 48 }, .{ .p = 3, .m = 16 }, .{ .p = 4, .m = 4 }, .{ .p = 4, .m = 1 } }, .bitrev = &tables.fft_bitrev240 },
    .{ .nfft = 120, .shift = 2, .stages = &.{ .{ .p = 5, .m = 24 }, .{ .p = 3, .m = 8 }, .{ .p = 2, .m = 4 }, .{ .p = 4, .m = 1 } }, .bitrev = &tables.fft_bitrev120 },
    .{ .nfft = 60, .shift = 3, .stages = &.{ .{ .p = 5, .m = 12 }, .{ .p = 3, .m = 4 }, .{ .p = 4, .m = 1 } }, .bitrev = &tables.fft_bitrev60 },
};

fn add(a: Cpx, b: Cpx) Cpx {
    return .{ .r = a.r + b.r, .i = a.i + b.i };
}

fn sub(a: Cpx, b: Cpx) Cpx {
    return .{ .r = a.r - b.r, .i = a.i - b.i };
}

fn mul(a: Cpx, b: Cpx) Cpx {
    return .{ .r = a.r * b.r - a.i * b.i, .i = a.r * b.i + a.i * b.r };
}

/// The radix 2 stage, which only follows a radix 4 stage so that `m` is 4.
fn bfly2(f: []Cpx, n: usize) void {
    const tw: f32 = 0.7071067812;
    var base: usize = 0;
    for (0..n) |_| {
        var t = f[base + 4];
        f[base + 4] = sub(f[base], t);
        f[base] = add(f[base], t);

        t = .{ .r = (f[base + 5].r + f[base + 5].i) * tw, .i = (f[base + 5].i - f[base + 5].r) * tw };
        f[base + 5] = sub(f[base + 1], t);
        f[base + 1] = add(f[base + 1], t);

        t = .{ .r = f[base + 6].i, .i = -f[base + 6].r };
        f[base + 6] = sub(f[base + 2], t);
        f[base + 2] = add(f[base + 2], t);

        t = .{ .r = (f[base + 7].i - f[base + 7].r) * tw, .i = -(f[base + 7].i + f[base + 7].r) * tw };
        f[base + 7] = sub(f[base + 3], t);
        f[base + 3] = add(f[base + 3], t);
        base += 8;
    }
}

fn bfly4(f: []Cpx, fstride: usize, m: usize, n: usize, mm: usize) void {
    if (m == 1) {
        var base: usize = 0;
        for (0..n) |_| {
            const s0 = sub(f[base], f[base + 2]);
            f[base] = add(f[base], f[base + 2]);
            var s1 = add(f[base + 1], f[base + 3]);
            f[base + 2] = sub(f[base], s1);
            f[base] = add(f[base], s1);
            s1 = sub(f[base + 1], f[base + 3]);
            f[base + 1] = .{ .r = s0.r + s1.i, .i = s0.i - s1.r };
            f[base + 3] = .{ .r = s0.r - s1.i, .i = s0.i + s1.r };
            base += 4;
        }
        return;
    }
    const m2 = 2 * m;
    const m3 = 3 * m;
    for (0..n) |i| {
        const base = i * mm;
        for (0..m) |j| {
            const o = base + j;
            const s0 = mul(f[o + m], twiddles[j * fstride]);
            const s1 = mul(f[o + m2], twiddles[2 * j * fstride]);
            const s2 = mul(f[o + m3], twiddles[3 * j * fstride]);
            const s5 = sub(f[o], s1);
            f[o] = add(f[o], s1);
            const s3 = add(s0, s2);
            const s4 = sub(s0, s2);
            f[o + m2] = sub(f[o], s3);
            f[o] = add(f[o], s3);
            f[o + m] = .{ .r = s5.r + s4.i, .i = s5.i - s4.r };
            f[o + m3] = .{ .r = s5.r - s4.i, .i = s5.i + s4.r };
        }
    }
}

fn bfly3(f: []Cpx, fstride: usize, m: usize, n: usize, mm: usize) void {
    const m2 = 2 * m;
    const epi3 = twiddles[fstride * m];
    for (0..n) |i| {
        const base = i * mm;
        for (0..m) |j| {
            const o = base + j;
            const s1 = mul(f[o + m], twiddles[j * fstride]);
            const s2 = mul(f[o + m2], twiddles[2 * j * fstride]);
            const s3 = add(s1, s2);
            var s0 = sub(s1, s2);
            f[o + m] = .{ .r = f[o].r - s3.r * 0.5, .i = f[o].i - s3.i * 0.5 };
            s0 = .{ .r = s0.r * epi3.i, .i = s0.i * epi3.i };
            f[o] = add(f[o], s3);
            f[o + m2] = .{ .r = f[o + m].r + s0.i, .i = f[o + m].i - s0.r };
            f[o + m] = .{ .r = f[o + m].r - s0.i, .i = f[o + m].i + s0.r };
        }
    }
}

fn bfly5(f: []Cpx, fstride: usize, m: usize, n: usize, mm: usize) void {
    const ya = twiddles[fstride * m];
    const yb = twiddles[fstride * 2 * m];
    for (0..n) |i| {
        const base = i * mm;
        for (0..m) |u| {
            const o0 = base + u;
            const s0 = f[o0];
            const s1 = mul(f[o0 + m], twiddles[u * fstride]);
            const s2 = mul(f[o0 + 2 * m], twiddles[2 * u * fstride]);
            const s3 = mul(f[o0 + 3 * m], twiddles[3 * u * fstride]);
            const s4 = mul(f[o0 + 4 * m], twiddles[4 * u * fstride]);

            const s7 = add(s1, s4);
            const s10 = sub(s1, s4);
            const s8 = add(s2, s3);
            const s9 = sub(s2, s3);

            f[o0] = .{ .r = f[o0].r + (s7.r + s8.r), .i = f[o0].i + (s7.i + s8.i) };

            const s5: Cpx = .{
                .r = s0.r + (s7.r * ya.r + s8.r * yb.r),
                .i = s0.i + (s7.i * ya.r + s8.i * yb.r),
            };
            const s6: Cpx = .{
                .r = s10.i * ya.i + s9.i * yb.i,
                .i = -(s10.r * ya.i + s9.r * yb.i),
            };
            f[o0 + m] = sub(s5, s6);
            f[o0 + 4 * m] = add(s5, s6);

            const s11: Cpx = .{
                .r = s0.r + (s7.r * yb.r + s8.r * ya.r),
                .i = s0.i + (s7.i * yb.r + s8.i * ya.r),
            };
            const s12: Cpx = .{
                .r = s9.i * ya.i - s10.i * yb.i,
                .i = s10.r * yb.i - s9.r * ya.i,
            };
            f[o0 + 2 * m] = add(s11, s12);
            f[o0 + 3 * m] = sub(s11, s12);
        }
    }
}

/// The butterflies of a transform whose input is already in bit reversed order.
fn fftImpl(plan: Plan, f: []Cpx) void {
    var fstride: [6]usize = undefined;
    fstride[0] = 1;
    for (plan.stages, 0..) |s, l| fstride[l + 1] = fstride[l] * s.p;
    var l = plan.stages.len;
    var m: usize = 1;
    while (l > 0) {
        l -= 1;
        const m2: usize = if (l != 0) plan.stages[l - 1].m else 1;
        const stage = plan.stages[l];
        const stride = fstride[l] << plan.shift;
        switch (stage.p) {
            2 => bfly2(f, fstride[l]),
            3 => bfly3(f, stride, m, fstride[l], m2),
            4 => bfly4(f, stride, m, fstride[l], m2),
            5 => bfly5(f, stride, m, fstride[l], m2),
            else => unreachable,
        }
        m = m2;
    }
}

/// Inverse MDCT of one block with the 120 sample window overlap folded in (clt_mdct_backward).
/// The block has `960 >> shift` coefficients, read from `freq[i * stride]`. The output goes to
/// `out`, which needs `60 + (960 >> shift)` samples. Its first 60 samples hold the folded tail
/// of the block before, and the call leaves the final samples in `out[0..960 >> shift]` and the
/// new folded tail after them.
pub fn backward(freq: []const f32, stride: usize, out: []f32, shift: u2) void {
    const n = @as(usize, 1920) >> shift;
    const n2 = n >> 1;
    const n4 = n >> 2;
    const plan = plans[shift];
    std.debug.assert(plan.nfft == n4);
    std.debug.assert(out.len >= overlap / 2 + n2);
    std.debug.assert(freq.len > (n2 - 1) * stride);
    var trig_off: usize = 0;
    var size: usize = 1920;
    for (0..shift) |_| {
        size >>= 1;
        trig_off += size;
    }
    const t = tables.mdct_twiddles960[trig_off..][0..n2];

    var f: [480]Cpx = undefined;
    for (0..n4) |i| {
        const x1 = freq[2 * i * stride];
        const x2 = freq[(n2 - 1 - 2 * i) * stride];
        const yr = x2 * t[i] + x1 * t[n4 + i];
        const yi = x1 * t[i] - x2 * t[n4 + i];
        f[plan.bitrev[i]] = .{ .r = yi, .i = yr };
    }
    fftImpl(plan, f[0..n4]);

    const o = out[overlap / 2 ..][0..n2];
    for (0..(n4 + 1) >> 1) |i| {
        const j = n4 - 1 - i;
        var re = f[i].i;
        var im = f[i].r;
        var t0 = t[i];
        var t1 = t[n4 + i];
        const yr0 = re * t0 + im * t1;
        const yi0 = re * t1 - im * t0;
        re = f[j].i;
        im = f[j].r;
        o[2 * i] = yr0;
        o[2 * j + 1] = yi0;
        t0 = t[n4 - i - 1];
        t1 = t[n2 - i - 1];
        o[2 * j] = re * t0 + im * t1;
        o[2 * i + 1] = re * t1 - im * t0;
    }

    const w = &tables.window120;
    for (0..overlap / 2) |i| {
        const x1 = out[overlap - 1 - i];
        const x2 = out[i];
        out[i] = x2 * w[overlap - 1 - i] - x1 * w[i];
        out[overlap - 1 - i] = x2 * w[i] + x1 * w[overlap - 1 - i];
    }
}

/// Forward MDCT of one block with the 120 sample window overlap folded in (clt_mdct_forward).
/// `input` holds `(960 >> shift) + 120` samples. The `960 >> shift` coefficients go to
/// `out[i * stride]`.
pub fn forward(input: []const f32, out: []f32, stride: usize, shift: u2) void {
    const n = @as(usize, 1920) >> shift;
    const n2 = n >> 1;
    const n4 = n >> 2;
    const plan = plans[shift];
    std.debug.assert(plan.nfft == n4);
    std.debug.assert(input.len >= n2 + overlap);
    std.debug.assert(out.len > (n2 - 1) * stride);
    var trig_off: usize = 0;
    var size: usize = 1920;
    for (0..shift) |_| {
        size >>= 1;
        trig_off += size;
    }
    const t = tables.mdct_twiddles960[trig_off..][0..n2];
    const w = &tables.window120;
    const scale: f32 = 1.0 / @as(f32, @floatFromInt(n4));

    var f: [960]f32 = undefined;
    const half = overlap >> 1;
    const edge = (overlap + 3) >> 2;
    var xp1: usize = half;
    var xp2: usize = n2 - 1 + half;
    var wp1: usize = half;
    var wp2: usize = half - 1;
    var yp: usize = 0;
    var i: usize = 0;
    while (i < edge) : (i += 1) {
        f[yp] = input[xp1 + n2] * w[wp2] + input[xp2] * w[wp1];
        f[yp + 1] = input[xp1] * w[wp1] - input[xp2 - n2] * w[wp2];
        yp += 2;
        xp1 += 2;
        xp2 -%= 2;
        wp1 += 2;
        wp2 -%= 2;
    }
    while (i < n4 - edge) : (i += 1) {
        f[yp] = input[xp2];
        f[yp + 1] = input[xp1];
        yp += 2;
        xp1 += 2;
        xp2 -%= 2;
    }
    wp1 = 0;
    wp2 = overlap - 1;
    while (i < n4) : (i += 1) {
        f[yp] = -input[xp1 - n2] * w[wp1] + input[xp2] * w[wp2];
        f[yp + 1] = input[xp1] * w[wp2] + input[xp2 + n2] * w[wp1];
        yp += 2;
        xp1 += 2;
        xp2 -%= 2;
        wp1 += 2;
        wp2 -%= 2;
    }

    var f2: [480]Cpx = undefined;
    for (0..n4) |k| {
        const t0 = t[k];
        const t1 = t[n4 + k];
        const re = f[2 * k];
        const im = f[2 * k + 1];
        const yr = re * t0 - im * t1;
        const yi = im * t0 + re * t1;
        f2[plan.bitrev[k]] = .{ .r = yr * scale, .i = yi * scale };
    }
    fftImpl(plan, f2[0..n4]);

    for (0..n4) |k| {
        const t0 = t[k];
        const t1 = t[n4 + k];
        out[2 * k * stride] = f2[k].i * t1 - f2[k].r * t0;
        out[(n2 - 1 - 2 * k) * stride] = f2[k].r * t1 + f2[k].i * t0;
    }
}

const testing = std.testing;

fn lcg(s: *u32) f32 {
    s.* = s.* *% 1664525 +% 1013904223;
    return @as(f32, @floatFromInt(@as(i32, @bitCast(s.*)) >> 8)) / 8388608.0;
}

test "fft matches a direct transform" {
    var seed: u32 = 7;
    for (plans) |plan| {
        var x: [480]Cpx = undefined;
        var f: [480]Cpx = undefined;
        for (0..plan.nfft) |i| {
            x[i] = .{ .r = lcg(&seed), .i = lcg(&seed) };
            f[plan.bitrev[i]] = x[i];
        }
        fftImpl(plan, f[0..plan.nfft]);
        for (0..plan.nfft) |k| {
            var re: f64 = 0;
            var im: f64 = 0;
            for (0..plan.nfft) |i| {
                const a = -2.0 * std.math.pi * @as(f64, @floatFromInt(i * k % plan.nfft)) / @as(f64, @floatFromInt(plan.nfft));
                re += x[i].r * @cos(a) - x[i].i * @sin(a);
                im += x[i].r * @sin(a) + x[i].i * @cos(a);
            }
            try testing.expectApproxEqAbs(@as(f32, @floatCast(re)), f[k].r, 2e-4);
            try testing.expectApproxEqAbs(@as(f32, @floatCast(im)), f[k].i, 2e-4);
        }
    }
}

/// The unwindowed inverse transform of the textbook definition, with 2L outputs.
fn directInverse(coef: []const f32, y: []f64) void {
    const l = coef.len;
    for (0..2 * l) |n| {
        var sum: f64 = 0;
        for (0..l) |k| {
            const a = std.math.pi / @as(f64, @floatFromInt(l)) * (@as(f64, @floatFromInt(n)) + 0.5 + @as(f64, @floatFromInt(l)) / 2.0) * (@as(f64, @floatFromInt(k)) + 0.5);
            sum += coef[k] * @cos(a);
        }
        y[n] = sum;
    }
}

test "backward matches the textbook inverse with overlap add" {
    var seed: u32 = 99;
    inline for (.{ 0, 1, 2, 3 }) |shift| {
        const l = 960 >> shift;
        const z = (l - 120) / 2;
        var coef: [2][l]f32 = undefined;
        for (&coef) |*blk| for (blk) |*c| {
            c.* = lcg(&seed);
        };
        var wf: [2 * l]f64 = undefined;
        for (0..2 * l) |n| {
            wf[n] = if (n < z) 0 else if (n < z + 120) tables.window120[n - z] else if (n < z + l) 1 else if (n < z + l + 120) tables.window120[z + l + 119 - n] else 0;
        }
        var ya: [2 * l]f64 = undefined;
        var yb: [2 * l]f64 = undefined;
        directInverse(&coef[0], &ya);
        directInverse(&coef[1], &yb);

        var buf: [2 * l + 120]f32 = @splat(0);
        backward(&coef[0], 1, buf[0..], shift);
        // The second block starts one block later and keeps the folded tail in place.
        backward(&coef[1], 1, buf[l..], shift);
        // Output sample j of the second block is textbook sample j + L/2 - 60.
        const off = l / 2 - 60;
        var worst: f64 = 0;
        for (0..l) |j| {
            const n = j + off;
            const a = if (n + l < 2 * l) wf[n + l] * ya[n + l] else 0;
            worst = @max(worst, @abs(a + wf[n] * yb[n] - buf[l + j]));
        }
        try testing.expect(worst < 5e-3);
    }
}

test "forward matches the textbook transform with overlap windowing" {
    var seed: u32 = 77;
    inline for (.{ 0, 1, 2, 3 }) |shift| {
        const l = 960 >> shift;
        const z = (l - 120) / 2;
        var input: [l + 120]f32 = undefined;
        for (&input) |*v| v.* = lcg(&seed);
        var out: [l]f32 = undefined;
        forward(&input, &out, 1, shift);
        var worst: f64 = 0;
        for (0..l) |k| {
            var sum: f64 = 0;
            for (0..l + 120) |j| {
                const n = j + z;
                const wj = if (j < 120) tables.window120[j] else if (j < l) 1.0 else tables.window120[l + 119 - j];
                const a = std.math.pi / @as(f64, l) * (@as(f64, @floatFromInt(n)) + 0.5 + @as(f64, l) / 2.0) * (@as(f64, @floatFromInt(k)) + 0.5);
                sum += wj * input[j] * @cos(a);
            }
            worst = @max(worst, @abs(sum * 2.0 / @as(f64, l) - out[k]));
        }
        try testing.expect(worst < 2e-4);
    }
}
