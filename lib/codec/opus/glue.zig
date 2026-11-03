//! Opus packet decoding on top of the CELT and SILK decoders: the TOC byte, the frames of a
//! packet, mode changes, packet loss and the final range. libopus is BSD 3 clause, see
//! LICENSE-libopus.
const std = @import("std");
const packet = @import("packet.zig");
const range = @import("range.zig");
const celt = @import("celt.zig");
const silk = @import("silk.zig");
const opus = @import("../opus.zig");

const decode_rate = 48000;
/// Samples of 2.5 ms, 5 ms, 10 ms and 20 ms at 48 kHz.
const f2_5 = 120;
const f5 = 240;
const f10 = 480;
const f20 = 960;

pub const Error = celt.decode.Error || error{ BufferTooSmall, InvalidFrameSize };

/// The last sample below 1.0.
const max_sample: f32 = 0x1.fffffep-1;

fn endBand(bandwidth: packet.Bandwidth) u32 {
    return switch (bandwidth) {
        .narrow => 13,
        .medium, .wide => 17,
        .super_wide => 19,
        .full => 21,
    };
}

/// Fades from `in1` to `in2` over 2.5 ms with the squared CELT window. `out` may be `in1`
/// or `in2`.
fn smoothFade(in1: []const f32, in2: []const f32, out: []f32, ch: usize) void {
    const window = &celt.tables.window120;
    for (0..f2_5) |i| {
        const w = window[i] * window[i];
        for (0..ch) |c| {
            out[i * ch + c] = w * in2[i * ch + c] + (1.0 - w) * in1[i * ch + c];
        }
    }
}

/// Decodes whole Opus packets to 48 kHz f32 samples.
pub const PacketDecoder = struct {
    channels: u32,
    celt: celt.decode.Decoder,
    silk: silk.decode.Decoder,
    /// The mode of the last decoded frame.
    prev_mode: ?packet.Mode = null,
    /// The last frame ended with a redundant CELT frame, so the CELT state is current.
    prev_redundancy: bool = false,
    /// Clamp the output to [-1, 1). A caller that applies a gain can turn this off and clamp itself.
    limit_output: bool = true,
    final_range: u32 = 0,
    /// How many redundant CELT frames failed to decode. They do not change the result.
    redundant_errors: u32 = 0,
    /// The mode and frame size of the last packet that was parsed.
    stream_mode: ?packet.Mode = null,
    frame_samples: usize = f2_5,
    /// The SILK settings of the last packet that held SILK data. A lost frame uses them.
    silk_channels: u32 = 1,
    silk_khz: u32 = 16,

    pub const InitError = error{InvalidChannels};

    /// A decoder for 1 or 2 output channels. A mono decoder skips the stereo phase inversion.
    pub fn init(channels: u32, options: opus.Options) InitError!PacketDecoder {
        if (channels != 1 and channels != 2) return error.InvalidChannels;
        return .{
            .channels = channels,
            .celt = celt.decode.Decoder.init(channels, channels == 1 or !options.phase_inversion),
            .silk = silk.decode.Decoder.init(),
        };
    }

    pub fn reset(self: *PacketDecoder) void {
        self.celt.reset();
        self.silk.reset();
        self.prev_mode = null;
        self.prev_redundancy = false;
        self.final_range = 0;
        self.redundant_errors = 0;
        self.stream_mode = null;
        self.frame_samples = f2_5;
        self.silk_channels = 1;
        self.silk_khz = 16;
    }

    /// The range coder state at the end of the last packet.
    pub fn finalRange(self: *const PacketDecoder) u32 {
        return self.final_range;
    }

    /// Decodes one packet into `out`, interleaved over the output channels. Returns the samples
    /// of each channel. The contents of `out` are undefined after an error. A CELT error still
    /// sets the final range and the mode, as libopus does.
    ///
    /// A missing packet (`pkt` null or empty) runs the loss concealment and fills all of `out`,
    /// so `out` holds the duration to conceal, a multiple of 2.5 ms in whole samples of every
    /// channel. An empty `out`, a length that is not a multiple of the channels and a duration that
    /// is not a multiple of 2.5 ms give `InvalidFrameSize`. A frame of one byte or none inside a
    /// packet is concealed too.
    ///
    /// With `fec` set, `pkt` is the packet after the lost one and `out` holds the duration of
    /// the lost packet. The first frame of `pkt` makes the end of `out` from its redundancy
    /// frames, and the concealment makes the rest. Without redundancy data, or when `pkt` or
    /// the packet before it is CELT, the concealment makes all of `out`.
    pub fn decode(self: *PacketDecoder, pkt: ?[]const u8, fec: bool, out: []f32) Error!usize {
        const ch: usize = self.channels;
        const frame_size = out.len / ch;
        if ((pkt == null or pkt.?.len == 0 or fec) and out.len % ch != 0) return error.InvalidFrameSize;
        const data = pkt orelse &.{};
        var total: usize = undefined;
        if (data.len == 0) {
            total = try self.concealAll(frame_size, out);
        } else {
            const p = try packet.parse(data, false);
            const frame_samples: usize = p.toc.frameSamples(decode_rate);
            if (fec) {
                if (frame_size % f2_5 != 0) return error.InvalidFrameSize;
                if (frame_size < frame_samples or p.toc.mode() == .celt or self.stream_mode == .celt) {
                    total = try self.concealAll(frame_size, out);
                } else {
                    const lost = frame_size - frame_samples;
                    if (lost != 0) _ = try self.concealAll(lost, out);
                    self.stream_mode = p.toc.mode();
                    self.frame_samples = frame_samples;
                    _ = try self.decodeFrame(p.toc, p.frame(0), true, frame_samples, out[lost * ch ..]);
                    total = frame_size;
                }
            } else {
                total = try self.decodeFrames(&p, out);
            }
        }
        if (self.limit_output) limit(out[0 .. total * ch]);
        return total;
    }

    /// Decodes a packet that `packet.parse` split, with or without self delimited framing.
    /// This is `decode` without a loss and without `fec`. `out` holds at least the samples of
    /// the packet. Returns the samples of each channel.
    pub fn decodeParsed(self: *PacketDecoder, p: *const packet.Packet, out: []f32) Error!usize {
        const total = try self.decodeFrames(p, out);
        if (self.limit_output) limit(out[0 .. total * self.channels]);
        return total;
    }

    fn decodeFrames(self: *PacketDecoder, p: *const packet.Packet, out: []f32) Error!usize {
        const ch: usize = self.channels;
        const frame_size = out.len / ch;
        const frame_samples: usize = p.toc.frameSamples(decode_rate);
        const total = p.count * frame_samples;
        if (out.len < total * ch) return error.BufferTooSmall;
        self.stream_mode = p.toc.mode();
        self.frame_samples = frame_samples;
        var done: usize = 0;
        for (0..p.count) |i| {
            done += try self.decodeFrame(p.toc, p.frame(i), false, frame_size - done, out[done * ch ..]);
        }
        std.debug.assert(done == total);
        return total;
    }

    fn limit(samples: []f32) void {
        for (samples) |*s| {
            s.* = if (std.math.isNan(s.*)) 0 else std.math.clamp(s.*, -1.0, max_sample);
        }
    }

    /// Conceals `frame_size` samples of each channel.
    fn concealAll(self: *PacketDecoder, frame_size: usize, out: []f32) Error!usize {
        if (frame_size % f2_5 != 0) return error.InvalidFrameSize;
        if (frame_size == 0) return error.InvalidFrameSize;
        const ch: usize = self.channels;
        var done: usize = 0;
        while (done < frame_size) {
            done += try self.decodeFrame(.{ .byte = 0 }, null, false, frame_size - done, out[done * ch ..]);
        }
        return frame_size;
    }

    /// One frame of a packet, in the order of opus_decode_frame, or a lost frame when
    /// `frame_data` is null or has one byte or none. `frame_size` is the room in `pcm_out`
    /// in samples of each channel. Returns the samples that it made.
    fn decodeFrame(self: *PacketDecoder, toc: packet.Toc, frame_data: ?[]const u8, fec: bool, frame_size_in: usize, pcm_out: []f32) Error!usize {
        const ch: usize = self.channels;
        var frame_size: usize = @min(frame_size_in, packet.max_samples);
        var data = frame_data;
        if (data == null or data.?.len <= 1) {
            // A concealed frame is not longer than the frames of the last packet.
            data = null;
            frame_size = @min(frame_size, self.frame_samples);
        }
        var audiosize: usize = undefined;
        var mode: packet.Mode = undefined;
        var dec = range.Decoder.init(&.{});
        if (data) |d| {
            audiosize = toc.frameSamples(decode_rate);
            mode = toc.mode();
            dec = range.Decoder.init(d);
        } else {
            audiosize = frame_size;
            mode = if (self.prev_redundancy) .celt else self.prev_mode orelse {
                @memset(pcm_out[0 .. audiosize * ch], 0);
                return audiosize;
            };
            if (audiosize > f20) {
                var left = audiosize;
                var done: usize = 0;
                while (left > 0) {
                    const n = try self.decodeFrame(toc, null, false, @min(left, f20), pcm_out[done * ch ..]);
                    done += n;
                    left -= n;
                }
                return frame_size;
            } else if (audiosize < f20) {
                if (audiosize > f10) {
                    audiosize = f10;
                } else if (mode != .silk and audiosize > f5 and audiosize < f10) {
                    audiosize = f5;
                }
            }
        }
        const accum = mode != .celt;

        var transition = false;
        if (data != null) {
            if (self.prev_mode) |prev| {
                transition = (mode == .celt and prev != .celt and !self.prev_redundancy) or (mode != .celt and prev == .celt);
            }
        }
        var pcm_transition: [f5 * 2]f32 = undefined;
        if (transition and mode == .celt) {
            _ = try self.decodeFrame(toc, null, false, @min(f5, audiosize), pcm_transition[0 .. f5 * ch]);
        }
        if (audiosize > frame_size or pcm_out.len < audiosize * ch) return error.BufferTooSmall;
        frame_size = audiosize;
        const pcm = pcm_out[0 .. audiosize * ch];
        const lm: u32 = @ctz(@min(f20, audiosize) / f2_5);
        var len: i32 = if (data) |d| @intCast(d.len) else 0;

        if (mode != .celt) {
            if (self.prev_mode == .celt) self.silk.reset();
            if (data != null) {
                self.silk_channels = toc.channels();
                self.silk_khz = if (mode == .silk) switch (toc.bandwidth()) {
                    .narrow => 8,
                    .medium => 12,
                    else => 16,
                } else 16;
            }
            const loss: silk.decode.Loss = if (data == null) .lost else if (fec) .fec else .none;
            try self.decodeSilk(loss, &dec, pcm);
        }

        var redundancy = false;
        var celt_to_silk = false;
        var red_bytes: i32 = 0;
        if (!fec and mode != .celt and data != null) {
            const hybrid = mode == .hybrid;
            if (dec.tell() + 17 + (if (hybrid) @as(i32, 20) else 0) <= 8 * len) {
                redundancy = if (hybrid) dec.bitLogp(12) else true;
                if (redundancy) {
                    celt_to_silk = dec.bitLogp(1);
                    red_bytes = if (hybrid) @as(i32, @intCast(dec.uint(256))) + 2 else len - ((dec.tell() + 7) >> 3);
                    len -= red_bytes;
                    // A size that cannot hold the symbols read so far drops the redundancy and
                    // leaves no bytes for the CELT part, which libopus then conceals.
                    if (len * 8 < dec.tell()) {
                        len = 0;
                        red_bytes = 0;
                        redundancy = false;
                    } else {
                        dec.shrink(@intCast(len));
                    }
                }
            }
        }
        if (redundancy) transition = false;

        if (transition and mode != .celt) {
            _ = try self.decodeFrame(toc, null, false, @min(f5, audiosize), pcm_transition[0 .. f5 * ch]);
        }

        if (data != null) self.celt.end = endBand(toc.bandwidth());

        var redundant: [f5 * 2]f32 = undefined;
        var redundant_rng: u32 = 0;
        const red_data: []const u8 = if (redundancy) data.?[@intCast(len)..][0..@intCast(red_bytes)] else &.{};
        if (redundancy and celt_to_silk) {
            redundant_rng = self.decodeRedundant(red_data, toc.channels(), redundant[0 .. f5 * ch]);
        }

        var celt_err: ?celt.decode.Error = null;
        if (mode != .silk) {
            if (self.prev_mode) |prev| {
                if (prev != mode and !self.prev_redundancy) self.celt.reset();
            }
            self.celt.start = if (mode == .hybrid) 17 else 0;
            if (data == null or fec or len <= 1) {
                self.celt.concealFrame(pcm, lm, accum);
            } else {
                const ext: ?*range.Decoder = if (mode == .hybrid) &dec else null;
                self.celt.decode(data.?[0..@intCast(len)], ext, toc.channels(), lm, pcm, mode == .hybrid) catch |e| {
                    celt_err = e;
                };
            }
            self.final_range = self.celt.rng;
        } else {
            // Leaving hybrid, a silent CELT frame adds the tail of the last CELT overlap.
            if (self.prev_mode == .hybrid and !(redundancy and celt_to_silk and self.prev_redundancy)) {
                self.celt.start = 0;
                // A silence frame of two bytes with a valid size cannot fail.
                self.celt.decode(&.{ 0xFF, 0xFF }, null, self.silk_channels, 0, pcm[0 .. f2_5 * ch], true) catch unreachable;
            }
            self.final_range = if (data != null) dec.finalRange() else 0;
        }

        if (redundancy and !celt_to_silk) {
            self.celt.reset();
            redundant_rng = self.decodeRedundant(red_data, toc.channels(), redundant[0 .. f5 * ch]);
            const tail = pcm[(audiosize - f2_5) * ch ..];
            smoothFade(tail, redundant[f2_5 * ch .. f5 * ch], tail, ch);
        }
        if (redundancy and celt_to_silk and (self.prev_mode != .silk or self.prev_redundancy)) {
            @memcpy(pcm[0 .. f2_5 * ch], redundant[0 .. f2_5 * ch]);
            smoothFade(redundant[f2_5 * ch .. f5 * ch], pcm[f2_5 * ch .. f5 * ch], pcm[f2_5 * ch .. f5 * ch], ch);
        }
        if (transition) {
            if (audiosize >= f5) {
                @memcpy(pcm[0 .. f2_5 * ch], pcm_transition[0 .. f2_5 * ch]);
                smoothFade(pcm_transition[f2_5 * ch .. f5 * ch], pcm[f2_5 * ch .. f5 * ch], pcm[f2_5 * ch .. f5 * ch], ch);
            } else {
                smoothFade(pcm_transition[0 .. f2_5 * ch], pcm[0 .. f2_5 * ch], pcm[0 .. f2_5 * ch], ch);
            }
        }

        if (len <= 1) self.final_range = 0 else self.final_range ^= redundant_rng;
        self.prev_mode = mode;
        self.prev_redundancy = redundancy and !celt_to_silk;
        if (celt_err) |e| return e;
        return audiosize;
    }

    /// Decodes a redundant CELT frame of 5 ms. libopus ignores an error of such a frame, so this
    /// counts it in `redundant_errors` and goes on.
    fn decodeRedundant(self: *PacketDecoder, data: []const u8, stream_ch: u32, out: []f32) u32 {
        self.celt.start = 0;
        self.celt.decode(data, null, stream_ch, 1, out, false) catch {
            self.redundant_errors +%= 1;
        };
        return self.celt.rng;
    }

    /// Runs the SILK decoder over the frame and writes f32 samples to `pcm`. A frame of fewer
    /// than 10 ms takes the start of a 10 ms frame.
    fn decodeSilk(self: *PacketDecoder, loss: silk.decode.Loss, dec: *range.Decoder, pcm: []f32) Error!void {
        const ch: usize = self.channels;
        const audio_size = pcm.len / ch;
        const ctl: silk.decode.Control = .{
            .channels_api = self.channels,
            .channels_internal = self.silk_channels,
            .internal_khz = self.silk_khz,
            .payload_ms = @intCast(@max(10, audio_size / (decode_rate / 1000))),
        };
        var buf: [f20 * 2]i16 = undefined;
        var done: usize = 0;
        while (done < audio_size) {
            const first = done == 0;
            const n = switch (loss) {
                .none => try self.silk.decode(ctl, first, dec, &buf),
                .fec => try self.silk.decodeFec(ctl, first, dec, &buf),
                .lost => try self.silk.conceal(ctl, first, &buf),
            };
            const take = @min(n, audio_size - done);
            const dst = pcm[done * ch ..][0 .. take * ch];
            for (dst, buf[0 .. take * ch]) |*d, s| d.* = @as(f32, @floatFromInt(s)) * (1.0 / 32768.0);
            done += n;
        }
    }
};

const testing = std.testing;
const test_util = @import("test_util.zig");
const fnv = test_util.fnv;

test "init takes one or two channels" {
    try testing.expectError(error.InvalidChannels, PacketDecoder.init(0, .{}));
    try testing.expectError(error.InvalidChannels, PacketDecoder.init(3, .{}));
    const d = try PacketDecoder.init(2, .{});
    try testing.expect(!d.celt.disable_inv);
    const m = try PacketDecoder.init(1, .{});
    try testing.expect(m.celt.disable_inv);
}

test "a silence frame decodes to zeros" {
    var d = try PacketDecoder.init(2, .{});
    var out: [960 * 2]f32 = @splat(1);
    const n = try d.decode(&.{ 0xFC, 0xFF, 0xFF }, false, &out);
    try testing.expectEqual(@as(usize, 960), n);
    for (out) |v| try testing.expectApproxEqAbs(@as(f32, 0), v, 1e-30);
}

/// Builds CELT packets of random bytes. The libopus check in the test uses the same generator.
const RandomPackets = struct {
    rng: test_util.Xorshift = .{ .s = 0x2545F491 },

    fn next(self: *RandomPackets) u32 {
        return self.rng.next();
    }

    fn packet(self: *RandomPackets, buf: *[1400]u8) []const u8 {
        const r = self.next();
        const config: u8 = @intCast(16 + r % 16);
        const stereo: u8 = @intCast((r >> 8) & 1);
        const code: u8 = if ((r >> 9) % 4 == 0) 1 else 0;
        const max_len: u32 = switch (self.next() % 4) {
            0 => 20,
            1 => 120,
            2 => 400,
            else => 1275,
        };
        var len = 2 + self.next() % (max_len - 1);
        if (code == 1) len = @max(len & ~@as(u32, 1), 4);
        buf[0] = config << 3 | stereo << 2 | code;
        test_util.fillPayload(&self.rng, buf[1..][0..len]);
        return buf[0 .. len + 1];
    }
};

test "random CELT packets give the libopus final range and a finite output" {
    var gen: RandomPackets = .{};
    var mono = try PacketDecoder.init(1, .{});
    var stereo = try PacketDecoder.init(2, .{});
    var buf: [1400]u8 = undefined;
    var out_m: [packet.max_samples]f32 = undefined;
    var out_s: [packet.max_samples * 2]f32 = undefined;
    var hash_m: u32 = 2166136261;
    var hash_s: u32 = 2166136261;
    for (0..1000) |_| {
        const pkt = gen.packet(&buf);
        const nm = try mono.decode(pkt, false, &out_m);
        const ns = try stereo.decode(pkt, false, &out_s);
        hash_m = fnv(fnv(hash_m, @intCast(nm)), mono.finalRange());
        hash_s = fnv(fnv(hash_s, @intCast(ns)), stereo.finalRange());
        for (out_m[0..nm]) |v| try testing.expect(v >= -1.0 and v < 1.0);
        for (out_s[0 .. ns * 2]) |v| try testing.expect(v >= -1.0 and v < 1.0);
    }
    // Both hashes come from libopus 1.6.1 decoding the same packets.
    try testing.expectEqual(@as(u32, 389360601), hash_m);
    try testing.expectEqual(@as(u32, 389360601), hash_s);
}

test "mutated packets decode without a panic" {
    var gen: RandomPackets = .{ .rng = .{ .s = 0x9E3779B9 } };
    var mono = try PacketDecoder.init(1, .{});
    var d = try PacketDecoder.init(2, .{});
    var buf: [1400]u8 = undefined;
    var out: [packet.max_samples * 2]f32 = undefined;
    var raw: [200]u8 = undefined;
    for (0..3000) |i| {
        const len = 1 + gen.next() % (raw.len - 1);
        for (raw[0..len]) |*b| b.* = @truncate(gen.next());
        // Most inputs get a CELT TOC, so that the decoder runs.
        if (i % 4 != 0) raw[0] |= 0x80;
        const dec = if (i % 2 == 0) &mono else &d;
        if (dec.decode(raw[0..len], false, &out)) |n| {
            for (out[0 .. n * dec.channels]) |v| try testing.expect(v >= -1.0 and v < 1.0);
        } else |err| try expectRejected(err);
    }
    for (0..600) |i| {
        const pkt = gen.packet(&buf);
        // Flip a few bits and cut the packet.
        for (0..1 + i % 4) |_| {
            const at = gen.next() % pkt.len;
            buf[at] ^= @as(u8, 1) << @intCast(gen.next() % 8);
        }
        const cut = 1 + gen.next() % pkt.len;
        if (d.decode(buf[0..cut], false, &out)) |n| {
            for (out[0 .. n * 2]) |v| try testing.expect(v >= -1.0 and v < 1.0);
        } else |err| try expectRejected(err);
    }
}

test "the options set the phase inversion of a stereo decoder" {
    const off = try PacketDecoder.init(2, .{ .phase_inversion = false });
    try testing.expect(off.celt.disable_inv);
}

test "a SILK packet decodes to one frame of finite samples" {
    var d = try PacketDecoder.init(2, .{});
    var out: [960 * 2]f32 = undefined;
    const n = try d.decode(&.{ 0x08, 0, 0 }, false, &out);
    try testing.expectEqual(@as(usize, 480 * 2), n);
    for (out[0 .. n * 2]) |v| try testing.expect(v >= -1.0 and v < 1.0);
    try testing.expectEqual(packet.Mode.silk, d.prev_mode.?);
}

test "random packets of every mode give the libopus sample counts and final ranges" {
    var gen: test_util.ModePackets = .{};
    var mono = try PacketDecoder.init(1, .{});
    var stereo = try PacketDecoder.init(2, .{});
    var buf: [test_util.ModePackets.max_len]u8 = undefined;
    var out_m: [packet.max_samples]f32 = undefined;
    var out_s: [packet.max_samples * 2]f32 = undefined;
    var hash_m: u32 = 2166136261;
    var hash_s: u32 = 2166136261;
    var redundant: usize = 0;
    var changes: usize = 0;
    var last: ?packet.Mode = null;
    for (0..2500) |_| {
        const pkt = gen.packet(&buf);
        const nm = try mono.decode(pkt, false, &out_m);
        const ns = try stereo.decode(pkt, false, &out_s);
        hash_m = fnv(fnv(hash_m, @intCast(nm)), mono.finalRange());
        hash_s = fnv(fnv(hash_s, @intCast(ns)), stereo.finalRange());
        for (out_m[0..nm]) |v| try testing.expect(v >= -1.0 and v < 1.0);
        for (out_s[0 .. ns * 2]) |v| try testing.expect(v >= -1.0 and v < 1.0);
        if (stereo.prev_redundancy) redundant += 1;
        if (last != stereo.prev_mode) changes += 1;
        last = stereo.prev_mode;
    }
    // Both hashes come from libopus 1.6.1 decoding the same packets.
    try testing.expectEqual(@as(u32, 980255149), hash_m);
    try testing.expectEqual(@as(u32, 980255149), hash_s);
    try testing.expect(redundant > 100 and changes > 1000);
}

fn clampSample(x: f32) f32 {
    return std.math.clamp(x, -1.0, max_sample);
}

test "a change from CELT to SILK starts with the concealed CELT frame" {
    var d = try PacketDecoder.init(2, .{});
    var gen: RandomPackets = .{};
    var buf: [1400]u8 = undefined;
    var out: [packet.max_samples * 2]f32 = undefined;
    for (0..3) |_| _ = try d.decode(gen.packet(&buf), false, &out);
    try testing.expectEqual(packet.Mode.celt, d.prev_mode.?);
    var probe = d.celt;
    var held: [f5 * 2]f32 = undefined;
    probe.concealFrame(&held, 1, false);

    const silk_packet = [_]u8{ 0x08, 0, 0 };
    var fresh = try PacketDecoder.init(2, .{});
    var plain: [960 * 2]f32 = undefined;
    const n = try fresh.decode(&silk_packet, false, &plain);
    try testing.expectEqual(n, try d.decode(&silk_packet, false, &out));

    for (0..f2_5 * 2) |i| try testing.expectEqual(clampSample(held[i]), out[i]);
    for (0..f2_5) |i| {
        const w = celt.tables.window120[i] * celt.tables.window120[i];
        for (0..2) |c| {
            const at = (f2_5 + i) * 2 + c;
            const want = clampSample(w * plain[at] + (1.0 - w) * held[at]);
            try testing.expectApproxEqAbs(want, out[at], 1e-6);
        }
    }
    for (f5 * 2..n * 2) |i| try testing.expectEqual(plain[i], out[i]);
}

test "a CELT error still sets the mode and the final range" {
    var d = try PacketDecoder.init(2, .{});
    var out: [960 * 2]f32 = undefined;
    _ = try d.decode(&.{ 0x08, 0, 0 }, false, &out);
    try testing.expect(d.finalRange() != 0);
    // The frame is too long for CELT, which rejects it before it reads a symbol. The CELT state
    // is reset by the mode change, so the final range is its range of 0.
    const long: [1276]u8 = @splat(0x55);
    try testing.expectError(error.InvalidPacket, d.decodeFrame(.{ .byte = 0xFC }, &long, false, 960, &out));
    try testing.expectEqual(packet.Mode.celt, d.prev_mode.?);
    try testing.expectEqual(@as(u32, 0), d.finalRange());
}

test "mutated packets of every mode decode without a panic" {
    var gen: test_util.ModePackets = .{ .rng = .{ .s = 0x6A09E667 } };
    var mono = try PacketDecoder.init(1, .{});
    var stereo = try PacketDecoder.init(2, .{});
    var buf: [test_util.ModePackets.max_len]u8 = undefined;
    var out: [packet.max_samples * 2]f32 = undefined;
    for (0..3000) |i| {
        var pkt = gen.packet(&buf);
        // Flip bits, cut the packet and give it the TOC byte of another mode.
        for (0..gen.next() % 4) |_| {
            const at = gen.next() % pkt.len;
            buf[at] ^= @as(u8, 1) << @intCast(gen.next() % 8);
        }
        if (gen.next() % 4 == 0) pkt = pkt[0 .. 1 + gen.next() % pkt.len];
        if (gen.next() % 4 == 0) buf[0] = @truncate(gen.next());
        if (i % 700 == 699) {
            mono.reset();
            stereo.reset();
        }
        if (mono.decode(pkt, false, &out)) |n| {
            for (out[0..n]) |v| try testing.expect(v >= -1.0 and v < 1.0);
        } else |err| try expectRejected(err);
        if (stereo.decode(pkt, false, &out)) |n| {
            for (out[0 .. n * 2]) |v| try testing.expect(v >= -1.0 and v < 1.0);
        } else |err| try expectRejected(err);
    }
}

test "packets of 120 ms decode to the full length" {
    var d = try PacketDecoder.init(2, .{});
    var out: [packet.max_samples * 2]f32 = undefined;
    // 48 CELT frames of 2.5 ms, each a silence frame.
    var celt_packet: [2 + 48 * 2]u8 = @splat(0xFF);
    celt_packet[0] = 0xE3;
    celt_packet[1] = 48;
    try testing.expectEqual(@as(usize, 5760), try d.decode(&celt_packet, false, &out));
    for (out) |v| try testing.expectApproxEqAbs(@as(f32, 0), v, 1e-30);
    try testing.expectEqual(@as(u32, 16777216), d.finalRange());
    // Two SILK frames of 60 ms.
    var silk_packet: [2 + 3 * 10]u8 = @splat(0);
    silk_packet[0] = 0x1B;
    silk_packet[1] = 2;
    try testing.expectEqual(@as(usize, 5760), try d.decode(silk_packet[0..22], false, &out));
    try testing.expectEqual(@as(u32, 1353049344), d.finalRange());
    // A third frame does not fit in 120 ms.
    silk_packet[1] = 3;
    try testing.expectError(error.InvalidPacket, d.decode(&silk_packet, false, &out));
}

fn expectRejected(err: Error) !void {
    // The output buffers of the tests have the largest size, so any other error is fine.
    if (err == error.BufferTooSmall) return error.TestUnexpectedResult;
}

test "a failed redundant frame is counted and does not stop the packet" {
    var d = try PacketDecoder.init(2, .{});
    var out: [f5 * 2]f32 = undefined;
    const long: [1276]u8 = @splat(0x55);
    _ = d.decodeRedundant(&long, 2, &out);
    try testing.expectEqual(@as(u32, 1), d.redundant_errors);
    d.reset();
    try testing.expectEqual(@as(u32, 0), d.redundant_errors);
}

const plc_expected = @import("plc_expected.zig");
const fec_mono_file = @embedFile("../testdata/opus/fec_mono.opus");
const fec_stereo_file = @embedFile("../testdata/opus/fec_stereo.opus");

fn playFile(file: []const u8, channels: u32, pattern: u8, fec: bool, expected: anytype, tolerance: i32) !void {
    const packets = try test_util.oggPackets(testing.allocator, file);
    defer test_util.freePackets(testing.allocator, packets);
    var d = try PacketDecoder.init(channels, .{});
    try test_util.playLoss(&d, packets, pattern, fec, expected, tolerance);
}

// The files are FFmpeg libopus encodes with in band FEC on. libopus decoded them with the loss patterns
// of test_util.isLost. The SILK parts are exact, so the tolerance only matters for the hybrid
// packets at the start of the stereo file.
const file_tolerance = 2;

test "mono file with lost packets gives the libopus results" {
    try playFile(fec_mono_file, 1, 1, false, plc_expected.mono_p1_f0, file_tolerance);
    try playFile(fec_mono_file, 1, 0, true, plc_expected.mono_p0_f1, file_tolerance);
    try playFile(fec_mono_file, 1, 1, true, plc_expected.mono_p1_f1, file_tolerance);
    try playFile(fec_mono_file, 1, 2, false, plc_expected.mono_p2_f0, file_tolerance);
    try playFile(fec_mono_file, 1, 3, false, plc_expected.mono_p3_f0, file_tolerance);
    try playFile(fec_mono_file, 1, 5, true, plc_expected.mono_p5_f1, file_tolerance);
}

test "stereo file with lost packets gives the libopus results" {
    try playFile(fec_stereo_file, 2, 1, false, plc_expected.stereo_p1_f0, file_tolerance);
    try playFile(fec_stereo_file, 2, 0, true, plc_expected.stereo_p0_f1, file_tolerance);
    try playFile(fec_stereo_file, 2, 1, true, plc_expected.stereo_p1_f1, file_tolerance);
    try playFile(fec_stereo_file, 2, 2, false, plc_expected.stereo_p2_f0, file_tolerance);
    try playFile(fec_stereo_file, 2, 3, false, plc_expected.stereo_p3_f0, file_tolerance);
    try playFile(fec_stereo_file, 2, 3, true, plc_expected.stereo_p3_f1, file_tolerance);
    try playFile(fec_stereo_file, 2, 5, true, plc_expected.stereo_p5_f1, file_tolerance);
}

test "random packets of every mode with lost frames of any size give the libopus counts and ranges" {
    const packets = try test_util.mixedPackets(testing.allocator, 0x1F123BB5, 300);
    defer test_util.freePackets(testing.allocator, packets);
    inline for (.{ 1, 2 }) |channels| {
        inline for (.{ false, true }) |fec| {
            const name = std.fmt.comptimePrint("random_c{d}_f{d}", .{ channels, @intFromBool(fec) });
            var d = try PacketDecoder.init(channels, .{});
            try test_util.playLoss(&d, packets, 4, fec, @field(plc_expected, name), 0);
        }
    }
}

fn energyOf(samples: []const f32) f64 {
    var sum: f64 = 0;
    for (samples) |v| sum += @as(f64, v) * v;
    return sum;
}

fn errorEnergy(a: []const f32, b: []const f32) f64 {
    var sum: f64 = 0;
    for (a, b) |x, y| sum += (@as(f64, x) - y) * (@as(f64, x) - y);
    return sum;
}

fn expectInRange(samples: []const f32) !void {
    for (samples) |v| try testing.expect(v >= -1.0 and v < 1.0);
}

test "a loss before the first packet gives silence and leaves the decoder fresh" {
    inline for (.{ 1, 2 }) |channels| {
        var d = try PacketDecoder.init(channels, .{});
        var fresh = try PacketDecoder.init(channels, .{});
        var out: [960 * channels]f32 = @splat(1);
        try testing.expectEqual(@as(usize, 960), try d.decode(null, false, &out));
        for (out) |v| try testing.expectEqual(@as(f32, 0), v);
        try testing.expectEqual(@as(u32, 0), d.finalRange());
        var a: [960 * channels]f32 = undefined;
        var b: [960 * channels]f32 = undefined;
        const pkt = [_]u8{ 0x78, 0x55, 0xAA, 0x55, 0xAA, 0x12, 0x34, 0x56 };
        try testing.expectEqual(try fresh.decode(&pkt, false, &a), try d.decode(&pkt, false, &b));
        try testing.expectEqualSlices(f32, &a, &b);
    }
}

test "lost frames need a size that is a multiple of 2.5 ms" {
    var d = try PacketDecoder.init(2, .{});
    var out: [960 * 2]f32 = undefined;
    try testing.expectError(error.InvalidFrameSize, d.decode(null, false, out[0..200]));
    try testing.expectError(error.InvalidFrameSize, d.decode(null, false, out[0..0]));
    try testing.expectError(error.InvalidFrameSize, d.decode(null, false, out[0..1]));
    try testing.expectError(error.InvalidFrameSize, d.decode(null, false, out[0..481]));
    const pkt = [_]u8{ 0xF8, 0xFF, 0xFF };
    try testing.expectError(error.InvalidFrameSize, d.decode(&pkt, true, out[0..200]));
    try testing.expectError(error.BufferTooSmall, d.decode(&pkt, false, out[0..100]));
    // An empty packet is a lost frame.
    try testing.expectEqual(@as(usize, 480), try d.decode(&.{}, false, out[0 .. 480 * 2]));
}

test "a frame with no data conceals as long as the frames of the packet" {
    var d = try PacketDecoder.init(2, .{});
    var out: [5760 * 2]f32 = undefined;
    var gen: RandomPackets = .{};
    var buf: [1400]u8 = undefined;
    for (0..4) |_| _ = try d.decode(gen.packet(&buf), false, &out);
    var lost = d;
    lost.frame_samples = 960;
    var made: [5760 * 2]f32 = undefined;
    // The TOC of a CELT packet of 20 ms alone.
    const toc: u8 = (31 << 3) | 4;
    try testing.expectEqual(@as(usize, 960), try d.decode(&.{toc}, false, &out));
    try testing.expectEqual(@as(u32, 0), d.finalRange());
    try testing.expectEqual(@as(usize, 960), try lost.decode(null, false, made[0 .. 960 * 2]));
    try testing.expectEqualSlices(f32, made[0 .. 960 * 2], out[0 .. 960 * 2]);
}

test "a concealed frame is made in steps of the last frame size" {
    var d = try PacketDecoder.init(2, .{});
    var out: [960 * 2]f32 = undefined;
    var gen: RandomPackets = .{ .rng = .{ .s = 77 } };
    var buf: [1400]u8 = undefined;
    // CELT frames of 10 ms: 20 ms of loss takes two steps.
    while (true) {
        const pkt = gen.packet(&buf);
        if (pkt[0] >> 3 != 30) continue;
        _ = try d.decode(pkt, false, &out);
        break;
    }
    var steps = d;
    var whole: [960 * 2]f32 = undefined;
    var first: [480 * 2]f32 = undefined;
    var second: [480 * 2]f32 = undefined;
    try testing.expectEqual(@as(usize, 960), try d.decode(null, false, &whole));
    _ = try steps.decode(null, false, &first);
    _ = try steps.decode(null, false, &second);
    try testing.expectEqualSlices(f32, whole[0 .. 480 * 2], &first);
    try testing.expectEqualSlices(f32, whole[480 * 2 ..], &second);
}

test "FEC without redundancy data falls back to the concealment" {
    const packets = try test_util.oggPackets(testing.allocator, fec_mono_file);
    defer test_util.freePackets(testing.allocator, packets);
    var d = try PacketDecoder.init(1, .{});
    var out: [960 * 4]f32 = undefined;
    for (packets[10..20]) |p| _ = try d.decode(p, false, &out);
    // A SILK packet whose header says there is no redundancy.
    const plain = [_]u8{ 0x48, 0, 0 };
    // A CELT packet.
    const celt_packet = [_]u8{ 0xF8, 0x55, 0xAA, 0x12, 0x34 };

    var plc = d;
    var a: [960]f32 = undefined;
    var b: [960]f32 = undefined;
    _ = try plc.decode(null, false, &a);
    var fec = d;
    _ = try fec.decode(&plain, true, &b);
    try testing.expectEqualSlices(f32, &a, &b);
    try testing.expect(fec.silk.channels[0].lbrr_flag == false);

    fec = d;
    _ = try fec.decode(&celt_packet, true, &b);
    try testing.expectEqualSlices(f32, &a, &b);
    try testing.expectEqual(@as(u32, 0), fec.finalRange());

    // The lost audio is shorter than the frame of the next packet.
    fec = d;
    var short_plc = d;
    var c: [480]f32 = undefined;
    var e: [480]f32 = undefined;
    _ = try short_plc.decode(null, false, &c);
    _ = try fec.decode(packets[20], true, &e);
    try testing.expectEqualSlices(f32, &c, &e);
}

test "FEC with a longer gap conceals the start and decodes the last frame from the redundancy" {
    const packets = try test_util.oggPackets(testing.allocator, fec_mono_file);
    defer test_util.freePackets(testing.allocator, packets);
    var d = try PacketDecoder.init(1, .{});
    var out: [960 * 4]f32 = undefined;
    for (packets[10..30]) |p| _ = try d.decode(p, false, &out);
    var whole = d;
    var parts = d;
    var all: [960 * 2]f32 = undefined;
    var head: [960]f32 = undefined;
    var tail: [960]f32 = undefined;
    try testing.expectEqual(@as(usize, 1920), try whole.decode(packets[30], true, &all));
    _ = try parts.decode(null, false, &head);
    _ = try parts.decode(packets[30], true, &tail);
    try testing.expectEqualSlices(f32, &head, all[0..960]);
    try testing.expectEqualSlices(f32, &tail, all[960..]);
    try testing.expect(whole.finalRange() != 0);
    try testing.expectEqual(whole.finalRange(), parts.finalRange());
}

test "the FEC files hold redundancy frames for each channel" {
    inline for (.{ .{ fec_mono_file, 1, 100, 0 }, .{ fec_stereo_file, 2, 100, 8 } }) |spec| {
        const packets = try test_util.oggPackets(testing.allocator, spec[0]);
        defer test_util.freePackets(testing.allocator, packets);
        var d = try PacketDecoder.init(spec[1], .{});
        var out: [960 * 2]f32 = undefined;
        var counts = [2]usize{ 0, 0 };
        for (packets) |p| {
            // A frame of fewer than two bytes is concealed and sets no flags.
            for (&d.silk.channels) |*c| c.lbrr_flag = false;
            _ = try d.decode(p, false, &out);
            for (0..spec[1]) |c| {
                if (d.silk.channels[c].lbrr_flag) counts[c] += 1;
            }
        }
        try testing.expect(counts[0] >= spec[2]);
        if (spec[1] == 2) try testing.expect(counts[1] >= spec[3]);
    }
}

test "FEC makes audio that follows the lost frame" {
    inline for (.{ .{ fec_mono_file, 1 }, .{ fec_stereo_file, 2 } }) |spec| {
        const channels = spec[1];
        const packets = try test_util.oggPackets(testing.allocator, spec[0]);
        defer test_util.freePackets(testing.allocator, packets);
        var d = try PacketDecoder.init(channels, .{});
        var real: [960 * channels]f32 = undefined;
        var plc_out: [960 * channels]f32 = undefined;
        var fec_out: [960 * channels]f32 = undefined;
        var differing: usize = 0;
        var fec_error: f64 = 0;
        var signal: f64 = 0;
        for (packets[0 .. packets.len - 1], 0..) |p, i| {
            var a = d;
            var b = d;
            _ = try d.decode(p, false, &real);
            if (i >= 12 and i % 3 == 0) {
                _ = try a.decode(null, false, &plc_out);
                _ = try b.decode(packets[i + 1], true, &fec_out);
                try expectInRange(&fec_out);
                if (!std.mem.eql(f32, &plc_out, &fec_out)) differing += 1;
                fec_error += errorEnergy(&real, &fec_out);
                signal += energyOf(&real);
            }
        }
        // The redundancy is coarser than the main frame, but it follows the lost audio.
        try testing.expect(differing >= 25);
        try testing.expect(fec_error < 0.25 * signal);
    }
}

test "a change from SILK or hybrid to CELT starts with the concealed old frame" {
    const packets = try test_util.oggPackets(testing.allocator, fec_stereo_file);
    defer test_util.freePackets(testing.allocator, packets);
    var gen: RandomPackets = .{ .rng = .{ .s = 4242 } };
    var buf: [1400]u8 = undefined;
    // The file starts with hybrid packets and goes on with SILK.
    var short: usize = 0;
    var long: usize = 0;
    inline for (.{ 3, 40 }) |at| {
        var d = try PacketDecoder.init(1, .{});
        var out: [960 * 4]f32 = undefined;
        for (packets[0 .. at + 1]) |p| _ = try d.decode(p, false, &out);
        try testing.expectEqual(if (at == 3) packet.Mode.hybrid else packet.Mode.silk, d.prev_mode.?);
        for (0..24) |_| {
            const pkt = gen.packet(&buf);
            if (pkt[0] < 0x80) continue;
            var fresh = try PacketDecoder.init(1, .{});
            var plain: [packet.max_samples]f32 = undefined;
            var mixed = d;
            const frame: usize = packet.Toc.frameSamples(.{ .byte = pkt[0] }, decode_rate);
            // The concealment that the change uses is as long as the frame, up to 5 ms.
            var probe = d;
            var held: [f5]f32 = undefined;
            _ = try probe.decode(null, false, held[0..@min(f5, frame)]);
            const n = try fresh.decode(pkt, false, &plain);
            try testing.expectEqual(n, try mixed.decode(pkt, false, &out));
            for (0..f2_5) |i| {
                const w = celt.tables.window120[i] * celt.tables.window120[i];
                if (frame >= f5) {
                    if (i == 0) long += 1;
                    try testing.expectEqual(clampSample(held[i]), out[i]);
                    const want = clampSample(w * plain[f2_5 + i] + (1.0 - w) * held[f2_5 + i]);
                    // The packet output is clamped, so only unclamped samples can be compared.
                    if (@abs(plain[f2_5 + i]) < 0.99) try testing.expectApproxEqAbs(want, out[f2_5 + i], 1e-5);
                } else {
                    // A frame of 2.5 ms gets the cross fade over its whole length.
                    if (i == 0) short += 1;
                    const want = clampSample(w * plain[i] + (1.0 - w) * held[i]);
                    if (@abs(plain[i]) < 0.99) try testing.expectApproxEqAbs(want, out[i], 1e-5);
                }
            }
            for (@min(f5, frame)..n) |i| try testing.expectEqual(plain[i], out[i]);
        }
    }
    // Both fade branches ran: frames of 5 ms or more, and frames of 2.5 ms.
    try testing.expect(short > 0 and long > 0);
}

test "many lost frames in a row stay finite and fade toward silence" {
    const packets = try test_util.oggPackets(testing.allocator, fec_mono_file);
    defer test_util.freePackets(testing.allocator, packets);
    var out: [960]f32 = undefined;
    // SILK: the concealment fades to a faint comfort noise.
    var d = try PacketDecoder.init(1, .{});
    for (packets[0..40]) |p| _ = try d.decode(p, false, &out);
    var energies: [60]f64 = undefined;
    for (&energies) |*e| {
        try testing.expectEqual(@as(usize, 960), try d.decode(null, false, &out));
        try expectInRange(&out);
        e.* = energyOf(&out);
    }
    try testing.expect(energies[0] > 1e-3);
    try testing.expect(energies[59] < energies[0] * 1e-3);

    // CELT: the pitch repeat gives way to noise that falls to the background level.
    var celt_decoder = try PacketDecoder.init(2, .{});
    var gen: RandomPackets = .{ .rng = .{ .s = 99 } };
    var buf: [1400]u8 = undefined;
    var stereo: [960 * 2]f32 = undefined;
    for (0..6) |_| _ = try celt_decoder.decode(gen.packet(&buf), false, &stereo);
    var first: f64 = 0;
    var last: f64 = 0;
    for (0..100) |i| {
        try testing.expectEqual(@as(usize, 960), try celt_decoder.decode(null, false, &stereo));
        try expectInRange(&stereo);
        if (i == 0) first = energyOf(&stereo);
        last = energyOf(&stereo);
    }
    try testing.expect(last <= first);
}

test "random loss and FEC mixed into mutated packets never panic" {
    var gen: test_util.ModePackets = .{ .rng = .{ .s = 0x3C6EF372 } };
    var mono = try PacketDecoder.init(1, .{});
    var stereo = try PacketDecoder.init(2, .{});
    var buf: [test_util.ModePackets.max_len]u8 = undefined;
    var out: [packet.max_samples * 2]f32 = undefined;
    for (0..4000) |i| {
        var pkt = gen.packet(&buf);
        for (0..gen.next() % 4) |_| {
            const at = gen.next() % pkt.len;
            buf[at] ^= @as(u8, 1) << @intCast(gen.next() % 8);
        }
        if (gen.next() % 4 == 0) pkt = pkt[0 .. 1 + gen.next() % pkt.len];
        if (gen.next() % 8 == 0) buf[0] = @truncate(gen.next());
        if (i % 900 == 899) {
            mono.reset();
            stereo.reset();
        }
        for ([_]*PacketDecoder{ &mono, &stereo }) |dec| {
            const ch = dec.channels;
            const size = 120 * (1 + gen.next() % 48);
            switch (gen.next() % 4) {
                0 => {
                    const n = try dec.decode(null, false, out[0 .. size * ch]);
                    try testing.expectEqual(size, n);
                    try expectInRange(out[0 .. n * ch]);
                },
                1 => {
                    if (dec.decode(pkt, true, out[0 .. size * ch])) |n| {
                        try testing.expectEqual(size, n);
                        try expectInRange(out[0 .. n * ch]);
                    } else |err| try expectRejected(err);
                },
                else => {
                    if (dec.decode(pkt, false, &out)) |n| {
                        try expectInRange(out[0 .. n * ch]);
                    } else |err| try expectRejected(err);
                },
            }
        }
    }
}

test "a hybrid frame with an impossible redundancy size is concealed like libopus" {
    const packets = try test_util.withBadRedundancy(testing.allocator, fec_stereo_file);
    defer test_util.freePackets(testing.allocator, packets);
    var d = try PacketDecoder.init(1, .{});
    try test_util.playLoss(&d, packets, 6, false, plc_expected.bad_redundancy, 2);
    // The frame is the sixth packet. It has no CELT bytes left, so its final range is 0.
    var e = try PacketDecoder.init(1, .{});
    var out: [960]f32 = undefined;
    for (packets[0..5]) |p| _ = try e.decode(p, false, &out);
    try testing.expectEqual(@as(usize, 960), try e.decode(packets[5], false, &out));
    try testing.expectEqual(@as(u32, 0), e.finalRange());
    try testing.expectEqual(packet.Mode.hybrid, e.prev_mode.?);
    try testing.expectEqual(@as(i32, 8), e.celt.loss_duration);
}
