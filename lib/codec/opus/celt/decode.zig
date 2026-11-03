//! CELT frame decoder at 48 kHz, ported from libopus celt/celt_decoder.c and celt/celt.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const range = @import("../range.zig");
const tables = @import("tables.zig");
const rate = @import("rate.zig");
const energy = @import("energy.zig");
const bands = @import("bands.zig");
const mdct = @import("mdct.zig");
const vq = @import("vq.zig");
const pitch = @import("pitch.zig");

const nb = tables.nb_ebands;
const eb = tables.eband5ms;
const bitres = 3;
const overlap = 120;
const decode_buffer = 2048;
const mem_len = decode_buffer + overlap;
const min_period = 15;
const max_frame_samples = 960;
const preemph: f32 = 0.85000610;

pub const Error = bands.Error || error{InvalidPacket};

/// What the last frame was, for the concealment of the next one.
const FrameType = enum { none, normal, noise, periodic };

const max_period = 1024;
const plc_pitch_max = 720;
const plc_pitch_min = 100;

pub const Decoder = struct {
    /// Output channels.
    channels: u32,
    /// First coded band. A hybrid frame starts at 17.
    start: u32 = 0,
    /// One after the last coded band.
    end: u32 = nb,
    /// Skips the stereo phase inversion.
    disable_inv: bool,
    /// The range of the last frame, which seeds the noise of the next one.
    rng: u32 = 0,
    period: i32 = 0,
    period_old: i32 = 0,
    gain: f32 = 0,
    gain_old: f32 = 0,
    tapset: u32 = 0,
    tapset_old: u32 = 0,
    preemph_mem: [2]f32 = .{ 0, 0 },
    mem: [2][mem_len]f32,
    old_band_e: energy.Energies,
    old_log_e: energy.Energies,
    old_log_e2: energy.Energies,
    background_log_e: energy.Energies,
    last_pitch_index: i32,
    loss_duration: i32,
    plc_duration: i32,
    last_frame_type: FrameType,
    skip_plc: bool,
    prefilter_and_fold: bool,
    plc_lpc: [2][pitch.lpc_order]f32,

    pub fn init(channels: u32, disable_inv: bool) Decoder {
        std.debug.assert(channels == 1 or channels == 2);
        var self: Decoder = undefined;
        self.channels = channels;
        self.disable_inv = disable_inv;
        self.start = 0;
        self.end = nb;
        self.reset();
        return self;
    }

    pub fn reset(self: *Decoder) void {
        self.rng = 0;
        self.period = 0;
        self.period_old = 0;
        self.gain = 0;
        self.gain_old = 0;
        self.tapset = 0;
        self.tapset_old = 0;
        self.preemph_mem = .{ 0, 0 };
        self.mem = @splat(@splat(0));
        self.old_band_e = @splat(0);
        self.old_log_e = @splat(-28);
        self.old_log_e2 = @splat(-28);
        self.background_log_e = @splat(0);
        self.last_pitch_index = 0;
        self.loss_duration = 0;
        self.plc_duration = 0;
        self.last_frame_type = .none;
        self.skip_plc = true;
        self.prefilter_and_fold = false;
        self.plc_lpc = @splat(@splat(0));
    }

    /// Decodes one frame of `120 << lm` samples. `data` holds the frame bytes, at least two.
    /// With `ext` the symbols come from a range decoder that already read the first symbols
    /// (the SILK part of a hybrid frame). The output goes to `pcm`, interleaved over `channels`
    /// channels, and is added to it when `accum` is set.
    pub fn decode(
        self: *Decoder,
        data: []const u8,
        ext: ?*range.Decoder,
        stream_channels: u32,
        lm: u32,
        pcm: []f32,
        accum: bool,
    ) Error!void {
        if (data.len < 2 or data.len > 1275 or lm > tables.max_lm) return error.InvalidPacket;
        std.debug.assert(stream_channels == 1 or stream_channels == 2);
        std.debug.assert(self.start < self.end and self.end <= nb);
        const m: u32 = @as(u32, 1) << @intCast(lm);
        const n: usize = 120 * m;
        const cc: usize = self.channels;
        const c: usize = stream_channels;
        std.debug.assert(pcm.len >= n * cc);
        const start = self.start;
        const end = self.end;
        const old = &self.old_band_e;
        if (self.loss_duration == 0) self.skip_plc = false;

        var local: range.Decoder = undefined;
        const dec: *range.Decoder = if (ext) |e| e else blk: {
            local = range.Decoder.init(data);
            break :blk &local;
        };

        if (c == 1) {
            for (0..nb) |i| old[i] = @max(old[i], old[nb + i]);
        }

        const len: i32 = @intCast(data.len);
        const total_bits = len * 8;
        var tell = dec.tell();
        var silence = false;
        if (tell >= total_bits) {
            silence = true;
        } else if (tell == 1) {
            silence = dec.bitLogp(15);
        }
        if (silence) {
            tell = total_bits;
            dec.nbits_total += tell - dec.tell();
        }

        var pf_gain: f32 = 0;
        var pf_pitch: i32 = 0;
        var pf_tapset: u32 = 0;
        if (start == 0 and tell + 16 <= total_bits) {
            if (dec.bitLogp(1)) {
                const octave: u32 = dec.uint(6);
                pf_pitch = (@as(i32, 16) << @intCast(octave)) + @as(i32, @intCast(dec.bits(@intCast(4 + octave)))) - 1;
                const qg: u32 = dec.bits(3);
                if (dec.tell() + 2 <= total_bits) pf_tapset = dec.icdf(&tables.tapset_icdf, 2);
                pf_gain = 0.09375 * @as(f32, @floatFromInt(qg + 1));
            }
            tell = dec.tell();
        }

        var is_transient = false;
        if (lm > 0 and tell + 3 <= total_bits) {
            is_transient = dec.bitLogp(3);
            tell = dec.tell();
        }
        const intra = if (tell + 3 <= total_bits) dec.bitLogp(3) else false;
        if (!intra and self.loss_duration != 0) self.energySafety(lm);

        energy.unquantCoarse(start, end, old, intra, dec, @intCast(c), lm);

        var tf_res: [nb]i32 = @splat(0);
        tfDecode(start, end, is_transient, &tf_res, lm, dec);

        tell = dec.tell();
        var spread: vq.Spread = .normal;
        if (tell + 4 <= total_bits) spread = @fromBackingInt(@intCast(dec.icdf(&tables.spread_icdf, 5)));

        var cap: [nb]i32 = undefined;
        rate.initCaps(&cap, lm, @intCast(c));

        var offsets: [nb]i32 = @splat(0);
        var dynalloc_logp: i32 = 6;
        var bits8 = total_bits << bitres;
        var tell8: i32 = @intCast(dec.tellFrac());
        for (start..end) |i| {
            const width: i32 = @as(i32, @intCast(c)) * (eb[i + 1] - eb[i]) << @intCast(lm);
            const quanta = @min(width << bitres, @max(6 << bitres, width));
            var loop_logp = dynalloc_logp;
            var boost: i32 = 0;
            while (tell8 + (loop_logp << bitres) < bits8 and boost < cap[i]) {
                const flag = dec.bitLogp(@intCast(loop_logp));
                tell8 = @intCast(dec.tellFrac());
                if (!flag) break;
                boost += quanta;
                bits8 -= quanta;
                loop_logp = 1;
            }
            offsets[i] = boost;
            if (boost > 0) dynalloc_logp = @max(2, dynalloc_logp - 1);
        }

        const alloc_trim: i32 = if (tell8 + (6 << bitres) <= bits8) @intCast(dec.icdf(&tables.trim_icdf, 7)) else 5;

        var bits: i32 = (len * 8 << bitres) - @as(i32, @intCast(dec.tellFrac())) - 1;
        const anti_collapse_rsv: i32 = if (is_transient and lm >= 2 and bits >= (@as(i32, @intCast(lm)) + 2) << bitres) 1 << bitres else 0;
        bits -= anti_collapse_rsv;

        var alloc: rate.Allocation = .{};
        const coded_bands = rate.computeAllocation(.{
            .start = start,
            .end = end,
            .offsets = &offsets,
            .caps = &cap,
            .alloc_trim = alloc_trim,
            .total = std.math.clamp(bits, -100_000, 100_000),
            .channels = @intCast(c),
            .lm = lm,
        }, .{ .decoder = dec }, &alloc);

        energy.unquantFine(start, end, old, &alloc.fine_quant, dec, @intCast(c));

        var x_buf: [2 * max_frame_samples]f32 = undefined;
        const x = x_buf[0 .. c * n];
        var masks: [2 * nb]u8 = @splat(0);
        try bands.quantAllBands(.{
            .start = start,
            .end = end,
            .lm = lm,
            .channels = @intCast(c),
            .short_blocks = is_transient,
            .spread = spread,
            .dual_stereo = alloc.dual_stereo,
            .intensity = alloc.intensity,
            .tf_res = &tf_res,
            .pulses = &alloc.pulses,
            .total_bits = len * (8 << bitres) - anti_collapse_rsv,
            .balance = alloc.balance,
            .coded_bands = coded_bands,
            .disable_inv = self.disable_inv,
        }, x, &masks, dec, &self.rng);

        for (0..cc) |ch| {
            const buf = &self.mem[ch];
            std.mem.copyForwards(f32, buf[0 .. mem_len - n], buf[n..mem_len]);
        }

        var anti_collapse_on = false;
        if (anti_collapse_rsv > 0) anti_collapse_on = dec.bits(1) != 0;
        energy.unquantFinalise(start, end, old, &alloc.fine_quant, &alloc.fine_priority, len * 8 - dec.tell(), dec, @intCast(c));
        if (anti_collapse_on) {
            bands.antiCollapse(x, &masks, lm, @intCast(c), start, end, old, &self.old_log_e, &self.old_log_e2, &alloc.pulses, self.rng);
        }
        if (silence) {
            for (0..c * nb) |i| old[i] = -28;
        }

        if (self.prefilter_and_fold) self.prefilterAndFold(n);
        self.synthesis(x, is_transient, lm, c, silence);

        for (0..cc) |ch| {
            const pos = decode_buffer - n;
            self.period = @max(self.period, min_period);
            self.period_old = @max(self.period_old, min_period);
            combFilter(&self.mem[ch], pos, self.period_old, self.period, 120, self.gain_old, self.gain, self.tapset_old, self.tapset);
            if (lm != 0) {
                combFilter(&self.mem[ch], pos + 120, self.period, pf_pitch, n - 120, self.gain, pf_gain, self.tapset, pf_tapset);
            }
        }
        self.period_old = self.period;
        self.gain_old = self.gain;
        self.tapset_old = self.tapset;
        self.period = pf_pitch;
        self.gain = pf_gain;
        self.tapset = pf_tapset;
        if (lm != 0) {
            self.period_old = self.period;
            self.gain_old = self.gain;
            self.tapset_old = self.tapset;
        }

        if (c == 1) @memcpy(old[nb..], old[0..nb]);
        if (!is_transient) {
            self.old_log_e2 = self.old_log_e;
            self.old_log_e = old.*;
        } else {
            for (0..2 * nb) |i| self.old_log_e[i] = @min(self.old_log_e[i], old[i]);
        }
        const inc: f32 = @as(f32, @floatFromInt(@min(160, self.loss_duration + @as(i32, @intCast(m))))) * 0.001;
        for (0..2 * nb) |i| self.background_log_e[i] = @min(self.background_log_e[i] + inc, old[i]);
        for (0..2) |ch| {
            for (0..nb) |i| {
                if (i < start or i >= end) {
                    old[ch * nb + i] = 0;
                    self.old_log_e[ch * nb + i] = -28;
                    self.old_log_e2[ch * nb + i] = -28;
                }
            }
        }
        self.rng = dec.finalRange();

        self.deemphasis(pcm, n, accum);
        self.loss_duration = 0;
        self.plc_duration = 0;
        self.last_frame_type = .normal;
        self.prefilter_and_fold = false;
        if (dec.tell() > 8 * len) return error.InvalidPacket;
    }

    /// Makes `120 << lm` samples for a frame that is missing, from the state after the last good
    /// frame (celt_decode_lost), and writes them to `pcm` like `decode`. The first losses repeat
    /// the pitch. A later loss, a start band above 0 and the first loss after a reset or an earlier
    /// noise frame use noise at a decaying band energy.
    pub fn concealFrame(self: *Decoder, pcm: []f32, lm: u32, accum: bool) void {
        std.debug.assert(lm <= tables.max_lm);
        const n: usize = @as(usize, 120) << @intCast(lm);
        std.debug.assert(pcm.len >= n * self.channels);
        const step: i32 = @as(i32, 1) << @intCast(lm);
        const noise = self.plc_duration >= 40 or self.start != 0 or self.skip_plc;
        if (noise) {
            self.concealNoise(n, lm);
            self.last_frame_type = .noise;
        } else {
            self.concealPeriodic(n);
            self.last_frame_type = .periodic;
        }
        self.deemphasis(pcm, n, accum);
        self.loss_duration = @min(10000, self.loss_duration + step);
        self.plc_duration = @min(10000, self.plc_duration + step);
    }

    fn concealNoise(self: *Decoder, n: usize, lm: u32) void {
        const cc: usize = self.channels;
        const start = self.start;
        const end = self.end;
        const eff_end = @max(start, @min(end, nb));
        for (0..cc) |c| {
            const buf = &self.mem[c];
            std.mem.copyForwards(f32, buf[0 .. mem_len - n], buf[n..mem_len]);
        }
        if (self.prefilter_and_fold) self.prefilterAndFold(n);

        const decay: f32 = if (self.loss_duration == 0) 1.5 else 0.5;
        for (0..cc) |c| {
            for (start..end) |i| {
                const at = c * nb + i;
                self.old_band_e[at] = @max(self.background_log_e[at], self.old_band_e[at] - decay);
            }
        }
        var x: [2 * max_frame_samples]f32 = @splat(0);
        var seed = self.rng;
        for (0..cc) |c| {
            for (start..eff_end) |i| {
                const lo: usize = @as(usize, @intCast(eb[i])) << @intCast(lm);
                const hi: usize = @as(usize, @intCast(eb[i + 1])) << @intCast(lm);
                const band = x[n * c + lo .. n * c + hi];
                for (band) |*v| {
                    seed = bands.lcg(seed);
                    v.* = @floatFromInt(@as(i32, @bitCast(seed)) >> 20);
                }
                vq.renormaliseVector(band, 1.0);
            }
        }
        self.rng = seed;
        self.synthesis(&x, false, lm, cc, false);

        for (0..cc) |c| {
            const pos = decode_buffer - n;
            self.period = @max(self.period, min_period);
            self.period_old = @max(self.period_old, min_period);
            combFilter(&self.mem[c], pos, self.period_old, self.period, 120, self.gain_old, self.gain, self.tapset_old, self.tapset);
            if (lm != 0) {
                combFilter(&self.mem[c], pos + 120, self.period, self.period, n - 120, self.gain, self.gain, self.tapset, self.tapset);
            }
        }
        self.period_old = self.period;
        self.gain_old = self.gain;
        self.tapset_old = self.tapset;
        self.prefilter_and_fold = false;
        self.skip_plc = true;
    }

    /// Applies the post filter in reverse to the overlap of the concealed frame and folds it, so
    /// that it blends with the MDCT of the next frame.
    fn prefilterAndFold(self: *Decoder, n: usize) void {
        for (0..self.channels) |c| {
            const buf = &self.mem[c];
            var etmp: [overlap]f32 = undefined;
            combFilterTo(&etmp, buf, decode_buffer - n, self.period, -self.gain, self.tapset);
            for (0..overlap / 2) |i| {
                buf[decode_buffer - n + i] = tables.window120[i] * etmp[overlap - 1 - i] + tables.window120[overlap - i - 1] * etmp[i];
            }
        }
    }

    /// Lowers the predicted band energies after a loss, so that a coarse energy delta cannot
    /// make a loud frame.
    fn energySafety(self: *Decoder, lm: u32) void {
        const old = &self.old_band_e;
        const missing: i32 = @min(10, self.loss_duration >> @intCast(lm));
        const safety: f32 = if (lm == 0) 1.5 else if (lm == 1) 0.5 else 0;
        for (0..2) |c| {
            for (self.start..self.end) |i| {
                const at = c * nb + i;
                if (old[at] < @max(self.old_log_e[at], self.old_log_e2[at])) {
                    var e0 = old[at];
                    const e1 = self.old_log_e[at];
                    const e2 = self.old_log_e2[at];
                    const slope = @min(@max(e1 - e0, 0.5 * (e2 - e0)), 2.0);
                    e0 -= @max(0, @as(f32, @floatFromInt(1 + missing)) * slope);
                    old[at] = @max(-20.0, e0);
                } else {
                    old[at] = @min(@min(old[at], self.old_log_e[at]), self.old_log_e2[at]);
                }
                old[at] -= safety;
            }
        }
    }

    fn concealPeriodic(self: *Decoder, n: usize) void {
        const cc: usize = self.channels;
        const lpc_order = pitch.lpc_order;
        var fade: f32 = 1.0;
        const first = self.last_frame_type != .periodic;
        if (first) {
            var lp: [decode_buffer >> 1]f32 = undefined;
            const mems = [2][]const f32{ &self.mem[0], &self.mem[1] };
            pitch.downsample(mems[0..cc], &lp);
            const found = pitch.search(lp[plc_pitch_max >> 1 ..], &lp, decode_buffer - plc_pitch_max, plc_pitch_max - plc_pitch_min);
            self.last_pitch_index = plc_pitch_max - @as(i32, @intCast(found));
        } else {
            fade = 0.8;
        }
        const pitch_index: usize = @intCast(self.last_pitch_index);
        const exc_length = @min(2 * pitch_index, max_period);
        const len = n + overlap;

        for (0..cc) |c| {
            const buf = &self.mem[c];
            const lpc = &self.plc_lpc[c];
            var exc_buf: [max_period + lpc_order]f32 = undefined;
            @memcpy(&exc_buf, buf[decode_buffer - max_period - lpc_order .. decode_buffer]);
            const exc = exc_buf[lpc_order..];
            if (first) {
                var ac: [lpc_order + 1]f32 = undefined;
                pitch.autocorr(exc, &ac, &tables.window120, overlap, lpc_order, max_period);
                ac[0] *= 1.0001;
                const w: f32 = 0.008 * 0.008;
                for (1..lpc_order + 1) |i| {
                    const f: f32 = @floatFromInt(i);
                    ac[i] -= ac[i] * w * f * f;
                }
                pitch.lpcFromAutocorr(lpc, &ac);
            }
            var fir_tmp: [max_period]f32 = undefined;
            pitch.fir(&exc_buf, lpc_order + max_period - exc_length, lpc, fir_tmp[0..exc_length]);
            @memcpy(exc_buf[lpc_order + max_period - exc_length ..], fir_tmp[0..exc_length]);

            var e1: f32 = 1;
            var e2: f32 = 1;
            const decay_length = exc_length >> 1;
            for (0..decay_length) |i| {
                const a = exc[max_period - decay_length + i];
                e1 += a * a;
                const b = exc[max_period - 2 * decay_length + i];
                e2 += b * b;
            }
            e1 = @min(e1, e2);
            const decay = @sqrt(e1 / e2);

            std.mem.copyForwards(f32, buf[0 .. decode_buffer - n], buf[n..decode_buffer]);

            const offset = max_period - pitch_index;
            var attenuation = fade * decay;
            var s1: f32 = 0;
            var j: usize = 0;
            for (0..len) |i| {
                if (j >= pitch_index) {
                    j -= pitch_index;
                    attenuation = attenuation * decay;
                }
                buf[decode_buffer - n + i] = attenuation * exc[offset + j];
                const t = buf[decode_buffer - max_period - n + offset + j];
                s1 += t * t;
                j += 1;
            }
            var mem: [lpc_order]f32 = undefined;
            for (0..lpc_order) |i| mem[i] = buf[decode_buffer - n - 1 - i];
            pitch.iir(buf[decode_buffer - n ..][0..len], lpc, &mem);

            var s2: f32 = 0;
            for (buf[decode_buffer - n ..][0..len]) |v| s2 += v * v;
            const out = buf[decode_buffer - n ..][0..len];
            if (!(s1 > 0.2 * s2)) {
                @memset(out, 0);
            } else if (s1 < s2) {
                const ratio = @sqrt((s1 + 1) / (s2 + 1));
                for (out[0..overlap], tables.window120) |*v, w| v.* *= 1.0 - w * (1.0 - ratio);
                for (out[overlap..]) |*v| v.* *= ratio;
            }
        }
        self.prefilter_and_fold = true;
    }

    fn synthesis(self: *Decoder, x: []const f32, is_transient: bool, lm: u32, c: usize, silence: bool) void {
        const cc: usize = self.channels;
        const m: usize = @as(usize, 1) << @intCast(lm);
        const n = 120 * m;
        const blocks: usize = if (is_transient) m else 1;
        const block_len: usize = if (is_transient) 120 else n;
        const shift: u2 = @intCast(if (is_transient) 3 else 3 - lm);
        const end = @min(self.end, nb);
        var freq: [max_frame_samples]f32 = undefined;
        var freq2: [max_frame_samples]f32 = undefined;
        if (cc == 2 and c == 1) {
            bands.denormalise(x[0..n], freq[0..n], self.old_band_e[0..nb], self.start, end, lm, silence);
            for (0..2) |ch| {
                const out = self.mem[ch][decode_buffer - n ..];
                for (0..blocks) |b| mdct.backward(freq[b..n], blocks, out[block_len * b ..], shift);
            }
        } else if (cc == 1 and c == 2) {
            bands.denormalise(x[0..n], freq[0..n], self.old_band_e[0..nb], self.start, end, lm, silence);
            bands.denormalise(x[n..][0..n], freq2[0..n], self.old_band_e[nb..][0..nb], self.start, end, lm, silence);
            for (freq[0..n], freq2[0..n]) |*a, b| a.* = 0.5 * a.* + 0.5 * b;
            const out = self.mem[0][decode_buffer - n ..];
            for (0..blocks) |b| mdct.backward(freq[b..n], blocks, out[block_len * b ..], shift);
        } else {
            for (0..cc) |ch| {
                bands.denormalise(x[ch * n ..][0..n], freq[0..n], self.old_band_e[ch * nb ..][0..nb], self.start, end, lm, silence);
                const out = self.mem[ch][decode_buffer - n ..];
                for (0..blocks) |b| mdct.backward(freq[b..n], blocks, out[block_len * b ..], shift);
            }
        }
    }

    fn deemphasis(self: *Decoder, pcm: []f32, n: usize, accum: bool) void {
        const cc: usize = self.channels;
        for (0..cc) |ch| {
            var mem = self.preemph_mem[ch];
            const src = self.mem[ch][decode_buffer - n .. decode_buffer];
            for (src, 0..) |s, j| {
                const tmp = s + 1e-30 + mem;
                mem = preemph * tmp;
                const v = (1.0 / 32768.0) * tmp;
                if (accum) {
                    pcm[j * cc + ch] += v;
                } else {
                    pcm[j * cc + ch] = v;
                }
            }
            self.preemph_mem[ch] = mem;
        }
    }
};

fn tfDecode(start: u32, end: u32, is_transient: bool, tf_res: *[nb]i32, lm: u32, dec: *range.Decoder) void {
    var budget: i32 = @intCast(dec.storage * 8);
    var tell = dec.tell();
    var logp: u5 = if (is_transient) 2 else 4;
    const select_rsv = lm > 0 and tell + logp + 1 <= budget;
    budget -= @intFromBool(select_rsv);
    var curr: i32 = 0;
    var tf_changed: i32 = 0;
    for (start..end) |i| {
        if (tell + logp <= budget) {
            curr ^= @intFromBool(dec.bitLogp(logp));
            tell = dec.tell();
            tf_changed |= curr;
        }
        tf_res[i] = curr;
        logp = if (is_transient) 4 else 5;
    }
    const row = &tables.tf_select_table[lm];
    const base: usize = if (is_transient) 4 else 0;
    var tf_select: usize = 0;
    if (select_rsv and row[base + @as(usize, @intCast(tf_changed))] != row[base + 2 + @as(usize, @intCast(tf_changed))]) {
        tf_select = @intFromBool(dec.bitLogp(1));
    }
    for (start..end) |i| {
        tf_res[i] = row[base + 2 * tf_select + @as(usize, @intCast(tf_res[i]))];
    }
}

/// The post filter on `h[pos .. pos + len]` in place (comb_filter). It reads the filtered
/// samples before `pos` as history. A change of period or gain fades over the overlap.
fn combFilter(h: []f32, pos: usize, t0: i32, t1: i32, len: usize, g0: f32, g1: f32, tapset0: u32, tapset1: u32) void {
    pitch.combFilter(h, pos, h, pos, t0, t1, len, g0, g1, tapset0, tapset1, overlap);
}

/// The constant post filter over `y.len` samples of `x` from `pos`, written to `y` (comb_filter
/// with no overlap and `x` not equal to `y`). The history comes from `x`.
fn combFilterTo(y: []f32, x: []const f32, pos: usize, t_in: i32, g: f32, tapset: u32) void {
    pitch.combFilter(y, 0, x, pos, t_in, t_in, y.len, g, g, tapset, tapset, 0);
}
const testing = std.testing;

test "post filter echoes an impulse through the taps" {
    var h: [mem_len]f32 = @splat(0);
    h[1500] = 1;
    combFilter(&h, 1500, 20, 20, 100, 0.5, 0.5, 1, 1);
    const g0: f32 = 0.5 * 0.4638671875;
    const g1: f32 = 0.5 * 0.2680664062;
    try testing.expectEqual(@as(f32, 1), h[1500]);
    try testing.expectEqual(g0, h[1520]);
    try testing.expectEqual(g1, h[1519]);
    try testing.expectEqual(g1, h[1521]);
    try testing.expectEqual(@as(f32, 0), h[1530]);
    // The second echo is made from the first, as the filter runs in place.
    try testing.expectApproxEqAbs(g0 * g0 + 2 * g1 * g1, h[1540], 1e-7);
}

test "post filter with zero gains leaves the samples" {
    var h: [mem_len]f32 = undefined;
    for (&h, 0..) |*v, i| v.* = @floatFromInt(i);
    combFilter(&h, 1200, 30, 40, 200, 0, 0, 0, 2);
    for (h, 0..) |v, i| try testing.expectEqual(@as(f32, @floatFromInt(i)), v);
}

test "de-emphasis runs a one pole filter and scales to 1.0" {
    var d = Decoder.init(1, true);
    const n = 240;
    @memset(d.mem[0][decode_buffer - n .. decode_buffer], 32768);
    var pcm: [n]f32 = undefined;
    d.deemphasis(&pcm, n, false);
    var mem: f32 = 0;
    for (0..n) |_| mem = preemph * (32768 + 1e-30 + mem);
    const second = (1.0 / 32768.0) * (32768 + 1e-30 + mem);
    try testing.expectApproxEqAbs(@as(f32, 1.0), pcm[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0 + preemph), pcm[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0 + preemph + preemph * preemph), pcm[2], 1e-6);
    d.deemphasis(&pcm, n, true);
    try testing.expectEqual(1.0 + second, pcm[0]);
}

test "reset clears the history and sets the energy floor" {
    var d = Decoder.init(2, false);
    d.rng = 5;
    d.old_band_e[3] = 2;
    d.mem[1][100] = 1;
    d.reset();
    try testing.expectEqual(@as(u32, 0), d.rng);
    try testing.expectEqual(@as(f32, 0), d.old_band_e[3]);
    try testing.expectEqual(@as(f32, -28), d.old_log_e2[41]);
    try testing.expectEqual(@as(f32, 0), d.mem[1][100]);
}

test "frames of one byte and bad sizes are rejected" {
    var d = Decoder.init(2, false);
    var pcm: [960 * 2]f32 = undefined;
    try testing.expectError(error.InvalidPacket, d.decode(&.{0xFF}, null, 2, 3, &pcm, false));
    try testing.expectError(error.InvalidPacket, d.decode(&.{ 0xFF, 0xFF }, null, 2, 4, &pcm, false));
}

// A decaying history with two tones and noise. The expected samples below come from the
// libopus float concealment run on the same history.
fn syntheticHistory(d: *Decoder, seed: u32) void {
    var rng: @import("../test_util.zig").Xorshift = .{ .s = seed };
    for (0..2) |ch| {
        for (0..mem_len) |i| {
            if (i >= decode_buffer) {
                d.mem[ch][i] = 0;
                continue;
            }
            const fi: f64 = @floatFromInt(i);
            const fc: f64 = @floatFromInt(ch);
            const tone = 2500.0 * @sin(2.0 * std.math.pi * fi / (73.1 + fc * 2.5)) + 1200.0 * @sin(2.0 * std.math.pi * fi / 29.3 + fc);
            const noise = (@as(f64, @floatFromInt(rng.next() >> 20)) - 2048.0) * 0.2;
            d.mem[ch][i] = @floatCast(tone + noise);
        }
    }
}

test "the concealment of a 5 ms frame repeats the pitch like libopus" {
    var d = Decoder.init(2, false);
    syntheticHistory(&d, 1);
    d.skip_plc = false;
    d.last_frame_type = .normal;
    var pcm: [480]f32 = undefined;
    d.concealFrame(&pcm, 1, false);
    try testing.expectEqual(@as(i32, 145), d.last_pitch_index);
    try testing.expectEqual(@as(i32, 2), d.loss_duration);
    try testing.expectEqual(FrameType.periodic, d.last_frame_type);
    const at = [_]usize{ 0, 56, 118, 119, 199, 238, 239, 299, 358 };
    const left = [_]f32{ -37.3611221, -3284.09668, -2166.73413, -2231.72607, -3964.3501, 3302.47363, 2967.10645, 3398.24316, 711.668701 };
    const right = [_]f32{ 1789.48804, -2311.31372, -1596.37036, -1602.7251, -2766.02173, 3252.83862, 2846.88574, 3843.30054, 1426.24841 };
    for (at, left, right) |i, l, r| {
        try testing.expectApproxEqAbs(l, d.mem[0][decode_buffer - 240 + i], 0.5);
        try testing.expectApproxEqAbs(r, d.mem[1][decode_buffer - 240 + i], 0.5);
    }
    // The output is the de-emphasised history of the concealed frame.
    try testing.expectApproxEqAbs((1.0 / 32768.0) * (d.mem[0][decode_buffer - 240] + 1e-30), pcm[0], 1e-6);
}

test "concealment needs a good frame before it and the pitch method" {
    var d = Decoder.init(1, false);
    var pcm: [480]f32 = undefined;
    // A fresh decoder has no frame to repeat, so it makes noise.
    d.concealFrame(&pcm, 1, false);
    try testing.expectEqual(FrameType.noise, d.last_frame_type);
    try testing.expect(d.skip_plc);
    d.skip_plc = false;
    d.last_frame_type = .normal;
    d.plc_duration = 0;
    d.start = 17;
    d.concealFrame(&pcm, 1, false);
    try testing.expectEqual(FrameType.noise, d.last_frame_type);
}

test "noise concealment lowers the band energies by 1.5 and then by 0.5 down to the background" {
    var d = Decoder.init(1, true);
    d.old_band_e = @splat(4);
    d.background_log_e = @splat(1);
    var pcm: [240]f32 = undefined;
    d.concealFrame(&pcm, 1, false);
    try testing.expectEqual(@as(f32, 2.5), d.old_band_e[0]);
    try testing.expectEqual(@as(f32, 2.5), d.old_band_e[nb - 1]);
    try testing.expectEqual(FrameType.noise, d.last_frame_type);
    try testing.expect(d.rng != 0);
    d.concealFrame(&pcm, 1, false);
    try testing.expectEqual(@as(f32, 2.0), d.old_band_e[0]);
    for (0..6) |_| d.concealFrame(&pcm, 1, false);
    try testing.expectEqual(@as(f32, 1.0), d.old_band_e[3]);
    try testing.expectEqual(@as(i32, 16), d.loss_duration);
    for (pcm) |v| try testing.expect(std.math.isFinite(v) and @abs(v) < 1.0);
}

test "reset keeps the band range" {
    var d = Decoder.init(2, false);
    d.start = 17;
    d.end = 19;
    d.reset();
    try testing.expectEqual(@as(u32, 17), d.start);
    try testing.expectEqual(@as(u32, 19), d.end);
}

test "the energy safety lowers the prediction after a loss" {
    var d = Decoder.init(1, true);
    d.start = 0;
    d.end = 3;
    d.loss_duration = 4;
    // Band 0 is below the older energies and goes on falling, band 1 takes the minimum.
    d.old_band_e[0] = 1;
    d.old_log_e[0] = 3;
    d.old_log_e2[0] = 2;
    d.old_band_e[1] = 5;
    d.old_log_e[1] = 3;
    d.old_log_e2[1] = 4;
    d.old_band_e[2] = -19;
    d.old_log_e[2] = 0;
    d.old_log_e2[2] = 0;
    d.energySafety(1);
    try testing.expectEqual(@as(f32, -5.5), d.old_band_e[0]);
    try testing.expectEqual(@as(f32, 2.5), d.old_band_e[1]);
    try testing.expectEqual(@as(f32, -20.5), d.old_band_e[2]);
    d.old_band_e[0] = 5;
    d.energySafety(2);
    try testing.expectEqual(@as(f32, 2), d.old_band_e[0]);
}

test "the prefilter folds the overlap of a concealed frame" {
    var d = Decoder.init(1, true);
    d.gain = 0;
    d.period = 30;
    const n = 240;
    for (&d.mem[0], 0..) |*v, i| v.* = @floatFromInt(i % 17);
    var before: [overlap]f32 = undefined;
    @memcpy(&before, d.mem[0][decode_buffer - n ..][0..overlap]);
    d.prefilterAndFold(n);
    for (0..overlap / 2) |i| {
        const want = tables.window120[i] * before[overlap - 1 - i] + tables.window120[overlap - i - 1] * before[i];
        try testing.expectEqual(want, d.mem[0][decode_buffer - n + i]);
    }
    try testing.expectEqual(before[70], d.mem[0][decode_buffer - n + 70]);
}
