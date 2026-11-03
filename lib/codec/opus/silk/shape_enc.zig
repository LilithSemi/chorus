//! Noise shaping analysis and gain processing of the SILK encoder, ported from libopus
//! silk/float/noise_shape_analysis_FLP.c, silk/float/process_gains_FLP.c and silk/gain_quant.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const m = @import("macros.zig");
const tables = @import("tables.zig");
const flp = @import("flp.zig");
const st = @import("enc_state.zig");

const shape_order = st.max_shape_lpc_order;
const n_levels_qgain = 64;
const max_delta_gain_quant = 36;
const min_delta_gain_quant = -4;
const gain_offset = 2090;
const scale_q16 = 2251;
const inv_scale_q16 = 1907825;

/// Quantizes the gains of the subframes to log indices. `gain_q16` gets the quantized gains.
pub fn gainsQuant(ind: []i8, gain_q16: []i32, prev_ind: *i8, conditional: bool, nb_subfr: usize) void {
    for (0..nb_subfr) |k| {
        var v: i32 = @as(i8, @truncate(m.smulwb(scale_q16, m.lin2log(gain_q16[k]) - gain_offset)));
        if (v < prev_ind.*) v += 1;
        v = std.math.clamp(v, 0, n_levels_qgain - 1);
        if (k == 0 and !conditional) {
            v = m.limit(v, prev_ind.* + min_delta_gain_quant, n_levels_qgain - 1);
            prev_ind.* = @intCast(v);
        } else {
            v -= prev_ind.*;
            const double_step_size_threshold: i32 = 2 * max_delta_gain_quant - n_levels_qgain + prev_ind.*;
            if (v > double_step_size_threshold) {
                v = double_step_size_threshold + ((v - double_step_size_threshold + 1) >> 1);
            }
            v = std.math.clamp(v, min_delta_gain_quant, max_delta_gain_quant);
            if (v > double_step_size_threshold) {
                var p: i32 = prev_ind.* + ((v << 1) - double_step_size_threshold);
                p = @min(p, n_levels_qgain - 1);
                prev_ind.* = @intCast(p);
            } else {
                prev_ind.* = @intCast(@as(i32, prev_ind.*) + v);
            }
            v -= min_delta_gain_quant;
        }
        ind[k] = @intCast(v);
        gain_q16[k] = m.log2lin(@min(m.smulwb(inv_scale_q16, prev_ind.*) + gain_offset, 3967));
    }
}

/// The gains that a decoder gets from the indices.
pub fn gainsDequant(gain_q16: []i32, ind: []const i8, prev_ind: *i8, conditional: bool, nb_subfr: usize) void {
    for (0..nb_subfr) |k| {
        var p: i32 = prev_ind.*;
        if (k == 0 and !conditional) {
            p = @max(ind[k], p - 16);
        } else {
            const ind_tmp: i32 = @as(i32, ind[k]) + min_delta_gain_quant;
            const double_step_size_threshold: i32 = 2 * max_delta_gain_quant - n_levels_qgain + p;
            if (ind_tmp > double_step_size_threshold) {
                p += (ind_tmp << 1) - double_step_size_threshold;
            } else {
                p += ind_tmp;
            }
        }
        p = std.math.clamp(p, 0, n_levels_qgain - 1);
        prev_ind.* = @intCast(p);
        gain_q16[k] = m.log2lin(@min(m.smulwb(inv_scale_q16, p) + gain_offset, 3967));
    }
}

/// A number that identifies the gain indices of a frame.
pub fn gainsId(ind: []const i8, nb_subfr: usize) i32 {
    var id: i32 = 0;
    for (0..nb_subfr) |k| id = ind[k] +% (id << 8);
    return id;
}

fn warpedGain(coefs: []const f32, lambda_in: f32, order: usize) f32 {
    const lambda = -lambda_in;
    var gain = coefs[order - 1];
    var i = order - 1;
    while (i > 0) {
        i -= 1;
        gain = lambda * gain + coefs[i];
    }
    return 1.0 / (1.0 - lambda * gain);
}

fn warpedTrue2MonicCoefs(coefs: []f32, lambda: f32, limit: f32, order: usize) void {
    var ind: usize = 0;
    var i = order - 1;
    while (i > 0) : (i -= 1) coefs[i - 1] -= lambda * coefs[i];
    var gain = (1.0 - lambda * lambda) / (1.0 + lambda * coefs[0]);
    for (coefs[0..order]) |*c| c.* *= gain;
    var iter: u32 = 0;
    while (iter < 10) : (iter += 1) {
        var maxabs: f32 = -1.0;
        for (0..order) |j| {
            const tmp = @abs(coefs[j]);
            if (tmp > maxabs) {
                maxabs = tmp;
                ind = j;
            }
        }
        if (maxabs <= limit) return;
        for (1..order) |j| coefs[j - 1] += lambda * coefs[j];
        gain = 1.0 / gain;
        for (coefs[0..order]) |*c| c.* *= gain;
        const chirp = 0.99 - (0.8 + 0.1 * @as(f32, @floatFromInt(iter))) * (maxabs - limit) / (maxabs * @as(f32, @floatFromInt(ind + 1)));
        flp.bwexpander(coefs[0..order], chirp);
        i = order - 1;
        while (i > 0) : (i -= 1) coefs[i - 1] -= lambda * coefs[i];
        gain = (1.0 - lambda * lambda) / (1.0 + lambda * coefs[0]);
        for (coefs[0..order]) |*c| c.* *= gain;
    }
}

fn limitCoefs(coefs: []f32, limit: f32, order: usize) void {
    var ind: usize = 0;
    var iter: u32 = 0;
    while (iter < 10) : (iter += 1) {
        var maxabs: f32 = -1.0;
        for (0..order) |j| {
            const tmp = @abs(coefs[j]);
            if (tmp > maxabs) {
                maxabs = tmp;
                ind = j;
            }
        }
        if (maxabs <= limit) return;
        const chirp = 0.99 - (0.8 + 0.1 * @as(f32, @floatFromInt(iter))) * (maxabs - limit) / (maxabs * @as(f32, @floatFromInt(ind + 1)));
        flp.bwexpander(coefs[0..order], chirp);
    }
}

/// Computes the noise shaping filters, the initial gains and the shaping parameters of the frame.
/// `x` holds the signal and `x_off` is the position of the frame in it. `pitch_res` and `res_off`
/// are the same for the residual of the pitch analysis.
pub fn noiseShapeAnalysis(ch: *st.Channel, ctrl: *st.Control, pitch_res: []const f32, res_off: usize, x: []const f32, x_off: usize) void {
    const hp_noise_coef: f32 = 0.25;
    const harm_hp_noise_coef: f32 = 0.35;
    const inv128: f32 = 1.0 / 128.0;
    const inv256: f32 = 1.0 / 256.0;
    const inv32768: f32 = 1.0 / 32768.0;
    const nb_subfr: usize = @intCast(ch.nb_subfr);
    const fs_khz: usize = @intCast(ch.fs_khz);
    const order: usize = @intCast(ch.shaping_lpc_order);
    const win_length: usize = @intCast(ch.shape_win_length);
    const speech_act: f32 = @floatFromInt(ch.speech_activity_q8);
    var x_pos = x_off - @as(usize, @intCast(ch.la_shape));

    var snr_adj_db: f32 = @as(f32, @floatFromInt(ch.snr_db_q7)) * inv128;
    ctrl.input_quality = 0.5 * @as(f32, @floatFromInt(ch.input_quality_bands_q15[0] + ch.input_quality_bands_q15[1])) * inv32768;
    ctrl.coding_quality = flp.sigmoid(0.25 * (snr_adj_db - 20.0));
    if (!ch.use_cbr) {
        const b = 1.0 - speech_act * inv256;
        snr_adj_db -= 2.0 * ctrl.coding_quality * (0.5 + 0.5 * ctrl.input_quality) * b * b;
    }
    if (ch.indices.signal_type == st.type_voiced) {
        snr_adj_db += 2.0 * ch.ltp_corr;
    } else {
        snr_adj_db += (-0.4 * @as(f32, @floatFromInt(ch.snr_db_q7)) * inv128 + 6.0) * (1.0 - ctrl.input_quality);
    }

    if (ch.indices.signal_type == st.type_voiced) {
        ch.indices.quant_offset_type = 0;
    } else {
        const n_samples = 2 * fs_khz;
        var energy_variation: f32 = 0.0;
        var log_energy_prev: f32 = 0.0;
        var res_pos = res_off;
        const n_segs = (5 * nb_subfr) / 2;
        for (0..n_segs) |k| {
            const nrg: f32 = @as(f32, @floatFromInt(n_samples)) + @as(f32, @floatCast(flp.energy(pitch_res[res_pos..][0..n_samples])));
            const log_energy = flp.log2(nrg);
            if (k > 0) energy_variation += @abs(log_energy - log_energy_prev);
            log_energy_prev = log_energy;
            res_pos += n_samples;
        }
        if (energy_variation > 0.6 * @as(f32, @floatFromInt(n_segs - 1))) {
            ch.indices.quant_offset_type = 0;
        } else {
            ch.indices.quant_offset_type = 1;
        }
    }

    var strength: f32 = 1e-3 * ctrl.pred_gain;
    const bw_exp: f32 = 0.94 / (1.0 + strength * strength);
    const warping: f32 = @as(f32, @floatFromInt(ch.warping_q16)) / 65536.0 + 0.01 * ctrl.coding_quality;

    var x_windowed: [15 * 16]f32 = undefined;
    for (0..nb_subfr) |k| {
        const flat_part = fs_khz * 3;
        const slope_part = (win_length - flat_part) / 2;
        flp.applySineWindow(x_windowed[0..slope_part], x[x_pos..][0..slope_part], 1, slope_part);
        var shift = slope_part;
        @memcpy(x_windowed[shift..][0..flat_part], x[x_pos + shift ..][0..flat_part]);
        shift += flat_part;
        flp.applySineWindow(x_windowed[shift..][0..slope_part], x[x_pos + shift ..][0..slope_part], 2, slope_part);
        x_pos += @intCast(ch.subfr_length);

        var auto_corr: [shape_order + 1]f32 = undefined;
        if (ch.warping_q16 > 0) {
            flp.warpedAutocorrelation(&auto_corr, x_windowed[0..win_length], warping, order);
        } else {
            flp.autocorrelation(&auto_corr, x_windowed[0..win_length], order + 1);
        }
        auto_corr[0] += auto_corr[0] * 3e-5 + 1.0;
        var rc: [shape_order + 1]f32 = undefined;
        const nrg = flp.schur(&rc, &auto_corr, order);
        const ar = ctrl.ar[k * shape_order ..][0..shape_order];
        flp.k2a(ar, &rc, order);
        ctrl.gains[k] = @floatCast(@sqrt(@as(f64, nrg)));
        if (ch.warping_q16 > 0) ctrl.gains[k] *= warpedGain(ar, warping, order);
        flp.bwexpander(ar[0..order], bw_exp);
        if (ch.warping_q16 > 0) {
            warpedTrue2MonicCoefs(ar, warping, 3.999, order);
        } else {
            limitCoefs(ar, 3.999, order);
        }
    }

    const gain_mult: f32 = @floatCast(std.math.pow(f64, 2.0, -0.16 * snr_adj_db));
    const gain_add_exp: f32 = 0.16 * @as(f32, 2.0);
    const gain_add: f32 = @floatCast(std.math.pow(f64, 2.0, gain_add_exp));
    for (0..nb_subfr) |k| {
        ctrl.gains[k] *= gain_mult;
        ctrl.gains[k] += gain_add;
    }

    strength = 4.0 * (1.0 + 0.5 * (@as(f32, @floatFromInt(ch.input_quality_bands_q15[0])) * inv32768 - 1.0));
    strength *= speech_act * inv256;
    var tilt: f32 = undefined;
    if (ch.indices.signal_type == st.type_voiced) {
        for (0..nb_subfr) |k| {
            const b = 0.2 / @as(f32, @floatFromInt(ch.fs_khz)) + 3.0 / @as(f32, @floatFromInt(ctrl.pitch_l[k]));
            ctrl.lf_ma_shp[k] = -1.0 + b;
            ctrl.lf_ar_shp[k] = 1.0 - b - b * strength;
        }
        tilt = -hp_noise_coef - (1 - hp_noise_coef) * harm_hp_noise_coef * speech_act * inv256;
    } else {
        const b = 1.3 / @as(f32, @floatFromInt(ch.fs_khz));
        ctrl.lf_ma_shp[0] = -1.0 + b;
        ctrl.lf_ar_shp[0] = 1.0 - b - b * strength * 0.6;
        for (1..nb_subfr) |k| {
            ctrl.lf_ma_shp[k] = ctrl.lf_ma_shp[0];
            ctrl.lf_ar_shp[k] = ctrl.lf_ar_shp[0];
        }
        tilt = -hp_noise_coef;
    }

    var harm_shape_gain: f32 = undefined;
    if (ch.indices.signal_type == st.type_voiced) {
        harm_shape_gain = 0.3;
        harm_shape_gain += 0.2 * (1.0 - (1.0 - ctrl.coding_quality) * ctrl.input_quality);
        harm_shape_gain *= @floatCast(@sqrt(@as(f64, ch.ltp_corr)));
    } else {
        harm_shape_gain = 0.0;
    }

    for (0..nb_subfr) |k| {
        ch.harm_shape_gain_smth += 0.4 * (harm_shape_gain - ch.harm_shape_gain_smth);
        ctrl.harm_shape_gain[k] = ch.harm_shape_gain_smth;
        ch.tilt_smth += 0.4 * (tilt - ch.tilt_smth);
        ctrl.tilt[k] = ch.tilt_smth;
    }
}

/// Quantizes the gains and sets the rate distortion trade off of the quantizer.
pub fn processGains(ch: *st.Channel, ctrl: *st.Control, cond: st.Cond) void {
    const nb_subfr: usize = @intCast(ch.nb_subfr);
    if (ch.indices.signal_type == st.type_voiced) {
        const s: f32 = 1.0 - 0.5 * flp.sigmoid(0.25 * (ctrl.ltp_pred_cod_gain - 12.0));
        for (0..nb_subfr) |k| ctrl.gains[k] *= s;
    }
    const exponent: f32 = 0.33 * (21.0 - @as(f32, @floatFromInt(ch.snr_db_q7)) * (1.0 / 128.0));
    const inv_max_sqr_val: f32 = @floatCast(std.math.pow(f64, 2.0, exponent) / @as(f64, @floatFromInt(ch.subfr_length)));
    for (0..nb_subfr) |k| {
        var gain = ctrl.gains[k];
        gain = @floatCast(@sqrt(@as(f64, gain * gain + ctrl.res_nrg[k] * inv_max_sqr_val)));
        ctrl.gains[k] = @min(gain, 32767.0);
    }
    var p_gains_q16: [st.max_subfr]i32 = undefined;
    for (0..nb_subfr) |k| p_gains_q16[k] = truncInt(ctrl.gains[k] * 65536.0);
    ctrl.gains_unq_q16 = p_gains_q16;
    ctrl.last_gain_index_prev = ch.last_gain_index;
    gainsQuant(&ch.indices.gains, &p_gains_q16, &ch.last_gain_index, cond == .conditionally, nb_subfr);
    for (0..nb_subfr) |k| ctrl.gains[k] = @as(f32, @floatFromInt(p_gains_q16[k])) / 65536.0;

    if (ch.indices.signal_type == st.type_voiced) {
        if (ctrl.ltp_pred_cod_gain + @as(f32, @floatFromInt(ch.input_tilt_q15)) * (1.0 / 32768.0) > 1.0) {
            ch.indices.quant_offset_type = 0;
        } else {
            ch.indices.quant_offset_type = 1;
        }
    }
    const offset_q10: i32 = tables.quantization_offsets_q10[@as(usize, @intCast(ch.indices.signal_type >> 1)) * 2 + @as(usize, @intCast(ch.indices.quant_offset_type))];
    const quant_offset: f32 = @as(f32, @floatFromInt(offset_q10)) / 1024.0;
    ctrl.lambda = 1.2 +
        -0.05 * @as(f32, @floatFromInt(ch.n_states_delayed_decision)) +
        -0.2 * @as(f32, @floatFromInt(ch.speech_activity_q8)) * (1.0 / 256.0) +
        -0.1 * ctrl.input_quality +
        -0.2 * ctrl.coding_quality +
        0.8 * quant_offset;
}

/// The C cast of a float to a 32 bit integer: truncation toward zero.
pub fn truncInt(x: f32) i32 {
    if (!(x > -2147483648.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(x);
}

const testing = std.testing;

test "gain quantization and dequantization agree" {
    var ind: [4]i8 = undefined;
    var gains = [4]i32{ 100000, 120000, 90000, 60000 };
    var prev: i8 = 10;
    gainsQuant(&ind, &gains, &prev, false, 4);
    var out: [4]i32 = undefined;
    var prev2: i8 = 10;
    gainsDequant(&out, &ind, &prev2, false, 4);
    try testing.expectEqualSlices(i32, &gains, &out);
    try testing.expectEqual(prev, prev2);
}
