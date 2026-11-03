//! The SILK encoder, ported from libopus silk/enc_API.c, control_codec.c, control_SNR.c,
//! control_audio_bandwidth.c, init_encoder.c, HP_variable_cutoff.c, LP_variable_cutoff.c,
//! biquad_alt.c and silk/float/encode_frame_FLP.c. libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const m = @import("macros.zig");
const range = @import("../range.zig");
const tables = @import("tables.zig");
const enc_tables = @import("enc_tables.zig");
const nlsf = @import("nlsf.zig");
const flp = @import("flp.zig");
const st = @import("enc_state.zig");
const vad = @import("vad.zig");
const resampler = @import("resampler.zig");
const enc_resampler = @import("enc_resampler.zig");
const pitch_enc = @import("pitch_enc.zig");
const pred_enc = @import("pred_enc.zig");
const shape_enc = @import("shape_enc.zig");
const nsq_mod = @import("nsq.zig");
const indices_enc = @import("indices_enc.zig");
const stereo_enc = @import("stereo_enc.zig");

pub const Channel = st.Channel;
pub const EncControl = st.EncControl;
pub const Activity = st.Activity;

pub const Error = error{ InvalidControl, InvalidInput };

const transition_frames = 256;
const transition_int_num = 5;
const bitreservoir_decay_time_ms = 500;
const variable_hp_min_cutoff_hz = 60;
const variable_hp_max_cutoff_hz = 100;
const speech_activity_dtx_thres_q8 = 13;
const max_bandwidth_switch_delay_ms = 5000;

/// The scratch buffers of the encoder. They hold no state between packets.
pub const Scratch = struct {
    pitch: pitch_enc.Scratch,
    nsq: nsq_mod.Scratch,
    stereo: stereo_enc.Scratch,
    res_pitch: [2 * st.max_frame_length + st.la_pitch_max]f32,
    nsq_copy: [2]st.NsqState,
    nsq_lbrr: st.NsqState,
    ec_buf_copy: [1275]u8,
};

pub const Encoder = struct {
    stereo: st.StereoEncState = .{},
    n_bits_used_lbrr: i32 = 0,
    n_bits_exceeded: i32 = 0,
    n_channels_api: i32 = 1,
    n_channels_internal: i32 = 1,
    n_prev_channels_internal: i32 = 0,
    time_since_switch_allowed_ms: i32 = 0,
    allow_bandwidth_switch: bool = false,
    prev_decode_only_middle: i32 = 0,
    channels: [2]st.Channel = .{ .{}, .{} },
    scratch: Scratch = undefined,

    /// Clears the state as silk_InitEncoder does for `channels` channels.
    pub fn reset(self: *Encoder, channels: usize) void {
        self.stereo = .{};
        self.n_bits_used_lbrr = 0;
        self.n_bits_exceeded = 0;
        self.n_prev_channels_internal = 0;
        self.time_since_switch_allowed_ms = 0;
        self.allow_bandwidth_switch = false;
        self.prev_decode_only_middle = 0;
        for (0..channels) |n| initChannel(&self.channels[n]);
        self.n_channels_api = 1;
        self.n_channels_internal = 1;
    }
};

/// Initializes the state of one channel (silk_init_encoder).
pub fn initChannel(ch: *st.Channel) void {
    ch.* = .{};
    ch.variable_hp_smth1_q15 = (m.lin2log(variable_hp_min_cutoff_hz << 16) - (16 << 7)) << 8;
    ch.variable_hp_smth2_q15 = ch.variable_hp_smth1_q15;
    ch.first_frame_after_reset = true;
    vad.init(&ch.vad);
}

fn res2int16(x: f32) i32 {
    var v = x * 32768.0;
    v = if (v > -32768.0) v else -32768.0;
    v = if (v < 32767.0) v else 32767.0;
    return flp.float2int(v);
}

// Bandwidth control.

fn controlAudioBandwidth(ch: *st.Channel, ctl: *EncControl) i32 {
    var orig_khz = ch.fs_khz;
    if (orig_khz == 0) orig_khz = ch.lp.saved_fs_khz;
    var fs_khz = orig_khz;
    var fs_hz = fs_khz * 1000;
    if (fs_hz == 0) {
        fs_hz = @min(ch.desired_internal_fs_hz, ch.api_fs_hz);
        fs_khz = @divTrunc(fs_hz, 1000);
    } else if (fs_hz > ch.api_fs_hz or fs_hz > ch.max_internal_fs_hz or fs_hz < ch.min_internal_fs_hz) {
        fs_hz = ch.api_fs_hz;
        fs_hz = @min(fs_hz, ch.max_internal_fs_hz);
        fs_hz = @max(fs_hz, ch.min_internal_fs_hz);
        fs_khz = @divTrunc(fs_hz, 1000);
    } else {
        if (ch.lp.transition_frame_no >= transition_frames) ch.lp.mode = 0;
        if (ch.allow_bandwidth_switch or ctl.opus_can_switch) {
            if (orig_khz * 1000 > ch.desired_internal_fs_hz) {
                if (ch.lp.mode == 0) {
                    ch.lp.transition_frame_no = transition_frames;
                    ch.lp.in_lp_state = .{ 0, 0 };
                }
                if (ctl.opus_can_switch) {
                    ch.lp.mode = 0;
                    fs_khz = if (orig_khz == 16) 12 else 8;
                } else {
                    if (ch.lp.transition_frame_no <= 0) {
                        ctl.switch_ready = true;
                        ctl.max_bits -= @divTrunc(ctl.max_bits * 5, ctl.payload_size_ms + 5);
                    } else {
                        ch.lp.mode = -2;
                    }
                }
            } else if (orig_khz * 1000 < ch.desired_internal_fs_hz) {
                if (ctl.opus_can_switch) {
                    fs_khz = if (orig_khz == 8) 12 else 16;
                    ch.lp.transition_frame_no = 0;
                    ch.lp.in_lp_state = .{ 0, 0 };
                    ch.lp.mode = 1;
                } else {
                    if (ch.lp.mode == 0) {
                        ctl.switch_ready = true;
                        ctl.max_bits -= @divTrunc(ctl.max_bits * 5, ctl.payload_size_ms + 5);
                    } else {
                        ch.lp.mode = 1;
                    }
                }
            } else {
                if (ch.lp.mode < 0) ch.lp.mode = 1;
            }
        }
    }
    return fs_khz;
}

/// Sets the SNR of the quantizer from the target rate.
fn controlSnr(ch: *st.Channel, target_rate_bps_in: i32) void {
    ch.target_rate_bps = target_rate_bps_in;
    var target_rate_bps = target_rate_bps_in;
    if (ch.nb_subfr == 2) target_rate_bps -= 2000 + @divTrunc(ch.fs_khz, 16);
    const table: []const u8 = switch (ch.fs_khz) {
        8 => &enc_tables.target_rate_nb_21,
        12 => &enc_tables.target_rate_mb_21,
        else => &enc_tables.target_rate_wb_21,
    };
    var id = @divTrunc(target_rate_bps + 200, 400);
    id = @min(id - 10, @as(i32, @intCast(table.len)) - 1);
    if (id <= 0) {
        ch.snr_db_q7 = 0;
    } else {
        ch.snr_db_q7 = @as(i32, table[@intCast(id)]) * 21;
    }
}

// Variable filters.

fn biquadAltStride1(input: []const i16, b_q28: *const [3]i32, a_q28: *const [2]i32, s: *[2]i32, out: []i16) void {
    const a0_l_q28 = (0 -% a_q28[0]) & 0x00003FFF;
    const a0_u_q28 = (0 -% a_q28[0]) >> 14;
    const a1_l_q28 = (0 -% a_q28[1]) & 0x00003FFF;
    const a1_u_q28 = (0 -% a_q28[1]) >> 14;
    for (input, out) |sample, *o| {
        const inval: i32 = sample;
        const out32_q14 = m.smlawb(s[0], b_q28[0], inval) << 2;
        s[0] = s[1] +% m.rshiftRound(m.smulwb(out32_q14, a0_l_q28), 14);
        s[0] = m.smlawb(s[0], out32_q14, a0_u_q28);
        s[0] = m.smlawb(s[0], b_q28[1], inval);
        s[1] = m.rshiftRound(m.smulwb(out32_q14, a1_l_q28), 14);
        s[1] = m.smlawb(s[1], out32_q14, a1_u_q28);
        s[1] = m.smlawb(s[1], b_q28[2], inval);
        o.* = @intCast(m.sat16((out32_q14 +% (1 << 14) -% 1) >> 14));
    }
}

fn lpInterpolateFilterTaps(b_q28: *[3]i32, a_q28: *[2]i32, ind: usize, fac_q16: i32) void {
    const tb = &enc_tables.transition_lp_b_q28;
    const ta = &enc_tables.transition_lp_a_q28;
    if (ind < transition_int_num - 1) {
        if (fac_q16 > 0) {
            if (fac_q16 < 32768) {
                for (0..3) |nb| b_q28[nb] = m.smlawb(tb[ind * 3 + nb], tb[(ind + 1) * 3 + nb] - tb[ind * 3 + nb], fac_q16);
                for (0..2) |na| a_q28[na] = m.smlawb(ta[ind * 2 + na], ta[(ind + 1) * 2 + na] - ta[ind * 2 + na], fac_q16);
            } else {
                for (0..3) |nb| b_q28[nb] = m.smlawb(tb[(ind + 1) * 3 + nb], tb[(ind + 1) * 3 + nb] - tb[ind * 3 + nb], fac_q16 - (1 << 16));
                for (0..2) |na| a_q28[na] = m.smlawb(ta[(ind + 1) * 2 + na], ta[(ind + 1) * 2 + na] - ta[ind * 2 + na], fac_q16 - (1 << 16));
            }
        } else {
            b_q28.* = tb[ind * 3 ..][0..3].*;
            a_q28.* = ta[ind * 2 ..][0..2].*;
        }
    } else {
        b_q28.* = tb[(transition_int_num - 1) * 3 ..][0..3].*;
        a_q28.* = ta[(transition_int_num - 1) * 2 ..][0..2].*;
    }
}

/// Low pass filter with a cut off that moves during a bandwidth switch.
fn lpVariableCutoff(lp: *st.LpState, frame: []i16) void {
    if (lp.mode == 0) return;
    var fac_q16: i32 = (transition_frames - lp.transition_frame_no) << (16 - 6);
    const ind: usize = @intCast(fac_q16 >> 16);
    fac_q16 -= @as(i32, @intCast(ind)) << 16;
    var b_q28: [3]i32 = undefined;
    var a_q28: [2]i32 = undefined;
    lpInterpolateFilterTaps(&b_q28, &a_q28, ind, fac_q16);
    lp.transition_frame_no = std.math.clamp(lp.transition_frame_no + lp.mode, 0, transition_frames);
    biquadAltStride1(frame, &b_q28, &a_q28, &lp.in_lp_state, frame);
}

/// Adapts the cut off of the high pass filter to the pitch of the speaker.
fn hpVariableCutoff(ch: *st.Channel) void {
    if (ch.prev_signal_type != st.type_voiced) return;
    const pitch_freq_hz_q16 = @divTrunc((ch.fs_khz * 1000) << 16, ch.prev_lag);
    var pitch_freq_log_q7 = m.lin2log(pitch_freq_hz_q16) - (16 << 7);
    const quality_q15 = ch.input_quality_bands_q15[0];
    const min_cutoff_log_q7 = m.lin2log(variable_hp_min_cutoff_hz << 16) - (16 << 7);
    pitch_freq_log_q7 = m.smlawb(pitch_freq_log_q7, m.smulwb((-quality_q15) << 2, quality_q15), pitch_freq_log_q7 - min_cutoff_log_q7);
    var delta_freq_q7 = pitch_freq_log_q7 - (ch.variable_hp_smth1_q15 >> 8);
    if (delta_freq_q7 < 0) delta_freq_q7 *= 3;
    delta_freq_q7 = m.limit(delta_freq_q7, -51, 51);
    ch.variable_hp_smth1_q15 = m.smlawb(ch.variable_hp_smth1_q15, m.smulbb(ch.speech_activity_q8, delta_freq_q7), 6554);
    ch.variable_hp_smth1_q15 = m.limit(ch.variable_hp_smth1_q15, m.lin2log(variable_hp_min_cutoff_hz) << 8, m.lin2log(variable_hp_max_cutoff_hz) << 8);
}

// Control of the state by the packet settings.

fn setupResamplers(ch: *st.Channel, fs_khz: i32) void {
    if (ch.fs_khz != fs_khz or ch.prev_api_fs_hz != ch.api_fs_hz) {
        if (ch.fs_khz == 0) {
            ch.resampler = enc_resampler.DownResampler.init(@divTrunc(ch.api_fs_hz, 1000), fs_khz);
        } else {
            const buf_length_ms: usize = @intCast((ch.nb_subfr * 5 << 1) + st.la_shape_ms);
            const old_khz: usize = @intCast(ch.fs_khz);
            const new_khz: usize = @intCast(fs_khz);
            const old_buf_samples = buf_length_ms * old_khz;
            const new_buf_samples = buf_length_ms * new_khz;
            const api_khz: usize = @intCast(@divTrunc(ch.api_fs_hz, 1000));
            const api_buf_samples = buf_length_ms * api_khz;
            var x_buf_fix: [45 * 16]i16 = undefined;
            var x_buf_api: [45 * 48]i16 = undefined;
            for (0..old_buf_samples) |i| x_buf_fix[i] = flp.float2short(ch.x_buf[i]);
            var temp = resampler.Resampler.initTo(@intCast(old_khz), @intCast(api_khz));
            temp.process(x_buf_api[0..api_buf_samples], x_buf_fix[0..old_buf_samples]);
            ch.resampler = enc_resampler.DownResampler.init(@divTrunc(ch.api_fs_hz, 1000), fs_khz);
            ch.resampler.process(x_buf_fix[0..new_buf_samples], x_buf_api[0..api_buf_samples]);
            for (0..new_buf_samples) |i| ch.x_buf[i] = @floatFromInt(x_buf_fix[i]);
        }
    }
    ch.prev_api_fs_hz = ch.api_fs_hz;
}

fn setupFs(ch: *st.Channel, fs_khz: i32, packet_size_ms: i32) void {
    if (packet_size_ms != ch.packet_size_ms) {
        if (packet_size_ms <= 10) {
            ch.n_frames_per_packet = 1;
            ch.nb_subfr = if (packet_size_ms == 10) 2 else 1;
            ch.frame_length = packet_size_ms * fs_khz;
            ch.pitch_lpc_win_length = (10 + (st.la_pitch_max / 16 << 1)) * fs_khz;
            ch.pitch_contour_icdf = if (ch.fs_khz == 8) &tables.pitch_contour_10_ms_nb_icdf else &tables.pitch_contour_10_ms_icdf;
        } else {
            ch.n_frames_per_packet = @divTrunc(packet_size_ms, 20);
            ch.nb_subfr = st.max_subfr;
            ch.frame_length = 20 * fs_khz;
            ch.pitch_lpc_win_length = (20 + (st.la_pitch_max / 16 << 1)) * fs_khz;
            ch.pitch_contour_icdf = if (ch.fs_khz == 8) &tables.pitch_contour_nb_icdf else &tables.pitch_contour_icdf;
        }
        ch.packet_size_ms = packet_size_ms;
        ch.target_rate_bps = 0;
    }
    if (ch.fs_khz != fs_khz) {
        ch.harm_shape_gain_smth = 0;
        ch.tilt_smth = 0;
        ch.last_gain_index = 0;
        ch.nsq = .{};
        ch.prev_nlsfq_q15 = @splat(0);
        ch.lp.in_lp_state = .{ 0, 0 };
        ch.input_buf_ix = 0;
        ch.n_frames_encoded = 0;
        ch.target_rate_bps = 0;

        ch.prev_lag = 100;
        ch.first_frame_after_reset = true;
        ch.last_gain_index = 10;
        ch.nsq.lag_prev = 100;
        ch.nsq.prev_gain_q16 = 65536;
        ch.prev_signal_type = st.type_no_voice_activity;

        ch.fs_khz = fs_khz;
        if (ch.fs_khz == 8) {
            ch.pitch_contour_icdf = if (ch.nb_subfr == st.max_subfr) &tables.pitch_contour_nb_icdf else &tables.pitch_contour_10_ms_nb_icdf;
        } else {
            ch.pitch_contour_icdf = if (ch.nb_subfr == st.max_subfr) &tables.pitch_contour_icdf else &tables.pitch_contour_10_ms_icdf;
        }
        if (ch.fs_khz == 8 or ch.fs_khz == 12) {
            ch.predict_lpc_order = 10;
            ch.nlsf_cb = &nlsf.nb_mb;
        } else {
            ch.predict_lpc_order = 16;
            ch.nlsf_cb = &nlsf.wb;
        }
        ch.subfr_length = 5 * fs_khz;
        ch.frame_length = ch.subfr_length * ch.nb_subfr;
        ch.ltp_mem_length = 20 * fs_khz;
        ch.la_pitch = 2 * fs_khz;
        ch.max_pitch_lag = 18 * fs_khz;
        if (ch.nb_subfr == st.max_subfr) {
            ch.pitch_lpc_win_length = (20 + 4) * fs_khz;
        } else {
            ch.pitch_lpc_win_length = (10 + 4) * fs_khz;
        }
        ch.pitch_lag_low_bits_icdf = switch (ch.fs_khz) {
            16 => &tables.uniform8_icdf,
            12 => &tables.uniform6_icdf,
            else => &tables.uniform4_icdf,
        };
    }
}

fn setupComplexity(ch: *st.Channel, complexity: i32) void {
    const warping_mult: i32 = 983;
    if (complexity < 1) {
        ch.pitch_estimation_complexity = 0;
        ch.pitch_estimation_threshold_q16 = 52429;
        ch.pitch_estimation_lpc_order = 6;
        ch.shaping_lpc_order = 12;
        ch.la_shape = 3 * ch.fs_khz;
        ch.n_states_delayed_decision = 1;
        ch.use_interpolated_nlsfs = false;
        ch.nlsf_msvq_survivors = 2;
        ch.warping_q16 = 0;
    } else if (complexity < 2) {
        ch.pitch_estimation_complexity = 1;
        ch.pitch_estimation_threshold_q16 = 49807;
        ch.pitch_estimation_lpc_order = 8;
        ch.shaping_lpc_order = 14;
        ch.la_shape = 5 * ch.fs_khz;
        ch.n_states_delayed_decision = 1;
        ch.use_interpolated_nlsfs = false;
        ch.nlsf_msvq_survivors = 3;
        ch.warping_q16 = 0;
    } else if (complexity < 3) {
        ch.pitch_estimation_complexity = 0;
        ch.pitch_estimation_threshold_q16 = 52429;
        ch.pitch_estimation_lpc_order = 6;
        ch.shaping_lpc_order = 12;
        ch.la_shape = 3 * ch.fs_khz;
        ch.n_states_delayed_decision = 2;
        ch.use_interpolated_nlsfs = false;
        ch.nlsf_msvq_survivors = 2;
        ch.warping_q16 = 0;
    } else if (complexity < 4) {
        ch.pitch_estimation_complexity = 1;
        ch.pitch_estimation_threshold_q16 = 49807;
        ch.pitch_estimation_lpc_order = 8;
        ch.shaping_lpc_order = 14;
        ch.la_shape = 5 * ch.fs_khz;
        ch.n_states_delayed_decision = 2;
        ch.use_interpolated_nlsfs = false;
        ch.nlsf_msvq_survivors = 4;
        ch.warping_q16 = 0;
    } else if (complexity < 6) {
        ch.pitch_estimation_complexity = 1;
        ch.pitch_estimation_threshold_q16 = 48497;
        ch.pitch_estimation_lpc_order = 10;
        ch.shaping_lpc_order = 16;
        ch.la_shape = 5 * ch.fs_khz;
        ch.n_states_delayed_decision = 2;
        ch.use_interpolated_nlsfs = true;
        ch.nlsf_msvq_survivors = 6;
        ch.warping_q16 = ch.fs_khz * warping_mult;
    } else if (complexity < 8) {
        ch.pitch_estimation_complexity = 1;
        ch.pitch_estimation_threshold_q16 = 47186;
        ch.pitch_estimation_lpc_order = 12;
        ch.shaping_lpc_order = 20;
        ch.la_shape = 5 * ch.fs_khz;
        ch.n_states_delayed_decision = 3;
        ch.use_interpolated_nlsfs = true;
        ch.nlsf_msvq_survivors = 8;
        ch.warping_q16 = ch.fs_khz * warping_mult;
    } else {
        ch.pitch_estimation_complexity = 2;
        ch.pitch_estimation_threshold_q16 = 45875;
        ch.pitch_estimation_lpc_order = 16;
        ch.shaping_lpc_order = 24;
        ch.la_shape = 5 * ch.fs_khz;
        ch.n_states_delayed_decision = st.max_del_dec_states;
        ch.use_interpolated_nlsfs = true;
        ch.nlsf_msvq_survivors = 16;
        ch.warping_q16 = ch.fs_khz * warping_mult;
    }
    ch.pitch_estimation_lpc_order = @min(ch.pitch_estimation_lpc_order, ch.predict_lpc_order);
    ch.shape_win_length = 5 * ch.fs_khz + 2 * ch.la_shape;
    ch.complexity = complexity;
}

fn setupLbrr(ch: *st.Channel, ctl: *const EncControl) void {
    const in_previous_packet = ch.lbrr_enabled;
    ch.lbrr_enabled = ctl.lbrr_coded;
    if (ch.lbrr_enabled) {
        if (!in_previous_packet) {
            ch.lbrr_gain_increases = 7;
        } else {
            ch.lbrr_gain_increases = @max(7 - m.smulwb(ch.packet_loss_perc, 13107), 3);
        }
    }
}

fn controlEncoder(ch: *st.Channel, ctl: *EncControl, allow_bw_switch: bool, channel_nb: i32, force_fs_khz: i32) void {
    ch.use_dtx = ctl.use_dtx;
    ch.use_cbr = ctl.use_cbr;
    ch.api_fs_hz = ctl.api_sample_rate;
    ch.max_internal_fs_hz = ctl.max_internal_sample_rate;
    ch.min_internal_fs_hz = ctl.min_internal_sample_rate;
    ch.desired_internal_fs_hz = ctl.desired_internal_sample_rate;
    ch.use_inband_fec = ctl.use_in_band_fec;
    ch.n_channels_api = ctl.n_channels_api;
    ch.n_channels_internal = ctl.n_channels_internal;
    ch.allow_bandwidth_switch = allow_bw_switch;
    ch.channel_nb = channel_nb;

    if (ch.controlled_since_last_payload and !ch.prefill_flag) {
        if (ch.api_fs_hz != ch.prev_api_fs_hz and ch.fs_khz > 0) setupResamplers(ch, ch.fs_khz);
        return;
    }
    var fs_khz = controlAudioBandwidth(ch, ctl);
    if (force_fs_khz != 0) fs_khz = force_fs_khz;
    setupResamplers(ch, fs_khz);
    setupFs(ch, fs_khz, ctl.payload_size_ms);
    setupComplexity(ch, ctl.complexity);
    ch.packet_loss_perc = ctl.packet_loss_percentage;
    setupLbrr(ch, ctl);
    ch.controlled_since_last_payload = true;
}

// Coding of a frame.

fn doVad(ch: *st.Channel, activity: Activity) void {
    vad.getSaQ8(ch);
    if (activity == .no_activity and ch.speech_activity_q8 >= speech_activity_dtx_thres_q8) {
        ch.speech_activity_q8 = speech_activity_dtx_thres_q8 - 1;
    }
    if (ch.speech_activity_q8 < speech_activity_dtx_thres_q8) {
        ch.indices.signal_type = st.type_no_voice_activity;
        ch.no_speech_counter += 1;
        if (ch.no_speech_counter <= 10) {
            ch.in_dtx = false;
        } else if (ch.no_speech_counter > 20 + 10) {
            ch.no_speech_counter = 10;
            ch.in_dtx = false;
        }
        ch.vad_flags[@intCast(ch.n_frames_encoded)] = 0;
    } else {
        ch.no_speech_counter = 0;
        ch.in_dtx = false;
        ch.indices.signal_type = st.type_unvoiced;
        ch.vad_flags[@intCast(ch.n_frames_encoded)] = 1;
    }
}

/// Runs the quantizer on the frame with the parameters found by the analysis.
fn nsqWrapper(ch: *st.Channel, ctrl: *const st.Control, indices: *st.Indices, nsq: *st.NsqState, pulses: []i8, x: []const f32, sc: *nsq_mod.Scratch) void {
    const nb_subfr: usize = @intCast(ch.nb_subfr);
    const order: usize = @intCast(ch.predict_lpc_order);
    var ar_q13: [st.max_subfr * st.max_shape_lpc_order]i16 = undefined;
    var lf_shp_q14: [st.max_subfr]i32 = undefined;
    var tilt_q14: [st.max_subfr]i32 = undefined;
    var harm_shape_gain_q14: [st.max_subfr]i32 = undefined;
    var ltp_coef_q14: [st.ltp_order * st.max_subfr]i16 = undefined;
    var pred_coef_q12: [2][st.max_lpc_order]i16 = @splat(@splat(0));
    var gains_q16: [st.max_subfr]i32 = undefined;
    var x16: [st.max_frame_length]i16 = undefined;
    for (0..nb_subfr) |i| {
        for (0..@as(usize, @intCast(ch.shaping_lpc_order))) |j| {
            ar_q13[i * st.max_shape_lpc_order + j] = @truncate(flp.float2int(ctrl.ar[i * st.max_shape_lpc_order + j] * 8192.0));
        }
    }
    for (0..nb_subfr) |i| {
        const ar = flp.float2int(ctrl.lf_ar_shp[i] * 16384.0);
        const ma = flp.float2int(ctrl.lf_ma_shp[i] * 16384.0);
        lf_shp_q14[i] = (ar << 16) | @as(i32, @as(u16, @truncate(@as(u32, @bitCast(ma)))));
        tilt_q14[i] = flp.float2int(ctrl.tilt[i] * 16384.0);
        harm_shape_gain_q14[i] = flp.float2int(ctrl.harm_shape_gain[i] * 16384.0);
    }
    const lambda_q10 = flp.float2int(ctrl.lambda * 1024.0);
    for (0..nb_subfr * st.ltp_order) |i| ltp_coef_q14[i] = @truncate(flp.float2int(ctrl.ltp_coef[i] * 16384.0));
    for (0..2) |j| {
        for (0..order) |i| pred_coef_q12[j][i] = @truncate(flp.float2int(ctrl.pred_coef[j][i] * 4096.0));
    }
    for (0..nb_subfr) |i| gains_q16[i] = flp.float2int(ctrl.gains[i] * 65536.0);
    const ltp_scale_q14: i32 = if (indices.signal_type == st.type_voiced) tables.ltp_scales_table_q14[@intCast(indices.ltp_scale_index)] else 0;
    const frame_length: usize = @intCast(ch.frame_length);
    for (0..frame_length) |i| x16[i] = @truncate(flp.float2int(x[i]));

    const p: nsq_mod.Params = .{
        .ltp_mem_length = ch.ltp_mem_length,
        .frame_length = ch.frame_length,
        .subfr_length = ch.subfr_length,
        .nb_subfr = ch.nb_subfr,
        .predict_lpc_order = ch.predict_lpc_order,
        .shaping_lpc_order = ch.shaping_lpc_order,
        .n_states_delayed_decision = ch.n_states_delayed_decision,
        .warping_q16 = ch.warping_q16,
    };
    const in: nsq_mod.Input = .{
        .x16 = &x16,
        .pred_coef_q12 = &pred_coef_q12,
        .ltp_coef_q14 = &ltp_coef_q14,
        .ar_q13 = &ar_q13,
        .harm_shape_gain_q14 = &harm_shape_gain_q14,
        .tilt_q14 = &tilt_q14,
        .lf_shp_q14 = &lf_shp_q14,
        .gains_q16 = &gains_q16,
        .pitch_l = &ctrl.pitch_l,
        .lambda_q10 = lambda_q10,
        .ltp_scale_q14 = ltp_scale_q14,
    };
    if (ch.n_states_delayed_decision > 1 or ch.warping_q16 > 0) {
        nsq_mod.nsqDelDec(p, sc, nsq, indices, in, pulses);
    } else {
        nsq_mod.nsqSingle(p, sc, nsq, indices, in, pulses);
    }
}

/// Encodes the frame again at a lower rate for the next packet as redundancy.
fn lbrrEncode(ch: *st.Channel, ctrl: *st.Control, x: []const f32, cond: st.Cond, sc: *Scratch) void {
    if (!(ch.lbrr_enabled and ch.speech_activity_q8 > 77)) return;
    const frame_idx: usize = @intCast(ch.n_frames_encoded);
    const indices_lbrr = &ch.indices_lbrr[frame_idx];
    ch.lbrr_flags[frame_idx] = 1;
    sc.nsq_lbrr = ch.nsq;
    indices_lbrr.* = ch.indices;
    const nb_subfr: usize = @intCast(ch.nb_subfr);
    var temp_gains: [st.max_subfr]f32 = undefined;
    @memcpy(temp_gains[0..nb_subfr], ctrl.gains[0..nb_subfr]);
    if (frame_idx == 0 or ch.lbrr_flags[frame_idx - 1] == 0) {
        ch.lbrr_prev_last_gain_index = ch.last_gain_index;
        indices_lbrr.gains[0] += @intCast(ch.lbrr_gain_increases);
        indices_lbrr.gains[0] = @min(indices_lbrr.gains[0], 63);
    }
    var gains_q16: [st.max_subfr]i32 = undefined;
    shape_enc.gainsDequant(&gains_q16, &indices_lbrr.gains, &ch.lbrr_prev_last_gain_index, cond == .conditionally, nb_subfr);
    for (0..nb_subfr) |k| ctrl.gains[k] = @as(f32, @floatFromInt(gains_q16[k])) * (1.0 / 65536.0);
    nsqWrapper(ch, ctrl, indices_lbrr, &sc.nsq_lbrr, &ch.pulses_lbrr[frame_idx], x, &sc.nsq);
    @memcpy(ctrl.gains[0..nb_subfr], temp_gains[0..nb_subfr]);
}

/// Encodes one frame. Returns the number of bytes of the payload so far in `n_bytes_out`.
fn encodeFrame(ch: *st.Channel, sc: *Scratch, n_bytes_out: *i32, enc: ?*range.Encoder, cond: st.Cond, max_bits: i32, use_cbr: bool) void {
    var ctrl: st.Control = .{};
    ch.indices.seed = @intCast(ch.frame_counter & 3);
    ch.frame_counter += 1;
    const ltp_mem: usize = @intCast(ch.ltp_mem_length);
    const frame_length: usize = @intCast(ch.frame_length);
    const x_off = ltp_mem;
    const bits_margin: i32 = if (use_cbr) 5 else @divTrunc(max_bits, 4);

    lpVariableCutoff(&ch.lp, ch.input_buf[1..][0..frame_length]);
    const new_off = x_off + @as(usize, @intCast(st.la_shape_ms * ch.fs_khz));
    for (0..frame_length) |i| ch.x_buf[new_off + i] = @floatFromInt(ch.input_buf[1 + i]);
    for (0..8) |i| {
        const sign: f32 = @floatFromInt(1 - @as(i32, @intCast(i & 2)));
        ch.x_buf[new_off + i * (frame_length >> 3)] += sign * 1e-6;
    }

    if (!ch.prefill_flag) {
        const rc = enc.?;
        pitch_enc.findPitchLags(&sc.pitch, ch, &ctrl, &sc.res_pitch);
        shape_enc.noiseShapeAnalysis(ch, &ctrl, &sc.res_pitch, ltp_mem, &ch.x_buf, x_off);
        pred_enc.findPredCoefs(ch, &ctrl, &sc.res_pitch, ltp_mem, &ch.x_buf, x_off, cond);
        shape_enc.processGains(ch, &ctrl, cond);
        lbrrEncode(ch, &ctrl, ch.x_buf[x_off..], cond, sc);

        const nb_subfr: usize = @intCast(ch.nb_subfr);
        const max_iter = 6;
        var gain_mult_q8: i16 = 256;
        var found_lower = false;
        var found_upper = false;
        var gains_id = shape_enc.gainsId(&ch.indices.gains, nb_subfr);
        var gains_id_lower: i32 = -1;
        var gains_id_upper: i32 = -1;
        const rc_copy = rc.*;
        var rc_copy2: range.Encoder = undefined;
        sc.nsq_copy[0] = ch.nsq;
        const seed_copy = ch.indices.seed;
        const ec_prev_lag_index_copy = ch.ec_prev_lag_index;
        const ec_prev_signal_type_copy = ch.ec_prev_signal_type;
        var n_bits: i32 = 0;
        var n_bits_lower: i32 = 0;
        var n_bits_upper: i32 = 0;
        var gain_mult_lower: i32 = 0;
        var gain_mult_upper: i32 = 0;
        var last_gain_index_copy2: i8 = 0;
        var gain_lock: [st.max_subfr]bool = @splat(false);
        var best_gain_mult: [st.max_subfr]i16 = @splat(0);
        var best_sum: [st.max_subfr]i32 = @splat(0);
        var iter: i32 = 0;
        while (true) : (iter += 1) {
            if (gains_id == gains_id_lower) {
                n_bits = n_bits_lower;
            } else if (gains_id == gains_id_upper) {
                n_bits = n_bits_upper;
            } else {
                if (iter > 0) {
                    rc.* = rc_copy;
                    ch.nsq = sc.nsq_copy[0];
                    ch.indices.seed = seed_copy;
                    ch.ec_prev_lag_index = ec_prev_lag_index_copy;
                    ch.ec_prev_signal_type = ec_prev_signal_type_copy;
                }
                nsqWrapper(ch, &ctrl, &ch.indices, &ch.nsq, &ch.pulses, ch.x_buf[x_off..], &sc.nsq);
                if (iter == max_iter and !found_lower) rc_copy2 = rc.*;
                indices_enc.encodeIndices(ch, rc, @intCast(ch.n_frames_encoded), false, cond);
                indices_enc.encodePulses(rc, ch.indices.signal_type, ch.indices.quant_offset_type, &ch.pulses, frame_length);
                n_bits = rc.tell();

                if (iter == max_iter and !found_lower and n_bits > max_bits) {
                    rc.* = rc_copy2;
                    ch.last_gain_index = ctrl.last_gain_index_prev;
                    for (0..nb_subfr) |i| ch.indices.gains[i] = 4;
                    if (cond != .conditionally) ch.indices.gains[0] = ctrl.last_gain_index_prev;
                    ch.ec_prev_lag_index = ec_prev_lag_index_copy;
                    ch.ec_prev_signal_type = ec_prev_signal_type_copy;
                    @memset(ch.pulses[0..frame_length], 0);
                    indices_enc.encodeIndices(ch, rc, @intCast(ch.n_frames_encoded), false, cond);
                    indices_enc.encodePulses(rc, ch.indices.signal_type, ch.indices.quant_offset_type, &ch.pulses, frame_length);
                    n_bits = rc.tell();
                }
                if (!use_cbr and iter == 0 and n_bits <= max_bits) break;
            }

            if (iter == max_iter) {
                if (found_lower and (gains_id == gains_id_lower or n_bits > max_bits)) {
                    rc.* = rc_copy2;
                    @memcpy(rc.buf[0..rc_copy2.offs], sc.ec_buf_copy[0..rc_copy2.offs]);
                    ch.nsq = sc.nsq_copy[1];
                    ch.last_gain_index = last_gain_index_copy2;
                }
                break;
            }

            if (n_bits > max_bits) {
                if (!found_lower and iter >= 2) {
                    ctrl.lambda = @max(ctrl.lambda * 1.5, 1.5);
                    ch.indices.quant_offset_type = 0;
                    found_upper = false;
                    gains_id_upper = -1;
                } else {
                    found_upper = true;
                    n_bits_upper = n_bits;
                    gain_mult_upper = gain_mult_q8;
                    gains_id_upper = gains_id;
                }
            } else if (n_bits < max_bits - bits_margin) {
                found_lower = true;
                n_bits_lower = n_bits;
                gain_mult_lower = gain_mult_q8;
                if (gains_id != gains_id_lower) {
                    gains_id_lower = gains_id;
                    rc_copy2 = rc.*;
                    @memcpy(sc.ec_buf_copy[0..rc.offs], rc.buf[0..rc.offs]);
                    sc.nsq_copy[1] = ch.nsq;
                    last_gain_index_copy2 = ch.last_gain_index;
                }
            } else {
                break;
            }

            if (!found_lower and n_bits > max_bits) {
                for (0..nb_subfr) |i| {
                    var sum: i32 = 0;
                    const sub: usize = @intCast(ch.subfr_length);
                    for (i * sub..(i + 1) * sub) |j| sum += @as(i32, @intCast(@abs(@as(i32, ch.pulses[j]))));
                    if (iter == 0 or (sum < best_sum[i] and !gain_lock[i])) {
                        best_sum[i] = sum;
                        best_gain_mult[i] = gain_mult_q8;
                    } else {
                        gain_lock[i] = true;
                    }
                }
            }
            if (!(found_lower and found_upper)) {
                if (n_bits > max_bits) {
                    gain_mult_q8 = @intCast(@min(1024, @divTrunc(@as(i32, gain_mult_q8) * 3, 2)));
                } else {
                    gain_mult_q8 = @intCast(@max(64, @divTrunc(@as(i32, gain_mult_q8) * 4, 5)));
                }
            } else {
                gain_mult_q8 = @truncate(gain_mult_lower + @divTrunc((gain_mult_upper - gain_mult_lower) * (max_bits - n_bits_lower), n_bits_upper - n_bits_lower));
                const hi = gain_mult_lower + ((gain_mult_upper - gain_mult_lower) >> 2);
                const lo = gain_mult_upper - ((gain_mult_upper - gain_mult_lower) >> 2);
                if (gain_mult_q8 > hi) {
                    gain_mult_q8 = @truncate(hi);
                } else if (gain_mult_q8 < lo) {
                    gain_mult_q8 = @truncate(lo);
                }
            }

            var p_gains_q16: [st.max_subfr]i32 = undefined;
            for (0..nb_subfr) |i| {
                const tmp: i16 = if (gain_lock[i]) best_gain_mult[i] else gain_mult_q8;
                p_gains_q16[i] = m.lshiftSat32(m.smulwb(ctrl.gains_unq_q16[i], tmp), 8);
            }
            ch.last_gain_index = ctrl.last_gain_index_prev;
            shape_enc.gainsQuant(&ch.indices.gains, &p_gains_q16, &ch.last_gain_index, cond == .conditionally, nb_subfr);
            gains_id = shape_enc.gainsId(&ch.indices.gains, nb_subfr);
            for (0..nb_subfr) |i| ctrl.gains[i] = @as(f32, @floatFromInt(p_gains_q16[i])) / 65536.0;
        }
    }

    std.mem.copyForwards(f32, ch.x_buf[0 .. ltp_mem + @as(usize, @intCast(st.la_shape_ms * ch.fs_khz))], ch.x_buf[frame_length..][0 .. ltp_mem + @as(usize, @intCast(st.la_shape_ms * ch.fs_khz))]);

    if (ch.prefill_flag) {
        n_bytes_out.* = 0;
        return;
    }
    ch.prev_lag = ctrl.pitch_l[@as(usize, @intCast(ch.nb_subfr)) - 1];
    ch.prev_signal_type = ch.indices.signal_type;
    ch.first_frame_after_reset = false;
    n_bytes_out.* = (enc.?.tell() + 7) >> 3;
}

/// Encodes `samples_in`, which holds `n_samples_in` samples of each API channel, into the
/// range coder. `n_bytes_out` returns the payload size in bytes. With `prefill_flag` set the
/// input only primes the buffers and `enc` may be null.
pub fn encode(
    self: *Encoder,
    ctl: *EncControl,
    samples_in: []const f32,
    n_samples_in_total: usize,
    enc: ?*range.Encoder,
    n_bytes_out: *i32,
    prefill_flag: u32,
    activity: Activity,
) Error!void {
    var n_samples_in: i32 = @intCast(n_samples_in_total);
    const nb_api: usize = @intCast(ctl.n_channels_api);
    if (ctl.n_channels_api < 1 or ctl.n_channels_api > 2 or ctl.n_channels_internal < 1 or ctl.n_channels_internal > ctl.n_channels_api) return error.InvalidControl;
    if (ctl.reduced_dependency) {
        for (0..nb_api) |n| self.channels[n].first_frame_after_reset = true;
    }
    for (0..nb_api) |n| self.channels[n].n_frames_encoded = 0;
    ctl.switch_ready = false;

    if (ctl.n_channels_internal > self.n_channels_internal) {
        initChannel(&self.channels[1]);
        self.stereo.pred_prev_q13 = .{ 0, 0 };
        self.stereo.sside = .{ 0, 0 };
        self.stereo.mid_side_amp_q0 = .{ 0, 1, 0, 1 };
        self.stereo.width_prev_q14 = 0;
        self.stereo.smth_width_q14 = 1 << 14;
        if (self.n_channels_api == 2) {
            self.channels[1].resampler = self.channels[0].resampler;
            self.channels[1].in_hp_state = self.channels[0].in_hp_state;
        }
    }

    const transition = ctl.payload_size_ms != self.channels[0].packet_size_ms or self.n_channels_internal != ctl.n_channels_internal;
    self.n_channels_api = ctl.n_channels_api;
    self.n_channels_internal = ctl.n_channels_internal;
    const n_blocks_of_10ms = @divTrunc(100 * n_samples_in, ctl.api_sample_rate);
    const tot_blocks: i32 = if (n_blocks_of_10ms > 1) n_blocks_of_10ms >> 1 else 1;
    var curr_block: i32 = 0;
    var tmp_payload_size_ms: i32 = 0;
    var tmp_complexity: i32 = 0;
    const n_int: usize = @intCast(ctl.n_channels_internal);
    if (prefill_flag != 0) {
        if (n_blocks_of_10ms != 1) return error.InvalidInput;
        var save_lp: st.LpState = undefined;
        if (prefill_flag == 2) {
            save_lp = self.channels[0].lp;
            save_lp.saved_fs_khz = self.channels[0].fs_khz;
        }
        for (0..n_int) |n| {
            initChannel(&self.channels[n]);
            if (prefill_flag == 2) self.channels[n].lp = save_lp;
        }
        tmp_payload_size_ms = ctl.payload_size_ms;
        ctl.payload_size_ms = 10;
        tmp_complexity = ctl.complexity;
        ctl.complexity = 0;
        for (0..n_int) |n| {
            self.channels[n].controlled_since_last_payload = false;
            self.channels[n].prefill_flag = true;
        }
    } else {
        if (n_blocks_of_10ms * ctl.api_sample_rate != 100 * n_samples_in or n_samples_in < 0) return error.InvalidInput;
        if (1000 * n_samples_in > ctl.payload_size_ms * ctl.api_sample_rate) return error.InvalidInput;
    }

    for (0..n_int) |n| {
        const force_fs_khz: i32 = if (n == 1) self.channels[0].fs_khz else 0;
        controlEncoder(&self.channels[n], ctl, self.allow_bandwidth_switch, @intCast(n), force_fs_khz);
        if (self.channels[n].first_frame_after_reset or transition) {
            for (0..@as(usize, @intCast(self.channels[0].n_frames_per_packet))) |i| self.channels[n].lbrr_flags[i] = 0;
        }
        self.channels[n].in_dtx = self.channels[n].use_dtx;
    }

    var buf: [10 * 3 * 48 * 2]i16 = undefined;
    var in_pos: usize = 0;
    const sc = &self.scratch;
    while (true) {
        const c0 = &self.channels[0];
        const fs_khz = c0.fs_khz;
        const n_samples_to_buffer_max = 10 * n_blocks_of_10ms * fs_khz;
        var n_samples_to_buffer = c0.frame_length - c0.input_buf_ix;
        n_samples_to_buffer = @min(n_samples_to_buffer, n_samples_to_buffer_max);
        const n_samples_from_input: usize = @intCast(@divTrunc(n_samples_to_buffer * c0.api_fs_hz, fs_khz * 1000));
        const ix0: usize = @intCast(c0.input_buf_ix);
        if (ctl.n_channels_api == 2 and ctl.n_channels_internal == 2) {
            const id = c0.n_frames_encoded;
            for (0..n_samples_from_input) |n| buf[n] = @intCast(res2int16(samples_in[in_pos + 2 * n]));
            if (self.n_prev_channels_internal == 1 and id == 0) {
                self.channels[1].resampler = self.channels[0].resampler;
            }
            self.channels[0].resampler.process(self.channels[0].input_buf[ix0 + 2 ..][0..@intCast(n_samples_to_buffer)], buf[0..n_samples_from_input]);
            self.channels[0].input_buf_ix += n_samples_to_buffer;

            const c1 = &self.channels[1];
            n_samples_to_buffer = c1.frame_length - c1.input_buf_ix;
            n_samples_to_buffer = @min(n_samples_to_buffer, 10 * n_blocks_of_10ms * c1.fs_khz);
            for (0..n_samples_from_input) |n| buf[n] = @intCast(res2int16(samples_in[in_pos + 2 * n + 1]));
            const ix1: usize = @intCast(c1.input_buf_ix);
            c1.resampler.process(c1.input_buf[ix1 + 2 ..], buf[0..n_samples_from_input]);
            c1.input_buf_ix += n_samples_to_buffer;
        } else if (ctl.n_channels_api == 2 and ctl.n_channels_internal == 1) {
            for (0..n_samples_from_input) |n| {
                const sum = res2int16(samples_in[in_pos + 2 * n] + samples_in[in_pos + 2 * n + 1]);
                buf[n] = @truncate(m.rshiftRound(sum, 1));
            }
            self.channels[0].resampler.process(self.channels[0].input_buf[ix0 + 2 ..][0..@intCast(n_samples_to_buffer)], buf[0..n_samples_from_input]);
            if (self.n_prev_channels_internal == 2 and self.channels[0].n_frames_encoded == 0) {
                const c1 = &self.channels[1];
                const ix1: usize = @intCast(c1.input_buf_ix);
                c1.resampler.process(c1.input_buf[ix1 + 2 ..], buf[0..n_samples_from_input]);
                const fl: usize = @intCast(c0.frame_length);
                for (0..fl) |n| {
                    self.channels[0].input_buf[ix0 + n + 2] = @truncate((@as(i32, self.channels[0].input_buf[ix0 + n + 2]) + c1.input_buf[ix1 + n + 2]) >> 1);
                }
            }
            self.channels[0].input_buf_ix += n_samples_to_buffer;
        } else {
            for (0..n_samples_from_input) |n| buf[n] = @intCast(res2int16(samples_in[in_pos + n]));
            self.channels[0].resampler.process(self.channels[0].input_buf[ix0 + 2 ..][0..@intCast(n_samples_to_buffer)], buf[0..n_samples_from_input]);
            self.channels[0].input_buf_ix += n_samples_to_buffer;
        }

        in_pos += n_samples_from_input * nb_api;
        n_samples_in -= @intCast(n_samples_from_input);
        self.allow_bandwidth_switch = false;

        const ch0 = &self.channels[0];
        if (ch0.input_buf_ix >= ch0.frame_length) {
            var curr_n_bits_used_lbrr: i32 = 0;
            if (ch0.n_frames_encoded == 0 and prefill_flag == 0) {
                const rc = enc.?;
                var icdf: [2]u8 = .{ 0, 0 };
                icdf[0] = @intCast(256 - (@as(i32, 256) >> @intCast((ch0.n_frames_per_packet + 1) * ctl.n_channels_internal)));
                rc.encodeIcdf(0, &icdf, 8);
                curr_n_bits_used_lbrr = rc.tell();

                for (0..n_int) |n| {
                    var lbrr_symbol: i32 = 0;
                    const nfp: usize = @intCast(self.channels[n].n_frames_per_packet);
                    for (0..nfp) |i| lbrr_symbol |= self.channels[n].lbrr_flags[i] << @intCast(i);
                    self.channels[n].lbrr_flag = @intFromBool(lbrr_symbol > 0);
                    if (lbrr_symbol != 0 and nfp > 1) {
                        const t: []const u8 = if (nfp == 2) &tables.lbrr_flags_2_icdf else &tables.lbrr_flags_3_icdf;
                        rc.encodeIcdf(@intCast(lbrr_symbol - 1), t, 8);
                    }
                }
                const nfp0: usize = @intCast(self.channels[0].n_frames_per_packet);
                for (0..nfp0) |i| {
                    for (0..n_int) |n| {
                        if (self.channels[n].lbrr_flags[i] != 0) {
                            if (ctl.n_channels_internal == 2 and n == 0) {
                                stereo_enc.encodePred(rc, &self.stereo.pred_ix[i]);
                                if (self.channels[1].lbrr_flags[i] == 0) stereo_enc.encodeMidOnly(rc, self.stereo.mid_only_flags[i]);
                            }
                            const cond: st.Cond = if (i > 0 and self.channels[n].lbrr_flags[i - 1] != 0) .conditionally else .independently;
                            indices_enc.encodeIndices(&self.channels[n], rc, i, true, cond);
                            indices_enc.encodePulses(rc, self.channels[n].indices_lbrr[i].signal_type, self.channels[n].indices_lbrr[i].quant_offset_type, &self.channels[n].pulses_lbrr[i], @intCast(self.channels[n].frame_length));
                        }
                    }
                }
                for (0..n_int) |n| self.channels[n].lbrr_flags = @splat(0);
                curr_n_bits_used_lbrr = rc.tell() - curr_n_bits_used_lbrr;
            }

            hpVariableCutoff(&self.channels[0]);

            var n_bits: i32 = @divTrunc(ctl.bit_rate * ctl.payload_size_ms, 1000);
            if (prefill_flag == 0) {
                if (curr_n_bits_used_lbrr < 10) {
                    self.n_bits_used_lbrr = 0;
                } else if (self.n_bits_used_lbrr < 10) {
                    self.n_bits_used_lbrr = curr_n_bits_used_lbrr;
                } else {
                    self.n_bits_used_lbrr = @divTrunc(self.n_bits_used_lbrr + curr_n_bits_used_lbrr, 2);
                }
                n_bits -= self.n_bits_used_lbrr;
            }
            n_bits = @divTrunc(n_bits, self.channels[0].n_frames_per_packet);
            var target_rate_bps: i32 = if (ctl.payload_size_ms == 10) m.smulbb(n_bits, 100) else m.smulbb(n_bits, 50);
            target_rate_bps -= @divTrunc(self.n_bits_exceeded * 1000, bitreservoir_decay_time_ms);
            if (prefill_flag == 0 and self.channels[0].n_frames_encoded > 0) {
                const bits_balance = enc.?.tell() - self.n_bits_used_lbrr - n_bits * self.channels[0].n_frames_encoded;
                target_rate_bps -= @divTrunc(bits_balance * 1000, bitreservoir_decay_time_ms);
            }
            target_rate_bps = m.limit(target_rate_bps, ctl.bit_rate, 5000);

            var ms_target_rates_bps: [2]i32 = .{ 0, 0 };
            const frame_idx: usize = @intCast(self.channels[0].n_frames_encoded);
            if (ctl.n_channels_internal == 2) {
                stereo_enc.lrToMs(
                    &sc.stereo,
                    &self.stereo,
                    &self.channels[0].input_buf,
                    &self.channels[1].input_buf,
                    &self.stereo.pred_ix[frame_idx],
                    &self.stereo.mid_only_flags[frame_idx],
                    &ms_target_rates_bps,
                    target_rate_bps,
                    self.channels[0].speech_activity_q8,
                    ctl.to_mono,
                    self.channels[0].fs_khz,
                    @intCast(self.channels[0].frame_length),
                );
                if (self.stereo.mid_only_flags[frame_idx] == 0) {
                    if (self.prev_decode_only_middle == 1) {
                        const c1 = &self.channels[1];
                        c1.harm_shape_gain_smth = 0;
                        c1.tilt_smth = 0;
                        c1.last_gain_index = 0;
                        c1.nsq = .{};
                        c1.prev_nlsfq_q15 = @splat(0);
                        c1.lp.in_lp_state = .{ 0, 0 };
                        c1.prev_lag = 100;
                        c1.nsq.lag_prev = 100;
                        c1.last_gain_index = 10;
                        c1.prev_signal_type = st.type_no_voice_activity;
                        c1.nsq.prev_gain_q16 = 65536;
                        c1.first_frame_after_reset = true;
                    }
                    doVad(&self.channels[1], activity);
                } else {
                    self.channels[1].vad_flags[frame_idx] = 0;
                }
                if (prefill_flag == 0) {
                    stereo_enc.encodePred(enc.?, &self.stereo.pred_ix[frame_idx]);
                    if (self.channels[1].vad_flags[frame_idx] == 0) {
                        stereo_enc.encodeMidOnly(enc.?, self.stereo.mid_only_flags[frame_idx]);
                    }
                }
            } else {
                const c0m = &self.channels[0];
                const fl: usize = @intCast(c0m.frame_length);
                c0m.input_buf[0..2].* = self.stereo.smid;
                self.stereo.smid = c0m.input_buf[fl..][0..2].*;
            }
            doVad(&self.channels[0], activity);

            for (0..n_int) |n| {
                var max_bits = ctl.max_bits;
                if (tot_blocks == 2 and curr_block == 0) {
                    max_bits = @divTrunc(max_bits * 3, 5);
                } else if (tot_blocks == 3) {
                    if (curr_block == 0) {
                        max_bits = @divTrunc(max_bits * 2, 5);
                    } else if (curr_block == 1) {
                        max_bits = @divTrunc(max_bits * 3, 4);
                    }
                }
                var use_cbr = ctl.use_cbr and curr_block == tot_blocks - 1;
                var channel_rate_bps: i32 = undefined;
                if (ctl.n_channels_internal == 1) {
                    channel_rate_bps = target_rate_bps;
                } else {
                    channel_rate_bps = ms_target_rates_bps[n];
                    if (n == 0 and ms_target_rates_bps[1] > 0) {
                        use_cbr = false;
                        max_bits -= @divTrunc(ctl.max_bits, tot_blocks * 2);
                    }
                }
                if (channel_rate_bps > 0) {
                    controlSnr(&self.channels[n], channel_rate_bps);
                    var cond: st.Cond = undefined;
                    if (self.channels[0].n_frames_encoded - @as(i32, @intCast(n)) <= 0) {
                        cond = .independently;
                    } else if (n > 0 and self.prev_decode_only_middle != 0) {
                        cond = .independently_no_ltp_scaling;
                    } else {
                        cond = .conditionally;
                    }
                    encodeFrame(&self.channels[n], sc, n_bytes_out, enc, cond, max_bits, use_cbr);
                }
                self.channels[n].controlled_since_last_payload = false;
                self.channels[n].input_buf_ix = 0;
                self.channels[n].n_frames_encoded += 1;
            }
            self.prev_decode_only_middle = self.stereo.mid_only_flags[@intCast(self.channels[0].n_frames_encoded - 1)];

            if (n_bytes_out.* > 0 and self.channels[0].n_frames_encoded == self.channels[0].n_frames_per_packet) {
                var flags: u32 = 0;
                for (0..n_int) |n| {
                    for (0..@as(usize, @intCast(self.channels[n].n_frames_per_packet))) |i| {
                        flags = (flags << 1) | @as(u32, @intCast(self.channels[n].vad_flags[i]));
                    }
                    flags = (flags << 1) | @as(u32, @intCast(self.channels[n].lbrr_flag));
                }
                if (prefill_flag == 0) {
                    enc.?.patchInitialBits(flags, @intCast((self.channels[0].n_frames_per_packet + 1) * ctl.n_channels_internal));
                }
                if (self.channels[0].in_dtx and (ctl.n_channels_internal == 1 or self.channels[1].in_dtx)) n_bytes_out.* = 0;

                self.n_bits_exceeded += n_bytes_out.* * 8;
                self.n_bits_exceeded -= @divTrunc(ctl.bit_rate * ctl.payload_size_ms, 1000);
                self.n_bits_exceeded = m.limit(self.n_bits_exceeded, 0, 10000);

                const speech_act_thr_for_switch_q8 = m.smlawb(speech_activity_dtx_thres_q8, 3188, self.time_since_switch_allowed_ms);
                if (self.channels[0].speech_activity_q8 < speech_act_thr_for_switch_q8) {
                    self.allow_bandwidth_switch = true;
                    self.time_since_switch_allowed_ms = 0;
                } else {
                    self.allow_bandwidth_switch = false;
                    self.time_since_switch_allowed_ms += ctl.payload_size_ms;
                }
            }
            if (n_samples_in == 0) break;
        } else break;
        curr_block += 1;
    }

    self.n_prev_channels_internal = ctl.n_channels_internal;
    ctl.allow_bandwidth_switch = self.allow_bandwidth_switch;
    ctl.in_wb_mode_without_variable_lp = self.channels[0].fs_khz == 16 and self.channels[0].lp.mode == 0;
    ctl.internal_sample_rate = self.channels[0].fs_khz * 1000;
    ctl.stereo_width_q14 = if (ctl.to_mono) 0 else self.stereo.smth_width_q14;
    if (prefill_flag != 0) {
        ctl.payload_size_ms = tmp_payload_size_ms;
        ctl.complexity = tmp_complexity;
        for (0..n_int) |n| {
            self.channels[n].controlled_since_last_payload = false;
            self.channels[n].prefill_flag = false;
        }
    }
    ctl.signal_type = self.channels[0].indices.signal_type;
    ctl.offset = tables.quantization_offsets_q10[@as(usize, @intCast(self.channels[0].indices.signal_type >> 1)) * 2 + @as(usize, @intCast(self.channels[0].indices.quant_offset_type))];
}

const testing = std.testing;
const decode_mod = @import("decode.zig");

fn speechLike(buf: []f32, start: usize, rate: f32) void {
    for (buf, 0..) |*v, i| {
        const t = @as(f32, @floatFromInt(start + i)) / rate;
        const phase = 2 * std.math.pi * (140.0 * t - 20.0 / (2 * std.math.pi * 3.0) * @cos(2 * std.math.pi * 3.0 * t));
        var s: f32 = 0;
        var h: f32 = 1;
        while (h < 25) : (h += 1) {
            s += @sin(phase * h) / h;
        }
        v.* = 0.25 * s * (0.6 + 0.4 * @sin(2 * std.math.pi * 2.0 * t));
    }
}

test "a frame of speech like input decodes close to the input" {
    const enc = try testing.allocator.create(Encoder);
    defer testing.allocator.destroy(enc);
    enc.reset(1);
    const dec = try testing.allocator.create(decode_mod.Decoder);
    defer testing.allocator.destroy(dec);
    dec.* = decode_mod.Decoder.init();
    var ctl: EncControl = .{ .bit_rate = 24000, .max_bits = 8 * 400, .complexity = 2 };
    const frames = 40;
    var pcm: [frames * 960]f32 = undefined;
    speechLike(&pcm, 0, 48000);
    var out: [frames * 960]i16 = undefined;
    var total_bytes: usize = 0;
    for (0..frames) |f| {
        var buf: [1275]u8 = undefined;
        var rc = range.Encoder.init(&buf);
        var n_bytes: i32 = 0;
        try encode(enc, &ctl, pcm[f * 960 ..][0..960], 960, &rc, &n_bytes, 0, .no_decision);
        total_bytes += @intCast(n_bytes);
        rc.done();
        var rd = range.Decoder.init(buf[0..@intCast(n_bytes)]);
        const got = try dec.decode(.{ .channels_api = 1, .channels_internal = 1, .internal_khz = @intCast(@divTrunc(ctl.internal_sample_rate, 1000)), .payload_ms = 20 }, true, &rd, out[f * 960 ..][0..960]);
        try testing.expectEqual(@as(usize, 960), got);
    }
    var best: f64 = -100;
    for (0..1200) |d| {
        var sig: f64 = 0;
        var err: f64 = 0;
        for (20 * 960..frames * 960 - 1200) |i| {
            const a: f64 = pcm[i] * 32768.0;
            const b: f64 = @floatFromInt(out[i + d]);
            sig += a * a;
            err += (a - b) * (a - b);
        }
        const snr = 10 * std.math.log10(sig / err);
        if (snr > best) {
            best = snr;
        }
    }
    try testing.expect(best > 5);
}
