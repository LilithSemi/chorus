//! CELT band shape coding, ported from libopus celt/bands.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const range = @import("../range.zig");
const tables = @import("tables.zig");
const rate = @import("rate.zig");
const cwrs = @import("cwrs.zig");
const vq = @import("vq.zig");
const energy = @import("energy.zig");

const nb = tables.nb_ebands;
const eb = tables.eband5ms;
const bitres = 3;
/// The most coefficients of one channel below the last band.
const norm_len = 8 * 78;
const half_sqrt2: f32 = 0.70710678;

pub const Error = cwrs.Error;

pub fn lcg(seed: u32) u32 {
    return 1664525 *% seed +% 1013904223;
}

fn fracMul16(a: i32, b: i32) i32 {
    const x: i32 = @as(i16, @truncate(a));
    const y: i32 = @as(i16, @truncate(b));
    return (16384 + x * y) >> 15;
}

/// A cosine that gives the same bits on every platform, for x from 1 to 16383.
fn bitexactCos(x: i32) i32 {
    const xt: i32 = @as(i16, @truncate(x));
    const tmp = (4096 + xt * xt) >> 13;
    const x2: i32 = @as(i16, @truncate(tmp));
    const r: i32 = @as(i16, @truncate((32767 - x2) + fracMul16(x2, -7651 + fracMul16(x2, 8277 + fracMul16(-626, x2)))));
    return @as(i16, @truncate(1 + r));
}

fn bitexactLog2Tan(isin_in: i32, icos_in: i32) i32 {
    const lc = range.ilog(@intCast(icos_in));
    const ls = range.ilog(@intCast(isin_in));
    const icos = icos_in << @intCast(15 - lc);
    const isin = isin_in << @intCast(15 - ls);
    return (ls - lc) * 2048 + fracMul16(isin, fracMul16(isin, -2597) + 7932) - fracMul16(icos, fracMul16(icos, -2597) + 7932);
}

/// floor(sqrt(v)) for v greater than 0.
fn isqrt32(v_in: u32) u32 {
    var v = v_in;
    var g: u32 = 0;
    var bshift: i32 = (range.ilog(v) - 1) >> 1;
    var b: u32 = @as(u32, 1) << @intCast(bshift);
    while (true) {
        const t = ((g << 1) +% b) << @intCast(bshift);
        if (t <= v) {
            g += b;
            v -= t;
        }
        b >>= 1;
        bshift -= 1;
        if (bshift < 0) break;
    }
    return g;
}

pub fn haar1(x: []f32, n0_in: usize, stride: usize) void {
    const n0 = n0_in >> 1;
    for (0..stride) |i| {
        for (0..n0) |j| {
            const t1 = half_sqrt2 * x[stride * 2 * j + i];
            const t2 = half_sqrt2 * x[stride * (2 * j + 1) + i];
            x[stride * 2 * j + i] = t1 + t2;
            x[stride * (2 * j + 1) + i] = t1 - t2;
        }
    }
}

fn deinterleaveHadamard(x: []f32, n0: usize, stride: usize, hadamard: bool) void {
    var tmp: [vq.max_dim]f32 = undefined;
    const n = n0 * stride;
    if (hadamard) {
        const ordery = tables.ordery_table[stride - 2 ..];
        for (0..stride) |i| {
            for (0..n0) |j| tmp[ordery[i] * n0 + j] = x[j * stride + i];
        }
    } else {
        for (0..stride) |i| {
            for (0..n0) |j| tmp[i * n0 + j] = x[j * stride + i];
        }
    }
    @memcpy(x[0..n], tmp[0..n]);
}

fn interleaveHadamard(x: []f32, n0: usize, stride: usize, hadamard: bool) void {
    var tmp: [vq.max_dim]f32 = undefined;
    const n = n0 * stride;
    if (hadamard) {
        const ordery = tables.ordery_table[stride - 2 ..];
        for (0..stride) |i| {
            for (0..n0) |j| tmp[j * stride + i] = x[ordery[i] * n0 + j];
        }
    } else {
        for (0..stride) |i| {
            for (0..n0) |j| tmp[j * stride + i] = x[i * n0 + j];
        }
    }
    @memcpy(x[0..n], tmp[0..n]);
}

fn computeQn(n: i32, b: i32, offset: i32, pulse_cap: i32, stereo: bool) i32 {
    var n2 = 2 * n - 1;
    if (stereo and n == 2) n2 -= 1;
    var qb = @divTrunc(b + n2 * offset, n2);
    qb = @min(b - pulse_cap - (4 << bitres), qb);
    qb = @min(8 << bitres, qb);
    if (qb < (1 << bitres >> 1)) return 1;
    const qn: i32 = @as(i32, tables.exp2_table8[@intCast(qb & 7)]) >> @intCast(14 - (qb >> bitres));
    return (qn + 1) >> 1 << 1;
}

/// The range coder of a band: the decoder when decoding, the encoder when encoding.
pub const Coder = union(enum) { dec: *range.Decoder, enc: *range.Encoder };

const Ctx = struct {
    coder: Coder,
    band: usize,
    intensity: i32,
    spread: vq.Spread,
    tf_change: i32,
    remaining_bits: i32,
    seed: u32,
    disable_inv: bool,
    /// Encoder only: the band amplitudes of both channels.
    band_e: ?*const [2 * nb]f32 = null,
    /// Encoder only: the first band of a short block frame avoids a split with noise.
    avoid_split_noise: bool = false,
    scratch: [vq.max_dim]f32 = undefined,

    fn tellFrac(self: *const Ctx) u32 {
        return switch (self.coder) {
            .dec => |d| d.tellFrac(),
            .enc => |e| e.tellFrac(),
        };
    }

    fn encoding(self: *const Ctx) bool {
        return self.coder == .enc;
    }
};

const Split = struct {
    inv: bool,
    imid: i32,
    iside: i32,
    delta: i32,
    itheta: i32,
    qalloc: i32,
};

/// Replaces the left and right bands by one band that holds both (intensity_stereo).
fn intensityStereo(x: []f32, y: []const f32, band_e: *const [2 * nb]f32, band: usize) void {
    const left = band_e[band];
    const right = band_e[nb + band];
    const norm = 1e-15 + @sqrt(1e-15 + left * left + right * right);
    const a1 = left / norm;
    const a2 = right / norm;
    for (x, y) |*xv, yv| xv.* = a1 * xv.* + a2 * yv;
}

fn stereoSplit(x: []f32, y: []f32) void {
    for (x, y) |*xv, *yv| {
        const l = half_sqrt2 * xv.*;
        const r = half_sqrt2 * yv.*;
        xv.* = l + r;
        yv.* = r - l;
    }
}

fn computeTheta(ctx: *Ctx, x: []f32, y: []f32, n: i32, b: *i32, bb: u32, b0: u32, lm: i32, stereo: bool, fill: *u32) Split {
    const pulse_cap: i32 = tables.logN400[ctx.band] + lm * (1 << bitres);
    const offset = (pulse_cap >> 1) - (if (stereo and n == 2) @as(i32, 16) else 4);
    var qn = computeQn(n, b.*, offset, pulse_cap, stereo);
    if (stereo and @as(i32, @intCast(ctx.band)) >= ctx.intensity) qn = 1;
    var itheta: i32 = 0;
    if (ctx.encoding()) itheta = vq.stereoItheta(x, y, stereo) >> 16;
    const tell: i32 = @intCast(ctx.tellFrac());
    var inv = false;
    if (qn != 1) {
        switch (ctx.coder) {
            .enc => |enc| {
                itheta = (itheta * qn + 8192) >> 14;
                if (!stereo and ctx.avoid_split_noise and itheta > 0 and itheta < qn) {
                    const unquantized = @divTrunc(itheta * 16384, qn);
                    const imid = bitexactCos(unquantized);
                    const iside = bitexactCos(16384 - unquantized);
                    const delta = fracMul16((n - 1) << 7, bitexactLog2Tan(iside, imid));
                    if (delta > b.*) {
                        itheta = qn;
                    } else if (delta < -b.*) {
                        itheta = 0;
                    }
                }
                if (stereo and n > 2) {
                    const p0: i32 = 3;
                    const x0 = qn >> 1;
                    const ft = p0 * (x0 + 1) + x0;
                    const fl = if (itheta <= x0) p0 * itheta else (itheta - 1 - x0) + (x0 + 1) * p0;
                    const fh = if (itheta <= x0) p0 * (itheta + 1) else (itheta - x0) + (x0 + 1) * p0;
                    enc.encode(@intCast(fl), @intCast(fh), @intCast(ft));
                } else if (b0 > 1 or stereo) {
                    enc.encodeUint(@intCast(itheta), @intCast(qn + 1));
                } else {
                    const h = qn >> 1;
                    const ft = (h + 1) * (h + 1);
                    const fs = if (itheta <= h) itheta + 1 else qn + 1 - itheta;
                    const fl = if (itheta <= h) itheta * (itheta + 1) >> 1 else ft - ((qn + 1 - itheta) * (qn + 2 - itheta) >> 1);
                    enc.encode(@intCast(fl), @intCast(fl + fs), @intCast(ft));
                }
                itheta = @divTrunc(itheta * 16384, qn);
                if (stereo) {
                    if (itheta == 0) {
                        intensityStereo(x, y, ctx.band_e.?, ctx.band);
                    } else {
                        stereoSplit(x, y);
                    }
                }
            },
            .dec => |dec| {
                if (stereo and n > 2) {
                    const p0: i32 = 3;
                    const x0 = qn >> 1;
                    const ft = p0 * (x0 + 1) + x0;
                    const fs: i32 = @intCast(dec.decode(@intCast(ft)));
                    const xv = if (fs < (x0 + 1) * p0) @divTrunc(fs, p0) else x0 + 1 + (fs - (x0 + 1) * p0);
                    const fl = if (xv <= x0) p0 * xv else (xv - 1 - x0) + (x0 + 1) * p0;
                    const fh = if (xv <= x0) p0 * (xv + 1) else (xv - x0) + (x0 + 1) * p0;
                    dec.update(@intCast(fl), @intCast(fh), @intCast(ft));
                    itheta = xv;
                } else if (b0 > 1 or stereo) {
                    itheta = @intCast(dec.uint(@intCast(qn + 1)));
                } else {
                    const h = qn >> 1;
                    const ft = (h + 1) * (h + 1);
                    const fm: i32 = @intCast(dec.decode(@intCast(ft)));
                    var fl: i32 = undefined;
                    var fs: i32 = undefined;
                    if (fm < (h * (h + 1) >> 1)) {
                        itheta = @as(i32, @intCast(isqrt32(@intCast(8 * fm + 1)))) - 1 >> 1;
                        fs = itheta + 1;
                        fl = itheta * (itheta + 1) >> 1;
                    } else {
                        itheta = (2 * (qn + 1) - @as(i32, @intCast(isqrt32(@intCast(8 * (ft - fm - 1) + 1))))) >> 1;
                        fs = qn + 1 - itheta;
                        fl = ft - ((qn + 1 - itheta) * (qn + 2 - itheta) >> 1);
                    }
                    dec.update(@intCast(fl), @intCast(fl + fs), @intCast(ft));
                }
                itheta = @divTrunc(itheta * 16384, qn);
            },
        }
    } else if (stereo) {
        switch (ctx.coder) {
            .enc => |enc| {
                inv = itheta > 8192 and !ctx.disable_inv;
                if (inv) {
                    for (y) |*v| v.* = -v.*;
                }
                intensityStereo(x, y, ctx.band_e.?, ctx.band);
                if (b.* > (2 << bitres) and ctx.remaining_bits > (2 << bitres)) {
                    enc.encodeBitLogp(inv, 2);
                } else {
                    inv = false;
                }
            },
            .dec => |dec| {
                if (b.* > (2 << bitres) and ctx.remaining_bits > (2 << bitres)) inv = dec.bitLogp(2);
            },
        }
        if (ctx.disable_inv) inv = false;
        itheta = 0;
    }
    const qalloc = @as(i32, @intCast(ctx.tellFrac())) - tell;
    b.* -= qalloc;

    var imid: i32 = undefined;
    var iside: i32 = undefined;
    var delta: i32 = undefined;
    const bmask = (@as(u32, 1) << @intCast(bb)) - 1;
    if (itheta == 0) {
        imid = 32767;
        iside = 0;
        fill.* &= bmask;
        delta = -16384;
    } else if (itheta == 16384) {
        imid = 0;
        iside = 32767;
        fill.* &= bmask << @intCast(bb);
        delta = 16384;
    } else {
        imid = bitexactCos(itheta);
        iside = bitexactCos(16384 - itheta);
        delta = fracMul16((n - 1) << 7, bitexactLog2Tan(iside, imid));
    }
    return .{ .inv = inv, .imid = imid, .iside = iside, .delta = delta, .itheta = itheta, .qalloc = qalloc };
}

fn quantBandN1(ctx: *Ctx, x: []f32, y: ?[]f32, lowband_out: ?[]f32) u32 {
    var cur = x;
    for (0..if (y != null) @as(usize, 2) else 1) |c| {
        var sign: u32 = 0;
        if (ctx.remaining_bits >= 1 << bitres) {
            switch (ctx.coder) {
                .enc => |enc| {
                    sign = @intFromBool(cur[0] < 0);
                    enc.encodeBits(sign, 1);
                },
                .dec => |dec| sign = dec.bits(1),
            }
            ctx.remaining_bits -= 1 << bitres;
        }
        if (!ctx.encoding()) cur[0] = if (sign != 0) -1.0 else 1.0;
        if (c == 0 and y != null) cur = y.?;
    }
    if (lowband_out) |o| o[0] = x[0];
    return 1;
}

fn cacheMax(band: usize, lm: i32) i32 {
    const idx: usize = @intCast(tables.cache_index50[@as(usize, @intCast(lm + 1)) * nb + band]);
    const cache = tables.cache_bits50[idx..];
    return cache[cache[0]];
}

fn quantPartition(ctx: *Ctx, x: []f32, b_in: i32, bb_in: u32, lowband: ?[]f32, lm_in: i32, gain: f32, fill_in: u32) Error!u32 {
    var n: i32 = @intCast(x.len);
    var b = b_in;
    var fill = fill_in;
    var lm = lm_in;
    var bb = bb_in;
    const b0 = bb_in;
    if (lm != -1 and b > cacheMax(ctx.band, lm) + 12 and n > 2) {
        n >>= 1;
        const half: usize = @intCast(n);
        const xa = x[0..half];
        const ya = x[half..][0..half];
        lm -= 1;
        if (bb == 1) fill = (fill & 1) | (fill << 1);
        bb = (bb + 1) >> 1;
        const sp = computeTheta(ctx, xa, ya, n, &b, bb, b0, lm, false, &fill);
        const mid: f32 = (1.0 / 32768.0) * @as(f32, @floatFromInt(sp.imid));
        const side: f32 = (1.0 / 32768.0) * @as(f32, @floatFromInt(sp.iside));
        var delta = sp.delta;
        if (b0 > 1 and (sp.itheta & 0x3fff) != 0) {
            if (sp.itheta > 8192) {
                delta -= delta >> @intCast(4 - lm);
            } else {
                delta = @min(0, delta + (n << bitres >> @intCast(5 - lm)));
            }
        }
        var mbits: i32 = @max(0, @min(b, @divTrunc(b - delta, 2)));
        var sbits: i32 = b - mbits;
        ctx.remaining_bits -= sp.qalloc;
        const next_lowband2: ?[]f32 = if (lowband) |lb| lb[half..] else null;
        var rebalance = ctx.remaining_bits;
        const hi_shift: u5 = @intCast(b0 >> 1);
        const fill_hi = fill >> @intCast(bb);
        var cm: u32 = undefined;
        if (mbits >= sbits) {
            cm = try quantPartition(ctx, xa, mbits, bb, lowband, lm, gain * mid, fill);
            rebalance = mbits - (rebalance - ctx.remaining_bits);
            if (rebalance > 3 << bitres and sp.itheta != 0) sbits += rebalance - (3 << bitres);
            cm |= (try quantPartition(ctx, ya, sbits, bb, next_lowband2, lm, gain * side, fill_hi)) << hi_shift;
        } else {
            cm = (try quantPartition(ctx, ya, sbits, bb, next_lowband2, lm, gain * side, fill_hi)) << hi_shift;
            rebalance = sbits - (rebalance - ctx.remaining_bits);
            if (rebalance > 3 << bitres and sp.itheta != 16384) mbits += rebalance - (3 << bitres);
            cm |= try quantPartition(ctx, xa, mbits, bb, lowband, lm, gain * mid, fill);
        }
        return cm;
    }
    var q = rate.bitsToPulses(ctx.band, lm, b);
    var curr_bits = rate.pulsesToBits(ctx.band, lm, q);
    ctx.remaining_bits -= curr_bits;
    while (ctx.remaining_bits < 0 and q > 0) {
        ctx.remaining_bits += curr_bits;
        q -= 1;
        curr_bits = rate.pulsesToBits(ctx.band, lm, q);
        ctx.remaining_bits -= curr_bits;
    }
    if (q != 0) {
        const k = tables.getPulses(q);
        return switch (ctx.coder) {
            .dec => |dec| try vq.algUnquant(x, k, ctx.spread, bb, dec, gain),
            .enc => |enc| vq.algQuant(x, k, ctx.spread, bb, enc),
        };
    }
    if (ctx.encoding()) return 0;
    const cm_mask = (@as(u32, 1) << @intCast(bb)) - 1;
    fill &= cm_mask;
    if (fill == 0) {
        @memset(x, 0);
        return 0;
    }
    var cm: u32 = undefined;
    if (lowband) |lb| {
        for (x, 0..) |*v, j| {
            ctx.seed = lcg(ctx.seed);
            const tmp: f32 = if (ctx.seed & 0x8000 != 0) 1.0 / 256.0 else -1.0 / 256.0;
            v.* = lb[j] + tmp;
        }
        cm = fill;
    } else {
        for (x) |*v| {
            ctx.seed = lcg(ctx.seed);
            v.* = @floatFromInt(@as(i32, @bitCast(ctx.seed)) >> 20);
        }
        cm = cm_mask;
    }
    vq.renormaliseVector(x, gain);
    return cm;
}

fn quantBand(ctx: *Ctx, x: []f32, b: i32, bb_in: u32, lowband_in: ?[]f32, lm: i32, lowband_out: ?[]f32, gain: f32, fill_in: u32) Error!u32 {
    const n0 = x.len;
    var bb = bb_in;
    var n_b = n0 / bb;
    var b0 = bb;
    var time_divide: u5 = 0;
    var recombine: u5 = 0;
    const long_blocks = b0 == 1;
    var fill = fill_in;
    if (n0 == 1) return quantBandN1(ctx, x, null, lowband_out);
    var tf_change = ctx.tf_change;
    if (tf_change > 0) recombine = @intCast(tf_change);
    var lowband = lowband_in;
    if (lowband != null and (recombine != 0 or ((n_b & 1) == 0 and tf_change < 0) or b0 > 1)) {
        @memcpy(ctx.scratch[0..n0], lowband.?[0..n0]);
        lowband = ctx.scratch[0..n0];
    }
    for (0..recombine) |k| {
        if (ctx.encoding()) haar1(x, n0 >> @intCast(k), @as(usize, 1) << @intCast(k));
        if (lowband) |lb| haar1(lb, n0 >> @intCast(k), @as(usize, 1) << @intCast(k));
        fill = @as(u32, tables.bit_interleave_table[fill & 15]) | @as(u32, tables.bit_interleave_table[(fill >> 4) & 15]) << 2;
    }
    bb >>= recombine;
    n_b <<= recombine;
    while ((n_b & 1) == 0 and tf_change < 0) {
        if (ctx.encoding()) haar1(x, n_b, bb);
        if (lowband) |lb| haar1(lb, n_b, bb);
        fill |= fill << @intCast(bb);
        bb <<= 1;
        n_b >>= 1;
        time_divide += 1;
        tf_change += 1;
    }
    b0 = bb;
    const n_b0 = n_b;
    if (b0 > 1) {
        if (ctx.encoding()) deinterleaveHadamard(x, n_b >> recombine, @as(usize, b0) << recombine, long_blocks);
        if (lowband) |lb| deinterleaveHadamard(lb, n_b >> recombine, @as(usize, b0) << recombine, long_blocks);
    }
    var cm = try quantPartition(ctx, x, b, bb, lowband, lm, gain, fill);
    if (ctx.encoding()) return cm;

    if (b0 > 1) interleaveHadamard(x, n_b0 >> recombine, @as(usize, b0) << recombine, long_blocks);
    n_b = n_b0;
    bb = b0;
    for (0..time_divide) |_| {
        bb >>= 1;
        n_b <<= 1;
        cm |= cm >> @intCast(bb);
        haar1(x, n_b, bb);
    }
    for (0..recombine) |k| {
        cm = tables.bit_deinterleave_table[cm & 15];
        haar1(x, n0 >> @intCast(k), @as(usize, 1) << @intCast(k));
    }
    bb <<= recombine;
    if (lowband_out) |o| {
        const nn: f32 = @sqrt(@as(f32, @floatFromInt(n0)));
        for (x, 0..) |v, j| o[j] = nn * v;
    }
    return cm & ((@as(u32, 1) << @intCast(bb)) - 1);
}

fn dot(a: []const f32, b: []const f32) f32 {
    var sum: f32 = 0;
    for (a, b) |p, q| sum += p * q;
    return sum;
}

fn stereoMerge(x: []f32, y: []f32, mid: f32) void {
    var xp = dot(y, x);
    const side = dot(y, y);
    xp = mid * xp;
    const el = mid * mid + side - 2 * xp;
    const er = mid * mid + side + 2 * xp;
    if (er < 6e-4 or el < 6e-4) {
        @memcpy(y, x);
        return;
    }
    const lgain = 1.0 / @sqrt(el);
    const rgain = 1.0 / @sqrt(er);
    for (x, y) |*xv, *yv| {
        const l = mid * xv.*;
        const r = yv.*;
        xv.* = lgain * (l - r);
        yv.* = rgain * (l + r);
    }
}

fn quantBandStereo(ctx: *Ctx, x: []f32, y: []f32, b_in: i32, bb: u32, lowband: ?[]f32, lm: i32, lowband_out: ?[]f32, fill_in: u32) Error!u32 {
    const n: i32 = @intCast(x.len);
    if (n == 1) return quantBandN1(ctx, x, y, lowband_out);
    var b = b_in;
    var fill = fill_in;
    const orig_fill = fill;
    if (ctx.band_e) |be| {
        const quiet = 1e-10;
        if (be[ctx.band] < quiet or be[nb + ctx.band] < quiet) {
            if (be[ctx.band] > be[nb + ctx.band]) @memcpy(y, x) else @memcpy(x, y);
        }
    }
    const sp = computeTheta(ctx, x, y, n, &b, bb, bb, lm, true, &fill);
    const mid: f32 = (1.0 / 32768.0) * @as(f32, @floatFromInt(sp.imid));
    const side: f32 = (1.0 / 32768.0) * @as(f32, @floatFromInt(sp.iside));
    var cm: u32 = undefined;
    if (n == 2) {
        const sbits: i32 = if (sp.itheta != 0 and sp.itheta != 16384) 1 << bitres else 0;
        const mbits = b - sbits;
        const c = sp.itheta > 8192;
        ctx.remaining_bits -= sp.qalloc + sbits;
        const x2 = if (c) y else x;
        const y2 = if (c) x else y;
        var sign: i32 = 0;
        if (sbits != 0) {
            switch (ctx.coder) {
                .enc => |enc| {
                    sign = @intFromBool(x2[0] * y2[1] - x2[1] * y2[0] < 0);
                    enc.encodeBits(@intCast(sign), 1);
                },
                .dec => |dec| sign = @intCast(dec.bits(1)),
            }
        }
        sign = 1 - 2 * sign;
        cm = try quantBand(ctx, x2, mbits, bb, lowband, lm, lowband_out, 1.0, orig_fill);
        if (ctx.encoding()) return cm;
        const sf: f32 = @floatFromInt(sign);
        y2[0] = -sf * x2[1];
        y2[1] = sf * x2[0];
        x[0] = mid * x[0];
        x[1] = mid * x[1];
        y[0] = side * y[0];
        y[1] = side * y[1];
        var t = x[0];
        x[0] = t - y[0];
        y[0] = t + y[0];
        t = x[1];
        x[1] = t - y[1];
        y[1] = t + y[1];
    } else {
        var mbits: i32 = @max(0, @min(b, @divTrunc(b - sp.delta, 2)));
        var sbits: i32 = b - mbits;
        ctx.remaining_bits -= sp.qalloc;
        var rebalance = ctx.remaining_bits;
        const fill_hi = fill >> @intCast(bb);
        if (mbits >= sbits) {
            cm = try quantBand(ctx, x, mbits, bb, lowband, lm, lowband_out, 1.0, fill);
            rebalance = mbits - (rebalance - ctx.remaining_bits);
            if (rebalance > 3 << bitres and sp.itheta != 0) sbits += rebalance - (3 << bitres);
            cm |= try quantBand(ctx, y, sbits, bb, null, lm, null, side, fill_hi);
        } else {
            cm = try quantBand(ctx, y, sbits, bb, null, lm, null, side, fill_hi);
            rebalance = sbits - (rebalance - ctx.remaining_bits);
            if (rebalance > 3 << bitres and sp.itheta != 16384) mbits += rebalance - (3 << bitres);
            cm |= try quantBand(ctx, x, mbits, bb, lowband, lm, lowband_out, 1.0, fill);
        }
        if (ctx.encoding()) return cm;
        stereoMerge(x, y, mid);
    }
    if (sp.inv) {
        for (y) |*v| v.* = -v.*;
    }
    return cm;
}

pub const Params = struct {
    start: u32,
    end: u32,
    lm: u32,
    channels: u32,
    short_blocks: bool,
    spread: vq.Spread,
    dual_stereo: bool,
    intensity: i32,
    tf_res: *const [nb]i32,
    pulses: *const [nb]i32,
    total_bits: i32,
    balance: i32,
    coded_bands: u32,
    disable_inv: bool,
};

fn specialHybridFolding(norm: *[2][norm_len]f32, start: usize, m: usize, dual_stereo: bool) void {
    const n1 = m * @as(usize, @intCast(eb[start + 1] - eb[start]));
    const n2 = m * @as(usize, @intCast(eb[start + 2] - eb[start + 1]));
    if (n2 <= n1) return;
    const chans: usize = if (dual_stereo) 2 else 1;
    for (0..chans) |c| @memcpy(norm[c][n1..n2], norm[c][2 * n1 - n2 .. n1]);
}

/// Decodes the shapes of all bands of a frame into `x`, which holds the `channels` channels
/// of `120 << lm` coefficients one after the other (quant_all_bands).
pub fn quantAllBands(p: Params, x_all: []f32, collapse_masks: *[2 * nb]u8, dec: *range.Decoder, seed: *u32) Error!void {
    const lm: i32 = @intCast(p.lm);
    const m: i32 = @as(i32, 1) << @intCast(p.lm);
    const bb: u32 = if (p.short_blocks) @intCast(m) else 1;
    const chans: usize = p.channels;
    const n_total: usize = @as(usize, 120) << @intCast(p.lm);
    std.debug.assert(x_all.len == chans * n_total);
    std.debug.assert(p.start < p.end and p.end <= nb);
    const start: usize = p.start;
    const end: usize = p.end;
    const norm_offset: i32 = m * eb[start];
    var norm: [2][norm_len]f32 = @splat(@splat(0));

    var ctx: Ctx = .{
        .coder = .{ .dec = dec },
        .band = 0,
        .intensity = p.intensity,
        .spread = p.spread,
        .tf_change = 0,
        .remaining_bits = 0,
        .seed = seed.*,
        .disable_inv = p.disable_inv,
    };
    var balance = p.balance;
    var dual_stereo = p.dual_stereo;
    var lowband_offset: usize = 0;
    var update_lowband = true;

    for (start..end) |i| {
        ctx.band = i;
        const last = i == end - 1;
        const edge: usize = @intCast(m * eb[i]);
        const n: usize = @intCast(m * (eb[i + 1] - eb[i]));
        const xs = x_all[edge..][0..n];
        const ys: ?[]f32 = if (chans == 2) x_all[n_total + edge ..][0..n] else null;
        const tell: i32 = @intCast(dec.tellFrac());
        if (i != start) balance -= tell;
        const remaining = p.total_bits - tell - 1;
        ctx.remaining_bits = remaining;
        var b: i32 = 0;
        if (i < p.coded_bands) {
            const curr_balance = @divTrunc(balance, @as(i32, @intCast(@min(3, p.coded_bands - i))));
            b = @max(0, @min(16383, @min(remaining + 1, p.pulses[i] + curr_balance)));
        }
        const ni: i32 = @intCast(n);
        if ((m * eb[i] - ni >= m * eb[start] or i == start + 1) and (update_lowband or lowband_offset == 0)) {
            lowband_offset = i;
        }
        if (i == start + 1) specialHybridFolding(&norm, start, @intCast(m), dual_stereo);

        const tf_change = p.tf_res[i];
        ctx.tf_change = tf_change;

        var effective_lowband: i32 = -1;
        var x_cm: u32 = undefined;
        var y_cm: u32 = undefined;
        if (lowband_offset != 0 and (p.spread != .aggressive or bb > 1 or tf_change < 0)) {
            effective_lowband = @max(0, m * eb[lowband_offset] - norm_offset - ni);
            var fold_start: usize = lowband_offset;
            while (true) {
                fold_start -= 1;
                if (!(m * eb[fold_start] > effective_lowband + norm_offset)) break;
            }
            var fold_end: usize = lowband_offset - 1;
            while (true) {
                fold_end += 1;
                if (!(fold_end < i and m * eb[fold_end] < effective_lowband + norm_offset + ni)) break;
            }
            x_cm = 0;
            y_cm = 0;
            var f = fold_start;
            while (true) {
                x_cm |= collapse_masks[f * chans];
                y_cm |= collapse_masks[f * chans + chans - 1];
                f += 1;
                if (f >= fold_end) break;
            }
        } else {
            x_cm = (@as(u32, 1) << @intCast(bb)) - 1;
            y_cm = x_cm;
        }

        if (dual_stereo and @as(i32, @intCast(i)) == p.intensity) {
            dual_stereo = false;
            const count: usize = @intCast(m * eb[i] - norm_offset);
            for (0..count) |j| norm[0][j] = 0.5 * (norm[0][j] + norm[1][j]);
        }

        const eff: usize = if (effective_lowband != -1) @intCast(effective_lowband) else 0;
        const have_low = effective_lowband != -1;
        const lb: ?[]f32 = if (have_low) norm[0][eff..] else null;
        const lb2: ?[]f32 = if (have_low) norm[1][eff..] else null;
        const out_pos: usize = @intCast(m * eb[i] - norm_offset);
        const out: ?[]f32 = if (last) null else norm[0][out_pos..];
        const out2: ?[]f32 = if (last) null else norm[1][out_pos..];

        if (dual_stereo) {
            x_cm = try quantBand(&ctx, xs, @divTrunc(b, 2), bb, lb, lm, out, 1.0, x_cm);
            y_cm = try quantBand(&ctx, ys.?, @divTrunc(b, 2), bb, lb2, lm, out2, 1.0, y_cm);
        } else if (ys) |yv| {
            x_cm = try quantBandStereo(&ctx, xs, yv, b, bb, lb, lm, out, x_cm | y_cm);
            y_cm = x_cm;
        } else {
            x_cm = try quantBand(&ctx, xs, b, bb, lb, lm, out, 1.0, x_cm | y_cm);
            y_cm = x_cm;
        }
        collapse_masks[i * chans] = @truncate(x_cm);
        collapse_masks[i * chans + chans - 1] = @truncate(y_cm);
        balance += p.pulses[i] + tell;
        update_lowband = b > (ni << bitres);
    }
    seed.* = ctx.seed;
}

pub const EncodeParams = struct {
    start: u32,
    end: u32,
    lm: u32,
    channels: u32,
    short_blocks: bool,
    spread: vq.Spread,
    dual_stereo: bool,
    intensity: i32,
    tf_res: *const [nb]i32,
    pulses: *const [nb]i32,
    total_bits: i32,
    balance: i32,
    coded_bands: u32,
    disable_inv: bool,
    /// The amplitude of each band, channel `c` at `c * nb`.
    band_e: *const [2 * nb]f32,
};

/// Writes the shapes of all bands of a frame (quant_all_bands). `x_all` holds the `channels`
/// channels of `120 << lm` unit band coefficients one after the other. The call changes them.
pub fn quantAllBandsEncode(p: EncodeParams, x_all: []f32, enc: *range.Encoder) Error!void {
    const lm: i32 = @intCast(p.lm);
    const m: i32 = @as(i32, 1) << @intCast(p.lm);
    const bb: u32 = if (p.short_blocks) @intCast(m) else 1;
    const chans: usize = p.channels;
    const n_total: usize = @as(usize, 120) << @intCast(p.lm);
    std.debug.assert(x_all.len == chans * n_total);
    std.debug.assert(p.start < p.end and p.end <= nb);
    const start: usize = p.start;
    const end: usize = p.end;
    var ctx: Ctx = .{
        .coder = .{ .enc = enc },
        .band = 0,
        .intensity = p.intensity,
        .spread = p.spread,
        .tf_change = 0,
        .remaining_bits = 0,
        .seed = 0,
        .disable_inv = p.disable_inv,
        .band_e = p.band_e,
        .avoid_split_noise = bb > 1,
    };
    var balance = p.balance;
    var dual_stereo = p.dual_stereo;
    const fill: u32 = (@as(u32, 1) << @intCast(bb)) - 1;
    for (start..end) |i| {
        ctx.band = i;
        const edge: usize = @intCast(m * eb[i]);
        const n: usize = @intCast(m * (eb[i + 1] - eb[i]));
        const xs = x_all[edge..][0..n];
        const ys: ?[]f32 = if (chans == 2) x_all[n_total + edge ..][0..n] else null;
        const tell: i32 = @intCast(enc.tellFrac());
        if (i != start) balance -= tell;
        const remaining = p.total_bits - tell - 1;
        ctx.remaining_bits = remaining;
        var b: i32 = 0;
        if (i < p.coded_bands) {
            const curr_balance = @divTrunc(balance, @as(i32, @intCast(@min(3, p.coded_bands - i))));
            b = @max(0, @min(16383, @min(remaining + 1, p.pulses[i] + curr_balance)));
        }
        ctx.tf_change = p.tf_res[i];
        if (dual_stereo and @as(i32, @intCast(i)) == p.intensity) dual_stereo = false;
        if (dual_stereo) {
            _ = try quantBand(&ctx, xs, @divTrunc(b, 2), bb, null, lm, null, 1.0, fill);
            _ = try quantBand(&ctx, ys.?, @divTrunc(b, 2), bb, null, lm, null, 1.0, fill);
        } else if (ys) |yv| {
            _ = try quantBandStereo(&ctx, xs, yv, b, bb, null, lm, null, fill);
        } else {
            _ = try quantBand(&ctx, xs, b, bb, null, lm, null, 1.0, fill);
        }
        balance += p.pulses[i] + tell;
        ctx.avoid_split_noise = false;
    }
}

/// The amplitude of each band for `channels` channels of `120 << lm` coefficients
/// (compute_band_energies).
pub fn bandEnergies(freq: []const f32, band_e: *[2 * nb]f32, end: u32, channels: u32, lm: u32) void {
    const n: usize = @as(usize, 120) << @intCast(lm);
    for (0..channels) |c| {
        for (0..end) |i| {
            const lo: usize = c * n + (@as(usize, @intCast(eb[i])) << @intCast(lm));
            const hi: usize = c * n + (@as(usize, @intCast(eb[i + 1])) << @intCast(lm));
            var sum: f32 = 1e-27;
            for (freq[lo..hi]) |v| sum += v * v;
            band_e[c * nb + i] = @sqrt(sum);
        }
    }
}

/// Scales each band to unit energy (normalise_bands).
pub fn normaliseBands(freq: []const f32, x: []f32, band_e: *const [2 * nb]f32, end: u32, channels: u32, lm: u32) void {
    const n: usize = @as(usize, 120) << @intCast(lm);
    for (0..channels) |c| {
        for (0..end) |i| {
            const g: f32 = 1.0 / (1e-27 + band_e[c * nb + i]);
            const lo: usize = c * n + (@as(usize, @intCast(eb[i])) << @intCast(lm));
            const hi: usize = c * n + (@as(usize, @intCast(eb[i + 1])) << @intCast(lm));
            for (lo..hi) |j| x[j] = freq[j] * g;
        }
    }
}

/// Picks the step of `thresholds` that `val` falls in, and keeps `prev` while `val` is within
/// the hysteresis of its edge (hysteresis_decision).
pub fn hysteresisDecision(val: f32, thresholds: []const f32, hysteresis: []const f32, prev: usize) usize {
    var i: usize = 0;
    while (i < thresholds.len) : (i += 1) {
        if (val < thresholds[i]) break;
    }
    if (i > prev and val < thresholds[prev] + hysteresis[prev]) i = prev;
    if (i < prev and val > thresholds[prev - 1] - hysteresis[prev - 1]) i = prev;
    return i;
}

/// The spreading state that carries over from frame to frame.
pub const SpreadState = struct {
    average: i32 = 256,
    hf_average: i32 = 0,
    tapset: u32 = 0,
    decision: vq.Spread = .normal,
};

/// Decides how much to spread the pulses of a frame from how many small coefficients the bands
/// hold (spreading_decision). It also updates the post filter tap set when `update_hf` is set.
pub fn spreadingDecision(
    x: []const f32,
    state: *SpreadState,
    update_hf: bool,
    end: u32,
    channels: u32,
    lm: u32,
    spread_weight: *const [nb]i32,
) vq.Spread {
    const n0: usize = @as(usize, 120) << @intCast(lm);
    const mm: i32 = @as(i32, 1) << @intCast(lm);
    if (mm * (eb[end] - eb[end - 1]) <= 8) return .none;
    var sum: i32 = 0;
    var nb_bands: i32 = 0;
    var hf_sum: i32 = 0;
    for (0..channels) |c| {
        for (0..end) |i| {
            const lo: usize = c * n0 + @as(usize, @intCast(mm * eb[i]));
            const n: usize = @intCast(mm * (eb[i + 1] - eb[i]));
            if (n <= 8) continue;
            var tcount = [3]i32{ 0, 0, 0 };
            const nf: f32 = @floatFromInt(n);
            for (x[lo..][0..n]) |v| {
                const x2n = (v * v) * nf;
                if (x2n < 0.25) tcount[0] += 1;
                if (x2n < 0.0625) tcount[1] += 1;
                if (x2n < 0.015625) tcount[2] += 1;
            }
            const ni: i32 = @intCast(n);
            if (i > nb - 4) hf_sum += @divTrunc(32 * (tcount[1] + tcount[0]), ni);
            const tmp: i32 = @as(i32, @intFromBool(2 * tcount[2] >= ni)) + @as(i32, @intFromBool(2 * tcount[1] >= ni)) + @as(i32, @intFromBool(2 * tcount[0] >= ni));
            sum += tmp * spread_weight[i];
            nb_bands += spread_weight[i];
        }
    }
    if (update_hf) {
        if (hf_sum != 0) hf_sum = @divTrunc(hf_sum, @as(i32, @intCast(channels)) * (4 - @as(i32, nb) + @as(i32, @intCast(end))));
        state.hf_average = (state.hf_average + hf_sum) >> 1;
        hf_sum = state.hf_average;
        if (state.tapset == 2) {
            hf_sum += 4;
        } else if (state.tapset == 0) {
            hf_sum -= 4;
        }
        state.tapset = if (hf_sum > 22) 2 else if (hf_sum > 18) 1 else 0;
    }
    sum = @divTrunc(sum << 8, @max(nb_bands, 1));
    sum = (sum + state.average) >> 1;
    state.average = sum;
    sum = (3 * sum + (((3 - @as(i32, @backingInt(state.decision))) << 7) + 64) + 2) >> 2;
    return if (sum < 80) .aggressive else if (sum < 256) .normal else if (sum < 384) .light else .none;
}

/// 2 to the power of `x`, in the same way as celt_exp2 of libopus.
pub fn exp2f(x: f32) f32 {
    return @floatCast(@exp(0.6931471805599453094 * @as(f64, x)));
}

/// Turns the unit band shapes into spectrum coefficients (denormalise_bands). `silence`
/// gives a zero spectrum.
pub fn denormalise(x: []const f32, freq: []f32, band_log: []const f32, start_in: u32, end_in: u32, lm: u32, silence: bool) void {
    const m: usize = @as(usize, 1) << @intCast(lm);
    const n = 120 * m;
    var start: usize = start_in;
    var end: usize = end_in;
    var bound: usize = m * @as(usize, @intCast(eb[end]));
    if (silence) {
        bound = 0;
        start = 0;
        end = 0;
    }
    @memset(freq[0 .. m * @as(usize, @intCast(eb[start]))], 0);
    for (start..end) |i| {
        const lg = band_log[i] + tables.e_means[i];
        const g = exp2f(@min(32.0, lg));
        const lo = m * @as(usize, @intCast(eb[i]));
        const hi = m * @as(usize, @intCast(eb[i + 1]));
        for (lo..hi) |j| freq[j] = x[j] * g;
    }
    @memset(freq[bound..n], 0);
}

/// Fills the short blocks of a band that got no pulses with noise (anti_collapse).
pub fn antiCollapse(
    x_all: []f32,
    collapse_masks: *const [2 * nb]u8,
    lm: u32,
    channels: u32,
    start: u32,
    end: u32,
    log_e: *const energy.Energies,
    prev1_log_e: *const energy.Energies,
    prev2_log_e: *const energy.Energies,
    pulses: *const [nb]i32,
    seed_in: u32,
) void {
    var seed = seed_in;
    const size = @as(usize, 120) << @intCast(lm);
    const chans: usize = channels;
    for (start..end) |i| {
        const n0: u32 = @intCast(eb[i + 1] - eb[i]);
        const depth = (@as(u32, @bitCast(1 + pulses[i])) / n0) >> @intCast(lm);
        const thresh: f32 = 0.5 * exp2f(-0.125 * @as(f32, @floatFromInt(depth)));
        const sqrt_1: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(n0 << @intCast(lm))));
        for (0..chans) |c| {
            var prev1 = prev1_log_e[c * nb + i];
            var prev2 = prev2_log_e[c * nb + i];
            if (chans == 1) {
                prev1 = @max(prev1, prev1_log_e[nb + i]);
                prev2 = @max(prev2, prev2_log_e[nb + i]);
            }
            const ediff = @max(0, log_e[c * nb + i] - @min(prev1, prev2));
            var r: f32 = 2.0 * exp2f(-ediff);
            if (lm == 3) r *= 1.41421356;
            r = @min(thresh, r);
            r = r * sqrt_1;
            const xb = x_all[c * size + (@as(usize, @intCast(eb[i])) << @intCast(lm)) ..][0 .. n0 << @intCast(lm)];
            var renorm = false;
            for (0..@as(usize, 1) << @intCast(lm)) |k| {
                if (collapse_masks[i * chans + c] & (@as(u32, 1) << @intCast(k)) == 0) {
                    for (0..n0) |j| {
                        seed = lcg(seed);
                        xb[(j << @intCast(lm)) + k] = if (seed & 0x8000 != 0) r else -r;
                    }
                    renorm = true;
                }
            }
            if (renorm) vq.renormaliseVector(xb, 1.0);
        }
    }
}

const testing = std.testing;

test "integer helpers" {
    try testing.expectEqual(@as(u32, 1), isqrt32(1));
    try testing.expectEqual(@as(u32, 1000), isqrt32(1000 * 1000 + 17));
    try testing.expectEqual(@as(u32, 65535), isqrt32(0xFFFFFFFF));
    // Values from libopus bitexact_cos.
    try testing.expectEqual(@as(i32, 32767), bitexactCos(64));
    try testing.expectEqual(@as(i32, 23171), bitexactCos(8192));
    try testing.expectEqual(@as(i32, 30274), bitexactCos(4096));
    try testing.expectEqual(@as(i32, 3), bitexactCos(16383));
    try testing.expectEqual(@as(i32, 0), bitexactLog2Tan(1000, 1000));
    try testing.expectEqual(@as(i32, 16384 >> 1), fracMul16(16384, 16384));
}

test "bit exact cosine falls from 32767 to 1" {
    var prev: i32 = 32768;
    var x: i32 = 64;
    while (x < 16384) : (x += 1) {
        const c = bitexactCos(x);
        try testing.expect(c <= prev and c >= 1);
        prev = c;
    }
    try testing.expect(bitexactCos(16383) < 4);
}

test "hadamard reordering is its own inverse" {
    var x: [16]f32 = undefined;
    for (&x, 0..) |*v, i| v.* = @floatFromInt(i);
    var y = x;
    deinterleaveHadamard(&y, 4, 4, true);
    interleaveHadamard(&y, 4, 4, true);
    try testing.expectEqualSlices(f32, &x, &y);
    deinterleaveHadamard(&y, 2, 8, false);
    interleaveHadamard(&y, 2, 8, false);
    try testing.expectEqualSlices(f32, &x, &y);
}

test "haar twice keeps the signal" {
    var x = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    haar1(&x, 8, 1);
    haar1(&x, 8, 1);
    for (x, 1..) |v, i| try testing.expectApproxEqAbs(@as(f32, @floatFromInt(i)), v, 1e-5);
}

test "denormalise zeroes outside the bands and scales inside" {
    var x: [120]f32 = @splat(1.0);
    var freq: [120]f32 = undefined;
    var logs: [nb]f32 = @splat(0);
    logs[0] = -tables.e_means[0] + 1;
    denormalise(&x, &freq, &logs, 0, 21, 0, false);
    try testing.expectApproxEqAbs(@as(f32, 2.0), freq[0], 1e-5);
    denormalise(&x, &freq, &logs, 0, 21, 0, true);
    for (freq) |v| try testing.expectEqual(@as(f32, 0), v);
}

test "hysteresis keeps the step near its edge" {
    const th = [_]f32{ 10, 20, 30 };
    const hy = [_]f32{ 2, 2, 2 };
    try testing.expectEqual(@as(usize, 0), hysteresisDecision(5, &th, &hy, 0));
    try testing.expectEqual(@as(usize, 2), hysteresisDecision(25, &th, &hy, 0));
    // Just above the edge of the step that it came from, the decision stays.
    try testing.expectEqual(@as(usize, 0), hysteresisDecision(11, &th, &hy, 0));
    try testing.expectEqual(@as(usize, 1), hysteresisDecision(12, &th, &hy, 0));
    try testing.expectEqual(@as(usize, 1), hysteresisDecision(9, &th, &hy, 1));
    try testing.expectEqual(@as(usize, 0), hysteresisDecision(7, &th, &hy, 1));
    try testing.expectEqual(@as(usize, 3), hysteresisDecision(99, &th, &hy, 3));
}

test "peaky bands do not spread and flat bands do" {
    var weights: [nb]i32 = @splat(32);
    var peaky: [120]f32 = @splat(0);
    var flat: [120]f32 = undefined;
    for (eb[0..nb], 0..) |lo, i| {
        const hi = eb[i + 1];
        if (hi - lo > 8) peaky[@intCast(lo)] = 1;
    }
    for (&flat) |*v| v.* = 0.1;
    var state: SpreadState = .{};
    try testing.expectEqual(vq.Spread.none, spreadingDecision(&peaky, &state, true, nb, 1, 0, &weights));
    state = .{};
    const d = spreadingDecision(&flat, &state, true, nb, 1, 0, &weights);
    try testing.expectEqual(vq.Spread.normal, d);
}

test "band energies and normalisation give unit bands" {
    var freq: [240]f32 = undefined;
    for (&freq, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i % 7)) - 3.0;
    var band_e: [2 * nb]f32 = @splat(0);
    bandEnergies(&freq, &band_e, nb, 2, 0);
    var x: [240]f32 = undefined;
    normaliseBands(&freq, &x, &band_e, nb, 2, 0);
    for (0..2) |c| {
        for (0..nb) |i| {
            var sum: f32 = 0;
            for (x[c * 120 + @as(usize, @intCast(eb[i])) ..][0..@intCast(eb[i + 1] - eb[i])]) |v| sum += v * v;
            if (band_e[c * nb + i] > 1e-6) try testing.expectApproxEqAbs(@as(f32, 1.0), sum, 1e-4);
        }
    }
}
