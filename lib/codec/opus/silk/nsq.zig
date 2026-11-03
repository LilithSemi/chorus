//! Noise shaping quantizers of the SILK encoder, ported from libopus silk/NSQ.c and
//! silk/NSQ_del_dec.c. libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const m = @import("macros.zig");
const tables = @import("tables.zig");
const lpc = @import("lpc.zig");
const st = @import("enc_state.zig");

const ltp_order = st.ltp_order;
const max_lpc = st.max_lpc_order;
const shape_order = st.max_shape_lpc_order;
const lpc_buf = st.nsq_lpc_buf_length;
const decision_delay = st.decision_delay;
const quant_level_adjust_q10 = 80;

/// The parameters of the frame that the quantizers need.
pub const Params = struct {
    ltp_mem_length: i32,
    frame_length: i32,
    subfr_length: i32,
    nb_subfr: i32,
    predict_lpc_order: i32,
    shaping_lpc_order: i32,
    n_states_delayed_decision: i32,
    warping_q16: i32,
};

/// The values that the encoder analysis passes to the quantizer.
pub const Input = struct {
    x16: []const i16,
    /// The prediction filters of the two frame halves, 16 values each.
    pred_coef_q12: *const [2][max_lpc]i16,
    ltp_coef_q14: []const i16,
    ar_q13: []const i16,
    harm_shape_gain_q14: []const i32,
    tilt_q14: []const i32,
    lf_shp_q14: []const i32,
    gains_q16: []const i32,
    pitch_l: []const i32,
    lambda_q10: i32,
    ltp_scale_q14: i32,
};

const DelDecState = struct {
    slpc_q14: [st.max_sub_frame_length + lpc_buf]i32,
    rand_state: [decision_delay]i32,
    q_q10: [decision_delay]i32,
    xq_q14: [decision_delay]i32,
    pred_q15: [decision_delay]i32,
    shape_q14: [decision_delay]i32,
    sar2_q14: [shape_order]i32,
    lf_ar_q14: i32,
    diff_q14: i32,
    seed: i32,
    seed_init: i32,
    rd_q10: i32,
};

const SampleState = struct {
    q_q10: i32,
    rd_q10: i32,
    xq_q14: i32,
    lf_ar_q14: i32,
    diff_q14: i32,
    sltp_shp_q14: i32,
    lpc_exc_q14: i32,
};

/// Buffers of the quantizers. They live in the encoder so that a call needs little stack.
pub const Scratch = struct {
    sltp_q15: [2 * st.max_frame_length]i32,
    sltp: [2 * st.max_frame_length]i16,
    x_sc_q10: [st.max_sub_frame_length]i32,
    del_dec: [st.max_del_dec_states]DelDecState,
    sample_state: [st.max_del_dec_states][2]SampleState,
    delayed_gain_q10: [decision_delay]i32,
};

fn shortPrediction(buf: []const i32, pos: usize, coef: []const i16, order: usize) i32 {
    var out: i32 = @intCast(order >> 1);
    for (0..order) |j| out = m.smlawb(out, buf[pos - j], coef[j]);
    return out;
}

fn noiseShapeFeedback(data0: i32, data1: *[shape_order]i32, coef: []const i16, order: usize) i32 {
    var tmp2 = data0;
    var tmp1 = data1[0];
    data1[0] = tmp2;
    var out: i32 = @intCast(order >> 1);
    out = m.smlawb(out, tmp2, coef[0]);
    var j: usize = 2;
    while (j < order) : (j += 2) {
        tmp2 = data1[j - 1];
        data1[j - 1] = tmp1;
        out = m.smlawb(out, tmp1, coef[j - 1]);
        tmp1 = data1[j];
        data1[j] = tmp2;
        out = m.smlawb(out, tmp2, coef[j]);
    }
    data1[order - 1] = tmp1;
    out = m.smlawb(out, tmp1, coef[order - 1]);
    return out << 1;
}

fn pidx(base: i32, delta: i32) usize {
    return @intCast(base + delta);
}

fn scaleStates(p: Params, nsq: *st.NsqState, sc: *Scratch, x16: []const i16, subfr: usize, ltp_scale_q14: i32, gains_q16: []const i32, pitch_l: []const i32, signal_type: i32) void {
    const lag = pitch_l[subfr];
    var inv_gain_q31 = m.inverse32VarQ(@max(gains_q16[subfr], 1), 47);
    const inv_gain_q26 = m.rshiftRound(inv_gain_q31, 5);
    const subfr_length: usize = @intCast(p.subfr_length);
    for (0..subfr_length) |i| sc.x_sc_q10[i] = m.smulww(x16[i], inv_gain_q26);
    if (nsq.rewhite_flag != 0) {
        if (subfr == 0) inv_gain_q31 = m.smulwb(inv_gain_q31, ltp_scale_q14) << 2;
        var i = nsq.sltp_buf_idx - lag - ltp_order / 2;
        while (i < nsq.sltp_buf_idx) : (i += 1) {
            sc.sltp_q15[@intCast(i)] = m.smulwb(inv_gain_q31, sc.sltp[@intCast(i)]);
        }
    }
    if (gains_q16[subfr] != nsq.prev_gain_q16) {
        const gain_adj_q16 = m.div32VarQ(nsq.prev_gain_q16, gains_q16[subfr], 16);
        var i = nsq.sltp_shp_buf_idx - p.ltp_mem_length;
        while (i < nsq.sltp_shp_buf_idx) : (i += 1) {
            nsq.sltp_shp_q14[@intCast(i)] = m.smulww(gain_adj_q16, nsq.sltp_shp_q14[@intCast(i)]);
        }
        if (signal_type == st.type_voiced and nsq.rewhite_flag == 0) {
            i = nsq.sltp_buf_idx - lag - ltp_order / 2;
            while (i < nsq.sltp_buf_idx) : (i += 1) {
                sc.sltp_q15[@intCast(i)] = m.smulww(gain_adj_q16, sc.sltp_q15[@intCast(i)]);
            }
        }
        nsq.slf_ar_shp_q14 = m.smulww(gain_adj_q16, nsq.slf_ar_shp_q14);
        nsq.sdiff_shp_q14 = m.smulww(gain_adj_q16, nsq.sdiff_shp_q14);
        for (&nsq.slpc_q14[0..lpc_buf].*, 0..) |v, k| nsq.slpc_q14[k] = m.smulww(gain_adj_q16, v);
        for (&nsq.sar2_q14, 0..) |v, k| nsq.sar2_q14[k] = m.smulww(gain_adj_q16, v);
        nsq.prev_gain_q16 = gains_q16[subfr];
    }
}

fn quantizer(
    p: Params,
    nsq: *st.NsqState,
    signal_type: i32,
    x_sc_q10: []const i32,
    pulses: []i8,
    xq_base: usize,
    sltp_q15: []i32,
    a_q12: []const i16,
    b_q14: []const i16,
    ar_shp_q13: []const i16,
    lag: i32,
    harm_shape_fir_packed_q14: i32,
    tilt_q14: i32,
    lf_shp_q14: i32,
    gain_q16: i32,
    lambda_q10: i32,
    offset_q10: i32,
) void {
    const length: usize = @intCast(p.subfr_length);
    const predict_order: usize = @intCast(p.predict_lpc_order);
    const shaping_order: usize = @intCast(p.shaping_lpc_order);
    var shp_lag_idx: i32 = nsq.sltp_shp_buf_idx - lag + 1;
    var pred_lag_idx: i32 = nsq.sltp_buf_idx - lag + ltp_order / 2;
    const gain_q10 = gain_q16 >> 6;
    var lpc_idx: usize = lpc_buf - 1;
    for (0..length) |i| {
        nsq.rand_seed = m.rand(nsq.rand_seed);
        const lpc_pred_q10 = shortPrediction(&nsq.slpc_q14, lpc_idx, a_q12, predict_order);
        var ltp_pred_q13: i32 = 0;
        if (signal_type == st.type_voiced) {
            ltp_pred_q13 = 2;
            for (0..ltp_order) |j| {
                ltp_pred_q13 = m.smlawb(ltp_pred_q13, sltp_q15[pidx(pred_lag_idx, -@as(i32, @intCast(j)))], b_q14[j]);
            }
            pred_lag_idx += 1;
        }
        var n_ar_q12 = noiseShapeFeedback(nsq.sdiff_shp_q14, &nsq.sar2_q14, ar_shp_q13, shaping_order);
        n_ar_q12 = m.smlawb(n_ar_q12, nsq.slf_ar_shp_q14, tilt_q14);
        var n_lf_q12 = m.smulwb(nsq.sltp_shp_q14[pidx(nsq.sltp_shp_buf_idx, -1)], lf_shp_q14);
        n_lf_q12 = m.smlawt(n_lf_q12, nsq.slf_ar_shp_q14, lf_shp_q14);

        var tmp1 = (lpc_pred_q10 << 2) -% n_ar_q12;
        tmp1 = tmp1 -% n_lf_q12;
        if (lag > 0) {
            const s0 = nsq.sltp_shp_q14[pidx(shp_lag_idx, 0)];
            const s1 = nsq.sltp_shp_q14[pidx(shp_lag_idx, -1)];
            const s2 = nsq.sltp_shp_q14[pidx(shp_lag_idx, -2)];
            var n_ltp_q13 = m.smulwb(m.addSat32(s0, s2), harm_shape_fir_packed_q14);
            n_ltp_q13 = m.smlawt(n_ltp_q13, s1, harm_shape_fir_packed_q14);
            n_ltp_q13 = n_ltp_q13 << 1;
            shp_lag_idx += 1;
            const tmp2 = ltp_pred_q13 - n_ltp_q13;
            tmp1 = tmp2 +% (tmp1 << 1);
            tmp1 = m.rshiftRound(tmp1, 3);
        } else {
            tmp1 = m.rshiftRound(tmp1, 2);
        }
        var r_q10 = x_sc_q10[i] - tmp1;
        if (nsq.rand_seed < 0) r_q10 = -r_q10;
        r_q10 = std.math.clamp(r_q10, -(31 << 10), 30 << 10);

        var q1_q10 = r_q10 - offset_q10;
        var q1_q0 = q1_q10 >> 10;
        if (lambda_q10 > 2048) {
            const rdo_offset = @divTrunc(lambda_q10, 2) - 512;
            if (q1_q10 > rdo_offset) {
                q1_q0 = (q1_q10 - rdo_offset) >> 10;
            } else if (q1_q10 < -rdo_offset) {
                q1_q0 = (q1_q10 + rdo_offset) >> 10;
            } else if (q1_q10 < 0) {
                q1_q0 = -1;
            } else {
                q1_q0 = 0;
            }
        }
        var q2_q10: i32 = undefined;
        var rd1_q20: i32 = undefined;
        var rd2_q20: i32 = undefined;
        if (q1_q0 > 0) {
            q1_q10 = (q1_q0 << 10) - quant_level_adjust_q10;
            q1_q10 += offset_q10;
            q2_q10 = q1_q10 + 1024;
            rd1_q20 = m.smulbb(q1_q10, lambda_q10);
            rd2_q20 = m.smulbb(q2_q10, lambda_q10);
        } else if (q1_q0 == 0) {
            q1_q10 = offset_q10;
            q2_q10 = q1_q10 + (1024 - quant_level_adjust_q10);
            rd1_q20 = m.smulbb(q1_q10, lambda_q10);
            rd2_q20 = m.smulbb(q2_q10, lambda_q10);
        } else if (q1_q0 == -1) {
            q2_q10 = offset_q10;
            q1_q10 = q2_q10 - (1024 - quant_level_adjust_q10);
            rd1_q20 = m.smulbb(-q1_q10, lambda_q10);
            rd2_q20 = m.smulbb(q2_q10, lambda_q10);
        } else {
            q1_q10 = (q1_q0 << 10) + quant_level_adjust_q10;
            q1_q10 += offset_q10;
            q2_q10 = q1_q10 + 1024;
            rd1_q20 = m.smulbb(-q1_q10, lambda_q10);
            rd2_q20 = m.smulbb(-q2_q10, lambda_q10);
        }
        var rr_q10 = r_q10 - q1_q10;
        rd1_q20 = m.smlabb(rd1_q20, rr_q10, rr_q10);
        rr_q10 = r_q10 - q2_q10;
        rd2_q20 = m.smlabb(rd2_q20, rr_q10, rr_q10);
        if (rd2_q20 < rd1_q20) q1_q10 = q2_q10;

        pulses[i] = @truncate(m.rshiftRound(q1_q10, 10));
        var exc_q14 = q1_q10 << 4;
        if (nsq.rand_seed < 0) exc_q14 = -exc_q14;
        const lpc_exc_q14 = exc_q14 + (ltp_pred_q13 << 1);
        const xq_q14 = lpc_exc_q14 +% (lpc_pred_q10 << 4);
        nsq.xq[xq_base + i] = @intCast(m.sat16(m.rshiftRound(m.smulww(xq_q14, gain_q10), 8)));

        lpc_idx += 1;
        nsq.slpc_q14[lpc_idx] = xq_q14;
        nsq.sdiff_shp_q14 = xq_q14 -% (x_sc_q10[i] << 4);
        const slf_ar_shp_q14 = nsq.sdiff_shp_q14 -% (n_ar_q12 << 2);
        nsq.slf_ar_shp_q14 = slf_ar_shp_q14;
        nsq.sltp_shp_q14[@intCast(nsq.sltp_shp_buf_idx)] = slf_ar_shp_q14 -% (n_lf_q12 << 2);
        sltp_q15[@intCast(nsq.sltp_buf_idx)] = lpc_exc_q14 << 1;
        nsq.sltp_shp_buf_idx += 1;
        nsq.sltp_buf_idx += 1;
        nsq.rand_seed +%= pulses[i];
    }
    std.mem.copyForwards(i32, nsq.slpc_q14[0..lpc_buf], nsq.slpc_q14[length..][0..lpc_buf]);
}

/// Noise shaping quantizer with a single state.
pub fn nsqSingle(p: Params, sc: *Scratch, nsq: *st.NsqState, indices: *st.Indices, in: Input, pulses_all: []i8) void {
    nsq.rand_seed = indices.seed;
    var lag = nsq.lag_prev;
    const offset_q10: i32 = tables.quantization_offsets_q10[@as(usize, @intCast(indices.signal_type >> 1)) * 2 + @as(usize, @intCast(indices.quant_offset_type))];
    const lsf_interpolation_flag: u32 = if (indices.nlsf_interp_coef_q2 == 4) 0 else 1;
    nsq.sltp_shp_buf_idx = p.ltp_mem_length;
    nsq.sltp_buf_idx = p.ltp_mem_length;
    const ltp_mem: usize = @intCast(p.ltp_mem_length);
    const subfr_length: usize = @intCast(p.subfr_length);
    const order: usize = @intCast(p.predict_lpc_order);
    var pxq_pos = ltp_mem;
    var x_pos: usize = 0;
    for (0..@as(usize, @intCast(p.nb_subfr))) |k| {
        const a_q12 = &in.pred_coef_q12[(k >> 1) | (1 - lsf_interpolation_flag)];
        const b_q14 = in.ltp_coef_q14[k * ltp_order ..][0..ltp_order];
        const ar_shp_q13 = in.ar_q13[k * shape_order ..][0..shape_order];
        const harm = in.harm_shape_gain_q14[k];
        const harm_packed: i32 = (harm >> 2) | ((harm >> 1) << 16);
        nsq.rewhite_flag = 0;
        if (indices.signal_type == st.type_voiced) {
            lag = in.pitch_l[k];
            if ((k & (3 - (lsf_interpolation_flag << 1))) == 0) {
                const start_idx: usize = @intCast(p.ltp_mem_length - lag - p.predict_lpc_order - ltp_order / 2);
                lpc.analysisFilter(sc.sltp[start_idx..][0 .. ltp_mem - start_idx], nsq.xq[start_idx + k * subfr_length ..], a_q12[0..order]);
                nsq.rewhite_flag = 1;
                nsq.sltp_buf_idx = p.ltp_mem_length;
            }
        }
        scaleStates(p, nsq, sc, in.x16[x_pos..], k, in.ltp_scale_q14, in.gains_q16, in.pitch_l, indices.signal_type);
        quantizer(p, nsq, indices.signal_type, &sc.x_sc_q10, pulses_all[x_pos..], pxq_pos, &sc.sltp_q15, a_q12, b_q14, ar_shp_q13, lag, harm_packed, in.tilt_q14[k], in.lf_shp_q14[k], in.gains_q16[k], in.lambda_q10, offset_q10);
        x_pos += subfr_length;
        pxq_pos += subfr_length;
    }
    nsq.lag_prev = in.pitch_l[@as(usize, @intCast(p.nb_subfr)) - 1];
    const frame_length: usize = @intCast(p.frame_length);
    std.mem.copyForwards(i16, nsq.xq[0..ltp_mem], nsq.xq[frame_length..][0..ltp_mem]);
    std.mem.copyForwards(i32, nsq.sltp_shp_q14[0..ltp_mem], nsq.sltp_shp_q14[frame_length..][0..ltp_mem]);
}

fn scaleStatesDelDec(p: Params, nsq: *st.NsqState, sc: *Scratch, x16: []const i16, subfr: usize, n_states: usize, ltp_scale_q14: i32, gains_q16: []const i32, pitch_l: []const i32, signal_type: i32, delay: i32) void {
    const lag = pitch_l[subfr];
    var inv_gain_q31 = m.inverse32VarQ(@max(gains_q16[subfr], 1), 47);
    const inv_gain_q26 = m.rshiftRound(inv_gain_q31, 5);
    const subfr_length: usize = @intCast(p.subfr_length);
    for (0..subfr_length) |i| sc.x_sc_q10[i] = m.smulww(x16[i], inv_gain_q26);
    if (nsq.rewhite_flag != 0) {
        if (subfr == 0) inv_gain_q31 = m.smulwb(inv_gain_q31, ltp_scale_q14) << 2;
        var i = nsq.sltp_buf_idx - lag - ltp_order / 2;
        while (i < nsq.sltp_buf_idx) : (i += 1) {
            sc.sltp_q15[@intCast(i)] = m.smulwb(inv_gain_q31, sc.sltp[@intCast(i)]);
        }
    }
    if (gains_q16[subfr] != nsq.prev_gain_q16) {
        const gain_adj_q16 = m.div32VarQ(nsq.prev_gain_q16, gains_q16[subfr], 16);
        var i = nsq.sltp_shp_buf_idx - p.ltp_mem_length;
        while (i < nsq.sltp_shp_buf_idx) : (i += 1) {
            nsq.sltp_shp_q14[@intCast(i)] = m.smulww(gain_adj_q16, nsq.sltp_shp_q14[@intCast(i)]);
        }
        if (signal_type == st.type_voiced and nsq.rewhite_flag == 0) {
            i = nsq.sltp_buf_idx - lag - ltp_order / 2;
            while (i < nsq.sltp_buf_idx - delay) : (i += 1) {
                sc.sltp_q15[@intCast(i)] = m.smulww(gain_adj_q16, sc.sltp_q15[@intCast(i)]);
            }
        }
        for (0..n_states) |k| {
            const dd = &sc.del_dec[k];
            dd.lf_ar_q14 = m.smulww(gain_adj_q16, dd.lf_ar_q14);
            dd.diff_q14 = m.smulww(gain_adj_q16, dd.diff_q14);
            for (0..lpc_buf) |j| dd.slpc_q14[j] = m.smulww(gain_adj_q16, dd.slpc_q14[j]);
            for (0..shape_order) |j| dd.sar2_q14[j] = m.smulww(gain_adj_q16, dd.sar2_q14[j]);
            for (0..decision_delay) |j| {
                dd.pred_q15[j] = m.smulww(gain_adj_q16, dd.pred_q15[j]);
                dd.shape_q14[j] = m.smulww(gain_adj_q16, dd.shape_q14[j]);
            }
        }
        nsq.prev_gain_q16 = gains_q16[subfr];
    }
}

fn quantizerDelDec(
    p: Params,
    nsq: *st.NsqState,
    sc: *Scratch,
    signal_type: i32,
    pulses_all: []i8,
    pulse_base: usize,
    xq_base: usize,
    a_q12: []const i16,
    b_q14: []const i16,
    ar_shp_q13: []const i16,
    lag: i32,
    harm_shape_fir_packed_q14: i32,
    tilt_q14: i32,
    lf_shp_q14: i32,
    gain_q16: i32,
    lambda_q10: i32,
    offset_q10: i32,
    subfr: usize,
    smpl_buf_idx: *i32,
    delay: i32,
) void {
    const length: usize = @intCast(p.subfr_length);
    const predict_order: usize = @intCast(p.predict_lpc_order);
    const shaping_order: usize = @intCast(p.shaping_lpc_order);
    const n_states: usize = @intCast(p.n_states_delayed_decision);
    const warping_q16 = p.warping_q16;
    var shp_lag_idx: i32 = nsq.sltp_shp_buf_idx - lag + 1;
    var pred_lag_idx: i32 = nsq.sltp_buf_idx - lag + ltp_order / 2;
    const gain_q10 = gain_q16 >> 6;
    const del: i32 = delay;
    for (0..length) |i| {
        var ltp_pred_q14: i32 = 0;
        if (signal_type == st.type_voiced) {
            ltp_pred_q14 = 2;
            for (0..ltp_order) |j| {
                ltp_pred_q14 = m.smlawb(ltp_pred_q14, sc.sltp_q15[pidx(pred_lag_idx, -@as(i32, @intCast(j)))], b_q14[j]);
            }
            ltp_pred_q14 = ltp_pred_q14 << 1;
            pred_lag_idx += 1;
        }
        var n_ltp_q14: i32 = 0;
        if (lag > 0) {
            const s0 = nsq.sltp_shp_q14[pidx(shp_lag_idx, 0)];
            const s1 = nsq.sltp_shp_q14[pidx(shp_lag_idx, -1)];
            const s2 = nsq.sltp_shp_q14[pidx(shp_lag_idx, -2)];
            n_ltp_q14 = m.smulwb(m.addSat32(s0, s2), harm_shape_fir_packed_q14);
            n_ltp_q14 = m.smlawt(n_ltp_q14, s1, harm_shape_fir_packed_q14);
            n_ltp_q14 = ltp_pred_q14 - (n_ltp_q14 << 2);
            shp_lag_idx += 1;
        }
        for (0..n_states) |k| {
            const dd = &sc.del_dec[k];
            const ss = &sc.sample_state[k];
            dd.seed = m.rand(dd.seed);
            const lpc_idx = lpc_buf - 1 + i;
            var lpc_pred_q14 = shortPrediction(&dd.slpc_q14, lpc_idx, a_q12, predict_order);
            lpc_pred_q14 = lpc_pred_q14 << 4;

            var tmp2 = m.smlawb(dd.diff_q14, dd.sar2_q14[0], warping_q16);
            var tmp1 = m.smlawb(dd.sar2_q14[0], dd.sar2_q14[1] -% tmp2, warping_q16);
            dd.sar2_q14[0] = tmp2;
            var n_ar_q14: i32 = @intCast(shaping_order >> 1);
            n_ar_q14 = m.smlawb(n_ar_q14, tmp2, ar_shp_q13[0]);
            var j: usize = 2;
            while (j < shaping_order) : (j += 2) {
                tmp2 = m.smlawb(dd.sar2_q14[j - 1], dd.sar2_q14[j] -% tmp1, warping_q16);
                dd.sar2_q14[j - 1] = tmp1;
                n_ar_q14 = m.smlawb(n_ar_q14, tmp1, ar_shp_q13[j - 1]);
                tmp1 = m.smlawb(dd.sar2_q14[j], dd.sar2_q14[j + 1] -% tmp2, warping_q16);
                dd.sar2_q14[j] = tmp2;
                n_ar_q14 = m.smlawb(n_ar_q14, tmp2, ar_shp_q13[j]);
            }
            dd.sar2_q14[shaping_order - 1] = tmp1;
            n_ar_q14 = m.smlawb(n_ar_q14, tmp1, ar_shp_q13[shaping_order - 1]);
            n_ar_q14 = n_ar_q14 << 1;
            n_ar_q14 = m.smlawb(n_ar_q14, dd.lf_ar_q14, tilt_q14);
            n_ar_q14 = n_ar_q14 << 2;

            var n_lf_q14 = m.smulwb(dd.shape_q14[@intCast(smpl_buf_idx.*)], lf_shp_q14);
            n_lf_q14 = m.smlawt(n_lf_q14, dd.lf_ar_q14, lf_shp_q14);
            n_lf_q14 = n_lf_q14 << 2;

            tmp1 = m.addSat32(n_ar_q14, n_lf_q14);
            tmp2 = n_ltp_q14 +% lpc_pred_q14;
            tmp1 = m.subSat32(tmp2, tmp1);
            tmp1 = m.rshiftRound(tmp1, 4);
            var r_q10 = sc.x_sc_q10[i] - tmp1;
            if (dd.seed < 0) r_q10 = -r_q10;
            r_q10 = std.math.clamp(r_q10, -(31 << 10), 30 << 10);

            var q1_q10 = r_q10 - offset_q10;
            var q1_q0 = q1_q10 >> 10;
            if (lambda_q10 > 2048) {
                const rdo_offset = @divTrunc(lambda_q10, 2) - 512;
                if (q1_q10 > rdo_offset) {
                    q1_q0 = (q1_q10 - rdo_offset) >> 10;
                } else if (q1_q10 < -rdo_offset) {
                    q1_q0 = (q1_q10 + rdo_offset) >> 10;
                } else if (q1_q10 < 0) {
                    q1_q0 = -1;
                } else {
                    q1_q0 = 0;
                }
            }
            var q2_q10: i32 = undefined;
            var rd1_q10: i32 = undefined;
            var rd2_q10: i32 = undefined;
            if (q1_q0 > 0) {
                q1_q10 = (q1_q0 << 10) - quant_level_adjust_q10;
                q1_q10 += offset_q10;
                q2_q10 = q1_q10 + 1024;
                rd1_q10 = m.smulbb(q1_q10, lambda_q10);
                rd2_q10 = m.smulbb(q2_q10, lambda_q10);
            } else if (q1_q0 == 0) {
                q1_q10 = offset_q10;
                q2_q10 = q1_q10 + (1024 - quant_level_adjust_q10);
                rd1_q10 = m.smulbb(q1_q10, lambda_q10);
                rd2_q10 = m.smulbb(q2_q10, lambda_q10);
            } else if (q1_q0 == -1) {
                q2_q10 = offset_q10;
                q1_q10 = q2_q10 - (1024 - quant_level_adjust_q10);
                rd1_q10 = m.smulbb(-q1_q10, lambda_q10);
                rd2_q10 = m.smulbb(q2_q10, lambda_q10);
            } else {
                q1_q10 = (q1_q0 << 10) + quant_level_adjust_q10;
                q1_q10 += offset_q10;
                q2_q10 = q1_q10 + 1024;
                rd1_q10 = m.smulbb(-q1_q10, lambda_q10);
                rd2_q10 = m.smulbb(-q2_q10, lambda_q10);
            }
            var rr_q10 = r_q10 - q1_q10;
            rd1_q10 = m.smlabb(rd1_q10, rr_q10, rr_q10) >> 10;
            rr_q10 = r_q10 - q2_q10;
            rd2_q10 = m.smlabb(rd2_q10, rr_q10, rr_q10) >> 10;
            if (rd1_q10 < rd2_q10) {
                ss[0].rd_q10 = dd.rd_q10 +% rd1_q10;
                ss[1].rd_q10 = dd.rd_q10 +% rd2_q10;
                ss[0].q_q10 = q1_q10;
                ss[1].q_q10 = q2_q10;
            } else {
                ss[0].rd_q10 = dd.rd_q10 +% rd2_q10;
                ss[1].rd_q10 = dd.rd_q10 +% rd1_q10;
                ss[0].q_q10 = q2_q10;
                ss[1].q_q10 = q1_q10;
            }

            inline for (0..2) |w| {
                var exc_q14 = ss[w].q_q10 << 4;
                if (dd.seed < 0) exc_q14 = -exc_q14;
                const lpc_exc_q14 = exc_q14 + ltp_pred_q14;
                const xq_q14 = lpc_exc_q14 +% lpc_pred_q14;
                ss[w].diff_q14 = xq_q14 -% (sc.x_sc_q10[i] << 4);
                const slf_ar_shp_q14 = ss[w].diff_q14 -% n_ar_q14;
                ss[w].sltp_shp_q14 = m.subSat32(slf_ar_shp_q14, n_lf_q14);
                ss[w].lf_ar_q14 = slf_ar_shp_q14;
                ss[w].lpc_exc_q14 = lpc_exc_q14;
                ss[w].xq_q14 = xq_q14;
            }
        }
        smpl_buf_idx.* = @mod(smpl_buf_idx.* - 1, decision_delay);
        const last_smple_idx: usize = @intCast(@mod(smpl_buf_idx.* + del, decision_delay));

        var rd_min_q10 = sc.sample_state[0][0].rd_q10;
        var winner_ind: usize = 0;
        for (1..n_states) |k| {
            if (sc.sample_state[k][0].rd_q10 < rd_min_q10) {
                rd_min_q10 = sc.sample_state[k][0].rd_q10;
                winner_ind = k;
            }
        }
        const winner_rand_state = sc.del_dec[winner_ind].rand_state[last_smple_idx];
        for (0..n_states) |k| {
            if (sc.del_dec[k].rand_state[last_smple_idx] != winner_rand_state) {
                sc.sample_state[k][0].rd_q10 +%= std.math.maxInt(i32) >> 4;
                sc.sample_state[k][1].rd_q10 +%= std.math.maxInt(i32) >> 4;
            }
        }
        var rd_max_q10 = sc.sample_state[0][0].rd_q10;
        rd_min_q10 = sc.sample_state[0][1].rd_q10;
        var rd_max_ind: usize = 0;
        var rd_min_ind: usize = 0;
        for (1..n_states) |k| {
            if (sc.sample_state[k][0].rd_q10 > rd_max_q10) {
                rd_max_q10 = sc.sample_state[k][0].rd_q10;
                rd_max_ind = k;
            }
            if (sc.sample_state[k][1].rd_q10 < rd_min_q10) {
                rd_min_q10 = sc.sample_state[k][1].rd_q10;
                rd_min_ind = k;
            }
        }
        if (rd_min_q10 < rd_max_q10) {
            sc.del_dec[rd_max_ind] = sc.del_dec[rd_min_ind];
            sc.sample_state[rd_max_ind][0] = sc.sample_state[rd_min_ind][1];
        }

        const wd = &sc.del_dec[winner_ind];
        if (subfr > 0 or @as(i32, @intCast(i)) >= del) {
            const rel: i32 = @as(i32, @intCast(i)) - del;
            pulses_all[pidx(@intCast(pulse_base), rel)] = @truncate(m.rshiftRound(wd.q_q10[last_smple_idx], 10));
            nsq.xq[pidx(@intCast(xq_base), rel)] = @intCast(m.sat16(m.rshiftRound(m.smulww(wd.xq_q14[last_smple_idx], sc.delayed_gain_q10[last_smple_idx]), 8)));
            nsq.sltp_shp_q14[pidx(nsq.sltp_shp_buf_idx, -del)] = wd.shape_q14[last_smple_idx];
            sc.sltp_q15[pidx(nsq.sltp_buf_idx, -del)] = wd.pred_q15[last_smple_idx];
        }
        nsq.sltp_shp_buf_idx += 1;
        nsq.sltp_buf_idx += 1;

        const idx: usize = @intCast(smpl_buf_idx.*);
        for (0..n_states) |k| {
            const dd = &sc.del_dec[k];
            const ss = &sc.sample_state[k][0];
            dd.lf_ar_q14 = ss.lf_ar_q14;
            dd.diff_q14 = ss.diff_q14;
            dd.slpc_q14[lpc_buf + i] = ss.xq_q14;
            dd.xq_q14[idx] = ss.xq_q14;
            dd.q_q10[idx] = ss.q_q10;
            dd.pred_q15[idx] = ss.lpc_exc_q14 << 1;
            dd.shape_q14[idx] = ss.sltp_shp_q14;
            dd.seed +%= m.rshiftRound(ss.q_q10, 10);
            dd.rand_state[idx] = dd.seed;
            dd.rd_q10 = ss.rd_q10;
        }
        sc.delayed_gain_q10[idx] = gain_q10;
    }
    for (0..n_states) |k| {
        const dd = &sc.del_dec[k];
        std.mem.copyForwards(i32, dd.slpc_q14[0..lpc_buf], dd.slpc_q14[length..][0..lpc_buf]);
    }
}
/// Noise shaping quantizer with delayed decision.
pub fn nsqDelDec(p: Params, sc: *Scratch, nsq: *st.NsqState, indices: *st.Indices, in: Input, pulses_all: []i8) void {
    var lag = nsq.lag_prev;
    const n_states: usize = @intCast(p.n_states_delayed_decision);
    const ltp_mem: usize = @intCast(p.ltp_mem_length);
    const subfr_length: usize = @intCast(p.subfr_length);
    const nb_subfr: usize = @intCast(p.nb_subfr);
    const order: usize = @intCast(p.predict_lpc_order);
    for (0..n_states) |k| {
        const dd = &sc.del_dec[k];
        dd.* = std.mem.zeroes(DelDecState);
        dd.seed = (@as(i32, @intCast(k)) + indices.seed) & 3;
        dd.seed_init = dd.seed;
        dd.rd_q10 = 0;
        dd.lf_ar_q14 = nsq.slf_ar_shp_q14;
        dd.diff_q14 = nsq.sdiff_shp_q14;
        dd.shape_q14[0] = nsq.sltp_shp_q14[ltp_mem - 1];
        @memcpy(dd.slpc_q14[0..lpc_buf], nsq.slpc_q14[0..lpc_buf]);
        dd.sar2_q14 = nsq.sar2_q14;
    }
    const offset_q10: i32 = tables.quantization_offsets_q10[@as(usize, @intCast(indices.signal_type >> 1)) * 2 + @as(usize, @intCast(indices.quant_offset_type))];
    var smpl_buf_idx: i32 = 0;
    var decision_delay_v: i32 = @min(decision_delay, p.subfr_length);
    if (indices.signal_type == st.type_voiced) {
        for (0..nb_subfr) |k| decision_delay_v = @min(decision_delay_v, in.pitch_l[k] - ltp_order / 2 - 1);
    } else if (lag > 0) {
        decision_delay_v = @min(decision_delay_v, lag - ltp_order / 2 - 1);
    }
    const lsf_interpolation_flag: u32 = if (indices.nlsf_interp_coef_q2 == 4) 0 else 1;
    var pxq_pos = ltp_mem;
    nsq.sltp_shp_buf_idx = p.ltp_mem_length;
    nsq.sltp_buf_idx = p.ltp_mem_length;
    var subfr: usize = 0;
    var x_pos: usize = 0;
    for (0..nb_subfr) |k| {
        const a_q12 = &in.pred_coef_q12[(k >> 1) | (1 - lsf_interpolation_flag)];
        const b_q14 = in.ltp_coef_q14[k * ltp_order ..][0..ltp_order];
        const ar_shp_q13 = in.ar_q13[k * shape_order ..][0..shape_order];
        const harm = in.harm_shape_gain_q14[k];
        const harm_packed: i32 = (harm >> 2) | ((harm >> 1) << 16);
        nsq.rewhite_flag = 0;
        if (indices.signal_type == st.type_voiced) {
            lag = in.pitch_l[k];
            if ((k & (3 - (lsf_interpolation_flag << 1))) == 0) {
                if (k == 2) {
                    var rd_min_q10 = sc.del_dec[0].rd_q10;
                    var winner_ind: usize = 0;
                    for (1..n_states) |i| {
                        if (sc.del_dec[i].rd_q10 < rd_min_q10) {
                            rd_min_q10 = sc.del_dec[i].rd_q10;
                            winner_ind = i;
                        }
                    }
                    for (0..n_states) |i| {
                        if (i != winner_ind) sc.del_dec[i].rd_q10 +%= std.math.maxInt(i32) >> 4;
                    }
                    const dd = &sc.del_dec[winner_ind];
                    var last_smple_idx: i32 = smpl_buf_idx + decision_delay_v;
                    for (0..@as(usize, @intCast(decision_delay_v))) |i| {
                        last_smple_idx = @mod(last_smple_idx - 1, decision_delay);
                        const li: usize = @intCast(last_smple_idx);
                        const rel: i32 = @as(i32, @intCast(i)) - decision_delay_v;
                        pulses_all[pidx(@intCast(x_pos), rel)] = @truncate(m.rshiftRound(dd.q_q10[li], 10));
                        nsq.xq[pidx(@intCast(pxq_pos), rel)] = @intCast(m.sat16(m.rshiftRound(m.smulww(dd.xq_q14[li], in.gains_q16[1]), 14)));
                        nsq.sltp_shp_q14[pidx(nsq.sltp_shp_buf_idx - decision_delay_v, @intCast(i))] = dd.shape_q14[li];
                    }
                    subfr = 0;
                }
                const start_idx: usize = @intCast(p.ltp_mem_length - lag - p.predict_lpc_order - ltp_order / 2);
                lpc.analysisFilter(sc.sltp[start_idx..][0 .. ltp_mem - start_idx], nsq.xq[start_idx + k * subfr_length ..], a_q12[0..order]);
                nsq.sltp_buf_idx = p.ltp_mem_length;
                nsq.rewhite_flag = 1;
            }
        }
        scaleStatesDelDec(p, nsq, sc, in.x16[x_pos..], k, n_states, in.ltp_scale_q14, in.gains_q16, in.pitch_l, indices.signal_type, decision_delay_v);
        quantizerDelDec(p, nsq, sc, indices.signal_type, pulses_all, x_pos, pxq_pos, a_q12, b_q14, ar_shp_q13, lag, harm_packed, in.tilt_q14[k], in.lf_shp_q14[k], in.gains_q16[k], in.lambda_q10, offset_q10, subfr, &smpl_buf_idx, decision_delay_v);
        subfr += 1;
        x_pos += subfr_length;
        pxq_pos += subfr_length;
    }

    var rd_min_q10 = sc.del_dec[0].rd_q10;
    var winner_ind: usize = 0;
    for (1..n_states) |k| {
        if (sc.del_dec[k].rd_q10 < rd_min_q10) {
            rd_min_q10 = sc.del_dec[k].rd_q10;
            winner_ind = k;
        }
    }
    const dd = &sc.del_dec[winner_ind];
    indices.seed = @intCast(dd.seed_init);
    var last_smple_idx: i32 = smpl_buf_idx + decision_delay_v;
    const gain_q10 = in.gains_q16[nb_subfr - 1] >> 6;
    for (0..@as(usize, @intCast(decision_delay_v))) |i| {
        last_smple_idx = @mod(last_smple_idx - 1, decision_delay);
        const li: usize = @intCast(last_smple_idx);
        const rel: i32 = @as(i32, @intCast(i)) - decision_delay_v;
        pulses_all[pidx(@intCast(x_pos), rel)] = @truncate(m.rshiftRound(dd.q_q10[li], 10));
        nsq.xq[pidx(@intCast(pxq_pos), rel)] = @intCast(m.sat16(m.rshiftRound(m.smulww(dd.xq_q14[li], gain_q10), 8)));
        nsq.sltp_shp_q14[pidx(nsq.sltp_shp_buf_idx - decision_delay_v, @intCast(i))] = dd.shape_q14[li];
    }
    @memcpy(nsq.slpc_q14[0..lpc_buf], dd.slpc_q14[subfr_length..][0..lpc_buf]);
    nsq.sar2_q14 = dd.sar2_q14;
    nsq.slf_ar_shp_q14 = dd.lf_ar_q14;
    nsq.sdiff_shp_q14 = dd.diff_q14;
    nsq.lag_prev = in.pitch_l[nb_subfr - 1];
    const frame_length: usize = @intCast(p.frame_length);
    std.mem.copyForwards(i16, nsq.xq[0..ltp_mem], nsq.xq[frame_length..][0..ltp_mem]);
    std.mem.copyForwards(i32, nsq.sltp_shp_q14[0..ltp_mem], nsq.sltp_shp_q14[frame_length..][0..ltp_mem]);
}
