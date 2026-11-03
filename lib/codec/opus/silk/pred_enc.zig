//! Linear prediction analysis of the SILK encoder, ported from libopus silk/float/find_pred_coefs_FLP.c,
//! find_LPC_FLP.c, find_LTP_FLP.c, LTP_analysis_filter_FLP.c, LTP_scale_ctrl_FLP.c,
//! residual_energy_FLP.c, wrappers_FLP.c, silk/quant_LTP_gains.c and silk/VQ_WMat_EC.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const m = @import("macros.zig");
const tables = @import("tables.zig");
const enc_tables = @import("enc_tables.zig");
const lpc = @import("lpc.zig");
const flp = @import("flp.zig");
const st = @import("enc_state.zig");
const nlsf_enc = @import("nlsf_enc.zig");
const pitch = @import("pitch.zig");

const ltp_order = st.ltp_order;
const max_order = st.max_lpc_order;
const flt_max: f32 = 3.4028234663852886e38;

const ltp_gain_bits = [3][]const u8{ &enc_tables.ltp_gain_bits_q5_0, &enc_tables.ltp_gain_bits_q5_1, &enc_tables.ltp_gain_bits_q5_2 };
const ltp_vq_gain = [3][]const u8{ &enc_tables.ltp_vq_gain_q7_0, &enc_tables.ltp_vq_gain_q7_1, &enc_tables.ltp_vq_gain_q7_2 };
const ltp_vq_sizes = [3]usize{ 8, 16, 32 };

/// Correlations of the LTP filter taps for every subframe, normalized.
fn findLtp(xx: []f32, xxv: []f32, r: []const f32, r_off: usize, lag: []const i32, subfr_length: usize, nb_subfr: usize) void {
    var r_pos = r_off;
    for (0..nb_subfr) |k| {
        const lag_pos = r_pos - @as(usize, @intCast(lag[k] + ltp_order / 2));
        const xx_k = xx[k * ltp_order * ltp_order ..][0 .. ltp_order * ltp_order];
        const xxv_k = xxv[k * ltp_order ..][0..ltp_order];
        flp.corrMatrix(r[lag_pos..], subfr_length, ltp_order, xx_k);
        flp.corrVector(r[lag_pos..], r[r_pos..], subfr_length, ltp_order, xxv_k);
        const xxe: f32 = @floatCast(flp.energy(r[r_pos..][0 .. subfr_length + ltp_order]));
        const corr_inv_max: f32 = 0.03;
        const temp: f32 = 1.0 / @max(xxe, corr_inv_max * 0.5 * (xx_k[0] + xx_k[24]) + 1.0);
        flp.scaleVector(xx_k, temp);
        flp.scaleVector(xxv_k, temp);
        r_pos += subfr_length;
    }
}

/// Entropy constrained matrix weighted VQ of the five LTP taps of one subframe.
fn vqWMatEc(
    ind: *i8,
    res_nrg_q15: *i32,
    rate_dist_q8: *i32,
    gain_q7: *i32,
    xx_q17: []const i32,
    xxv_q17: []const i32,
    cb_q7: []const i8,
    cb_gain_q7: []const u8,
    cl_q5: []const u8,
    subfr_len: i32,
    max_gain_q7: i32,
    l: usize,
) void {
    var neg_xx_q24: [5]i32 = undefined;
    for (0..5) |i| neg_xx_q24[i] = 0 -% (xxv_q17[i] << 7);
    rate_dist_q8.* = std.math.maxInt(i32);
    res_nrg_q15.* = std.math.maxInt(i32);
    ind.* = 0;
    for (0..l) |k| {
        const row = cb_q7[k * 5 ..][0..5];
        const gain_tmp_q7: i32 = cb_gain_q7[k];
        var sum1_q15: i32 = 32801;
        const penalty = @max(gain_tmp_q7 - max_gain_q7, 0) << 11;
        var sum2 = neg_xx_q24[0] +% xx_q17[1] *% row[1];
        sum2 = sum2 +% xx_q17[2] *% row[2];
        sum2 = sum2 +% xx_q17[3] *% row[3];
        sum2 = sum2 +% xx_q17[4] *% row[4];
        sum2 = sum2 << 1;
        sum2 = sum2 +% xx_q17[0] *% row[0];
        sum1_q15 = m.smlawb(sum1_q15, sum2, row[0]);

        sum2 = neg_xx_q24[1] +% xx_q17[7] *% row[2];
        sum2 = sum2 +% xx_q17[8] *% row[3];
        sum2 = sum2 +% xx_q17[9] *% row[4];
        sum2 = sum2 << 1;
        sum2 = sum2 +% xx_q17[6] *% row[1];
        sum1_q15 = m.smlawb(sum1_q15, sum2, row[1]);

        sum2 = neg_xx_q24[2] +% xx_q17[13] *% row[3];
        sum2 = sum2 +% xx_q17[14] *% row[4];
        sum2 = sum2 << 1;
        sum2 = sum2 +% xx_q17[12] *% row[2];
        sum1_q15 = m.smlawb(sum1_q15, sum2, row[2]);

        sum2 = neg_xx_q24[3] +% xx_q17[19] *% row[4];
        sum2 = sum2 << 1;
        sum2 = sum2 +% xx_q17[18] *% row[3];
        sum1_q15 = m.smlawb(sum1_q15, sum2, row[3]);

        sum2 = neg_xx_q24[4] << 1;
        sum2 = sum2 +% xx_q17[24] *% row[4];
        sum1_q15 = m.smlawb(sum1_q15, sum2, row[4]);

        if (sum1_q15 >= 0) {
            const bits_res_q8 = m.smulbb(subfr_len, m.lin2log(sum1_q15 +% penalty) - (15 << 7));
            const bits_tot_q8 = bits_res_q8 +% (@as(i32, cl_q5[k]) << (3 - 1));
            if (bits_tot_q8 <= rate_dist_q8.*) {
                rate_dist_q8.* = bits_tot_q8;
                res_nrg_q15.* = sum1_q15 +% penalty;
                ind.* = @intCast(k);
                gain_q7.* = gain_tmp_q7;
            }
        }
    }
}

/// Quantizes the LTP taps. Returns the prediction gain in dB.
fn quantLtpGains(
    b: []f32,
    cbk_index: []i8,
    periodicity_index: *i8,
    sum_log_gain_q7: *i32,
    xx: []const f32,
    xxv: []const f32,
    subfr_len: i32,
    nb_subfr: usize,
) f32 {
    var xx_q17: [st.max_subfr * ltp_order * ltp_order]i32 = undefined;
    var xxv_q17: [st.max_subfr * ltp_order]i32 = undefined;
    for (0..nb_subfr * ltp_order * ltp_order) |i| xx_q17[i] = flp.float2int(xx[i] * 131072.0);
    for (0..nb_subfr * ltp_order) |i| xxv_q17[i] = flp.float2int(xxv[i] * 131072.0);

    var temp_idx: [st.max_subfr]i8 = undefined;
    var min_rate_dist_q7: i32 = std.math.maxInt(i32);
    var best_sum_log_gain_q7: i32 = 0;
    var res_nrg_q15: i32 = 0;
    const gain_safety: i32 = 51;
    const max_sum_log_gain: i32 = 5333;
    for (0..3) |k| {
        const cbk = pitch.ltp_vq[k];
        res_nrg_q15 = 0;
        var rate_dist_q7: i32 = 0;
        var sum_log_gain_tmp_q7 = sum_log_gain_q7.*;
        for (0..nb_subfr) |j| {
            const max_gain_q7 = m.log2lin((max_sum_log_gain - sum_log_gain_tmp_q7) + 896) - gain_safety;
            var res_nrg_subfr: i32 = undefined;
            var rate_dist_subfr: i32 = undefined;
            var gain_q7: i32 = 0;
            vqWMatEc(
                &temp_idx[j],
                &res_nrg_subfr,
                &rate_dist_subfr,
                &gain_q7,
                xx_q17[j * 25 ..],
                xxv_q17[j * 5 ..],
                cbk,
                ltp_vq_gain[k],
                ltp_gain_bits[k],
                subfr_len,
                max_gain_q7,
                ltp_vq_sizes[k],
            );
            res_nrg_q15 = m.addPosSat32(res_nrg_q15, res_nrg_subfr);
            rate_dist_q7 = m.addPosSat32(rate_dist_q7, rate_dist_subfr);
            sum_log_gain_tmp_q7 = @max(0, sum_log_gain_tmp_q7 + m.lin2log(gain_safety + gain_q7) - 896);
        }
        if (rate_dist_q7 <= min_rate_dist_q7) {
            min_rate_dist_q7 = rate_dist_q7;
            periodicity_index.* = @intCast(k);
            @memcpy(cbk_index[0..nb_subfr], temp_idx[0..nb_subfr]);
            best_sum_log_gain_q7 = sum_log_gain_tmp_q7;
        }
    }
    const cbk = pitch.ltp_vq[@intCast(periodicity_index.*)];
    for (0..nb_subfr) |j| {
        for (0..ltp_order) |k| {
            const q14: i32 = @as(i32, cbk[@as(usize, @intCast(cbk_index[j])) * ltp_order + k]) << 7;
            b[j * ltp_order + k] = @as(f32, @floatFromInt(q14)) * (1.0 / 16384.0);
        }
    }
    if (nb_subfr == 2) {
        res_nrg_q15 >>= 1;
    } else {
        res_nrg_q15 >>= 2;
    }
    sum_log_gain_q7.* = best_sum_log_gain_q7;
    const pred_gain_db_q7 = m.smulbb(-3, m.lin2log(res_nrg_q15) - (15 << 7));
    return @as(f32, @floatFromInt(pred_gain_db_q7)) * (1.0 / 128.0);
}

/// The C cast of a float to a 16 bit integer: truncation toward zero.
fn truncToI16(x: f32) i32 {
    if (!(x > -2147483648.0 and x < 2147483648.0)) return 0;
    const v: i32 = @intFromFloat(x);
    return @as(i16, @truncate(v));
}

fn ltpScaleCtrl(ch: *st.Channel, ctrl: *st.Control, cond: st.Cond) void {
    if (cond == .independently) {
        var round_loss = ch.packet_loss_perc * ch.n_frames_per_packet;
        if (ch.lbrr_flag != 0) {
            round_loss = 2 + @divTrunc(m.smulbb(round_loss, round_loss), 100);
        }
        const gain = m.smulbb(truncToI16(ctrl.ltp_pred_cod_gain), round_loss);
        ch.indices.ltp_scale_index = @intFromBool(gain > m.log2lin(2900 - ch.snr_db_q7));
        ch.indices.ltp_scale_index += @intFromBool(gain > m.log2lin(3900 - ch.snr_db_q7));
    } else {
        ch.indices.ltp_scale_index = 0;
    }
    ctrl.ltp_scale = @as(f32, @floatFromInt(tables.ltp_scales_table_q14[@intCast(ch.indices.ltp_scale_index)])) / 16384.0;
}

/// Whitens each subframe with its LTP filter and scales it by the inverse gain.
fn ltpAnalysisFilter(
    ltp_res: []f32,
    x: []const f32,
    x_off: usize,
    b: []const f32,
    pitch_l: []const i32,
    inv_gains: []const f32,
    subfr_length: usize,
    nb_subfr: usize,
    pre_length: usize,
) void {
    var x_pos = x_off;
    var res_pos: usize = 0;
    for (0..nb_subfr) |k| {
        var x_lag = x_pos - @as(usize, @intCast(pitch_l[k]));
        const inv_gain = inv_gains[k];
        var btmp: [ltp_order]f32 = undefined;
        for (0..ltp_order) |i| btmp[i] = b[k * ltp_order + i];
        for (0..subfr_length + pre_length) |i| {
            ltp_res[res_pos + i] = x[x_pos + i];
            for (0..ltp_order) |j| {
                ltp_res[res_pos + i] -= btmp[j] * x[x_lag + ltp_order / 2 - j];
            }
            ltp_res[res_pos + i] *= inv_gain;
            x_lag += 1;
        }
        res_pos += subfr_length + pre_length;
        x_pos += subfr_length;
    }
}

fn nlsf2aFlp(a: []f32, nlsf_q15: []const i16, order: usize) void {
    var a_fix_q12: [max_order]i16 = undefined;
    lpc.nlsf2a(a_fix_q12[0..order], nlsf_q15[0..order]);
    for (0..order) |i| a[i] = @as(f32, @floatFromInt(a_fix_q12[i])) * (1.0 / 4096.0);
}

fn a2nlsfFlp(nlsf_q15: []i16, ar: []const f32, order: usize) void {
    var a_fix_q16: [max_order]i32 = undefined;
    for (0..order) |i| a_fix_q16[i] = flp.float2int(ar[i] * 65536.0);
    nlsf_enc.a2nlsf(nlsf_q15, a_fix_q16[0..order], order);
}

/// LPC analysis of the frame by the Burg method and, when active, the interpolation search.
fn findLpc(ch: *st.Channel, nlsf_q15: []i16, x: []const f32, min_inv_gain: f32) void {
    const subfr_length: usize = @intCast(ch.subfr_length + ch.predict_lpc_order);
    const order: usize = @intCast(ch.predict_lpc_order);
    const nb_subfr: usize = @intCast(ch.nb_subfr);
    var a: [max_order]f32 = undefined;
    var a_tmp: [max_order]f32 = undefined;
    var lpc_res: [st.max_frame_length + st.max_subfr * max_order]f32 = undefined;
    ch.indices.nlsf_interp_coef_q2 = 4;
    var res_nrg = flp.burgModified(&a, x, min_inv_gain, subfr_length, nb_subfr, order);
    if (ch.use_interpolated_nlsfs and !ch.first_frame_after_reset and nb_subfr == st.max_subfr) {
        res_nrg -= flp.burgModified(&a_tmp, x[(st.max_subfr / 2) * subfr_length ..], min_inv_gain, subfr_length, st.max_subfr / 2, order);
        a2nlsfFlp(nlsf_q15, &a_tmp, order);
        var res_nrg_2nd: f32 = flt_max;
        var nlsf0: [max_order]i16 = undefined;
        var k: i32 = 3;
        while (k >= 0) : (k -= 1) {
            nlsf_enc.interpolate(&nlsf0, &ch.prev_nlsfq_q15, nlsf_q15, k, order);
            nlsf2aFlp(&a_tmp, &nlsf0, order);
            flp.lpcAnalysisFilter(lpc_res[0 .. 2 * subfr_length], &a_tmp, x, order);
            const e0 = flp.energy(lpc_res[order..][0 .. subfr_length - order]);
            const e1 = flp.energy(lpc_res[order + subfr_length ..][0 .. subfr_length - order]);
            const res_nrg_interp: f32 = @floatCast(e0 + e1);
            if (res_nrg_interp < res_nrg) {
                res_nrg = res_nrg_interp;
                ch.indices.nlsf_interp_coef_q2 = @intCast(k);
            } else if (res_nrg_interp > res_nrg_2nd) {
                break;
            }
            res_nrg_2nd = res_nrg_interp;
        }
    }
    if (ch.indices.nlsf_interp_coef_q2 == 4) {
        a2nlsfFlp(nlsf_q15, &a, order);
    }
}

/// The energy of the LPC residual of each subframe with the quantized filters.
fn residualEnergy(nrgs: *[st.max_subfr]f32, x: []const f32, a: *const [2][max_order]f32, gains: []const f32, subfr_length: usize, nb_subfr: usize, order: usize) void {
    var lpc_res: [(st.max_frame_length + st.max_subfr * max_order) / 2]f32 = undefined;
    const shift = order + subfr_length;
    flp.lpcAnalysisFilter(lpc_res[0 .. 2 * shift], &a[0], x, order);
    nrgs[0] = @floatCast(@as(f64, gains[0] * gains[0]) * flp.energy(lpc_res[order..][0..subfr_length]));
    nrgs[1] = @floatCast(@as(f64, gains[1] * gains[1]) * flp.energy(lpc_res[order + shift ..][0..subfr_length]));
    if (nb_subfr == st.max_subfr) {
        flp.lpcAnalysisFilter(lpc_res[0 .. 2 * shift], &a[1], x[2 * shift ..], order);
        nrgs[2] = @floatCast(@as(f64, gains[2] * gains[2]) * flp.energy(lpc_res[order..][0..subfr_length]));
        nrgs[3] = @floatCast(@as(f64, gains[3] * gains[3]) * flp.energy(lpc_res[order + shift ..][0..subfr_length]));
    }
}

/// Finds the LPC and LTP coefficients of the frame. `x_off` is the position of the frame in
/// `x`, and `res_off` the same in `res_pitch`.
pub fn findPredCoefs(ch: *st.Channel, ctrl: *st.Control, res_pitch: []const f32, res_off: usize, x: []const f32, x_off: usize, cond: st.Cond) void {
    const nb_subfr: usize = @intCast(ch.nb_subfr);
    const subfr_length: usize = @intCast(ch.subfr_length);
    const order: usize = @intCast(ch.predict_lpc_order);
    var inv_gains: [st.max_subfr]f32 = undefined;
    for (0..nb_subfr) |i| inv_gains[i] = 1.0 / ctrl.gains[i];
    var nlsf_q15: [max_order]i16 = @splat(0);
    var lpc_in_pre: [st.max_subfr * max_order + st.max_frame_length]f32 = undefined;

    if (ch.indices.signal_type == st.type_voiced) {
        var xx: [st.max_subfr * ltp_order * ltp_order]f32 = undefined;
        var xxv: [st.max_subfr * ltp_order]f32 = undefined;
        findLtp(&xx, &xxv, res_pitch, res_off, &ctrl.pitch_l, subfr_length, nb_subfr);
        ctrl.ltp_pred_cod_gain = quantLtpGains(&ctrl.ltp_coef, &ch.indices.ltp_index, &ch.indices.per_index, &ch.sum_log_gain_q7, &xx, &xxv, ch.subfr_length, nb_subfr);
        ltpScaleCtrl(ch, ctrl, cond);
        ltpAnalysisFilter(&lpc_in_pre, x, x_off - order, &ctrl.ltp_coef, &ctrl.pitch_l, &inv_gains, subfr_length, nb_subfr, order);
    } else {
        var x_pos = x_off - order;
        var pre: usize = 0;
        for (0..nb_subfr) |i| {
            flp.scaleCopyVector(lpc_in_pre[pre..][0 .. subfr_length + order], x[x_pos..][0 .. subfr_length + order], inv_gains[i]);
            pre += subfr_length + order;
            x_pos += subfr_length;
        }
        @memset(ctrl.ltp_coef[0 .. nb_subfr * ltp_order], 0);
        ctrl.ltp_pred_cod_gain = 0.0;
        ch.sum_log_gain_q7 = 0;
    }

    var min_inv_gain: f32 = undefined;
    if (ch.first_frame_after_reset) {
        min_inv_gain = 1.0 / 1e2;
    } else {
        min_inv_gain = @floatCast(std.math.pow(f64, 2, ctrl.ltp_pred_cod_gain / 3));
        min_inv_gain = min_inv_gain / 1e4;
        min_inv_gain /= 0.25 + 0.75 * ctrl.coding_quality;
    }
    findLpc(ch, &nlsf_q15, lpc_in_pre[0 .. nb_subfr * (subfr_length + order)], min_inv_gain);

    var pred_q12: [2][max_order]i16 = undefined;
    nlsf_enc.processNlsfs(ch, &pred_q12, &nlsf_q15, &ch.prev_nlsfq_q15);
    for (0..2) |j| {
        for (0..order) |i| ctrl.pred_coef[j][i] = @as(f32, @floatFromInt(pred_q12[j][i])) * (1.0 / 4096.0);
    }
    residualEnergy(&ctrl.res_nrg, &lpc_in_pre, &ctrl.pred_coef, &ctrl.gains, subfr_length, nb_subfr, order);
    ch.prev_nlsfq_q15 = nlsf_q15;
}
