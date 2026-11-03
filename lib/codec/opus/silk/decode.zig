//! SILK decoder ported from libopus silk/dec_API.c, decode_frame.c, decode_core.c and decode_indices.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const range = @import("../range.zig");
const m = @import("macros.zig");
const tables = @import("tables.zig");
const lpc = @import("lpc.zig");
const nlsf = @import("nlsf.zig");
const excitation = @import("excitation.zig");
const pitch = @import("pitch.zig");
const stereo = @import("stereo.zig");
const Resampler = @import("resampler.zig").Resampler;
const plc_mod = @import("plc.zig");

pub const max_frame_length = 320;
const max_subfr = 4;
const max_subfr_length = 80;
const max_ltp_mem = 320;
const out_buf_len = max_frame_length + 2 * max_subfr_length;
const ltp_order = pitch.ltp_order;
const max_frames_per_packet = 3;
const type_voiced = 2;
const bwe_after_loss_q16 = 63570;

pub const Error = error{BufferTooSmall};

/// How the first values of a frame depend on the frame before it.
const Cond = enum { independently, independently_no_ltp_scaling, conditionally };

/// The decoded side information of one frame.
pub const Indices = struct {
    gains: [max_subfr]u8 = @splat(0),
    nlsf: [17]i8 = @splat(0),
    lag_index: i16 = 0,
    contour_index: u8 = 0,
    nlsf_interp_coef_q2: u8 = 4,
    per_index: u8 = 0,
    ltp_index: [max_subfr]u8 = @splat(0),
    ltp_scale_index: u8 = 0,
    seed: u8 = 0,
    signal_type: u8 = 0,
    quant_offset_type: u8 = 0,
};

/// Values that `decodeParameters` derives for the synthesis of one frame.
pub const Params = struct {
    pitch_l: [max_subfr]i32 = @splat(0),
    gains_q16: [max_subfr]i32 = @splat(0),
    pred_coef_q12: [2][lpc.max_order]i16 = @splat(@splat(0)),
    ltp_coef_q14: [max_subfr * ltp_order]i16 = @splat(0),
    ltp_scale_q14: i32 = 0,
};

/// A low bit rate redundancy frame. It codes the audio of the same time as a regular frame.
pub const LbrrFrame = struct {
    indices: Indices = .{},
    pulses: [excitation.max_pulses]i16 = @splat(0),
};

/// The redundancy frames of the last packet. Frame `i` of channel `n` is valid when
/// `Channel.lbrr_flags[i]` is set.
pub const Lbrr = struct {
    frames: [2][max_frames_per_packet]LbrrFrame = @splat(@splat(.{})),
    /// The stereo prediction and the mid only flag of each frame.
    pred_q13: [max_frames_per_packet]stereo.Prediction = @splat(.{ 0, 0 }),
    only_middle: [max_frames_per_packet]bool = @splat(false),
};

/// The state of one channel.
pub const Channel = struct {
    prev_gain_q16: i32 = 65536,
    exc_q14: [max_frame_length]i32 = @splat(0),
    s_lpc_q14_buf: [lpc.max_order]i32 = @splat(0),
    out_buf: [out_buf_len]i16 = @splat(0),
    lag_prev: i32 = 0,
    last_gain_index: i32 = 0,
    prev_signal_type: u8 = 0,
    first_frame_after_reset: bool = true,
    prev_nlsf_q15: [lpc.max_order]i16 = @splat(0),
    ec_prev_signal_type: u8 = 0,
    ec_prev_lag_index: i16 = 0,
    fs_khz: u32 = 0,
    fs_api_hz: u32 = 0,
    nb_subfr: u32 = 0,
    subfr_length: u32 = 0,
    frame_length: u32 = 0,
    ltp_mem_length: u32 = 0,
    lpc_order: u32 = 0,
    vad_flags: [max_frames_per_packet]bool = @splat(false),
    lbrr_flag: bool = false,
    lbrr_flags: [max_frames_per_packet]bool = @splat(false),
    n_frames_decoded: u32 = 0,
    n_frames_per_packet: u32 = 0,
    indices: Indices = .{},
    resampler: Resampler = Resampler.init(8),
    loss_cnt: i32 = 0,
    plc: plc_mod.State = .{},
    cng: plc_mod.Cng = .{},

    fn codebook(self: *const Channel) *const nlsf.Codebook {
        return if (self.fs_khz == 16) &nlsf.wb else &nlsf.nb_mb;
    }

    fn setFs(self: *Channel, fs_khz: u32) void {
        self.subfr_length = 5 * fs_khz;
        const frame_length = self.nb_subfr * self.subfr_length;
        if (self.fs_khz != fs_khz or self.fs_api_hz != 48000) {
            self.resampler = Resampler.init(fs_khz);
            self.fs_api_hz = 48000;
        }
        if (self.fs_khz != fs_khz or frame_length != self.frame_length) {
            if (self.fs_khz != fs_khz) {
                self.ltp_mem_length = 20 * fs_khz;
                self.lpc_order = if (fs_khz == 16) 16 else 10;
                self.first_frame_after_reset = true;
                self.lag_prev = 100;
                self.last_gain_index = 10;
                self.prev_signal_type = 0;
                self.out_buf = @splat(0);
                self.s_lpc_q14_buf = @splat(0);
            }
            self.fs_khz = fs_khz;
            self.frame_length = frame_length;
        }
    }

    fn decodeIndices(self: *Channel, dec: *range.Decoder, frame_index: usize, decode_lbrr: bool, cond: Cond) void {
        const ind = &self.indices;
        const type_offset: u32 = if (decode_lbrr or self.vad_flags[frame_index])
            dec.icdf(&tables.type_offset_vad_icdf, 8) + 2
        else
            dec.icdf(&tables.type_offset_no_vad_icdf, 8);
        ind.signal_type = @intCast(type_offset >> 1);
        ind.quant_offset_type = @intCast(type_offset & 1);

        if (cond == .conditionally) {
            ind.gains[0] = @intCast(dec.icdf(&tables.delta_gain_icdf, 8));
        } else {
            const high = dec.icdf(tables.gain_icdf[ind.signal_type * 8 ..][0..8], 8);
            ind.gains[0] = @intCast((high << 3) + dec.icdf(&tables.uniform8_icdf, 8));
        }
        for (ind.gains[1..self.nb_subfr]) |*g| g.* = @intCast(dec.icdf(&tables.delta_gain_icdf, 8));

        const cb = self.codebook();
        ind.nlsf[0] = @intCast(dec.icdf(cb.cb1_icdf[(ind.signal_type >> 1) * 32 ..], 8));
        var ec_ix: [lpc.max_order]u16 = undefined;
        var pred_q8: [lpc.max_order]u8 = undefined;
        nlsf.unpack(cb, @intCast(ind.nlsf[0]), &ec_ix, &pred_q8);
        for (0..cb.order) |i| {
            var ix: i32 = @intCast(dec.icdf(cb.ec_icdf[ec_ix[i]..], 8));
            if (ix == 0) {
                ix -= @intCast(dec.icdf(&tables.nlsf_ext_icdf, 8));
            } else if (ix == 8) {
                ix += @intCast(dec.icdf(&tables.nlsf_ext_icdf, 8));
            }
            ind.nlsf[i + 1] = @intCast(ix - 4);
        }
        ind.nlsf_interp_coef_q2 = if (self.nb_subfr == max_subfr)
            @intCast(dec.icdf(&tables.nlsf_interpolation_factor_icdf, 8))
        else
            4;

        if (ind.signal_type == type_voiced) {
            var absolute = true;
            if (cond == .conditionally and self.ec_prev_signal_type == type_voiced) {
                const delta: i32 = @intCast(dec.icdf(&tables.pitch_delta_icdf, 8));
                if (delta > 0) {
                    ind.lag_index = self.ec_prev_lag_index +% @as(i16, @intCast(delta - 9));
                    absolute = false;
                }
            }
            if (absolute) {
                const high: i16 = @intCast(dec.icdf(&tables.pitch_lag_icdf, 8));
                const low: i16 = @intCast(dec.icdf(pitch.lagLowBitsIcdf(self.fs_khz), 8));
                ind.lag_index = high *% @as(i16, @intCast(self.fs_khz >> 1)) +% low;
            }
            self.ec_prev_lag_index = ind.lag_index;
            ind.contour_index = @intCast(dec.icdf(pitch.lagTables(self.fs_khz, self.nb_subfr).contour_icdf, 8));
            ind.per_index = @intCast(dec.icdf(&tables.ltp_per_index_icdf, 8));
            for (ind.ltp_index[0..self.nb_subfr]) |*l| {
                l.* = @intCast(dec.icdf(pitch.ltp_gain_icdfs[ind.per_index], 8));
            }
            ind.ltp_scale_index = if (cond == .independently)
                @intCast(dec.icdf(&tables.ltp_scale_icdf, 8))
            else
                0;
        }
        self.ec_prev_signal_type = ind.signal_type;
        ind.seed = @intCast(dec.icdf(&tables.uniform4_icdf, 8));
    }

    fn gainsDequant(self: *Channel, gains_q16: []i32, conditional: bool) void {
        for (gains_q16, 0..) |*g, k| {
            const ind: i32 = self.indices.gains[k];
            var prev = self.last_gain_index;
            if (k == 0 and !conditional) {
                prev = @max(ind, prev - 16);
            } else {
                const tmp = ind - 4;
                const threshold = 2 * 36 - 64 + prev;
                prev += if (tmp > threshold) (tmp << 1) - threshold else tmp;
            }
            prev = std.math.clamp(prev, 0, 63);
            self.last_gain_index = prev;
            g.* = m.log2lin(@min(m.smulwb(1907825, prev) + 2090, 3967));
        }
    }

    fn decodeParameters(self: *Channel, ctrl: *Params, cond: Cond) void {
        const ind = &self.indices;
        const order = self.lpc_order;
        self.gainsDequant(ctrl.gains_q16[0..self.nb_subfr], cond == .conditionally);

        var nlsf_q15: [lpc.max_order]i16 = undefined;
        nlsf.decode(&nlsf_q15, &ind.nlsf, self.codebook());
        lpc.nlsf2a(ctrl.pred_coef_q12[1][0..order], nlsf_q15[0..order]);
        if (self.first_frame_after_reset) ind.nlsf_interp_coef_q2 = 4;
        if (ind.nlsf_interp_coef_q2 < 4) {
            var nlsf0: [lpc.max_order]i16 = undefined;
            const w: i32 = ind.nlsf_interp_coef_q2;
            for (0..order) |i| {
                const prev: i32 = self.prev_nlsf_q15[i];
                nlsf0[i] = m.trunc16(prev + ((w * (@as(i32, nlsf_q15[i]) - prev)) >> 2));
            }
            lpc.nlsf2a(ctrl.pred_coef_q12[0][0..order], nlsf0[0..order]);
        } else {
            ctrl.pred_coef_q12[0] = ctrl.pred_coef_q12[1];
        }
        @memcpy(self.prev_nlsf_q15[0..order], nlsf_q15[0..order]);
        if (self.loss_cnt != 0) {
            lpc.bwexpander(ctrl.pred_coef_q12[0][0..order], bwe_after_loss_q16);
            lpc.bwexpander(ctrl.pred_coef_q12[1][0..order], bwe_after_loss_q16);
        }

        if (ind.signal_type == type_voiced) {
            pitch.decodePitch(ind.lag_index, ind.contour_index, ctrl.pitch_l[0..self.nb_subfr], self.fs_khz);
            const cb = pitch.ltp_vq[ind.per_index];
            for (0..self.nb_subfr) |k| {
                const row = cb[@as(usize, ind.ltp_index[k]) * ltp_order ..][0..ltp_order];
                for (row, 0..) |v, i| ctrl.ltp_coef_q14[k * ltp_order + i] = @as(i16, v) << 7;
            }
            ctrl.ltp_scale_q14 = tables.ltp_scales_table_q14[ind.ltp_scale_index];
        } else {
            ctrl.pitch_l = @splat(0);
            ctrl.ltp_coef_q14 = @splat(0);
            ind.per_index = 0;
            ctrl.ltp_scale_q14 = 0;
        }
    }

    fn decodeCore(self: *Channel, ctrl: *Params, xq: []i16, pulses: *const [excitation.max_pulses]i16) void {
        const ind = &self.indices;
        const ltp_mem: usize = self.ltp_mem_length;
        const sub: usize = self.subfr_length;
        const order: usize = self.lpc_order;
        var s_ltp: [max_ltp_mem]i16 = @splat(0);
        var s_ltp_q15: [max_ltp_mem + max_frame_length]i32 = @splat(0);
        var res_q14: [max_subfr_length]i32 = undefined;
        var s_lpc_q14: [max_subfr_length + lpc.max_order]i32 = undefined;

        const offset_q10: i32 = tables.quantization_offsets_q10[(ind.signal_type >> 1) * 2 + ind.quant_offset_type];
        const interpolate = ind.nlsf_interp_coef_q2 < 4;

        var seed: i32 = ind.seed;
        for (0..self.frame_length) |i| {
            seed = m.rand(seed);
            var e: i32 = @as(i32, pulses[i]) << 14;
            if (e > 0) {
                e -= 80 << 4;
            } else if (e < 0) {
                e += 80 << 4;
            }
            e += offset_q10 << 4;
            if (seed < 0) e = -e;
            self.exc_q14[i] = e;
            seed +%= pulses[i];
        }

        s_lpc_q14[0..lpc.max_order].* = self.s_lpc_q14_buf;
        var buf_idx: usize = ltp_mem;
        for (0..self.nb_subfr) |k| {
            const a = ctrl.pred_coef_q12[k >> 1][0..order];
            const b = ctrl.ltp_coef_q14[k * ltp_order ..][0..ltp_order];
            const gain_q16 = ctrl.gains_q16[k];
            const gain_q10 = gain_q16 >> 6;
            var inv_gain_q31 = m.inverse32VarQ(gain_q16, 47);

            var gain_adj_q16: i32 = 1 << 16;
            if (gain_q16 != self.prev_gain_q16) {
                gain_adj_q16 = m.div32VarQ(self.prev_gain_q16, gain_q16, 16);
                for (s_lpc_q14[0..lpc.max_order]) |*s| s.* = m.smulww(gain_adj_q16, s.*);
            }
            self.prev_gain_q16 = gain_q16;

            var voiced = ind.signal_type == type_voiced;
            if (self.loss_cnt != 0 and self.prev_signal_type == type_voiced and !voiced and k < max_subfr / 2) {
                // Avoids a jump from voiced concealment to an unvoiced frame.
                b.* = @splat(0);
                b[ltp_order / 2] = 1 << 12;
                voiced = true;
                ctrl.pitch_l[k] = std.math.clamp(self.lag_prev, 2, @as(i32, @intCast(ltp_mem - order - 3)));
            }
            if (voiced) {
                const lag: usize = @intCast(ctrl.pitch_l[k]);
                if (k == 0 or (k == 2 and interpolate)) {
                    const start = ltp_mem - lag - order - ltp_order / 2;
                    if (k == 2) @memcpy(self.out_buf[ltp_mem..][0 .. 2 * sub], xq[0 .. 2 * sub]);
                    lpc.analysisFilter(s_ltp[start..ltp_mem], self.out_buf[start + k * sub ..][0 .. ltp_mem - start], a);
                    if (k == 0) inv_gain_q31 = m.smulwb(inv_gain_q31, ctrl.ltp_scale_q14) << 2;
                    for (0..lag + ltp_order / 2) |i| {
                        s_ltp_q15[buf_idx - i - 1] = m.smulwb(inv_gain_q31, s_ltp[ltp_mem - i - 1]);
                    }
                } else if (gain_adj_q16 != 1 << 16) {
                    for (0..lag + ltp_order / 2) |i| {
                        s_ltp_q15[buf_idx - i - 1] = m.smulww(gain_adj_q16, s_ltp_q15[buf_idx - i - 1]);
                    }
                }
                var p = buf_idx - lag + ltp_order / 2;
                for (0..sub) |i| {
                    var t: i32 = 2;
                    for (0..ltp_order) |j| t = m.smlawb(t, s_ltp_q15[p - j], b[j]);
                    p += 1;
                    res_q14[i] = self.exc_q14[k * sub + i] +% (t << 1);
                    s_ltp_q15[buf_idx] = res_q14[i] << 1;
                    buf_idx += 1;
                }
            }
            const res: []const i32 = if (voiced) res_q14[0..sub] else self.exc_q14[k * sub ..][0..sub];

            for (0..sub) |i| {
                var t: i32 = @intCast(order >> 1);
                for (0..order) |j| t = m.smlawb(t, s_lpc_q14[lpc.max_order + i - 1 - j], a[j]);
                const s = m.addSat32(res[i], m.lshiftSat32(t, 4));
                s_lpc_q14[lpc.max_order + i] = s;
                xq[k * sub + i] = @intCast(m.sat16(m.rshiftRound(m.smulww(s, gain_q10), 8)));
            }
            const next: [lpc.max_order]i32 = s_lpc_q14[sub..][0..lpc.max_order].*;
            s_lpc_q14[0..lpc.max_order].* = next;
        }
        self.s_lpc_q14_buf = s_lpc_q14[0..lpc.max_order].*;
    }

    fn pushOutput(self: *Channel, frame: []const i16) void {
        const mv_len = self.ltp_mem_length - self.frame_length;
        std.mem.copyForwards(i16, self.out_buf[0..mv_len], self.out_buf[self.frame_length..][0..mv_len]);
        @memcpy(self.out_buf[mv_len..][0..self.frame_length], frame);
    }

    /// Where the data of a frame comes from.
    const Source = union(enum) {
        coded,
        stored: *const LbrrFrame,
        lost,
    };

    fn decodeFrame(self: *Channel, dec: *range.Decoder, out: []i16, cond: Cond, src: Source) void {
        var ctrl: Params = .{};
        switch (src) {
            .lost => {
                plc_mod.conceal(self, &ctrl, out);
                self.pushOutput(out);
            },
            .coded, .stored => {
                var pulses: [excitation.max_pulses]i16 = @splat(0);
                switch (src) {
                    .coded => {
                        self.decodeIndices(dec, self.n_frames_decoded, false, cond);
                        excitation.decodePulses(dec, &pulses, self.indices.signal_type, self.indices.quant_offset_type, self.frame_length);
                    },
                    .stored => |frame| {
                        self.indices = frame.indices;
                        pulses = frame.pulses;
                    },
                    .lost => unreachable,
                }
                self.decodeParameters(&ctrl, cond);
                self.decodeCore(&ctrl, out, &pulses);
                self.pushOutput(out);
                plc_mod.update(self, &ctrl);
                self.loss_cnt = 0;
                self.first_frame_after_reset = false;
            },
        }
        plc_mod.applyCng(self, &ctrl, out);
        plc_mod.glueFrames(self, out);
        self.lag_prev = ctrl.pitch_l[self.nb_subfr - 1];
    }
};

/// How a frame is made: from its own data, from the redundancy frames of the next packet, or
/// from nothing.
pub const Loss = enum { none, fec, lost };

/// What the caller knows about the packet.
pub const Control = struct {
    /// Output channels, 1 or 2.
    channels_api: u32,
    /// Channels in the stream, 1 or 2.
    channels_internal: u32,
    /// The internal rate in kHz: 8, 12 or 16.
    internal_khz: u32,
    /// The duration of the frame: 10, 20, 40 or 60.
    payload_ms: u32,
};

pub const Decoder = struct {
    channels: [2]Channel = .{ .{}, .{} },
    stereo: stereo.State = .{},
    prev_decode_only_middle: bool = false,
    n_channels_api: u32 = 0,
    n_channels_internal: u32 = 0,
    lbrr: Lbrr = .{},

    pub fn init() Decoder {
        return .{};
    }

    /// Clears the state of the channels and of the stereo filter.
    pub fn reset(self: *Decoder) void {
        self.channels = .{ .{}, .{} };
        self.stereo = .{};
        self.prev_decode_only_middle = false;
    }

    /// Decodes the next 10 or 20 ms of a frame and writes it as 48 kHz samples, interleaved when
    /// `channels_api` is 2. `new_packet` is set on the first call for a range decoder. A frame of
    /// 40 or 60 ms takes two or three calls. Returns the samples of each channel. `ctl` holds the
    /// same values for all calls of one frame, `payload_ms` is 10, 20, 40 or 60 and `internal_khz`
    /// is 8, 12 or 16.
    pub fn decode(self: *Decoder, ctl: Control, new_packet: bool, dec: *range.Decoder, out: []i16) Error!usize {
        return self.run(ctl, new_packet, .none, dec, out);
    }

    /// Like `decode`, but makes the audio of the frame from the low bit rate redundancy frames
    /// of the packet, and from the concealment where a redundancy frame is missing.
    pub fn decodeFec(self: *Decoder, ctl: Control, new_packet: bool, dec: *range.Decoder, out: []i16) Error!usize {
        return self.run(ctl, new_packet, .fec, dec, out);
    }

    /// Like `decode`, for a frame that was lost. No data is read. `ctl` is the control of the
    /// last packet, except for `payload_ms`.
    pub fn conceal(self: *Decoder, ctl: Control, new_packet: bool, out: []i16) Error!usize {
        var unused = range.Decoder.init(&.{});
        return self.run(ctl, new_packet, .lost, &unused, out);
    }

    fn run(self: *Decoder, ctl: Control, new_packet: bool, loss: Loss, dec: *range.Decoder, out: []i16) Error!usize {
        std.debug.assert(ctl.channels_api == 1 or ctl.channels_api == 2);
        std.debug.assert(ctl.channels_internal == 1 or ctl.channels_internal == 2);
        const n_int = ctl.channels_internal;
        const n_api = ctl.channels_api;
        const frames_per_packet: u32, const nb_subfr: u32 = switch (ctl.payload_ms) {
            10 => .{ 1, 2 },
            20 => .{ 1, 4 },
            40 => .{ 2, 4 },
            60 => .{ 3, 4 },
            else => unreachable,
        };
        std.debug.assert(ctl.internal_khz == 8 or ctl.internal_khz == 12 or ctl.internal_khz == 16);
        const ch = &self.channels;

        if (new_packet) {
            for (ch[0..n_int]) |*c| c.n_frames_decoded = 0;
        }
        if (n_int > self.n_channels_internal) ch[1] = .{};
        const stereo_to_mono = n_int == 1 and self.n_channels_internal == 2 and ctl.internal_khz == ch[0].fs_khz;

        if (ch[0].n_frames_decoded == 0) {
            for (ch[0..n_int]) |*c| {
                c.n_frames_per_packet = frames_per_packet;
                c.nb_subfr = nb_subfr;
                c.setFs(ctl.internal_khz);
            }
        }
        std.debug.assert(ch[0].n_frames_decoded < frames_per_packet);
        std.debug.assert(ch[0].nb_subfr == nb_subfr and ch[0].fs_khz == ctl.internal_khz);
        const frame_length = ch[0].frame_length;
        const n_out = frame_length * 48 / ch[0].fs_khz;
        if (out.len < n_out * n_api) return error.BufferTooSmall;

        if (n_api == 2 and n_int == 2 and (self.n_channels_api == 1 or self.n_channels_internal == 1)) {
            self.stereo.pred_prev_q13 = .{ 0, 0 };
            self.stereo.s_side = .{ 0, 0 };
            ch[1].resampler = ch[0].resampler;
        }
        self.n_channels_api = n_api;
        self.n_channels_internal = n_int;

        if (loss != .lost and ch[0].n_frames_decoded == 0) self.parseHeader(dec, n_int);

        const frame = ch[0].n_frames_decoded;
        var pred_q13: stereo.Prediction = .{ 0, 0 };
        var only_middle = false;
        if (n_int == 2) {
            pred_q13 = .{ self.stereo.pred_prev_q13[0], self.stereo.pred_prev_q13[1] };
            if (loss == .none) {
                pred_q13 = stereo.decodePred(dec);
                if (!ch[1].vad_flags[frame]) only_middle = stereo.decodeMidOnly(dec);
            } else if (loss == .fec and ch[0].lbrr_flags[frame]) {
                pred_q13 = self.lbrr.pred_q13[frame];
                only_middle = self.lbrr.only_middle[frame];
            }
        }
        if (n_int == 2 and !only_middle and self.prev_decode_only_middle) {
            const side = &ch[1];
            side.out_buf = @splat(0);
            side.s_lpc_q14_buf = @splat(0);
            side.lag_prev = 100;
            side.last_gain_index = 10;
            side.prev_signal_type = 0;
            side.first_frame_after_reset = true;
        }

        var tmp: [2][max_frame_length + 2]i16 = @splat(@splat(0));
        const has_side = if (loss == .none)
            !only_middle
        else
            !self.prev_decode_only_middle or (n_int == 2 and loss == .fec and ch[1].lbrr_flags[frame]);
        for (0..n_int) |n| {
            if (n == 0 or has_side) {
                const cond: Cond = if (frame == 0)
                    .independently
                else if (loss == .fec)
                    (if (ch[n].lbrr_flags[frame - 1]) .conditionally else .independently)
                else if (n > 0 and self.prev_decode_only_middle)
                    .independently_no_ltp_scaling
                else
                    .conditionally;
                const src: Channel.Source = switch (loss) {
                    .none => .coded,
                    .lost => .lost,
                    .fec => if (ch[n].lbrr_flags[frame]) .{ .stored = &self.lbrr.frames[n][frame] } else .lost,
                };
                ch[n].decodeFrame(dec, tmp[n][2..][0..frame_length], cond, src);
            }
            ch[n].n_frames_decoded += 1;
        }

        if (n_api == 2 and n_int == 2) {
            stereo.msToLr(&self.stereo, &tmp[0], &tmp[1], pred_q13, ch[0].fs_khz, frame_length);
        } else {
            tmp[0][0..2].* = self.stereo.s_mid;
            self.stereo.s_mid = tmp[0][frame_length..][0..2].*;
        }

        var resampled: [960]i16 = undefined;
        for (0..@min(n_api, n_int)) |n| {
            ch[n].resampler.process(resampled[0..n_out], tmp[n][1..][0..frame_length]);
            for (0..n_out) |i| out[if (n_api == 2) n + 2 * i else i] = resampled[i];
        }
        if (n_api == 2 and n_int == 1) {
            if (stereo_to_mono) {
                ch[1].resampler.process(resampled[0..n_out], tmp[0][1..][0..frame_length]);
                for (0..n_out) |i| out[1 + 2 * i] = resampled[i];
            } else {
                for (0..n_out) |i| out[1 + 2 * i] = out[2 * i];
            }
        }
        if (loss == .lost) {
            for (ch[0..n_int]) |*c| c.last_gain_index = 10;
        } else {
            self.prev_decode_only_middle = only_middle;
        }
        return n_out;
    }

    /// Reads the VAD and redundancy flags that open a frame and parses the redundancy frames.
    fn parseHeader(self: *Decoder, dec: *range.Decoder, n_int: u32) void {
        const ch = &self.channels;
        for (ch[0..n_int]) |*c| {
            for (c.vad_flags[0..c.n_frames_per_packet]) |*f| f.* = dec.bitLogp(1);
            c.lbrr_flag = dec.bitLogp(1);
        }
        for (ch[0..n_int]) |*c| {
            c.lbrr_flags = @splat(false);
            if (!c.lbrr_flag) continue;
            if (c.n_frames_per_packet == 1) {
                c.lbrr_flags[0] = true;
            } else {
                const icdf: []const u8 = if (c.n_frames_per_packet == 2) &tables.lbrr_flags_2_icdf else &tables.lbrr_flags_3_icdf;
                const sym = dec.icdf(icdf, 8) + 1;
                for (&c.lbrr_flags, 0..) |*f, i| f.* = (sym >> @intCast(i)) & 1 != 0;
            }
        }
        for (0..ch[0].n_frames_per_packet) |i| {
            for (0..n_int) |n| {
                const c = &ch[n];
                if (!c.lbrr_flags[i]) continue;
                if (n_int == 2 and n == 0) {
                    self.lbrr.pred_q13[i] = stereo.decodePred(dec);
                    self.lbrr.only_middle[i] = !ch[1].lbrr_flags[i] and stereo.decodeMidOnly(dec);
                }
                const cond: Cond = if (i > 0 and c.lbrr_flags[i - 1]) .conditionally else .independently;
                c.decodeIndices(dec, i, true, cond);
                const slot = &self.lbrr.frames[n][i];
                slot.indices = c.indices;
                excitation.decodePulses(dec, &slot.pulses, c.indices.signal_type, c.indices.quant_offset_type, c.frame_length);
            }
        }
    }
};

const testing = std.testing;
const test_util = @import("../test_util.zig");

test "a decoder starts with the libopus defaults" {
    const d = Decoder.init();
    try testing.expectEqual(@as(i32, 65536), d.channels[0].prev_gain_q16);
    try testing.expect(d.channels[1].first_frame_after_reset);
    try testing.expectEqual(@as(u32, 0), d.n_channels_internal);
}

// Packets of libopus 1.6.1 with in band redundancy, one 20 ms and one 60 ms frame, mono, 16 kHz.
const lbrr_20ms = [_]u8{
    72, 198, 30,  1,  199, 153, 236, 38,  147, 93,  0,   230, 13,  85, 192, 141, 145, 171, 77,  96, 214, 75,  163, 183, 131, 182, 12, 124, 6,   124, 83, 40,
    42, 9,   217, 90, 3,   78,  72,  182, 199, 184, 164, 67,  203, 6,  106, 235, 184, 132, 228, 99, 72,  139, 51,  132, 144, 42,  98, 73,  241, 145, 3,  147,
    31, 99,  126, 92, 190, 6,   69,  151, 153,
};

const lbrr_60ms = [_]u8{
    88,  245, 222, 226, 250, 62,  65,  157, 169, 201, 85,  237, 74,  116, 65,  18,  126, 141, 82,  14,  100, 210, 199, 74,  50, 110, 29,  199, 85,  196, 78,  9,
    8,   179, 173, 104, 129, 36,  139, 221, 166, 223, 184, 202, 15,  81,  239, 132, 13,  193, 40,  23,  192, 203, 213, 91,  92, 154, 167, 116, 166, 247, 103, 250,
    114, 156, 240, 180, 140, 125, 31,  190, 95,  161, 164, 65,  210, 235, 42,  162, 148, 165, 134, 116, 70,  63,  46,  105, 1,  165, 41,  88,  160, 97,  58,  244,
    98,  105, 46,  150, 252, 70,  254, 199, 85,  5,   193, 166, 139, 174, 171, 68,  46,  227, 19,  204, 106, 197, 196, 118, 50, 48,  13,  186, 93,  62,  102, 253,
    135, 118, 236, 182, 171, 9,   210, 95,  147, 165, 126, 194, 233, 167, 55,  95,  15,  206, 89,  126, 115, 182, 41,  153, 10, 148, 127, 98,  151, 98,  65,  234,
    241,
};

fn pulseHash(pulses: []const i16) u32 {
    var h: u32 = 2166136261;
    for (pulses) |p| h = test_util.fnv(h, @as(u16, @bitCast(p)));
    return h;
}

test "the redundancy frames of a packet are parsed and kept" {
    var d = Decoder.init();
    var out: [960]i16 = undefined;
    var rd = range.Decoder.init(lbrr_20ms[1..]);
    const ctl: Control = .{ .channels_api = 1, .channels_internal = 1, .internal_khz = 16, .payload_ms = 20 };
    try testing.expectEqual(@as(usize, 960), try d.decode(ctl, true, &rd, &out));
    try testing.expect(d.channels[0].lbrr_flag);
    try testing.expectEqual([3]bool{ true, false, false }, d.channels[0].lbrr_flags);
    const f = d.lbrr.frames[0][0];
    try testing.expectEqual(@as(u8, 1), f.indices.signal_type);
    try testing.expectEqual(@as(u8, 1), f.indices.quant_offset_type);
    try testing.expectEqualSlices(u8, &.{ 6, 4, 4, 4 }, &f.indices.gains);
    try testing.expectEqual(@as(i8, 25), f.indices.nlsf[0]);
    try testing.expectEqual(@as(u8, 4), f.indices.nlsf_interp_coef_q2);
    try testing.expectEqual(@as(u8, 0), f.indices.seed);
    try testing.expectEqual(@as(u32, 410753867), pulseHash(f.pulses[0..320]));
    var sum: i32 = 0;
    for (f.pulses[0..320]) |p| sum += p;
    try testing.expectEqual(@as(i32, -36), sum);
}

test "a 60 ms packet keeps the redundancy frame of its third frame" {
    var d = Decoder.init();
    var out: [960]i16 = undefined;
    var rd = range.Decoder.init(lbrr_60ms[1..]);
    const ctl: Control = .{ .channels_api = 1, .channels_internal = 1, .internal_khz = 16, .payload_ms = 60 };
    for (0..3) |i| try testing.expectEqual(@as(usize, 960), try d.decode(ctl, i == 0, &rd, &out));
    try testing.expectEqual([3]bool{ false, false, true }, d.channels[0].lbrr_flags);
    const f = d.lbrr.frames[0][2];
    try testing.expectEqualSlices(u8, &.{ 7, 4, 4, 4 }, &f.indices.gains);
    try testing.expectEqual(@as(i8, 25), f.indices.nlsf[0]);
    try testing.expectEqual(@as(u32, 923030325), pulseHash(f.pulses[0..320]));
}

const Xorshift = test_util.Xorshift;

fn decodeAll(d: *Decoder, ctl: Control, data: []const u8, out: []i16) Error!void {
    var rd = range.Decoder.init(data);
    const calls: u32 = if (ctl.payload_ms > 20) ctl.payload_ms / 20 else 1;
    for (0..calls) |i| _ = try d.decode(ctl, i == 0, &rd, out);
}

test "random and mutated packets decode without a panic" {
    var rng: Xorshift = .{ .s = 0x1234567 };
    var d = Decoder.init();
    var data: [400]u8 = undefined;
    var out: [960 * 2]i16 = undefined;
    for (0..3000) |it| {
        const len = 2 + rng.next() % (data.len - 2);
        const style = rng.next() % 4;
        for (data[0..len]) |*b| {
            const v = rng.next();
            b.* = switch (style) {
                0 => @truncate(v >> 5),
                1 => if (v & 7 == 0) @truncate(v >> 8) else 0,
                2 => if (v & 7 == 0) @truncate(v >> 8) else 0xFF,
                else => @truncate((v >> 5) | 0x81),
            };
        }
        const ctl: Control = .{
            .channels_api = 1 + (rng.next() & 1),
            .channels_internal = 1 + (rng.next() & 1),
            .internal_khz = (@as(u32, 2) + rng.next() % 3) * 4,
            .payload_ms = switch (rng.next() % 4) {
                0 => 10,
                1 => 20,
                2 => 40,
                else => 60,
            },
        };
        try decodeAll(&d, ctl, data[0..len], &out);
        if (it % 500 == 499) d.reset();
    }
    // Flip bits of real packets.
    const real = [_][]const u8{ lbrr_20ms[1..], lbrr_60ms[1..] };
    for (0..600) |it| {
        const src = real[it % 2];
        @memcpy(data[0..src.len], src);
        for (0..1 + it % 5) |_| data[rng.next() % src.len] ^= @as(u8, 1) << @intCast(rng.next() % 8);
        const ctl: Control = .{
            .channels_api = 1 + (rng.next() & 1),
            .channels_internal = 1 + (rng.next() & 1),
            .internal_khz = 16,
            .payload_ms = if (it % 2 == 0) 20 else 60,
        };
        try decodeAll(&d, ctl, data[0 .. src.len - rng.next() % 4], &out);
    }
}

test "a small output buffer is an error" {
    var d = Decoder.init();
    var out: [960 * 2]i16 = undefined;
    const data: [20]u8 = @splat(0);
    var rd = range.Decoder.init(&data);
    const ok: Control = .{ .channels_api = 2, .channels_internal = 1, .internal_khz = 16, .payload_ms = 20 };
    try testing.expectError(error.BufferTooSmall, d.decode(ok, true, &rd, out[0..1000]));
}

test "a lost frame needs no data and a first loss gives a quiet frame" {
    var d = Decoder.init();
    var out: [960 * 2]i16 = undefined;
    const ctl: Control = .{ .channels_api = 2, .channels_internal = 2, .internal_khz = 16, .payload_ms = 20 };
    try testing.expectEqual(@as(usize, 960), try d.conceal(ctl, true, &out));
    for (out[0 .. 960 * 2]) |v| try testing.expectEqual(@as(i16, 0), v);
    try testing.expectEqual(@as(i32, 1), d.channels[0].loss_cnt);
    try testing.expectEqual(@as(i32, 10), d.channels[0].last_gain_index);
    const small: Control = .{ .channels_api = 1, .channels_internal = 1, .internal_khz = 8, .payload_ms = 10 };
    try testing.expectEqual(@as(usize, 480), try d.conceal(small, true, &out));
}

test "the frame after a loss survives any pitch lag in the state" {
    const lags = [_]i32{ std.math.minInt(i32), -1, 0, 1, 2, 1 << 20, std.math.maxInt(i32) };
    for (lags) |lag| {
        var d = Decoder.init();
        var out: [960 * 2]i16 = undefined;
        const ctl: Control = .{ .channels_api = 1, .channels_internal = 1, .internal_khz = 16, .payload_ms = 20 };
        // An all zero packet has a frame without voice.
        const zeros: [40]u8 = @splat(0);
        try decodeAll(&d, ctl, &zeros, &out);
        _ = try d.conceal(ctl, true, &out);
        d.channels[0].prev_signal_type = type_voiced;
        d.channels[0].lag_prev = lag;
        try decodeAll(&d, ctl, &zeros, &out);
        try testing.expectEqual(@as(i32, 0), d.channels[0].loss_cnt);
    }
}

test "frames of random packets with losses and redundancy decode without a panic" {
    var rng: Xorshift = .{ .s = 0x7777 };
    var d = Decoder.init();
    var data: [300]u8 = undefined;
    var out: [960 * 2]i16 = undefined;
    for (0..2000) |it| {
        const len = 2 + rng.next() % (data.len - 2);
        test_util.fillPayload(&rng, data[0..len]);
        const ctl: Control = .{
            .channels_api = 1 + (rng.next() & 1),
            .channels_internal = 1 + (rng.next() & 1),
            .internal_khz = (@as(u32, 2) + rng.next() % 3) * 4,
            .payload_ms = switch (rng.next() % 4) {
                0 => 10,
                1 => 20,
                2 => 40,
                else => 60,
            },
        };
        var rd = range.Decoder.init(data[0..len]);
        const calls: u32 = if (ctl.payload_ms > 20) ctl.payload_ms / 20 else 1;
        switch (rng.next() % 3) {
            0 => for (0..calls) |i| {
                _ = try d.decode(ctl, i == 0, &rd, &out);
            },
            1 => for (0..calls) |i| {
                _ = try d.decodeFec(ctl, i == 0, &rd, &out);
            },
            else => {
                const lost: Control = .{ .channels_api = ctl.channels_api, .channels_internal = ctl.channels_internal, .internal_khz = ctl.internal_khz, .payload_ms = if (rng.next() & 1 == 0) 10 else 20 };
                _ = try d.conceal(lost, true, &out);
            },
        }
        if (it % 500 == 499) d.reset();
    }
}
