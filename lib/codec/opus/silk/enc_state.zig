//! State of the SILK encoder, after libopus silk/structs.h and silk/float/structs_FLP.h.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const nlsf = @import("nlsf.zig");
const tables = @import("tables.zig");
const DownResampler = @import("enc_resampler.zig").DownResampler;

pub const max_frame_length = 320;
pub const max_subfr = 4;
pub const max_sub_frame_length = 80;
pub const max_lpc_order = 16;
pub const max_shape_lpc_order = 24;
pub const ltp_order = 5;
pub const max_frames_per_packet = 3;
pub const nsq_lpc_buf_length = 16;
pub const decision_delay = 40;
pub const max_del_dec_states = 4;
pub const la_shape_ms = 5;
pub const la_shape_max = la_shape_ms * 16;
pub const la_pitch_max = 2 * 16;
pub const x_buf_length = 2 * max_frame_length + la_shape_max;
pub const vad_n_bands = 4;

pub const type_no_voice_activity = 0;
pub const type_unvoiced = 1;
pub const type_voiced = 2;

pub const Cond = enum { independently, independently_no_ltp_scaling, conditionally };

/// The decision of the Opus layer on voice activity.
pub const Activity = enum { no_decision, no_activity, activity };

/// The quantization indices of one frame.
pub const Indices = struct {
    gains: [max_subfr]i8 = @splat(0),
    ltp_index: [max_subfr]i8 = @splat(0),
    nlsf_indices: [max_lpc_order + 1]i8 = @splat(0),
    lag_index: i16 = 0,
    contour_index: i8 = 0,
    signal_type: i8 = 0,
    quant_offset_type: i8 = 0,
    nlsf_interp_coef_q2: i8 = 0,
    per_index: i8 = 0,
    ltp_scale_index: i8 = 0,
    seed: i8 = 0,
};

/// State of the noise shaping quantizer.
pub const NsqState = struct {
    xq: [2 * max_frame_length]i16 = @splat(0),
    sltp_shp_q14: [2 * max_frame_length]i32 = @splat(0),
    slpc_q14: [max_sub_frame_length + nsq_lpc_buf_length]i32 = @splat(0),
    sar2_q14: [max_shape_lpc_order]i32 = @splat(0),
    slf_ar_shp_q14: i32 = 0,
    sdiff_shp_q14: i32 = 0,
    lag_prev: i32 = 0,
    sltp_buf_idx: i32 = 0,
    sltp_shp_buf_idx: i32 = 0,
    rand_seed: i32 = 0,
    prev_gain_q16: i32 = 0,
    rewhite_flag: i32 = 0,
};

pub const VadState = struct {
    ana_state: [2]i32 = @splat(0),
    ana_state1: [2]i32 = @splat(0),
    ana_state2: [2]i32 = @splat(0),
    xnrg_subfr: [vad_n_bands]i32 = @splat(0),
    nrg_ratio_smth_q8: [vad_n_bands]i32 = @splat(0),
    hp_state: i16 = 0,
    nl: [vad_n_bands]i32 = @splat(0),
    inv_nl: [vad_n_bands]i32 = @splat(0),
    noise_level_bias: [vad_n_bands]i32 = @splat(0),
    counter: i32 = 0,
};

/// Variable cut off low pass filter state for bandwidth switches.
pub const LpState = struct {
    in_lp_state: [2]i32 = @splat(0),
    transition_frame_no: i32 = 0,
    mode: i32 = 0,
    saved_fs_khz: i32 = 0,
};

pub const StereoEncState = struct {
    pred_prev_q13: [2]i16 = @splat(0),
    smid: [2]i16 = @splat(0),
    sside: [2]i16 = @splat(0),
    mid_side_amp_q0: [4]i32 = @splat(0),
    smth_width_q14: i16 = 0,
    width_prev_q14: i16 = 0,
    silent_side_len: i16 = 0,
    pred_ix: [max_frames_per_packet][2][3]i8 = @splat(@splat(@splat(0))),
    mid_only_flags: [max_frames_per_packet]i8 = @splat(0),
};

/// The control structure that the Opus layer gives to the SILK encoder.
pub const EncControl = struct {
    n_channels_api: i32 = 1,
    n_channels_internal: i32 = 1,
    api_sample_rate: i32 = 48000,
    max_internal_sample_rate: i32 = 16000,
    min_internal_sample_rate: i32 = 8000,
    desired_internal_sample_rate: i32 = 16000,
    payload_size_ms: i32 = 20,
    bit_rate: i32 = 25000,
    packet_loss_percentage: i32 = 0,
    complexity: i32 = 9,
    use_in_band_fec: bool = false,
    lbrr_coded: bool = false,
    use_dtx: bool = false,
    use_cbr: bool = false,
    max_bits: i32 = 0,
    to_mono: bool = false,
    opus_can_switch: bool = false,
    reduced_dependency: bool = false,
    // Outputs.
    internal_sample_rate: i32 = 0,
    allow_bandwidth_switch: bool = false,
    in_wb_mode_without_variable_lp: bool = false,
    switch_ready: bool = false,
    stereo_width_q14: i32 = 0,
    signal_type: i32 = 0,
    offset: i32 = 0,
};

/// State of one channel of the encoder.
pub const Channel = struct {
    in_hp_state: [2]i32 = @splat(0),
    variable_hp_smth1_q15: i32 = 0,
    variable_hp_smth2_q15: i32 = 0,
    lp: LpState = .{},
    vad: VadState = .{},
    nsq: NsqState = .{},
    prev_nlsfq_q15: [max_lpc_order]i16 = @splat(0),
    speech_activity_q8: i32 = 0,
    allow_bandwidth_switch: bool = false,
    lbrr_prev_last_gain_index: i8 = 0,
    prev_signal_type: i8 = 0,
    prev_lag: i32 = 0,
    pitch_lpc_win_length: i32 = 0,
    max_pitch_lag: i32 = 0,
    api_fs_hz: i32 = 0,
    prev_api_fs_hz: i32 = 0,
    max_internal_fs_hz: i32 = 0,
    min_internal_fs_hz: i32 = 0,
    desired_internal_fs_hz: i32 = 0,
    fs_khz: i32 = 0,
    nb_subfr: i32 = 0,
    frame_length: i32 = 0,
    subfr_length: i32 = 0,
    ltp_mem_length: i32 = 0,
    la_pitch: i32 = 0,
    la_shape: i32 = 0,
    shape_win_length: i32 = 0,
    target_rate_bps: i32 = 0,
    packet_size_ms: i32 = 0,
    packet_loss_perc: i32 = 0,
    frame_counter: i32 = 0,
    complexity: i32 = 0,
    n_states_delayed_decision: i32 = 0,
    use_interpolated_nlsfs: bool = false,
    shaping_lpc_order: i32 = 0,
    predict_lpc_order: i32 = 0,
    pitch_estimation_complexity: i32 = 0,
    pitch_estimation_lpc_order: i32 = 0,
    pitch_estimation_threshold_q16: i32 = 0,
    sum_log_gain_q7: i32 = 0,
    nlsf_msvq_survivors: i32 = 0,
    first_frame_after_reset: bool = true,
    controlled_since_last_payload: bool = false,
    warping_q16: i32 = 0,
    use_cbr: bool = false,
    prefill_flag: bool = false,
    pitch_lag_low_bits_icdf: []const u8 = &tables.uniform4_icdf,
    pitch_contour_icdf: []const u8 = &tables.pitch_contour_icdf,
    nlsf_cb: *const nlsf.Codebook = &nlsf.nb_mb,
    input_quality_bands_q15: [vad_n_bands]i32 = @splat(0),
    input_tilt_q15: i32 = 0,
    snr_db_q7: i32 = 0,
    vad_flags: [max_frames_per_packet]i8 = @splat(0),
    lbrr_flag: i8 = 0,
    lbrr_flags: [max_frames_per_packet]i32 = @splat(0),
    indices: Indices = .{},
    pulses: [max_frame_length]i8 = @splat(0),
    input_buf: [max_frame_length + 2]i16 = @splat(0),
    input_buf_ix: i32 = 0,
    n_frames_per_packet: i32 = 0,
    n_frames_encoded: i32 = 0,
    n_channels_api: i32 = 0,
    n_channels_internal: i32 = 0,
    channel_nb: i32 = 0,
    ec_prev_signal_type: i32 = 0,
    ec_prev_lag_index: i16 = 0,
    resampler: DownResampler = .{},
    use_dtx: bool = false,
    in_dtx: bool = false,
    no_speech_counter: i32 = 0,
    use_inband_fec: bool = false,
    lbrr_enabled: bool = false,
    lbrr_gain_increases: i32 = 0,
    indices_lbrr: [max_frames_per_packet]Indices = @splat(.{}),
    pulses_lbrr: [max_frames_per_packet][max_frame_length]i8 = @splat(@splat(0)),
    // The noise shaping analysis state.
    last_gain_index: i8 = 0,
    harm_shape_gain_smth: f32 = 0,
    tilt_smth: f32 = 0,
    x_buf: [x_buf_length]f32 = @splat(0),
    ltp_corr: f32 = 0,
};

/// The parameters of one frame that the analysis finds, after silk_encoder_control_FLP.
pub const Control = struct {
    gains: [max_subfr]f32 = @splat(0),
    pred_coef: [2][max_lpc_order]f32 = @splat(@splat(0)),
    ltp_coef: [ltp_order * max_subfr]f32 = @splat(0),
    ltp_scale: f32 = 0,
    pitch_l: [max_subfr]i32 = @splat(0),
    ar: [max_subfr * max_shape_lpc_order]f32 = @splat(0),
    lf_ma_shp: [max_subfr]f32 = @splat(0),
    lf_ar_shp: [max_subfr]f32 = @splat(0),
    tilt: [max_subfr]f32 = @splat(0),
    harm_shape_gain: [max_subfr]f32 = @splat(0),
    lambda: f32 = 0,
    input_quality: f32 = 0,
    coding_quality: f32 = 0,
    pred_gain: f32 = 0,
    ltp_pred_cod_gain: f32 = 0,
    res_nrg: [max_subfr]f32 = @splat(0),
    gains_unq_q16: [max_subfr]i32 = @splat(0),
    last_gain_index_prev: i8 = 0,
};
