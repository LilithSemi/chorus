//! Pitch analysis of the SILK encoder, ported from libopus silk/float/pitch_analysis_core_FLP.c
//! and silk/float/find_pitch_lags_FLP.c. libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const m = @import("macros.zig");
const tables = @import("tables.zig");
const enc_tables = @import("enc_tables.zig");
const flp = @import("flp.zig");
const st = @import("enc_state.zig");
const resampler = @import("enc_resampler.zig");
const pitchXcorr = @import("../celt/pitch.zig").pitchXcorr;

const max_nb_subfr = 4;
const max_lag_len = 288 / 2 + 5;
const nb_stage3_lags = 5;
const nb_cbks_stage3_max = 34;
const nb_cbks_stage2_ext = 11;
const scratch_size = 22;
const pe_ltp_mem_length_ms = 20;
const pe_subfr_length_ms = 5;
const pe_max_lag_ms = 18;
const pe_min_lag_ms = 2;
const shortlag_bias: f32 = 0.2;
const prevlag_bias: f32 = 0.2;
const flatcontour_bias: f32 = 0.05;

/// Buffers of the pitch analysis. They live in the encoder so that a call needs little stack.
pub const Scratch = struct {
    frame_8khz: [40 * 8]f32,
    frame_4khz: [40 * 4]f32,
    frame_8_fix: [40 * 8]i16,
    frame_4_fix: [40 * 4]i16,
    frame_in_fix: [40 * 16]i16,
    c: [max_nb_subfr][max_lag_len]f32,
    energies_st3: [max_nb_subfr][nb_cbks_stage3_max][nb_stage3_lags]f32,
    cross_corr_st3: [max_nb_subfr][nb_cbks_stage3_max][nb_stage3_lags]f32,
};

fn short2float(out: []f32, in: []const i16) void {
    for (out, in) |*o, v| o.* = @floatFromInt(v);
}

fn float2shortArray(out: []i16, in: []const f32) void {
    for (out, in) |*o, v| o.* = flp.float2short(v);
}

/// The correlations of the third stage, for all lags near the best lag of the second stage.
fn calcCorrSt3(cross: *[max_nb_subfr][nb_cbks_stage3_max][nb_stage3_lags]f32, frame: []const f32, start_lag: i32, sf_length: usize, nb_subfr: usize, complexity: usize) void {
    var scratch_mem: [scratch_size]f32 = undefined;
    var xcorr: [scratch_size]f32 = undefined;
    const lag_cb: []const i8 = if (nb_subfr == max_nb_subfr) &tables.cb_lags_stage3 else &tables.cb_lags_stage3_10_ms;
    const nb_cbk_search: usize = if (nb_subfr == max_nb_subfr) enc_tables.nb_cbk_searchs_stage3[complexity] else 12;
    const cbk_size: usize = if (nb_subfr == max_nb_subfr) nb_cbks_stage3_max else 12;
    var target: usize = sf_length << 2;
    for (0..nb_subfr) |k| {
        const range = if (nb_subfr == max_nb_subfr) enc_tables.lag_range_stage3[complexity][k] else enc_tables.lag_range_stage3_10_ms[k];
        const lag_low: i32 = range[0];
        const lag_high: i32 = range[1];
        const n_lags: usize = @intCast(lag_high - lag_low + 1);
        const y_start: usize = @intCast(@as(i32, @intCast(target)) - start_lag - lag_high);
        pitchXcorr(frame[target..][0..sf_length], frame[y_start..], xcorr[0..n_lags]);
        var lag_counter: usize = 0;
        var j = lag_low;
        while (j <= lag_high) : (j += 1) {
            scratch_mem[lag_counter] = xcorr[@intCast(lag_high - j)];
            lag_counter += 1;
        }
        const delta: i32 = lag_low;
        for (0..nb_cbk_search) |i| {
            const idx: usize = @intCast(@as(i32, lag_cb[k * cbk_size + i]) - delta);
            for (0..nb_stage3_lags) |jj| cross[k][i][jj] = scratch_mem[idx + jj];
        }
        target += sf_length;
    }
}

/// The energies of the third stage for the same lags, computed recursively.
fn calcEnergySt3(energies: *[max_nb_subfr][nb_cbks_stage3_max][nb_stage3_lags]f32, frame: []const f32, start_lag: i32, sf_length: usize, nb_subfr: usize, complexity: usize) void {
    var scratch_mem: [scratch_size]f32 = undefined;
    const lag_cb: []const i8 = if (nb_subfr == max_nb_subfr) &tables.cb_lags_stage3 else &tables.cb_lags_stage3_10_ms;
    const nb_cbk_search: usize = if (nb_subfr == max_nb_subfr) enc_tables.nb_cbk_searchs_stage3[complexity] else 12;
    const cbk_size: usize = if (nb_subfr == max_nb_subfr) nb_cbks_stage3_max else 12;
    var target: usize = sf_length << 2;
    for (0..nb_subfr) |k| {
        const range = if (nb_subfr == max_nb_subfr) enc_tables.lag_range_stage3[complexity][k] else enc_tables.lag_range_stage3_10_ms[k];
        const lag_low: i32 = range[0];
        const lag_high: i32 = range[1];
        const basis: usize = @intCast(@as(i32, @intCast(target)) - (start_lag + lag_low));
        var energy: f64 = flp.energy(frame[basis..][0..sf_length]) + 1e-3;
        scratch_mem[0] = @floatCast(energy);
        var lag_counter: usize = 1;
        const lag_diff: usize = @intCast(lag_high - lag_low + 1);
        for (1..lag_diff) |i| {
            const out = frame[basis + sf_length - i];
            energy -= @as(f64, out) * out;
            const in = frame[basis - i];
            energy += @as(f64, in) * in;
            scratch_mem[lag_counter] = @floatCast(energy);
            lag_counter += 1;
        }
        const delta: i32 = lag_low;
        for (0..nb_cbk_search) |i| {
            const idx: usize = @intCast(@as(i32, lag_cb[k * cbk_size + i]) - delta);
            for (0..nb_stage3_lags) |jj| energies[k][i][jj] = scratch_mem[idx + jj];
        }
        target += sf_length;
    }
}

/// Finds the pitch lags of the frame in three stages. Returns true when the frame is unvoiced.
/// `frame` holds the residual of 20 ms of past samples and the frame.
pub fn analysisCore(
    sc: *Scratch,
    frame: []const f32,
    pitch_out: []i32,
    lag_index: *i16,
    contour_index: *i8,
    ltp_corr: *f32,
    prev_lag_in: i32,
    search_thres1: f32,
    search_thres2: f32,
    fs_khz: i32,
    complexity: i32,
    nb_subfr_i: i32,
) bool {
    const nb_subfr: usize = @intCast(nb_subfr_i);
    const fs: usize = @intCast(fs_khz);
    const cx: usize = @intCast(complexity);
    const frame_length = (pe_ltp_mem_length_ms + nb_subfr * pe_subfr_length_ms) * fs;
    const frame_length_4khz = (pe_ltp_mem_length_ms + nb_subfr * pe_subfr_length_ms) * 4;
    const frame_length_8khz = (pe_ltp_mem_length_ms + nb_subfr * pe_subfr_length_ms) * 8;
    const sf_length = pe_subfr_length_ms * fs;
    const sf_length_4khz = pe_subfr_length_ms * 4;
    const sf_length_8khz = pe_subfr_length_ms * 8;
    const min_lag: i32 = @intCast(pe_min_lag_ms * fs);
    const min_lag_4khz: usize = pe_min_lag_ms * 4;
    const min_lag_8khz: usize = pe_min_lag_ms * 8;
    const max_lag: i32 = @intCast(pe_max_lag_ms * fs - 1);
    const max_lag_4khz: usize = pe_max_lag_ms * 4;
    const max_lag_8khz: usize = pe_max_lag_ms * 8 - 1;

    if (fs_khz == 16) {
        float2shortArray(sc.frame_in_fix[0..frame_length], frame[0..frame_length]);
        var filt: [2]i32 = @splat(0);
        resampler.down2(&filt, &sc.frame_8_fix, sc.frame_in_fix[0..frame_length]);
        short2float(sc.frame_8khz[0..frame_length_8khz], sc.frame_8_fix[0..frame_length_8khz]);
    } else if (fs_khz == 12) {
        float2shortArray(sc.frame_in_fix[0..frame_length], frame[0..frame_length]);
        var filt: [6]i32 = @splat(0);
        resampler.down2_3(&filt, &sc.frame_8_fix, sc.frame_in_fix[0..frame_length]);
        short2float(sc.frame_8khz[0..frame_length_8khz], sc.frame_8_fix[0..frame_length_8khz]);
    } else {
        float2shortArray(sc.frame_8_fix[0..frame_length_8khz], frame[0..frame_length_8khz]);
    }
    {
        var filt: [2]i32 = @splat(0);
        resampler.down2(&filt, &sc.frame_4_fix, sc.frame_8_fix[0..frame_length_8khz]);
        short2float(sc.frame_4khz[0..frame_length_4khz], sc.frame_4_fix[0..frame_length_4khz]);
    }
    var i: usize = frame_length_4khz - 1;
    while (i > 0) : (i -= 1) {
        sc.frame_4khz[i] = @floatFromInt(std.math.clamp(@as(i32, @intFromFloat(sc.frame_4khz[i])) + @as(i32, @intFromFloat(sc.frame_4khz[i - 1])), -32768, 32767));
    }

    // First stage, at 4 kHz.
    for (sc.c[0..nb_subfr]) |*row| @memset(row, 0);
    var xcorr: [max_lag_4khz - min_lag_4khz + 1]f32 = undefined;
    var target: usize = sf_length_4khz << 2;
    for (0..nb_subfr >> 1) |_| {
        var basis: usize = target - min_lag_4khz;
        pitchXcorr(sc.frame_4khz[target..][0..sf_length_8khz], sc.frame_4khz[target - max_lag_4khz ..], &xcorr);
        var cross_corr: f64 = xcorr[max_lag_4khz - min_lag_4khz];
        var normalizer: f64 = flp.energy(sc.frame_4khz[target..][0..sf_length_8khz]) +
            flp.energy(sc.frame_4khz[basis..][0..sf_length_8khz]) +
            @as(f32, @floatFromInt(sf_length_8khz)) * 4000.0;
        sc.c[0][min_lag_4khz] += @floatCast(2 * cross_corr / normalizer);
        var d = min_lag_4khz + 1;
        while (d <= max_lag_4khz) : (d += 1) {
            basis -= 1;
            cross_corr = xcorr[max_lag_4khz - d];
            const b0 = sc.frame_4khz[basis];
            const b1 = sc.frame_4khz[basis + sf_length_8khz];
            normalizer += @as(f64, b0) * b0 - @as(f64, b1) * b1;
            sc.c[0][d] += @floatCast(2 * cross_corr / normalizer);
        }
        target += sf_length_8khz;
    }
    i = max_lag_4khz;
    while (i >= min_lag_4khz) : (i -= 1) {
        sc.c[0][i] -= sc.c[0][i] * @as(f32, @floatFromInt(i)) / 4096.0;
    }

    var length_d_srch: usize = @intCast(4 + 2 * complexity);
    var d_srch: [24]i32 = undefined;
    flp.insertionSortDecreasing(sc.c[0][min_lag_4khz..], &d_srch, max_lag_4khz - min_lag_4khz + 1, length_d_srch);
    const cmax = sc.c[0][min_lag_4khz];
    if (cmax < 0.2) {
        @memset(pitch_out[0..nb_subfr], 0);
        ltp_corr.* = 0;
        lag_index.* = 0;
        contour_index.* = 0;
        return true;
    }
    const threshold = search_thres1 * cmax;
    for (0..length_d_srch) |k| {
        if (sc.c[0][min_lag_4khz + k] > threshold) {
            d_srch[k] = (d_srch[k] + @as(i32, @intCast(min_lag_4khz))) << 1;
        } else {
            length_d_srch = k;
            break;
        }
    }
    var d_comp: [max_lag_len]i16 = undefined;
    for (min_lag_8khz - 5..max_lag_8khz + 5) |k| d_comp[k] = 0;
    for (0..length_d_srch) |k| d_comp[@intCast(d_srch[k])] = 1;
    i = max_lag_8khz + 3;
    while (i >= min_lag_8khz) : (i -= 1) d_comp[i] +%= d_comp[i - 1] +% d_comp[i - 2];
    length_d_srch = 0;
    for (min_lag_8khz..max_lag_8khz + 1) |k| {
        if (d_comp[k + 1] > 0) {
            d_srch[length_d_srch] = @intCast(k);
            length_d_srch += 1;
        }
    }
    i = max_lag_8khz + 3;
    while (i >= min_lag_8khz) : (i -= 1) d_comp[i] +%= d_comp[i - 1] +% d_comp[i - 2] +% d_comp[i - 3];
    var length_d_comp: usize = 0;
    for (min_lag_8khz..max_lag_8khz + 4) |k| {
        if (d_comp[k] > 0) {
            d_comp[length_d_comp] = @intCast(@as(i32, @intCast(k)) - 2);
            length_d_comp += 1;
        }
    }

    // Second stage, at 8 kHz, on the lags with high correlation.
    for (sc.c[0..max_nb_subfr]) |*row| @memset(row, 0);
    const frame_8: []const f32 = if (fs_khz == 8) frame else &sc.frame_8khz;
    target = pe_ltp_mem_length_ms * 8;
    for (0..nb_subfr) |k| {
        const energy_tmp: f64 = flp.energy(frame_8[target..][0..sf_length_8khz]) + 1.0;
        for (0..length_d_comp) |j| {
            const d: usize = @intCast(d_comp[j]);
            const basis = target - d;
            const cc = flp.innerProduct(frame_8[basis..][0..sf_length_8khz], frame_8[target..][0..sf_length_8khz]);
            if (cc > 0.0) {
                const energy = flp.energy(frame_8[basis..][0..sf_length_8khz]);
                sc.c[k][d] = @floatCast(2 * cc / (energy + energy_tmp));
            } else {
                sc.c[k][d] = 0.0;
            }
        }
        target += sf_length_8khz;
    }

    var ccmax: f32 = 0.0;
    var ccmax_b: f32 = -1000.0;
    var cbimax: usize = 0;
    var lag: i32 = -1;
    var prev_lag = prev_lag_in;
    var prev_lag_log2: f32 = 0;
    if (prev_lag > 0) {
        if (fs_khz == 12) {
            prev_lag = @divTrunc(prev_lag << 1, 3);
        } else if (fs_khz == 16) {
            prev_lag >>= 1;
        }
        prev_lag_log2 = flp.log2(@as(f32, @floatFromInt(prev_lag)));
    }
    var cbk_size: usize = undefined;
    var lag_cb: []const i8 = undefined;
    var nb_cbk_search: usize = undefined;
    if (nb_subfr == max_nb_subfr) {
        cbk_size = nb_cbks_stage2_ext;
        lag_cb = &tables.cb_lags_stage2;
        nb_cbk_search = if (fs_khz == 8 and complexity > 0) nb_cbks_stage2_ext else 3;
    } else {
        cbk_size = 3;
        lag_cb = &tables.cb_lags_stage2_10_ms;
        nb_cbk_search = 3;
    }
    const nb_subfr_f: f32 = @floatFromInt(nb_subfr);
    for (0..length_d_srch) |k| {
        const d: i32 = d_srch[k];
        var cc: [nb_cbks_stage2_ext]f32 = undefined;
        for (0..nb_cbk_search) |j| {
            cc[j] = 0.0;
            for (0..nb_subfr) |ii| {
                cc[j] += sc.c[ii][@intCast(d + lag_cb[ii * cbk_size + j])];
            }
        }
        var ccmax_new: f32 = -1000.0;
        var cbimax_new: usize = 0;
        for (0..nb_cbk_search) |ii| {
            if (cc[ii] > ccmax_new) {
                ccmax_new = cc[ii];
                cbimax_new = ii;
            }
        }
        const lag_log2 = flp.log2(@as(f32, @floatFromInt(d)));
        var ccmax_new_b = ccmax_new - shortlag_bias * nb_subfr_f * lag_log2;
        if (prev_lag > 0) {
            var delta_lag_log2_sqr = lag_log2 - prev_lag_log2;
            delta_lag_log2_sqr *= delta_lag_log2_sqr;
            ccmax_new_b -= prevlag_bias * nb_subfr_f * ltp_corr.* * delta_lag_log2_sqr / (delta_lag_log2_sqr + 0.5);
        }
        if (ccmax_new_b > ccmax_b and ccmax_new > nb_subfr_f * search_thres2) {
            ccmax_b = ccmax_new_b;
            ccmax = ccmax_new;
            lag = d;
            cbimax = cbimax_new;
        }
    }
    if (lag == -1) {
        @memset(pitch_out[0..max_nb_subfr], 0);
        ltp_corr.* = 0;
        lag_index.* = 0;
        contour_index.* = 0;
        return true;
    }
    ltp_corr.* = ccmax / nb_subfr_f;

    if (fs_khz > 8) {
        if (fs_khz == 12) {
            lag = m.rshiftRound(m.smulbb(lag, 3), 1);
        } else {
            lag = lag << 1;
        }
        lag = m.limit(lag, min_lag, max_lag);
        const start_lag = @max(lag - 2, min_lag);
        const end_lag = @min(lag + 2, max_lag);
        var lag_new = lag;
        cbimax = 0;
        ccmax = -1000.0;
        calcCorrSt3(&sc.cross_corr_st3, frame, start_lag, sf_length, nb_subfr, cx);
        calcEnergySt3(&sc.energies_st3, frame, start_lag, sf_length, nb_subfr, cx);
        var lag_counter: usize = 0;
        const contour_bias: f32 = flatcontour_bias / @as(f32, @floatFromInt(lag));
        var lag_cb3: []const i8 = undefined;
        if (nb_subfr == max_nb_subfr) {
            nb_cbk_search = enc_tables.nb_cbk_searchs_stage3[cx];
            cbk_size = nb_cbks_stage3_max;
            lag_cb3 = &tables.cb_lags_stage3;
        } else {
            nb_cbk_search = 12;
            cbk_size = 12;
            lag_cb3 = &tables.cb_lags_stage3_10_ms;
        }
        const target3 = pe_ltp_mem_length_ms * fs;
        const energy_tmp: f64 = flp.energy(frame[target3..][0 .. nb_subfr * sf_length]) + 1.0;
        var d = start_lag;
        while (d <= end_lag) : (d += 1) {
            for (0..nb_cbk_search) |j| {
                var cross_corr: f64 = 0.0;
                var energy = energy_tmp;
                for (0..nb_subfr) |k| {
                    cross_corr += sc.cross_corr_st3[k][j][lag_counter];
                    energy += sc.energies_st3[k][j][lag_counter];
                }
                var ccmax_new: f32 = undefined;
                if (cross_corr > 0.0) {
                    ccmax_new = @floatCast(2 * cross_corr / energy);
                    ccmax_new *= 1.0 - contour_bias * @as(f32, @floatFromInt(j));
                } else {
                    ccmax_new = 0.0;
                }
                if (ccmax_new > ccmax and (d + @as(i32, tables.cb_lags_stage3[j])) <= max_lag) {
                    ccmax = ccmax_new;
                    lag_new = d;
                    cbimax = j;
                }
            }
            lag_counter += 1;
        }
        for (0..nb_subfr) |k| {
            pitch_out[k] = lag_new + lag_cb3[k * cbk_size + cbimax];
            pitch_out[k] = m.limit(pitch_out[k], min_lag, pe_max_lag_ms * fs_khz);
        }
        lag_index.* = @intCast(lag_new - min_lag);
        contour_index.* = @intCast(cbimax);
    } else {
        for (0..nb_subfr) |k| {
            pitch_out[k] = lag + lag_cb[k * cbk_size + cbimax];
            pitch_out[k] = m.limit(pitch_out[k], @intCast(min_lag_8khz), pe_max_lag_ms * 8);
        }
        lag_index.* = @intCast(lag - @as(i32, @intCast(min_lag_8khz)));
        contour_index.* = @intCast(cbimax);
    }
    return false;
}

/// Whitens the frame with an LPC fit and runs the pitch search when the frame is active.
/// The residual goes to `res`. `ch.x_buf` holds the signal.
pub fn findPitchLags(sc: *Scratch, ch: *st.Channel, ctrl: *st.Control, res: []f32) void {
    const la_pitch: usize = @intCast(ch.la_pitch);
    const frame_length: usize = @intCast(ch.frame_length);
    const ltp_mem_length: usize = @intCast(ch.ltp_mem_length);
    const win_length: usize = @intCast(ch.pitch_lpc_win_length);
    const order: usize = @intCast(ch.pitch_estimation_lpc_order);
    const buf_len = la_pitch + frame_length + ltp_mem_length;
    const x_buf = ch.x_buf[0..buf_len];

    var wsig: [24 * 16]f32 = undefined;
    var start = buf_len - win_length;
    flp.applySineWindow(wsig[0..la_pitch], x_buf[start..][0..la_pitch], 1, la_pitch);
    var w_off = la_pitch;
    start += la_pitch;
    const middle = win_length - (la_pitch << 1);
    @memcpy(wsig[w_off..][0..middle], x_buf[start..][0..middle]);
    w_off += middle;
    start += middle;
    flp.applySineWindow(wsig[w_off..][0..la_pitch], x_buf[start..][0..la_pitch], 2, la_pitch);

    var auto_corr: [flp.max_order_lpc + 1]f32 = undefined;
    flp.autocorrelation(&auto_corr, wsig[0..win_length], order + 1);
    auto_corr[0] += auto_corr[0] * 1e-3 + 1;
    var refl_coef: [16]f32 = undefined;
    const res_nrg = flp.schur(&refl_coef, &auto_corr, order);
    ctrl.pred_gain = auto_corr[0] / @max(res_nrg, 1.0);
    var a: [16]f32 = undefined;
    flp.k2a(&a, &refl_coef, order);
    flp.bwexpander(a[0..order], 0.99);
    flp.lpcAnalysisFilter(res[0..buf_len], &a, x_buf, order);

    if (ch.indices.signal_type != st.type_no_voice_activity and !ch.first_frame_after_reset) {
        var thrhld: f32 = 0.6;
        thrhld -= 0.004 * @as(f32, @floatFromInt(ch.pitch_estimation_lpc_order));
        thrhld -= 0.1 * @as(f32, @floatFromInt(ch.speech_activity_q8)) * (1.0 / 256.0);
        thrhld -= 0.15 * @as(f32, @floatFromInt(ch.prev_signal_type >> 1));
        thrhld -= 0.1 * @as(f32, @floatFromInt(ch.input_tilt_q15)) * (1.0 / 32768.0);
        const unvoiced = analysisCore(
            sc,
            res[0..buf_len],
            &ctrl.pitch_l,
            &ch.indices.lag_index,
            &ch.indices.contour_index,
            &ch.ltp_corr,
            ch.prev_lag,
            @as(f32, @floatFromInt(ch.pitch_estimation_threshold_q16)) / 65536.0,
            thrhld,
            ch.fs_khz,
            ch.pitch_estimation_complexity,
            ch.nb_subfr,
        );
        ch.indices.signal_type = if (unvoiced) st.type_unvoiced else st.type_voiced;
    } else {
        ctrl.pitch_l = @splat(0);
        ch.indices.lag_index = 0;
        ch.indices.contour_index = 0;
        ch.ltp_corr = 0;
    }
}
