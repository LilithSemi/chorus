//! Round trip tests of the Opus packet encoder through the packet decoder.
const std = @import("std");
const opus = @import("../opus.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;
const rate = 48000;

const Signal = enum { sine, noise, chirp, impulses, silence, mixed };

fn uniform(rng: *test_util.Xorshift) f64 {
    return @as(f64, @floatFromInt(rng.next() >> 8)) / 8388608.0 - 1.0;
}

/// Fills `pcm` with a test signal. The noise and the pulses have no energy above 20 kHz, the top of
/// the coded band, so that the SNR can reach high values.
fn fill(kind: Signal, pcm: []f32, channels: usize, seed: u32) void {
    var rng: test_util.Xorshift = .{ .s = seed };
    const frames = pcm.len / channels;
    var lp: [2][4]f64 = @splat(@splat(0));
    for (0..frames) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / rate;
        for (0..channels) |c| {
            const cf: f64 = @floatFromInt(c);
            const v: f64 = switch (kind) {
                .sine => 0.5 * @sin(2.0 * std.math.pi * (440.0 + 110.0 * cf) * t),
                .noise => blk: {
                    var x = uniform(&rng);
                    for (&lp[c]) |*s| {
                        s.* += 0.5 * (x - s.*);
                        x = s.*;
                    }
                    break :blk 1.6 * x;
                },
                .chirp => 0.5 * @sin(2.0 * std.math.pi * (200.0 * t + 2000.0 * t * t * 0.5) + cf),
                .impulses => blk: {
                    const d = @as(f64, @floatFromInt(i % 4800)) - 300.0 - 40.0 * cf;
                    break :blk 0.8 * @exp(-d * d / 72.0);
                },
                .silence => 0,
                .mixed => 0.3 * @sin(2.0 * std.math.pi * 330.0 * t) + 0.2 * @sin(2.0 * std.math.pi * (1760.0 + 55.0 * cf) * t) +
                    0.05 * uniform(&rng),
            };
            pcm[i * channels + c] = @floatCast(v);
        }
    }
}

const Result = struct {
    snr_db: f64,
    bytes: usize,
    packets: usize,
    range_mismatches: usize,
    min_len: usize,
    max_len: usize,
};

fn snrAt(input: []const f32, output: []const f32, ch: usize, delay: usize, skip: usize) f64 {
    var sig: f64 = 0;
    var err: f64 = 0;
    const frames = input.len / ch;
    var i: usize = skip;
    while (i + delay < frames) : (i += 1) {
        for (0..ch) |c| {
            const a: f64 = input[i * ch + c];
            const b: f64 = output[(i + delay) * ch + c];
            sig += a * a;
            err += (a - b) * (a - b);
        }
    }
    return 10.0 * std.math.log10((sig + 1e-20) / (err + 1e-20));
}

/// Encodes a signal, decodes it and measures the SNR after the delay of the codec.
fn roundTrip(channels: u32, options: opus.EncodeOptions, kind: Signal, millis: usize) !Result {
    var enc = try opus.PacketEncoder.init(channels, options);
    var dec = try opus.PacketDecoder.init(channels, .{});
    const n = enc.frameSamples();
    const ch: usize = channels;
    const frames = millis * rate / 1000 / n;
    const input = try testing.allocator.alloc(f32, frames * n * ch);
    defer testing.allocator.free(input);
    const output = try testing.allocator.alloc(f32, frames * n * ch);
    defer testing.allocator.free(output);
    fill(kind, input, ch, 12345);
    var res: Result = .{ .snr_db = 0, .bytes = 0, .packets = 0, .range_mismatches = 0, .min_len = 1 << 20, .max_len = 0 };
    var pkt: [1276]u8 = undefined;
    for (0..frames) |f| {
        const len = try enc.encode(input[f * n * ch ..][0 .. n * ch], &pkt);
        res.bytes += len;
        res.packets += 1;
        res.min_len = @min(res.min_len, len);
        res.max_len = @max(res.max_len, len);
        const got = try dec.decode(pkt[0..len], false, output[f * n * ch ..][0 .. n * ch]);
        try testing.expectEqual(n, got);
        if (dec.finalRange() != enc.finalRange()) res.range_mismatches += 1;
    }
    res.snr_db = snrAt(input, output, ch, enc.lookahead(), 4 * n);
    return res;
}

const sizes = [4]f32{ 2.5, 5, 10, 20 };
const all_sizes = [9]f32{ 2.5, 5, 10, 20, 40, 60, 80, 100, 120 };
const rates = [4]u32{ 32000, 64000, 128000, 256000 };

/// The lowest SNR in dB that a signal may reach for the frame size (rows) and the bitrate
/// (columns). Each value is the lower one of the variable and the constant bitrate run, less
/// 3 dB, rounded down. The low values at 32 and 64 kbit/s are expected: CELT codes the shape of
/// a band as noise when it has few bits, and a stereo signal at a low rate is coded as mono.
/// A floor of 0 or less is not checked: silent output scores 0 dB, so such a cell would assert
/// nothing. Those cells only keep the decode and the final range checks.
const Floors = [4][4]i32;
const floors = struct {
    const sine = [2]Floors{
        .{ .{ 5, 29, 40, 40 }, .{ 22, 38, 39, 38 }, .{ 24, 41, 41, 41 }, .{ 38, 40, 40, 40 } },
        .{ .{ -2, -2, 30, 38 }, .{ -1, 26, 33, 38 }, .{ 11, 32, 36, 40 }, .{ 28, 34, 39, 40 } },
    };
    const noise = [2]Floors{
        .{ .{ -1, 9, 18, 24 }, .{ 4, 10, 19, 24 }, .{ 5, 10, 18, 24 }, .{ 5, 10, 18, 24 } },
        .{ .{ -2, 0, 9, 17 }, .{ -2, 4, 10, 18 }, .{ 1, 4, 11, 18 }, .{ 1, 4, 10, 17 } },
    };
    const chirp = [2]Floors{
        .{ .{ 3, 18, 41, 41 }, .{ 10, 38, 40, 41 }, .{ 14, 39, 41, 42 }, .{ 34, 39, 42, 42 } },
        .{ .{ 0, -4, 35, 41 }, .{ -2, 21, 37, 41 }, .{ 6, 31, 38, 41 }, .{ 20, 33, 39, 42 } },
    };
    const impulses = [2]Floors{
        .{ .{ -2, 14, 18, 19 }, .{ 10, 11, 18, 19 }, .{ 16, 16, 18, 19 }, .{ 12, 17, 19, 19 } },
        .{ .{ -4, -4, 14, 18 }, .{ -3, 4, 15, 18 }, .{ 8, 7, 16, 19 }, .{ 9, 10, 17, 19 } },
    };
    const mixed = [2]Floors{
        .{ .{ 5, 13, 20, 23 }, .{ 9, 15, 21, 23 }, .{ 11, 16, 21, 23 }, .{ 14, 17, 22, 23 } },
        .{ .{ 2, 4, 14, 20 }, .{ 2, 10, 15, 20 }, .{ 6, 12, 16, 21 }, .{ 11, 13, 17, 22 } },
    };

    fn get(kind: Signal) [2]Floors {
        return switch (kind) {
            .sine => sine,
            .noise => noise,
            .chirp => chirp,
            .impulses => impulses,
            .mixed => mixed,
            .silence => unreachable,
        };
    }
};

test "round trips stay above the SNR floors and keep the final range" {
    const kinds = [_]Signal{ .sine, .noise, .chirp, .impulses, .mixed };
    for (kinds) |kind| {
        const table = floors.get(kind);
        for ([_]u32{ 1, 2 }) |channels| {
            for (sizes, 0..) |fm, si| {
                for (rates, 0..) |br, ri| {
                    for ([_]bool{ true, false }) |vbr| {
                        const r = try roundTrip(channels, .{ .bitrate = br, .frame_ms = fm, .vbr = vbr }, kind, 1000);
                        try testing.expectEqual(@as(usize, 0), r.range_mismatches);
                        const floor: f64 = @floatFromInt(table[channels - 1][si][ri]);
                        if (floor > 0 and r.snr_db < floor) {
                            std.debug.print("{s} ch{d} {d}ms {d} vbr={}: {d:.1} dB below {d}\n", .{ @tagName(kind), channels, fm, br, vbr, r.snr_db, floor });
                            return error.TestExpectedEqual;
                        }
                    }
                }
            }
        }
    }
}

test "a decoder lags the encoder by the lookahead" {
    var enc = try opus.PacketEncoder.init(1, .{ .bitrate = 128000 });
    var dec = try opus.PacketDecoder.init(1, .{});
    const n = enc.frameSamples();
    const frames = 30;
    var input: [frames * 960]f32 = undefined;
    var output: [frames * 960]f32 = undefined;
    fill(.noise, &input, 1, 99);
    var pkt: [1276]u8 = undefined;
    for (0..frames) |f| {
        const len = try enc.encode(input[f * n ..][0..n], &pkt);
        _ = try dec.decode(pkt[0..len], false, output[f * n ..][0..n]);
    }
    var best: usize = 0;
    var best_snr: f64 = -100;
    for (0..400) |d| {
        const snr = snrAt(&input, &output, 1, d, 4 * n);
        if (snr > best_snr) {
            best_snr = snr;
            best = d;
        }
    }
    try testing.expectEqual(@as(usize, enc.lookahead()), best);
}

/// The size that libopus gives to a constant bitrate packet, the TOC byte included.
fn cbrBytes(bitrate: u32, samples: usize) usize {
    return (bitrate * samples / rate + 4) / 8;
}

test "constant bitrate packets have the exact size" {
    const kinds = [_]Signal{ .silence, .sine, .noise, .impulses, .mixed };
    for (kinds) |kind| {
        for ([_]u32{ 1, 2 }) |channels| {
            for (sizes) |fm| {
                for (rates) |br| {
                    const r = try roundTrip(channels, .{ .bitrate = br, .frame_ms = fm, .vbr = false }, kind, 500);
                    const n: usize = @intFromFloat(fm * 48);
                    const want = cbrBytes(br, n);
                    try testing.expectEqual(want, r.min_len);
                    try testing.expectEqual(want, r.max_len);
                    try testing.expectEqual(want * r.packets, r.bytes);
                }
            }
        }
    }
    // The packet is not longer than the buffer.
    var enc = try opus.PacketEncoder.init(2, .{ .bitrate = 128000, .vbr = false });
    var input: [960 * 2]f32 = undefined;
    fill(.mixed, &input, 2, 5);
    var small: [100]u8 = undefined;
    try testing.expectEqual(@as(usize, 100), try enc.encode(&input, &small));
}

test "the default bitrate follows the channels" {
    const mono = try opus.PacketEncoder.init(1, .{});
    const stereo = try opus.PacketEncoder.init(2, .{});
    try testing.expectEqual(@as(u32, 51000), mono.bitrate);
    try testing.expectEqual(@as(u32, 99000), stereo.bitrate);
    const fast = try opus.PacketEncoder.init(1, .{ .frame_ms = 2.5 });
    try testing.expectEqual(@as(u32, 72000), fast.bitrate);
    const clamped = try opus.PacketEncoder.init(1, .{ .bitrate = 10_000_000 });
    try testing.expectEqual(@as(u32, 750000), clamped.bitrate);
}

test "variable bitrate averages near the target" {
    // The packets include the TOC byte, so the average bitrate of the packets is the target.
    const cases = [_]struct { channels: u32, ms: f32, bitrate: u32, kind: Signal, tolerance: f64 }{
        .{ .channels = 1, .ms = 20, .bitrate = 64000, .kind = .mixed, .tolerance = 0.03 },
        .{ .channels = 2, .ms = 20, .bitrate = 128000, .kind = .mixed, .tolerance = 0.03 },
        .{ .channels = 1, .ms = 10, .bitrate = 32000, .kind = .noise, .tolerance = 0.05 },
        .{ .channels = 2, .ms = 10, .bitrate = 96000, .kind = .chirp, .tolerance = 0.05 },
        .{ .channels = 1, .ms = 5, .bitrate = 64000, .kind = .sine, .tolerance = 0.06 },
        .{ .channels = 1, .ms = 20, .bitrate = 256000, .kind = .noise, .tolerance = 0.03 },
        .{ .channels = 1, .ms = 20, .bitrate = 64000, .kind = .impulses, .tolerance = 0.05 },
    };
    for (cases) |c| {
        const r = try roundTrip(c.channels, .{ .bitrate = c.bitrate, .frame_ms = c.ms }, c.kind, 4000);
        const average = @as(f64, @floatFromInt(r.bytes * 8)) / 4.0;
        const target: f64 = @floatFromInt(c.bitrate);
        if (@abs(average - target) > c.tolerance * target) {
            std.debug.print("{s} ch{d} {d}ms {d}: average {d:.0}\n", .{ @tagName(c.kind), c.channels, c.ms, c.bitrate, average });
            return error.TestExpectedEqual;
        }
        try testing.expect(r.max_len <= 1276);
    }
}

test "silence takes two bytes and a TOC byte" {
    const r = try roundTrip(2, .{ .bitrate = 64000 }, .silence, 1000);
    try testing.expectEqual(@as(usize, 3), r.max_len);
    try testing.expectEqual(@as(usize, 0), r.range_mismatches);
}

fn roundTripSamples(channels: u32, options: opus.EncodeOptions, input: []const f32, out: []f32) !void {
    var enc = try opus.PacketEncoder.init(channels, options);
    var dec = try opus.PacketDecoder.init(channels, .{});
    const n = enc.frameSamples() * channels;
    var pkt: [1276]u8 = undefined;
    var f: usize = 0;
    while ((f + 1) * n <= input.len) : (f += 1) {
        const len = try enc.encode(input[f * n ..][0..n], &pkt);
        _ = try dec.decode(pkt[0..len], false, out[f * n ..][0..n]);
        try testing.expectEqual(dec.finalRange(), enc.finalRange());
    }
}

test "extreme input gives finite output" {
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const values = [_]f32{ nan, inf, -inf, 1e30, -1e30, 3.0e4, 1.0, -1.0, 0.5, 2.0, 1e-30, -0.0 };
    var input: [960 * 2 * 8]f32 = undefined;
    var output: [960 * 2 * 8]f32 = undefined;
    for (values) |v| {
        for ([_]u32{ 1, 2 }) |channels| {
            for (sizes) |fm| {
                // A constant, which is a DC offset at 1.0.
                @memset(&input, v);
                try roundTripSamples(channels, .{ .bitrate = 96000, .frame_ms = fm }, &input, &output);
                for (output) |o| try testing.expect(std.math.isFinite(o) and o >= -1.0 and o < 1.0);
                // One bad sample in a sine.
                fill(.sine, &input, 1, 1);
                input[1000] = v;
                try roundTripSamples(channels, .{ .bitrate = 48000, .frame_ms = fm, .vbr = false }, input[0 .. 960 * 8], &output);
                for (output[0 .. 960 * 8]) |o| try testing.expect(std.math.isFinite(o) and o >= -1.0 and o < 1.0);
            }
        }
    }
}

test "a constant input is removed by the DC filter" {
    var input: [960 * 2 * 100]f32 = undefined;
    var output: [960 * 2 * 100]f32 = undefined;
    for ([_]f32{ 0.25, -0.5 }) |dc| {
        @memset(&input, dc);
        try roundTripSamples(2, .{ .bitrate = 128000 }, &input, &output);
        // The filter removes the constant with a time constant of 53 ms, and the codec adds no gain.
        try testing.expect(@abs(output[960 * 2 * 2]) < @abs(dc));
        try testing.expect(@abs(output[output.len - 1]) < 0.01);
    }
}

const Rng = test_util.Xorshift;

fn pick(rng: *Rng, comptime T: type, items: []const T) T {
    return items[rng.next() % items.len];
}

/// Fills one frame with random content: noise at a random level, a sine, a silent part, a click
/// or an out of range value.
fn randomFrame(rng: *Rng, frame: []f32) void {
    const kind = rng.next() % 8;
    const level: f32 = switch (rng.next() % 4) {
        0 => 1e-6,
        1 => 0.05,
        2 => 1.0,
        else => 40.0,
    };
    for (frame, 0..) |*v, i| {
        const u: f32 = @floatCast(@as(f64, @floatFromInt(rng.next() >> 8)) / 8388608.0 - 1.0);
        v.* = switch (kind) {
            0, 1 => level * u,
            2 => level * @as(f32, @floatCast(@sin(@as(f64, @floatFromInt(i)) * 0.07))),
            3 => 0,
            4 => if (i % 97 == 3) level else 0,
            5 => if (rng.next() % 50 == 0) pick(rng, f32, &.{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 1e30, -1e30 }) else level * u,
            6 => level,
            else => 0.3 * u + 0.2 * @as(f32, @floatCast(@sin(@as(f64, @floatFromInt(i)) * 0.3))),
        };
    }
}

test "random options and random input never fail the encoder or the decoder" {
    var rng: Rng = .{ .s = 0xE1C0DE5 };
    var input: [5760 * 2]f32 = undefined;
    var pcm: [5760 * 2]f32 = undefined;
    var pkt: [7700]u8 = undefined;
    for (0..60) |_| {
        const channels: u32 = 1 + rng.next() % 2;
        const options: opus.EncodeOptions = .{
            .bitrate = pick(&rng, u32, &.{ 0, 500, 2400, 6000, 16000, 24000, 48000, 64000, 128000, 256000, 510000, 800000, 4000000000 }),
            .application = pick(&rng, opus.Application, &.{ .audio, .voip, .low_delay }),
            .vbr = rng.next() % 2 == 0,
            .frame_ms = pick(&rng, f32, &all_sizes),
            .packet_loss = pick(&rng, u8, &.{ 0, 0, 5, 20, 100 }),
        };
        var enc = try opus.PacketEncoder.init(channels, options);
        var dec = try opus.PacketDecoder.init(channels, .{});
        const n = enc.frameSamples() * channels;
        for (0..40) |_| {
            if (rng.next() % 8 == 0) enc.setBitrate(pick(&rng, u32, &.{ 0, 500, 6000, 24000, 64000, 256000, 4000000000 }));
            if (rng.next() % 8 == 0) try enc.setComplexity(@intCast(rng.next() % 11));
            if (rng.next() % 8 == 0) enc.forced_mode = pick(&rng, ?opus.encode.Mode, &.{ null, .silk_only, .hybrid, .celt_only });
            randomFrame(&rng, input[0..n]);
            const size = 1 + rng.next() % pkt.len;
            const len = try enc.encode(input[0..n], pkt[0..size]);
            try testing.expect(len >= 1 and len <= size);
            const got = try dec.decode(pkt[0..len], false, pcm[0..n]);
            try testing.expectEqual(enc.frameSamples(), got);
            for (pcm[0..n]) |o| try testing.expect(std.math.isFinite(o) and o >= -1.0 and o < 1.0);
            if (enc.finalRange() != 0) try testing.expectEqual(enc.finalRange(), dec.finalRange());
        }
    }
}

test "the CELT encoder with random settings gives frames that the decoder reads" {
    const celt = opus.celt;
    var rng: Rng = .{ .s = 0xC0DEC };
    var input: [960 * 2]f32 = undefined;
    var pcm: [960 * 2]f32 = undefined;
    var frame: [1275]u8 = undefined;
    for (0..60) |_| {
        const channels: u32 = 1 + rng.next() % 2;
        var enc = celt.encode.Encoder.init(channels);
        var dec = celt.decode.Decoder.init(channels, false);
        enc.end = pick(&rng, u32, &.{ 13, 17, 19, 21 });
        dec.end = enc.end;
        enc.settings.vbr = rng.next() % 2 == 0;
        enc.settings.constrained_vbr = rng.next() % 4 != 0;
        enc.settings.bitrate = if (enc.settings.vbr or rng.next() % 2 == 0) pick(&rng, u32, &.{ 6000, 24000, 64000, 128000, 400000 }) else null;
        enc.settings.complexity = @intCast(rng.next() % 11);
        enc.settings.force_intra = rng.next() % 8 == 0;
        enc.settings.disable_pf = rng.next() % 4 == 0;
        enc.settings.disable_inv = rng.next() % 4 == 0;
        for (0..30) |_| {
            if (rng.next() % 6 == 0) {
                enc.stream_channels = 1 + rng.next() % channels;
            }
            const lm: u32 = rng.next() % 4;
            const n = (@as(usize, 120) << @intCast(lm)) * channels;
            randomFrame(&rng, input[0..n]);
            const size: usize = 2 + rng.next() % 1274;
            const used = try enc.encode(input[0..n], lm, frame[0..size]);
            try testing.expect(used >= 2 and used <= size);
            dec.disable_inv = enc.settings.disable_inv;
            try dec.decode(frame[0..used], null, enc.stream_channels, lm, pcm[0..n], false);
            try testing.expectEqual(enc.finalRange(), dec.rng);
        }
    }
}

const Voice = enum { speech, music };

/// A voiced speech model: a pulse train with a drifting pitch through three resonators, with a
/// syllable envelope and a pause.
fn fillVoice(kind: Voice, pcm: []f32, channels: usize) void {
    var rng: test_util.Xorshift = .{ .s = 777 };
    const frames = pcm.len / channels;
    const formants = [3]f64{ 700, 1220, 2600 };
    var y1: [3]f64 = @splat(0);
    var y2: [3]f64 = @splat(0);
    var phase: f64 = 0;
    for (0..frames) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / rate;
        var v: f64 = 0;
        switch (kind) {
            .speech => {
                const f0 = 115.0 + 25.0 * @sin(2.0 * std.math.pi * 0.7 * t);
                phase += f0 / rate;
                var x: f64 = 0;
                if (phase >= 1.0) {
                    phase -= 1.0;
                    x = 40.0;
                }
                x += 0.02 * uniform(&rng);
                for (formants, 0..) |f, k| {
                    const r = 0.97;
                    const a1 = 2.0 * r * @cos(2.0 * std.math.pi * f / rate);
                    const y = x + a1 * y1[k] - r * r * y2[k];
                    y2[k] = y1[k];
                    y1[k] = y;
                    v += y * @as(f64, if (k == 0) 1.0 else 0.5);
                }
                const env = @abs(@sin(2.0 * std.math.pi * 2.5 * t));
                const gate: f64 = if (@mod(t, 1.2) > 0.9) 0.0 else 1.0;
                v *= env * gate * 0.004;
            },
            .music => {
                const note = @as(usize, @intFromFloat(t / 0.4)) % 4;
                const bases = [4]f64{ 220.0, 277.18, 329.63, 246.94 };
                const base = bases[note];
                const age = @mod(t, 0.4);
                const env = @exp(-3.0 * age);
                for (1..7) |h| {
                    const hf: f64 = @floatFromInt(h);
                    v += @sin(2.0 * std.math.pi * base * hf * t) / hf;
                }
                v += 0.5 * @sin(2.0 * std.math.pi * base * 1.5 * t);
                v *= 0.12 * env;
            },
        }
        for (0..channels) |c| {
            const cf: f32 = if (c == 0) 1.0 else 0.7;
            pcm[i * channels + c] = @floatCast(std.math.clamp(v, -0.95, 0.95) * cf);
        }
    }
}

const Mode = enum(u2) { silk, hybrid, celt };

fn tocMode(toc: u8) Mode {
    const config = toc >> 3;
    return if (config < 12) .silk else if (config < 16) .hybrid else .celt;
}

const Coded = struct {
    snr_db: f64,
    lookahead: usize,
    range_mismatches: usize,
    modes: [3]usize,
    first: [200]Mode,
};

/// Codes `input` frame by frame and decodes it again.
fn codeSignal(channels: u32, options: opus.EncodeOptions, input: []const f32, output: []f32) !Coded {
    var enc = try opus.PacketEncoder.init(channels, options);
    var dec = try opus.PacketDecoder.init(channels, .{});
    const n = enc.frameSamples();
    const ch: usize = channels;
    const frames = input.len / ch / n;
    var res: Coded = .{ .snr_db = 0, .lookahead = enc.lookahead(), .range_mismatches = 0, .modes = @splat(0), .first = @splat(.silk) };
    var pkt: [7660]u8 = undefined;
    for (0..frames) |f| {
        const len = try enc.encode(input[f * n * ch ..][0 .. n * ch], &pkt);
        const mode = tocMode(pkt[0]);
        res.modes[@backingInt(mode)] += 1;
        if (f < res.first.len) res.first[f] = mode;
        const got = try dec.decode(pkt[0..len], false, output[f * n * ch ..][0 .. n * ch]);
        try testing.expectEqual(n, got);
        if (dec.finalRange() != enc.finalRange()) res.range_mismatches += 1;
    }
    res.snr_db = snrAt(input, output, ch, enc.lookahead(), 8 * n);
    return res;
}

const App = opus.Application;
const apps = [3]App{ .audio, .voip, .low_delay };
const voice_rates = [7]u32{ 8000, 12000, 16000, 24000, 32000, 48000, 64000 };

const dft_n = 512;

/// The SNR of the short time spectrum magnitudes, with the bins below 280 Hz left out. It
/// ignores phase shifts, so it suits the voip application, whose high pass filter moves the phase of
/// the low harmonics.
fn spectralSnr(input: []const f32, output: []const f32, delay: usize, skip: usize) f64 {
    var sig: f64 = 0;
    var err: f64 = 0;
    var start: usize = skip;
    while (start + delay + dft_n <= input.len) : (start += dft_n) {
        for (3..dft_n / 2) |k| {
            var xr: f64 = 0;
            var xi: f64 = 0;
            var yr: f64 = 0;
            var yi: f64 = 0;
            for (0..dft_n) |i| {
                const w = 0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / dft_n);
                const ang = 2.0 * std.math.pi * @as(f64, @floatFromInt((k * i) % dft_n)) / dft_n;
                const c = @cos(ang);
                const s = @sin(ang);
                const a = w * input[start + i];
                const b = w * output[start + delay + i];
                xr += a * c;
                xi -= a * s;
                yr += b * c;
                yi -= b * s;
            }
            const mx = @sqrt(xr * xr + xi * xi);
            const my = @sqrt(yr * yr + yi * yi);
            sig += mx * mx;
            err += (mx - my) * (mx - my);
        }
    }
    return 10.0 * std.math.log10((sig + 1e-20) / (err + 1e-20));
}

fn voiceSnr(app: App, input: []const f32, output: []const f32, delay: usize, skip: usize) f64 {
    if (app == .voip) return spectralSnr(input, output, delay, skip);
    return snrAt(input, output, 1, delay, skip);
}

/// The lowest SNR in dB for the signal (outer), the application (middle) and the bitrates of
/// `voice_rates`. Each value is the lowest SNR that the run of the 1.5 s signal gave, less 3 dB,
/// rounded down. The voip rows use `spectralSnr`, the other rows the waveform SNR. A floor of 0 or
/// less is not checked.
const voice_floors = [2][3][7]i32{
    .{ .{ 5, 5, 6, 9, 10, 11, 11 }, .{ 13, 16, 16, 19, 21, 23, 22 }, .{ 5, 7, 9, 10, 10, 11, 11 } },
    .{ .{ 7, 5, 7, 17, 19, 22, 24 }, .{ 11, 8, 10, 14, 17, 21, 25 }, .{ 4, 9, 10, 17, 19, 22, 24 } },
};

fn codeVoice(app: App, br: u32, input: []const f32, output: []f32) !struct { coded: Coded, snr: f64 } {
    const r = try codeSignal(1, .{ .bitrate = br, .application = app }, input, output);
    return .{ .coded = r, .snr = voiceSnr(app, input, output, r.lookahead, 8 * 960) };
}

test "speech and music round trips stay above the SNR floors for every application" {
    var input: [rate * 3 / 2]f32 = undefined;
    var output: [rate * 3 / 2]f32 = undefined;
    for ([_]Voice{ .speech, .music }) |kind| {
        fillVoice(kind, &input, 1);
        for (apps) |app| {
            for (voice_rates, 0..) |br, ri| {
                const r = try codeVoice(app, br, &input, &output);
                try testing.expectEqual(@as(usize, 0), r.coded.range_mismatches);
                const floor: f64 = @floatFromInt(voice_floors[@backingInt(kind)][@backingInt(app)][ri]);
                if (floor > 0 and r.snr < floor) {
                    std.debug.print("{s} {s} {d}: {d:.1} dB below {d}\n", .{ @tagName(kind), @tagName(app), br, r.snr, floor });
                    return error.TestExpectedEqual;
                }
            }
        }
    }
}

/// The mode of every frame, for the applications (outer) and the bitrates of `voice_rates`. The
/// first rows are mono speech and music at 20 ms.
const expected_modes = [3][7]Mode{
    .{ .silk, .hybrid, .hybrid, .celt, .celt, .celt, .celt },
    .{ .silk, .silk, .hybrid, .hybrid, .hybrid, .hybrid, .celt },
    .{ .celt, .celt, .celt, .celt, .celt, .celt, .celt },
};

test "the mode follows the application and the bitrate" {
    var input: [rate]f32 = undefined;
    var output: [rate]f32 = undefined;
    for ([_]Voice{ .speech, .music }) |kind| {
        fillVoice(kind, &input, 1);
        for (apps, 0..) |app, ai| {
            for (voice_rates, 0..) |br, ri| {
                const r = try codeSignal(1, .{ .bitrate = br, .application = app }, &input, &output);
                const want = expected_modes[ai][ri];
                const frames = r.modes[0] + r.modes[1] + r.modes[2];
                if (r.modes[@backingInt(want)] != frames) {
                    std.debug.print("{s} {s} {d}: modes {any}, want all {s}\n", .{ @tagName(kind), @tagName(app), br, r.modes, @tagName(want) });
                    return error.TestExpectedEqual;
                }
            }
        }
    }
}

test "a change of the mode decodes without a click" {
    var enc = try opus.PacketEncoder.init(1, .{ .application = .audio });
    var dec = try opus.PacketDecoder.init(1, .{});
    const n = enc.frameSamples();
    const frames = 150;
    var input: [frames * 960]f32 = undefined;
    var output: [frames * 960]f32 = undefined;
    fillVoice(.music, &input, 1);
    var pkt: [1500]u8 = undefined;
    var seen: [3]bool = @splat(false);
    var changes: usize = 0;
    var last: Mode = .silk;
    for (0..frames) |f| {
        enc.setBitrate(if ((f / 30) % 2 == 0) 8000 else 64000);
        const len = try enc.encode(input[f * n ..][0..n], &pkt);
        const mode = tocMode(pkt[0]);
        seen[@backingInt(mode)] = true;
        if (f > 0 and mode != last) changes += 1;
        last = mode;
        _ = try dec.decode(pkt[0..len], false, output[f * n ..][0..n]);
        try testing.expectEqual(enc.finalRange(), dec.finalRange());
    }
    try testing.expect(seen[0] and seen[2]);
    try testing.expect(changes >= 4);
    var max_in: f32 = 0;
    var max_out: f32 = 0;
    for (input) |v| max_in = @max(max_in, @abs(v));
    for (output) |v| max_out = @max(max_out, @abs(v));
    var max_step_in: f32 = 0;
    var max_step_out: f32 = 0;
    for (1..input.len) |i| {
        max_step_in = @max(max_step_in, @abs(input[i] - input[i - 1]));
        max_step_out = @max(max_step_out, @abs(output[i] - output[i - 1]));
    }
    try testing.expect(max_out < 1.5 * max_in);
    try testing.expect(max_step_out < 1.25 * max_step_in);
}

const lbrr_frames = 80;
const lbrr_n = 960;

fn lbrrDecode(pkts: *const [lbrr_frames][1500]u8, lens: *const [lbrr_frames]usize, lost: ?usize, use_fec: bool, out: []f32) !void {
    var dec = try opus.PacketDecoder.init(1, .{});
    for (0..lbrr_frames - 1) |f| {
        const dst = out[f * lbrr_n ..][0..lbrr_n];
        if (f == lost) {
            if (use_fec) {
                _ = try dec.decode(pkts[f + 1][0..lens[f + 1]], true, dst);
            } else {
                _ = try dec.decode(null, false, dst);
            }
        } else {
            _ = try dec.decode(pkts[f][0..lens[f]], false, dst);
        }
    }
}

/// The LBRR flag of a mono packet of one SILK frame of 20 ms: the first range coder symbols
/// after the TOC byte are the VAD flag and the LBRR flag.
fn hasLbrr(pkt: []const u8) bool {
    var dec = opus.range.Decoder.init(pkt[1..]);
    _ = dec.bitLogp(1);
    return dec.bitLogp(1);
}

fn errorEnergy(ref: []const f32, got: []const f32) f64 {
    var e: f64 = 0;
    for (ref, got) |a, b| e += (@as(f64, a) - b) * (a - b);
    return e;
}

test "redundancy in a packet lets a decoder fill a lost frame" {
    var input: [lbrr_frames * lbrr_n]f32 = undefined;
    fillVoice(.speech, &input, 1);
    var totals: [2]usize = undefined;
    var lbrr_packets: [2]usize = undefined;
    for ([_]u8{ 0, 20 }, 0..) |loss, k| {
        var enc = try opus.PacketEncoder.init(1, .{ .bitrate = 24000, .application = .voip, .packet_loss = loss });
        var pkts: [lbrr_frames][1500]u8 = undefined;
        var lens: [lbrr_frames]usize = undefined;
        totals[k] = 0;
        lbrr_packets[k] = 0;
        for (0..lbrr_frames) |f| {
            lens[f] = try enc.encode(input[f * lbrr_n ..][0..lbrr_n], &pkts[f]);
            totals[k] += lens[f];
            if (hasLbrr(pkts[f][0..lens[f]])) lbrr_packets[k] += 1;
        }
        if (loss == 0) continue;
        var reference: [lbrr_frames * lbrr_n]f32 = undefined;
        try lbrrDecode(&pkts, &lens, null, false, &reference);
        var fec_err: f64 = 0;
        var plc_err: f64 = 0;
        var tried: usize = 0;
        for (8..lbrr_frames - 2) |lost| {
            if (!hasLbrr(pkts[lost + 1][0..lens[lost + 1]])) continue;
            var with_fec: [lbrr_frames * lbrr_n]f32 = undefined;
            var with_plc: [lbrr_frames * lbrr_n]f32 = undefined;
            try lbrrDecode(&pkts, &lens, lost, true, &with_fec);
            try lbrrDecode(&pkts, &lens, lost, false, &with_plc);
            const lo = lost * lbrr_n;
            fec_err += errorEnergy(reference[lo..][0..lbrr_n], with_fec[lo..][0..lbrr_n]);
            plc_err += errorEnergy(reference[lo..][0..lbrr_n], with_plc[lo..][0..lbrr_n]);
            tried += 1;
        }
        try testing.expect(tried >= 10);
        try testing.expect(fec_err < 0.5 * plc_err);
    }
    try testing.expectEqual(@as(usize, 0), lbrr_packets[0]);
    try testing.expect(lbrr_packets[1] >= 10);
    try testing.expect(totals[1] > totals[0]);
}

test "long frames of several codec frames decode with the final range of the encoder" {
    var input: [rate * 3]f32 = undefined;
    var output: [rate * 3]f32 = undefined;
    const long_floors = [2][3]f64{ .{ 5, 10, 12 }, .{ 4, 16, 24 } };
    for ([_]Voice{ .speech, .music }) |kind| {
        fillVoice(kind, &input, 1);
        for ([_]f32{ 40, 60, 80, 100, 120 }) |fm| {
            for ([_]u32{ 12000, 24000, 64000 }, 0..) |br, bi| {
                const r = try codeSignal(1, .{ .bitrate = br, .application = .audio, .frame_ms = fm }, &input, &output);
                try testing.expectEqual(@as(usize, 0), r.range_mismatches);
                try testing.expect(r.snr_db > long_floors[@backingInt(kind)][bi]);
            }
        }
    }
}

test "constant bitrate packets of the lowest rate keep the duration of 40 to 120 ms" {
    for ([_]f32{ 40, 60, 80, 100, 120 }) |fm| {
        for ([_]u32{ 500, 2400, 6000 }) |br| {
            var enc = try opus.PacketEncoder.init(1, .{ .bitrate = br, .vbr = false, .frame_ms = fm });
            var dec = try opus.PacketDecoder.init(1, .{});
            var pcm: [5760]f32 = @splat(0.1);
            var out: [7700]u8 = undefined;
            var back: [5760]f32 = undefined;
            const n = enc.frameSamples();
            const len = try enc.encode(pcm[0..n], &out);
            try testing.expectEqual(n, try dec.decode(out[0..len], false, &back));
        }
    }
}

test "a stereo packet after a drop to mono with a new internal rate does not overflow" {
    var enc = try opus.PacketEncoder.init(2, .{ .bitrate = 64000, .vbr = false, .application = .audio, .packet_loss = 10, .complexity = 1 });
    var input: [960 * 2]f32 = undefined;
    fillVoice(.speech, &input, 2);
    var out: [4000]u8 = undefined;
    for ([_]usize{ 3028, 32, 13 }) |size| {
        _ = try enc.encode(&input, out[0..size]);
    }
}

const Golden = struct {
    channels: u32,
    bitrate: u32,
    vbr: bool,
    app: App,
    loss: u8,
    complexity: u4,
    kind: Voice,
    mode: Mode,
    hash: u64,
};

/// Packet streams that opus_demo of libopus 1.6.1 (float build, no FMA contraction, `-e audio` or
/// `-e voip`, 20 ms frames, `-complexity` as listed) gave for the signals of `goldenSignal`. The
/// hash is FNV-1a over the opus_demo .bit file: the length, the final range and the bytes of each
/// packet.
const golden = [_]Golden{
    .{ .channels = 1, .bitrate = 12000, .vbr = true, .app = .voip, .loss = 0, .complexity = 0, .kind = .speech, .mode = .silk, .hash = 0xf97fb0bd75c6b29d },
    .{ .channels = 1, .bitrate = 8000, .vbr = false, .app = .voip, .loss = 0, .complexity = 1, .kind = .speech, .mode = .silk, .hash = 0x7d9a3dbed7a8b9b6 },
    .{ .channels = 2, .bitrate = 12000, .vbr = true, .app = .voip, .loss = 0, .complexity = 2, .kind = .speech, .mode = .silk, .hash = 0xb3a75c9fc3c40b0a },
    .{ .channels = 1, .bitrate = 16000, .vbr = true, .app = .audio, .loss = 0, .complexity = 3, .kind = .speech, .mode = .hybrid, .hash = 0x5ad796c29cec93c4 },
    .{ .channels = 1, .bitrate = 24000, .vbr = false, .app = .voip, .loss = 20, .complexity = 4, .kind = .speech, .mode = .silk, .hash = 0x90ea45a598262277 },
    .{ .channels = 1, .bitrate = 64000, .vbr = false, .app = .audio, .loss = 0, .complexity = 5, .kind = .music, .mode = .celt, .hash = 0xce10c5b0a1011b64 },
    .{ .channels = 2, .bitrate = 32000, .vbr = true, .app = .voip, .loss = 10, .complexity = 6, .kind = .speech, .mode = .hybrid, .hash = 0x23888db7b251c1c6 },
};

/// Mono or stereo speech or music, rounded to 16 bit like the PCM file of opus_demo.
fn goldenSignal(kind: Voice, channels: u32, pcm: []f32) void {
    fillVoice(kind, pcm, channels);
    for (pcm) |*v| v.* = @round(v.* * 32768.0) / 32768.0;
}

fn goldenStream(g: Golden) !u64 {
    const enc = try testing.allocator.create(opus.PacketEncoder);
    defer testing.allocator.destroy(enc);
    try enc.initInto(g.channels, .{ .bitrate = g.bitrate, .vbr = g.vbr, .application = g.app, .packet_loss = g.loss, .complexity = g.complexity });
    enc.setLsbDepth(16);
    enc.toc_overhead = false;
    const n = enc.frameSamples();
    const frames = 60;
    const ch: usize = g.channels;
    var pcm: [frames * 960 * 2]f32 = undefined;
    goldenSignal(g.kind, g.channels, pcm[0 .. frames * n * ch]);
    var h: u64 = test_util.fnv64_basis;
    var pkt: [1500]u8 = undefined;
    for (0..frames) |f| {
        const len = try enc.encode(pcm[f * n * ch ..][0 .. n * ch], &pkt);
        var hdr: [8]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], @intCast(len), .big);
        std.mem.writeInt(u32, hdr[4..8], enc.finalRange(), .big);
        h = test_util.fnv64(h, &hdr);
        h = test_util.fnv64(h, pkt[0..len]);
        if (f == frames - 1) try testing.expectEqual(g.mode, tocMode(pkt[0]));
    }
    return h;
}

test "packet streams equal the ones of libopus" {
    for (golden) |g| try testing.expectEqual(g.hash, try goldenStream(g));
}

/// Encodes 10 frames of a mixed signal with a setup applied to the encoder and returns the TOC
/// byte of the last packet and the decoded samples.
fn setupRun(channels: u32, options: opus.EncodeOptions, comptime setup: fn (*opus.PacketEncoder) void, toc: *u8, out: []f32) !void {
    const enc = try testing.allocator.create(opus.PacketEncoder);
    defer testing.allocator.destroy(enc);
    try enc.initInto(channels, options);
    setup(enc);
    const dec = try testing.allocator.create(opus.PacketDecoder);
    defer testing.allocator.destroy(dec);
    dec.* = try .init(channels, .{});
    const n = enc.frameSamples();
    const ch: usize = channels;
    var pcm: [10 * 960 * 2]f32 = undefined;
    fill(.mixed, pcm[0 .. 10 * n * ch], ch, 5);
    var pkt: [1500]u8 = undefined;
    for (0..10) |f| {
        const len = try enc.encode(pcm[f * n * ch ..][0 .. n * ch], &pkt);
        toc.* = pkt[0];
        _ = try dec.decode(pkt[0..len], false, out[f * n * ch ..][0 .. n * ch]);
        try testing.expectEqual(enc.finalRange(), dec.finalRange());
    }
}

fn forceNarrow(enc: *opus.PacketEncoder) void {
    enc.user_bandwidth = .narrow;
}

fn inputSuperWide(enc: *opus.PacketEncoder) void {
    enc.input_bandwidth = .super_wide;
}

fn forceCelt(enc: *opus.PacketEncoder) void {
    enc.forced_mode = .celt_only;
}

fn lowFrequency(enc: *opus.PacketEncoder) void {
    enc.setLfe(true);
}

test "the bandwidth and mode limits of the encoder show in the TOC byte" {
    var toc: u8 = 0;
    var out: [10 * 960 * 2]f32 = undefined;
    const rich: opus.EncodeOptions = .{ .bitrate = 128000 };
    try setupRun(2, rich, forceNarrow, &toc, &out);
    try testing.expectEqual(opus.packet.Bandwidth.narrow, (opus.packet.Toc{ .byte = toc }).bandwidth());
    try setupRun(2, rich, inputSuperWide, &toc, &out);
    try testing.expectEqual(opus.packet.Bandwidth.super_wide, (opus.packet.Toc{ .byte = toc }).bandwidth());
    // A speech rate makes SILK, unless the mode is forced.
    const lean: opus.EncodeOptions = .{ .bitrate = 16000, .application = .voip };
    try setupRun(1, lean, forceNarrow, &toc, &out);
    try testing.expect((opus.packet.Toc{ .byte = toc }).mode() != .celt);
    try setupRun(1, lean, forceCelt, &toc, &out);
    try testing.expectEqual(opus.packet.Mode.celt, (opus.packet.Toc{ .byte = toc }).mode());
}

test "a low frequency stream is CELT and narrow band" {
    var toc: u8 = 0;
    var out: [10 * 960]f32 = undefined;
    try setupRun(1, .{ .bitrate = 20000, .application = .voip }, lowFrequency, &toc, &out);
    const t: opus.packet.Toc = .{ .byte = toc };
    try testing.expectEqual(opus.packet.Mode.celt, t.mode());
    try testing.expectEqual(opus.packet.Bandwidth.narrow, t.bandwidth());
    for (out) |v| try testing.expect(std.math.isFinite(v));
}

/// A voiced signal with a drifting pitch, formant like weights, bursts and noise at the rate `fs`,
/// rounded to 16 bit like the PCM file of opus_demo.
fn nativeSignal(pcm: []f32, channels: usize, fs: u32) void {
    var seed: u32 = 5;
    const frames = pcm.len / channels;
    const rate_hz: f64 = @floatFromInt(fs);
    var phase: [2]f64 = @splat(0);
    for (0..frames) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / rate_hz;
        for (0..channels) |c| {
            const cf: f64 = @floatFromInt(c);
            const f0 = 110.0 + 25.0 * @sin(2.0 * std.math.pi * 0.7 * t + cf) + 12.0 * cf;
            phase[c] += f0 / rate_hz;
            var v: f64 = 0;
            var h: usize = 1;
            while (h < 30 and @as(f64, @floatFromInt(h)) * f0 < rate_hz * 0.45) : (h += 1) {
                const hf: f64 = @floatFromInt(h);
                const fh = hf * f0;
                const w = 1.0 / hf + 1.5 * @exp(-std.math.pow(f64, (fh - 700.0) / 250.0, 2)) +
                    @exp(-std.math.pow(f64, (fh - 1800.0) / 400.0, 2)) + 0.4 * @exp(-std.math.pow(f64, (fh - 3200.0) / 500.0, 2));
                v += w * @sin(2.0 * std.math.pi * hf * phase[c]);
            }
            const env = @abs(@sin(2.0 * std.math.pi * 1.9 * t + 0.5 * cf));
            const gate: f64 = if (@mod(t, 1.7) > 1.45) 0.0 else 1.0;
            v *= 0.06 * env * gate;
            if ((i / @as(usize, @intFromFloat(rate_hz * 0.3))) % 5 == 3) v += 0.15 * @sin(2.0 * std.math.pi * (900.0 + 200.0 * cf) * t);
            seed = seed *% 1664525 +% 1013904223;
            v += 0.02 * (@as(f64, @floatFromInt(seed >> 8)) / 8388608.0 - 1.0);
            v = std.math.clamp(v, -0.99, 0.99);
            pcm[i * channels + c] = @as(f32, @floatCast(@round(v * 32767.0))) / 32768.0;
        }
    }
}

const NativeGolden = struct {
    fs: u32,
    channels: u32,
    bitrate: u32,
    vbr: bool,
    app: App,
    frame_ms: f32,
    complexity: u4,
    loss: u8 = 0,
    sweep: i32 = 0,
    sweep_max: i32 = 0,
    hash: u64,
};

const native_golden = [_]NativeGolden{
    .{ .fs = 24000, .channels = 1, .bitrate = 64000, .vbr = true, .app = .audio, .frame_ms = 20, .complexity = 4, .hash = 0x17edc5dde80a80d8 },
    .{ .fs = 16000, .channels = 1, .bitrate = 16000, .vbr = true, .app = .voip, .frame_ms = 20, .complexity = 4, .hash = 0xa105ceacfd7cc2e5 },
    .{ .fs = 12000, .channels = 2, .bitrate = 40000, .vbr = true, .app = .voip, .frame_ms = 20, .complexity = 3, .hash = 0xf9db733516b60905 },
    .{ .fs = 8000, .channels = 1, .bitrate = 12000, .vbr = false, .app = .voip, .frame_ms = 20, .complexity = 6, .hash = 0xd31f1a188776311f },
    .{ .fs = 16000, .channels = 2, .bitrate = 96000, .vbr = true, .app = .audio, .frame_ms = 10, .complexity = 5, .hash = 0x4cd4a0fe14c4a958 },
    .{ .fs = 24000, .channels = 1, .bitrate = 6000, .vbr = true, .app = .voip, .frame_ms = 20, .complexity = 4, .sweep = 600, .sweep_max = 60000, .hash = 0x25f2c2a15b296a34 },
    .{ .fs = 8000, .channels = 2, .bitrate = 10000, .vbr = true, .app = .audio, .frame_ms = 20, .complexity = 5, .sweep = 800, .sweep_max = 90000, .hash = 0x2d6ef5e4b56ed6f4 },
    .{ .fs = 12000, .channels = 1, .bitrate = 48000, .vbr = false, .app = .low_delay, .frame_ms = 5, .complexity = 6, .hash = 0x700a4c6a077f5a18 },
    .{ .fs = 24000, .channels = 1, .bitrate = 20000, .vbr = true, .app = .voip, .frame_ms = 20, .complexity = 4, .loss = 20, .hash = 0xddb76cb40a58b742 },
    .{ .fs = 16000, .channels = 1, .bitrate = 8000, .vbr = true, .app = .voip, .frame_ms = 60, .complexity = 4, .sweep = 400, .sweep_max = 40000, .hash = 0xfe9cb3a7f2213444 },
};

fn nativeStream(g: NativeGolden) !u64 {
    const enc = try testing.allocator.create(opus.PacketEncoder);
    defer testing.allocator.destroy(enc);
    try enc.initIntoRate(g.fs, g.channels, .{ .bitrate = g.bitrate, .vbr = g.vbr, .frame_ms = g.frame_ms, .application = g.app, .packet_loss = g.loss, .complexity = g.complexity });
    enc.setLsbDepth(16);
    enc.toc_overhead = false;
    const n = enc.frameSamples();
    const ch: usize = g.channels;
    const frames: usize = @intCast(@divTrunc(@as(u64, g.fs) * 4, n));
    const pcm = try testing.allocator.alloc(f32, frames * n * ch);
    defer testing.allocator.free(pcm);
    nativeSignal(pcm, ch, g.fs);
    var h: u64 = test_util.fnv64_basis;
    var pkt: [1500]u8 = undefined;
    var rate_now: i32 = @intCast(g.bitrate);
    var sweep = g.sweep;
    for (0..frames) |f| {
        const len = try enc.encode(pcm[f * n * ch ..][0 .. n * ch], &pkt);
        var hdr: [8]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], @intCast(len), .big);
        std.mem.writeInt(u32, hdr[4..8], enc.finalRange(), .big);
        h = test_util.fnv64(h, &hdr);
        h = test_util.fnv64(h, pkt[0..len]);
        if (sweep != 0) {
            rate_now += sweep;
            if (g.sweep_max != 0) {
                if (rate_now > g.sweep_max) sweep = -sweep else if (rate_now < @as(i32, @intCast(g.bitrate))) sweep = -sweep;
            }
            if (rate_now < 1000) rate_now = 1000;
            enc.setBitrate(@intCast(rate_now));
        }
    }
    return h;
}

test "packet streams of the input rates below 48 kHz equal the ones of libopus" {
    for (native_golden) |g| try testing.expectEqual(g.hash, try nativeStream(g));
}

test "an input rate that libopus does not take is refused" {
    for ([_]u32{ 0, 7999, 11025, 22050, 32000, 44100, 96000, 48001 }) |fs| {
        try testing.expectError(error.InvalidRate, opus.PacketEncoder.initRate(fs, 2, .{}));
    }
    try testing.expectError(error.InvalidChannels, opus.PacketEncoder.initRate(16000, 3, .{}));
    // 2.5 ms is 20 samples at 8 kHz, and a frame of 7 ms is no frame at any rate.
    const enc = try opus.PacketEncoder.initRate(8000, 1, .{ .frame_ms = 2.5 });
    try testing.expectEqual(@as(usize, 20), enc.frameSamples());
    try testing.expectEqual(@as(u32, 52), enc.lookahead());
    try testing.expectError(error.InvalidFrameSize, opus.PacketEncoder.initRate(8000, 1, .{ .frame_ms = 7 }));
    try testing.expectError(error.InvalidFrameSize, opus.PacketEncoder.initRate(24000, 1, .{ .frame_ms = 130 }));
    const wide = try opus.PacketEncoder.initRate(24000, 1, .{ .frame_ms = 120 });
    try testing.expectEqual(@as(usize, 2880), wide.frameSamples());
    try testing.expectEqual(@as(u32, 156), wide.lookahead());
}

test "a complexity above 10 is refused and the input bit depth is limited" {
    try testing.expectError(error.InvalidComplexity, opus.PacketEncoder.init(1, .{ .complexity = 11 }));
    var enc = try opus.PacketEncoder.init(1, .{ .complexity = 10 });
    try testing.expectError(error.InvalidComplexity, enc.setComplexity(15));
    try enc.setComplexity(0);
    enc.setLsbDepth(31);
    try testing.expectEqual(@as(u5, 24), enc.lsb_depth);
    enc.setLsbDepth(0);
    try testing.expectEqual(@as(u5, 8), enc.lsb_depth);
    var input: [960]f32 = @splat(0.1);
    var out: [1276]u8 = undefined;
    _ = try enc.encode(&input, &out);
}
