//! Opus packet encoder: the TOC byte, the bitrate rules, the mode decision, the SILK, hybrid
//! and CELT frames and the repacketizing of long frames, following libopus src/opus_encoder.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const celt = @import("celt.zig");
const silk = @import("silk.zig");
const packet = @import("packet.zig");
const range = @import("range.zig");
const opus = @import("../opus.zig");

const sample_rate = 48000;
const max_packet = 1276;
const dc_cutoff_hz = 3.0;
const max_encoder_buffer = sample_rate / 100;
const max_delay_compensation = sample_rate / 250;
const max_frame_samples = 3 * sample_rate / 50;

/// How the encoder codes a frame.
pub const Mode = enum { silk_only, hybrid, celt_only };

pub const Error = celt.encode.Error;

const Bandwidth = packet.Bandwidth;

fn bwInt(b: Bandwidth) i32 {
    return @backingInt(b);
}

fn bwFromInt(v: i32) Bandwidth {
    return @fromBackingInt(@intCast(v));
}

/// The bitrates in bit/s where the bandwidth changes between two steps, each with its
/// hysteresis. The steps are narrow to medium, medium to wide, wide to super wide and super wide
/// to full. A voice signal and a music signal have their own values.
const voice_thresholds = [8]i32{ 9000, 700, 9000, 700, 13500, 1000, 14000, 2000 };
const music_thresholds = [8]i32{ 9000, 700, 9000, 700, 11000, 1000, 12000, 2000 };
const fec_thresholds = [10]i32{ 12000, 1000, 14000, 1000, 16000, 1000, 20000, 1000, 22000, 1000 };

/// The smoothed state of the stereo width measure.
const StereoWidth = struct {
    xx: f32 = 0,
    xy: f32 = 0,
    yy: f32 = 0,
    smoothed_width: f32 = 0,
    max_follower: f32 = 0,
};

/// Buffers of the encoder. They live in the encoder so that a call needs little stack.
const Scratch = struct {
    pcm_buf: [(max_frame_samples + max_delay_compensation) * 2]f32,
    /// The packets of the frames of a long frame, before they are repacketized.
    frames: [6 * max_packet + 16]u8,
    prefill: [2 * sample_rate / 400]f32,
};

/// True for the input rates of libopus.
pub fn validRate(fs: u32) bool {
    return fs == 8000 or fs == 12000 or fs == 16000 or fs == 24000 or fs == 48000;
}

/// The frame sizes that one packet can hold, in samples at the rate `fs`.
fn validFrameSize(n: u32, fs: u32) bool {
    return 400 * n == fs or 200 * n == fs or 100 * n == fs or
        50 * n == fs or 25 * n == fs or 50 * n == 3 * fs or
        50 * n == 4 * fs or 50 * n == 5 * fs or 50 * n == 6 * fs;
}

pub fn frameSizeOf(frame_ms: f32, fs: u32) ?u32 {
    const v = frame_ms * @as(f32, @floatFromInt(fs)) / 1000.0;
    if (!(v >= @as(f32, @floatFromInt(fs / 400)) and v <= @as(f32, @floatFromInt(6 * fs / 50)))) return null;
    const n: u32 = @intFromFloat(@round(v));
    if (@abs(@as(f32, @floatFromInt(n)) - v) > 0.01) return null;
    if (!validFrameSize(n, fs)) return null;
    return n;
}

/// Encodes f32 samples to whole Opus packets, one packet per call. The input rate is 8000, 12000,
/// 16000, 24000 or 48000 Hz.
pub const PacketEncoder = struct {
    /// The input sampling rate in Hz.
    fs: u32,
    channels: u32,
    options: opus.EncodeOptions,
    /// The samples of each channel that one packet codes.
    frame_size: u32,
    /// The bitrate that the user asked for, or the default of libopus.
    bitrate: u32,
    celt: celt.encode.Encoder,
    silk: silk.encode.Encoder,
    /// The control structure of the SILK layer (silk_mode in libopus).
    silk_ctl: silk.enc_state.EncControl,
    hp_mem: [4]f32 = @splat(0),
    width_mem: StereoWidth = .{},
    delay_buffer: [max_encoder_buffer * 2]f32 = @splat(0),
    variable_hp_smth2_q15: i32,
    prev_hb_gain: f32 = 1.0,
    hybrid_stereo_width_q14: i32 = 16384,
    mode: Mode = .hybrid,
    prev_mode: ?Mode = null,
    prev_channels: u32 = 0,
    bandwidth: Bandwidth = .full,
    auto_bandwidth: Bandwidth = .full,
    first: bool = true,
    /// The channels of the coded stream. A stereo input at a low rate gives a mono stream.
    stream_channels: u32,
    force_channels: ?u32 = null,
    /// The bits of the input samples (OPUS_SET_LSB_DEPTH). Float input has 24. Use `setLsbDepth`.
    lsb_depth: u5 = 24,
    silk_bw_switch: bool = false,
    bitrate_bps: i32 = 0,
    final_range: u32 = 0,
    /// Subtracts the byte of the TOC from the target of a variable rate, so that the packets
    /// average the requested rate. libopus does not. A test sets it to false to compare packets.
    toc_overhead: bool = true,
    /// Forces the mode (OPUS_SET_FORCE_MODE). Null lets the encoder choose.
    forced_mode: ?Mode = null,
    /// Forces the bandwidth (OPUS_SET_BANDWIDTH). Null lets the encoder choose.
    user_bandwidth: ?Bandwidth = null,
    /// The bandwidth of the input signal. A signal that was resampled from a low rate has no
    /// content above it (the Fs limit of libopus).
    input_bandwidth: Bandwidth = .full,
    scratch: Scratch = undefined,

    pub const InitError = error{ InvalidChannels, InvalidFrameSize, InvalidRate, InvalidComplexity };

    /// An encoder for 1 or 2 channels. `options.frame_ms` is 2.5, 5, 10, 20, 40, 60, 80, 100
    /// or 120. The bitrate is limited to 500 bit/s and 750 kbit/s per channel, see `initRate` for
    /// the bitrate 0. `options.complexity` is 0 to 10.
    ///
    /// The result is larger than 160 KB. A caller that keeps it in a long lived place uses
    /// `initInto` to avoid the copy on the stack.
    pub fn init(channels: u32, options: opus.EncodeOptions) InitError!PacketEncoder {
        return initRate(48000, channels, options);
    }

    /// Like `init`, for an input at `fs` Hz. The rate is 8000, 12000, 16000, 24000 or 48000, and the
    /// frame size is `options.frame_ms` at that rate.
    ///
    /// The bitrate 0 gives 60 bit/s for each frame of one second plus `fs` bit/s for each channel,
    /// as libopus does.
    pub fn initRate(fs: u32, channels: u32, options: opus.EncodeOptions) InitError!PacketEncoder {
        var self: PacketEncoder = undefined;
        try self.initIntoRate(fs, channels, options);
        return self;
    }

    /// Like `init`, for an encoder that lives at `self`. It avoids a copy of the large state.
    pub fn initInto(self: *PacketEncoder, channels: u32, options: opus.EncodeOptions) InitError!void {
        return self.initIntoRate(48000, channels, options);
    }

    /// Like `initInto`, for an input at `fs` Hz.
    pub fn initIntoRate(self: *PacketEncoder, fs: u32, channels: u32, options: opus.EncodeOptions) InitError!void {
        if (!validRate(fs)) return error.InvalidRate;
        if (channels != 1 and channels != 2) return error.InvalidChannels;
        const frame_size = frameSizeOf(options.frame_ms, fs) orelse return error.InvalidFrameSize;
        if (options.complexity > 10) return error.InvalidComplexity;
        self.fs = fs;
        self.channels = channels;
        self.options = options;
        self.frame_size = frame_size;
        self.setBitrate(options.bitrate);
        self.celt = celt.encode.Encoder.initUpsampled(channels, 48000 / fs);
        self.celt.settings.complexity = options.complexity;
        self.celt.settings.loss_rate = @min(options.packet_loss, 100);
        self.forced_mode = null;
        self.user_bandwidth = null;
        self.input_bandwidth = .full;
        self.force_channels = null;
        self.lsb_depth = 24;
        self.toc_overhead = true;
        self.clearState();
    }

    fn clearState(self: *PacketEncoder) void {
        const channels = self.channels;
        const options = self.options;
        self.celt.reset();
        self.silk.reset(channels);
        self.silk_ctl = .{
            .n_channels_api = @intCast(channels),
            .n_channels_internal = @intCast(channels),
            .api_sample_rate = @intCast(self.fs),
            .max_internal_sample_rate = 16000,
            .min_internal_sample_rate = 8000,
            .desired_internal_sample_rate = 16000,
            .payload_size_ms = 20,
            .bit_rate = 25000,
            .packet_loss_percentage = @intCast(@min(options.packet_loss, 100)),
            .complexity = options.complexity,
            .use_in_band_fec = options.packet_loss > 0,
        };
        self.hp_mem = @splat(0);
        self.width_mem = .{};
        self.delay_buffer = @splat(0);
        self.variable_hp_smth2_q15 = silk.macros.lin2log(60) << 8;
        self.prev_hb_gain = 1.0;
        self.hybrid_stereo_width_q14 = 16384;
        self.mode = .hybrid;
        self.prev_mode = null;
        self.prev_channels = 0;
        self.bandwidth = .full;
        self.auto_bandwidth = .full;
        self.first = true;
        self.stream_channels = channels;
        self.silk_bw_switch = false;
        self.bitrate_bps = 0;
        self.final_range = 0;
    }

    /// Changes the bitrate for the next packets. 0 picks the default of the channels and the frame
    /// size.
    pub fn setBitrate(self: *PacketEncoder, bitrate: u32) void {
        self.options.bitrate = bitrate;
        self.bitrate = if (bitrate == 0)
            self.defaultBitrate()
        else
            std.math.clamp(bitrate, 500, 750_000 * self.channels);
    }

    fn defaultBitrate(self: *const PacketEncoder) u32 {
        return 60 * self.fs / self.frame_size + self.fs * self.channels;
    }

    /// Changes the effort of the encoder for the next packets, 0 to 10 (OPUS_SET_COMPLEXITY).
    pub fn setComplexity(self: *PacketEncoder, level: u4) error{InvalidComplexity}!void {
        if (level > 10) return error.InvalidComplexity;
        self.options.complexity = level;
        self.celt.settings.complexity = level;
    }

    /// Sets the bits of the input samples (OPUS_SET_LSB_DEPTH). The value is limited to 8 to 24.
    pub fn setLsbDepth(self: *PacketEncoder, depth: u5) void {
        self.lsb_depth = std.math.clamp(depth, 8, 24);
    }

    /// Turns the low frequency effects mode (OPUS_SET_LFE) on or off. A low frequency stream codes
    /// only the lowest bands with CELT.
    pub fn setLfe(self: *PacketEncoder, on: bool) void {
        self.celt.settings.lfe = on;
    }

    /// Sets the masking of each band by the other channels of a surround stream, 21 values for
    /// each channel (OPUS_SET_ENERGY_MASK), or null to remove it.
    pub fn setEnergyMask(self: *PacketEncoder, mask: ?*const [42]f32) void {
        self.celt.settings.energy_mask = if (mask) |m| m.* else null;
    }

    /// Clears the history, as for a new stream. The settings and the SILK control stay.
    pub fn reset(self: *PacketEncoder) void {
        const settings = self.celt.settings;
        const ctl = self.silk_ctl;
        self.clearState();
        self.silk_ctl = ctl;
        self.celt.settings = settings;
        self.celt.settings.silk_signal_type = 0;
        self.celt.settings.silk_offset = 0;
    }

    /// The samples of each channel that one packet codes.
    pub fn frameSamples(self: *const PacketEncoder) usize {
        return self.frame_size;
    }

    /// The range coder state at the end of the last packet. The decoder of the same packet
    /// ends with the same value.
    pub fn finalRange(self: *const PacketEncoder) u32 {
        return self.final_range;
    }

    /// The samples of delay between the input and the output of a decoder. A caller that
    /// writes Ogg Opus uses it as the pre-skip.
    pub fn lookahead(self: *const PacketEncoder) u32 {
        var v: u32 = self.fs / 400;
        if (self.options.application != .low_delay) v += (self.fs / 250);
        return v;
    }

    fn complexity(self: *const PacketEncoder) i32 {
        return self.options.complexity;
    }

    fn userBitrate(self: *const PacketEncoder, frame_size: u32, max_data_bytes: i32) i32 {
        const max_bitrate = bitsToBitrate(self.fs, max_data_bytes * 8, frame_size);
        return @min(@as(i32, @intCast(self.bitrate)), max_bitrate);
    }

    /// Encodes `frameSamples()` samples of each channel from the interleaved `pcm` into the packet
    /// `out` and returns its length. Without VBR the packet has the length that the bitrate
    /// gives, or `out.len` if that is shorter. Samples that are not finite or not in range are
    /// cleaned like in libopus.
    /// After `error.EncoderFailed` the prediction state is not valid, so call `reset`.
    pub fn encode(self: *PacketEncoder, pcm: []const f32, out: []u8) Error!usize {
        const frame_size = self.frame_size;
        const cc: usize = self.channels;
        if (pcm.len < frame_size * cc) return error.InvalidFrameSize;
        if (out.len == 0) return error.BufferTooSmall;
        const out_data_bytes: i32 = @intCast(@min(out.len, 1 << 30));
        var max_data_bytes: i32 = @min(max_packet * 6, out_data_bytes);
        self.final_range = 0;
        if (max_data_bytes == 1 and self.fs == frame_size * 10) return error.BufferTooSmall;
        const data = out[0..@intCast(out_data_bytes)];

        const is_silence = isDigitalSilence(pcm[0 .. frame_size * cc], self.lsb_depth);
        var stereo_width: f32 = 0;
        if (self.channels == 2 and self.force_channels != 1) {
            stereo_width = self.computeStereoWidth(pcm[0 .. frame_size * 2], frame_size);
        }
        self.bitrate_bps = self.userBitrate(frame_size, max_data_bytes);
        const frame_rate: i32 = @intCast(self.fs / frame_size);
        var cbr_bytes: i32 = -1;
        if (!self.options.vbr) {
            cbr_bytes = @min(@divTrunc(bitrateToBits(self.fs, self.bitrate_bps, frame_size) + 4, 8), max_data_bytes);
            self.bitrate_bps = bitsToBitrate(self.fs, cbr_bytes * 8, frame_size);
            max_data_bytes = @max(1, cbr_bytes);
        }
        if (max_data_bytes < 3 or self.bitrate_bps < 3 * frame_rate * 8 or
            (frame_rate < 50 and (max_data_bytes * frame_rate < 300 or self.bitrate_bps < 2400)))
        {
            return self.emptyPacket(data, max_data_bytes, frame_rate);
        }
        const max_rate = bitsToBitrate(self.fs, max_data_bytes * 8, frame_size);

        const loss: i32 = self.silk_ctl.packet_loss_percentage;
        var equiv_rate = self.equivalentRate(self.bitrate_bps, self.channels, frame_rate, null, loss);
        const voice_est: i32 = if (self.options.application == .voip) 115 else 48;

        if (self.force_channels != null and self.channels == 2) {
            self.stream_channels = self.force_channels.?;
        } else if (self.channels == 2) {
            var stereo_threshold: i32 = 17000 + ((voice_est * voice_est * (19000 - 17000)) >> 14);
            stereo_threshold += if (self.stream_channels == 2) -1000 else 1000;
            self.stream_channels = if (equiv_rate > stereo_threshold) 2 else 1;
        } else {
            self.stream_channels = self.channels;
        }
        equiv_rate = self.equivalentRate(self.bitrate_bps, self.stream_channels, frame_rate, null, loss);
        self.silk_ctl.use_dtx = false;

        if (self.options.application == .low_delay) {
            self.mode = .celt_only;
        } else if (self.forced_mode) |forced| {
            self.mode = forced;
        } else {
            const mode_voice: i32 = truncF32((1.0 - stereo_width) * 64000.0 + stereo_width * 44000.0);
            const mode_music: i32 = truncF32((1.0 - stereo_width) * 10000.0 + stereo_width * 10000.0);
            var threshold: i32 = mode_music + ((voice_est * voice_est * (mode_voice - mode_music)) >> 14);
            if (self.options.application == .voip) threshold += 8000;
            if (self.prev_mode) |pm| {
                if (pm == .celt_only) threshold -= 4000 else threshold += 4000;
            }
            self.mode = if (equiv_rate >= threshold) .celt_only else .silk_only;
            if (self.silk_ctl.use_in_band_fec and self.silk_ctl.packet_loss_percentage > (128 - voice_est) >> 4) {
                self.mode = .silk_only;
            }
            if (max_data_bytes < @divTrunc(bitrateToBits(self.fs, if (frame_rate > 50) 9000 else 6000, frame_size), 8)) {
                self.mode = .celt_only;
            }
        }
        if (self.mode != .celt_only and frame_size < self.fs / 100) self.mode = .celt_only;
        if (self.celt.settings.lfe) self.mode = .celt_only;

        var redundancy = false;
        var celt_to_silk = false;
        var to_celt = false;
        if (self.prev_mode) |pm| {
            if ((self.mode != .celt_only and pm == .celt_only) or (self.mode == .celt_only and pm != .celt_only)) {
                redundancy = true;
                celt_to_silk = self.mode != .celt_only;
                if (!celt_to_silk) {
                    if (frame_size >= self.fs / 100) {
                        self.mode = pm;
                        to_celt = true;
                    } else {
                        redundancy = false;
                    }
                }
            }
        }

        if (self.stream_channels == 1 and self.prev_channels == 2 and !self.silk_ctl.to_mono and
            self.mode != .celt_only and self.prev_mode != Mode.celt_only)
        {
            self.silk_ctl.to_mono = true;
            self.stream_channels = 2;
        } else {
            self.silk_ctl.to_mono = false;
        }

        equiv_rate = self.equivalentRate(self.bitrate_bps, self.stream_channels, frame_rate, self.mode, loss);

        var prefill: u32 = 0;
        if (self.mode != .celt_only and self.prev_mode == Mode.celt_only) {
            self.silk.reset(self.channels);
            prefill = 1;
        }

        if (self.mode == .celt_only or self.first or self.silk_ctl.allow_bandwidth_switch) {
            var thresholds: [8]i32 = undefined;
            for (&thresholds, music_thresholds, voice_thresholds) |*t, music, voice| {
                t.* = music + ((voice_est * voice_est * (voice - music)) >> 14);
            }
            var bandwidth: i32 = bwInt(.full);
            while (true) {
                const step: usize = @intCast(2 * (bandwidth - bwInt(.medium)));
                var threshold = thresholds[step];
                const hysteresis = thresholds[step + 1];
                if (!self.first) {
                    if (bwInt(self.auto_bandwidth) >= bandwidth) {
                        threshold -= hysteresis;
                    } else {
                        threshold += hysteresis;
                    }
                }
                if (equiv_rate >= threshold) break;
                bandwidth -= 1;
                if (bandwidth <= bwInt(.narrow)) break;
            }
            if (bandwidth == bwInt(.medium)) bandwidth = bwInt(.wide);
            self.bandwidth = bwFromInt(bandwidth);
            self.auto_bandwidth = self.bandwidth;
            if (!self.first and self.mode != .celt_only and !self.silk_ctl.in_wb_mode_without_variable_lp and bwInt(self.bandwidth) > bwInt(.wide)) {
                self.bandwidth = .wide;
            }
        }
        if (self.user_bandwidth) |user| self.bandwidth = user;
        if (self.mode != .celt_only and max_rate < 15000) {
            if (bwInt(self.bandwidth) > bwInt(.wide)) self.bandwidth = .wide;
        }
        if (bwInt(self.bandwidth) > bwInt(self.input_bandwidth)) self.bandwidth = self.input_bandwidth;
        if (self.fs <= 24000 and bwInt(self.bandwidth) > bwInt(.super_wide)) self.bandwidth = .super_wide;
        if (self.fs <= 16000 and bwInt(self.bandwidth) > bwInt(.wide)) self.bandwidth = .wide;
        if (self.fs <= 12000 and bwInt(self.bandwidth) > bwInt(.medium)) self.bandwidth = .medium;
        if (self.fs <= 8000 and bwInt(self.bandwidth) > bwInt(.narrow)) self.bandwidth = .narrow;

        var bandwidth_v = self.bandwidth;
        self.silk_ctl.lbrr_coded = decideFec(self.silk_ctl.use_in_band_fec, self.silk_ctl.packet_loss_percentage, self.silk_ctl.lbrr_coded, self.mode, &bandwidth_v, equiv_rate);
        self.bandwidth = bandwidth_v;
        if (self.mode == .celt_only and self.bandwidth == .medium) self.bandwidth = .wide;
        if (self.celt.settings.lfe) self.bandwidth = .narrow;
        const curr_bandwidth = self.bandwidth;
        if (self.mode == .silk_only and bwInt(curr_bandwidth) > bwInt(.wide)) self.mode = .hybrid;
        if (self.mode == .hybrid and bwInt(curr_bandwidth) <= bwInt(.wide)) self.mode = .silk_only;

        if ((frame_size > self.fs / 50 and self.mode != .silk_only) or frame_size > 3 * self.fs / 50) {
            var enc_frame_size: u32 = undefined;
            if (self.mode == .silk_only) {
                if (frame_size == 2 * self.fs / 25) {
                    enc_frame_size = self.fs / 25;
                } else if (frame_size == 3 * self.fs / 25) {
                    enc_frame_size = 3 * self.fs / 50;
                } else {
                    enc_frame_size = self.fs / 50;
                }
            } else {
                enc_frame_size = self.fs / 50;
            }
            const nb_frames: usize = frame_size / enc_frame_size;
            const max_header_bytes: i32 = if (nb_frames == 2) 3 else @intCast(2 + (nb_frames - 1) * 2);
            const repacketize_len: i32 = if (self.options.vbr) out_data_bytes else @min(cbr_bytes, out_data_bytes);
            const max_len_sum: i32 = @as(i32, @intCast(nb_frames)) + repacketize_len - max_header_bytes;
            if (max_len_sum < @as(i32, @intCast(2 * nb_frames))) return error.BufferTooSmall;
            var rp: Repacketizer = .{};
            const bak_to_mono = self.silk_ctl.to_mono;
            if (bak_to_mono) {
                self.force_channels = 1;
            } else {
                self.prev_channels = self.stream_channels;
            }
            var tot_size: i32 = 0;
            var dtx_count: usize = 0;
            for (0..nb_frames) |i| {
                self.silk_ctl.to_mono = false;
                const frame_to_celt = to_celt and i == nb_frames - 1;
                const frame_redundancy = redundancy and (frame_to_celt or (!to_celt and i == 0));
                var curr_max = @min(@divTrunc(bitrateToBits(self.fs, self.bitrate_bps, enc_frame_size), 8), @divTrunc(max_len_sum, @as(i32, @intCast(nb_frames))));
                curr_max = @min(max_len_sum - tot_size, @min(curr_max, max_packet));
                if (curr_max < 2) return error.BufferTooSmall;
                const frame_pcm = pcm[i * cc * enc_frame_size ..][0 .. cc * enc_frame_size];
                const silent = isDigitalSilence(frame_pcm, self.lsb_depth);
                const dst = self.scratch.frames[@intCast(tot_size)..][0..@intCast(curr_max)];
                const tmp_len = try self.encodeFrame(frame_pcm, enc_frame_size, dst, silent, frame_redundancy, celt_to_silk, prefill, equiv_rate, frame_to_celt, i < nb_frames - 1);
                if (tmp_len == 1) dtx_count += 1;
                rp.cat(self.scratch.frames[@intCast(tot_size)..][0..tmp_len]) catch return error.EncoderFailed;
                tot_size += @intCast(tmp_len);
            }
            const pad = !self.options.vbr and dtx_count != nb_frames;
            const n = rp.outRange(0, nb_frames, data[0..@intCast(repacketize_len)], pad) catch return error.EncoderFailed;
            self.silk_ctl.to_mono = bak_to_mono;
            return n;
        }
        return self.encodeFrame(pcm[0 .. frame_size * cc], frame_size, data[0..@intCast(max_data_bytes)], is_silence, redundancy, celt_to_silk, prefill, equiv_rate, to_celt, false);
    }

    /// A packet that holds no frame data, which a decoder conceals.
    fn emptyPacket(self: *PacketEncoder, data: []u8, max_data_bytes_in: i32, frame_rate_in: i32) Error!usize {
        var frame_rate = frame_rate_in;
        var tocmode = self.mode;
        var bw = self.bandwidth;
        var packet_code: u8 = 0;
        var num_multiframes: u8 = 0;
        if (frame_rate > 100) tocmode = .celt_only;
        if (frame_rate == 25 and tocmode != .silk_only) {
            frame_rate = 50;
            packet_code = 1;
        }
        if (frame_rate <= 16) {
            if (data.len == 1 or (tocmode == .silk_only and frame_rate != 10)) {
                tocmode = .silk_only;
                packet_code = @intFromBool(frame_rate <= 12);
                frame_rate = if (frame_rate == 12) 25 else 16;
            } else {
                num_multiframes = @intCast(@divTrunc(50, frame_rate));
                frame_rate = 50;
                packet_code = 3;
            }
        }
        if (tocmode == .silk_only and bwInt(bw) > bwInt(.wide)) {
            bw = .wide;
        } else if (tocmode == .celt_only and bw == .medium) {
            bw = .narrow;
        } else if (tocmode == .hybrid and bwInt(bw) <= bwInt(.super_wide)) {
            bw = .super_wide;
        }
        data[0] = genToc(tocmode, @intCast(frame_rate), bw, self.stream_channels) | packet_code;
        var ret: usize = if (packet_code <= 1) 1 else 2;
        const max_data_bytes: usize = @max(@as(usize, @intCast(max_data_bytes_in)), ret);
        if (packet_code == 3) data[1] = num_multiframes;
        self.final_range = 0;
        if (!self.options.vbr) {
            const target = @min(max_data_bytes, data.len);
            ret = try padPacket(data, ret, target);
        }
        return ret;
    }

    /// The rate that a frame of 20 ms would need for the same quality (compute_equiv_rate).
    fn equivalentRate(self: *const PacketEncoder, bitrate: i32, channels: u32, frame_rate: i32, mode: ?Mode, loss: i32) i32 {
        const ch: i32 = @intCast(channels);
        var equiv: i32 = bitrate;
        if (frame_rate > 50) equiv -= (40 * ch + 20) * (frame_rate - 50);
        if (!self.options.vbr) equiv -= @divTrunc(equiv, 12);
        const cx = self.complexity();
        equiv = @divTrunc(equiv * (90 + cx), 100);
        if (mode) |m| {
            switch (m) {
                .silk_only, .hybrid => {
                    if (cx < 2) equiv = @divTrunc(equiv * 4, 5);
                    equiv -= @divTrunc(equiv * loss, 6 * loss + 10);
                },
                .celt_only => if (cx < 5) {
                    equiv = @divTrunc(equiv * 9, 10);
                },
            }
        } else {
            equiv -= @divTrunc(equiv * loss, 12 * loss + 20);
        }
        return equiv;
    }

    /// Narrows the stereo image at low rates, and fades from the width of the last packet to the new
    /// width over the first 2.5 ms (stereo_fade).
    fn fadeStereo(self: *PacketEncoder, buf: []f32, g1_q14: i32, g2_q14: i32, frame_size: usize) void {
        const g1: f32 = 1.0 - @as(f32, @floatFromInt(g1_q14)) * (1.0 / 16384.0);
        const g2: f32 = 1.0 - @as(f32, @floatFromInt(g2_q14)) * (1.0 / 16384.0);
        const window = &celt.tables.window120;
        const inc = 48000 / self.fs;
        const overlap = window.len / inc;
        for (0..frame_size) |i| {
            var g = g2;
            if (i < overlap) {
                const w = window[i * inc] * window[i * inc];
                g = w * g2 + (1.0 - w) * g1;
            }
            const diff = 0.5 * (buf[2 * i] - buf[2 * i + 1]) * g;
            buf[2 * i] -= diff;
            buf[2 * i + 1] += diff;
        }
    }

    /// Fades the gain of all channels from `g1` to `g2` over the overlap (gain_fade).
    fn fadeGain(buf: []f32, g1: f32, g2: f32, frame_size: usize, channels: usize, fs: u32) void {
        const window = &celt.tables.window120;
        const inc = 48000 / fs;
        const overlap = window.len / inc;
        for (0..@min(overlap, frame_size)) |i| {
            const w = window[i * inc] * window[i * inc];
            const g = w * g2 + (1.0 - w) * g1;
            for (0..channels) |c| buf[i * channels + c] = g * buf[i * channels + c];
        }
        for (@min(overlap, frame_size)..frame_size) |i| {
            for (0..channels) |c| buf[i * channels + c] = g2 * buf[i * channels + c];
        }
    }

    fn dcReject(self: *PacketEncoder, in: []const f32, out: []f32) void {
        const coef: f32 = @as(f32, 6.3) * @as(f32, dc_cutoff_hz) / @as(f32, @floatFromInt(self.fs));
        const coef2: f32 = 1 - coef;
        const tiny: f32 = 1e-30;
        const cc: usize = self.channels;
        for (0..cc) |c| {
            var m = self.hp_mem[2 * c];
            var i = c;
            while (i < in.len) : (i += cc) {
                const x = in[i];
                out[i] = x - m;
                m = coef * x + tiny + coef2 * m;
            }
            self.hp_mem[2 * c] = m;
        }
    }

    /// The 60 to 100 Hz high pass filter of the voice application (hp_cutoff).
    fn hpCutoff(self: *PacketEncoder, in: []const f32, cutoff_hz: i32, out: []f32) void {
        const m = silk.macros;
        const fc_q19 = @divTrunc(m.smulbb(2471, cutoff_hz), @as(i32, @intCast(self.fs / 1000)));
        const r_q28 = 268435456 - 471 * fc_q19;
        const b_q28 = [3]i32{ r_q28, (0 -% r_q28) << 1, r_q28 };
        const r_q22 = r_q28 >> 6;
        const a_q28 = [2]i32{ m.smulww(r_q22, m.smulww(fc_q19, fc_q19) - 8388608), m.smulww(r_q22, r_q22) };
        const scale: f32 = 1.0 / 268435456.0;
        const a0: f32 = @as(f32, @floatFromInt(a_q28[0])) * scale;
        const a1: f32 = @as(f32, @floatFromInt(a_q28[1])) * scale;
        const b0: f32 = @as(f32, @floatFromInt(b_q28[0])) * scale;
        const b1: f32 = @as(f32, @floatFromInt(b_q28[1])) * scale;
        const b2: f32 = @as(f32, @floatFromInt(b_q28[2])) * scale;
        const cc: usize = self.channels;
        for (0..cc) |c| {
            var s0 = self.hp_mem[2 * c];
            var s1 = self.hp_mem[2 * c + 1];
            var i = c;
            while (i < in.len) : (i += cc) {
                const inval = in[i];
                const vout = s0 + b0 * inval;
                s0 = s1 - vout * a0 + b1 * inval;
                s1 = -(vout * a1) + b2 * inval + 1e-30;
                out[i] = vout;
            }
            self.hp_mem[2 * c] = s0;
            self.hp_mem[2 * c + 1] = s1;
        }
    }

    fn computeStereoWidth(self: *PacketEncoder, pcm: []const f32, frame_size: usize) f32 {
        const mem = &self.width_mem;
        const frame_rate: i32 = @intCast(self.fs / frame_size);
        const short_alpha: f32 = 25.0 / @as(f32, @floatFromInt(@max(50, frame_rate)));
        var xx: f32 = 0;
        var xy: f32 = 0;
        var yy: f32 = 0;
        var i: usize = 0;
        while (i + 3 < frame_size) : (i += 4) {
            var pxx: f32 = 0;
            var pxy: f32 = 0;
            var pyy: f32 = 0;
            for (0..4) |k| {
                const x = pcm[2 * (i + k)];
                const y = pcm[2 * (i + k) + 1];
                pxx += x * x;
                pxy += x * y;
                pyy += y * y;
            }
            xx += pxx;
            xy += pxy;
            yy += pyy;
        }
        if (!(xx < 1e9) or xx != xx or !(yy < 1e9) or yy != yy) {
            xx = 0;
            xy = 0;
            yy = 0;
        }
        mem.xx += short_alpha * (xx - mem.xx);
        mem.xy = (1.0 - short_alpha) * mem.xy + short_alpha * xy;
        mem.yy += short_alpha * (yy - mem.yy);
        mem.xx = @max(0, mem.xx);
        mem.xy = @max(0, mem.xy);
        mem.yy = @max(0, mem.yy);
        if (@max(mem.xx, mem.yy) > 8e-4) {
            const sqrt_xx = @sqrt(mem.xx);
            const sqrt_yy = @sqrt(mem.yy);
            const qrrt_xx = @sqrt(sqrt_xx);
            const qrrt_yy = @sqrt(sqrt_yy);
            mem.xy = @min(mem.xy, sqrt_xx * sqrt_yy);
            const corr = mem.xy / (1e-15 + sqrt_xx * sqrt_yy);
            const ldiff = 1.0 * @abs(qrrt_xx - qrrt_yy) / (1e-15 + qrrt_xx + qrrt_yy);
            const width = @min(1.0, @sqrt(1.0 - corr * corr)) * ldiff;
            mem.smoothed_width += (width - mem.smoothed_width) / @as(f32, @floatFromInt(frame_rate));
            mem.max_follower = @max(mem.max_follower - 0.02 / @as(f32, @floatFromInt(frame_rate)), mem.smoothed_width);
        }
        return @min(1.0, 20.0 * mem.max_follower);
    }

    /// Lowers the SILK rate of a stream that the other channels of a surround mix mask.
    fn applySurroundMasking(self: *PacketEncoder, mask_in: *const [42]f32, bandwidth: Bandwidth) void {
        var end: usize = 17;
        var srate: f32 = 16000;
        if (bandwidth == .narrow) {
            end = 13;
            srate = 8000;
        } else if (bandwidth == .medium) {
            end = 15;
            srate = 12000;
        }
        var mask_sum: f32 = 0;
        for (0..self.channels) |c| {
            for (0..end) |i| {
                var mask = @max(@min(mask_in[21 * c + i], 0.5), -2.0);
                if (mask > 0) mask = 0.5 * mask;
                mask_sum += mask;
            }
        }
        var masking_depth = mask_sum / @as(f32, @floatFromInt(end)) * @as(f32, @floatFromInt(self.channels));
        masking_depth += 0.2;
        var rate_offset = truncF32(srate * masking_depth);
        rate_offset = @max(rate_offset, @divTrunc(-2 * self.silk_ctl.bit_rate, 3));
        if (bandwidth == .super_wide or bandwidth == .full) {
            self.silk_ctl.bit_rate += @divTrunc(3 * rate_offset, 5);
        } else {
            self.silk_ctl.bit_rate += rate_offset;
        }
    }

    /// Encodes one frame of `frame_size` samples. `data` has the room for the packet, `data[0]`
    /// is the TOC byte. Returns the length of the packet.
    fn encodeFrame(
        self: *PacketEncoder,
        pcm: []const f32,
        frame_size: u32,
        data: []u8,
        is_silence: bool,
        redundancy_in: bool,
        celt_to_silk_in: bool,
        prefill_in: u32,
        equiv_rate: i32,
        to_celt: bool,
        nonfinal_frame: bool,
    ) Error!usize {
        const cc: usize = self.channels;
        const orig_max_data_bytes: i32 = @intCast(data.len);
        const max_data_bytes: i32 = @min(orig_max_data_bytes, max_packet);
        self.final_range = 0;
        var curr_bandwidth = self.bandwidth;
        const delay_comp: u32 = if (self.options.application == .low_delay) 0 else (self.fs / 250);
        const total_buffer: usize = delay_comp;
        const frame_rate: i32 = @intCast(self.fs / frame_size);
        var redundancy = redundancy_in;
        var celt_to_silk = celt_to_silk_in;
        var prefill = prefill_in;
        var redundancy_bytes: i32 = 0;
        var activity: silk.enc_state.Activity = .no_decision;
        if (is_silence) activity = .no_activity;

        if (self.silk_bw_switch) {
            redundancy = true;
            celt_to_silk = true;
            self.silk_bw_switch = false;
            prefill = 2;
        }
        if (self.mode == .celt_only) redundancy = false;
        if (redundancy) {
            redundancy_bytes = computeRedundancyBytes(max_data_bytes, self.bitrate_bps, frame_rate, self.stream_channels);
            if (redundancy_bytes == 0) redundancy = false;
        }

        const bits_target: i32 = @min(8 * (max_data_bytes - redundancy_bytes), bitrateToBits(self.fs, self.bitrate_bps, frame_size)) - 8;

        var enc = range.Encoder.init(data[1..]);
        const pcm_buf = self.scratch.pcm_buf[0 .. (total_buffer + frame_size) * cc];
        @memcpy(pcm_buf[0 .. total_buffer * cc], self.delay_buffer[((self.fs / 100) - total_buffer) * cc ..][0 .. total_buffer * cc]);

        var hp_freq_smth1: i32 = undefined;
        if (self.mode == .celt_only) {
            hp_freq_smth1 = silk.macros.lin2log(60) << 8;
        } else {
            hp_freq_smth1 = self.silk.channels[0].variable_hp_smth1_q15;
        }
        self.variable_hp_smth2_q15 = silk.macros.smlawb(self.variable_hp_smth2_q15, hp_freq_smth1 - self.variable_hp_smth2_q15, 983);
        const cutoff_hz = silk.macros.log2lin(self.variable_hp_smth2_q15 >> 8);

        const new_pcm = pcm_buf[total_buffer * cc ..][0 .. frame_size * cc];
        if (self.options.application == .voip) {
            self.hpCutoff(pcm[0 .. frame_size * cc], cutoff_hz, new_pcm);
        } else {
            self.dcReject(pcm[0 .. frame_size * cc], new_pcm);
        }
        var sum: f32 = 0;
        for (new_pcm) |v| sum += v * v;
        if (!(sum < 1e9) or sum != sum) {
            @memset(new_pcm, 0);
            self.hp_mem = @splat(0);
        }

        var hb_gain: f32 = 1.0;
        var nbytes: i32 = 0;
        if (self.mode != .celt_only) {
            const total_bitrate = bitsToBitrate(self.fs, bits_target, frame_size);
            if (self.mode == .hybrid) {
                self.silk_ctl.bit_rate = computeSilkRateForHybrid(total_bitrate, curr_bandwidth, self.fs == 50 * frame_size, self.options.vbr, self.silk_ctl.lbrr_coded, self.stream_channels);
                if (self.celt.settings.energy_mask == null) {
                    const celt_rate = total_bitrate - self.silk_ctl.bit_rate;
                    hb_gain = 1.0 - celt.bands.exp2f(@as(f32, @floatFromInt(-celt_rate)) * (1.0 / 1024.0));
                }
            } else {
                self.silk_ctl.bit_rate = total_bitrate;
            }
            if (self.celt.settings.energy_mask) |mask| {
                if (self.options.vbr and !self.celt.settings.lfe) self.applySurroundMasking(&mask, curr_bandwidth);
            }
            const c = &self.silk_ctl;
            c.payload_size_ms = @intCast(1000 * frame_size / self.fs);
            c.n_channels_api = @intCast(self.channels);
            c.n_channels_internal = @intCast(self.stream_channels);
            c.desired_internal_sample_rate = switch (curr_bandwidth) {
                .narrow => 8000,
                .medium => 12000,
                else => 16000,
            };
            c.min_internal_sample_rate = if (self.mode == .hybrid) 16000 else 8000;
            c.max_internal_sample_rate = 16000;
            if (self.mode == .silk_only) {
                var effective_max_rate = bitsToBitrate(self.fs, max_data_bytes * 8, frame_size);
                if (frame_rate > 50) effective_max_rate = @divTrunc(effective_max_rate * 2, 3);
                if (effective_max_rate < 8000) {
                    c.max_internal_sample_rate = 12000;
                    c.desired_internal_sample_rate = @min(12000, c.desired_internal_sample_rate);
                }
                if (effective_max_rate < 7000) {
                    c.max_internal_sample_rate = 8000;
                    c.desired_internal_sample_rate = @min(8000, c.desired_internal_sample_rate);
                }
            }
            c.use_cbr = !self.options.vbr;
            c.complexity = self.complexity();
            c.max_bits = (max_data_bytes - 1) * 8;
            if (redundancy and redundancy_bytes >= 2) {
                c.max_bits -= redundancy_bytes * 8 + 1;
                if (self.mode == .hybrid) c.max_bits -= 20;
            }
            if (c.use_cbr) {
                if (self.mode == .hybrid) {
                    const raw_other: i32 = c.max_bits - @divTrunc(c.bit_rate * @as(i32, @intCast(frame_size)), @as(i32, @intCast(self.fs)));
                    const other_bits: i32 = @as(i16, @truncate(if (raw_other > 0) raw_other else 0));
                    c.max_bits = @max(0, c.max_bits - @divTrunc(other_bits * 3, 4));
                    c.use_cbr = false;
                }
            } else if (self.mode == .hybrid) {
                const max_bit_rate = computeSilkRateForHybrid(@divTrunc(c.max_bits * @as(i32, @intCast(self.fs)), @as(i32, @intCast(frame_size))), curr_bandwidth, self.fs == 50 * frame_size, self.options.vbr, c.lbrr_coded, self.stream_channels);
                c.max_bits = bitrateToBits(self.fs, max_bit_rate, frame_size);
            }

            if (prefill != 0) {
                const prefill_offset: usize = cc * ((self.fs / 100) - delay_comp - self.fs / 400);
                fadeGain(self.delay_buffer[prefill_offset..], 0.0, 1.0, self.fs / 400, cc, self.fs);
                @memset(self.delay_buffer[0..prefill_offset], 0);
                var zero: i32 = 0;
                silk.encode.encode(&self.silk, c, &self.delay_buffer, (self.fs / 100), null, &zero, prefill, activity) catch return error.EncoderFailed;
                c.opus_can_switch = false;
            }

            silk.encode.encode(&self.silk, c, pcm_buf[total_buffer * cc ..], frame_size, &enc, &nbytes, 0, activity) catch return error.EncoderFailed;

            if (self.mode == .silk_only) {
                curr_bandwidth = switch (c.internal_sample_rate) {
                    8000 => .narrow,
                    12000 => .medium,
                    else => .wide,
                };
            }
            c.opus_can_switch = c.switch_ready and !nonfinal_frame;
            if (nbytes == 0) {
                self.final_range = 0;
                data[0] = genToc(self.mode, @intCast(frame_rate), curr_bandwidth, self.stream_channels);
                return 1;
            }
            if (c.opus_can_switch) {
                redundancy_bytes = computeRedundancyBytes(max_data_bytes, self.bitrate_bps, frame_rate, self.stream_channels);
                redundancy = redundancy_bytes != 0;
                celt_to_silk = false;
                self.silk_bw_switch = true;
            }
        }

        // CELT processing.
        const endband: u32 = switch (curr_bandwidth) {
            .narrow => 13,
            .medium, .wide => 17,
            .super_wide => 19,
            .full => 21,
        };
        self.celt.end = endband;
        self.celt.settings.lsb_depth = self.lsb_depth;
        self.celt.stream_channels = self.stream_channels;
        self.celt.settings.bitrate = null;
        if (self.mode != .silk_only) {
            self.celt.settings.force_intra = false;
            self.celt.settings.disable_pf = false;
        }

        const prefill_len = cc * (self.fs / 400);
        const tmp_prefill = self.scratch.prefill[0..prefill_len];
        if (self.mode != .silk_only and self.prev_mode != null and self.mode != self.prev_mode.?) {
            @memcpy(tmp_prefill, self.delay_buffer[((self.fs / 100) - total_buffer - self.fs / 400) * cc ..][0..prefill_len]);
        }

        const keep: i64 = @as(i64, (self.fs / 100)) - @as(i64, frame_size) - @as(i64, @intCast(total_buffer));
        if (keep > 0) {
            const k: usize = @intCast(keep);
            std.mem.copyForwards(f32, self.delay_buffer[0 .. cc * k], self.delay_buffer[cc * frame_size ..][0 .. cc * k]);
            @memcpy(self.delay_buffer[cc * k ..][0 .. (frame_size + total_buffer) * cc], pcm_buf[0 .. (frame_size + total_buffer) * cc]);
        } else {
            @memcpy(self.delay_buffer[0 .. (self.fs / 100) * cc], pcm_buf[(frame_size + total_buffer - (self.fs / 100)) * cc ..][0 .. (self.fs / 100) * cc]);
        }
        if (self.prev_hb_gain < 1.0 or hb_gain < 1.0) {
            fadeGain(pcm_buf[0 .. frame_size * cc], self.prev_hb_gain, hb_gain, frame_size, cc, self.fs);
        }
        self.prev_hb_gain = hb_gain;
        if (self.mode != .hybrid or self.stream_channels == 1) {
            if (equiv_rate > 32000) {
                self.silk_ctl.stereo_width_q14 = 16384;
            } else if (equiv_rate < 16000) {
                self.silk_ctl.stereo_width_q14 = 0;
            } else {
                self.silk_ctl.stereo_width_q14 = 16384 - @divTrunc(2048 * (32000 - equiv_rate), equiv_rate - 14000);
            }
        }
        if (self.celt.settings.energy_mask == null and self.channels == 2) {
            if (self.hybrid_stereo_width_q14 < 16384 or self.silk_ctl.stereo_width_q14 < 16384) {
                self.fadeStereo(pcm_buf[0 .. frame_size * 2], self.hybrid_stereo_width_q14, self.silk_ctl.stereo_width_q14, frame_size);
                self.hybrid_stereo_width_q14 = self.silk_ctl.stereo_width_q14;
            }
        }

        const hybrid = self.mode == .hybrid;
        if (self.mode != .celt_only and enc.tell() + 17 + @as(i32, if (hybrid) 20 else 0) <= 8 * (max_data_bytes - 1)) {
            if (hybrid) enc.encodeBitLogp(redundancy, 12);
            if (redundancy) {
                enc.encodeBitLogp(celt_to_silk, 1);
                var max_redundancy: i32 = undefined;
                if (hybrid) {
                    max_redundancy = (max_data_bytes - 1) - ((enc.tell() + 8 + 3 + 7) >> 3);
                } else {
                    max_redundancy = (max_data_bytes - 1) - ((enc.tell() + 7) >> 3);
                }
                redundancy_bytes = @min(max_redundancy, redundancy_bytes);
                redundancy_bytes = @min(257, @max(2, redundancy_bytes));
                if (hybrid) enc.encodeUint(@intCast(redundancy_bytes - 2), 256);
            }
        } else {
            redundancy = false;
        }
        if (!redundancy) {
            self.silk_bw_switch = false;
            redundancy_bytes = 0;
        }
        const start_band: u32 = if (self.mode != .celt_only) 17 else 0;

        var ret: i32 = 0;
        var nb_compr_bytes: i32 = undefined;
        if (self.mode == .silk_only) {
            ret = (enc.tell() + 7) >> 3;
            enc.done();
            nb_compr_bytes = ret;
        } else {
            nb_compr_bytes = (max_data_bytes - 1) - redundancy_bytes;
            enc.shrink(@intCast(nb_compr_bytes));
        }

        if (hybrid) {
            self.celt.settings.silk_signal_type = @intCast(self.silk_ctl.signal_type);
            self.celt.settings.silk_offset = self.silk_ctl.offset;
        }

        var redundant_rng: u32 = 0;
        const lm_red: u32 = 1;
        if (redundancy and celt_to_silk) {
            self.celt.settings.vbr = false;
            self.celt.settings.bitrate = null;
            const dst = data[1 + @as(usize, @intCast(nb_compr_bytes)) ..][0..@intCast(redundancy_bytes)];
            _ = try self.celt.encodeFrom(pcm_buf[0 .. (self.fs / 200) * cc], lm_red, dst, 0);
            redundant_rng = self.celt.finalRange();
            self.celt.reset();
        }

        data[0] = 0;
        if (self.mode != .silk_only) {
            self.celt.settings.vbr = self.options.vbr;
            const toc_bits: u32 = if (self.toc_overhead) @intCast(8 * frame_rate) else 0;
            if (hybrid) {
                if (self.options.vbr) {
                    const celt_rate = self.bitrate_bps - self.silk_ctl.bit_rate;
                    if (celt_rate > 500) self.celt.settings.bitrate = @intCast(@max(0, celt_rate - @as(i32, @intCast(toc_bits))));
                    self.celt.settings.constrained_vbr = false;
                }
            } else if (self.options.vbr) {
                self.celt.settings.vbr = true;
                self.celt.settings.constrained_vbr = true;
                if (self.bitrate_bps > 500) self.celt.settings.bitrate = @intCast(@max(0, self.bitrate_bps - @as(i32, @intCast(toc_bits))));
            }
            if (self.prev_mode != null and self.mode != self.prev_mode.?) {
                self.celt.reset();
                var dummy: [2]u8 = undefined;
                _ = try self.celt.encodeFrom(tmp_prefill, 0, &dummy, start_band);
                self.celt.settings.force_intra = true;
                self.celt.settings.disable_pf = true;
            }
            if (enc.tell() <= 8 * nb_compr_bytes) {
                const lm: u32 = @intCast(std.math.log2_int(u32, frame_size * (48000 / self.fs) / 120));
                const used = try self.celt.encodeWithEc(pcm_buf[0 .. frame_size * cc], lm, &enc, @intCast(nb_compr_bytes), start_band);
                ret = @intCast(used);
                if (redundancy and celt_to_silk and self.mode == .hybrid and nb_compr_bytes != ret) {
                    std.mem.copyForwards(u8, data[1 + @as(usize, @intCast(ret)) ..][0..@intCast(redundancy_bytes)], data[1 + @as(usize, @intCast(nb_compr_bytes)) ..][0..@intCast(redundancy_bytes)]);
                    nb_compr_bytes = ret + redundancy_bytes;
                }
            }
            self.final_range = self.celt.finalRange();
        } else {
            self.final_range = enc.rng;
        }

        if (redundancy and !celt_to_silk) {
            const n2: usize = self.fs / 200;
            const n4: usize = self.fs / 400;
            self.celt.reset();
            self.celt.settings.force_intra = true;
            self.celt.settings.disable_pf = true;
            self.celt.settings.vbr = false;
            self.celt.settings.bitrate = null;
            if (self.mode == .hybrid) {
                nb_compr_bytes = ret;
                enc.shrink(@intCast(nb_compr_bytes));
            }
            var dummy: [2]u8 = undefined;
            _ = try self.celt.encodeFrom(pcm_buf[cc * (frame_size - n2 - n4) ..][0 .. n4 * cc], 0, &dummy, 0);
            const dst = data[1 + @as(usize, @intCast(nb_compr_bytes)) ..][0..@intCast(redundancy_bytes)];
            _ = try self.celt.encodeFrom(pcm_buf[cc * (frame_size - n2) ..][0 .. n2 * cc], lm_red, dst, 0);
            redundant_rng = self.celt.finalRange();
        }

        data[0] |= genToc(self.mode, @intCast(frame_rate), curr_bandwidth, self.stream_channels);
        self.final_range ^= redundant_rng;
        self.prev_mode = if (to_celt) Mode.celt_only else self.mode;
        self.prev_channels = self.stream_channels;
        self.first = false;

        if (enc.tell() > (max_data_bytes - 1) * 8) {
            if (max_data_bytes < 2) return error.BufferTooSmall;
            data[1] = 0;
            ret = 1;
            self.final_range = 0;
        } else if (self.mode == .silk_only and !redundancy) {
            while (ret > 2 and data[@intCast(ret)] == 0) ret -= 1;
        }
        ret += 1 + redundancy_bytes;
        const len: usize = @intCast(ret);
        if (!self.options.vbr) return padPacket(data, len, data.len);
        return len;
    }
};

const truncF32 = celt.encode.truncInt;
const bitrateToBits = celt.rate.bitrateToBits;
const bitsToBitrate = celt.rate.bitsToBitrate;

fn isDigitalSilence(pcm: []const f32, lsb_depth: u5) bool {
    var max: f32 = 0;
    for (pcm) |v| max = @max(max, @abs(v));
    return max <= 1.0 / @as(f32, @floatFromInt(@as(u32, 1) << lsb_depth));
}

/// The bytes of a redundant frame, or 0 when there is too little room for one.
fn computeRedundancyBytes(max_data_bytes: i32, bitrate_bps: i32, frame_rate: i32, channels: u32) i32 {
    const ch: i32 = @intCast(channels);
    const base_bits = 40 * ch + 20;
    var redundancy_rate = bitrate_bps + base_bits * (200 - frame_rate);
    redundancy_rate = @divTrunc(3 * redundancy_rate, 2);
    var redundancy_bytes = @divTrunc(redundancy_rate, 1600);
    const available_bits = max_data_bytes * 8 - 2 * base_bits;
    const cap = @divTrunc(@divTrunc(available_bits * 240, 240 + @divTrunc(48000, frame_rate)) + base_bits, 8);
    redundancy_bytes = @min(redundancy_bytes, cap);
    if (redundancy_bytes > 4 + 8 * ch) return @min(257, redundancy_bytes);
    return 0;
}

/// The part of the rate that SILK gets in a hybrid frame.
fn computeSilkRateForHybrid(rate_in: i32, bandwidth: Bandwidth, frame20ms: bool, vbr: bool, fec: bool, channels: u32) i32 {
    const table = [7][5]i32{
        .{ 0, 0, 0, 0, 0 },
        .{ 12000, 10000, 10000, 11000, 11000 },
        .{ 16000, 13500, 13500, 15000, 15000 },
        .{ 20000, 16000, 16000, 18000, 18000 },
        .{ 24000, 18000, 18000, 21000, 21000 },
        .{ 32000, 22000, 22000, 28000, 28000 },
        .{ 64000, 38000, 38000, 50000, 50000 },
    };
    const ch: i32 = @intCast(channels);
    const rate = @divTrunc(rate_in, ch);
    const entry: usize = 1 + @as(usize, @intFromBool(frame20ms)) + 2 * @as(usize, @intFromBool(fec));
    var i: usize = 1;
    while (i < table.len) : (i += 1) {
        if (table[i][0] > rate) break;
    }
    var silk_rate: i32 = undefined;
    if (i == table.len) {
        silk_rate = table[i - 1][entry];
        silk_rate += @divTrunc(rate - table[i - 1][0], 2);
    } else {
        const lo = table[i - 1][entry];
        const hi = table[i][entry];
        const x0 = table[i - 1][0];
        const x1 = table[i][0];
        silk_rate = @divTrunc(lo * (x1 - rate) + hi * (rate - x0), x1 - x0);
    }
    if (!vbr) silk_rate += 100;
    if (bandwidth == .super_wide) silk_rate += 300;
    silk_rate *= ch;
    if (ch == 2 and rate >= 12000) silk_rate -= 1000;
    return silk_rate;
}

/// Decides whether the SILK layer codes redundancy for the previous frame, and may lower the
/// bandwidth so that it can (decide_fec).
fn decideFec(use_in_band_fec: bool, packet_loss_perc: i32, last_fec: bool, mode: Mode, bandwidth: *Bandwidth, rate: i32) bool {
    if (!use_in_band_fec or packet_loss_perc == 0 or mode == .celt_only) return false;
    const orig = bandwidth.*;
    while (true) {
        const idx: usize = @intCast(2 * (bwInt(bandwidth.*) - bwInt(.narrow)));
        var thres = fec_thresholds[idx];
        const hysteresis = fec_thresholds[idx + 1];
        if (last_fec) thres -= hysteresis else thres += hysteresis;
        thres = silk.macros.smulwb(thres * (125 - @min(packet_loss_perc, 25)), 655);
        if (rate > thres) {
            return true;
        } else if (packet_loss_perc <= 5) {
            return false;
        } else if (bwInt(bandwidth.*) > bwInt(.narrow)) {
            bandwidth.* = bwFromInt(bwInt(bandwidth.*) - 1);
        } else break;
    }
    bandwidth.* = orig;
    return false;
}

fn genToc(mode: Mode, frame_rate_in: u32, bandwidth: Bandwidth, channels: u32) u8 {
    var framerate = frame_rate_in;
    var period: u32 = 0;
    while (framerate < 400) {
        framerate <<= 1;
        period += 1;
    }
    var toc: u8 = undefined;
    switch (mode) {
        .silk_only => {
            toc = @intCast((bwInt(bandwidth) - bwInt(.narrow)) << 5);
            toc |= @intCast((period -% 2) << 3);
        },
        .celt_only => {
            const tmp: i32 = @max(bwInt(bandwidth) - bwInt(.medium), 0);
            toc = 0x80;
            toc |= @intCast(tmp << 5);
            toc |= @intCast(period << 3);
        },
        .hybrid => {
            toc = 0x60;
            toc |= @intCast((bwInt(bandwidth) - bwInt(.super_wide)) << 4);
            toc |= @intCast((period -% 2) << 3);
        },
    }
    toc |= @as(u8, @intFromBool(channels == 2)) << 2;
    return toc;
}

/// Pads the packet in `data[0..len]` with the padding of a code 3 packet to `new_len` bytes.
/// Returns the new length.
fn padPacket(data: []u8, len: usize, new_len: usize) Error!usize {
    if (len >= new_len) return len;
    var rp: Repacketizer = .{};
    std.mem.copyBackwards(u8, data[new_len - len ..][0..len], data[0..len]);
    const moved = data[new_len - len ..][0..len];
    rp.cat(moved) catch return error.EncoderFailed;
    return rp.outRange(0, rp.count, data[0..new_len], true) catch error.EncoderFailed;
}

/// Joins the frames of several single frame packets into one packet (opus_repacketizer).
pub const Repacketizer = struct {
    toc: u8 = 0,
    count: usize = 0,
    frames: [48][]const u8 = undefined,

    const RepackError = error{InvalidPacket};

    pub fn cat(self: *Repacketizer, data: []const u8) RepackError!void {
        if (data.len < 1) return error.InvalidPacket;
        if (self.count == 0) {
            self.toc = data[0];
        } else if ((self.toc & 0xFC) != (data[0] & 0xFC)) {
            return error.InvalidPacket;
        }
        const p = packet.parse(data, false) catch return error.InvalidPacket;
        if (self.count + p.count > 48) return error.InvalidPacket;
        for (0..p.count) |i| {
            self.frames[self.count] = p.frames[i];
            self.count += 1;
        }
    }

    pub fn outRange(self: *Repacketizer, begin: usize, end: usize, out: []u8, pad: bool) RepackError!usize {
        return self.outRangeImpl(begin, end, out, false, pad);
    }

    /// A self delimited packet carries the size of its last frame, so that packets can follow
    /// each other in one buffer.
    pub fn outRangeImpl(self: *Repacketizer, begin: usize, end: usize, out: []u8, self_delimited: bool, pad: bool) RepackError!usize {
        std.debug.assert(begin < end and end <= self.count);
        const count = end - begin;
        const frames = self.frames[begin..end];
        const maxlen = out.len;
        var tot_size: usize = if (self_delimited) 1 + @as(usize, @intFromBool(frames[count - 1].len >= 252)) else 0;
        var ptr: usize = 0;
        if (count == 1) {
            tot_size += frames[0].len + 1;
            if (tot_size > maxlen) return error.InvalidPacket;
            out[ptr] = self.toc & 0xFC;
            ptr += 1;
        } else if (count == 2) {
            if (frames[1].len == frames[0].len) {
                tot_size += 2 * frames[0].len + 1;
                if (tot_size > maxlen) return error.InvalidPacket;
                out[ptr] = (self.toc & 0xFC) | 1;
                ptr += 1;
            } else {
                tot_size += frames[0].len + frames[1].len + 2 + @as(usize, @intFromBool(frames[0].len >= 252));
                if (tot_size > maxlen) return error.InvalidPacket;
                out[ptr] = (self.toc & 0xFC) | 2;
                ptr += 1;
                var sz: [2]u8 = undefined;
                const n = packet.encodeSize(@intCast(frames[0].len), &sz);
                @memcpy(out[ptr..][0..n], sz[0..n]);
                ptr += n;
            }
        }
        if (count > 2 or (pad and tot_size < maxlen)) {
            ptr = 0;
            tot_size = if (self_delimited) 1 + @as(usize, @intFromBool(frames[count - 1].len >= 252)) else 0;
            var vbr = false;
            for (1..count) |i| {
                if (frames[i].len != frames[0].len) {
                    vbr = true;
                    break;
                }
            }
            if (vbr) {
                tot_size += 2;
                for (0..count - 1) |i| tot_size += 1 + @as(usize, @intFromBool(frames[i].len >= 252)) + frames[i].len;
                tot_size += frames[count - 1].len;
                if (tot_size > maxlen) return error.InvalidPacket;
                out[ptr] = (self.toc & 0xFC) | 3;
                out[ptr + 1] = @intCast(count | 0x80);
                ptr += 2;
            } else {
                tot_size += count * frames[0].len + 2;
                if (tot_size > maxlen) return error.InvalidPacket;
                out[ptr] = (self.toc & 0xFC) | 3;
                out[ptr + 1] = @intCast(count);
                ptr += 2;
            }
            const pad_amount: usize = if (pad) maxlen - tot_size else 0;
            if (pad_amount != 0) {
                out[1] |= 0x40;
                const nb_255s = (pad_amount - 1) / 255;
                if (tot_size + nb_255s + 1 > maxlen) return error.InvalidPacket;
                for (0..nb_255s) |_| {
                    out[ptr] = 255;
                    ptr += 1;
                }
                out[ptr] = @intCast(pad_amount - 255 * nb_255s - 1);
                ptr += 1;
                tot_size += pad_amount;
            }
            if (vbr) {
                for (0..count - 1) |i| {
                    var sz: [2]u8 = undefined;
                    const n = packet.encodeSize(@intCast(frames[i].len), &sz);
                    @memcpy(out[ptr..][0..n], sz[0..n]);
                    ptr += n;
                }
            }
        }
        if (self_delimited) {
            var sz: [2]u8 = undefined;
            const n = packet.encodeSize(@intCast(frames[count - 1].len), &sz);
            @memcpy(out[ptr..][0..n], sz[0..n]);
            ptr += n;
        }
        for (0..count) |i| {
            std.mem.copyForwards(u8, out[ptr..][0..frames[i].len], frames[i]);
            ptr += frames[i].len;
        }
        if (pad) @memset(out[ptr..], 0);
        return tot_size;
    }
};
