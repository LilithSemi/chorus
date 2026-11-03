//! NLSF analysis and quantization of the SILK encoder, ported from libopus silk/A2NLSF.c,
//! NLSF_VQ.c, NLSF_VQ_weights_laroia.c, NLSF_del_dec_quant.c, NLSF_encode.c, process_NLSFs.c and
//! interpolate.c. libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const m = @import("macros.zig");
const tables = @import("tables.zig");
const lpc = @import("lpc.zig");
const nlsf = @import("nlsf.zig");
const st = @import("enc_state.zig");

const max_order = st.max_lpc_order;
const lsf_cos_tab_sz = 128;
const bin_div_steps = 3;
const max_iterations = 16;
const quant_max_amplitude = 4;
const quant_max_amplitude_ext = 10;
const del_dec_states = 4;

fn transPoly(p: []i32, dd: usize) void {
    var k: usize = 2;
    while (k <= dd) : (k += 1) {
        var n = dd;
        while (n > k) : (n -= 1) p[n - 2] -%= p[n];
        p[k - 2] -%= p[k] << 1;
    }
}

fn evalPoly(p: []const i32, x: i32, dd: usize) i32 {
    var y32 = p[dd];
    const x_q16 = x << 4;
    var n = dd;
    while (n > 0) {
        n -= 1;
        y32 = m.smlaww(p[n], y32, x_q16);
    }
    return y32;
}

fn a2nlsfInit(a_q16: []const i32, p: []i32, q: []i32, dd: usize) void {
    p[dd] = 1 << 16;
    q[dd] = 1 << 16;
    for (0..dd) |k| {
        p[k] = 0 -% a_q16[dd - k - 1] -% a_q16[dd + k];
        q[k] = 0 -% a_q16[dd - k - 1] +% a_q16[dd + k];
    }
    var k = dd;
    while (k > 0) : (k -= 1) {
        p[k - 1] -%= p[k];
        q[k - 1] +%= q[k];
    }
    transPoly(p, dd);
    transPoly(q, dd);
}

/// NLSF values in Q15 from the monic whitening filter in Q16. Bandwidth expansion changes
/// `a_q16` when roots are missing.
pub fn a2nlsf(nlsf_out: []i16, a_q16: []i32, d: usize) void {
    var pq: [2][max_order / 2 + 1]i32 = undefined;
    const dd = d >> 1;
    a2nlsfInit(a_q16[0..d], &pq[0], &pq[1], dd);
    const cos_tab = &tables.lsf_cos_tab_fix_q12;
    var p: usize = 0;
    var xlo: i32 = cos_tab[0];
    var ylo = evalPoly(&pq[p], xlo, dd);
    var root_ix: usize = undefined;
    if (ylo < 0) {
        nlsf_out[0] = 0;
        p = 1;
        ylo = evalPoly(&pq[p], xlo, dd);
        root_ix = 1;
    } else {
        root_ix = 0;
    }
    var k: usize = 1;
    var iter: u32 = 0;
    var thr: i32 = 0;
    while (true) {
        var xhi: i32 = cos_tab[k];
        var yhi = evalPoly(&pq[p], xhi, dd);
        if ((ylo <= 0 and yhi >= thr) or (ylo >= 0 and yhi <= -thr)) {
            thr = if (yhi == 0) 1 else 0;
            var ffrac: i32 = -256;
            for (0..bin_div_steps) |mm| {
                const xmid = m.rshiftRound(xlo + xhi, 1);
                const ymid = evalPoly(&pq[p], xmid, dd);
                if ((ylo <= 0 and ymid >= 0) or (ylo >= 0 and ymid <= 0)) {
                    xhi = xmid;
                    yhi = ymid;
                } else {
                    xlo = xmid;
                    ylo = ymid;
                    ffrac += @as(i32, 128) >> @intCast(mm);
                }
            }
            if (@abs(ylo) < 65536) {
                const den = ylo - yhi;
                const nom = (ylo << (8 - bin_div_steps)) + (den >> 1);
                if (den != 0) ffrac += m.div32(nom, den);
            } else {
                ffrac += m.div32(ylo, (ylo - yhi) >> (8 - bin_div_steps));
            }
            nlsf_out[root_ix] = @intCast(@min((@as(i32, @intCast(k)) << 8) + ffrac, std.math.maxInt(i16)));
            root_ix += 1;
            if (root_ix >= d) break;
            p = root_ix & 1;
            xlo = cos_tab[k - 1];
            ylo = (1 - @as(i32, @intCast(root_ix & 2))) << 12;
        } else {
            k += 1;
            xlo = xhi;
            ylo = yhi;
            thr = 0;
            if (k > lsf_cos_tab_sz) {
                iter += 1;
                if (iter > max_iterations) {
                    nlsf_out[0] = @intCast(@divTrunc(@as(i32, 1) << 15, @as(i32, @intCast(d)) + 1));
                    for (1..d) |kk| nlsf_out[kk] = nlsf_out[kk - 1] +% nlsf_out[0];
                    return;
                }
                lpc.bwexpander32(a_q16[0..d], 65536 - (@as(i32, 1) << @intCast(iter)));
                a2nlsfInit(a_q16[0..d], &pq[0], &pq[1], dd);
                p = 0;
                xlo = cos_tab[0];
                ylo = evalPoly(&pq[p], xlo, dd);
                if (ylo < 0) {
                    nlsf_out[0] = 0;
                    p = 1;
                    ylo = evalPoly(&pq[p], xlo, dd);
                    root_ix = 1;
                } else {
                    root_ix = 0;
                }
                k = 1;
            }
        }
    }
}

/// Weighted absolute quantization errors of the first stage for each of the 32 vectors.
fn nlsfVq(err_q24: []i32, in_q15: []const i16, cb_q8: []const u8, wght_q9: []const i16, k_count: usize, order: usize) void {
    for (0..k_count) |i| {
        var sum_error: i32 = 0;
        var pred: i32 = 0;
        const cb = cb_q8[i * order ..];
        const w = wght_q9[i * order ..];
        var mm: isize = @as(isize, @intCast(order)) - 2;
        while (mm >= 0) : (mm -= 2) {
            const u: usize = @intCast(mm);
            var diff_q15 = @as(i32, in_q15[u + 1]) - (@as(i32, cb[u + 1]) << 7);
            var diffw = m.smulbb(diff_q15, w[u + 1]);
            sum_error +%= @intCast(@abs(diffw -% (pred >> 1)));
            pred = diffw;
            diff_q15 = @as(i32, in_q15[u]) - (@as(i32, cb[u]) << 7);
            diffw = m.smulbb(diff_q15, w[u]);
            sum_error +%= @intCast(@abs(diffw -% (pred >> 1)));
            pred = diffw;
        }
        err_q24[i] = sum_error;
    }
}

/// Weights from the distances to the neighbouring NLSFs (Laroia).
fn vqWeightsLaroia(w_out: []i16, nlsf_q15: []const i16, d: usize) void {
    const num: i32 = 1 << (15 + 2);
    var tmp1: i32 = @max(@as(i32, nlsf_q15[0]), 1);
    tmp1 = @divTrunc(num, tmp1);
    var tmp2: i32 = @max(@as(i32, nlsf_q15[1]) - nlsf_q15[0], 1);
    tmp2 = @divTrunc(num, tmp2);
    w_out[0] = @intCast(@min(tmp1 + tmp2, std.math.maxInt(i16)));
    var k: usize = 1;
    while (k < d - 1) : (k += 2) {
        tmp1 = @max(@as(i32, nlsf_q15[k + 1]) - nlsf_q15[k], 1);
        tmp1 = @divTrunc(num, tmp1);
        w_out[k] = @intCast(@min(tmp1 + tmp2, std.math.maxInt(i16)));
        tmp2 = @max(@as(i32, nlsf_q15[k + 2]) - nlsf_q15[k + 1], 1);
        tmp2 = @divTrunc(num, tmp2);
        w_out[k + 1] = @intCast(@min(tmp1 + tmp2, std.math.maxInt(i16)));
    }
    tmp1 = @max((1 << 15) - @as(i32, nlsf_q15[d - 1]), 1);
    tmp1 = @divTrunc(num, tmp1);
    w_out[d - 1] = @intCast(@min(tmp1 + tmp2, std.math.maxInt(i16)));
}

/// Delayed decision quantizer of the NLSF residual. Returns the rate distortion value in Q25.
fn delDecQuant(
    indices: []i8,
    x_q10: []const i16,
    w_q5: []const i16,
    pred_coef_q8: []const u8,
    ec_ix: []const u16,
    ec_rates_q5: []const u8,
    quant_step_size_q16: i32,
    inv_quant_step_size_q6: i32,
    mu_q20: i32,
    order: usize,
) i32 {
    var out0_table: [2 * quant_max_amplitude_ext]i32 = undefined;
    var out1_table: [2 * quant_max_amplitude_ext]i32 = undefined;
    const level_adj: i16 = 102;
    var ii: i32 = -quant_max_amplitude_ext;
    while (ii <= quant_max_amplitude_ext - 1) : (ii += 1) {
        var out0: i16 = @truncate(ii << 10);
        var out1: i16 = out0 +% 1024;
        if (ii > 0) {
            out0 -%= level_adj;
            out1 -%= level_adj;
        } else if (ii == 0) {
            out1 -%= level_adj;
        } else if (ii == -1) {
            out0 +%= level_adj;
        } else {
            out0 +%= level_adj;
            out1 +%= level_adj;
        }
        const slot: usize = @intCast(ii + quant_max_amplitude_ext);
        out0_table[slot] = m.smulbb(out0, quant_step_size_q16) >> 16;
        out1_table[slot] = m.smulbb(out1, quant_step_size_q16) >> 16;
    }

    var ind_sort: [del_dec_states]i32 = undefined;
    var ind: [del_dec_states][max_order]i8 = undefined;
    var prev_out_q10: [2 * del_dec_states]i16 = undefined;
    var rd_q25: [2 * del_dec_states]i32 = undefined;
    var rd_min_q25: [del_dec_states]i32 = undefined;
    var rd_max_q25: [del_dec_states]i32 = undefined;
    var n_states: usize = 1;
    rd_q25[0] = 0;
    prev_out_q10[0] = 0;
    var i = order;
    while (i > 0) {
        i -= 1;
        const rates = ec_rates_q5[ec_ix[i]..];
        const in_q10: i32 = x_q10[i];
        for (0..n_states) |j| {
            const pred_q10: i32 = m.smulbb(@as(i32, pred_coef_q8[i]), prev_out_q10[j]) >> 8;
            const res_q10: i16 = @truncate(in_q10 - pred_q10);
            var ind_tmp: i32 = m.smulbb(inv_quant_step_size_q6, res_q10) >> 16;
            ind_tmp = std.math.clamp(ind_tmp, -quant_max_amplitude_ext, quant_max_amplitude_ext - 1);
            ind[j][i] = @intCast(ind_tmp);
            const slot: usize = @intCast(ind_tmp + quant_max_amplitude_ext);
            const out0: i16 = @truncate(out0_table[slot] +% pred_q10);
            const out1: i16 = @truncate(out1_table[slot] +% pred_q10);
            prev_out_q10[j] = out0;
            prev_out_q10[j + n_states] = out1;
            var rate0: i32 = undefined;
            var rate1: i32 = undefined;
            if (ind_tmp + 1 >= quant_max_amplitude) {
                if (ind_tmp + 1 == quant_max_amplitude) {
                    rate0 = rates[@intCast(ind_tmp + quant_max_amplitude)];
                    rate1 = 280;
                } else {
                    rate0 = m.smlabb(280 - 43 * quant_max_amplitude, 43, ind_tmp);
                    rate1 = rate0 + 43;
                }
            } else if (ind_tmp <= -quant_max_amplitude) {
                if (ind_tmp == -quant_max_amplitude) {
                    rate0 = 280;
                    rate1 = rates[@intCast(ind_tmp + 1 + quant_max_amplitude)];
                } else {
                    rate0 = m.smlabb(280 - 43 * quant_max_amplitude, -43, ind_tmp);
                    rate1 = rate0 - 43;
                }
            } else {
                rate0 = rates[@intCast(ind_tmp + quant_max_amplitude)];
                rate1 = rates[@intCast(ind_tmp + 1 + quant_max_amplitude)];
            }
            const rd_tmp = rd_q25[j];
            var diff_q10: i32 = @as(i16, @truncate(in_q10 - out0));
            rd_q25[j] = m.smlabb(rd_tmp +% m.smulbb(diff_q10, diff_q10) *% w_q5[i], mu_q20, rate0);
            diff_q10 = @as(i16, @truncate(in_q10 - out1));
            rd_q25[j + n_states] = m.smlabb(rd_tmp +% m.smulbb(diff_q10, diff_q10) *% w_q5[i], mu_q20, rate1);
        }
        if (n_states <= del_dec_states / 2) {
            for (0..n_states) |j| ind[j + n_states][i] = ind[j][i] + 1;
            n_states <<= 1;
            var j = n_states;
            while (j < del_dec_states) : (j += 1) ind[j][i] = ind[j - n_states][i];
        } else {
            for (0..del_dec_states) |j| {
                if (rd_q25[j] > rd_q25[j + del_dec_states]) {
                    rd_max_q25[j] = rd_q25[j];
                    rd_min_q25[j] = rd_q25[j + del_dec_states];
                    rd_q25[j] = rd_min_q25[j];
                    rd_q25[j + del_dec_states] = rd_max_q25[j];
                    const tmp = prev_out_q10[j];
                    prev_out_q10[j] = prev_out_q10[j + del_dec_states];
                    prev_out_q10[j + del_dec_states] = tmp;
                    ind_sort[j] = @intCast(j + del_dec_states);
                } else {
                    rd_min_q25[j] = rd_q25[j];
                    rd_max_q25[j] = rd_q25[j + del_dec_states];
                    ind_sort[j] = @intCast(j);
                }
            }
            while (true) {
                var min_max_q25: i32 = std.math.maxInt(i32);
                var max_min_q25: i32 = 0;
                var ind_min_max: usize = 0;
                var ind_max_min: usize = 0;
                for (0..del_dec_states) |j| {
                    if (min_max_q25 > rd_max_q25[j]) {
                        min_max_q25 = rd_max_q25[j];
                        ind_min_max = j;
                    }
                    if (max_min_q25 < rd_min_q25[j]) {
                        max_min_q25 = rd_min_q25[j];
                        ind_max_min = j;
                    }
                }
                if (min_max_q25 >= max_min_q25) break;
                ind_sort[ind_max_min] = ind_sort[ind_min_max] ^ del_dec_states;
                rd_q25[ind_max_min] = rd_q25[ind_min_max + del_dec_states];
                prev_out_q10[ind_max_min] = prev_out_q10[ind_min_max + del_dec_states];
                rd_min_q25[ind_max_min] = 0;
                rd_max_q25[ind_min_max] = std.math.maxInt(i32);
                ind[ind_max_min] = ind[ind_min_max];
            }
            for (0..del_dec_states) |j| {
                ind[j][i] +%= @intCast(ind_sort[j] >> 2);
            }
        }
    }

    var ind_tmp: usize = 0;
    var min_q25: i32 = std.math.maxInt(i32);
    for (0..2 * del_dec_states) |j| {
        if (min_q25 > rd_q25[j]) {
            min_q25 = rd_q25[j];
            ind_tmp = j;
        }
    }
    for (0..order) |j| indices[j] = ind[ind_tmp & (del_dec_states - 1)][j];
    indices[0] +%= @intCast(ind_tmp >> 2);
    return min_q25;
}

fn insertionSortIncreasing(a: []i32, idx: []i32, l: usize, k: usize) void {
    for (0..k) |i| idx[i] = @intCast(i);
    for (1..k) |i| {
        const value = a[i];
        var j: isize = @as(isize, @intCast(i)) - 1;
        while (j >= 0 and value < a[@intCast(j)]) : (j -= 1) {
            a[@intCast(j + 1)] = a[@intCast(j)];
            idx[@intCast(j + 1)] = idx[@intCast(j)];
        }
        a[@intCast(j + 1)] = value;
        idx[@intCast(j + 1)] = @intCast(i);
    }
    for (k..l) |i| {
        const value = a[i];
        if (value < a[k - 1]) {
            var j: isize = @as(isize, @intCast(k)) - 2;
            while (j >= 0 and value < a[@intCast(j)]) : (j -= 1) {
                a[@intCast(j + 1)] = a[@intCast(j)];
                idx[@intCast(j + 1)] = idx[@intCast(j)];
            }
            a[@intCast(j + 1)] = value;
            idx[@intCast(j + 1)] = @intCast(i);
        }
    }
}

/// Quantizes the NLSF vector in place with the two stage codebook. `indices` is
/// `[stage 1, residual 0 .. order]`.
pub fn encode(indices: []i8, nlsf_q15: []i16, cb: *const nlsf.Codebook, w_q2: []const i16, mu_q20: i32, n_survivors: usize, signal_type: i32) void {
    const order: usize = cb.order;
    nlsf.stabilize(nlsf_q15[0..order], cb.delta_min);
    var err_q24: [32]i32 = undefined;
    nlsfVq(&err_q24, nlsf_q15, cb.cb1, cb.weights, 32, order);
    var temp_indices1: [16]i32 = undefined;
    insertionSortIncreasing(&err_q24, &temp_indices1, 32, n_survivors);
    var rd_q25: [16]i32 = undefined;
    var temp_indices2: [16 * max_order]i8 = undefined;
    for (0..n_survivors) |s| {
        const ind1: usize = @intCast(temp_indices1[s]);
        const cb_element = cb.cb1[ind1 * order ..];
        const cb_wght = cb.weights[ind1 * order ..];
        var nlsf_tmp: [max_order]i16 = undefined;
        var res_q10: [max_order]i16 = undefined;
        var w_adj_q5: [max_order]i16 = undefined;
        for (0..order) |i| {
            nlsf_tmp[i] = @as(i16, cb_element[i]) << 7;
            const w_tmp_q9: i32 = cb_wght[i];
            res_q10[i] = @truncate(m.smulbb(@as(i32, nlsf_q15[i]) - nlsf_tmp[i], w_tmp_q9) >> 14);
            w_adj_q5[i] = @truncate(m.div32VarQ(w_q2[i], m.smulbb(w_tmp_q9, w_tmp_q9), 21));
        }
        var ec_ix: [max_order]u16 = undefined;
        var pred_q8: [max_order]u8 = undefined;
        nlsf.unpack(cb, ind1, &ec_ix, &pred_q8);
        rd_q25[s] = delDecQuant(temp_indices2[s * max_order ..], &res_q10, &w_adj_q5, &pred_q8, &ec_ix, cb.ec_rates, cb.quant_step_size_q16, cb.inv_quant_step_size_q6, mu_q20, order);
        const icdf = cb.cb1_icdf[@as(usize, @intCast(signal_type >> 1)) * 32 ..];
        const prob_q8: i32 = if (ind1 == 0) 256 - @as(i32, icdf[ind1]) else @as(i32, icdf[ind1 - 1]) - icdf[ind1];
        const bits_q7 = (8 << 7) - m.lin2log(prob_q8);
        rd_q25[s] = m.smlabb(rd_q25[s], bits_q7, mu_q20 >> 2);
    }
    var best_index: [1]i32 = undefined;
    insertionSortIncreasing(&rd_q25, &best_index, n_survivors, 1);
    const best: usize = @intCast(best_index[0]);
    indices[0] = @intCast(temp_indices1[best]);
    @memcpy(indices[1..][0..order], temp_indices2[best * max_order ..][0..order]);
    nlsf.decode(nlsf_q15, indices, cb);
}

/// Interpolates between two NLSF vectors with the weight `ifact_q2` / 4 on the second.
pub fn interpolate(xi: []i16, x0: []const i16, x1: []const i16, ifact_q2: i32, d: usize) void {
    for (0..d) |i| {
        xi[i] = @truncate(@as(i32, x0[i]) + (m.smulbb(@as(i32, x1[i]) - x0[i], ifact_q2) >> 2));
    }
}

/// Limits, stabilizes, converts and quantizes the NLSFs of the frame. `pred_coef_q12[1]` is
/// the filter of the second half, `[0]` the one of the first half.
pub fn processNlsfs(ch: *st.Channel, pred_coef_q12: *[2][max_order]i16, nlsf_q15: []i16, prev_nlsf_q15: []const i16) void {
    const order: usize = @intCast(ch.predict_lpc_order);
    var mu_q20 = m.smlawb(3146, -268434, ch.speech_activity_q8);
    if (ch.nb_subfr == 2) mu_q20 = mu_q20 + (mu_q20 >> 1);

    var w_qw: [max_order]i16 = undefined;
    vqWeightsLaroia(&w_qw, nlsf_q15, order);
    const do_interpolate = ch.use_interpolated_nlsfs and ch.indices.nlsf_interp_coef_q2 < 4;
    var nlsf0_temp: [max_order]i16 = undefined;
    if (do_interpolate) {
        interpolate(&nlsf0_temp, prev_nlsf_q15, nlsf_q15, ch.indices.nlsf_interp_coef_q2, order);
        var w0_temp: [max_order]i16 = undefined;
        vqWeightsLaroia(&w0_temp, &nlsf0_temp, order);
        const i_sqr_q15: i16 = @truncate(m.smulbb(ch.indices.nlsf_interp_coef_q2, ch.indices.nlsf_interp_coef_q2) << 11);
        for (0..order) |i| {
            w_qw[i] = (w_qw[i] >> 1) +% @as(i16, @truncate(m.smulbb(w0_temp[i], i_sqr_q15) >> 16));
        }
    }
    encode(&ch.indices.nlsf_indices, nlsf_q15, ch.nlsf_cb, &w_qw, mu_q20, @intCast(ch.nlsf_msvq_survivors), ch.indices.signal_type);
    lpc.nlsf2a(pred_coef_q12[1][0..order], nlsf_q15[0..order]);
    if (do_interpolate) {
        interpolate(&nlsf0_temp, prev_nlsf_q15, nlsf_q15, ch.indices.nlsf_interp_coef_q2, order);
        lpc.nlsf2a(pred_coef_q12[0][0..order], nlsf0_temp[0..order]);
    } else {
        pred_coef_q12[0] = pred_coef_q12[1];
    }
}

const testing = std.testing;

test "a2nlsf finds ordered NLSFs of a stable filter and nlsf2a inverts them" {
    // A resonance at about one fifth of the sampling rate.
    var a_q12: [16]i16 = undefined;
    var nlsf_q15: [16]i16 = undefined;
    for (&nlsf_q15, 0..) |*v, i| v.* = @intCast((i + 1) * 1900);
    lpc.nlsf2a(&a_q12, &nlsf_q15);
    var a_q16: [16]i32 = undefined;
    for (&a_q16, a_q12) |*o, v| o.* = @as(i32, v) << 4;
    var back: [16]i16 = undefined;
    a2nlsf(&back, &a_q16, 16);
    for (0..16) |i| try testing.expect(@abs(@as(i32, back[i]) - nlsf_q15[i]) < 80);
    for (1..16) |i| try testing.expect(back[i] > back[i - 1]);
}

test "the NLSF quantizer returns indices that decode close to the input" {
    const cb = &nlsf.wb;
    var in: [16]i16 = undefined;
    for (&in, 0..) |*v, i| v.* = @intCast((i + 1) * 1900 + (i % 3) * 40);
    var w: [16]i16 = undefined;
    vqWeightsLaroia(&w, &in, 16);
    var q = in;
    var indices: [17]i8 = undefined;
    encode(&indices, &q, cb, &w, 3000, 4, 2);
    for (0..16) |i| try testing.expect(@abs(@as(i32, q[i]) - in[i]) < 900);
    var dec: [16]i16 = undefined;
    nlsf.decode(&dec, &indices, cb);
    try testing.expectEqualSlices(i16, &dec, &q);
}
