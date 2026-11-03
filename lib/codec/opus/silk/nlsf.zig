//! NLSF codebooks ported from libopus silk/NLSF_unpack.c, NLSF_decode.c and NLSF_stabilize.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const m = @import("macros.zig");
const tables = @import("tables.zig");
const enc_tables = @import("enc_tables.zig");
const lpc = @import("lpc.zig");

pub const max_order = lpc.max_order;

/// A two stage NLSF codebook. `cb1` and `weights` hold `order` values for each of the 32 vectors.
pub const Codebook = struct {
    order: u32,
    quant_step_size_q16: i32,
    cb1: []const u8,
    weights: []const i16,
    cb1_icdf: []const u8,
    pred: []const u8,
    ec_sel: []const u8,
    ec_icdf: []const u8,
    delta_min: []const i16,
    /// Bits of the second stage indices in Q5, used by the encoder.
    ec_rates: []const u8,
    inv_quant_step_size_q6: i32,
};

pub const nb_mb: Codebook = .{
    .order = 10,
    .quant_step_size_q16 = 11796,
    .cb1 = &tables.nlsf_cb1_nb_mb_q8,
    .weights = &tables.nlsf_cb1_nb_mb_wght_q9,
    .cb1_icdf = &tables.nlsf_cb1_nb_mb_icdf,
    .pred = &tables.nlsf_pred_nb_mb_q8,
    .ec_sel = &tables.nlsf_cb2_nb_mb_select,
    .ec_icdf = &tables.nlsf_cb2_nb_mb_icdf,
    .delta_min = &tables.nlsf_delta_min_nb_mb_q15,
    .ec_rates = &enc_tables.nlsf_cb2_bits_nb_mb_q5,
    .inv_quant_step_size_q6 = 356,
};

pub const wb: Codebook = .{
    .order = 16,
    .quant_step_size_q16 = 9830,
    .cb1 = &tables.nlsf_cb1_wb_q8,
    .weights = &tables.nlsf_cb1_wb_wght_q9,
    .cb1_icdf = &tables.nlsf_cb1_wb_icdf,
    .pred = &tables.nlsf_pred_wb_q8,
    .ec_sel = &tables.nlsf_cb2_wb_select,
    .ec_icdf = &tables.nlsf_cb2_wb_icdf,
    .delta_min = &tables.nlsf_delta_min_wb_q15,
    .ec_rates = &enc_tables.nlsf_cb2_bits_wb_q5,
    .inv_quant_step_size_q6 = 427,
};

/// The offsets into the second stage tables and the predictor of each coefficient.
pub fn unpack(cb: *const Codebook, cb_index: usize, ec_ix: *[max_order]u16, pred_q8: *[max_order]u8) void {
    const order = cb.order;
    const sel = cb.ec_sel[cb_index * order / 2 ..];
    var i: usize = 0;
    while (i < order) : (i += 2) {
        const entry: u32 = sel[i / 2];
        ec_ix[i] = @intCast(((entry >> 1) & 7) * 9);
        pred_q8[i] = cb.pred[i + (entry & 1) * (order - 1)];
        ec_ix[i + 1] = @intCast(((entry >> 5) & 7) * 9);
        pred_q8[i + 1] = cb.pred[i + ((entry >> 4) & 1) * (order - 1) + 1];
    }
}

fn residualDequant(res_q10: []i16, indices: []const i8, pred_q8: []const u8, step_q16: i32) void {
    var out_q10: i32 = 0;
    var i = res_q10.len;
    while (i > 0) {
        i -= 1;
        const pred_q10 = m.smulbb(out_q10, pred_q8[i]) >> 8;
        out_q10 = @as(i32, indices[i]) << 10;
        if (out_q10 > 0) {
            out_q10 -= 102;
        } else if (out_q10 < 0) {
            out_q10 += 102;
        }
        out_q10 = m.smlawb(pred_q10, out_q10, step_q16);
        res_q10[i] = m.trunc16(out_q10);
    }
}

/// Decodes the quantized NLSF vector in Q15 from the indices `[stage 1, residual 0 .. order]`.
pub fn decode(nlsf_q15: []i16, indices: []const i8, cb: *const Codebook) void {
    const order = cb.order;
    const cb_index: usize = @intCast(indices[0]);
    var ec_ix: [max_order]u16 = undefined;
    var pred_q8: [max_order]u8 = undefined;
    unpack(cb, cb_index, &ec_ix, &pred_q8);
    var res_q10: [max_order]i16 = undefined;
    residualDequant(res_q10[0..order], indices[1..][0..order], pred_q8[0..order], cb.quant_step_size_q16);
    const elem = cb.cb1[cb_index * order ..][0..order];
    const wght = cb.weights[cb_index * order ..][0..order];
    for (0..order) |i| {
        const tmp = m.div32(@as(i32, res_q10[i]) << 14, wght[i]) +% (@as(i32, elem[i]) << 7);
        nlsf_q15[i] = @intCast(m.limit(tmp, 0, 32767));
    }
    stabilize(nlsf_q15[0..order], cb.delta_min);
}

fn insertionSort(a: []i16) void {
    var i: usize = 1;
    while (i < a.len) : (i += 1) {
        const value = a[i];
        var j = i;
        while (j > 0 and value < a[j - 1]) : (j -= 1) a[j] = a[j - 1];
        a[j] = value;
    }
}

/// Spreads NLSF values that are closer than `delta_min` apart.
pub fn stabilize(nlsf: []i16, delta_min: []const i16) void {
    const l = nlsf.len;
    for (0..20) |_| {
        var min_diff: i32 = @as(i32, nlsf[0]) - delta_min[0];
        var idx: usize = 0;
        for (1..l) |i| {
            const diff = @as(i32, nlsf[i]) - (@as(i32, nlsf[i - 1]) + delta_min[i]);
            if (diff < min_diff) {
                min_diff = diff;
                idx = i;
            }
        }
        const last = (1 << 15) - (@as(i32, nlsf[l - 1]) + delta_min[l]);
        if (last < min_diff) {
            min_diff = last;
            idx = l;
        }
        if (min_diff >= 0) return;
        if (idx == 0) {
            nlsf[0] = delta_min[0];
        } else if (idx == l) {
            nlsf[l - 1] = @intCast((1 << 15) - @as(i32, delta_min[l]));
        } else {
            var min_center: i32 = 0;
            for (delta_min[0..idx]) |v| min_center += v;
            min_center += delta_min[idx] >> 1;
            // A `-=` reduction in this loop gives a wrong sum when LLVM unrolls it for Apple CPUs
            // (llvm/llvm-project#201065).
            var upper: i32 = 0;
            for (delta_min[idx + 1 .. l + 1]) |v| upper += v;
            const max_center: i32 = (1 << 15) - upper - (delta_min[idx] >> 1);
            const mid = m.rshiftRound(@as(i32, nlsf[idx - 1]) + nlsf[idx], 1);
            const center = m.trunc16(m.limit(mid, min_center, max_center));
            nlsf[idx - 1] = center -% (delta_min[idx] >> 1);
            nlsf[idx] = nlsf[idx - 1] +% delta_min[idx];
        }
    }
    insertionSort(nlsf);
    nlsf[0] = @max(nlsf[0], delta_min[0]);
    for (1..l) |i| nlsf[i] = @max(nlsf[i], m.addSat16(nlsf[i - 1], delta_min[i]));
    nlsf[l - 1] = @min(nlsf[l - 1], @as(i16, @intCast((1 << 15) - @as(i32, delta_min[l]))));
    var i = l - 1;
    while (i > 0) {
        i -= 1;
        nlsf[i] = @min(nlsf[i], nlsf[i + 1] -% delta_min[i + 1]);
    }
}

const testing = std.testing;

test "codebook tables have the sizes of the libopus structures" {
    for ([_]Codebook{ nb_mb, wb }) |cb| {
        try testing.expectEqual(32 * cb.order, cb.cb1.len);
        try testing.expectEqual(cb.cb1.len, cb.weights.len);
        try testing.expectEqual(@as(usize, 64), cb.cb1_icdf.len);
        try testing.expectEqual(32 * cb.order / 2, cb.ec_sel.len);
        try testing.expectEqual(@as(usize, 72), cb.ec_icdf.len);
        try testing.expectEqual(2 * (cb.order - 1), cb.pred.len);
        try testing.expectEqual(cb.order + 1, cb.delta_min.len);
    }
}

test "unpack never reads past the predictor table" {
    for ([_]Codebook{ nb_mb, wb }) |cb| {
        var ec_ix: [max_order]u16 = undefined;
        var pred: [max_order]u8 = undefined;
        for (0..32) |cb_index| unpack(&cb, cb_index, &ec_ix, &pred);
    }
    var ec_ix: [max_order]u16 = undefined;
    var pred: [max_order]u8 = undefined;
    unpack(&nb_mb, 0, &ec_ix, &pred);
    try testing.expectEqual(@as(u16, 0), ec_ix[0]);
    try testing.expectEqual(@as(u8, 179), pred[0]);
}

test "stabilize leaves a valid vector and spreads a close one" {
    var ok = [_]i16{ 3000, 6000, 9000, 12000, 15000, 18000, 21000, 24000, 27000, 30000 };
    const before = ok;
    stabilize(&ok, &tables.nlsf_delta_min_nb_mb_q15);
    try testing.expectEqualSlices(i16, &before, &ok);
    var bad = [_]i16{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    stabilize(&bad, &tables.nlsf_delta_min_nb_mb_q15);
    for (1..10) |i| try testing.expect(bad[i] - bad[i - 1] >= tables.nlsf_delta_min_nb_mb_q15[i]);
    try testing.expect(bad[0] >= tables.nlsf_delta_min_nb_mb_q15[0]);
    try testing.expect(@as(i32, bad[9]) <= 32768 - @as(i32, tables.nlsf_delta_min_nb_mb_q15[10]));
}

test "stabilize spreads a close pair in the middle of the vector" {
    var nlsf = [_]i16{ 3788, 3691, 9230, 14379, 13966, 18774, 19245, 21221, 27270, 27730 };
    stabilize(&nlsf, &tables.nlsf_delta_min_nb_mb_q15);
    try testing.expectEqualSlices(i16, &.{ 3739, 3742, 9230, 14172, 14175, 18774, 19245, 21221, 27270, 27730 }, &nlsf);
}
