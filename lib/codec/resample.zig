//! Polyphase windowed sinc sample rate conversion.
const std = @import("std");

pub const Quality = enum { fast, good, best };

const phases = 256;
const max_taps = 64;

const Params = struct { taps: usize, beta: f64, rolloff: f64 };

fn params(quality: Quality) Params {
    return switch (quality) {
        .fast => .{ .taps = 16, .beta = 5.0, .rolloff = 0.90 },
        .good => .{ .taps = 32, .beta = 7.0, .rolloff = 0.94 },
        .best => .{ .taps = 64, .beta = 9.0, .rolloff = 0.97 },
    };
}

comptime {
    for (std.enums.values(Quality)) |q| std.debug.assert(params(q).taps <= max_taps);
}

fn besselI0(x: f64) f64 {
    const q = x * x / 4.0;
    var term: f64 = 1.0;
    var sum: f64 = 1.0;
    var k: f64 = 1.0;
    while (term >= 1e-12 * sum) : (k += 1.0) {
        term *= q / (k * k);
        sum += term;
    }
    return sum;
}

fn kaiser(x: f64, beta: f64) f64 {
    if (@abs(x) > 1.0) return 0.0;
    return besselI0(beta * @sqrt(1.0 - x * x)) / besselI0(beta);
}

fn sinc(x: f64) f64 {
    if (x == 0.0) return 1.0;
    const px = std.math.pi * x;
    return @sin(px) / px;
}

pub const Resampler = struct {
    pub const Options = struct {
        channels: u8,
        in_rate: u32,
        out_rate: u32,
        quality: Quality = .good,
        block_frames: u32 = 1024,
    };
    pub const Result = struct { in_frames: usize, out_frames: usize };

    channels: usize,
    taps: usize,
    table: []f32,
    work: []f32,
    /// Frames held in `work`.
    len: usize,
    /// First frame of the current window.
    idx: usize,
    /// Input frames still to drop after a large step.
    skip: usize,
    frac: f64,
    base_step: f64,
    step: f64,

    pub fn init(gpa: std.mem.Allocator, options: Options) error{OutOfMemory}!Resampler {
        std.debug.assert(options.channels > 0);
        std.debug.assert(options.in_rate > 0 and options.out_rate > 0);
        std.debug.assert(options.block_frames > 0);
        const taps = params(options.quality).taps;
        const beta = params(options.quality).beta;
        const rolloff = params(options.quality).rolloff;
        const in_rate: f64 = @floatFromInt(options.in_rate);
        const out_rate: f64 = @floatFromInt(options.out_rate);
        const cutoff = rolloff * @min(1.0, out_rate / in_rate);
        const half = taps / 2;

        const table = try gpa.alloc(f32, (phases + 1) * taps);
        errdefer gpa.free(table);
        for (0..phases + 1) |p| {
            const row = table[p * taps ..][0..taps];
            const offset = @as(f64, @floatFromInt(p)) / phases;
            var sum: f64 = 0;
            var tmp: [max_taps]f64 = undefined;
            for (0..taps) |k| {
                const u = @as(f64, @floatFromInt(k)) - @as(f64, @floatFromInt(half)) + 1.0 - offset;
                tmp[k] = cutoff * sinc(cutoff * u) * kaiser(u / @as(f64, @floatFromInt(half)), beta);
                sum += tmp[k];
            }
            for (row, tmp[0..taps]) |*dst, v| dst.* = @floatCast(v / sum);
        }

        const channels: usize = options.channels;
        const work = try gpa.alloc(f32, (taps + options.block_frames) * channels);
        @memset(work, 0);

        const step = in_rate / out_rate;
        return .{
            .channels = channels,
            .taps = taps,
            .table = table,
            .work = work,
            .len = half - 1,
            .idx = 0,
            .skip = 0,
            .frac = 0,
            .base_step = step,
            .step = step,
        };
    }

    pub fn deinit(self: *Resampler, gpa: std.mem.Allocator) void {
        gpa.free(self.table);
        gpa.free(self.work);
        self.* = undefined;
    }

    /// Forgets all earlier input. The filter starts as after init.
    pub fn reset(self: *Resampler) void {
        @memset(self.work, 0);
        self.len = self.taps / 2 - 1;
        self.idx = 0;
        self.frac = 0;
        self.skip = 0;
    }

    /// Multiplies the input step to follow clock drift. Asserts 0.9 <= factor <= 1.1.
    pub fn setAdjust(self: *Resampler, factor: f64) void {
        std.debug.assert(factor >= 0.9 and factor <= 1.1);
        self.step = self.base_step * factor;
    }

    /// Interleaved frames. Takes what it can hold, makes what fits in `out`.
    pub fn process(self: *Resampler, in: []const f32, out: []f32) Result {
        const ch = self.channels;
        const taps = self.taps;
        const cap = self.work.len / ch;
        const in_avail = in.len / ch;

        var consumed: usize = 0;
        const dropped = @min(self.skip, in_avail);
        self.skip -= dropped;
        consumed += dropped;

        const take = @min(in_avail - consumed, cap - self.len);
        @memcpy(self.work[self.len * ch ..][0 .. take * ch], in[consumed * ch ..][0 .. take * ch]);
        self.len += take;
        consumed += take;

        var produced: usize = 0;
        while (self.idx + taps <= self.len and (produced + 1) * ch <= out.len) {
            const pf = self.frac * phases;
            const p: usize = @intFromFloat(@floor(pf));
            const a: f32 = @floatCast(pf - @as(f64, @floatFromInt(p)));
            const row0 = self.table[p * taps ..][0..taps];
            const row1 = self.table[(p + 1) * taps ..][0..taps];
            for (0..ch) |c| {
                var y: f32 = 0;
                for (0..taps) |k| {
                    y += self.work[(self.idx + k) * ch + c] * (row0[k] * (1 - a) + row1[k] * a);
                }
                out[produced * ch + c] = y;
            }
            produced += 1;
            self.frac += self.step;
            const whole = @floor(self.frac);
            self.frac -= whole;
            self.idx += @intFromFloat(whole);
        }

        if (self.idx >= self.len) {
            self.skip += self.idx - self.len;
            self.len = 0;
        } else {
            const keep = self.len - self.idx;
            std.mem.copyForwards(f32, self.work[0 .. keep * ch], self.work[self.idx * ch ..][0 .. keep * ch]);
            self.len = keep;
        }
        self.idx = 0;

        return .{ .in_frames = consumed, .out_frames = produced };
    }
};

fn sine(buf: []f32, channels: u8, freq: f64, rate: f64) void {
    const frames = buf.len / channels;
    for (0..frames) |i| {
        const v: f32 = @floatCast(@sin(2.0 * std.math.pi * freq * @as(f64, @floatFromInt(i)) / rate));
        for (0..channels) |c| buf[i * channels + c] = v;
    }
}

/// Feeds `in` in pieces of `chunk` frames and collects all output.
fn runAll(gpa: std.mem.Allocator, r: *Resampler, channels: u8, in: []const f32, chunk: usize) ![]f32 {
    var out: std.ArrayList(f32) = .empty;
    errdefer out.deinit(gpa);
    var scratch: [512]f32 = undefined;
    const usable = scratch.len - scratch.len % channels;
    var pos: usize = 0;
    while (true) {
        const end = @min(in.len, pos + chunk * channels);
        const res = r.process(in[pos..end], scratch[0..usable]);
        try out.appendSlice(gpa, scratch[0 .. res.out_frames * channels]);
        pos += res.in_frames * channels;
        if (res.in_frames == 0 and res.out_frames == 0) {
            if (pos >= in.len) break;
        }
    }
    return out.toOwnedSlice(gpa);
}

test "a constant signal stays constant" {
    const gpa = std.testing.allocator;
    var r: Resampler = try .init(gpa, .{ .channels = 2, .in_rate = 48000, .out_rate = 44100 });
    defer r.deinit(gpa);
    var in: [4800 * 2]f32 = undefined;
    @memset(&in, 0.5);
    const out = try runAll(gpa, &r, 2, &in, 4800);
    defer gpa.free(out);
    for (out[64 * 2 .. out.len - 64 * 2]) |v| try std.testing.expectApproxEqAbs(@as(f32, 0.5), v, 1e-3);
}

test "a 1 kHz sine keeps its shape when going from 48 kHz to 44.1 kHz" {
    const gpa = std.testing.allocator;
    var r: Resampler = try .init(gpa, .{ .channels = 1, .in_rate = 48000, .out_rate = 44100, .quality = .best });
    defer r.deinit(gpa);
    var in: [48000]f32 = undefined;
    sine(&in, 1, 1000, 48000);
    const out = try runAll(gpa, &r, 1, &in, 1000);
    defer gpa.free(out);
    var err: f64 = 0;
    var sig: f64 = 0;
    for (64..out.len - 64) |j| {
        const ideal = @sin(2.0 * std.math.pi * 1000.0 * @as(f64, @floatFromInt(j)) / 44100.0);
        const d = @as(f64, out[j]) - ideal;
        err += d * d;
        sig += ideal * ideal;
    }
    try std.testing.expect(@sqrt(err / sig) < 1e-3);
}

test "a tone above the new Nyquist frequency is removed" {
    const gpa = std.testing.allocator;
    var r: Resampler = try .init(gpa, .{ .channels = 1, .in_rate = 48000, .out_rate = 32000 });
    defer r.deinit(gpa);
    var in: [48000]f32 = undefined;
    sine(&in, 1, 20000, 48000);
    const out = try runAll(gpa, &r, 1, &in, 1000);
    defer gpa.free(out);
    var energy: f64 = 0;
    for (out[64 .. out.len - 64]) |v| energy += @as(f64, v) * v;
    const rms = @sqrt(energy / @as(f64, @floatFromInt(out.len - 128)));
    try std.testing.expect(rms < 0.01 * std.math.sqrt1_2);
}

test "output does not depend on how the input is cut" {
    const gpa = std.testing.allocator;
    var in: [3000 * 2]f32 = undefined;
    sine(&in, 2, 440, 44100);
    var a: Resampler = try .init(gpa, .{ .channels = 2, .in_rate = 44100, .out_rate = 48000 });
    defer a.deinit(gpa);
    var b: Resampler = try .init(gpa, .{ .channels = 2, .in_rate = 44100, .out_rate = 48000 });
    defer b.deinit(gpa);
    const out_a = try runAll(gpa, &a, 2, &in, 7);
    defer gpa.free(out_a);
    const out_b = try runAll(gpa, &b, 2, &in, 3000);
    defer gpa.free(out_b);
    try std.testing.expectEqualSlices(f32, out_a, out_b);
}

test "upsampling one second gives about one second of output" {
    const gpa = std.testing.allocator;
    var r: Resampler = try .init(gpa, .{ .channels = 1, .in_rate = 44100, .out_rate = 48000 });
    defer r.deinit(gpa);
    const in = try gpa.alloc(f32, 44100);
    defer gpa.free(in);
    @memset(in, 0);
    const out = try runAll(gpa, &r, 1, in, 1024);
    defer gpa.free(out);
    try std.testing.expect(out.len >= 48000 - 64 and out.len <= 48000);
}

test "a drift adjust above one makes fewer output frames" {
    const gpa = std.testing.allocator;
    var r: Resampler = try .init(gpa, .{ .channels = 1, .in_rate = 48000, .out_rate = 48000 });
    defer r.deinit(gpa);
    r.setAdjust(1.01);
    const in = try gpa.alloc(f32, 48000);
    defer gpa.free(in);
    @memset(in, 0);
    const out = try runAll(gpa, &r, 1, in, 1024);
    defer gpa.free(out);
    try std.testing.expect(out.len < 47600 and out.len > 47400);
}
