//! CELT bit allocation and pulse cache lookups ported from libopus celt/rate.c and rate.h.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const range = @import("../range.zig");
const tables = @import("tables.zig");

const nb = tables.nb_ebands;
const bitres = 3;
const alloc_steps = 6;
const max_fine_bits = 8;
const fine_offset = 21;

/// The bits of one frame of `frame_size` samples at `fs` Hz for the bitrate `bitrate`.
pub fn bitrateToBits(fs: u32, bitrate: i64, frame_size: u32) i32 {
    return @intCast(@divTrunc(bitrate * 6, @divTrunc(6 * @as(i64, fs), frame_size)));
}

/// The bitrate that gives `bits` bits for each frame of `frame_size` samples at `fs` Hz.
pub fn bitsToBitrate(fs: u32, bits: i32, frame_size: u32) i32 {
    return @intCast(@divTrunc(@as(i64, bits) * @divTrunc(6 * @as(i64, fs), frame_size), 6));
}

/// The pulse cache block of a band. Every band size that is looked up has a block.
/// `lm` runs from -1 to 3.
fn cacheBlock(band: usize, lm: i32) []const u8 {
    std.debug.assert(lm >= -1 and lm <= tables.max_lm and band < nb);
    const idx = tables.cache_index50[@as(usize, @intCast(lm + 1)) * nb + band];
    std.debug.assert(idx >= 0);
    return tables.cache_bits50[@intCast(idx)..];
}

/// The pseudo pulse count of `band` whose cost is closest to `bits` (in 8th bits).
/// `lm` runs from -1 to 3. Pass the result to `tables.getPulses` for the pulse count.
pub fn bitsToPulses(band: usize, lm: i32, bits_in: i32) u32 {
    std.debug.assert(bits_in > -(1 << 20) and bits_in < (1 << 20));
    const cache = cacheBlock(band, lm);
    var lo: u32 = 0;
    var hi: u32 = cache[0];
    const bits = bits_in - 1;
    for (0..6) |_| {
        const mid = (lo + hi + 1) >> 1;
        if (@as(i32, cache[mid]) >= bits) hi = mid else lo = mid;
    }
    const lo_cost: i32 = if (lo == 0) -1 else cache[lo];
    return if (bits - lo_cost <= @as(i32, cache[hi]) - bits) lo else hi;
}

/// The cost in 8th bits of the pseudo pulse index `pulses`, up to the block's `maxK`.
pub fn pulsesToBits(band: usize, lm: i32, pulses: u32) i32 {
    if (pulses == 0) return 0;
    std.debug.assert(pulses <= cacheBlock(band, lm)[0]);
    return @as(i32, cacheBlock(band, lm)[pulses]) + 1;
}

/// Fills `caps` with the per band maximum of 8th bits for `lm` and `channels`.
pub fn initCaps(caps: *[nb]i32, lm: u32, channels: u32) void {
    std.debug.assert(lm <= tables.max_lm and (channels == 1 or channels == 2));
    const c: i32 = @intCast(channels);
    for (0..nb) |i| {
        const n: i32 = (tables.eband5ms[i + 1] - tables.eband5ms[i]) << @intCast(lm);
        const base: i32 = tables.cache_caps50[nb * (2 * lm + channels - 1) + i];
        caps[i] = ((base + 64) * c * n) >> 2;
    }
}

pub const Params = struct {
    start: u32,
    end: u32,
    /// Boost in 8th bits per band.
    offsets: *const [nb]i32,
    caps: *const [nb]i32,
    alloc_trim: i32,
    /// Bits for the band data in 8th bits.
    total: i32,
    channels: u32,
    lm: u32,
};

pub const Allocation = struct {
    /// PVQ budget per band in 8th bits.
    pulses: [nb]i32 = @splat(0),
    fine_quant: [nb]i32 = @splat(0),
    fine_priority: [nb]bool = @splat(false),
    /// Input when encoding (at least `start`), output when decoding.
    intensity: i32 = 0,
    /// Input when encoding, output when decoding.
    dual_stereo: bool = false,
    balance: i32 = 0,
};

pub const Encoding = struct {
    enc: *range.Encoder,
    /// The band count of the previous frame.
    prev: i32,
    signal_bandwidth: i32,
};

pub const Coder = union(enum) {
    decoder: *range.Decoder,
    encoder: Encoding,
};

fn width(j: usize) i32 {
    return tables.eband5ms[j + 1] - tables.eband5ms[j];
}

fn udiv(n: i32, d: i32) i32 {
    return @bitCast(@as(u32, @bitCast(n)) / @as(u32, @intCast(d)));
}

/// Splits the bit budget over the bands (clt_compute_allocation). Reads the skip,
/// intensity and dual stereo decisions from the decoder, or writes them with the encoder.
/// Returns the number of coded bands. Bands from there to `end` get fine energy only.
/// The caller bounds the input: `total` comes from a packet of at most 1275 bytes
/// (-100000 to 100000 in 8th bits) and each offset is at most `caps[j]` plus one boost step.
pub fn computeAllocation(p: Params, coder: Coder, out: *Allocation) u32 {
    std.debug.assert(p.start < p.end and p.end <= nb);
    std.debug.assert(p.channels == 1 or p.channels == 2);
    std.debug.assert(p.lm <= tables.max_lm);
    std.debug.assert(p.total >= -100_000 and p.total <= 100_000);
    for (p.start..p.end) |j| std.debug.assert(p.offsets[j] >= 0 and p.offsets[j] <= p.caps[j] + 352);
    const start: usize = p.start;
    const end: usize = p.end;
    const c: i32 = @intCast(p.channels);
    const lm: u5 = @intCast(p.lm);
    const lm_i: i32 = lm;

    var total: i32 = @max(p.total, 0);
    var skip_start: usize = start;
    const skip_rsv: i32 = if (total >= 8) 8 else 0;
    total -= skip_rsv;
    var intensity_rsv: i32 = 0;
    var dual_stereo_rsv: i32 = 0;
    if (c == 2) {
        intensity_rsv = tables.log2_frac_table[end - start];
        if (intensity_rsv > total) {
            intensity_rsv = 0;
        } else {
            total -= intensity_rsv;
            dual_stereo_rsv = if (total >= 8) 8 else 0;
            total -= dual_stereo_rsv;
        }
    }

    var bits1: [nb]i32 = @splat(0);
    var bits2: [nb]i32 = @splat(0);
    var thresh: [nb]i32 = @splat(0);
    var trim_offset: [nb]i32 = @splat(0);
    for (start..end) |j| {
        const w = width(j);
        const j_i: i32 = @intCast(j);
        const end_i: i32 = @intCast(end);
        thresh[j] = @max(c << bitres, ((3 * w) << lm << bitres) >> 4);
        trim_offset[j] = (c * w * (p.alloc_trim - 5 - lm_i) * (end_i - j_i - 1) * (@as(i32, 1) << (lm + bitres))) >> 6;
        if ((w << lm) == 1) trim_offset[j] -= c << bitres;
    }

    var lo: i32 = 1;
    var hi: i32 = tables.nb_alloc_vectors - 1;
    while (true) {
        var done = false;
        var psum: i32 = 0;
        const mid = (lo + hi) >> 1;
        var j = end;
        while (j > start) {
            j -= 1;
            var bitsj = allocBits(c, j, mid, lm);
            if (bitsj > 0) bitsj = @max(0, bitsj + trim_offset[j]);
            bitsj += p.offsets[j];
            if (bitsj >= thresh[j] or done) {
                done = true;
                psum += @min(bitsj, p.caps[j]);
            } else if (bitsj >= c << bitres) {
                psum += c << bitres;
            }
        }
        if (psum > total) hi = mid - 1 else lo = mid + 1;
        if (lo > hi) break;
    }
    hi = lo;
    lo -= 1;
    for (start..end) |j| {
        var bits1j = allocBits(c, j, lo, lm);
        var bits2j = if (hi >= tables.nb_alloc_vectors) p.caps[j] else allocBits(c, j, hi, lm);
        if (bits1j > 0) bits1j = @max(0, bits1j + trim_offset[j]);
        if (bits2j > 0) bits2j = @max(0, bits2j + trim_offset[j]);
        if (lo > 0) bits1j += p.offsets[j];
        bits2j += p.offsets[j];
        if (p.offsets[j] > 0) skip_start = j;
        bits2j = @max(0, bits2j - bits1j);
        bits1[j] = bits1j;
        bits2[j] = bits2j;
    }
    return interpBits(p, coder, out, .{
        .skip_start = skip_start,
        .bits1 = &bits1,
        .bits2 = &bits2,
        .thresh = &thresh,
        .total = total,
        .skip_rsv = skip_rsv,
        .intensity_rsv = intensity_rsv,
        .dual_stereo_rsv = dual_stereo_rsv,
    });
}

fn allocBits(c: i32, j: usize, row: i32, lm: u5) i32 {
    const a: i32 = tables.band_allocation[@as(usize, @intCast(row)) * nb + j];
    return ((c * width(j) * a) << lm) >> 2;
}

const Interp = struct {
    skip_start: usize,
    bits1: *const [nb]i32,
    bits2: *const [nb]i32,
    thresh: *const [nb]i32,
    total: i32,
    skip_rsv: i32,
    intensity_rsv: i32,
    dual_stereo_rsv: i32,
};

fn interpBits(p: Params, coder: Coder, out: *Allocation, in: Interp) u32 {
    const start: usize = p.start;
    const end: usize = p.end;
    const c: i32 = @intCast(p.channels);
    const lm: u5 = @intCast(p.lm);
    const stereo: u5 = @intCast(c - 1);
    const logm: i32 = @as(i32, lm) << bitres;
    const alloc_floor = c << bitres;
    const bits = &out.pulses;
    var total = in.total;
    var intensity_rsv = in.intensity_rsv;
    var dual_stereo_rsv = in.dual_stereo_rsv;

    var lo: i32 = 0;
    var hi: i32 = 1 << alloc_steps;
    for (0..alloc_steps) |_| {
        const mid = (lo + hi) >> 1;
        var psum: i32 = 0;
        var done = false;
        var j = end;
        while (j > start) {
            j -= 1;
            const tmp = in.bits1[j] + ((mid * in.bits2[j]) >> alloc_steps);
            if (tmp >= in.thresh[j] or done) {
                done = true;
                psum += @min(tmp, p.caps[j]);
            } else if (tmp >= alloc_floor) {
                psum += alloc_floor;
            }
        }
        if (psum > total) hi = mid else lo = mid;
    }
    var psum: i32 = 0;
    var done = false;
    var jj = end;
    while (jj > start) {
        jj -= 1;
        var tmp = in.bits1[jj] + ((lo * in.bits2[jj]) >> alloc_steps);
        if (tmp < in.thresh[jj] and !done) {
            tmp = if (tmp >= alloc_floor) alloc_floor else 0;
        } else {
            done = true;
        }
        tmp = @min(tmp, p.caps[jj]);
        bits[jj] = tmp;
        psum += tmp;
    }

    var coded: usize = end;
    while (true) : (coded -= 1) {
        const j = coded - 1;
        if (j <= in.skip_start) {
            total += in.skip_rsv;
            break;
        }
        var left = total - psum;
        const span = tables.eband5ms[coded] - tables.eband5ms[start];
        const percoeff = udiv(left, span);
        left -= span * percoeff;
        const rem = @max(left - (tables.eband5ms[j] - tables.eband5ms[start]), 0);
        const band_width = tables.eband5ms[coded] - tables.eband5ms[j];
        var band_bits = bits[j] + percoeff * band_width + rem;
        if (band_bits >= @max(in.thresh[j], alloc_floor + (1 << bitres))) {
            switch (coder) {
                .encoder => |e| {
                    const j_i: i32 = @intCast(j);
                    const depth_threshold: i32 = if (coded > 17) (if (j_i < e.prev) 7 else 9) else 0;
                    if (coded <= start + 2 or (band_bits > ((depth_threshold * band_width) << lm << bitres) >> 4 and j_i <= e.signal_bandwidth)) {
                        e.enc.encodeBitLogp(true, 1);
                        break;
                    }
                    e.enc.encodeBitLogp(false, 1);
                },
                .decoder => |d| if (d.bitLogp(1)) break,
            }
            psum += 1 << bitres;
            band_bits -= 1 << bitres;
        }
        psum -= bits[j] + intensity_rsv;
        if (intensity_rsv > 0) intensity_rsv = tables.log2_frac_table[j - start];
        psum += intensity_rsv;
        if (band_bits >= alloc_floor) {
            psum += alloc_floor;
            bits[j] = alloc_floor;
        } else {
            bits[j] = 0;
        }
    }

    const start_i: i32 = @intCast(start);
    const coded_i: i32 = @intCast(coded);
    if (intensity_rsv > 0) {
        switch (coder) {
            .encoder => |e| {
                std.debug.assert(out.intensity >= start_i);
                out.intensity = @min(out.intensity, coded_i);
                e.enc.encodeUint(@intCast(out.intensity - start_i), @intCast(coded_i + 1 - start_i));
            },
            .decoder => |d| out.intensity = start_i + @as(i32, @intCast(d.uint(@intCast(coded_i + 1 - start_i)))),
        }
    } else {
        out.intensity = 0;
    }
    if (out.intensity <= start_i) {
        total += dual_stereo_rsv;
        dual_stereo_rsv = 0;
    }
    if (dual_stereo_rsv > 0) {
        switch (coder) {
            .encoder => |e| e.enc.encodeBitLogp(out.dual_stereo, 1),
            .decoder => |d| out.dual_stereo = d.bitLogp(1),
        }
    } else {
        out.dual_stereo = false;
    }

    const span = tables.eband5ms[coded] - tables.eband5ms[start];
    var left = total - psum;
    const percoeff = udiv(left, span);
    left -= span * percoeff;
    for (start..coded) |j| bits[j] += percoeff * width(j);
    for (start..coded) |j| {
        const tmp = @min(left, width(j));
        bits[j] += tmp;
        left -= tmp;
    }

    var balance: i32 = 0;
    var j = start;
    while (j < coded) : (j += 1) {
        const n = width(j) << lm;
        const bit = bits[j] + balance;
        var excess: i32 = undefined;
        if (n > 1) {
            excess = @max(bit - p.caps[j], 0);
            bits[j] = bit - excess;
            const extra_dof: i32 = if (c == 2 and n > 2 and !out.dual_stereo and @as(i32, @intCast(j)) < out.intensity) 1 else 0;
            const den = c * n + extra_dof;
            const nclogn = den * (tables.logN400[j] + logm);
            var offset = (nclogn >> 1) - den * fine_offset;
            if (n == 2) offset += (den << bitres) >> 2;
            if (bits[j] + offset < (den * 2) << bitres) {
                offset += nclogn >> 2;
            } else if (bits[j] + offset < (den * 3) << bitres) {
                offset += nclogn >> 3;
            }
            const e0 = @max(0, bits[j] + offset + (den << (bitres - 1)));
            var e: i32 = @intCast(@as(u32, @intCast(e0)) / @as(u32, @intCast(den)) >> bitres);
            if (c * e > (bits[j] >> bitres)) e = (bits[j] >> stereo) >> bitres;
            e = @min(e, max_fine_bits);
            out.fine_priority[j] = e * (den << bitres) >= bits[j] + offset;
            bits[j] -= (c * e) << bitres;
            out.fine_quant[j] = e;
        } else {
            excess = @max(0, bit - (c << bitres));
            bits[j] = bit - excess;
            out.fine_quant[j] = 0;
            out.fine_priority[j] = true;
        }
        if (excess > 0) {
            const extra_fine = @min(excess >> (stereo + bitres), max_fine_bits - out.fine_quant[j]);
            out.fine_quant[j] += extra_fine;
            const extra_bits = (extra_fine * c) << bitres;
            out.fine_priority[j] = extra_bits >= excess - balance;
            excess -= extra_bits;
        }
        balance = excess;
    }
    out.balance = balance;

    while (j < end) : (j += 1) {
        out.fine_quant[j] = (bits[j] >> stereo) >> bitres;
        bits[j] = 0;
        out.fine_priority[j] = out.fine_quant[j] < 1;
    }
    return @intCast(coded);
}

const fnv = @import("../test_util.zig").fnv;
const Rng = @import("../test_util.zig").Xorshift;
const rng_seed = 0xC0FFEE11;

test "pulse cache lookups match libopus" {
    var h: u32 = 2166136261;
    var count: u32 = 0;
    var lm: i32 = -1;
    while (lm <= 3) : (lm += 1) {
        for (0..21) |b| {
            const idx = tables.cache_index50[@as(usize, @intCast(lm + 1)) * 21 + b];
            if (idx < 0) continue;
            const c = tables.cache_bits50[@intCast(idx)..];
            var bits: i32 = -3;
            while (bits <= @as(i32, c[c[0]]) + 40) : (bits += 1) {
                h = fnv(h, bitsToPulses(b, lm, bits));
                count += 1;
            }
            for (0..@as(usize, c[0]) + 1) |p| {
                h = fnv(h, @bitCast(pulsesToBits(b, lm, @intCast(p))));
                count += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(u32, 24182), count);
    try std.testing.expectEqual(@as(u32, 2796414306), h);
    try std.testing.expectEqual(@as(i32, 0), pulsesToBits(0, 0, 0));
    try std.testing.expectEqual(@as(i32, 8), pulsesToBits(0, 0, 1));
    try std.testing.expectEqual(@as(u32, 0), bitsToPulses(8, 0, 0));
}

test "allocation matches libopus on 4000 seeded cases" {
    var rng = Rng{ .s = rng_seed };
    var h: u32 = 2166136261;
    var he: u32 = 2166136261;
    const eb = tables.eband5ms;
    var c: u32 = 0;
    while (c < 4000) : (c += 1) {
        const ch: u32 = 1 + (rng.next() & 1);
        const lm: u32 = rng.next() % 4;
        var start: u32 = if (rng.next() % 5 == 0) 17 else 0;
        if (rng.next() % 11 == 0) start = rng.next() % 20;
        var end: u32 = if (rng.next() % 3 == 0)
            start + 1 + rng.next() % (21 - start)
        else
            ([4]u32{ 13, 17, 19, 21 })[rng.next() % 4];
        if (end <= start) end = start + 1;
        if (end > 21) end = 21;
        var caps: [21]i32 = undefined;
        initCaps(&caps, lm, ch);
        var offsets: [21]i32 = @splat(0);
        if (rng.next() & 1 != 0) {
            for (start..end) |j| {
                const w: i32 = @as(i32, @intCast(ch)) * ((eb[j + 1] - eb[j]) << @intCast(lm));
                const q = @min(w << 3, @max(48, w));
                if (rng.next() % 4 == 0) offsets[j] = q * @as(i32, @intCast(1 + rng.next() % 3));
            }
        }
        const trim: i32 = @intCast(rng.next() % 11);
        const ta = rng.next();
        const sh: u5 = @intCast(3 + rng.next() % 14);
        var total: i32 = @intCast(ta % (@as(u32, 1) << sh));
        if (rng.next() % 50 == 0) total = -@as(i32, @intCast(rng.next() % 100));
        var buf: [100]u8 = undefined;
        for (&buf) |*b| b.* = @truncate(rng.next());
        const p = Params{ .start = start, .end = end, .offsets = &offsets, .caps = &caps, .alloc_trim = trim, .total = total, .channels = ch, .lm = lm };

        var dec = range.Decoder.init(&buf);
        var a = Allocation{};
        const cb = computeAllocation(p, .{ .decoder = &dec }, &a);
        h = fnv(h, cb);
        h = fnv(h, @bitCast(a.intensity));
        h = fnv(h, @intFromBool(a.dual_stereo));
        h = fnv(h, @bitCast(a.balance));
        h = fnv(h, dec.tellFrac());
        h = fnv(h, dec.rng);
        for (start..end) |j| {
            h = fnv(h, @bitCast(a.pulses[j]));
            h = fnv(h, @bitCast(a.fine_quant[j]));
            h = fnv(h, @intFromBool(a.fine_priority[j]));
        }
        if (c == 0) {
            try std.testing.expectEqual(@as(u32, 11), cb);
            try std.testing.expectEqual(@as(i32, 9), a.intensity);
            try std.testing.expectEqual(@as(i32, 29383), a.balance);
            try std.testing.expectEqual(@as(i32, 960), a.pulses[8]);
            try std.testing.expectEqual(@as(i32, 8), a.fine_quant[8]);
        }

        const prev = rng.next() % 21;
        const sbw = rng.next() % 22;
        var a2 = Allocation{};
        a2.intensity = @intCast(start + rng.next() % (end - start + 1));
        a2.dual_stereo = rng.next() & 1 != 0;
        var ebuf: [100]u8 = @splat(0);
        var enc = range.Encoder.init(&ebuf);
        const cb2 = computeAllocation(p, .{ .encoder = .{ .enc = &enc, .prev = @intCast(prev), .signal_bandwidth = @intCast(sbw) } }, &a2);
        enc.done();
        he = fnv(he, cb2);
        he = fnv(he, @bitCast(a2.intensity));
        he = fnv(he, @intFromBool(a2.dual_stereo));
        he = fnv(he, @bitCast(a2.balance));
        he = fnv(he, enc.tellFrac());
        he = fnv(he, enc.rng);
        for (ebuf) |b| he = fnv(he, b);
        for (start..end) |j| {
            he = fnv(he, @bitCast(a2.pulses[j]));
            he = fnv(he, @bitCast(a2.fine_quant[j]));
            he = fnv(he, @intFromBool(a2.fine_priority[j]));
        }
    }
    try std.testing.expectEqual(@as(u32, 555539382), h);
    try std.testing.expectEqual(@as(u32, 3493591755), he);
}

test "allocation survives arbitrary inputs" {
    var rng = Rng{ .s = 7 };
    var c: u32 = 0;
    while (c < 3000) : (c += 1) {
        const ch: u32 = 1 + (rng.next() & 1);
        const lm: u32 = rng.next() % 4;
        const start: u32 = rng.next() % 20;
        const end: u32 = start + 1 + rng.next() % (21 - start);
        var caps: [21]i32 = undefined;
        initCaps(&caps, lm, ch);
        var offsets: [21]i32 = undefined;
        for (&offsets, caps) |*o, cap| o.* = @intCast(rng.next() % @as(u32, @intCast(cap + 1)));
        var buf: [40]u8 = undefined;
        for (&buf) |*b| b.* = @truncate(rng.next());
        const p = Params{
            .start = start,
            .end = end,
            .offsets = &offsets,
            .caps = &caps,
            .alloc_trim = @intCast(rng.next() % 11),
            .total = @as(i32, @intCast(rng.next() % 200_001)) - 100_000,
            .channels = ch,
            .lm = lm,
        };
        var dec = range.Decoder.init(&buf);
        var a = Allocation{};
        const cb = computeAllocation(p, .{ .decoder = &dec }, &a);
        try std.testing.expect(cb >= start and cb <= end);
    }
}

test "allocation matches libopus on large totals and boosts" {
    var rnd: Rng = .{ .s = 0xABCDEF01 };
    var h: u32 = 2166136261;
    var he: u32 = 2166136261;
    const eb = tables.eband5ms;
    var c: u32 = 0;
    while (c < 20000) : (c += 1) {
        const ch: u32 = 1 + (rnd.next() & 1);
        const lm: u32 = rnd.next() % 4;
        const start: u32 = if (rnd.next() % 4 == 0) 17 else (if (rnd.next() % 7 == 0) rnd.next() % 20 else 0);
        const end: u32 = if (rnd.next() & 1 != 0) 21 else start + 1 + rnd.next() % (21 - start);
        var caps: [21]i32 = undefined;
        initCaps(&caps, lm, ch);
        var offsets: [21]i32 = @splat(0);
        for (start..end) |j| {
            const w: i32 = @as(i32, @intCast(ch)) * ((eb[j + 1] - eb[j]) << @intCast(lm));
            const q = @min(w << 3, @max(48, w));
            if (rnd.next() % 3 == 0) {
                const k: i32 = @intCast(rnd.next() % @as(u32, @intCast(@divTrunc(caps[j], q) + 2)));
                offsets[j] = k * q;
            }
        }
        const trim: i32 = @intCast(rnd.next() % 11);
        const mode = rnd.next() % 8;
        const total: i32 = if (mode == 0) @intCast(rnd.next() % 64) else if (mode == 1) -@as(i32, @intCast(rnd.next() % 1000)) else @intCast(rnd.next() % 90000);
        var buf: [200]u8 = undefined;
        for (&buf) |*b| b.* = @truncate(rnd.next());
        const p = Params{ .start = start, .end = end, .offsets = &offsets, .caps = &caps, .alloc_trim = trim, .total = total, .channels = ch, .lm = lm };
        var dec = range.Decoder.init(&buf);
        var a = Allocation{};
        const cb = computeAllocation(p, .{ .decoder = &dec }, &a);
        h = fnv(h, cb);
        h = fnv(h, @bitCast(a.intensity));
        h = fnv(h, @intFromBool(a.dual_stereo));
        h = fnv(h, @bitCast(a.balance));
        h = fnv(h, dec.tellFrac());
        h = fnv(h, dec.rng);
        for (start..end) |j| {
            h = fnv(h, @bitCast(a.pulses[j]));
            h = fnv(h, @bitCast(a.fine_quant[j]));
            h = fnv(h, @intFromBool(a.fine_priority[j]));
        }
        const prev = rnd.next() % 22;
        const sbw = rnd.next() % 22;
        var a2 = Allocation{};
        a2.intensity = @intCast(start + rnd.next() % (end - start + 1));
        a2.dual_stereo = rnd.next() & 1 != 0;
        var ebuf: [200]u8 = @splat(0);
        var enc = range.Encoder.init(&ebuf);
        const cb2 = computeAllocation(p, .{ .encoder = .{ .enc = &enc, .prev = @intCast(prev), .signal_bandwidth = @intCast(sbw) } }, &a2);
        enc.done();
        he = fnv(he, cb2);
        he = fnv(he, @bitCast(a2.intensity));
        he = fnv(he, @intFromBool(a2.dual_stereo));
        he = fnv(he, @bitCast(a2.balance));
        he = fnv(he, enc.tellFrac());
        he = fnv(he, enc.rng);
        for (ebuf) |b| he = fnv(he, b);
        for (start..end) |j| {
            he = fnv(he, @bitCast(a2.pulses[j]));
            he = fnv(he, @bitCast(a2.fine_quant[j]));
            he = fnv(he, @intFromBool(a2.fine_priority[j]));
        }
    }
    try std.testing.expectEqual(@as(u32, 3275544687), h);
    try std.testing.expectEqual(@as(u32, 2027490170), he);
}
