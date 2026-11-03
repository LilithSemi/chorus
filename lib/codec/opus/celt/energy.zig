//! CELT band energy coding, ported from libopus celt/quant_bands.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const range = @import("../range.zig");
const tables = @import("tables.zig");
const vq = @import("vq.zig");

const nb = tables.nb_ebands;
const max_fine_bits = 8;

/// Energy per band in log2 units for up to two channels, channel `c` at `c * nb`.
pub const Energies = [2 * nb]f32;

/// Reads the coarse energy of the bands `start` to `end` for `channels` channels.
pub fn unquantCoarse(
    start: u32,
    end: u32,
    old: *Energies,
    intra: bool,
    dec: *range.Decoder,
    channels: u32,
    lm: u32,
) void {
    const prob = &tables.e_prob_model[lm][@intFromBool(intra)];
    const coef: f32 = if (intra) 0 else tables.pred_coef[lm];
    const beta: f32 = if (intra) tables.beta_intra else tables.beta_coef[lm];
    const budget: i32 = @intCast(dec.storage * 8);
    var prev = [2]f32{ 0, 0 };
    for (start..end) |i| {
        for (0..channels) |c| {
            const tell = dec.tell();
            var qi: i32 = undefined;
            if (budget - tell >= 15) {
                const pi: usize = 2 * @as(usize, @min(i, 20));
                qi = range.laplaceDecode(dec, @as(u32, prob[pi]) << 7, @as(i32, prob[pi + 1]) << 6);
            } else if (budget - tell >= 2) {
                const v: i32 = @intCast(dec.icdf(&tables.small_energy_icdf, 2));
                qi = (v >> 1) ^ -(v & 1);
            } else if (budget - tell >= 1) {
                qi = -@as(i32, @intFromBool(dec.bitLogp(1)));
            } else {
                qi = -1;
            }
            const q: f32 = @floatFromInt(qi);
            const idx = i + c * nb;
            old[idx] = @max(-9.0, old[idx]);
            old[idx] = coef * old[idx] + prev[c] + q;
            prev[c] = prev[c] + q - beta * q;
        }
    }
}

/// Reads the fine energy bits. `fine_quant` is the bits per band from the allocation.
pub fn unquantFine(
    start: u32,
    end: u32,
    old: *Energies,
    fine_quant: *const [nb]i32,
    dec: *range.Decoder,
    channels: u32,
) void {
    for (start..end) |i| {
        const extra = std.math.clamp(fine_quant[i], 0, max_fine_bits);
        if (extra <= 0) continue;
        if (dec.tell() + @as(i32, @intCast(channels)) * extra > @as(i32, @intCast(dec.storage * 8))) continue;
        for (0..channels) |c| {
            const q2: f32 = @floatFromInt(dec.bits(@intCast(extra)));
            const scale: f32 = @floatFromInt(@as(u32, 1) << @intCast(14 - extra));
            old[i + c * nb] += (q2 + 0.5) * scale * (1.0 / 16384.0) - 0.5;
        }
    }
}

/// Uses the bits that are left for one more energy bit per band, first for the bands with priority 0.
pub fn unquantFinalise(
    start: u32,
    end: u32,
    old: *Energies,
    fine_quant: *const [nb]i32,
    fine_priority: *const [nb]bool,
    bits_left_in: i32,
    dec: *range.Decoder,
    channels: u32,
) void {
    var bits_left = bits_left_in;
    const ch: i32 = @intCast(channels);
    for (0..2) |prio| {
        var i: usize = start;
        while (i < end and bits_left >= ch) : (i += 1) {
            if (fine_quant[i] >= max_fine_bits or @intFromBool(fine_priority[i]) != prio) continue;
            const fq = @max(fine_quant[i], 0);
            const scale: f32 = @floatFromInt(@as(u32, 1) << @intCast(14 - fq - 1));
            for (0..channels) |c| {
                const q2: f32 = @floatFromInt(dec.bits(1));
                old[i + c * nb] += (q2 - 0.5) * scale * (1.0 / 16384.0);
                bits_left -= 1;
            }
        }
    }
}

/// The log2 of band amplitudes, less the mean of each band (amp2Log2). Bands from `eff_end`
/// to `end` get a floor.
pub fn amplitudeToLog(band_e: *const Energies, out: *Energies, eff_end: u32, end: u32, channels: u32) void {
    for (0..channels) |c| {
        for (0..eff_end) |i| {
            const l: f32 = @floatCast(1.442695040888963387 * @log(@as(f64, band_e[c * nb + i])));
            out[c * nb + i] = l - tables.e_means[i];
        }
        for (eff_end..end) |i| out[c * nb + i] = -14.0;
    }
}

fn lossDistortion(e_bands: *const Energies, old: *const Energies, start: u32, end: u32, channels: u32) f32 {
    var dist: f32 = 0;
    for (0..channels) |c| {
        for (start..end) |i| {
            const d = e_bands[c * nb + i] - old[c * nb + i];
            dist += d * d;
        }
    }
    return @min(200.0, dist);
}

const CoarseParams = struct {
    start: u32,
    end: u32,
    budget: i32,
    channels: u32,
    lm: u32,
    max_decay: f32,
    lfe: bool,
};

/// Writes the coarse energy with a fixed step of one unit and returns how far the clamps moved
/// it (quant_coarse_energy_impl).
fn quantCoarseImpl(p: CoarseParams, e_bands: *const Energies, old: *Energies, tell0: i32, intra: bool, err: *Energies, enc: *range.Encoder) i32 {
    var badness: i32 = 0;
    var prev = [2]f32{ 0, 0 };
    if (tell0 + 3 <= p.budget) enc.encodeBitLogp(intra, 3);
    const prob = &tables.e_prob_model[p.lm][@intFromBool(intra)];
    const coef: f32 = if (intra) 0 else tables.pred_coef[p.lm];
    const beta: f32 = if (intra) tables.beta_intra else tables.beta_coef[p.lm];
    const ch: i32 = @intCast(p.channels);
    for (p.start..p.end) |i| {
        for (0..p.channels) |c| {
            const idx = i + c * nb;
            const x = e_bands[idx];
            const old_e = @max(-9.0, old[idx]);
            const f = x - coef * old_e - prev[c];
            var qi = vq.floorInt(0.5 + f);
            const decay_bound = @max(-28.0, old[idx]) - p.max_decay;
            if (qi < 0 and x < decay_bound) {
                qi += @intFromFloat(std.math.clamp(decay_bound - x, 0, 1.0e6));
                if (qi > 0) qi = 0;
            }
            const qi0 = qi;
            const tell = enc.tell();
            const bits_left = p.budget - tell - 3 * ch * @as(i32, @intCast(p.end - i));
            if (i != p.start and bits_left < 30) {
                if (bits_left < 24) qi = @min(1, qi);
                if (bits_left < 16) qi = @max(-1, qi);
            }
            if (p.lfe and i >= 2) qi = @min(qi, 0);
            if (p.budget - tell >= 15) {
                const pi: usize = 2 * @as(usize, @min(i, 20));
                range.laplaceEncode(enc, &qi, @as(u32, prob[pi]) << 7, @as(i32, prob[pi + 1]) << 6);
            } else if (p.budget - tell >= 2) {
                qi = std.math.clamp(qi, -1, 1);
                const v: i32 = (2 * qi) ^ -@as(i32, @intFromBool(qi < 0));
                enc.encodeIcdf(@intCast(v), &tables.small_energy_icdf, 2);
            } else if (p.budget - tell >= 1) {
                qi = @min(0, qi);
                enc.encodeBitLogp(qi != 0, 1);
            } else {
                qi = -1;
            }
            err[idx] = f - @as(f32, @floatFromInt(qi));
            badness += @intCast(@abs(qi0 - qi));
            const q: f32 = @floatFromInt(qi);
            old[idx] = coef * old_e + prev[c] + q;
            prev[c] = prev[c] + q - beta * q;
        }
    }
    return if (p.lfe) 0 else badness;
}

/// A bias toward intra coding when losses are expected: `budget * delayed_intra * loss_rate / (channels * 512)`.
fn intraBias(budget: u32, delayed_intra: f32, loss_rate: u8, channels: u32) i32 {
    const v = @as(f32, @floatFromInt(budget)) * delayed_intra * @as(f32, @floatFromInt(loss_rate)) / @as(f32, @floatFromInt(channels * 512));
    if (!(v > -2147483648.0 and v < 2147483648.0)) return 0;
    return @intFromFloat(v);
}

/// Writes the coarse energy of the bands `start` to `end`. With `two_pass` it also codes the
/// frame without prediction and keeps the cheaper one (quant_coarse_energy). `old` is the energy
/// that the decoder will have afterwards, and `err` the part that was not coded.
pub fn quantCoarse(
    start: u32,
    end: u32,
    eff_end: u32,
    e_bands: *const Energies,
    old: *Energies,
    budget: u32,
    err: *Energies,
    enc: *range.Encoder,
    channels: u32,
    lm: u32,
    nb_available_bytes: u32,
    force_intra: bool,
    delayed_intra: *f32,
    two_pass_in: bool,
    loss_rate: u8,
    lfe: bool,
) void {
    const ch: f32 = @floatFromInt(channels);
    const span: u32 = end - start;
    var two_pass = two_pass_in;
    var intra = force_intra or (!two_pass and delayed_intra.* > 2 * ch * @as(f32, @floatFromInt(span)) and nb_available_bytes > span * channels);
    const intra_bias: i32 = intraBias(budget, delayed_intra.*, loss_rate, channels);
    const new_distortion = lossDistortion(e_bands, old, start, eff_end, channels);
    const tell = enc.tell();
    const budget_i: i32 = @intCast(@min(budget, 1 << 24));
    if (tell + 3 > budget_i) {
        two_pass = false;
        intra = false;
    }
    var max_decay: f32 = 16.0;
    if (span > 10) max_decay = @min(max_decay, 0.125 * @as(f32, @floatFromInt(nb_available_bytes)));
    if (lfe) max_decay = 3.0;
    const p: CoarseParams = .{ .start = start, .end = end, .budget = budget_i, .channels = channels, .lm = lm, .max_decay = max_decay, .lfe = lfe };
    const enc_start_state = enc.*;
    var old_intra = old.*;
    var err_intra: Energies = undefined;
    var badness1: i32 = 0;
    if (two_pass or intra) badness1 = quantCoarseImpl(p, e_bands, &old_intra, tell, true, &err_intra, enc);

    if (!intra) {
        const tell_intra = enc.tellFrac();
        const enc_intra_state = enc.*;
        const nstart = enc_start_state.offs;
        const nintra = enc_intra_state.offs;
        var saved: [1275]u8 = undefined;
        const save_len = @min(nintra - nstart, saved.len);
        @memcpy(saved[0..save_len], enc.buf[nstart..][0..save_len]);
        enc.* = enc_start_state;
        const badness2 = quantCoarseImpl(p, e_bands, old, tell, false, err, enc);
        if (two_pass and (badness1 < badness2 or (badness1 == badness2 and @as(i32, @intCast(enc.tellFrac())) +% intra_bias > @as(i32, @intCast(tell_intra))))) {
            enc.* = enc_intra_state;
            @memcpy(enc.buf[nstart..][0..save_len], saved[0..save_len]);
            old.* = old_intra;
            err.* = err_intra;
            intra = true;
        }
    } else {
        old.* = old_intra;
        err.* = err_intra;
    }
    if (intra) {
        delayed_intra.* = new_distortion;
    } else {
        delayed_intra.* = tables.pred_coef[lm] * tables.pred_coef[lm] * delayed_intra.* + new_distortion;
    }
}

/// Writes the fine energy bits of each band and moves `old` and `err` by what they code
/// (quant_fine_energy).
pub fn quantFine(start: u32, end: u32, old: *Energies, err: *Energies, fine_quant: *const [nb]i32, enc: *range.Encoder, channels: u32) void {
    for (start..end) |i| {
        const extra_bits = fine_quant[i];
        if (extra_bits <= 0) continue;
        const extra: i32 = @as(i32, 1) << @intCast(extra_bits);
        if (enc.tell() + @as(i32, @intCast(channels)) * extra_bits > @as(i32, @intCast(enc.storage * 8))) continue;
        for (0..channels) |c| {
            const idx = i + c * nb;
            var q2 = vq.floorInt((err[idx] + 0.5) * @as(f32, @floatFromInt(extra)));
            q2 = std.math.clamp(q2, 0, extra - 1);
            enc.encodeBits(@intCast(q2), @intCast(extra_bits));
            const scale: f32 = @floatFromInt(@as(u32, 1) << @intCast(14 - extra_bits));
            const offset = (@as(f32, @floatFromInt(q2)) + 0.5) * scale * (1.0 / 16384.0) - 0.5;
            old[idx] += offset;
            err[idx] -= offset;
        }
    }
}

/// Spends the bits that are left on one more energy bit per band (quant_energy_finalise).
/// `old` is null when only `err` is needed.
pub fn quantFinalise(
    start: u32,
    end: u32,
    old: ?*Energies,
    err: *Energies,
    fine_quant: *const [nb]i32,
    fine_priority: *const [nb]bool,
    bits_left_in: i32,
    enc: *range.Encoder,
    channels: u32,
) void {
    var bits_left = bits_left_in;
    const ch: i32 = @intCast(channels);
    for (0..2) |prio| {
        var i: usize = start;
        while (i < end and bits_left >= ch) : (i += 1) {
            if (fine_quant[i] >= max_fine_bits or @intFromBool(fine_priority[i]) != prio) continue;
            const fq = @max(fine_quant[i], 0);
            const scale: f32 = @floatFromInt(@as(u32, 1) << @intCast(14 - fq - 1));
            for (0..channels) |c| {
                const idx = i + c * nb;
                const q2: u32 = if (err[idx] < 0) 0 else 1;
                enc.encodeBits(q2, 1);
                const offset = (@as(f32, @floatFromInt(q2)) - 0.5) * scale * (1.0 / 16384.0);
                if (old) |o| o[idx] += offset;
                err[idx] -= offset;
                bits_left -= 1;
            }
        }
    }
}

const testing = std.testing;

test "coarse energy of a silent stream falls back to -1 steps" {
    var dec = range.Decoder.init(&.{});
    var old: Energies = @splat(0);
    unquantCoarse(0, 21, &old, true, &dec, 1, 3);
    // With no bytes the budget is empty, so every band gets qi = -1 with the intra weights.
    var prev: f32 = 0;
    for (0..21) |i| {
        const expect = prev - 1;
        try testing.expectApproxEqAbs(expect, old[i], 1e-6);
        prev = prev - 1 + tables.beta_intra;
    }
}

test "fine energy offsets split the interval" {
    var buf = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var dec = range.Decoder.init(&buf);
    var old: Energies = @splat(0);
    var fq: [nb]i32 = @splat(0);
    fq[2] = 3;
    unquantFine(0, 21, &old, &fq, &dec, 1);
    try testing.expectEqual(@as(f32, 0.4375), old[2]);
    try testing.expectEqual(@as(f32, 0), old[1]);
}

test "coarse and fine energy decode to what the encoder keeps" {
    var rng: @import("../test_util.zig").Xorshift = .{ .s = 4 };
    for (0..200) |round| {
        const channels: u32 = 1 + rng.next() % 2;
        const lm: u32 = rng.next() % 4;
        var target: Energies = @splat(0);
        var old: Energies = @splat(0);
        for (0..channels) |c| {
            for (0..nb) |i| {
                target[c * nb + i] = @as(f32, @floatFromInt(@as(i32, @bitCast(rng.next())) >> 8)) / 8388608.0 * 6.0;
                old[c * nb + i] = @as(f32, @floatFromInt(@as(i32, @bitCast(rng.next())) >> 8)) / 8388608.0 * 3.0;
            }
        }
        var dec_old = old;
        var buf: [400]u8 = undefined;
        var enc = range.Encoder.init(&buf);
        var err: Energies = @splat(0);
        var delayed: f32 = 1;
        quantCoarse(0, nb, nb, &target, &old, buf.len * 8, &err, &enc, channels, lm, 100, round % 5 == 0, &delayed, round % 2 == 0, 0, false);
        // The error is what the coarse step leaves, at most a half unit unless a clamp moved it.
        for (0..channels) |c| {
            for (0..nb) |i| try testing.expect(@abs(err[c * nb + i]) < 8);
        }
        var fine_quant: [nb]i32 = undefined;
        var priority: [nb]bool = undefined;
        for (0..nb) |i| {
            fine_quant[i] = @intCast(rng.next() % 4);
            priority[i] = rng.next() % 2 == 0;
        }
        quantFine(0, nb, &old, &err, &fine_quant, &enc, channels);
        quantFinalise(0, nb, &old, &err, &fine_quant, &priority, 20, &enc, channels);
        enc.done();
        try testing.expect(!enc.err);

        var dec = range.Decoder.init(&buf);
        const intra = dec.bitLogp(3);
        unquantCoarse(0, nb, &dec_old, intra, &dec, channels, lm);
        unquantFine(0, nb, &dec_old, &fine_quant, &dec, channels);
        unquantFinalise(0, nb, &dec_old, &fine_quant, &priority, 20, &dec, channels);
        for (0..channels) |c| {
            for (0..nb) |i| try testing.expectApproxEqAbs(old[c * nb + i], dec_old[c * nb + i], 1e-4);
        }
    }
}
