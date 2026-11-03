//! Voice activity detection of the SILK encoder, ported from libopus silk/VAD.c,
//! silk/ana_filt_bank_1.c and silk/sigm_Q15.c. libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const m = @import("macros.zig");
const st = @import("enc_state.zig");

const n_bands = st.vad_n_bands;
const tilt_weights = [n_bands]i32{ 30000, 6000, -12000, -12000 };

const sigm_lut_slope_q10 = [6]i32{ 237, 153, 73, 30, 12, 7 };
const sigm_lut_pos_q15 = [6]i32{ 16384, 23955, 28861, 31213, 32178, 32548 };
const sigm_lut_neg_q15 = [6]i32{ 16384, 8812, 3906, 1554, 589, 219 };

/// An approximation of the sigmoid for an input in Q5 and an output in Q15.
pub fn sigmQ15(in_q5_in: i32) i32 {
    var in_q5 = in_q5_in;
    if (in_q5 < 0) {
        in_q5 = -in_q5;
        if (in_q5 >= 6 * 32) return 0;
        const ind: usize = @intCast(in_q5 >> 5);
        return sigm_lut_neg_q15[ind] - m.smulbb(sigm_lut_slope_q10[ind], in_q5 & 0x1F);
    }
    if (in_q5 >= 6 * 32) return 32767;
    const ind: usize = @intCast(in_q5 >> 5);
    return sigm_lut_pos_q15[ind] + m.smulbb(sigm_lut_slope_q10[ind], in_q5 & 0x1F);
}

/// Splits the signal into two decimated bands with first order all-pass filters.
fn anaFiltBank1(in: []const i16, s: *[2]i32, out_l: []i16, out_h: []i16) void {
    const a_fb1_20: i32 = 5394 << 1;
    const a_fb1_21: i32 = -24290;
    for (0..in.len >> 1) |k| {
        var in32 = @as(i32, in[2 * k]) << 10;
        var y = in32 -% s[0];
        var x = m.smlawb(y, y, a_fb1_21);
        const out_1 = s[0] +% x;
        s[0] = in32 +% x;
        in32 = @as(i32, in[2 * k + 1]) << 10;
        y = in32 -% s[1];
        x = m.smulwb(y, a_fb1_20);
        const out_2 = s[1] +% x;
        s[1] = in32 +% x;
        out_l[k] = @intCast(m.sat16(m.rshiftRound(out_2 +% out_1, 11)));
        out_h[k] = @intCast(m.sat16(m.rshiftRound(out_2 -% out_1, 11)));
    }
}

/// Clears the detector and sets the noise levels to those of pink noise.
pub fn init(vad: *st.VadState) void {
    vad.* = .{};
    for (0..n_bands) |b| {
        vad.noise_level_bias[b] = @max(@divTrunc(50, @as(i32, @intCast(b + 1))), 1);
        vad.nl[b] = 100 * vad.noise_level_bias[b];
        vad.inv_nl[b] = m.div32(std.math.maxInt(i32), vad.nl[b]);
        vad.nrg_ratio_smth_q8[b] = 100 * 256;
    }
    vad.counter = 15;
}

fn noiseLevels(px: *const [n_bands]i32, vad: *st.VadState) void {
    var min_coef: i32 = 0;
    if (vad.counter < 1000) {
        min_coef = @divTrunc(std.math.maxInt(i16), (vad.counter >> 4) + 1);
        vad.counter += 1;
    }
    for (0..n_bands) |k| {
        var nl = vad.nl[k];
        const nrg = m.addPosSat32(px[k], vad.noise_level_bias[k]);
        const inv_nrg = m.div32(std.math.maxInt(i32), nrg);
        var coef: i32 = undefined;
        if (nrg > nl << 3) {
            coef = 1024 >> 3;
        } else if (nrg < nl) {
            coef = 1024;
        } else {
            coef = m.smulwb(m.smulww(inv_nrg, nl), 1024 << 1);
        }
        coef = @max(coef, min_coef);
        vad.inv_nl[k] = m.smlawb(vad.inv_nl[k], inv_nrg -% vad.inv_nl[k], coef);
        nl = m.div32(std.math.maxInt(i32), vad.inv_nl[k]);
        nl = @min(nl, 0x00FFFFFF);
        vad.nl[k] = nl;
    }
}

/// Estimates the speech activity of the frame in `ch.input_buf[1..]` and sets
/// `speech_activity_q8`, `input_tilt_q15` and `input_quality_bands_q15`.
pub fn getSaQ8(ch: *st.Channel) void {
    const vad = &ch.vad;
    const frame_length: usize = @intCast(ch.frame_length);
    const dec1 = frame_length >> 1;
    const dec2 = frame_length >> 2;
    var dec = frame_length >> 3;
    var x_offset: [n_bands]usize = undefined;
    x_offset[0] = 0;
    x_offset[1] = dec + dec2;
    x_offset[2] = x_offset[1] + dec;
    x_offset[3] = x_offset[2] + dec2;
    var x: [4 * st.max_frame_length / 4 + st.max_frame_length / 2 + 80]i16 = undefined;
    const pin = ch.input_buf[1..][0..frame_length];
    anaFiltBank1(pin, &vad.ana_state, x[0..dec1], x[x_offset[3]..][0..dec1]);
    var tmp: [st.max_frame_length / 2]i16 = undefined;
    @memcpy(tmp[0..dec1], x[0..dec1]);
    anaFiltBank1(tmp[0..dec1], &vad.ana_state1, x[0..dec2], x[x_offset[2]..][0..dec2]);
    @memcpy(tmp[0..dec2], x[0..dec2]);
    anaFiltBank1(tmp[0..dec2], &vad.ana_state2, x[0..dec], x[x_offset[1]..][0..dec]);

    // Differentiator on the lowest band.
    x[dec - 1] >>= 1;
    const hp_state_tmp = x[dec - 1];
    var i = dec - 1;
    while (i > 0) : (i -= 1) {
        x[i - 1] >>= 1;
        x[i] -%= x[i - 1];
    }
    x[0] -%= vad.hp_state;
    vad.hp_state = hp_state_tmp;

    var xnrg: [n_bands]i32 = undefined;
    var sum_squared: i32 = 0;
    for (0..n_bands) |b| {
        const shift: u5 = @intCast(@min(n_bands - b, n_bands - 1));
        dec = frame_length >> shift;
        const dec_subframe_length = dec >> 2;
        var dec_subframe_offset: usize = 0;
        xnrg[b] = vad.xnrg_subfr[b];
        for (0..4) |s| {
            sum_squared = 0;
            for (0..dec_subframe_length) |j| {
                const x_tmp: i32 = x[x_offset[b] + j + dec_subframe_offset] >> 3;
                sum_squared = m.smlabb(sum_squared, x_tmp, x_tmp);
            }
            if (s < 3) {
                xnrg[b] = m.addPosSat32(xnrg[b], sum_squared);
            } else {
                xnrg[b] = m.addPosSat32(xnrg[b], sum_squared >> 1);
            }
            dec_subframe_offset += dec_subframe_length;
        }
        vad.xnrg_subfr[b] = sum_squared;
    }

    noiseLevels(&xnrg, vad);

    var nrg_to_noise_ratio_q8: [n_bands]i32 = undefined;
    sum_squared = 0;
    var input_tilt: i32 = 0;
    for (0..n_bands) |b| {
        const speech_nrg = xnrg[b] -% vad.nl[b];
        if (speech_nrg > 0) {
            if (@as(u32, @bitCast(xnrg[b])) & 0xFF800000 == 0) {
                nrg_to_noise_ratio_q8[b] = m.div32(xnrg[b] << 8, vad.nl[b] + 1);
            } else {
                nrg_to_noise_ratio_q8[b] = m.div32(xnrg[b], (vad.nl[b] >> 8) + 1);
            }
            var snr_q7 = m.lin2log(nrg_to_noise_ratio_q8[b]) - 8 * 128;
            sum_squared = m.smlabb(sum_squared, snr_q7, snr_q7);
            if (speech_nrg < (1 << 20)) {
                snr_q7 = m.smulwb(m.sqrtApprox(speech_nrg) << 6, snr_q7);
            }
            input_tilt = m.smlawb(input_tilt, tilt_weights[b], snr_q7);
        } else {
            nrg_to_noise_ratio_q8[b] = 256;
        }
    }
    sum_squared = @divTrunc(sum_squared, n_bands);
    const p_snr_db_q7: i32 = @as(i16, @truncate(3 * m.sqrtApprox(sum_squared)));

    var sa_q15 = sigmQ15(m.smulwb(45000, p_snr_db_q7) - 128);
    ch.input_tilt_q15 = (sigmQ15(input_tilt) - 16384) << 1;

    var speech_nrg: i32 = 0;
    for (0..n_bands) |b| {
        speech_nrg +%= (@as(i32, @intCast(b)) + 1) * ((xnrg[b] -% vad.nl[b]) >> 4);
    }
    if (ch.frame_length == 20 * ch.fs_khz) speech_nrg >>= 1;
    if (speech_nrg <= 0) {
        sa_q15 >>= 1;
    } else if (speech_nrg < 16384) {
        speech_nrg <<= 16;
        speech_nrg = m.sqrtApprox(speech_nrg);
        sa_q15 = m.smulwb(32768 + speech_nrg, sa_q15);
    }
    ch.speech_activity_q8 = @min(sa_q15 >> 7, 255);

    var smooth_coef_q16 = m.smulwb(4096, m.smulwb(sa_q15, sa_q15));
    if (ch.frame_length == 10 * ch.fs_khz) smooth_coef_q16 >>= 1;
    for (0..n_bands) |b| {
        vad.nrg_ratio_smth_q8[b] = m.smlawb(vad.nrg_ratio_smth_q8[b], nrg_to_noise_ratio_q8[b] - vad.nrg_ratio_smth_q8[b], smooth_coef_q16);
        const snr_q7 = 3 * (m.lin2log(vad.nrg_ratio_smth_q8[b]) - 8 * 128);
        ch.input_quality_bands_q15[b] = sigmQ15((snr_q7 - 16 * 128) >> 4);
    }
}

const testing = std.testing;

test "the sigmoid approximation covers its range" {
    try testing.expectEqual(@as(i32, 16384), sigmQ15(0));
    try testing.expectEqual(@as(i32, 32767), sigmQ15(1000));
    try testing.expectEqual(@as(i32, 0), sigmQ15(-1000));
    try testing.expect(sigmQ15(10) > sigmQ15(-10));
}

test "a loud tone is active and silence is not" {
    var ch: st.Channel = .{};
    init(&ch.vad);
    ch.fs_khz = 16;
    ch.frame_length = 320;
    for (0..30) |_| {
        for (ch.input_buf[1..321], 0..) |*v, i| v.* = @intCast(@as(i32, @intFromFloat(8000 * @sin(@as(f32, @floatFromInt(i)) * 0.3))));
        getSaQ8(&ch);
    }
    try testing.expect(ch.speech_activity_q8 > 100);
    var quiet: st.Channel = .{};
    init(&quiet.vad);
    quiet.fs_khz = 16;
    quiet.frame_length = 320;
    for (0..30) |_| {
        @memset(&quiet.input_buf, 0);
        getSaQ8(&quiet);
    }
    try testing.expect(quiet.speech_activity_q8 < 12);
}
