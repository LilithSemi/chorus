//! SILK packet loss concealment and comfort noise, ported from libopus silk/PLC.c and silk/CNG.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const m = @import("macros.zig");
const lpc = @import("lpc.zig");
const decode = @import("decode.zig");

const ltp_order = 5;
const max_order = lpc.max_order;
const max_frame_length = decode.max_frame_length;
const rand_buf_size = 128;
const rand_buf_mask = rand_buf_size - 1;
const type_voiced = 2;
const type_no_voice_activity = 0;

const harm_att_q15 = [2]i32{ 32440, 31130 };
const rand_attenuate_voiced_q15 = [2]i32{ 31130, 26214 };
const rand_attenuate_unvoiced_q15 = [2]i32{ 32440, 29491 };
const bwe_coef_q16 = 64881;
const v_pitch_gain_start_min_q14 = 11469;
const v_pitch_gain_start_max_q14 = 15565;
const max_pitch_lag_ms = 18;
const pitch_drift_fac_q16 = 655;
const log2_inv_lpc_gain_high_thres = 3;
const log2_inv_lpc_gain_low_thres = 8;

const cng_buf_mask_max = 255;
const cng_gain_smth_q16 = 4634;
const cng_gain_smth_threshold_q16 = 46396;
const cng_nlsf_smth_q16 = 16348;

/// What the concealment keeps from the last good frames.
pub const State = struct {
    pitch_l_q8: i32 = 0,
    ltp_coef_q14: [ltp_order]i16 = @splat(0),
    prev_lpc_q12: [max_order]i16 = @splat(0),
    last_frame_lost: bool = false,
    rand_seed: i32 = 0,
    rand_scale_q14: i16 = 0,
    conc_energy: i32 = 0,
    conc_energy_shift: i32 = 0,
    prev_ltp_scale_q14: i16 = 0,
    prev_gain_q16: [2]i32 = .{ 65536, 65536 },
    fs_khz: u32 = 0,
    nb_subfr: u32 = 2,
    subfr_length: u32 = 20,
};

/// The comfort noise estimate.
pub const Cng = struct {
    exc_buf_q14: [max_frame_length]i32 = @splat(0),
    smth_nlsf_q15: [max_order]i16 = @splat(0),
    synth_state: [max_order]i32 = @splat(0),
    smth_gain_q16: i32 = 0,
    rand_seed: i32 = 0,
    fs_khz: u32 = 0,
};

fn smultt(a: i32, b: i32) i32 {
    return (a >> 16) * (b >> 16);
}

fn resetPlc(ch: *decode.Channel) void {
    ch.plc.pitch_l_q8 = @as(i32, @intCast(ch.frame_length)) << 7;
    ch.plc.prev_gain_q16 = .{ 65536, 65536 };
    ch.plc.subfr_length = 20;
    ch.plc.nb_subfr = 2;
}

fn syncPlc(ch: *decode.Channel) void {
    if (ch.fs_khz != ch.plc.fs_khz) {
        resetPlc(ch);
        ch.plc.fs_khz = ch.fs_khz;
    }
}

/// Saves what a later loss needs from a good frame.
pub fn update(ch: *decode.Channel, ctrl: *const decode.Params) void {
    syncPlc(ch);
    const st = &ch.plc;
    const nb: usize = ch.nb_subfr;
    const sub: i32 = @intCast(ch.subfr_length);
    ch.prev_signal_type = ch.indices.signal_type;
    var ltp_gain: i32 = 0;
    if (ch.indices.signal_type == type_voiced) {
        var j: usize = 0;
        while (@as(i32, @intCast(j)) * sub < ctrl.pitch_l[nb - 1] and j != nb) : (j += 1) {
            const base = (nb - 1 - j) * ltp_order;
            var temp: i32 = 0;
            for (ctrl.ltp_coef_q14[base..][0..ltp_order]) |c| temp += c;
            if (temp > ltp_gain) {
                ltp_gain = temp;
                st.ltp_coef_q14 = ctrl.ltp_coef_q14[base..][0..ltp_order].*;
                st.pitch_l_q8 = ctrl.pitch_l[nb - 1 - j] << 8;
            }
        }
        st.ltp_coef_q14 = @splat(0);
        st.ltp_coef_q14[ltp_order / 2] = @truncate(ltp_gain);
        if (ltp_gain < v_pitch_gain_start_min_q14) {
            const scale = m.div32(v_pitch_gain_start_min_q14 << 10, @max(ltp_gain, 1));
            for (&st.ltp_coef_q14) |*c| c.* = @truncate(m.smulbb(c.*, scale) >> 10);
        } else if (ltp_gain > v_pitch_gain_start_max_q14) {
            const scale = m.div32(v_pitch_gain_start_max_q14 << 14, @max(ltp_gain, 1));
            for (&st.ltp_coef_q14) |*c| c.* = @truncate(m.smulbb(c.*, scale) >> 14);
        }
    } else {
        st.pitch_l_q8 = m.smulbb(@intCast(ch.fs_khz), 18) << 8;
        st.ltp_coef_q14 = @splat(0);
    }
    const order: usize = ch.lpc_order;
    @memcpy(st.prev_lpc_q12[0..order], ctrl.pred_coef_q12[1][0..order]);
    st.prev_ltp_scale_q14 = @truncate(ctrl.ltp_scale_q14);
    st.prev_gain_q16 = .{ ctrl.gains_q16[nb - 2], ctrl.gains_q16[nb - 1] };
    st.subfr_length = ch.subfr_length;
    st.nb_subfr = ch.nb_subfr;
}

/// Makes one frame of signal from the last good frames and advances the loss counter. The
/// pitch lag of every subframe in `ctrl` becomes the lag that was used.
pub fn conceal(ch: *decode.Channel, ctrl: *decode.Params, frame: []i16) void {
    syncPlc(ch);
    const st = &ch.plc;
    const order: usize = ch.lpc_order;
    const ltp_mem: usize = ch.ltp_mem_length;
    const frame_len: usize = ch.frame_length;
    const sub: usize = ch.subfr_length;
    const nb: usize = ch.nb_subfr;
    std.debug.assert(frame.len >= frame_len);
    const prev_gain_q10 = [2]i32{ st.prev_gain_q16[0] >> 6, st.prev_gain_q16[1] >> 6 };
    // The longest lag that keeps the re-whitening window inside the history.
    const max_lag: i32 = @intCast(ltp_mem - order - 3);

    if (ch.first_frame_after_reset) st.prev_lpc_q12 = @splat(0);

    var exc_buf: [2 * 80]i16 = undefined;
    for (0..2) |k| {
        for (0..sub) |i| {
            const e = ch.exc_q14[i + (k + nb - 2) * sub];
            exc_buf[k * sub + i] = @intCast(m.sat16(m.smulww(e, prev_gain_q10[k]) >> 8));
        }
    }
    const e1 = m.sumSqrShift(exc_buf[0..sub]);
    const e2 = m.sumSqrShift(exc_buf[sub .. 2 * sub]);
    const plc_sub: i32 = @intCast(st.subfr_length);
    const plc_nb: i32 = @intCast(st.nb_subfr);
    const rand_start: usize = if ((e1.energy >> @intCast(e2.shift)) < (e2.energy >> @intCast(e1.shift)))
        @intCast(@max(0, (plc_nb - 1) * plc_sub - rand_buf_size))
    else
        @intCast(@max(0, plc_nb * plc_sub - rand_buf_size));
    const rand_src = ch.exc_q14[@min(rand_start, max_frame_length - rand_buf_size)..];

    const b = &st.ltp_coef_q14;
    var rand_scale: i32 = st.rand_scale_q14;
    const loss: usize = @intCast(@min(1, ch.loss_cnt));
    const harm_gain = harm_att_q15[loss];
    const voiced = ch.prev_signal_type == type_voiced;
    var rand_gain: i32 = if (voiced) rand_attenuate_voiced_q15[loss] else rand_attenuate_unvoiced_q15[loss];

    lpc.bwexpander(st.prev_lpc_q12[0..order], bwe_coef_q16);
    var a_q12: [max_order]i16 = st.prev_lpc_q12;

    if (ch.loss_cnt == 0) {
        rand_scale = 1 << 14;
        if (voiced) {
            for (b) |c| rand_scale = m.trunc16(rand_scale - c);
            rand_scale = @max(3277, rand_scale);
            rand_scale = m.trunc16(m.smulbb(rand_scale, st.prev_ltp_scale_q14) >> 14);
        } else {
            const inv_gain = lpc.inversePredGain(st.prev_lpc_q12[0..order]);
            var down_scale = @min((@as(i32, 1) << 30) >> log2_inv_lpc_gain_high_thres, inv_gain);
            down_scale = @max((@as(i32, 1) << 30) >> log2_inv_lpc_gain_low_thres, down_scale);
            down_scale <<= log2_inv_lpc_gain_high_thres;
            rand_gain = m.smulwb(down_scale, rand_gain) >> 14;
        }
    }

    var rand_seed = st.rand_seed;
    var lag = lagFromQ8(st.pitch_l_q8, max_lag);
    var buf_idx = ltp_mem;

    var s_ltp: [max_frame_length]i16 = @splat(0);
    var s_ltp_q14: [2 * max_frame_length]i32 = @splat(0);
    const idx0 = ltp_mem - @as(usize, @intCast(lag)) - order - ltp_order / 2;
    lpc.analysisFilter(s_ltp[idx0..ltp_mem], ch.out_buf[idx0..ltp_mem], a_q12[0..order]);
    const inv_gain_q30 = @min(m.inverse32VarQ(st.prev_gain_q16[1], 46), std.math.maxInt(i32) >> 1);
    for (idx0 + order..ltp_mem) |i| s_ltp_q14[i] = m.smulwb(inv_gain_q30, s_ltp[i]);

    for (0..nb) |_| {
        var p: usize = buf_idx - @as(usize, @intCast(lag)) + ltp_order / 2;
        for (0..sub) |_| {
            var pred: i32 = 2;
            for (0..ltp_order) |j| pred = m.smlawb(pred, s_ltp_q14[p - j], b[j]);
            p += 1;
            rand_seed = m.rand(rand_seed);
            const ri: usize = @intCast((rand_seed >> 25) & rand_buf_mask);
            s_ltp_q14[buf_idx] = m.smlawb(pred, rand_src[ri], rand_scale) << 2;
            buf_idx += 1;
        }
        for (b) |*c| c.* = m.trunc16(m.smulbb(harm_gain, c.*) >> 15);
        rand_scale = m.trunc16(m.smulbb(rand_scale, rand_gain) >> 15);
        st.pitch_l_q8 = m.smlawb(st.pitch_l_q8, st.pitch_l_q8, pitch_drift_fac_q16);
        st.pitch_l_q8 = @min(st.pitch_l_q8, m.smulbb(max_pitch_lag_ms, @intCast(ch.fs_khz)) << 8);
        lag = lagFromQ8(st.pitch_l_q8, max_lag);
    }

    const base = ltp_mem - max_order;
    s_ltp_q14[base..][0..max_order].* = ch.s_lpc_q14_buf;
    for (0..frame_len) |i| {
        var pred: i32 = @intCast(order >> 1);
        for (0..order) |j| pred = m.smlawb(pred, s_ltp_q14[base + max_order + i - 1 - j], a_q12[j]);
        const s = m.addSat32(s_ltp_q14[base + max_order + i], m.lshiftSat32(pred, 4));
        s_ltp_q14[base + max_order + i] = s;
        frame[i] = @intCast(m.sat16(m.sat16(m.rshiftRound(m.smulww(s, prev_gain_q10[1]), 8))));
    }
    ch.s_lpc_q14_buf = s_ltp_q14[base + frame_len ..][0..max_order].*;

    st.rand_seed = rand_seed;
    st.rand_scale_q14 = @truncate(rand_scale);
    ch.loss_cnt +|= 1;
    ctrl.pitch_l = @splat(lag);
}

fn lagFromQ8(pitch_l_q8: i32, max_lag: i32) i32 {
    return std.math.clamp(m.rshiftRound(pitch_l_q8, 8), 2, max_lag);
}

/// Fades in a good frame that follows concealed frames when the good frame is louder
/// (silk_PLC_glue_frames).
pub fn glueFrames(ch: *decode.Channel, frame: []i16) void {
    const st = &ch.plc;
    if (ch.loss_cnt != 0) {
        const e = m.sumSqrShift(frame);
        st.conc_energy = e.energy;
        st.conc_energy_shift = e.shift;
        st.last_frame_lost = true;
        return;
    }
    if (st.last_frame_lost) {
        const e = m.sumSqrShift(frame);
        var energy = e.energy;
        if (e.shift > st.conc_energy_shift) {
            st.conc_energy >>= @intCast(e.shift - st.conc_energy_shift);
        } else if (e.shift < st.conc_energy_shift) {
            energy >>= @intCast(st.conc_energy_shift - e.shift);
        }
        if (energy > st.conc_energy) {
            const lz = m.clz(st.conc_energy) - 1;
            st.conc_energy <<= @intCast(lz);
            energy >>= @intCast(@max(24 - lz, 0));
            const frac_q24 = m.div32(st.conc_energy, @max(energy, 1));
            var gain_q16 = m.sqrtApprox(frac_q24) << 4;
            var slope_q16 = @divTrunc((@as(i32, 1) << 16) - gain_q16, @as(i32, @intCast(frame.len)));
            slope_q16 <<= 2;
            for (frame) |*s| {
                s.* = m.trunc16(m.smulwb(gain_q16, s.*));
                gain_q16 +%= slope_q16;
                if (gain_q16 > (@as(i32, 1) << 16)) break;
            }
        }
    }
    st.last_frame_lost = false;
}

fn resetCng(ch: *decode.Channel) void {
    const cng = &ch.cng;
    const step: i32 = @divTrunc(std.math.maxInt(i16), @as(i32, @intCast(ch.lpc_order)) + 1);
    var acc: i32 = 0;
    for (cng.smth_nlsf_q15[0..ch.lpc_order]) |*v| {
        acc += step;
        v.* = @truncate(acc);
    }
    cng.smth_gain_q16 = 0;
    cng.rand_seed = 3176576;
}

/// Updates the comfort noise estimate from a good frame without voice and adds the noise to a
/// concealed frame.
pub fn applyCng(ch: *decode.Channel, ctrl: *const decode.Params, frame: []i16) void {
    const cng = &ch.cng;
    const order: usize = ch.lpc_order;
    const sub: usize = ch.subfr_length;
    const nb: usize = ch.nb_subfr;
    const length = ch.frame_length;
    if (ch.fs_khz != cng.fs_khz) {
        resetCng(ch);
        cng.fs_khz = ch.fs_khz;
    }
    if (ch.loss_cnt == 0 and ch.prev_signal_type == type_no_voice_activity) {
        for (0..order) |i| {
            const d = @as(i32, ch.prev_nlsf_q15[i]) - cng.smth_nlsf_q15[i];
            cng.smth_nlsf_q15[i] +%= @truncate(m.smulwb(d, cng_nlsf_smth_q16));
        }
        var max_gain: i32 = 0;
        var subfr: usize = 0;
        for (ctrl.gains_q16[0..nb], 0..) |g, i| {
            if (g > max_gain) {
                max_gain = g;
                subfr = i;
            }
        }
        std.mem.copyBackwards(i32, cng.exc_buf_q14[sub..][0 .. (nb - 1) * sub], cng.exc_buf_q14[0 .. (nb - 1) * sub]);
        @memcpy(cng.exc_buf_q14[0..sub], ch.exc_q14[subfr * sub ..][0..sub]);
        for (ctrl.gains_q16[0..nb]) |g| {
            cng.smth_gain_q16 +%= m.smulwb(g -% cng.smth_gain_q16, cng_gain_smth_q16);
            if (m.smulww(cng.smth_gain_q16, cng_gain_smth_threshold_q16) > g) cng.smth_gain_q16 = g;
        }
    }

    if (ch.loss_cnt == 0) {
        @memset(cng.synth_state[0..order], 0);
        return;
    }
    var gain_q16 = m.smulww(ch.plc.rand_scale_q14, ch.plc.prev_gain_q16[1]);
    if (gain_q16 >= (1 << 21) or cng.smth_gain_q16 > (1 << 23)) {
        gain_q16 = smultt(gain_q16, gain_q16);
        gain_q16 = smultt(cng.smth_gain_q16, cng.smth_gain_q16) -% (gain_q16 << 5);
        gain_q16 = m.sqrtApprox(gain_q16) << 16;
    } else {
        gain_q16 = m.smulww(gain_q16, gain_q16);
        gain_q16 = m.smulww(cng.smth_gain_q16, cng.smth_gain_q16) -% (gain_q16 << 5);
        gain_q16 = m.sqrtApprox(gain_q16) << 8;
    }
    const gain_q10 = gain_q16 >> 6;

    var sig: [max_order + max_frame_length]i32 = undefined;
    var exc_mask: i32 = cng_buf_mask_max;
    while (exc_mask > @as(i32, @intCast(length))) exc_mask >>= 1;
    var seed = cng.rand_seed;
    for (0..length) |i| {
        seed = m.rand(seed);
        sig[max_order + i] = cng.exc_buf_q14[@intCast((seed >> 24) & exc_mask)];
    }
    cng.rand_seed = seed;

    var a_q12: [max_order]i16 = undefined;
    lpc.nlsf2a(a_q12[0..order], cng.smth_nlsf_q15[0..order]);
    sig[0..max_order].* = cng.synth_state;
    for (0..length) |i| {
        var pred: i32 = @intCast(order >> 1);
        for (0..order) |j| pred = m.smlawb(pred, sig[max_order + i - 1 - j], a_q12[j]);
        sig[max_order + i] = m.addSat32(sig[max_order + i], m.lshiftSat32(pred, 4));
        const add: i16 = @intCast(m.sat16(m.rshiftRound(m.smulww(sig[max_order + i], gain_q10), 8)));
        frame[i] = m.addSat16(frame[i], add);
    }
    cng.synth_state = sig[length..][0..max_order].*;
}

const testing = std.testing;
const test_util = @import("../test_util.zig");

fn i16Of(x: u32) i16 {
    return @bitCast(@as(u16, @truncate(x)));
}

test "the approximate square root gives the libopus values" {
    const xs = [_]i32{ 0, 1, 2, 3, 100, 12345, 1 << 20, 1 << 24, 16777215, 33554432, 987654321, 2147483647, -5 };
    const want = [_]i32{ 0, 1, 1, 1, 9, 108, 1024, 4096, 4080, 5776, 31142, 46293, 0 };
    for (xs, want) |x, w| try testing.expectEqual(w, m.sqrtApprox(x));
}

test "energies are shifted to fit the libopus range" {
    const a = [_]i16{ 1, -2, 300, -4000, 32767, -32768, 17 };
    const ea = m.sumSqrShift(&a);
    try testing.expectEqual(@as(i32, 270438550), ea.energy);
    try testing.expectEqual(@as(i32, 3), ea.shift);

    var b: [320]i16 = undefined;
    var s: u32 = 12345;
    for (&b) |*v| {
        s = s *% 1664525 +% 1013904223;
        v.* = i16Of(s >> 16);
    }
    const eb = m.sumSqrShift(&b);
    try testing.expectEqual(@as(i32, 463794475), eb.energy);
    try testing.expectEqual(@as(i32, 8), eb.shift);
    const e80 = m.sumSqrShift(b[0..80]);
    try testing.expectEqual(@as(i32, 489154176), e80.energy);
    try testing.expectEqual(@as(i32, 6), e80.shift);

    const zeros: [40]i16 = @splat(0);
    const ez = m.sumSqrShift(&zeros);
    try testing.expectEqual(@as(i32, 0), ez.energy);
    try testing.expectEqual(@as(i32, 0), ez.shift);

    var full: [160]i16 = undefined;
    for (&full, 0..) |*v, i| v.* = if (i & 1 == 1) -32768 else 32767;
    const ef = m.sumSqrShift(&full);
    try testing.expectEqual(@as(i32, 335534080), ef.energy);
    try testing.expectEqual(@as(i32, 9), ef.shift);
}

fn testChannel(fs_khz: u32, nb_subfr: u32) decode.Channel {
    var ch: decode.Channel = .{};
    ch.fs_khz = fs_khz;
    ch.nb_subfr = nb_subfr;
    ch.subfr_length = 5 * fs_khz;
    ch.frame_length = nb_subfr * ch.subfr_length;
    ch.ltp_mem_length = 20 * fs_khz;
    ch.lpc_order = if (fs_khz == 16) 16 else 10;
    ch.first_frame_after_reset = false;
    return ch;
}

test "a lost frame of a fresh channel is quiet and counts the loss" {
    var ch = testChannel(16, 4);
    var ctrl: decode.Params = .{};
    var frame: [320]i16 = undefined;
    conceal(&ch, &ctrl, &frame);
    for (frame) |v| try testing.expectEqual(@as(i16, 0), v);
    try testing.expectEqual(@as(i32, 1), ch.loss_cnt);
    try testing.expectEqual(@as(u32, 16), ch.plc.fs_khz);
    // The reset lag is half a frame and drifts up by 1 percent per subframe. All subframes report
    // the last lag.
    try testing.expectEqual([4]i32{ 166, 166, 166, 166 }, ctrl.pitch_l);
}

test "concealment stays inside its buffers for any lag and history" {
    var rng: test_util.Xorshift = .{ .s = 0x51F7 };
    for (0..400) |it| {
        const fs: u32 = (2 + rng.next() % 3) * 4;
        var ch = testChannel(fs, if (it & 1 == 0) 4 else 2);
        for (&ch.out_buf) |*v| v.* = i16Of(rng.next());
        for (&ch.exc_q14) |*v| v.* = @bitCast(rng.next() >> @intCast(rng.next() % 12));
        for (&ch.s_lpc_q14_buf) |*v| v.* = @bitCast(rng.next());
        for (&ch.plc.prev_lpc_q12) |*v| v.* = i16Of(rng.next());
        ch.plc.fs_khz = fs;
        ch.plc.pitch_l_q8 = switch (it % 4) {
            0 => 0,
            1 => std.math.maxInt(i32),
            2 => std.math.minInt(i32),
            else => @bitCast(rng.next()),
        };
        ch.plc.prev_gain_q16 = .{ @bitCast(rng.next() >> 8), @bitCast(rng.next() >> 8) };
        ch.plc.rand_scale_q14 = i16Of(rng.next());
        ch.plc.prev_ltp_scale_q14 = i16Of(rng.next());
        ch.plc.ltp_coef_q14 = .{ i16Of(rng.next()), i16Of(rng.next()), i16Of(rng.next()), i16Of(rng.next()), i16Of(rng.next()) };
        ch.plc.nb_subfr = 2 + 2 * (rng.next() & 1);
        ch.plc.subfr_length = 5 * fs;
        ch.prev_signal_type = @intCast(rng.next() % 3);
        ch.loss_cnt = @intCast(rng.next() % 5);
        var ctrl: decode.Params = .{};
        var frame: [320]i16 = undefined;
        for (0..3) |_| conceal(&ch, &ctrl, &frame);
        applyCng(&ch, &ctrl, frame[0..ch.frame_length]);
        glueFrames(&ch, frame[0..ch.frame_length]);
        for (ctrl.pitch_l) |lag| try testing.expect(lag >= 2 and lag < ch.ltp_mem_length);
    }
}

test "the glue fades in a louder frame after a loss" {
    var ch = testChannel(16, 4);
    ch.loss_cnt = 1;
    var quiet: [320]i16 = @splat(10);
    glueFrames(&ch, &quiet);
    try testing.expect(ch.plc.last_frame_lost);
    ch.loss_cnt = 0;
    var loud: [320]i16 = @splat(1000);
    glueFrames(&ch, &loud);
    try testing.expect(!ch.plc.last_frame_lost);
    // The gain starts at the square root of the energy ratio and rises four times faster than a
    // linear ramp over the frame.
    try testing.expect(loud[0] < 200);
    try testing.expect(loud[0] < loud[10] and loud[10] < loud[30]);
    try testing.expectEqual(@as(i16, 1000), loud[319]);
}
