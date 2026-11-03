//! Stereo prediction of the SILK encoder, ported from libopus silk/stereo_LR_to_MS.c,
//! stereo_find_predictor.c, stereo_quant_pred.c, stereo_encode_pred.c, sum_sqr_shift.c and
//! inner_prod_aligned.c. libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const m = @import("macros.zig");
const range = @import("../range.zig");
const tables = @import("tables.zig");
const st = @import("enc_state.zig");

const quant_tab_size = 16;
const quant_sub_steps = 5;
const interp_len_ms = 8;

/// Buffers of the stereo conversion. They live in the encoder so that a call needs little stack.
pub const Scratch = struct {
    side: [st.max_frame_length + 2]i16,
    lp_mid: [st.max_frame_length]i16,
    hp_mid: [st.max_frame_length]i16,
    lp_side: [st.max_frame_length]i16,
    hp_side: [st.max_frame_length]i16,
};

fn innerProdAlignedScale(a: []const i16, b: []const i16, scale: i32, len: usize) i32 {
    var sum: i32 = 0;
    for (0..len) |i| sum +%= m.smulbb(a[i], b[i]) >> @intCast(scale);
    return sum;
}

/// Least squares prediction of `y` from `x`, quantized later. Returns the predictor in Q13.
fn findPredictor(ratio_q14: *i32, x: []const i16, y: []const i16, mid_res_amp_q0: []i32, length: usize, smooth_coef_q16_in: i32) i32 {
    const rx = m.sumSqrShift(x[0..length]);
    const ry = m.sumSqrShift(y[0..length]);
    var nrgx = rx.energy;
    var nrgy = ry.energy;
    var scale = @max(rx.shift, ry.shift);
    scale = scale + (scale & 1);
    nrgy >>= @intCast(scale - ry.shift);
    nrgx >>= @intCast(scale - rx.shift);
    nrgx = @max(nrgx, 1);
    const corr = innerProdAlignedScale(x, y, scale, length);
    var pred_q13 = m.div32VarQ(corr, nrgx, 13);
    pred_q13 = m.limit(pred_q13, -(1 << 14), 1 << 14);
    const pred2_q10 = m.smulwb(pred_q13, pred_q13);

    const smooth_coef_q16 = @max(smooth_coef_q16_in, @as(i32, @intCast(@abs(pred2_q10))));
    scale >>= 1;
    mid_res_amp_q0[0] = m.smlawb(mid_res_amp_q0[0], (m.sqrtApprox(nrgx) << @intCast(scale)) - mid_res_amp_q0[0], smooth_coef_q16);
    nrgy = nrgy -% (m.smulwb(corr, pred_q13) << (3 + 1));
    nrgy = nrgy +% (m.smulwb(nrgx, pred2_q10) << 6);
    mid_res_amp_q0[1] = m.smlawb(mid_res_amp_q0[1], (m.sqrtApprox(nrgy) << @intCast(scale)) - mid_res_amp_q0[1], smooth_coef_q16);
    ratio_q14.* = m.div32VarQ(mid_res_amp_q0[1], @max(mid_res_amp_q0[0], 1), 14);
    ratio_q14.* = m.limit(ratio_q14.*, 0, 32767);
    return pred_q13;
}

/// Quantizes the predictors. The result of the quantizer replaces the values in `pred_q13`.
fn quantPred(pred_q13: *[2]i32, ix: *[2][3]i8) void {
    var quant_pred_q13: i32 = 0;
    for (0..2) |n| {
        var err_min_q13: i32 = std.math.maxInt(i32);
        search: for (0..quant_tab_size - 1) |i| {
            const low_q13: i32 = tables.stereo_pred_quant_q13[i];
            const step_q13 = m.smulwb(@as(i32, tables.stereo_pred_quant_q13[i + 1]) - low_q13, 6554);
            for (0..quant_sub_steps) |j| {
                const lvl_q13 = m.smlabb(low_q13, step_q13, @intCast(2 * j + 1));
                const err_q13: i32 = @intCast(@abs(pred_q13[n] - lvl_q13));
                if (err_q13 < err_min_q13) {
                    err_min_q13 = err_q13;
                    quant_pred_q13 = lvl_q13;
                    ix[n][0] = @intCast(i);
                    ix[n][1] = @intCast(j);
                } else {
                    break :search;
                }
            }
        }
        ix[n][2] = @intCast(@divTrunc(@as(i32, ix[n][0]), 3));
        ix[n][0] -= ix[n][2] * 3;
        pred_q13[n] = quant_pred_q13;
    }
    pred_q13[0] -= pred_q13[1];
}

/// Converts the left and right signal to an adaptive mid and side representation. `in1` and
/// `in2` hold the frame from index 2 on, with two older samples before it. The mid signal
/// ends in `in1` and the side residual in `in2`, both from index 1 on.
pub fn lrToMs(
    sc: *Scratch,
    state: *st.StereoEncState,
    in1: []i16,
    in2: []i16,
    ix: *[2][3]i8,
    mid_only_flag: *i8,
    mid_side_rates_bps: *[2]i32,
    total_rate_bps_in: i32,
    prev_speech_act_q8: i32,
    to_mono: bool,
    fs_khz: i32,
    frame_length: usize,
) void {
    var total_rate_bps = total_rate_bps_in;
    const mid = in1;
    const side = &sc.side;
    for (0..frame_length + 2) |n| {
        const sum: i32 = @as(i32, in1[n]) + in2[n];
        const diff: i32 = @as(i32, in1[n]) - in2[n];
        mid[n] = @truncate(m.rshiftRound(sum, 1));
        side[n] = @intCast(m.sat16(m.rshiftRound(diff, 1)));
    }
    mid[0..2].* = state.smid;
    side[0..2].* = state.sside;
    state.smid = mid[frame_length..][0..2].*;
    state.sside = side[frame_length..][0..2].*;

    for (0..frame_length) |n| {
        const sum = m.rshiftRound((@as(i32, mid[n]) + mid[n + 2]) +% (@as(i32, mid[n + 1]) << 1), 2);
        sc.lp_mid[n] = @truncate(sum);
        sc.hp_mid[n] = @truncate(@as(i32, mid[n + 1]) - sum);
    }
    for (0..frame_length) |n| {
        const sum = m.rshiftRound((@as(i32, side[n]) + side[n + 2]) +% (@as(i32, side[n + 1]) << 1), 2);
        sc.lp_side[n] = @truncate(sum);
        sc.hp_side[n] = @truncate(@as(i32, side[n + 1]) - sum);
    }

    const is_10ms_frame = frame_length == @as(usize, @intCast(10 * fs_khz));
    var smooth_coef_q16: i32 = if (is_10ms_frame) 328 else 655;
    smooth_coef_q16 = m.smulwb(m.smulbb(prev_speech_act_q8, prev_speech_act_q8), smooth_coef_q16);
    var lp_ratio_q14: i32 = undefined;
    var hp_ratio_q14: i32 = undefined;
    var pred_q13: [2]i32 = undefined;
    pred_q13[0] = findPredictor(&lp_ratio_q14, &sc.lp_mid, &sc.lp_side, state.mid_side_amp_q0[0..2], frame_length, smooth_coef_q16);
    pred_q13[1] = findPredictor(&hp_ratio_q14, &sc.hp_mid, &sc.hp_side, state.mid_side_amp_q0[2..4], frame_length, smooth_coef_q16);

    var frac_q16 = m.smlabb(hp_ratio_q14, lp_ratio_q14, 3);
    frac_q16 = @min(frac_q16, 1 << 16);

    total_rate_bps -= if (is_10ms_frame) 1200 else 600;
    if (total_rate_bps < 1) total_rate_bps = 1;
    const min_mid_rate_bps = m.smlabb(2000, fs_khz, 600);
    const frac_3_q16 = 3 * frac_q16;
    mid_side_rates_bps[0] = m.div32VarQ(total_rate_bps, ((8 + 5) << 16) + frac_3_q16, 16 + 3);
    var width_q14: i32 = undefined;
    if (mid_side_rates_bps[0] < min_mid_rate_bps) {
        mid_side_rates_bps[0] = min_mid_rate_bps;
        mid_side_rates_bps[1] = total_rate_bps - mid_side_rates_bps[0];
        width_q14 = m.div32VarQ((mid_side_rates_bps[1] << 1) - min_mid_rate_bps, m.smulwb((1 << 16) + frac_3_q16, min_mid_rate_bps), 14 + 2);
        width_q14 = m.limit(width_q14, 0, 1 << 14);
    } else {
        mid_side_rates_bps[1] = total_rate_bps - mid_side_rates_bps[0];
        width_q14 = 1 << 14;
    }

    state.smth_width_q14 = @truncate(m.smlawb(state.smth_width_q14, width_q14 - state.smth_width_q14, smooth_coef_q16));

    mid_only_flag.* = 0;
    if (to_mono) {
        width_q14 = 0;
        pred_q13 = .{ 0, 0 };
        quantPred(&pred_q13, ix);
    } else if (state.width_prev_q14 == 0 and
        (8 * total_rate_bps < 13 * min_mid_rate_bps or m.smulwb(frac_q16, state.smth_width_q14) < 819))
    {
        pred_q13[0] = m.smulbb(state.smth_width_q14, pred_q13[0]) >> 14;
        pred_q13[1] = m.smulbb(state.smth_width_q14, pred_q13[1]) >> 14;
        quantPred(&pred_q13, ix);
        width_q14 = 0;
        pred_q13 = .{ 0, 0 };
        mid_side_rates_bps[0] = total_rate_bps;
        mid_side_rates_bps[1] = 0;
        mid_only_flag.* = 1;
    } else if (state.width_prev_q14 != 0 and
        (8 * total_rate_bps < 11 * min_mid_rate_bps or m.smulwb(frac_q16, state.smth_width_q14) < 328))
    {
        pred_q13[0] = m.smulbb(state.smth_width_q14, pred_q13[0]) >> 14;
        pred_q13[1] = m.smulbb(state.smth_width_q14, pred_q13[1]) >> 14;
        quantPred(&pred_q13, ix);
        width_q14 = 0;
        pred_q13 = .{ 0, 0 };
    } else if (state.smth_width_q14 > 15565) {
        quantPred(&pred_q13, ix);
        width_q14 = 1 << 14;
    } else {
        pred_q13[0] = m.smulbb(state.smth_width_q14, pred_q13[0]) >> 14;
        pred_q13[1] = m.smulbb(state.smth_width_q14, pred_q13[1]) >> 14;
        quantPred(&pred_q13, ix);
        width_q14 = state.smth_width_q14;
    }

    if (mid_only_flag.* == 1) {
        state.silent_side_len +%= @as(i16, @truncate(@as(i32, @intCast(frame_length)) - interp_len_ms * fs_khz));
        if (state.silent_side_len < st.la_shape_ms * fs_khz) {
            mid_only_flag.* = 0;
        } else {
            state.silent_side_len = 10000;
        }
    } else {
        state.silent_side_len = 0;
    }

    if (mid_only_flag.* == 0 and mid_side_rates_bps[1] < 1) {
        mid_side_rates_bps[1] = 1;
        mid_side_rates_bps[0] = @max(1, total_rate_bps - mid_side_rates_bps[1]);
    }

    var pred0_q13: i32 = -@as(i32, state.pred_prev_q13[0]);
    var pred1_q13: i32 = -@as(i32, state.pred_prev_q13[1]);
    var w_q24: i32 = @as(i32, state.width_prev_q14) << 10;
    const denom_q16 = @divTrunc(@as(i32, 1) << 16, interp_len_ms * fs_khz);
    const delta0_q13 = -m.rshiftRound(m.smulbb(pred_q13[0] - state.pred_prev_q13[0], denom_q16), 16);
    const delta1_q13 = -m.rshiftRound(m.smulbb(pred_q13[1] - state.pred_prev_q13[1], denom_q16), 16);
    const deltaw_q24 = m.smulwb(width_q14 - state.width_prev_q14, denom_q16) << 10;
    const interp: usize = @intCast(interp_len_ms * fs_khz);
    for (0..interp) |n| {
        pred0_q13 += delta0_q13;
        pred1_q13 += delta1_q13;
        w_q24 += deltaw_q24;
        var sum = ((@as(i32, mid[n]) + mid[n + 2]) +% (@as(i32, mid[n + 1]) << 1)) << 9;
        sum = m.smlawb(m.smulwb(w_q24, side[n + 1]), sum, pred0_q13);
        sum = m.smlawb(sum, @as(i32, mid[n + 1]) << 11, pred1_q13);
        in2[n + 1] = @intCast(m.sat16(m.rshiftRound(sum, 8)));
    }
    pred0_q13 = -pred_q13[0];
    pred1_q13 = -pred_q13[1];
    w_q24 = width_q14 << 10;
    for (interp..frame_length) |n| {
        var sum = ((@as(i32, mid[n]) + mid[n + 2]) +% (@as(i32, mid[n + 1]) << 1)) << 9;
        sum = m.smlawb(m.smulwb(w_q24, side[n + 1]), sum, pred0_q13);
        sum = m.smlawb(sum, @as(i32, mid[n + 1]) << 11, pred1_q13);
        in2[n + 1] = @intCast(m.sat16(m.rshiftRound(sum, 8)));
    }
    state.pred_prev_q13[0] = @truncate(pred_q13[0]);
    state.pred_prev_q13[1] = @truncate(pred_q13[1]);
    state.width_prev_q14 = @truncate(width_q14);
}

/// Codes the quantization indices of the predictors.
pub fn encodePred(enc: *range.Encoder, ix: *const [2][3]i8) void {
    const n: u32 = @intCast(5 * @as(i32, ix[0][2]) + ix[1][2]);
    enc.encodeIcdf(n, &tables.stereo_pred_joint_icdf, 8);
    for (0..2) |k| {
        enc.encodeIcdf(@intCast(ix[k][0]), &tables.uniform3_icdf, 8);
        enc.encodeIcdf(@intCast(ix[k][1]), &tables.uniform5_icdf, 8);
    }
}

/// Codes the flag that only the mid signal is coded.
pub fn encodeMidOnly(enc: *range.Encoder, flag: i8) void {
    enc.encodeIcdf(@intCast(flag), &tables.stereo_only_code_mid_icdf, 8);
}

test "stereo predictor indices read back as the decoder expects" {
    const stereo = @import("stereo.zig");
    var buf: [64]u8 = undefined;
    for (0..5) |a| {
        for (0..5) |b| {
            const ix: [2][3]i8 = .{ .{ @intCast(a % 3), @intCast((a + b) % 5), @intCast(a % 5) }, .{ @intCast(b % 3), @intCast(b % 5), @intCast(b) } };
            var enc = range.Encoder.init(&buf);
            encodePred(&enc, &ix);
            encodeMidOnly(&enc, @intCast(a % 2));
            enc.done();
            var dec = range.Decoder.init(&buf);
            const pred = stereo.decodePred(&dec);
            const mid_only = stereo.decodeMidOnly(&dec);
            try std.testing.expectEqual(a % 2 == 1, mid_only);
            var want: [2]i32 = undefined;
            for (ix, 0..) |row, n| {
                const idx: usize = @intCast(@as(i32, row[0]) + 3 * row[2]);
                const low: i32 = tables.stereo_pred_quant_q13[idx];
                const step = m.smulwb(@as(i32, tables.stereo_pred_quant_q13[idx + 1]) - low, 6554);
                want[n] = m.smlabb(low, step, 2 * @as(i32, row[1]) + 1);
            }
            want[0] -%= want[1];
            try std.testing.expectEqual(want, pred);
        }
    }
}
