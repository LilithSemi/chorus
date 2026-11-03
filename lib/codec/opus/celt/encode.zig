//! CELT frame encoder at 48 kHz, ported from libopus celt/celt_encoder.c (float build, without
//! the tonality analysis). libopus is BSD 3 clause, see LICENSE-libopus.
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
const max_period = pitch.comb_max_period;
const min_period = pitch.comb_min_period;
const max_frame_samples = 960;
const max_frame_bytes = 1275;
const preemph: f32 = 0.85000610;

pub const Error = error{ BufferTooSmall, InvalidFrameSize, EncoderFailed };

const Energies = energy.Energies;

/// The C cast of a float to a 32 bit integer, cut to the range of a billion. NaN gives 0. The
/// SILK layer has its own rule, `silk.shape_enc.truncInt`, which libopus bit equality needs.
pub fn truncInt(v: f32) i32 {
    if (!(v == v)) return 0;
    return @intFromFloat(std.math.clamp(v, -1.0e9, 1.0e9));
}

/// A sample that is finite and has a bounded size.
fn sane(v: f32) f32 {
    if (v >= -1.0e5 and v <= 1.0e5) return v;
    if (v > 1.0e5) return 1.0e5;
    if (v < -1.0e5) return -1.0e5;
    return 0;
}

/// Looks for sudden increases of energy that the time domain analysis missed. The
/// analysis spreads the old energy and compares it with the new one (patch_transient_decision).
fn patchTransientDecision(new_e: *const Energies, old_e: *const Energies, start: u32, end: u32, channels: u32) bool {
    var spread_old: [nb]f32 = undefined;
    if (channels == 1) {
        spread_old[start] = old_e[start];
        for (start + 1..end) |i| spread_old[i] = @max(spread_old[i - 1] - 1.0, old_e[i]);
    } else {
        spread_old[start] = @max(old_e[start], old_e[nb + start]);
        for (start + 1..end) |i| spread_old[i] = @max(spread_old[i - 1] - 1.0, @max(old_e[i], old_e[i + nb]));
    }
    var i: usize = end - 2;
    while (true) : (i -= 1) {
        spread_old[i] = @max(spread_old[i], spread_old[i + 1] - 1.0);
        if (i == start) break;
    }
    var mean_diff: f32 = 0;
    for (0..channels) |c| {
        for (@max(2, start)..end - 1) |j| {
            const x1 = @max(0, new_e[j + c * nb]);
            const x2 = @max(0, spread_old[j]);
            mean_diff += @max(0, x1 - x2);
        }
    }
    const count: f32 = @floatFromInt(@as(i32, @intCast(channels)) * (@as(i32, @intCast(end)) - 1 - @as(i32, @intCast(@max(2, start)))));
    mean_diff /= count;
    return mean_diff > 1.0;
}

const Transient = struct {
    is_transient: bool,
    tf_estimate: f32,
    tf_chan: u32,
    /// A transient that a low rate hybrid frame codes as a long block (weak transient).
    weak: bool = false,
};

/// A pure or nearly pure tone found in the frame. `toneishness` is 0 when there is none.
const Tone = struct {
    freq: f32 = -1,
    toneishness: f32 = 0,
};

/// Fits a two pole predictor to `x` with the least squares of the forward and the backward
/// prediction (tone_lpc). Returns false when the fit fails.
fn toneLpc(x: []const f32, delay: usize, lpc: *[2]f32) bool {
    const len = x.len;
    var r00: f32 = 0;
    var r01: f32 = 0;
    var r02: f32 = 0;
    for (0..len - 2 * delay) |i| {
        r00 += x[i] * x[i];
        r01 += x[i] * x[i + delay];
        r02 += x[i] * x[i + 2 * delay];
    }
    var edges: f32 = 0;
    for (0..delay) |i| edges += x[len + i - 2 * delay] * x[len + i - 2 * delay] - x[i] * x[i];
    var r11 = r00 + edges;
    edges = 0;
    for (0..delay) |i| edges += x[len + i - delay] * x[len + i - delay] - x[i + delay] * x[i + delay];
    var r22 = r11 + edges;
    edges = 0;
    for (0..delay) |i| edges += x[len + i - 2 * delay] * x[len + i - delay] - x[i] * x[i + delay];
    var r12 = r01 + edges;
    const big_r00 = r00 + r22;
    const big_r01 = r01 + r12;
    const big_r11 = 2 * r11;
    const big_r02 = 2 * r02;
    const big_r12 = r12 + r01;
    r00 = big_r00;
    r01 = big_r01;
    r11 = big_r11;
    r02 = big_r02;
    r12 = big_r12;
    r22 = big_r00;
    const den = r00 * r11 - r01 * r01;
    if (!(den >= 0.001 * (r00 * r11))) return false;
    const num1 = r02 * r11 - r01 * r12;
    if (num1 >= den) {
        lpc[1] = 1.0;
    } else if (num1 <= -den) {
        lpc[1] = -1.0;
    } else {
        lpc[1] = num1 / den;
    }
    const num0 = r00 * r12 - r02 * r01;
    if (0.5 * num0 >= den) {
        lpc[0] = 1.999999;
    } else if (0.5 * num0 <= -den) {
        lpc[0] = -1.999999;
    } else {
        lpc[0] = num0 / den;
    }
    return true;
}

/// Looks for a pure tone in the pre-emphasised frame of `cc` channels of `len` samples each
/// (tone_detect). Stereo is summed.
fn toneDetect(input: []const f32, len: usize, cc: u32, x: []f32) Tone {
    if (cc == 2) {
        for (0..len) |i| x[i] = input[i] + input[i + len];
    } else {
        @memcpy(x[0..len], input[0..len]);
    }
    var delay: usize = 1;
    var lpc: [2]f32 = .{ 0, 0 };
    var ok = toneLpc(x[0..len], delay, &lpc);
    while (delay <= 48000 / 3000 and (!ok or (lpc[0] > 1.0 and lpc[1] < 0))) {
        delay *= 2;
        ok = toneLpc(x[0..len], delay, &lpc);
    }
    if (ok and lpc[0] * lpc[0] + 3.999999 * lpc[1] < 0) {
        const freq: f64 = std.math.acos(@as(f64, 0.5 * lpc[0])) / @as(f64, @floatFromInt(delay));
        return .{ .freq = @floatCast(freq), .toneishness = -lpc[1] };
    }
    return .{};
}

/// Decides from the energy envelope of the frame whether it holds an attack (transient_analysis).
/// `input` holds `channels` channels of `len` samples.
fn transientAnalysis(input: []const f32, len: usize, channels: u32, tone: Tone, allow_weak: bool) Transient {
    var tmp: [max_frame_samples + overlap]f32 = undefined;
    const forward_decay: f32 = if (allow_weak) 0.03125 else 0.0625;
    const len2 = len / 2;
    var mask_metric: i32 = 0;
    var tf_chan: u32 = 0;
    for (0..channels) |c| {
        var mem0: f32 = 0;
        var mem1: f32 = 0;
        for (0..len) |i| {
            const x = input[i + c * len];
            const y = mem0 + x;
            const mem00 = mem0;
            mem0 = mem0 - x + 0.5 * mem1;
            mem1 = x - mem00;
            tmp[i] = y;
        }
        @memset(tmp[0..12], 0);
        var mean: f32 = 0;
        mem0 = 0;
        for (0..len2) |i| {
            const x2 = tmp[2 * i] * tmp[2 * i] + tmp[2 * i + 1] * tmp[2 * i + 1];
            mean += x2;
            mem0 = x2 + (1.0 - forward_decay) * mem0;
            tmp[i] = forward_decay * mem0;
        }
        mem0 = 0;
        var max_e: f32 = 0;
        var i = len2;
        while (i > 0) {
            i -= 1;
            mem0 = tmp[i] + 0.875 * mem0;
            tmp[i] = 0.125 * mem0;
            max_e = @max(max_e, 0.125 * mem0);
        }
        mean = @sqrt(mean * max_e * 0.5 * @as(f32, @floatFromInt(len2)));
        const norm: f32 = @as(f32, @floatFromInt(len2)) / (1e-15 + mean);
        var unmask: i32 = 0;
        var k: usize = 12;
        while (k + 5 < len2) : (k += 4) {
            const id = std.math.clamp(vq.floorInt(64.0 * norm * (tmp[k] + 1e-15)), 0, 127);
            unmask += tables.inv_table[@intCast(id)];
        }
        unmask = @divTrunc(64 * unmask * 4, 6 * (@as(i32, @intCast(len2)) - 17));
        if (unmask > mask_metric) {
            tf_chan = @intCast(c);
            mask_metric = unmask;
        }
    }
    var is_transient = mask_metric > 200;
    // A partial cycle of a very low tone is not an attack.
    if (tone.toneishness > 0.98 and tone.freq < 0.026) {
        is_transient = false;
        mask_metric = 0;
    }
    var weak = false;
    if (allow_weak and is_transient and mask_metric < 600) {
        is_transient = false;
        weak = true;
    }
    const metric: f32 = @floatFromInt(mask_metric);
    const tf_max = @max(0, @sqrt(27.0 * metric) - 42.0);
    const est = @sqrt(@max(0, 0.0069 * @min(163.0, tf_max) - 0.139));
    return .{ .is_transient = is_transient, .tf_estimate = est, .tf_chan = tf_chan, .weak = weak };
}

fn l1Metric(x: []const f32, lm: i32, bias: f32) f32 {
    var l1: f32 = 0;
    for (x) |v| l1 += @abs(v);
    return l1 + @as(f32, @floatFromInt(lm)) * bias * l1;
}

/// Chooses the time and frequency resolution of each band with a Viterbi search over the L1
/// norm of the Haar transformed bands (tf_analysis). Returns the tf_select flag.
fn tfAnalysis(len: u32, is_transient: bool, tf_res: *[nb]i32, lambda: i32, x: []const f32, n0: usize, lm: u32, tf_estimate: f32, tf_chan: u32, importance: *const [nb]i32) bool {
    var metric: [nb]i32 = undefined;
    var path0: [nb]u8 = undefined;
    var path1: [nb]u8 = undefined;
    var tmp: [vq.max_dim]f32 = undefined;
    var tmp_1: [vq.max_dim]f32 = undefined;
    const lmi: i32 = @intCast(lm);
    const tr: usize = @intFromBool(is_transient);
    const bias: f32 = 0.04 * @max(-0.25, 0.5 - tf_estimate);
    for (0..len) |i| {
        const width: usize = @intCast(eb[i + 1] - eb[i]);
        const n = width << @intCast(lm);
        const narrow = width == 1;
        const src = x[tf_chan * n0 + (@as(usize, @intCast(eb[i])) << @intCast(lm)) ..][0..n];
        @memcpy(tmp[0..n], src);
        var best_l1 = l1Metric(tmp[0..n], if (is_transient) lmi else 0, bias);
        var best_level: i32 = 0;
        if (is_transient and !narrow) {
            @memcpy(tmp_1[0..n], tmp[0..n]);
            bands.haar1(tmp_1[0..n], n >> @intCast(lm), @as(usize, 1) << @intCast(lm));
            const l1 = l1Metric(tmp_1[0..n], lmi + 1, bias);
            if (l1 < best_l1) {
                best_l1 = l1;
                best_level = -1;
            }
        }
        const kmax: i32 = lmi + @intFromBool(!(is_transient or narrow));
        var k: i32 = 0;
        while (k < kmax) : (k += 1) {
            const bb: i32 = if (is_transient) lmi - k - 1 else k + 1;
            bands.haar1(tmp[0..n], n >> @intCast(k), @as(usize, 1) << @intCast(k));
            const l1 = l1Metric(tmp[0..n], bb, bias);
            if (l1 < best_l1) {
                best_l1 = l1;
                best_level = k + 1;
            }
        }
        metric[i] = if (is_transient) 2 * best_level else -2 * best_level;
        if (narrow and (metric[i] == 0 or metric[i] == -2 * lmi)) metric[i] -= 1;
    }
    const row = &tables.tf_select_table[lm];
    var sel_cost: [2]i32 = undefined;
    for (0..2) |sel| {
        const t0: i32 = row[4 * tr + 2 * sel];
        const t1: i32 = row[4 * tr + 2 * sel + 1];
        var cost0 = importance[0] * @as(i32, @intCast(@abs(metric[0] - 2 * t0)));
        var cost1 = importance[0] * @as(i32, @intCast(@abs(metric[0] - 2 * t1))) + (if (is_transient) @as(i32, 0) else lambda);
        for (1..len) |i| {
            const curr0 = @min(cost0, cost1 + lambda);
            const curr1 = @min(cost0 + lambda, cost1);
            cost0 = curr0 + importance[i] * @as(i32, @intCast(@abs(metric[i] - 2 * t0)));
            cost1 = curr1 + importance[i] * @as(i32, @intCast(@abs(metric[i] - 2 * t1)));
        }
        sel_cost[sel] = @min(cost0, cost1);
    }
    const tf_select = sel_cost[1] < sel_cost[0] and is_transient;
    const t0: i32 = row[4 * tr + 2 * @as(usize, @intFromBool(tf_select))];
    const t1: i32 = row[4 * tr + 2 * @as(usize, @intFromBool(tf_select)) + 1];
    var cost0 = importance[0] * @as(i32, @intCast(@abs(metric[0] - 2 * t0)));
    var cost1 = importance[0] * @as(i32, @intCast(@abs(metric[0] - 2 * t1))) + (if (is_transient) @as(i32, 0) else lambda);
    for (1..len) |i| {
        var curr0: i32 = undefined;
        var curr1: i32 = undefined;
        const from0 = cost0;
        const from1 = cost1 + lambda;
        if (from0 < from1) {
            curr0 = from0;
            path0[i] = 0;
        } else {
            curr0 = from1;
            path0[i] = 1;
        }
        const from0b = cost0 + lambda;
        const from1b = cost1;
        if (from0b < from1b) {
            curr1 = from0b;
            path1[i] = 0;
        } else {
            curr1 = from1b;
            path1[i] = 1;
        }
        cost0 = curr0 + importance[i] * @as(i32, @intCast(@abs(metric[i] - 2 * t0)));
        cost1 = curr1 + importance[i] * @as(i32, @intCast(@abs(metric[i] - 2 * t1)));
    }
    tf_res[len - 1] = if (cost0 < cost1) 0 else 1;
    var i: usize = len - 1;
    while (i > 0) {
        i -= 1;
        tf_res[i] = if (tf_res[i + 1] == 1) path1[i + 1] else path0[i + 1];
    }
    return tf_select;
}

/// Writes the tf_res flags and the tf_select flag, and turns `tf_res` into the values that the
/// band coder uses (tf_encode).
fn tfEncode(start: u32, end: u32, is_transient: bool, tf_res: *[nb]i32, lm: u32, tf_select_in: bool, enc: *range.Encoder) void {
    var budget: i32 = @intCast(enc.storage * 8);
    var tell = enc.tell();
    var logp: u5 = if (is_transient) 2 else 4;
    const select_rsv = lm > 0 and tell + logp + 1 <= budget;
    budget -= @intFromBool(select_rsv);
    var curr: i32 = 0;
    var tf_changed: usize = 0;
    for (start..end) |i| {
        if (tell + logp <= budget) {
            enc.encodeBitLogp((tf_res[i] ^ curr) != 0, logp);
            tell = enc.tell();
            curr = tf_res[i];
            tf_changed |= @intCast(curr);
        } else {
            tf_res[i] = curr;
        }
        logp = if (is_transient) 4 else 5;
    }
    const row = &tables.tf_select_table[lm];
    const base: usize = if (is_transient) 4 else 0;
    var tf_select = tf_select_in;
    if (select_rsv and row[base + tf_changed] != row[base + 2 + tf_changed]) {
        enc.encodeBitLogp(tf_select, 1);
    } else {
        tf_select = false;
    }
    for (start..end) |i| {
        tf_res[i] = row[base + 2 * @as(usize, @intFromBool(tf_select)) + @as(usize, @intCast(tf_res[i]))];
    }
}

/// Compares the L1 norm of left and right with that of mid and side (stereo_analysis).
/// True means dual stereo.
fn stereoAnalysis(x: []const f32, lm: u32, n0: usize) bool {
    var sum_lr: f32 = 1e-15;
    var sum_ms: f32 = 1e-15;
    for (0..13) |i| {
        const lo = @as(usize, @intCast(eb[i])) << @intCast(lm);
        const hi = @as(usize, @intCast(eb[i + 1])) << @intCast(lm);
        for (lo..hi) |j| {
            const l = x[j];
            const r = x[n0 + j];
            sum_lr += @abs(l) + @abs(r);
            sum_ms += @abs(l + r) + @abs(l - r);
        }
    }
    sum_ms *= 0.707107;
    var thetas: i32 = 13;
    if (lm <= 1) thetas -= 8;
    const base: f32 = @floatFromInt(@as(i32, eb[13]) << @intCast(lm + 1));
    const t: f32 = @floatFromInt(thetas);
    return (base + t) * sum_ms > base * sum_lr;
}

fn log2f(v: f32) f32 {
    return @floatCast(1.442695040888963387 * @log(@as(f64, v)));
}

/// The allocation trim from the stereo correlation and the spectral tilt (alloc_trim_analysis).
fn allocTrimAnalysis(x: []const f32, band_log_e: *const Energies, end: u32, lm: u32, channels: u32, n0: usize, stereo_saving: *f32, tf_estimate: f32, intensity: i32, surround_trim: f32, equiv_rate: i32) i32 {
    var trim: f32 = 5.0;
    if (equiv_rate < 64000) {
        trim = 4.0;
    } else if (equiv_rate < 80000) {
        const frac: f32 = @floatFromInt((equiv_rate - 64000) >> 10);
        trim = 4.0 + 0.0625 * frac;
    }
    if (channels == 2) {
        var sum: f32 = 0;
        for (0..8) |i| {
            const lo = @as(usize, @intCast(eb[i])) << @intCast(lm);
            const hi = @as(usize, @intCast(eb[i + 1])) << @intCast(lm);
            var partial: f32 = 0;
            for (lo..hi) |j| partial += x[j] * x[n0 + j];
            sum += partial;
        }
        sum = 0.125 * sum;
        sum = @min(1.0, @abs(sum));
        var min_xc = sum;
        var i: usize = 8;
        while (i < intensity) : (i += 1) {
            const lo = @as(usize, @intCast(eb[i])) << @intCast(lm);
            const hi = @as(usize, @intCast(eb[i + 1])) << @intCast(lm);
            var partial: f32 = 0;
            for (lo..hi) |j| partial += x[j] * x[n0 + j];
            min_xc = @min(min_xc, @abs(partial));
        }
        min_xc = @min(1.0, @abs(min_xc));
        const log_xc = log2f(1.001 - sum * sum);
        const log_xc2 = @max(0.5 * log_xc, log2f(1.001 - min_xc * min_xc));
        trim += @max(-4.0, 0.75 * log_xc);
        stereo_saving.* = @min(stereo_saving.* + 0.25, -0.5 * log_xc2);
    }
    var diff: f32 = 0;
    for (0..channels) |c| {
        for (0..end - 1) |i| {
            diff += band_log_e[i + c * nb] * @as(f32, @floatFromInt(2 + 2 * @as(i32, @intCast(i)) - @as(i32, @intCast(end))));
        }
    }
    diff /= @floatFromInt(channels * (end - 1));
    trim -= @max(-2.0, @min(2.0, (diff + 1.0) / 6.0));
    trim -= surround_trim;
    trim -= 2.0 * tf_estimate;
    const idx = vq.floorInt(0.5 + trim);
    return std.math.clamp(idx, 0, 10);
}

const SurroundMask = struct { trim: f32, masking: f32 };

/// How much the other channels of a surround stream mask this one. It fills the extra
/// boost of each band and gives the trim and the masking depth for the rate control.
fn surroundMask(energy_mask: *const [2 * nb]f32, channels: u32, last_coded_bands: u32, dynalloc: *[nb]f32) SurroundMask {
    const mask_end: usize = @max(2, last_coded_bands);
    const mask_end_i: i32 = @intCast(mask_end);
    var mask_avg: f32 = 0;
    var diff: f32 = 0;
    var count: i32 = 0;
    for (0..channels) |c| {
        for (0..mask_end) |i| {
            var mask = @max(@min(energy_mask[nb * c + i], 0.25), -2.0);
            if (mask > 0) mask = 0.5 * mask;
            const width: i32 = eb[i + 1] - eb[i];
            mask_avg += mask * @as(f32, @floatFromInt(width));
            count += width;
            diff += mask * @as(f32, @floatFromInt(1 + 2 * @as(i32, @intCast(i)) - mask_end_i));
        }
    }
    mask_avg = mask_avg / @as(f32, @floatFromInt(count));
    mask_avg += 0.2;
    const denom: i32 = @as(i32, @intCast(channels)) * (mask_end_i - 1) * (mask_end_i + 1) * mask_end_i;
    diff = diff * 6 / @as(f32, @floatFromInt(denom));
    diff = 0.5 * diff;
    diff = @max(@min(diff, 0.031), -0.031);
    var midband: usize = 0;
    while (eb[midband + 1] < @divTrunc(eb[mask_end], 2)) midband += 1;
    var count_dynalloc: u32 = 0;
    for (0..mask_end) |i| {
        const lin = mask_avg + diff * @as(f32, @floatFromInt(@as(i32, @intCast(i)) - @as(i32, @intCast(midband))));
        var unmask = if (channels == 2) @max(energy_mask[i], energy_mask[nb + i]) else energy_mask[i];
        unmask = @min(unmask, 0.0);
        unmask -= lin;
        if (unmask > 0.25) {
            dynalloc[i] = unmask - 0.25;
            count_dynalloc += 1;
        }
    }
    if (count_dynalloc >= 3) {
        mask_avg += 0.25;
        if (mask_avg > 0) {
            mask_avg = 0;
            diff = 0;
            @memset(dynalloc[0..mask_end], 0);
        } else {
            for (0..mask_end) |i| dynalloc[i] = @max(0, dynalloc[i] - 0.25);
        }
    }
    mask_avg += 0.2;
    return .{ .trim = 64 * diff, .masking = mask_avg };
}

fn medianOf5(x: []const f32) f32 {
    var t0: f32 = undefined;
    var t1: f32 = undefined;
    const t2 = x[2];
    var t3: f32 = undefined;
    var t4: f32 = undefined;
    if (x[0] > x[1]) {
        t0 = x[1];
        t1 = x[0];
    } else {
        t0 = x[0];
        t1 = x[1];
    }
    if (x[3] > x[4]) {
        t3 = x[4];
        t4 = x[3];
    } else {
        t3 = x[3];
        t4 = x[4];
    }
    if (t0 > t3) {
        std.mem.swap(f32, &t0, &t3);
        std.mem.swap(f32, &t1, &t4);
    }
    if (t2 > t1) {
        return if (t1 < t3) @min(t2, t3) else @min(t4, t1);
    }
    return if (t2 < t3) @min(t1, t3) else @min(t2, t4);
}

fn medianOf3(x: []const f32) f32 {
    var t0: f32 = undefined;
    var t1: f32 = undefined;
    if (x[0] > x[1]) {
        t0 = x[1];
        t1 = x[0];
    } else {
        t0 = x[0];
        t1 = x[1];
    }
    const t2 = x[2];
    if (t1 < t2) return t1;
    if (t0 < t2) return t2;
    return t0;
}

const Dynalloc = struct {
    offsets: [nb]i32,
    importance: [nb]i32,
    spread_weight: [nb]i32,
    tot_boost: i32,
    max_depth: f32,
};

const DynallocInput = struct {
    band_log_e: *const Energies,
    band_log_e2: *const Energies,
    old_band_e: *const Energies,
    start: u32,
    end: u32,
    channels: u32,
    lm: u32,
    is_transient: bool,
    vbr: bool,
    constrained_vbr: bool,
    effective_bytes: i32,
    tone_freq: f32,
    toneishness: f32,
    lsb_depth: u5,
    lfe: bool,
    surround_dynalloc: *const [nb]f32,
};

/// Finds the bands that need more bits than the allocation gives them (dynalloc_analysis). It
/// also gives the weights for the tf and spreading decisions.
fn dynallocAnalysis(in: DynallocInput) Dynalloc {
    const start = in.start;
    const end = in.end;
    const c_n = in.channels;
    const lm: i32 = @intCast(in.lm);
    var out: Dynalloc = .{
        .offsets = @splat(0),
        .importance = @splat(0),
        .spread_weight = @splat(0),
        .tot_boost = 0,
        .max_depth = -31.9,
    };
    var noise_floor: [nb]f32 = undefined;
    for (0..end) |i| {
        const fi: f32 = @floatFromInt(i + 5);
        noise_floor[i] = 0.0625 * @as(f32, @floatFromInt(tables.logN400[i])) + 0.5 + @as(f32, @floatFromInt(9 - @as(i32, in.lsb_depth))) - tables.e_means[i] + 0.0062 * fi * fi;
    }
    for (0..c_n) |c| {
        for (0..end) |i| out.max_depth = @max(out.max_depth, in.band_log_e[c * nb + i] - noise_floor[i]);
    }
    {
        var mask: [nb]f32 = undefined;
        var sig: [nb]f32 = undefined;
        for (0..end) |i| mask[i] = in.band_log_e[i] - noise_floor[i];
        if (c_n == 2) {
            for (0..end) |i| mask[i] = @max(mask[i], in.band_log_e[nb + i] - noise_floor[i]);
        }
        @memcpy(sig[0..end], mask[0..end]);
        for (1..end) |i| mask[i] = @max(mask[i], mask[i - 1] - 2.0);
        var i: usize = end - 1;
        while (i > 0) {
            i -= 1;
            mask[i] = @max(mask[i], mask[i + 1] - 3.0);
        }
        for (0..end) |j| {
            const smr = sig[j] - @max(@max(0, out.max_depth - 12.0), mask[j]);
            const shift = std.math.clamp(-vq.floorInt(0.5 + smr), 0, 5);
            out.spread_weight[j] = @as(i32, 32) >> @intCast(shift);
        }
    }
    if (in.effective_bytes >= 30 + 5 * lm and !in.lfe) {
        var follower: [2 * nb]f32 = @splat(0);
        var band3: [nb]f32 = undefined;
        var last: usize = 0;
        for (0..c_n) |c| {
            @memcpy(band3[0..end], in.band_log_e2[c * nb ..][0..end]);
            if (lm == 0) {
                for (0..@min(8, end)) |i| band3[i] = @max(in.band_log_e2[c * nb + i], in.old_band_e[c * nb + i]);
            }
            const f = follower[c * nb ..][0..nb];
            f[0] = band3[0];
            for (1..end) |i| {
                if (band3[i] > band3[i - 1] + 0.5) last = i;
                f[i] = @min(f[i - 1] + 1.5, band3[i]);
            }
            var i: usize = last;
            while (i > 0) {
                i -= 1;
                f[i] = @min(f[i], @min(f[i + 1] + 2.0, band3[i]));
            }
            const offset: f32 = 1.0;
            for (2..end - 2) |j| f[j] = @max(f[j], medianOf5(band3[j - 2 ..]) - offset);
            var tmp = medianOf3(band3[0..]) - offset;
            f[0] = @max(f[0], tmp);
            f[1] = @max(f[1], tmp);
            tmp = medianOf3(band3[end - 3 ..]) - offset;
            f[end - 2] = @max(f[end - 2], tmp);
            f[end - 1] = @max(f[end - 1], tmp);
            for (0..end) |j| f[j] = @max(f[j], noise_floor[j]);
        }
        if (c_n == 2) {
            for (start..end) |i| {
                follower[nb + i] = @max(follower[nb + i], follower[i] - 4.0);
                follower[i] = @max(follower[i], follower[nb + i] - 4.0);
                follower[i] = 0.5 * (@max(0, in.band_log_e[i] - follower[i]) + @max(0, in.band_log_e[nb + i] - follower[nb + i]));
            }
        } else {
            for (start..end) |i| follower[i] = @max(0, in.band_log_e[i] - follower[i]);
        }
        for (start..end) |i| follower[i] = @max(follower[i], in.surround_dynalloc[i]);
        for (start..end) |i| {
            out.importance[i] = vq.floorInt(0.5 + 13.0 * bands.exp2f(@min(follower[i], 4.0)));
        }
        if ((!in.vbr or in.constrained_vbr) and !in.is_transient) {
            for (start..end) |i| follower[i] = 0.5 * follower[i];
        }
        for (start..end) |i| {
            if (i < 8) follower[i] *= 2;
            if (i >= 12) follower[i] = 0.5 * follower[i];
        }
        if (in.toneishness > 0.98) {
            // Opus under-allocates on tones, so the bands around the tone get more.
            const freq_bin = vq.floorInt(0.5 + @as(f64, in.tone_freq * 120.0) / std.math.pi);
            for (start..end) |i| {
                const lo: i32 = eb[i];
                const hi: i32 = eb[i + 1];
                if (freq_bin >= lo and freq_bin <= hi) follower[i] += 2.0;
                if (freq_bin >= lo - 1 and freq_bin <= hi + 1) follower[i] += 1.0;
                if (freq_bin >= lo - 2 and freq_bin <= hi + 2) follower[i] += 1.0;
                if (freq_bin >= lo - 3 and freq_bin <= hi + 3) follower[i] += 0.5;
            }
            if (freq_bin >= eb[end]) {
                follower[end - 1] += 2.0;
                follower[end - 2] += 1.0;
            }
        }
        for (start..end) |i| {
            follower[i] = @min(follower[i], 4.0);
            const width: i32 = @as(i32, @intCast(c_n)) * (eb[i + 1] - eb[i]) << @intCast(lm);
            var boost: i32 = undefined;
            var boost_bits: i32 = undefined;
            if (width < 6) {
                boost = truncInt(follower[i]);
                boost_bits = (boost * width) << bitres;
            } else if (width > 48) {
                boost = truncInt(follower[i] * 8);
                boost_bits = @divTrunc((boost * width) << bitres, 8);
            } else {
                boost = truncInt(follower[i] * @as(f32, @floatFromInt(width)) / 6.0);
                boost_bits = (boost * 6) << bitres;
            }
            if ((!in.vbr or (in.constrained_vbr and !in.is_transient)) and (out.tot_boost + boost_bits) >> bitres >> 3 > @divTrunc(2 * in.effective_bytes, 3)) {
                const cap = (@divTrunc(2 * in.effective_bytes, 3) << bitres) << 3;
                out.offsets[i] = cap - out.tot_boost;
                out.tot_boost = cap;
                break;
            } else {
                out.offsets[i] = boost;
                out.tot_boost += boost_bits;
            }
        }
    } else {
        for (start..end) |i| out.importance[i] = 13;
    }
    return out;
}

const intensity_thresholds = [21]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 16, 24, 36, 44, 50, 56, 62, 67, 72, 79, 88, 106, 134 };
const intensity_hysteresis = [21]f32{ 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 3, 3, 4, 5, 6, 8, 8 };

/// Settings of one frame that the caller may change.
pub const Settings = struct {
    /// Bits per second, or null for no limit (CBR with the size of the buffer).
    bitrate: ?u32 = null,
    vbr: bool = false,
    /// Constrained VBR keeps the average near the bitrate with a bit reservoir.
    constrained_vbr: bool = true,
    force_intra: bool = false,
    disable_pf: bool = false,
    disable_inv: bool = false,
    /// The effort from 0 to 10, as in libopus. The encoder is bit equal to libopus at complexity 0
    /// to 6 (all tools except the tonality analysis of src/analysis.c, which runs from 7 up).
    /// Complexity 7 and up lacks that analysis and the stereo search by resynthesis of 8 and up, so
    /// its packets differ from libopus.
    complexity: u8 = 9,
    /// The packet loss in percent that the encoder expects.
    loss_rate: u8 = 0,
    /// The bits of the input samples. Bands below the noise of that depth get fewer bits.
    lsb_depth: u5 = 24,
    /// The signal type of the SILK layer (0 to 2) and its quantizer offset. A hybrid frame uses
    /// them to place its bits.
    silk_signal_type: u8 = 0,
    silk_offset: i32 = 0,
    /// A low frequency effects stream: only the first bands carry bits and the analysis is off.
    lfe: bool = false,
    /// The masking of each band by the other channels of a surround stream, 21 values per
    /// channel, in log2 units. Null for a stream without surround masking.
    energy_mask: ?[2 * nb]f32 = null,
};

/// The buffers of one frame. They live in the encoder so that a call needs little stack.
const Scratch = struct {
    in_buf: [2][max_frame_samples + overlap]f32,
    flat: [2 * (max_frame_samples + overlap)]f32,
    tone_x: [max_frame_samples + overlap]f32,
    freq: [2 * max_frame_samples]f32,
    x: [2 * max_frame_samples]f32,
    pre: [2][max_period + max_frame_samples]f32,
};

/// The CELT encoder state for 48 kHz. It keeps the history that the next frame needs.
pub const Encoder = struct {
    /// The input channels.
    channels: u32,
    /// The channels of the coded stream, which is 1 for a mono stream made from stereo input.
    stream_channels: u32,
    /// The factor from the sampling rate of the input to 48 kHz: 1, 2, 3, 4 or 6.
    upsample: u32,

    end: u32 = nb,
    settings: Settings = .{},

    rng: u32,
    spread: bands.SpreadState,
    delayed_intra: f32,
    last_coded_bands: u32,
    prefilter_period: i32,
    prefilter_gain: f32,
    prefilter_tapset: u32,
    consec_transient: u32,
    preemph_mem: [2]f32,
    vbr_reservoir: i32,
    vbr_drift: i32,
    vbr_offset: i32,
    vbr_count: i32,
    overlap_max: f32,
    stereo_saving: f32,
    intensity: i32,
    spec_avg: f32,
    in_mem: [2][overlap]f32,
    prefilter_mem: [2][max_period]f32,
    old_band_e: Energies,
    old_log_e: Energies,
    old_log_e2: Energies,
    energy_error: Energies,
    scratch: Scratch,

    pub fn init(channels: u32) Encoder {
        return initUpsampled(channels, 1);
    }

    /// An encoder for input at 48 kHz divided by `upsample`, which is 1, 2, 3, 4 or 6. The frames
    /// that it takes have `120 << lm` samples divided by `upsample`.
    pub fn initUpsampled(channels: u32, upsample: u32) Encoder {
        std.debug.assert(channels == 1 or channels == 2);
        std.debug.assert(upsample == 1 or upsample == 2 or upsample == 3 or upsample == 4 or upsample == 6);
        var self: Encoder = undefined;
        self.upsample = upsample;
        self.channels = channels;
        self.stream_channels = channels;
        self.end = nb;
        self.settings = .{};
        self.reset();
        return self;
    }

    /// Clears the history, as for a new stream. The settings stay.
    pub fn reset(self: *Encoder) void {
        self.settings.silk_signal_type = 0;
        self.settings.silk_offset = 0;
        self.rng = 0;
        self.spread = .{};
        self.delayed_intra = 1;
        self.last_coded_bands = 0;
        self.prefilter_period = 0;
        self.prefilter_gain = 0;
        self.prefilter_tapset = 0;
        self.consec_transient = 0;
        self.preemph_mem = .{ 0, 0 };
        self.vbr_reservoir = 0;
        self.vbr_drift = 0;
        self.vbr_offset = 0;
        self.vbr_count = 0;
        self.overlap_max = 0;
        self.stereo_saving = 0;
        self.intensity = 0;
        self.spec_avg = 0;
        self.in_mem = @splat(@splat(0));
        self.prefilter_mem = @splat(@splat(0));
        self.old_band_e = @splat(0);
        self.old_log_e = @splat(-28);
        self.old_log_e2 = @splat(-28);
        self.energy_error = @splat(0);
    }

    /// The range of the last frame.
    pub fn finalRange(self: *const Encoder) u32 {
        return self.rng;
    }

    /// Encodes one frame of `120 << lm` samples per channel from the interleaved samples `pcm`
    /// into `out`, and returns its length. Without a bitrate and without VBR the frame fills
    /// `out` (from 2 to 1275 bytes). With VBR the frame is as long as the rate control wants,
    /// up to `out.len` and 1275.
    pub fn encode(self: *Encoder, pcm: []const f32, lm: u32, out: []u8) Error!u32 {
        return self.encodeFrom(pcm, lm, out, 0);
    }

    /// Like `encode`, with the first coded band `start`, which is 17 for the CELT layer of a hybrid
    /// frame.
    pub fn encodeFrom(self: *Encoder, pcm: []const f32, lm: u32, out: []u8, start: u32) Error!u32 {
        if (out.len < 2) return error.BufferTooSmall;
        const size: u32 = @intCast(@min(out.len, max_frame_bytes));
        var enc = range.Encoder.init(out[0..size]);
        return self.encodeWithEc(pcm, lm, &enc, size, start);
    }

    /// Encodes a frame into the range encoder `enc`, which may hold symbols already.
    /// `nb_compressed_bytes` is the size of the whole range coder buffer. `start` is the first
    /// coded band, 17 for the CELT layer of a hybrid frame. Returns the bytes that the frame uses.
    /// After `error.EncoderFailed` the prediction state is not valid, so call `reset`.
    pub fn encodeWithEc(self: *Encoder, pcm: []const f32, lm_in: u32, enc: *range.Encoder, nb_compressed_bytes_in: u32, start: u32) Error!u32 {
        if (nb_compressed_bytes_in < 2) return error.BufferTooSmall;
        if (lm_in > tables.max_lm) return error.InvalidFrameSize;
        const lm = lm_in;
        const lm_i: i32 = @intCast(lm);
        const m: usize = @as(usize, 1) << @intCast(lm);
        const n: usize = 120 * m;
        const cc: usize = self.channels;
        const channels: u32 = self.stream_channels;
        const ch_i: i32 = @intCast(channels);
        const up: usize = self.upsample;
        if (pcm.len < n / up * cc) return error.InvalidFrameSize;
        std.debug.assert(self.end <= nb and self.end > 1);
        const hybrid = start != 0;
        const end = self.end;
        const eff_end = end;
        const frame_size: u32 = @intCast(n);
        const set = self.settings;
        const complexity = set.complexity;

        const tell0 = enc.tell();
        const tell0_frac: i32 = @intCast(enc.tellFrac());
        var tell: i32 = tell0;
        const nb_filled_bytes: i32 = (tell + 4) >> 3;
        var nb_compressed_bytes: i32 = @intCast(@min(nb_compressed_bytes_in, max_frame_bytes));

        var vbr_rate: i32 = 0;
        var effective_bytes: i32 = undefined;
        const bitrate_limited = set.bitrate != null;
        if (set.vbr and bitrate_limited) {
            vbr_rate = rate.bitrateToBits(48000, set.bitrate.?, frame_size) << bitres;
            effective_bytes = vbr_rate >> (3 + bitres);
        } else {
            if (bitrate_limited) {
                var tmp: i64 = @as(i64, set.bitrate.?) * frame_size;
                if (tell > 1) tmp += @as(i64, tell) * 48000;
                const bytes: i64 = @divTrunc(tmp + 4 * 48000, 8 * 48000);
                nb_compressed_bytes = @intCast(@max(2, @min(nb_compressed_bytes, bytes)));
                enc.shrink(@intCast(nb_compressed_bytes));
            }
            effective_bytes = nb_compressed_bytes - nb_filled_bytes;
        }
        var nb_available_bytes = nb_compressed_bytes - nb_filled_bytes;
        const equiv_overhead = (40 * ch_i + 20) * ((@as(i32, 400) >> @intCast(lm)) - 50);
        var equiv_rate: i32 = ((nb_compressed_bytes * 8 * 50) << @intCast(3 - lm_i)) - equiv_overhead;
        if (set.bitrate) |br| equiv_rate = @min(equiv_rate, @as(i32, @intCast(@min(br, 1 << 30))) - equiv_overhead);

        if (vbr_rate > 0 and set.constrained_vbr) {
            const vbr_bound = vbr_rate;
            const max_allowed = @min(@max(if (tell == 1) @as(i32, 2) else 0, (vbr_rate + vbr_bound - self.vbr_reservoir) >> (bitres + 3)), nb_available_bytes);
            if (max_allowed < nb_available_bytes) {
                nb_compressed_bytes = nb_filled_bytes + max_allowed;
                nb_available_bytes = max_allowed;
                enc.shrink(@intCast(nb_compressed_bytes));
            }
        }
        var total_bits: i32 = nb_compressed_bytes * 8;

        const sc = &self.scratch;
        const in_buf = &sc.in_buf;
        var sample_max = self.overlap_max;
        // libopus counts the samples with the channels of the stream, so a mono stream from a stereo
        // input looks at the first part of the buffer only.
        const split = channels * (n - overlap) / up;
        for (pcm[0..split]) |v| sample_max = @max(sample_max, @abs(sane(v)));
        var new_overlap_max: f32 = 0;
        for (pcm[split..][0 .. channels * overlap / up]) |v| new_overlap_max = @max(new_overlap_max, @abs(sane(v)));
        self.overlap_max = new_overlap_max;
        sample_max = @max(sample_max, new_overlap_max);
        var silence = sample_max <= 1.0 / @as(f32, @floatFromInt(@as(u32, 1) << set.lsb_depth));
        if (tell == 1) {
            enc.encodeBitLogp(silence, 15);
        } else {
            silence = false;
        }
        if (silence) {
            if (vbr_rate > 0) {
                nb_compressed_bytes = @min(nb_compressed_bytes, nb_filled_bytes + 2);
                effective_bytes = nb_compressed_bytes;
                total_bits = nb_compressed_bytes * 8;
                nb_available_bytes = 2;
                enc.shrink(@intCast(nb_compressed_bytes));
            }
            tell = nb_compressed_bytes * 8;
            enc.nbits_total += tell - enc.tell();
        }

        const need_clip = sample_max > 65536.0;
        for (0..cc) |c| {
            const input = &in_buf[c];
            var mem = self.preemph_mem[c];
            for (0..n) |i| {
                var x: f32 = 0;
                if (i % up == 0) x = 32768.0 * sane(pcm[cc * (i / up) + c]);
                if (need_clip) x = std.math.clamp(x, -65536.0, 65536.0);
                input[overlap + i] = x - mem;
                mem = preemph * x;
            }
            self.preemph_mem[c] = mem;
            @memcpy(input[0..overlap], self.prefilter_mem[c][max_period - overlap ..]);
        }

        const len = n + overlap;
        for (0..cc) |c| @memcpy(sc.flat[c * len ..][0..len], in_buf[c][0..len]);
        const tone = toneDetect(&sc.flat, len, self.channels, &sc.tone_x);
        var transient: Transient = .{ .is_transient = false, .tf_estimate = 0, .tf_chan = 0 };
        if (complexity >= 1 and !set.lfe) transient = transientAnalysis(&sc.flat, len, self.channels, tone, hybrid and effective_bytes < 15 and set.silk_signal_type != 2);
        const toneishness = @min(tone.toneishness, 1.0 - transient.tf_estimate);
        var is_transient = transient.is_transient;
        const weak_transient = transient.weak;
        var tf_estimate = transient.tf_estimate;
        const tf_chan: u32 = if (cc == 2 and channels == 1) 0 else transient.tf_chan;

        // The pitch pre-filter.
        var pitch_index: i32 = min_period;
        var gain1: f32 = 0;
        var qg: i32 = 0;
        var pf_on = false;
        var pitch_change = false;
        const prefilter_tapset: u32 = self.spread.tapset;
        {
            const enabled = ((set.lfe and nb_available_bytes > 3) or nb_available_bytes > 12 * ch_i) and !hybrid and !silence and tell + 16 <= total_bits and !set.disable_pf;
            const pf = self.runPrefilter(in_buf, n, prefilter_tapset, enabled, tf_estimate, nb_available_bytes, tone.freq, toneishness);
            pitch_index = pf.pitch;
            gain1 = pf.gain;
            qg = pf.qg;
            pf_on = pf.on;
            const pi: f32 = @floatFromInt(pitch_index);
            const pp: f32 = @floatFromInt(self.prefilter_period);
            if ((gain1 > 0.4 or self.prefilter_gain > 0.4) and (pi > 1.26 * pp or pi < 0.79 * pp)) pitch_change = true;
            if (!pf_on) {
                if (!hybrid and tell + 16 <= total_bits) enc.encodeBitLogp(false, 1);
            } else {
                enc.encodeBitLogp(true, 1);
                const pitch_plus = pitch_index + 1;
                const octave: u32 = @intCast(32 - @clz(@as(u32, @intCast(pitch_plus))) - 5);
                enc.encodeUint(octave, 6);
                enc.encodeBits(@intCast(pitch_plus - (@as(i32, 16) << @intCast(octave))), @intCast(4 + octave));
                enc.encodeBits(@intCast(qg), 3);
                enc.encodeIcdf(prefilter_tapset, &tables.tapset_icdf, 2);
            }
        }
        var transient_got_disabled = false;
        var short_blocks = false;
        if (lm > 0 and enc.tell() + 3 <= total_bits) {
            if (is_transient) short_blocks = true;
        } else {
            is_transient = false;
            transient_got_disabled = true;
        }

        const freq = &sc.freq;
        var band_e: [2 * nb]f32 = @splat(0);
        var band_log_e: Energies = @splat(0);
        var band_log_e2: Energies = @splat(0);
        const second_mdct = short_blocks and complexity >= 8;
        if (second_mdct) {
            computeMdcts(in_buf, freq, self.channels, channels, lm, false, up);
            bands.bandEnergies(freq, &band_e, eff_end, channels, lm);
            energy.amplitudeToLog(&band_e, &band_log_e2, eff_end, end, channels);
            for (0..channels) |c| {
                for (0..end) |i| band_log_e2[nb * c + i] += 0.5 * @as(f32, @floatFromInt(lm));
            }
        }
        computeMdcts(in_buf, freq, self.channels, channels, lm, short_blocks, up);
        bands.bandEnergies(freq, &band_e, eff_end, channels, lm);
        if (set.lfe) {
            for (2..end) |i| {
                band_e[i] = @min(band_e[i], 1e-4 * band_e[0]);
                band_e[i] = @max(band_e[i], 1e-15);
            }
        }
        energy.amplitudeToLog(&band_e, &band_log_e, eff_end, end, channels);

        var surround_dynalloc: [nb]f32 = @splat(0);
        var surround_trim: f32 = 0;
        var surround_masking: f32 = 0;
        if (!hybrid and !set.lfe) {
            if (set.energy_mask) |mask_in| {
                const sm = surroundMask(&mask_in, channels, self.last_coded_bands, &surround_dynalloc);
                surround_trim = sm.trim;
                surround_masking = sm.masking;
            }
        }

        var temporal_vbr: f32 = 0;
        if (!set.lfe) {
            var follow: f32 = -10.0;
            var frame_avg: f32 = 0;
            const offset: f32 = if (short_blocks) 0.5 * @as(f32, @floatFromInt(lm)) else 0;
            for (start..end) |i| {
                follow = @max(follow - 1.0, band_log_e[i] - offset);
                if (channels == 2) follow = @max(follow, band_log_e[i + nb] - offset);
                frame_avg += follow;
            }
            frame_avg /= @floatFromInt(end - start);
            temporal_vbr = frame_avg - self.spec_avg;
            temporal_vbr = @min(3.0, @max(-1.5, temporal_vbr));
            self.spec_avg += 0.02 * temporal_vbr;
        }
        if (!second_mdct) band_log_e2 = band_log_e;

        if (lm > 0 and enc.tell() + 3 <= total_bits and !is_transient and complexity >= 5 and !set.lfe and !hybrid) {
            if (patchTransientDecision(&band_log_e, &self.old_band_e, start, end, channels)) {
                is_transient = true;
                short_blocks = true;
                computeMdcts(in_buf, freq, self.channels, channels, lm, true, up);
                bands.bandEnergies(freq, &band_e, eff_end, channels, lm);
                energy.amplitudeToLog(&band_e, &band_log_e, eff_end, end, channels);
                for (0..channels) |c| {
                    for (0..end) |i| band_log_e2[nb * c + i] += 0.5 * @as(f32, @floatFromInt(lm));
                }
                tf_estimate = 0.2;
            }
        }
        if (lm > 0 and enc.tell() + 3 <= total_bits) enc.encodeBitLogp(is_transient, 3);

        const x = &sc.x;
        bands.normaliseBands(freq, x, &band_e, eff_end, channels, lm);

        const enable_tf_analysis = effective_bytes >= 15 * ch_i and !hybrid and complexity >= 2 and !set.lfe and toneishness < 0.98;
        const dyn = dynallocAnalysis(.{
            .band_log_e = &band_log_e,
            .band_log_e2 = &band_log_e2,
            .old_band_e = &self.old_band_e,
            .start = start,
            .end = end,
            .channels = channels,
            .lm = lm,
            .is_transient = is_transient,
            .vbr = set.vbr,
            .constrained_vbr = set.constrained_vbr,
            .effective_bytes = effective_bytes,
            .tone_freq = tone.freq,
            .toneishness = toneishness,
            .lsb_depth = set.lsb_depth,
            .lfe = set.lfe,
            .surround_dynalloc = &surround_dynalloc,
        });
        var offsets = dyn.offsets;
        const tot_boost0 = dyn.tot_boost;
        const max_depth = dyn.max_depth;

        var tf_res: [nb]i32 = @splat(0);
        var tf_select = false;
        if (enable_tf_analysis) {
            const lambda = @max(80, @divTrunc(20480, effective_bytes) + 2);
            tf_select = tfAnalysis(eff_end, is_transient, &tf_res, lambda, x, n, lm, tf_estimate, tf_chan, &dyn.importance);
            for (eff_end..end) |i| tf_res[i] = tf_res[eff_end - 1];
        } else if (hybrid and weak_transient) {
            @memset(tf_res[0..end], 1);
        } else if (hybrid and effective_bytes < 15 and set.silk_signal_type != 2) {
            @memset(tf_res[0..end], 0);
            tf_select = is_transient;
        } else {
            @memset(tf_res[0..end], @intFromBool(is_transient));
        }

        var err: Energies = @splat(0);
        for (0..channels) |c| {
            for (start..end) |i| {
                if (@abs(band_log_e[i + c * nb] - self.old_band_e[i + c * nb]) < 2.0) {
                    band_log_e[i + c * nb] -= 0.25 * self.energy_error[i + c * nb];
                }
            }
        }
        energy.quantCoarse(start, end, eff_end, &band_log_e, &self.old_band_e, @intCast(total_bits), &err, enc, channels, lm, @intCast(@max(nb_available_bytes, 0)), set.force_intra, &self.delayed_intra, complexity >= 4, set.loss_rate, set.lfe);

        tfEncode(start, end, is_transient, &tf_res, lm, tf_select, enc);

        if (enc.tell() + 4 <= total_bits) {
            if (set.lfe) {
                self.spread.tapset = 0;
                self.spread.decision = .normal;
            } else if (hybrid) {
                self.spread.decision = if (complexity == 0) .none else if (is_transient) .normal else .aggressive;
            } else if (short_blocks or complexity < 3 or nb_available_bytes < 10 * ch_i) {
                self.spread.decision = if (complexity == 0) .none else .normal;
            } else {
                self.spread.decision = bands.spreadingDecision(x, &self.spread, pf_on and !short_blocks, eff_end, channels, lm, &dyn.spread_weight);
            }
            enc.encodeIcdf(@backingInt(self.spread.decision), &tables.spread_icdf, 5);
        } else {
            self.spread.decision = .normal;
        }

        if (set.lfe) offsets[0] = @min(8, @divTrunc(effective_bytes, 3));
        var cap: [nb]i32 = undefined;
        rate.initCaps(&cap, lm, channels);

        var dynalloc_logp: u5 = 6;
        total_bits <<= bitres;
        var total_boost: i32 = 0;
        tell = @intCast(enc.tellFrac());
        for (start..end) |i| {
            const width: i32 = ch_i * (eb[i + 1] - eb[i]) << @intCast(lm);
            const quanta = @min(width << bitres, @max(6 << bitres, width));
            var loop_logp = dynalloc_logp;
            var boost: i32 = 0;
            var j: i32 = 0;
            while (tell + (@as(i32, loop_logp) << bitres) < total_bits - total_boost and boost < cap[i]) : (j += 1) {
                const flag = j < offsets[i];
                enc.encodeBitLogp(flag, loop_logp);
                tell = @intCast(enc.tellFrac());
                if (!flag) break;
                boost += quanta;
                total_boost += quanta;
                loop_logp = 1;
            }
            if (j != 0) dynalloc_logp = @max(2, dynalloc_logp - 1);
            offsets[i] = boost;
        }

        var dual_stereo = false;
        if (channels == 2) {
            if (lm != 0) dual_stereo = stereoAnalysis(x, lm, n);
            const val: f32 = @floatFromInt(@divTrunc(equiv_rate, 1000));
            const sel = bands.hysteresisDecision(val, &intensity_thresholds, &intensity_hysteresis, @intCast(std.math.clamp(self.intensity, 0, 21)));
            self.intensity = @min(@as(i32, @intCast(end)), @max(@as(i32, @intCast(start)), @as(i32, @intCast(sel))));
        }

        var alloc_trim: i32 = 5;
        if (tell + (6 << bitres) <= total_bits - total_boost) {
            if (start > 0 or set.lfe) {
                self.stereo_saving = 0;
                alloc_trim = 5;
            } else {
                alloc_trim = allocTrimAnalysis(x, &band_log_e, end, lm, channels, n, &self.stereo_saving, tf_estimate, self.intensity, surround_trim, equiv_rate);
            }
            enc.encodeIcdf(@intCast(alloc_trim), &tables.trim_icdf, 7);
            tell = @intCast(enc.tellFrac());
        }

        var min_allowed: i32 = ((tell + total_boost + (1 << (bitres + 3)) - 1) >> (bitres + 3)) + 2;
        // A hybrid frame keeps 37 bits for the flag of a redundant frame.
        if (hybrid) min_allowed = @max(min_allowed, (tell0_frac + (37 << bitres) + total_boost + (1 << (bitres + 3)) - 1) >> (bitres + 3));
        if (vbr_rate > 0) {
            const lm_diff: u5 = @intCast(3 - lm_i);
            nb_compressed_bytes = @min(nb_compressed_bytes, @as(i32, max_frame_bytes) >> @intCast(3 - lm_i));
            var base_target = if (!hybrid) vbr_rate - ((40 * ch_i + 20) << bitres) else @max(0, vbr_rate - ((9 * ch_i + 4) << bitres));
            if (set.constrained_vbr) base_target += self.vbr_offset >> lm_diff;
            var target: i32 = undefined;
            if (!hybrid) {
                target = self.computeVbr(base_target, lm, equiv_rate, tot_boost0, tf_estimate, max_depth, temporal_vbr, surround_masking);
            } else {
                target = base_target;
                if (set.silk_offset < 100) target += @as(i32, 12 << bitres) >> @intCast(3 - lm_i);
                if (set.silk_offset > 100) target -= @as(i32, 18 << bitres) >> @intCast(3 - lm_i);
                target += truncInt((tf_estimate - 0.25) * (50 << bitres));
                if (tf_estimate > 0.7) target = @max(target, 50 << bitres);
            }
            target += tell;
            nb_available_bytes = (target + (1 << (bitres + 2))) >> (bitres + 3);
            nb_available_bytes = @max(min_allowed, nb_available_bytes);
            nb_available_bytes = @min(nb_compressed_bytes, nb_available_bytes);
            var delta = target - vbr_rate;
            target = nb_available_bytes << (bitres + 3);
            if (silence) {
                nb_available_bytes = 2;
                target = (2 * 8) << bitres;
                delta = 0;
            }
            var alpha: f32 = 0.001;
            if (self.vbr_count < 970) {
                self.vbr_count += 1;
                alpha = 1.0 / @as(f32, @floatFromInt(self.vbr_count + 20));
            }
            if (set.constrained_vbr) self.vbr_reservoir += target - vbr_rate;
            if (set.constrained_vbr) {
                const dd: f32 = @floatFromInt((@as(i64, delta) << lm_diff) - self.vbr_offset - self.vbr_drift);
                self.vbr_drift += truncInt(alpha * dd);
                self.vbr_offset = -self.vbr_drift;
            }
            if (set.constrained_vbr and self.vbr_reservoir < 0) {
                const adjust = @divTrunc(-self.vbr_reservoir, 8 << bitres);
                nb_available_bytes += if (silence) 0 else adjust;
                self.vbr_reservoir = 0;
            }
            nb_compressed_bytes = @min(nb_compressed_bytes, nb_available_bytes);
            enc.shrink(@intCast(nb_compressed_bytes));
        }

        var alloc: rate.Allocation = .{};
        var bits: i32 = (nb_compressed_bytes * 8 << bitres) - @as(i32, @intCast(enc.tellFrac())) - 1;
        const anti_collapse_rsv: i32 = if (is_transient and lm >= 2 and bits >= (lm_i + 2) << bitres) 1 << bitres else 0;
        bits -= anti_collapse_rsv;
        const signal_bandwidth: i32 = if (set.lfe) 1 else @as(i32, @intCast(end)) - 1;
        alloc.intensity = self.intensity;
        alloc.dual_stereo = dual_stereo;
        const coded_bands = rate.computeAllocation(.{
            .start = start,
            .end = end,
            .offsets = &offsets,
            .caps = &cap,
            .alloc_trim = alloc_trim,
            .total = std.math.clamp(bits, -100_000, 100_000),
            .channels = channels,
            .lm = lm,
        }, .{ .encoder = .{ .enc = enc, .prev = @intCast(self.last_coded_bands), .signal_bandwidth = signal_bandwidth } }, &alloc);
        self.intensity = alloc.intensity;
        dual_stereo = alloc.dual_stereo;
        if (self.last_coded_bands != 0) {
            self.last_coded_bands = @min(self.last_coded_bands + 1, @max(self.last_coded_bands -| 1, coded_bands));
        } else {
            self.last_coded_bands = coded_bands;
        }

        energy.quantFine(start, end, &self.old_band_e, &err, &alloc.fine_quant, enc, channels);
        self.energy_error = @splat(0);

        bands.quantAllBandsEncode(.{
            .start = start,
            .end = end,
            .lm = lm,
            .channels = channels,
            .short_blocks = short_blocks,
            .spread = self.spread.decision,
            .dual_stereo = dual_stereo,
            .intensity = self.intensity,
            .tf_res = &tf_res,
            .pulses = &alloc.pulses,
            .total_bits = nb_compressed_bytes * (8 << bitres) - anti_collapse_rsv,
            .balance = alloc.balance,
            .coded_bands = coded_bands,
            .disable_inv = set.disable_inv,
            .band_e = &band_e,
        }, x[0 .. channels * n], enc) catch return error.EncoderFailed;

        if (anti_collapse_rsv > 0) {
            enc.encodeBits(@intFromBool(self.consec_transient < 2), 1);
        }
        energy.quantFinalise(start, end, &self.old_band_e, &err, &alloc.fine_quant, &alloc.fine_priority, nb_compressed_bytes * 8 - enc.tell(), enc, channels);
        for (0..channels) |c| {
            for (start..end) |i| self.energy_error[i + c * nb] = std.math.clamp(err[i + c * nb], -0.5, 0.5);
        }
        if (silence) {
            for (0..channels * nb) |i| self.old_band_e[i] = -28.0;
        }
        if (cc == 2 and channels == 1) @memcpy(self.old_band_e[nb .. 2 * nb], self.old_band_e[0..nb]);

        self.prefilter_period = pitch_index;
        self.prefilter_gain = gain1;
        self.prefilter_tapset = prefilter_tapset;

        if (!is_transient) {
            self.old_log_e2 = self.old_log_e;
            self.old_log_e = self.old_band_e;
        } else {
            for (0..2 * nb) |i| self.old_log_e[i] = @min(self.old_log_e[i], self.old_band_e[i]);
        }
        for (0..2) |c| {
            for (0..nb) |i| {
                if (i < start or i >= end) {
                    self.old_band_e[c * nb + i] = 0;
                    self.old_log_e[c * nb + i] = -28;
                    self.old_log_e2[c * nb + i] = -28;
                }
            }
        }
        if (is_transient or transient_got_disabled) {
            self.consec_transient += 1;
        } else {
            self.consec_transient = 0;
        }
        self.rng = enc.rng;
        enc.done();
        if (enc.err) return error.EncoderFailed;
        return @intCast(nb_compressed_bytes);
    }

    const Prefilter = struct { pitch: i32, gain: f32, qg: i32, on: bool };

    /// Searches the pitch and filters the frame with the comb filter that undoes the post
    /// filter of the decoder (run_prefilter). `in_buf` holds the pre-emphasised samples and is
    /// replaced by the filtered ones.
    fn runPrefilter(self: *Encoder, in_buf: *[2][max_frame_samples + overlap]f32, n: usize, prefilter_tapset: u32, enabled: bool, tf_estimate: f32, nb_available_bytes: i32, tone_freq_in: f32, toneishness: f32) Prefilter {
        const cc: usize = self.channels;
        const complexity = self.settings.complexity;
        const pre = &self.scratch.pre;
        for (0..cc) |c| {
            @memcpy(pre[c][0..max_period], &self.prefilter_mem[c]);
            @memcpy(pre[c][max_period..][0..n], in_buf[c][overlap..][0..n]);
        }
        var pitch_index: i32 = min_period;
        var gain1: f32 = 0;
        if (enabled and toneishness > 0.99) {
            // A single tone fools the pitch search, so the period comes from its frequency.
            var tone_freq = tone_freq_in;
            var multiple: f32 = 1;
            if (tone_freq >= 3.1416) tone_freq = 3.141593 - tone_freq;
            while (tone_freq >= multiple * 0.39) multiple += 1;
            if (tone_freq > 0.006148) {
                const period = vq.floorInt(0.5 + 2.0 * std.math.pi * @as(f64, multiple) / tone_freq);
                pitch_index = @min(period, @as(i32, max_period) - 2);
            } else {
                pitch_index = min_period;
            }
            gain1 = 0.75;
        } else if (enabled and complexity >= 5) {
            var pitch_buf: [(max_period + max_frame_samples) >> 1]f32 = undefined;
            const half = (max_period + n) >> 1;
            const chans: [2][]const f32 = .{ pre[0][0 .. max_period + n], pre[1][0 .. max_period + n] };
            pitch.downsample(chans[0..cc], pitch_buf[0..half]);
            var found: usize = undefined;
            switch (n) {
                120 => found = pitch.search(pitch_buf[max_period >> 1 ..], &pitch_buf, 120, max_period - 3 * min_period),
                240 => found = pitch.search(pitch_buf[max_period >> 1 ..], &pitch_buf, 240, max_period - 3 * min_period),
                480 => found = pitch.search(pitch_buf[max_period >> 1 ..], &pitch_buf, 480, max_period - 3 * min_period),
                else => found = pitch.search(pitch_buf[max_period >> 1 ..], &pitch_buf, 960, max_period - 3 * min_period),
            }
            pitch_index = @as(i32, max_period) - @as(i32, @intCast(found));
            gain1 = pitch.removeDoubling(pitch_buf[0..half], max_period, min_period, n, &pitch_index, self.prefilter_period, self.prefilter_gain);
            if (pitch_index > max_period - 2) pitch_index = max_period - 2;
            gain1 = 0.7 * gain1;
            if (self.settings.loss_rate > 2) gain1 *= 0.5;
            if (self.settings.loss_rate > 4) gain1 *= 0.5;
            if (self.settings.loss_rate > 8) gain1 = 0;
        }
        var pf_threshold: f32 = 0.2;
        if (@abs(pitch_index - self.prefilter_period) * 10 > pitch_index) {
            pf_threshold += 0.2;
            if (tf_estimate > 0.98) gain1 = 0;
        }
        if (nb_available_bytes < 25) pf_threshold += 0.1;
        if (nb_available_bytes < 35) pf_threshold += 0.1;
        if (self.prefilter_gain > 0.4) pf_threshold -= 0.1;
        if (self.prefilter_gain > 0.55) pf_threshold -= 0.1;
        pf_threshold = @max(pf_threshold, 0.2);
        var pf_on = false;
        var qg: i32 = 0;
        if (gain1 < pf_threshold) {
            gain1 = 0;
        } else {
            if (@abs(gain1 - self.prefilter_gain) < 0.1) gain1 = self.prefilter_gain;
            qg = vq.floorInt(0.5 + gain1 * 32.0 / 3.0) - 1;
            qg = std.math.clamp(qg, 0, 7);
            gain1 = 0.09375 * @as(f32, @floatFromInt(qg + 1));
            pf_on = true;
        }

        var before: [2]f32 = .{ 0, 0 };
        var after: [2]f32 = .{ 0, 0 };
        self.prefilter_period = @max(self.prefilter_period, min_period);
        for (0..cc) |c| {
            const frame = &in_buf[c];
            @memcpy(frame[0..overlap], &self.in_mem[c]);
            for (frame[overlap..][0..n]) |v| before[c] += @abs(v);
            pitch.combFilter(frame, overlap, &pre[c], max_period, self.prefilter_period, pitch_index, n, -self.prefilter_gain, -gain1, self.prefilter_tapset, prefilter_tapset, overlap);
            for (frame[overlap..][0..n]) |v| after[c] += @abs(v);
        }
        var cancel = false;
        if (cc == 2) {
            const thresh0 = 0.25 * gain1 * before[0] + 0.01 * before[1];
            const thresh1 = 0.25 * gain1 * before[1] + 0.01 * before[0];
            if (after[0] - before[0] > thresh0 or after[1] - before[1] > thresh1) cancel = true;
            if (before[0] - after[0] < thresh0 and before[1] - after[1] < thresh1) cancel = true;
        } else if (after[0] > before[0]) {
            cancel = true;
        }
        if (cancel) {
            for (0..cc) |c| {
                const frame = &in_buf[c];
                @memcpy(frame[overlap..][0..n], pre[c][max_period..][0..n]);
                pitch.combFilter(frame, overlap, &pre[c], max_period, self.prefilter_period, pitch_index, overlap, -self.prefilter_gain, -0.0, self.prefilter_tapset, prefilter_tapset, overlap);
            }
            gain1 = 0;
            pf_on = false;
            qg = 0;
        }
        for (0..cc) |c| {
            @memcpy(&self.in_mem[c], in_buf[c][n..][0..overlap]);
            if (n > max_period) {
                @memcpy(&self.prefilter_mem[c], pre[c][n..][0..max_period]);
            } else {
                std.mem.copyForwards(f32, self.prefilter_mem[c][0 .. max_period - n], self.prefilter_mem[c][n..max_period]);
                @memcpy(self.prefilter_mem[c][max_period - n ..], pre[c][max_period..][0..n]);
            }
        }
        return .{ .pitch = pitch_index, .gain = gain1, .qg = qg, .on = pf_on };
    }

    /// The bits to aim at for this frame in 8th bits (compute_vbr).
    fn computeVbr(self: *const Encoder, base_target: i32, lm: u32, bitrate: i32, tot_boost: i32, tf_estimate: f32, max_depth: f32, temporal_vbr: f32, surround_masking: f32) i32 {
        const coded_bands: usize = if (self.last_coded_bands != 0) self.last_coded_bands else nb;
        const l: u5 = @intCast(lm);
        var coded_bins: i32 = @as(i32, eb[coded_bands]) << l;
        const channels: i32 = @intCast(self.stream_channels);
        if (self.stream_channels == 2) coded_bins += @as(i32, eb[@min(@as(usize, @intCast(self.intensity)), coded_bands)]) << l;
        var target = base_target;
        if (self.stream_channels == 2) {
            const coded_stereo_bands: i32 = @intCast(@min(@as(usize, @intCast(self.intensity)), coded_bands));
            const coded_stereo_dof = (@as(i32, eb[@intCast(coded_stereo_bands)]) << l) - coded_stereo_bands;
            const max_frac: f32 = 0.8 * @as(f32, @floatFromInt(coded_stereo_dof)) / @as(f32, @floatFromInt(coded_bins));
            const saving = @min(self.stereo_saving, 1.0);
            const tf: f32 = @floatFromInt(target);
            target -= truncInt(@min(max_frac * tf, (saving - 0.1) * @as(f32, @floatFromInt(coded_stereo_dof << bitres))));
        }
        target += tot_boost - (@as(i32, 19) << l);
        target += truncInt((tf_estimate - 0.044) * @as(f32, @floatFromInt(target)));
        const has_mask = self.settings.energy_mask != null;
        if (has_mask and !self.settings.lfe) {
            const surround_target = target + truncInt(surround_masking * @as(f32, @floatFromInt(coded_bins << bitres)));
            target = @max(@divTrunc(target, 4), surround_target);
        }
        {
            const bins: i32 = @as(i32, eb[nb - 2]) << l;
            var floor_depth = truncInt(@as(f32, @floatFromInt((channels * bins) << bitres)) * max_depth);
            floor_depth = @max(floor_depth, target >> 2);
            target = @min(target, floor_depth);
        }
        if ((!has_mask or self.settings.lfe) and self.settings.constrained_vbr) {
            target = base_target + truncInt(0.67 * @as(f32, @floatFromInt(target - base_target)));
        }
        if (!has_mask and tf_estimate < 0.2) {
            const amount: f32 = 0.0000031 * @as(f32, @floatFromInt(@max(0, @min(32000, 96000 - bitrate))));
            const tvbr_factor = temporal_vbr * amount;
            target += truncInt(tvbr_factor * @as(f32, @floatFromInt(target)));
        }
        return @min(2 * base_target, target);
    }
};

/// Windows and transforms the frame (compute_mdcts). `in_buf` holds each of the `cc` input
/// channels as 120 samples of history and the new samples. The coefficients go to `out`, channel
/// after channel, with the short blocks interleaved. A stereo input with a mono stream is mixed
/// down.
fn computeMdcts(in_buf: *const [2][max_frame_samples + overlap]f32, out: []f32, cc: u32, channels: u32, lm: u32, short_blocks: bool, upsample: usize) void {
    const b: usize = if (short_blocks) @as(usize, 1) << @intCast(lm) else 1;
    const n: usize = if (short_blocks) 120 else @as(usize, 120) << @intCast(lm);
    const shift: u2 = @intCast(if (short_blocks) 3 else 3 - lm);
    for (0..cc) |c| {
        for (0..b) |blk| {
            const src = in_buf[c][blk * n ..];
            mdct.forward(src[0 .. n + overlap], out[blk + c * n * b ..], b, shift);
        }
    }
    if (cc == 2 and channels == 1) {
        for (0..b * n) |i| out[i] = 0.5 * out[i] + 0.5 * out[b * n + i];
    }
    if (upsample != 1) {
        const bound = b * n / upsample;
        for (0..channels) |c| {
            for (out[c * b * n ..][0..bound]) |*v| v.* *= @floatFromInt(upsample);
            @memset(out[c * b * n + bound ..][0 .. b * n - bound], 0);
        }
    }
}

const testing = std.testing;

test "a click in a quiet signal is a transient and a steady tone is not" {
    var steady: [960 + overlap]f32 = undefined;
    var click: [960 + overlap]f32 = undefined;
    for (&steady, 0..) |*v, i| v.* = 3000 * @sin(@as(f32, @floatFromInt(i)) * 0.2);
    for (&click, 0..) |*v, i| v.* = if (i >= 600 and i < 640) 30000 * @sin(@as(f32, @floatFromInt(i)) * 1.1) else 20 * @sin(@as(f32, @floatFromInt(i)) * 0.2);
    const a = transientAnalysis(&steady, steady.len, 1, .{}, false);
    const b = transientAnalysis(&click, click.len, 1, .{}, false);
    try testing.expect(!a.is_transient);
    try testing.expect(b.is_transient);
    try testing.expect(b.tf_estimate > a.tf_estimate);
}

test "an energy jump in the bands is a missed transient" {
    var old: Energies = @splat(0);
    var new: Energies = @splat(0);
    try testing.expect(!patchTransientDecision(&new, &old, 0, nb, 1));
    for (3..nb - 1) |i| new[i] = 3;
    try testing.expect(patchTransientDecision(&new, &old, 0, nb, 1));
    // The same energy before is not a jump.
    old = new;
    try testing.expect(!patchTransientDecision(&new, &old, 0, nb, 1));
}

test "dual stereo is chosen when one channel is silent" {
    var x: [2 * 480]f32 = undefined;
    for (x[0..480], 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)));
    @memcpy(x[480..], x[0..480]);
    try testing.expect(!stereoAnalysis(&x, 2, 480));
    @memset(x[480..], 0);
    try testing.expect(stereoAnalysis(&x, 2, 480));
}

test "the bit budget limits the allocation trim to the table" {
    var x: [2 * 120]f32 = undefined;
    for (&x, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.3);
    var logs: Energies = @splat(0);
    var saving: f32 = 0;
    const low = allocTrimAnalysis(&x, &logs, nb, 0, 2, 120, &saving, 0, 10, 0, 20000);
    const high = allocTrimAnalysis(&x, &logs, nb, 0, 2, 120, &saving, 0, 10, 0, 200000);
    // The base trim is 4 below 64 kbit/s and 5 above 80 kbit/s, and the other terms are small here.
    try testing.expectEqual(@as(i32, 4), low);
    try testing.expectEqual(@as(i32, 5), high);
}

test "a frame of silence is two bytes in variable bitrate" {
    var enc = Encoder.init(1);
    enc.settings.vbr = true;
    enc.settings.bitrate = 64000;
    const pcm: [960]f32 = @splat(0);
    var out: [1275]u8 = undefined;
    try testing.expectEqual(@as(u32, 2), try enc.encode(&pcm, 3, &out));
    var dec = @import("decode.zig").Decoder.init(1, false);
    var back: [960]f32 = undefined;
    try dec.decode(out[0..2], null, 1, 3, &back, false);
    try testing.expectEqual(enc.finalRange(), dec.rng);
    for (back) |v| try testing.expectApproxEqAbs(@as(f32, 0), v, 1e-20);
}

test "bad arguments are errors" {
    var enc = Encoder.init(2);
    var out: [100]u8 = undefined;
    const pcm: [1920]f32 = @splat(0);
    try testing.expectError(error.BufferTooSmall, enc.encode(&pcm, 3, out[0..1]));
    try testing.expectError(error.InvalidFrameSize, enc.encode(&pcm, 4, &out));
    try testing.expectError(error.InvalidFrameSize, enc.encode(pcm[0..100], 3, &out));
}

test "a sine is a tone at its frequency and noise is not" {
    var sine: [960 + overlap]f32 = undefined;
    var noise: [960 + overlap]f32 = undefined;
    var work: [960 + overlap]f32 = undefined;
    var rng: @import("../test_util.zig").Xorshift = .{ .s = 3 };
    for (&sine, &noise, 0..) |*s, *n, i| {
        s.* = 8000 * @sin(@as(f32, @floatFromInt(i)) * 2.0 * std.math.pi * 440.0 / 48000.0);
        n.* = @as(f32, @floatFromInt(@as(i32, @bitCast(rng.next())) >> 18));
    }
    const t = toneDetect(&sine, sine.len, 1, &work);
    try testing.expect(t.toneishness > 0.99);
    try testing.expectApproxEqAbs(@as(f32, 2.0 * std.math.pi * 440.0 / 48000.0), t.freq, 1e-4);
    const u = toneDetect(&noise, noise.len, 1, &work);
    try testing.expect(u.toneishness < 0.9);
}
