//! Test harness for the RFC 8251 Opus test vectors: the .bit reader and a port of
//! opus_compare from libopus 1.6.1. libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const options = @import("vector_options");
const opus = @import("codec").opus;

pub const Record = struct {
    /// The final range of the encoder. 0 for a lost packet.
    final_range: u32,
    packet: []const u8,
};

/// Reads the opus_demo framing: a big endian length, a big endian final range and the packet.
pub const BitIterator = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub const Error = error{ Truncated, BadLength };
    /// The most bytes of a packet that opus_demo accepts.
    pub const max_packet = 15000;

    pub fn next(self: *BitIterator) Error!?Record {
        if (self.pos == self.bytes.len) return null;
        const rest = self.bytes[self.pos..];
        if (rest.len < 8) return error.Truncated;
        const len = std.mem.readInt(u32, rest[0..4], .big);
        if (len > max_packet) return error.BadLength;
        if (rest.len - 8 < len) return error.Truncated;
        self.pos += 8 + len;
        return .{
            .final_range = std.mem.readInt(u32, rest[4..8], .big),
            .packet = rest[8..][0..len],
        };
    }
};

pub const CompareError = error{ SampleCountMismatch, TooShort, UnsupportedRate, OutOfMemory };

pub const Quality = struct {
    /// The internal weighted error.
    err: f64,
    /// 100 for equal signals, and below 0 when the comparison fails.
    quality: f64,

    pub fn passes(self: Quality) bool {
        return self.quality >= 0;
    }
};

const pi: f32 = 3.14159265;
const nbands = 21;
const nfreqs = 240;
const test_win_size = 480;
const test_win_step = 120;
const bands = [nbands + 1]usize{ 0, 2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48, 56, 68, 80, 96, 120, 156, 200 };

/// Reads 16 bit little endian PCM with `channels` channels. A cut last frame is dropped.
pub fn pcm16(allocator: std.mem.Allocator, bytes: []const u8, channels: usize) std.mem.Allocator.Error![]i16 {
    const n = bytes.len / (2 * channels) * channels;
    const out = try allocator.alloc(i16, n);
    for (out, 0..) |*s, i| s.* = std.mem.readInt(i16, bytes[2 * i ..][0..2], .little);
    return out;
}

fn cosf(x: f32) f32 {
    return @floatCast(@cos(@as(f64, x)));
}

fn sinf(x: f32) f32 {
    return @floatCast(@sin(@as(f64, x)));
}

const Complex = struct { re: f64, im: f64 };

/// Mixed radix transform of `n` points read from `input` with step `stride`. `table` holds
/// the `table.len` roots of unity, so the root for step `k` of an `n` point transform is
/// `table[k * (table.len / n) % table.len]`.
fn fft(table: []const Complex, n: usize, input: []const Complex, stride: usize, out: []Complex) void {
    if (n == 1) {
        out[0] = input[0];
        return;
    }
    const p: usize = if (n % 2 == 0) 2 else if (n % 3 == 0) 3 else 5;
    const m = n / p;
    for (0..p) |r| fft(table, m, input[r * stride ..], stride * p, out[r * m ..][0..m]);
    const step = table.len / n;
    var t: [5]Complex = undefined;
    for (0..m) |k| {
        for (0..p) |r| {
            const w = table[r * k * step % table.len];
            const v = out[r * m + k];
            t[r] = .{ .re = v.re * w.re - v.im * w.im, .im = v.re * w.im + v.im * w.re };
        }
        for (0..p) |q| {
            var sum = t[0];
            for (1..p) |r| {
                const w = table[r * q * m * step % table.len];
                sum.re += t[r].re * w.re - t[r].im * w.im;
                sum.im += t[r].re * w.im + t[r].im * w.re;
            }
            out[q * m + k] = sum;
        }
    }
}

fn bandEnergy(
    out: ?[]f32,
    ps: []f32,
    nb: usize,
    input: []const f32,
    nch: usize,
    nframes: usize,
    win: usize,
    step: usize,
    downsample: usize,
) void {
    var window: [test_win_size]f32 = undefined;
    var table: [test_win_size]Complex = undefined;
    var x: [test_win_size]Complex = undefined;
    var spectrum: [test_win_size]Complex = undefined;
    const ps_sz = win / 2;
    const k_window: f32 = 2 * pi / @as(f32, @floatFromInt(win - 1));
    for (0..win) |j| {
        const jf: f32 = @floatFromInt(j);
        window[j] = 0.5 - 0.5 * cosf(k_window * jf);
        const angle = 2 * std.math.pi * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(win));
        table[j] = .{ .re = @cos(angle), .im = -@sin(angle) };
    }
    const ds: f32 = @floatFromInt(downsample);
    for (0..nframes) |xi| {
        var xj: usize = 0;
        var p: [2][nbands]f32 = undefined;
        for (0..nch) |ci| {
            for (0..win) |xk| x[xk] = .{ .re = window[xk] * input[(xi * step + xk) * nch + ci], .im = 0 };
            fft(table[0..win], win, x[0..win], 1, spectrum[0..win]);
            xj = 0;
            for (0..nb) |bi| {
                p[ci][bi] = 0;
                while (xj < bands[bi + 1]) : (xj += 1) {
                    const re = @as(f32, @floatCast(spectrum[xj].re)) * ds;
                    const im = @as(f32, @floatCast(spectrum[xj].im)) * ds;
                    const v = re * re + im * im + 100000;
                    ps[(xi * ps_sz + xj) * nch + ci] = v;
                    p[ci][bi] += v;
                }
            }
        }
        if (out) |o| {
            for (0..nb) |bi| {
                const width: f32 = @floatFromInt(bands[bi + 1] - bands[bi]);
                for (0..nch) |ci| o[(xi * nb + bi) * nch + ci] = p[ci][bi] / width;
            }
        }
    }
}

/// opus_compare of libopus. `reference` is interleaved stereo at 48 kHz, `decoded` has one
/// or two channels at `rate`. A mono comparison mixes the reference down.
pub fn compare(
    allocator: std.mem.Allocator,
    reference: []const i16,
    decoded: []const i16,
    stereo: bool,
    rate: u32,
) CompareError!Quality {
    const nch: usize = if (stereo) 2 else 1;
    const downsample: usize, const ybands: usize = switch (rate) {
        48000 => .{ 1, 21 },
        24000 => .{ 2, 19 },
        16000 => .{ 3, 17 },
        12000 => .{ 4, 15 },
        8000 => .{ 6, 13 },
        else => return error.UnsupportedRate,
    };
    const yfreqs = nfreqs / downsample;
    const xlength = reference.len / 2;
    const ylength = decoded.len / nch;
    if (xlength != ylength * downsample) return error.SampleCountMismatch;
    if (xlength < test_win_size) return error.TooShort;
    const nframes = (xlength - test_win_size + test_win_step) / test_win_step;

    const x = try allocator.alloc(f32, xlength * nch);
    defer allocator.free(x);
    if (stereo) {
        for (x, reference[0..x.len]) |*d, s| d.* = @floatFromInt(s);
    } else {
        for (x, 0..) |*d, i| {
            const sum = @as(f32, @floatFromInt(reference[2 * i])) + @as(f32, @floatFromInt(reference[2 * i + 1]));
            d.* = @floatCast(0.5 * @as(f64, sum));
        }
    }
    const y = try allocator.alloc(f32, ylength * nch);
    defer allocator.free(y);
    for (y, decoded[0..y.len]) |*d, s| d.* = @floatFromInt(s);
    const xb = try allocator.alloc(f32, nframes * nbands * nch);
    defer allocator.free(xb);
    const big_x = try allocator.alloc(f32, nframes * nfreqs * nch);
    defer allocator.free(big_x);
    const big_y = try allocator.alloc(f32, nframes * yfreqs * nch);
    defer allocator.free(big_y);

    bandEnergy(xb, big_x, nbands, x, nch, nframes, test_win_size, test_win_step, 1);
    bandEnergy(null, big_y, ybands, y, nch, nframes, test_win_size / downsample, test_win_step / downsample, downsample);

    for (0..nframes) |xi| {
        for (1..nbands) |bi| {
            for (0..nch) |ci| xb[(xi * nbands + bi) * nch + ci] += 0.1 * xb[(xi * nbands + bi - 1) * nch + ci];
        }
        var bi: usize = nbands - 1;
        while (bi > 0) {
            bi -= 1;
            for (0..nch) |ci| xb[(xi * nbands + bi) * nch + ci] += 0.03 * xb[(xi * nbands + bi + 1) * nch + ci];
        }
        if (xi > 0) {
            for (0..nbands) |b| {
                for (0..nch) |ci| xb[(xi * nbands + b) * nch + ci] += 0.5 * xb[((xi - 1) * nbands + b) * nch + ci];
            }
        }
        if (nch == 2) {
            for (0..nbands) |b| {
                const l = xb[(xi * nbands + b) * 2];
                const r = xb[(xi * nbands + b) * 2 + 1];
                xb[(xi * nbands + b) * 2] += 0.01 * r;
                xb[(xi * nbands + b) * 2 + 1] += 0.01 * l;
            }
        }
        for (0..ybands) |b| {
            for (bands[b]..bands[b + 1]) |xj| {
                for (0..nch) |ci| {
                    const m = 0.1 * xb[(xi * nbands + b) * nch + ci];
                    big_x[(xi * nfreqs + xj) * nch + ci] += m;
                    big_y[(xi * yfreqs + xj) * nch + ci] += m;
                }
            }
        }
    }

    for (0..ybands) |b| {
        for (bands[b]..bands[b + 1]) |xj| {
            for (0..nch) |ci| {
                var xtmp = big_x[xj * nch + ci];
                var ytmp = big_y[xj * nch + ci];
                for (1..nframes) |xi| {
                    const xtmp2 = big_x[(xi * nfreqs + xj) * nch + ci];
                    const ytmp2 = big_y[(xi * yfreqs + xj) * nch + ci];
                    big_x[(xi * nfreqs + xj) * nch + ci] += xtmp;
                    big_y[(xi * yfreqs + xj) * nch + ci] += ytmp;
                    xtmp = xtmp2;
                    ytmp = ytmp2;
                }
            }
        }
    }

    const max_compare: usize = if (rate == 48000) bands[nbands] else if (rate == 12000) bands[ybands] else bands[ybands] - 3;
    var err: f64 = 0;
    for (0..nframes) |xi| {
        var ef: f64 = 0;
        for (0..ybands) |b| {
            var eb: f64 = 0;
            var xj = bands[b];
            while (xj < bands[b + 1] and xj < max_compare) : (xj += 1) {
                for (0..nch) |ci| {
                    const re: f32 = big_y[(xi * yfreqs + xj) * nch + ci] / big_x[(xi * nfreqs + xj) * nch + ci];
                    var im: f32 = @floatCast(@as(f64, re) - @log(@as(f64, re)) - 1);
                    if (xj >= 79 and xj <= 81) im *= 0.1;
                    if (xj == 80) im *= 0.1;
                    eb += im;
                }
            }
            eb /= @floatFromInt((bands[b + 1] - bands[b]) * nch);
            ef += eb * eb;
        }
        ef /= nbands;
        ef *= ef;
        err += ef * ef;
    }
    err = std.math.pow(f64, err / @as(f64, @floatFromInt(nframes)), 1.0 / 16.0);
    const q: f32 = @floatCast(100 * (1 - 0.5 * @log(1 + err) / @log(1.13)));
    return .{ .err = err, .quality = q };
}

const testing = std.testing;
const gpa = testing.allocator;
const Xorshift = opus.test_util.Xorshift;

/// Direct form of the transform, kept to check the fast form.
fn bandEnergyDirect(
    out: ?[]f32,
    ps: []f32,
    nb: usize,
    input: []const f32,
    nch: usize,
    nframes: usize,
    win: usize,
    step: usize,
    downsample: usize,
) void {
    var window: [test_win_size]f32 = undefined;
    var c: [test_win_size]f32 = undefined;
    var s: [test_win_size]f32 = undefined;
    var x: [2][test_win_size]f32 = undefined;
    const ps_sz = win / 2;
    const k_window: f32 = 2 * pi / @as(f32, @floatFromInt(win - 1));
    const k_dft: f32 = 2 * pi / @as(f32, @floatFromInt(win));
    for (0..win) |j| {
        const jf: f32 = @floatFromInt(j);
        window[j] = 0.5 - 0.5 * cosf(k_window * jf);
        c[j] = cosf(k_dft * jf);
        s[j] = sinf(k_dft * jf);
    }
    const ds: f32 = @floatFromInt(downsample);
    for (0..nframes) |xi| {
        for (0..nch) |ci| {
            for (0..win) |xk| x[ci][xk] = window[xk] * input[(xi * step + xk) * nch + ci];
        }
        var xj: usize = 0;
        for (0..nb) |bi| {
            var p = [2]f32{ 0, 0 };
            while (xj < bands[bi + 1]) : (xj += 1) {
                for (0..nch) |ci| {
                    var ti: usize = 0;
                    var re: f32 = 0;
                    var im: f32 = 0;
                    for (0..win) |xk| {
                        re += c[ti] * x[ci][xk];
                        im -= s[ti] * x[ci][xk];
                        ti += xj;
                        if (ti >= win) ti -= win;
                    }
                    re *= ds;
                    im *= ds;
                    const v = re * re + im * im + 100000;
                    ps[(xi * ps_sz + xj) * nch + ci] = v;
                    p[ci] += v;
                }
            }
            if (out) |o| {
                const width: f32 = @floatFromInt(bands[bi + 1] - bands[bi]);
                for (0..nch) |ci| o[(xi * nb + bi) * nch + ci] = p[ci] / width;
            }
        }
    }
}

const vector_count = 12;
// Packets and 48 kHz samples of each vector, from a scan of the TOC bytes.
const packet_counts = [vector_count]u32{ 2147, 1185, 998, 1265, 2037, 1876, 4186, 1247, 1337, 1912, 553, 1332 };
const sample_counts = [vector_count]u32{ 1415040, 1201440, 1015680, 1278240, 1304160, 1200960, 1085040, 1310160, 1323600, 1536480, 1440960, 1278720 };

fn readVector(name: []const u8) ![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ options.vectors_dir, name });
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1 << 28));
}

test "every vector bit file has the documented packet and sample counts" {
    for (0..vector_count) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "testvector{d:0>2}.bit", .{i + 1});
        const bytes = try readVector(name);
        defer gpa.free(bytes);
        var it: BitIterator = .{ .bytes = bytes };
        var packets: u32 = 0;
        var samples: u64 = 0;
        while (try it.next()) |record| {
            packets += 1;
            // The vectors hold no lost, DTX or one byte packets.
            try testing.expect(record.packet.len >= 2);
            const p = try opus.packet.parse(record.packet, false);
            samples += p.count * p.toc.frameSamples(48000);
        }
        try testing.expectEqual(packet_counts[i], packets);
        try testing.expectEqual(@as(u64, sample_counts[i]), samples);
        try testing.expectEqual(bytes.len, it.pos);
    }
}

test "bit records read big endian and stop at the end" {
    const bytes = [_]u8{ 0, 0, 0, 3, 0x12, 0x34, 0x56, 0x78, 9, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0 };
    var it: BitIterator = .{ .bytes = &bytes };
    const a = (try it.next()).?;
    try testing.expectEqualSlices(u8, &.{ 9, 8, 7 }, a.packet);
    try testing.expectEqual(@as(u32, 0x12345678), a.final_range);
    const lost = (try it.next()).?;
    try testing.expectEqual(@as(usize, 0), lost.packet.len);
    try testing.expectEqual(@as(u32, 0), lost.final_range);
    try testing.expectEqual(@as(?Record, null), try it.next());
}

test "bit records reject a cut header, a cut packet and a long packet" {
    var cut_header: BitIterator = .{ .bytes = &.{ 0, 0, 0, 1, 0, 0 } };
    try testing.expectError(error.Truncated, cut_header.next());
    var cut_packet: BitIterator = .{ .bytes = &.{ 0, 0, 0, 4, 0, 0, 0, 0, 1, 2, 3 } };
    try testing.expectError(error.Truncated, cut_packet.next());
    var long: BitIterator = .{ .bytes = &.{ 0, 0, 0x3a, 0x99, 0, 0, 0, 0 } };
    try testing.expectError(error.BadLength, long.next());
    var negative: BitIterator = .{ .bytes = &.{ 0x80, 0, 0, 0, 0, 0, 0, 0 } };
    try testing.expectError(error.BadLength, negative.next());
    var max: BitIterator = .{ .bytes = &.{ 0, 0, 0x3a, 0x98, 0, 0, 0, 0 } };
    try testing.expectError(error.Truncated, max.next());
}

/// The reference signal of the synthetic cases: one second of stereo.
fn synthRef(out: []i16) void {
    var x: Xorshift = .{ .s = 2463534242 };
    for (0..out.len / 2) |t| {
        const ti: i32 = @intCast(t);
        const a = @rem(ti * 37, 2001) - 1000;
        const b = @rem(ti * 101, 1601) - 800;
        const nl: i32 = @as(i32, @intCast(x.next() % 601)) - 300;
        const nr: i32 = @as(i32, @intCast(x.next() % 601)) - 300;
        out[2 * t] = @intCast(a * 8 + b * 2 + nl);
        out[2 * t + 1] = @intCast(b * 8 - a * 2 + nr);
    }
}

const synth_frames = 48000;

fn synthCase(c: u8, ref: []const i16, out: []i16) usize {
    var x: Xorshift = .{ .s = 88172645 };
    switch (c) {
        0 => {
            @memcpy(out[0..ref.len], ref);
            return ref.len;
        },
        1 => {
            for (0..synth_frames) |t| {
                const dl: i32 = @as(i32, @intCast(x.next() % 41)) - 20;
                const dr: i32 = @as(i32, @intCast(x.next() % 41)) - 20;
                out[2 * t] = @intCast(ref[2 * t] + dl);
                out[2 * t + 1] = @intCast(ref[2 * t + 1] + dr);
            }
            return ref.len;
        },
        2 => {
            for (ref, 0..) |s, i| out[i] = s >> 1;
            return ref.len;
        },
        3 => {
            for (0..synth_frames) |t| {
                const d: i32 = @as(i32, @intCast(x.next() % 41)) - 20;
                const mid: i32 = @intFromFloat(0.5 * @as(f64, @floatFromInt(@as(i32, ref[2 * t]) + ref[2 * t + 1])));
                out[t] = @intCast(mid + d);
            }
            return synth_frames;
        },
        4 => {
            for (0..synth_frames / 3) |t| {
                const d: i32 = @as(i32, @intCast(x.next() % 41)) - 20;
                const mid: i32 = @intFromFloat(0.5 * @as(f64, @floatFromInt(@as(i32, ref[6 * t]) + ref[6 * t + 1])));
                out[t] = @intCast(mid + d);
            }
            return synth_frames / 3;
        },
        5 => {
            for (0..synth_frames) |t| {
                const dl: i32 = @as(i32, @intCast(x.next() % 2001)) - 1000;
                const dr: i32 = @as(i32, @intCast(x.next() % 2001)) - 1000;
                out[2 * t] = @intCast(ref[2 * t] + dl);
                out[2 * t + 1] = @intCast(ref[2 * t + 1] + dr);
            }
            return ref.len;
        },
        else => unreachable,
    }
}

// Error values from opus_compare of libopus 1.6.1 on the same signals.
const synth_expect = [_]struct { c: u8, stereo: bool, rate: u32, err: f64 }{
    .{ .c = 0, .stereo = true, .rate = 48000, .err = 0.0 },
    .{ .c = 1, .stereo = true, .rate = 48000, .err = 0.020421243 },
    .{ .c = 2, .stereo = true, .rate = 48000, .err = 0.422342438 },
    .{ .c = 3, .stereo = false, .rate = 48000, .err = 0.032908882 },
    .{ .c = 4, .stereo = false, .rate = 16000, .err = 6.328914280 },
    .{ .c = 5, .stereo = true, .rate = 48000, .err = 1.224416119 },
};

test "opus_compare gives the libopus error on synthetic signals" {
    var ref: [synth_frames * 2]i16 = undefined;
    synthRef(&ref);
    var out: [synth_frames * 2]i16 = undefined;
    for (synth_expect) |e| {
        const n = synthCase(e.c, &ref, &out);
        const q = try compare(gpa, &ref, out[0..n], e.stereo, e.rate);
        try testing.expectApproxEqRel(e.err, q.err, 2e-4);
        try testing.expectEqual(e.err < 0.2769, q.passes());
    }
}

test "opus_compare quality follows the error" {
    var ref: [synth_frames * 2]i16 = undefined;
    synthRef(&ref);
    const same = try compare(gpa, &ref, &ref, true, 48000);
    try testing.expectEqual(@as(f64, 100), same.quality);
    try testing.expectEqual(@as(f64, 0), same.err);
    try testing.expect(same.passes());
    var out: [synth_frames * 2]i16 = undefined;
    const n = synthCase(1, &ref, &out);
    const noisy = try compare(gpa, &ref, out[0..n], true, 48000);
    // Q is 91.7297 in libopus.
    try testing.expectApproxEqAbs(@as(f64, 91.7297), noisy.quality, 0.01);
    try testing.expect(noisy.passes());
}

test "opus_compare rejects bad input" {
    var ref: [2 * 1000]i16 = @splat(0);
    var out: [2 * 999]i16 = @splat(0);
    try testing.expectError(error.SampleCountMismatch, compare(gpa, &ref, &out, true, 48000));
    var short_ref: [2 * 479]i16 = @splat(0);
    var short_out: [2 * 479]i16 = @splat(0);
    try testing.expectError(error.TooShort, compare(gpa, &short_ref, &short_out, true, 48000));
    try testing.expectError(error.UnsupportedRate, compare(gpa, &ref, &ref, true, 44100));
    // One more sample than a multiple of the downsample factor does not match.
    var out16: [334]i16 = @splat(0);
    try testing.expectError(error.SampleCountMismatch, compare(gpa, &ref, &out16, false, 16000));
}

test "pcm16 files read little endian and drop a cut frame" {
    const bytes = [_]u8{ 1, 0, 0xff, 0xff, 0x00, 0x80, 0xff, 0x7f, 5 };
    const samples = try pcm16(gpa, &bytes, 2);
    defer gpa.free(samples);
    try testing.expectEqualSlices(i16, &.{ 1, -1, -32768, 32767 }, samples);
}

fn rintf(v: f32) i32 {
    if (@abs(v - @trunc(v)) == 0.5) return @intFromFloat(2 * @round(v / 2));
    return @intFromFloat(@round(v));
}

/// The 16 bit output of opus_demo: a 24 bit value, rounded to 16 bits.
fn toS16(x: f32) i16 {
    var s = rintf(32768.0 * 256.0 * x);
    s = std.math.clamp(s, -0x7fff00, 0x7fff00);
    return @intCast((s + 128) >> 8);
}

/// Decodes a .bit file and checks the final range of every packet. The result has
/// `channels` interleaved channels and the caller frees it.
fn decodeVector(bytes: []const u8, channels: u32, vector: usize, samples: u32) ![]i16 {
    const pcm = try gpa.alloc(i16, @as(usize, samples) * channels);
    errdefer gpa.free(pcm);
    var dec = try opus.PacketDecoder.init(channels, .{});
    var out: [opus.packet.max_samples * 2]f32 = undefined;
    var it: BitIterator = .{ .bytes = bytes };
    var pos: usize = 0;
    var index: usize = 0;
    while (try it.next()) |record| : (index += 1) {
        const n = try dec.decode(record.packet, false, &out);
        if (pos + n * channels > pcm.len) return error.TooManySamples;
        if (record.final_range != dec.finalRange()) {
            std.debug.print("vector {d} channels {d}: packet {d} final range {x} instead of {x}\n", .{ vector, channels, index, dec.finalRange(), record.final_range });
            return error.FinalRangeMismatch;
        }
        for (out[0 .. n * channels]) |s| {
            pcm[pos] = toS16(s);
            pos += 1;
        }
    }
    try testing.expectEqual(pcm.len, pos);
    return pcm;
}

// Decodes a vector in stereo and mono, checks the final range of every packet and compares
// with opus_compare. A stereo decoder matches the set with phase inversion and a mono decoder
// the set without it.
fn checkOpusCompare(number: usize) !void {
    const index = number - 1;
    var name_buf: [32]u8 = undefined;
    const bit = try readVector(try std.fmt.bufPrint(&name_buf, "testvector{d:0>2}.bit", .{number}));
    defer gpa.free(bit);
    const dec_bytes = try readVector(try std.fmt.bufPrint(&name_buf, "testvector{d:0>2}.dec", .{number}));
    defer gpa.free(dec_bytes);
    const mdec_bytes = try readVector(try std.fmt.bufPrint(&name_buf, "testvector{d:0>2}m.dec", .{number}));
    defer gpa.free(mdec_bytes);
    const reference = try pcm16(gpa, dec_bytes, 2);
    defer gpa.free(reference);
    const reference_m = try pcm16(gpa, mdec_bytes, 2);
    defer gpa.free(reference_m);

    for ([_]u32{ 2, 1 }) |channels| {
        const pcm = try decodeVector(bit, channels, number, sample_counts[index]);
        defer gpa.free(pcm);
        const q = try compare(gpa, reference, pcm, channels == 2, 48000);
        const qm = try compare(gpa, reference_m, pcm, channels == 2, 48000);
        const expected = if (channels == 2) q else qm;
        if (!expected.passes()) {
            std.debug.print("vector {d:0>2} channels {d}: Q {d:.1} (dec) {d:.1} (m.dec)\n", .{ number, channels, q.quality, qm.quality });
            return error.CompareFailed;
        }
    }
}

// The vectors that hold CELT packets only.
const celt_vectors = [_]usize{ 1, 7, 11 };

test "CELT only vectors decode with the libopus final range and pass opus_compare" {
    for (celt_vectors) |number| try checkOpusCompare(number);
}

// The vectors with hybrid packets, and the ones that change mode, bandwidth or channels.
const mixed_vectors = [_]usize{ 5, 6, 8, 9, 10, 12 };

test "hybrid and mode switching vectors decode with the libopus final range and pass opus_compare" {
    for (mixed_vectors) |number| try checkOpusCompare(number);
}

// The vectors that hold SILK only packets.
const silk_vectors = [_]usize{ 2, 3, 4 };

test "SILK only vectors decode byte exact in stereo and pass opus_compare in mono" {
    for (silk_vectors) |number| {
        const index = number - 1;
        var name_buf: [32]u8 = undefined;
        const bit = try readVector(try std.fmt.bufPrint(&name_buf, "testvector{d:0>2}.bit", .{number}));
        defer gpa.free(bit);
        const dec_bytes = try readVector(try std.fmt.bufPrint(&name_buf, "testvector{d:0>2}.dec", .{number}));
        defer gpa.free(dec_bytes);
        const mdec_bytes = try readVector(try std.fmt.bufPrint(&name_buf, "testvector{d:0>2}m.dec", .{number}));
        defer gpa.free(mdec_bytes);
        const reference = try pcm16(gpa, dec_bytes, 2);
        defer gpa.free(reference);
        const reference_m = try pcm16(gpa, mdec_bytes, 2);
        defer gpa.free(reference_m);

        const stereo = try decodeVector(bit, 2, number, sample_counts[index]);
        defer gpa.free(stereo);
        try testing.expectEqual(reference.len, stereo.len);
        for (reference, stereo, 0..) |want, got, at| {
            if (want != got) {
                std.debug.print("vector {d:0>2}: sample {d} is {d} instead of {d}\n", .{ number, at, got, want });
                return error.SamplesDiffer;
            }
        }

        const mono = try decodeVector(bit, 1, number, sample_counts[index]);
        defer gpa.free(mono);
        const qm = try compare(gpa, reference_m, mono, false, 48000);
        if (!qm.passes()) {
            std.debug.print("vector {d:0>2} mono: Q {d:.1}\n", .{ number, qm.quality });
            return error.CompareFailed;
        }
    }
}

const plc_expected = @import("plc_vectors_expected.zig");

// Decodes a vector with runs of 1, 2 and 3 lost packets, like the libopus harness that made the
// expected values. The sample count and the final range of every call must match. The SILK
// only parts must be exact. The sampled output elsewhere may differ by `loss_tolerance`
// steps, as the concealment filters amplify rounding noise of the float code.
fn checkLoss(number: usize, channels: u32, pattern: u8, expected: anytype) !void {
    var name_buf: [32]u8 = undefined;
    const bit = try readVector(try std.fmt.bufPrint(&name_buf, "testvector{d:0>2}.bit", .{number}));
    defer gpa.free(bit);
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(gpa);
    var it: BitIterator = .{ .bytes = bit };
    while (try it.next()) |record| try list.append(gpa, record.packet);
    var dec = try opus.PacketDecoder.init(channels, .{});
    opus.test_util.playLoss(&dec, list.items, pattern, false, expected, loss_tolerance) catch |err| {
        std.debug.print("vector {d:0>2} channels {d}\n", .{ number, channels });
        return err;
    };
}

// The sampled points are few and do not hit the calls that the concealment makes chaotic (a few
// calls of vector 7 differ by more than 100 steps from libopus). The energy bound covers the rest.
const loss_tolerance = 8;

test "vectors with lost packets decode like libopus" {
    inline for (1..13) |number| {
        inline for (.{ 1, 2 }) |channels| {
            const name = std.fmt.comptimePrint("v{d:0>2}_c{d}", .{ number, channels });
            try checkLoss(number, channels, 1, @field(plc_expected, name));
        }
    }
}

test "vectors with a long burst of lost packets decode like libopus" {
    inline for (.{ 1, 2, 5, 7, 11 }) |number| {
        inline for (.{ 1, 2 }) |channels| {
            const name = std.fmt.comptimePrint("b{d:0>2}_c{d}", .{ number, channels });
            try checkLoss(number, channels, 2, @field(plc_expected, name));
        }
    }
}

test "fft band energies equal the direct transform" {
    var prng = Xorshift{ .s = 0x1234 };
    const frames = 6;
    for ([_]usize{ 1, 2, 3, 4, 6 }) |downsample| {
        for ([_]usize{ 1, 2 }) |nch| {
            const win = test_win_size / downsample;
            const step = test_win_step / downsample;
            const input = try gpa.alloc(f32, ((frames - 1) * step + win) * nch);
            defer gpa.free(input);
            for (input) |*v| v.* = @floatFromInt(@as(i32, @intCast(prng.next() % 65536)) - 32768);
            const nb: usize = switch (downsample) {
                1 => 21,
                2 => 19,
                3 => 17,
                4 => 15,
                else => 13,
            };
            const ps_len = frames * (win / 2) * nch;
            const out_len = frames * nb * nch;
            const ps_new = try gpa.alloc(f32, ps_len);
            defer gpa.free(ps_new);
            const ps_old = try gpa.alloc(f32, ps_len);
            defer gpa.free(ps_old);
            const out_new = try gpa.alloc(f32, out_len);
            defer gpa.free(out_new);
            const out_old = try gpa.alloc(f32, out_len);
            defer gpa.free(out_old);
            @memset(ps_new, 0);
            @memset(ps_old, 0);
            bandEnergy(out_new, ps_new, nb, input, nch, frames, win, step, downsample);
            bandEnergyDirect(out_old, ps_old, nb, input, nch, frames, win, step, downsample);
            for (out_new, out_old) |a, b| try testing.expectApproxEqRel(b, a, 1e-4);
            for (ps_new, ps_old) |a, b| try testing.expectApproxEqRel(b, a, 1e-4);
        }
    }
}
