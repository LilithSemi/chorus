//! Entropy coding of the SILK side information and excitation, ported from libopus
//! silk/encode_indices.c, silk/encode_pulses.c, silk/shell_coder.c and silk/code_signs.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const m = @import("macros.zig");
const range = @import("../range.zig");
const tables = @import("tables.zig");
const enc_tables = @import("enc_tables.zig");
const nlsf = @import("nlsf.zig");
const pitch = @import("pitch.zig");
const st = @import("enc_state.zig");

const shell_len = 16;
const quant_max_amplitude = 4;
const max_pulses = 16;
const n_rate_levels = 10;

/// Codes the side information of one frame: signal type, gains, NLSFs, pitch, LTP and seed.
pub fn encodeIndices(ch: *st.Channel, enc: *range.Encoder, frame_index: usize, encode_lbrr: bool, cond: st.Cond) void {
    const ind: *const st.Indices = if (encode_lbrr) &ch.indices_lbrr[frame_index] else &ch.indices;
    const type_offset: u32 = @intCast(2 * @as(i32, ind.signal_type) + ind.quant_offset_type);
    if (encode_lbrr or type_offset >= 2) {
        enc.encodeIcdf(type_offset - 2, &tables.type_offset_vad_icdf, 8);
    } else {
        enc.encodeIcdf(type_offset, &tables.type_offset_no_vad_icdf, 8);
    }

    const signal_type: usize = @intCast(ind.signal_type);
    if (cond == .conditionally) {
        enc.encodeIcdf(@intCast(ind.gains[0]), &tables.delta_gain_icdf, 8);
    } else {
        const g: u32 = @intCast(ind.gains[0]);
        enc.encodeIcdf(g >> 3, tables.gain_icdf[signal_type * 8 ..][0..8], 8);
        enc.encodeIcdf(g & 7, &tables.uniform8_icdf, 8);
    }
    for (1..@as(usize, @intCast(ch.nb_subfr))) |i| {
        enc.encodeIcdf(@intCast(ind.gains[i]), &tables.delta_gain_icdf, 8);
    }

    const cb = ch.nlsf_cb;
    const order: usize = cb.order;
    enc.encodeIcdf(@intCast(ind.nlsf_indices[0]), cb.cb1_icdf[(signal_type >> 1) * 32 ..][0..32], 8);
    var ec_ix: [st.max_lpc_order]u16 = undefined;
    var pred_q8: [st.max_lpc_order]u8 = undefined;
    nlsf.unpack(cb, @intCast(ind.nlsf_indices[0]), &ec_ix, &pred_q8);
    for (0..order) |i| {
        const v: i32 = ind.nlsf_indices[i + 1];
        const tab = cb.ec_icdf[ec_ix[i]..];
        if (v >= quant_max_amplitude) {
            enc.encodeIcdf(2 * quant_max_amplitude, tab, 8);
            enc.encodeIcdf(@intCast(v - quant_max_amplitude), &tables.nlsf_ext_icdf, 8);
        } else if (v <= -quant_max_amplitude) {
            enc.encodeIcdf(0, tab, 8);
            enc.encodeIcdf(@intCast(-v - quant_max_amplitude), &tables.nlsf_ext_icdf, 8);
        } else {
            enc.encodeIcdf(@intCast(v + quant_max_amplitude), tab, 8);
        }
    }
    if (ch.nb_subfr == st.max_subfr) {
        enc.encodeIcdf(@intCast(ind.nlsf_interp_coef_q2), &tables.nlsf_interpolation_factor_icdf, 8);
    }

    if (ind.signal_type == st.type_voiced) {
        var encode_absolute = true;
        if (cond == .conditionally and ch.ec_prev_signal_type == st.type_voiced) {
            var delta: i32 = @as(i32, ind.lag_index) - ch.ec_prev_lag_index;
            if (delta < -8 or delta > 11) {
                delta = 0;
            } else {
                delta += 9;
                encode_absolute = false;
            }
            enc.encodeIcdf(@intCast(delta), &tables.pitch_delta_icdf, 8);
        }
        if (encode_absolute) {
            const half: i32 = ch.fs_khz >> 1;
            const high = @divTrunc(@as(i32, ind.lag_index), half);
            const low = @as(i32, ind.lag_index) - high * half;
            enc.encodeIcdf(@intCast(high), &tables.pitch_lag_icdf, 8);
            enc.encodeIcdf(@intCast(low), ch.pitch_lag_low_bits_icdf, 8);
        }
        ch.ec_prev_lag_index = ind.lag_index;
        enc.encodeIcdf(@intCast(ind.contour_index), ch.pitch_contour_icdf, 8);

        enc.encodeIcdf(@intCast(ind.per_index), &tables.ltp_per_index_icdf, 8);
        for (0..@as(usize, @intCast(ch.nb_subfr))) |k| {
            enc.encodeIcdf(@intCast(ind.ltp_index[k]), pitch.ltp_gain_icdfs[@intCast(ind.per_index)], 8);
        }
        if (cond == .independently) {
            enc.encodeIcdf(@intCast(ind.ltp_scale_index), &tables.ltp_scale_icdf, 8);
        }
    }
    ch.ec_prev_signal_type = ind.signal_type;
    enc.encodeIcdf(@intCast(ind.seed), &tables.uniform4_icdf, 8);
}

fn combineAndCheck(comb: []i32, input: []const i32, max_sum: i32, len: usize) bool {
    for (0..len) |k| {
        const sum = input[2 * k] + input[2 * k + 1];
        if (sum > max_sum) return true;
        comb[k] = sum;
    }
    return false;
}

fn encodeSplit(enc: *range.Encoder, p_child1: i32, p: i32, table: []const u8) void {
    if (p > 0) {
        const off = tables.shell_code_table_offsets[@intCast(p)];
        enc.encodeIcdf(@intCast(p_child1), table[off..], 8);
    }
}

/// Codes one block of 16 pulse amplitudes as a binary tree of splits.
fn shellEncoder(enc: *range.Encoder, p0: []const i32) void {
    var p1: [8]i32 = undefined;
    var p2: [4]i32 = undefined;
    var p3: [2]i32 = undefined;
    for (0..8) |k| p1[k] = p0[2 * k] + p0[2 * k + 1];
    for (0..4) |k| p2[k] = p1[2 * k] + p1[2 * k + 1];
    for (0..2) |k| p3[k] = p2[2 * k] + p2[2 * k + 1];
    const p4 = p3[0] + p3[1];
    const t0 = &tables.shell_code_table0;
    const t1 = &tables.shell_code_table1;
    const t2 = &tables.shell_code_table2;
    const t3 = &tables.shell_code_table3;
    encodeSplit(enc, p3[0], p4, t3);
    encodeSplit(enc, p2[0], p3[0], t2);
    encodeSplit(enc, p1[0], p2[0], t1);
    encodeSplit(enc, p0[0], p1[0], t0);
    encodeSplit(enc, p0[2], p1[1], t0);
    encodeSplit(enc, p1[2], p2[1], t1);
    encodeSplit(enc, p0[4], p1[2], t0);
    encodeSplit(enc, p0[6], p1[3], t0);
    encodeSplit(enc, p2[2], p3[1], t2);
    encodeSplit(enc, p1[4], p2[2], t1);
    encodeSplit(enc, p0[8], p1[4], t0);
    encodeSplit(enc, p0[10], p1[5], t0);
    encodeSplit(enc, p1[6], p2[3], t1);
    encodeSplit(enc, p0[12], p1[6], t0);
    encodeSplit(enc, p0[14], p1[7], t0);
}

fn encodeSigns(enc: *range.Encoder, pulses: []const i8, length_in: usize, signal_type: i32, quant_offset_type: i32, sum_pulses: []const i32) void {
    const base: usize = @intCast(7 * (quant_offset_type + (signal_type << 1)));
    const icdf_ptr = tables.sign_icdf[base..];
    const length = (length_in + shell_len / 2) >> 4;
    var icdf: [2]u8 = .{ 0, 0 };
    for (0..length) |i| {
        const p = sum_pulses[i];
        if (p > 0) {
            icdf[0] = icdf_ptr[@intCast(@min(p & 0x1F, 6))];
            for (0..shell_len) |j| {
                const q = pulses[i * shell_len + j];
                if (q != 0) enc.encodeIcdf(@intCast((@as(i32, q) >> 15) + 1), &icdf, 8);
            }
        }
    }
}

/// Codes the excitation: rate level, pulse counts, pulse positions, low bits and signs.
/// `pulses` must have room for 16 values after `frame_length`.
pub fn encodePulses(enc: *range.Encoder, signal_type: i32, quant_offset_type: i32, pulses: []i8, frame_length: usize) void {
    var iter = frame_length >> 4;
    if (iter * shell_len < frame_length) {
        iter += 1;
        @memset(pulses[frame_length..][0..shell_len], 0);
    }
    var abs_pulses: [st.max_frame_length + shell_len]i32 = undefined;
    for (0..iter * shell_len) |i| abs_pulses[i] = @intCast(@abs(@as(i32, pulses[i])));
    var sum_pulses: [st.max_frame_length / shell_len + 1]i32 = undefined;
    var n_rshifts: [st.max_frame_length / shell_len + 1]i32 = undefined;
    var comb: [8]i32 = @splat(0);
    for (0..iter) |i| {
        n_rshifts[i] = 0;
        const block = abs_pulses[i * shell_len ..][0..shell_len];
        while (true) {
            var scale_down = combineAndCheck(&comb, block, enc_tables.max_pulses_table[0], 8);
            scale_down = combineAndCheck(&comb, &comb, enc_tables.max_pulses_table[1], 4) or scale_down;
            scale_down = combineAndCheck(&comb, &comb, enc_tables.max_pulses_table[2], 2) or scale_down;
            scale_down = combineAndCheck(sum_pulses[i..], &comb, enc_tables.max_pulses_table[3], 1) or scale_down;
            if (scale_down) {
                n_rshifts[i] += 1;
                for (block) |*v| v.* >>= 1;
            } else break;
        }
    }

    var min_sum_bits_q5: i32 = std.math.maxInt(i32);
    var rate_level_index: usize = 0;
    const st_idx: usize = @intCast(signal_type >> 1);
    for (0..n_rate_levels - 1) |k| {
        const n_bits = enc_tables.pulses_per_block_bits_q5[k * 18 ..][0..18];
        var sum_bits_q5: i32 = enc_tables.rate_levels_bits_q5[st_idx * 9 + k];
        for (0..iter) |i| {
            if (n_rshifts[i] > 0) {
                sum_bits_q5 += n_bits[max_pulses + 1];
            } else {
                sum_bits_q5 += n_bits[@intCast(sum_pulses[i])];
            }
        }
        if (sum_bits_q5 < min_sum_bits_q5) {
            min_sum_bits_q5 = sum_bits_q5;
            rate_level_index = k;
        }
    }
    enc.encodeIcdf(@intCast(rate_level_index), tables.rate_levels_icdf[st_idx * 9 ..][0..9], 8);

    const cdf = tables.pulses_per_block_icdf[rate_level_index * 18 ..][0..18];
    const escape_cdf = tables.pulses_per_block_icdf[(n_rate_levels - 1) * 18 ..][0..18];
    for (0..iter) |i| {
        if (n_rshifts[i] == 0) {
            enc.encodeIcdf(@intCast(sum_pulses[i]), cdf, 8);
        } else {
            enc.encodeIcdf(max_pulses + 1, cdf, 8);
            for (0..@as(usize, @intCast(n_rshifts[i] - 1))) |_| {
                enc.encodeIcdf(max_pulses + 1, escape_cdf, 8);
            }
            enc.encodeIcdf(@intCast(sum_pulses[i]), escape_cdf, 8);
        }
    }

    for (0..iter) |i| {
        if (sum_pulses[i] > 0) shellEncoder(enc, abs_pulses[i * shell_len ..][0..shell_len]);
    }

    for (0..iter) |i| {
        if (n_rshifts[i] > 0) {
            const block = pulses[i * shell_len ..][0..shell_len];
            const n_ls: i32 = n_rshifts[i] - 1;
            for (0..shell_len) |k| {
                const abs_q: i32 = @as(i8, @bitCast(@as(u8, @truncate(@abs(@as(i32, block[k]))))));
                var j: i32 = n_ls;
                while (j > 0) : (j -= 1) {
                    const bit: u32 = @intCast((abs_q >> @intCast(j)) & 1);
                    enc.encodeIcdf(bit, &tables.lsb_icdf, 8);
                }
                enc.encodeIcdf(@intCast(abs_q & 1), &tables.lsb_icdf, 8);
            }
        }
    }

    encodeSigns(enc, pulses, frame_length, signal_type, quant_offset_type, &sum_pulses);
}

test "pulses that the encoder codes are the pulses that the decoder reads" {
    const excitation = @import("excitation.zig");
    var seed: u32 = 12345;
    for (0..40) |round| {
        const frame_length: usize = if (round % 2 == 0) 160 else 320;
        const signal_type: i32 = @intCast(round % 3);
        const offset_type: i32 = @intCast(round % 2);
        var pulses: [st.max_frame_length + shell_len]i8 = @splat(0);
        for (pulses[0..frame_length]) |*p| {
            seed = seed *% 1664525 +% 1013904223;
            const r: i32 = @intCast((seed >> 16) % 100);
            const big: i32 = if (round % 5 == 0) 60 else 3;
            p.* = if (r < 40) 0 else @intCast(@mod(@as(i32, @intCast((seed >> 8) % 255)), big * 2 + 1) - big);
        }
        var buf: [1275]u8 = undefined;
        var enc = range.Encoder.init(&buf);
        var copy = pulses;
        encodePulses(&enc, signal_type, offset_type, &copy, frame_length);
        enc.done();
        var dec = range.Decoder.init(&buf);
        var got: [excitation.max_pulses]i16 = undefined;
        excitation.decodePulses(&dec, &got, @intCast(signal_type), @intCast(offset_type), @intCast(frame_length));
        for (0..frame_length) |i| try std.testing.expectEqual(@as(i16, pulses[i]), got[i]);
    }
}
