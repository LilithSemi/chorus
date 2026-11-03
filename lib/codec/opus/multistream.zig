//! Multistream Opus encoder for the channel mappings of Ogg Opus: the layout of the streams, the
//! surround analysis and the bitrate split, following libopus src/opus_multistream_encoder.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const celt = @import("celt.zig");
const packet_encoder = @import("encode.zig");
const packet = @import("packet.zig");
const opus = @import("../opus.zig");

const nb = celt.tables.nb_ebands;
const overlap = 120;
const sample_rate = 48000;
const max_tmp = 6 * 1275 + 12;
const preemph: f32 = 0.85000610;

pub const Error = packet_encoder.Error;
pub const InitError = packet_encoder.PacketEncoder.InitError || error{OutOfMemory};

/// How the channels map to the streams.
pub const Layout = struct {
    channels: u8,
    streams: u8,
    /// The first `coupled` streams have two channels.
    coupled: u8,
    /// For each channel the stream channel that feeds it, or 255 for none. Stream channel `2 * s`
    /// and `2 * s + 1` are the two channels of the coupled stream `s`, then come the mono streams.
    mapping: [255]u8,
    /// The mapping family of the Ogg Opus header.
    family: u8,
    /// The stream that carries the low frequency effects, for 6 or more channels of family 1.
    lfe_stream: ?u8,

    const Vorbis = struct { streams: u8, coupled: u8, mapping: [8]u8 };

    /// The order of the Vorbis I channel layouts for 1 to 8 channels.
    const vorbis_mappings = [8]Vorbis{
        .{ .streams = 1, .coupled = 0, .mapping = .{ 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .streams = 1, .coupled = 1, .mapping = .{ 0, 1, 0, 0, 0, 0, 0, 0 } },
        .{ .streams = 2, .coupled = 1, .mapping = .{ 0, 2, 1, 0, 0, 0, 0, 0 } },
        .{ .streams = 2, .coupled = 2, .mapping = .{ 0, 1, 2, 3, 0, 0, 0, 0 } },
        .{ .streams = 3, .coupled = 2, .mapping = .{ 0, 4, 1, 2, 3, 0, 0, 0 } },
        .{ .streams = 4, .coupled = 2, .mapping = .{ 0, 4, 1, 2, 3, 5, 0, 0 } },
        .{ .streams = 4, .coupled = 3, .mapping = .{ 0, 4, 1, 2, 3, 5, 6, 0 } },
        .{ .streams = 5, .coupled = 3, .mapping = .{ 0, 6, 1, 2, 3, 4, 5, 7 } },
    };

    /// The layout that libopus picks for `channels` channels: family 0 for 1 or 2 channels,
    /// family 1 (Vorbis order) for 3 to 8 and family 255 (one stream per channel) above.
    pub fn init(channels: u32) error{Unsupported}!Layout {
        if (channels == 0 or channels > 255) return error.Unsupported;
        var self: Layout = .{
            .channels = @intCast(channels),
            .streams = 0,
            .coupled = 0,
            .mapping = @splat(255),
            .family = 0,
            .lfe_stream = null,
        };
        if (channels <= 2) {
            self.streams = 1;
            self.coupled = @intCast(channels - 1);
            for (0..channels) |c| self.mapping[c] = @intCast(c);
        } else if (channels <= 8) {
            const v = vorbis_mappings[channels - 1];
            self.family = 1;
            self.streams = v.streams;
            self.coupled = v.coupled;
            @memcpy(self.mapping[0..channels], v.mapping[0..channels]);
            if (channels >= 6) self.lfe_stream = v.streams - 1;
        } else {
            self.family = 255;
            self.streams = @intCast(channels);
            for (0..channels) |c| self.mapping[c] = @intCast(c);
        }
        return self;
    }

    /// True for the layouts where the channels of different streams are analysed together.
    pub fn isSurround(self: *const Layout) bool {
        return self.family == 1 and self.channels > 2;
    }

    /// The channel that feeds the stream channel `index`.
    fn find(self: *const Layout, index: u32) ?usize {
        for (self.mapping[0..self.channels], 0..) |m, c| {
            if (m == index) return c;
        }
        return null;
    }

    fn left(self: *const Layout, stream: u32) ?usize {
        return self.find(2 * stream);
    }

    fn right(self: *const Layout, stream: u32) ?usize {
        return self.find(2 * stream + 1);
    }

    fn mono(self: *const Layout, stream: u32) ?usize {
        return self.find(stream + self.coupled);
    }
};

/// Encodes frames of interleaved 48 kHz samples to one multistream packet each. The channels are
/// in the order of the OpusHead mapping.
pub const Encoder = struct {
    gpa: std.mem.Allocator,
    layout: Layout,
    options: opus.EncodeOptions,
    frame_size: u32,
    /// The bits per second for all streams, or null for the libopus default of the layout.
    bitrate: ?u32,
    streams: []*packet_encoder.PacketEncoder,
    /// How many of the stream encoders exist.
    built: usize = 0,
    /// The samples of the stream that one call codes.
    stream_pcm: []f32,
    /// The packet of one stream before it is made self delimited.
    tmp: []u8,
    /// The per channel state of the surround analysis.
    window_mem: []f32,
    preemph_mem: []f32,
    band_log_e: []f32,
    analysis_in: []f32,
    analysis_x: []f32,

    pub fn init(gpa: std.mem.Allocator, layout: Layout, options: opus.EncodeOptions) InitError!Encoder {
        const frame_size = packet_encoder.frameSizeOf(options.frame_ms, sample_rate) orelse return error.InvalidFrameSize;
        const channels: usize = layout.channels;
        const surround = layout.isSurround();
        var self: Encoder = .{
            .gpa = gpa,
            .layout = layout,
            .options = options,
            .frame_size = frame_size,
            .bitrate = if (options.bitrate == 0) null else options.bitrate,
            .streams = &.{},
            .stream_pcm = &.{},
            .tmp = &.{},
            .window_mem = &.{},
            .preemph_mem = &.{},
            .band_log_e = &.{},
            .analysis_in = &.{},
            .analysis_x = &.{},
        };
        errdefer self.deinit();
        self.streams = try gpa.alloc(*packet_encoder.PacketEncoder, layout.streams);
        for (0..layout.streams) |s| {
            const enc = try gpa.create(packet_encoder.PacketEncoder);
            errdefer gpa.destroy(enc);
            const stream_channels: u32 = if (s < layout.coupled) 2 else 1;
            try enc.initInto(stream_channels, options);
            self.streams[s] = enc;
            self.built += 1;
            if (layout.lfe_stream) |lfe| {
                if (lfe == s) enc.setLfe(true);
            }
        }
        self.stream_pcm = try gpa.alloc(f32, 2 * frame_size);
        self.tmp = try gpa.alloc(u8, max_tmp);
        if (surround) {
            self.window_mem = try gpa.alloc(f32, channels * overlap);
            @memset(self.window_mem, 0);
            self.preemph_mem = try gpa.alloc(f32, channels);
            @memset(self.preemph_mem, 0);
            self.band_log_e = try gpa.alloc(f32, channels * nb);
            self.analysis_in = try gpa.alloc(f32, frame_size + overlap);
            self.analysis_x = try gpa.alloc(f32, frame_size);
        }
        return self;
    }

    pub fn deinit(self: *Encoder) void {
        const gpa = self.gpa;
        for (self.streams[0..self.built]) |enc| gpa.destroy(enc);
        gpa.free(self.streams);
        gpa.free(self.stream_pcm);
        gpa.free(self.tmp);
        gpa.free(self.window_mem);
        gpa.free(self.preemph_mem);
        gpa.free(self.band_log_e);
        gpa.free(self.analysis_in);
        gpa.free(self.analysis_x);
        self.* = undefined;
    }

    /// The samples of each channel that one packet codes.
    pub fn frameSamples(self: *const Encoder) usize {
        return self.frame_size;
    }

    /// The delay between the input and the output of a decoder, in samples at 48 kHz.
    pub fn lookahead(self: *const Encoder) u32 {
        return self.streams[0].lookahead();
    }

    /// Limits the bandwidth of every stream to the one of the input signal.
    pub fn setInputBandwidth(self: *Encoder, bandwidth: packet.Bandwidth) void {
        for (self.streams) |enc| enc.input_bandwidth = bandwidth;
    }

    /// Encodes `frameSamples()` samples of each channel from `pcm` into the packet `out` and returns
    /// its length. Without VBR the packet has the length that the bitrate gives.
    pub fn encode(self: *Encoder, pcm: []const f32, out: []u8) Error!usize {
        const frame_size = self.frame_size;
        const layout = &self.layout;
        const channels: usize = layout.channels;
        const nstreams: usize = layout.streams;
        if (pcm.len < frame_size * channels) return error.InvalidFrameSize;
        const vbr = self.options.vbr;
        const surround = layout.isSurround();
        const max_in: i32 = @intCast(@min(out.len, 1 << 30));

        var smallest_packet: i32 = @as(i32, @intCast(nstreams)) * 2 - 1;
        if (sample_rate / frame_size == 10) smallest_packet += @intCast(nstreams);
        if (max_in < smallest_packet) return error.BufferTooSmall;

        if (surround) self.surroundAnalysis(pcm, frame_size);

        var rates: [255]i32 = undefined;
        const rate_sum = self.rateAllocation(rates[0..nstreams], frame_size);

        var max_data_bytes = max_in;
        if (!vbr) {
            if (self.bitrate) |br| {
                const bits = celt.rate.bitrateToBits(sample_rate, @intCast(@min(br, 1 << 30)), frame_size);
                max_data_bytes = @min(max_data_bytes, @max(smallest_packet, @divTrunc(bits + 4, 8)));
            } else {
                max_data_bytes = @min(max_data_bytes, @divTrunc(celt.rate.bitrateToBits(sample_rate, rate_sum, frame_size) + 4, 8));
            }
        }

        for (self.streams, 0..) |enc, s| {
            enc.setBitrate(@intCast(rates[s]));
            if (surround) {
                // A bitrate of null is the automatic value of libopus, which counts as a negative rate.
                var equiv_rate: i32 = if (self.bitrate) |br| @intCast(@min(br, 1 << 30)) else -1000;
                const ch: i32 = @intCast(channels);
                if (frame_size * 50 < sample_rate) {
                    equiv_rate -= 60 * (@as(i32, @intCast(sample_rate / frame_size)) - 50) * ch;
                }
                enc.user_bandwidth = if (equiv_rate > 10000 * ch)
                    .full
                else if (equiv_rate > 7000 * ch)
                    .super_wide
                else if (equiv_rate > 5000 * ch)
                    .wide
                else
                    .narrow;
                if (s < layout.coupled) {
                    enc.forced_mode = .celt_only;
                    enc.force_channels = 2;
                }
            }
        }

        var tot_size: i32 = 0;
        for (self.streams, 0..) |enc, s| {
            const last = s == nstreams - 1;
            var stream_channels: usize = 1;
            if (s < layout.coupled) {
                const l = layout.left(@intCast(s)) orelse return error.EncoderFailed;
                const r = layout.right(@intCast(s)) orelse return error.EncoderFailed;
                for (0..frame_size) |i| {
                    self.stream_pcm[2 * i] = pcm[i * channels + l];
                    self.stream_pcm[2 * i + 1] = pcm[i * channels + r];
                }
                stream_channels = 2;
                if (surround) {
                    var mask: [42]f32 = undefined;
                    @memcpy(mask[0..nb], self.band_log_e[nb * l ..][0..nb]);
                    @memcpy(mask[nb..], self.band_log_e[nb * r ..][0..nb]);
                    enc.setEnergyMask(&mask);
                }
            } else {
                const m = layout.mono(@intCast(s)) orelse return error.EncoderFailed;
                for (0..frame_size) |i| self.stream_pcm[i] = pcm[i * channels + m];
                if (surround) {
                    var mask: [42]f32 = @splat(0);
                    @memcpy(mask[0..nb], self.band_log_e[nb * m ..][0..nb]);
                    enc.setEnergyMask(&mask);
                }
            }
            var curr_max = max_data_bytes - tot_size;
            const after: i32 = @intCast(nstreams - s - 1);
            curr_max -= @max(0, 2 * after - 1);
            if (sample_rate / frame_size == 10) curr_max -= after;
            curr_max = @min(curr_max, max_tmp);
            if (!last) curr_max -= if (curr_max > 253) 2 else 1;
            if (curr_max < 1) return error.BufferTooSmall;
            if (!vbr and last) enc.setBitrate(@intCast(celt.rate.bitsToBitrate(sample_rate, curr_max * 8, frame_size)));
            const len = try enc.encode(self.stream_pcm[0 .. frame_size * stream_channels], self.tmp[0..@intCast(curr_max)]);

            var rp: packet_encoder.Repacketizer = .{};
            rp.cat(self.tmp[0..len]) catch return error.EncoderFailed;
            const room: usize = @intCast(max_data_bytes - tot_size);
            if (@as(usize, @intCast(tot_size)) + room > out.len) return error.BufferTooSmall;
            const n = rp.outRangeImpl(0, rp.count, out[@intCast(tot_size)..][0..room], !last, !vbr and last) catch return error.BufferTooSmall;
            tot_size += @intCast(n);
        }
        return @intCast(tot_size);
    }

    /// Splits the bitrate between the streams (surround_rate_allocation) and returns the sum.
    fn rateAllocation(self: *const Encoder, rate: []i32, frame_size: u32) i32 {
        const layout = &self.layout;
        const nb_lfe: i64 = @intFromBool(layout.lfe_stream != null);
        const nb_coupled: i64 = layout.coupled;
        const nb_uncoupled: i64 = @as(i64, layout.streams) - nb_coupled - nb_lfe;
        const nb_normal = 2 * nb_coupled + nb_uncoupled;
        const frame_rate: i64 = @max(50, sample_rate / frame_size);

        // Gives each non LFE channel the bits for the band energies.
        const channel_offset = 40 * frame_rate;
        const bitrate: i64 = if (self.bitrate) |br|
            br
        else
            nb_normal * (channel_offset + sample_rate + 10000) + 8000 * nb_lfe;

        // The LFE gets a base rate, at most 1/20 of the total for the part without energy.
        const lfe_offset = @min(@divTrunc(bitrate, 20), 3000) + 15 * frame_rate;
        // Each stream gets a starting rate. This is the main saving of coupled channels.
        var stream_offset = @divTrunc(@divTrunc(bitrate - channel_offset * nb_normal - lfe_offset * nb_lfe, nb_normal), 2);
        stream_offset = @max(0, @min(20000, stream_offset));

        const coupled_ratio: i64 = 512;
        const lfe_ratio: i64 = 32;
        const total = (nb_uncoupled << 8) + coupled_ratio * nb_coupled + nb_lfe * lfe_ratio;
        const channel_rate: i64 = @divTrunc(256 * (bitrate - lfe_offset * nb_lfe - stream_offset * (nb_coupled + nb_uncoupled) - channel_offset * nb_normal), total);

        var sum: i64 = 0;
        for (rate, 0..) |*r, i| {
            var v: i64 = if (i < layout.coupled)
                2 * channel_offset + @max(0, stream_offset + ((channel_rate * coupled_ratio) >> 8))
            else if (layout.lfe_stream orelse 255 != i)
                channel_offset + @max(0, stream_offset + channel_rate)
            else
                @max(0, lfe_offset + ((channel_rate * lfe_ratio) >> 8));
            v = std.math.clamp(@max(v, 500), 0, 1 << 30);
            r.* = @intCast(v);
            sum += v;
        }
        return @intCast(@min(sum, 1 << 30));
    }

    /// Measures how much each channel stands out from the mix of the channels on its side
    /// (surround_analysis). The result in `band_log_e` is the energy mask of the stream encoders.
    fn surroundAnalysis(self: *Encoder, pcm: []const f32, frame_size: u32) void {
        const channels: usize = self.layout.channels;
        var lm: u5 = 0;
        while (lm < 3) : (lm += 1) {
            if (@as(u32, 120) << lm == frame_size) break;
        }
        const freq_size: usize = @as(usize, 120) << lm;
        const nb_frames = frame_size / freq_size;
        const shift: u2 = @intCast(3 - @as(u32, lm));
        const pos = channelPos(channels);
        var mask_log_e: [3][nb]f32 = @splat(@splat(-28.0));
        const in = self.analysis_in;
        const x = self.analysis_x;
        var freq: [960]f32 = undefined;
        var band_e: [2 * nb]f32 = undefined;
        const log_e = self.band_log_e;

        for (0..channels) |c| {
            @memcpy(in[0..overlap], self.window_mem[c * overlap ..][0..overlap]);
            for (0..frame_size) |i| x[i] = pcm[i * channels + c];
            var mem = self.preemph_mem[c];
            for (0..frame_size) |i| {
                const v = 32768.0 * x[i];
                in[overlap + i] = v - mem;
                mem = preemph * v;
            }
            self.preemph_mem[c] = mem;
            var sum: f32 = 0;
            for (in[0 .. frame_size + overlap]) |v| sum += v * v;
            if (!(sum < 1e18) or sum != sum) {
                @memset(in[0 .. frame_size + overlap], 0);
                self.preemph_mem[c] = 0;
            }
            var best: [nb]f32 = @splat(0);
            for (0..nb_frames) |frame| {
                celt.mdct.forward(in[freq_size * frame ..][0 .. freq_size + overlap], freq[0..freq_size], 1, shift);
                celt.bands.bandEnergies(freq[0..freq_size], &band_e, nb, 1, lm);
                for (&best, band_e[0..nb]) |*b, e| b.* = @max(b.*, e);
            }
            var padded: [2 * nb]f32 = @splat(0);
            @memcpy(padded[0..nb], &best);
            var logs: celt.energy.Energies = undefined;
            celt.energy.amplitudeToLog(&padded, &logs, nb, nb, 1);
            const mine = log_e[nb * c ..][0..nb];
            @memcpy(mine, logs[0..nb]);
            // A spreading function of -6 dB per band going up and -12 dB going down.
            for (1..nb) |i| mine[i] = @max(mine[i], mine[i - 1] - 1.0);
            var i: usize = nb - 1;
            while (i > 0) {
                i -= 1;
                mine[i] = @max(mine[i], mine[i + 1] - 2.0);
            }
            switch (pos[c]) {
                1 => for (0..nb) |k| {
                    mask_log_e[0][k] = logSum(mask_log_e[0][k], mine[k]);
                },
                3 => for (0..nb) |k| {
                    mask_log_e[2][k] = logSum(mask_log_e[2][k], mine[k]);
                },
                2 => for (0..nb) |k| {
                    mask_log_e[0][k] = logSum(mask_log_e[0][k], mine[k] - 0.5);
                    mask_log_e[2][k] = logSum(mask_log_e[2][k], mine[k] - 0.5);
                },
                else => {},
            }
            @memcpy(self.window_mem[c * overlap ..][0..overlap], in[frame_size..][0..overlap]);
        }
        for (0..nb) |k| mask_log_e[1][k] = @min(mask_log_e[0][k], mask_log_e[2][k]);
        const per_channel: f32 = 2.0 / @as(f32, @floatFromInt(channels - 1));
        const channel_offset: f32 = 0.5 * @as(f32, @floatCast(1.442695040888963387 * @log(@as(f64, per_channel))));
        for (&mask_log_e) |*row| {
            for (row) |*v| v.* += channel_offset;
        }
        for (0..channels) |c| {
            const mine = log_e[nb * c ..][0..nb];
            if (pos[c] != 0) {
                const mask = &mask_log_e[pos[c] - 1];
                for (mine, mask) |*v, m| v.* -= m;
            } else {
                @memset(mine, 0);
            }
        }
    }
};

/// The side of the mix that a channel belongs to: 1 left, 2 centre, 3 right and 0 none.
fn channelPos(channels: usize) [8]u8 {
    return switch (channels) {
        4 => .{ 1, 3, 1, 3, 0, 0, 0, 0 },
        3, 5, 6 => .{ 1, 2, 3, 1, 3, 0, 0, 0 },
        7 => .{ 1, 2, 3, 1, 3, 2, 0, 0 },
        8 => .{ 1, 2, 3, 1, 3, 1, 3, 0 },
        else => @splat(0),
    };
}

/// An approximation of log2(2^a + 2^b).
fn logSum(a: f32, b: f32) f32 {
    const diff_table = [17]f32{ 0.5000000, 0.2924813, 0.1609640, 0.0849625, 0.0437314, 0.0221971, 0.0111839, 0.0056136, 0.0028123, 0, 0, 0, 0, 0, 0, 0, 0 };
    const max = @max(a, b);
    const diff = if (a > b) a - b else b - a;
    if (!(diff < 8.0)) return max;
    const low: usize = @intFromFloat(@floor(2 * diff));
    const frac = 2 * diff - @as(f32, @floatFromInt(low));
    return max + diff_table[low] + frac * (diff_table[low + 1] - diff_table[low]);
}

const testing = std.testing;
const test_util = @import("test_util.zig");

test "the layouts follow the Vorbis table for 3 to 8 channels" {
    const wanted = [_]struct { channels: u32, streams: u8, coupled: u8, lfe: ?u8, mapping: []const u8 }{
        .{ .channels = 1, .streams = 1, .coupled = 0, .lfe = null, .mapping = &.{0} },
        .{ .channels = 2, .streams = 1, .coupled = 1, .lfe = null, .mapping = &.{ 0, 1 } },
        .{ .channels = 3, .streams = 2, .coupled = 1, .lfe = null, .mapping = &.{ 0, 2, 1 } },
        .{ .channels = 4, .streams = 2, .coupled = 2, .lfe = null, .mapping = &.{ 0, 1, 2, 3 } },
        .{ .channels = 5, .streams = 3, .coupled = 2, .lfe = null, .mapping = &.{ 0, 4, 1, 2, 3 } },
        .{ .channels = 6, .streams = 4, .coupled = 2, .lfe = 3, .mapping = &.{ 0, 4, 1, 2, 3, 5 } },
        .{ .channels = 7, .streams = 4, .coupled = 3, .lfe = 3, .mapping = &.{ 0, 4, 1, 2, 3, 5, 6 } },
        .{ .channels = 8, .streams = 5, .coupled = 3, .lfe = 4, .mapping = &.{ 0, 6, 1, 2, 3, 4, 5, 7 } },
    };
    for (wanted) |w| {
        const l = try Layout.init(w.channels);
        try testing.expectEqual(w.streams, l.streams);
        try testing.expectEqual(w.coupled, l.coupled);
        try testing.expectEqual(w.lfe, l.lfe_stream);
        try testing.expectEqualSlices(u8, w.mapping, l.mapping[0..w.channels]);
        try testing.expectEqual(@as(u8, if (w.channels <= 2) 0 else 1), l.family);
        // Every stream channel has an input channel.
        for (0..l.streams) |s| {
            if (s < l.coupled) {
                try testing.expect(l.left(@intCast(s)) != null);
                try testing.expect(l.right(@intCast(s)) != null);
            } else {
                try testing.expect(l.mono(@intCast(s)) != null);
            }
        }
    }
    const wide = try Layout.init(255);
    try testing.expectEqual(@as(u8, 255), wide.family);
    try testing.expectEqual(@as(u8, 255), wide.streams);
    try testing.expectEqual(@as(u8, 0), wide.coupled);
    try testing.expectEqual(@as(u8, 254), wide.mapping[254]);
    try testing.expectEqual(@as(?u8, null), wide.lfe_stream);
    try testing.expectError(error.Unsupported, Layout.init(0));
    try testing.expectError(error.Unsupported, Layout.init(256));
}

test "the bitrate is split like libopus" {
    const gpa = testing.allocator;
    // The rates come from OPUS_GET_BITRATE of each stream of libopus 1.6.1 after a variable
    // bitrate packet.
    const Case = struct { channels: u32, bitrate: u32, frame_ms: f32, rates: []const i32 };
    const cases = [_]Case{
        .{ .channels = 6, .bitrate = 256000, .frame_ms = 20, .rates = &.{ 95120, 95120, 57560, 8195 } },
        .{ .channels = 6, .bitrate = 64000, .frame_ms = 20, .rates = &.{ 22751, 22751, 13888, 4607 } },
        .{ .channels = 3, .bitrate = 24000, .frame_ms = 10, .rates = &.{ 15332, 8666 } },
        .{ .channels = 5, .bitrate = 40000, .frame_ms = 40, .rates = &.{ 15400, 15400, 9200 } },
        .{ .channels = 7, .bitrate = 90000, .frame_ms = 60, .rates = &.{ 28371, 28371, 28371, 4886 } },
        .{ .channels = 6, .bitrate = 16000, .frame_ms = 20, .rates = &.{ 5659, 5659, 3052, 1625 } },
        .{ .channels = 6, .bitrate = 500000, .frame_ms = 20, .rates = &.{ 190340, 190340, 105170, 14146 } },
    };
    for (cases) |case| {
        var enc = try Encoder.init(gpa, try Layout.init(case.channels), .{ .bitrate = case.bitrate, .frame_ms = case.frame_ms });
        defer enc.deinit();
        var rates: [8]i32 = undefined;
        const got = rates[0..case.rates.len];
        const sum = enc.rateAllocation(got, enc.frame_size);
        try testing.expectEqualSlices(i32, case.rates, got);
        var total: i32 = 0;
        for (got) |r| total += r;
        try testing.expectEqual(total, sum);
    }
}

test "a packet needs room for every stream" {
    const gpa = testing.allocator;
    var enc = try Encoder.init(gpa, try Layout.init(6), .{ .bitrate = 128000 });
    defer enc.deinit();
    const pcm = try gpa.alloc(f32, 960 * 6);
    defer gpa.free(pcm);
    @memset(pcm, 0.1);
    var out: [8000]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, enc.encode(pcm, out[0..6]));
    try testing.expectError(error.InvalidFrameSize, enc.encode(pcm[0 .. 960 * 5], &out));
    const n = try enc.encode(pcm, &out);
    try testing.expect(n > 20 and n < 8000);
    try testing.expectError(error.InvalidFrameSize, Encoder.init(gpa, try Layout.init(6), .{ .frame_ms = 7 }));
}
/// Several channels with a tone each, a slow envelope, bursts and a little noise.
fn goldenSignal(pcm: []f32, channels: usize) void {
    var seed: u32 = 0x9e3779b9;
    const frames = pcm.len / channels;
    for (0..frames) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / 48000.0;
        for (0..channels) |c| {
            const cf: f64 = @floatFromInt(c);
            const env = 0.5 + 0.5 * @sin(2.0 * std.math.pi * (1.3 + 0.37 * cf) * t);
            var v = 0.25 * env * @sin(2.0 * std.math.pi * 110.0 * (cf + 1.0) * t);
            if ((i / 4800) % (c + 2) == 0) v += 0.1 * @sin(2.0 * std.math.pi * (1000.0 + 311.0 * cf) * t);
            seed = seed *% 1664525 +% 1013904223;
            const noise = @as(f64, @floatFromInt(@as(i32, @bitCast(seed)) >> 8)) / 8388608.0;
            v += 0.03 * noise * (0.3 + env);
            pcm[i * channels + c] = @floatCast(v);
        }
    }
}

const Golden = struct {
    channels: u32,
    bitrate: u32,
    vbr: bool,
    app: opus.Application,
    frame_ms: f32,
    complexity: u4,
    hash: u64,
};

fn goldenHash(g: Golden) !u64 {
    const gpa = testing.allocator;
    var enc = try Encoder.init(gpa, try Layout.init(g.channels), .{ .bitrate = g.bitrate, .vbr = g.vbr, .application = g.app, .frame_ms = g.frame_ms, .complexity = g.complexity });
    defer enc.deinit();
    for (enc.streams) |s| s.toc_overhead = false;
    const n = enc.frameSamples();
    const ch: usize = g.channels;
    const frames = 40;
    const pcm = try gpa.alloc(f32, frames * n * ch);
    defer gpa.free(pcm);
    goldenSignal(pcm, ch);
    const out = try gpa.alloc(u8, 6 * 1276 * g.channels);
    defer gpa.free(out);
    var h: u64 = test_util.fnv64_basis;
    for (0..frames) |f| {
        const len = try enc.encode(pcm[f * n * ch ..][0 .. n * ch], out);
        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(len), .big);
        h = test_util.fnv64(h, &hdr);
        h = test_util.fnv64(h, out[0..len]);
    }
    return h;
}

const golden = [_]Golden{
    .{ .channels = 6, .bitrate = 256000, .vbr = true, .app = .audio, .frame_ms = 20, .complexity = 4, .hash = 0xf2493dbc488821f1 },
    .{ .channels = 6, .bitrate = 64000, .vbr = true, .app = .voip, .frame_ms = 20, .complexity = 6, .hash = 0xf3cdc9b88df4bd99 },
    .{ .channels = 8, .bitrate = 128000, .vbr = false, .app = .audio, .frame_ms = 20, .complexity = 3, .hash = 0xf45e4faf22e6ea08 },
    .{ .channels = 5, .bitrate = 40000, .vbr = true, .app = .voip, .frame_ms = 40, .complexity = 2, .hash = 0xe8f6a7de10bb8f26 },
    .{ .channels = 3, .bitrate = 24000, .vbr = true, .app = .audio, .frame_ms = 10, .complexity = 5, .hash = 0xa5b5e448c08cc4df },
    .{ .channels = 10, .bitrate = 150000, .vbr = true, .app = .audio, .frame_ms = 20, .complexity = 4, .hash = 0x455e97b1a0a997f6 },
    .{ .channels = 2, .bitrate = 64000, .vbr = true, .app = .audio, .frame_ms = 20, .complexity = 4, .hash = 0x8c8e2ed47d0c23e5 },
    .{ .channels = 7, .bitrate = 90000, .vbr = true, .app = .voip, .frame_ms = 60, .complexity = 3, .hash = 0x8bfbf646bbfa14a2 },
    .{ .channels = 4, .bitrate = 48000, .vbr = false, .app = .low_delay, .frame_ms = 5, .complexity = 6, .hash = 0x5fafdd4cdbb65a28 },
};

test "packet streams equal the ones of libopus" {
    for (golden) |g| try testing.expectEqual(g.hash, try goldenHash(g));
}
