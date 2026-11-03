//! The Vorbis MDCT. A block of `n` samples has `n / 2` spectrum lines. The inverse has no scale
//! and the forward has the scale 4 / n, so forward, window and overlap add rebuild the input
//! (each unfolded value counts twice, so a bare forward then inverse gives 2 times the input).
const std = @import("std");
const testing = std.testing;

pub const min_n = 8;
pub const max_n = 1 << 16;

/// The tables and the work space for one block size. `init` allocates, nothing else does.
/// It holds work buffers, so use one per decoder (or thread) and per block size.
pub const Mdct = struct {
    n: usize,
    /// cos and sin of -pi (8k + 1) / (4n) for k below n / 4, as pairs.
    twiddle: []f32,
    /// cos and sin of -2 pi k / (n / 4) for k below n / 8, as pairs.
    fft_twiddle: []f32,
    bit_reverse: []u32,
    re: []f32,
    im: []f32,
    /// The DCT-IV of the inverse before the unfold.
    u: []f32,

    /// The bytes that `init` takes from the allocator for block size `n`.
    pub fn bytes(n: usize) usize {
        const h = n / 4;
        return (h * 2 + h / 2 * 2 + h + h + h + h * 2) * 4;
    }

    pub fn init(gpa: std.mem.Allocator, n: usize) error{ OutOfMemory, BadSize }!Mdct {
        if (n < min_n or n > max_n or !std.math.isPowerOfTwo(n)) return error.BadSize;
        const m = n / 2;
        const h = m / 2;
        const twiddle = try gpa.alloc(f32, h * 2);
        errdefer gpa.free(twiddle);
        const fft_twiddle = try gpa.alloc(f32, h / 2 * 2);
        errdefer gpa.free(fft_twiddle);
        const bit_reverse = try gpa.alloc(u32, h);
        errdefer gpa.free(bit_reverse);
        const re = try gpa.alloc(f32, h);
        errdefer gpa.free(re);
        const im = try gpa.alloc(f32, h);
        errdefer gpa.free(im);
        const u = try gpa.alloc(f32, m);
        errdefer gpa.free(u);

        const mf: f64 = @floatFromInt(m);
        for (0..h) |k| {
            const a = -std.math.pi * @as(f64, @floatFromInt(8 * k + 1)) / (8.0 * mf);
            twiddle[2 * k] = @floatCast(@cos(a));
            twiddle[2 * k + 1] = @floatCast(@sin(a));
        }
        const hf: f64 = @floatFromInt(h);
        for (0..h / 2) |k| {
            const a = -2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / hf;
            fft_twiddle[2 * k] = @floatCast(@cos(a));
            fft_twiddle[2 * k + 1] = @floatCast(@sin(a));
        }
        const bits: u32 = std.math.log2_int(usize, h);
        for (bit_reverse, 0..) |*r, i| {
            const rev = @bitReverse(@as(u32, @intCast(i)));
            r.* = rev >> @intCast(32 - bits);
        }
        return .{ .n = n, .twiddle = twiddle, .fft_twiddle = fft_twiddle, .bit_reverse = bit_reverse, .re = re, .im = im, .u = u };
    }

    pub fn deinit(self: *Mdct, gpa: std.mem.Allocator) void {
        gpa.free(self.twiddle);
        gpa.free(self.fft_twiddle);
        gpa.free(self.bit_reverse);
        gpa.free(self.re);
        gpa.free(self.im);
        gpa.free(self.u);
        self.* = undefined;
    }

    /// `in` holds n / 2 spectrum lines and `out` gets n samples. `in` and `out` can not overlap.
    pub fn inverse(self: *Mdct, in: []const f32, out: []f32) void {
        std.debug.assert(in.len == self.n / 2 and out.len == self.n);
        const m = self.n / 2;
        const u = self.u;
        self.dct4(in, u);
        const q = m / 2;
        for (0..q) |i| {
            out[i] = u[q + i];
            out[3 * q + i] = -u[i];
        }
        for (q..3 * q) |i| out[i] = -u[3 * q - 1 - i];
    }

    /// `in` holds n windowed samples and `out` gets n / 2 spectrum lines, scaled by 4 / n.
    pub fn forward(self: *Mdct, in: []const f32, out: []f32) void {
        std.debug.assert(in.len == self.n and out.len == self.n / 2);
        const m = self.n / 2;
        const q = m / 2;
        for (0..q) |i| {
            out[i] = -in[3 * q - 1 - i] - in[3 * q + i];
            out[q + i] = in[i] - in[m - 1 - i];
        }
        self.dct4(out, out);
        const scale = 4.0 / @as(f32, @floatFromInt(self.n));
        for (out) |*v| v.* *= scale;
    }

    /// out[m] = sum of x[k] cos(pi / M (m + 1/2) (k + 1/2)). `x` and `out` can be the same slice.
    fn dct4(self: *Mdct, x: []const f32, out: []f32) void {
        const m = x.len;
        const h = m / 2;
        const re = self.re;
        const im = self.im;
        for (0..h) |k| {
            const c = self.twiddle[2 * k];
            const s = self.twiddle[2 * k + 1];
            const zr = x[2 * k];
            const zi = x[m - 1 - 2 * k];
            const j = self.bit_reverse[k];
            re[j] = zr * c - zi * s;
            im[j] = zr * s + zi * c;
        }
        var len: usize = 2;
        while (len <= h) : (len <<= 1) {
            const half = len / 2;
            const stride = h / len;
            var start: usize = 0;
            while (start < h) : (start += len) {
                for (0..half) |k| {
                    const c = self.fft_twiddle[2 * k * stride];
                    const s = self.fft_twiddle[2 * k * stride + 1];
                    const a = start + k;
                    const b = a + half;
                    const tr = re[b] * c - im[b] * s;
                    const ti = re[b] * s + im[b] * c;
                    re[b] = re[a] - tr;
                    im[b] = im[a] - ti;
                    re[a] += tr;
                    im[a] += ti;
                }
            }
        }
        for (0..h) |k| {
            const c = self.twiddle[2 * k];
            const s = self.twiddle[2 * k + 1];
            out[2 * k] = re[k] * c - im[k] * s;
            out[m - 1 - 2 * k] = -(re[k] * s + im[k] * c);
        }
    }
};

fn directInverse(x: []const f32, y: []f64) void {
    const n: f64 = @floatFromInt(y.len);
    for (y, 0..) |*out, i| {
        var sum: f64 = 0;
        for (x, 0..) |v, k| {
            const arg = std.math.pi / (2.0 * n) * @as(f64, @floatFromInt(2 * i + 1)) + std.math.pi / (2.0 * n) * (n / 2.0);
            sum += @as(f64, v) * @cos(arg * @as(f64, @floatFromInt(2 * k + 1)));
        }
        out.* = sum;
    }
}

fn directForward(x: []const f32, out: []f64) void {
    const n: f64 = @floatFromInt(x.len);
    for (out, 0..) |*o, k| {
        var sum: f64 = 0;
        for (x, 0..) |v, i| {
            const arg = std.math.pi / (2.0 * n) * (@as(f64, @floatFromInt(2 * i + 1)) + n / 2.0);
            sum += @as(f64, v) * @cos(arg * @as(f64, @floatFromInt(2 * k + 1)));
        }
        o.* = sum * 4.0 / n;
    }
}

fn fill(rng: *std.Random.DefaultPrng, buf: []f32) void {
    for (buf) |*v| v.* = rng.random().float(f32) * 2 - 1;
}

// About 3e-9 per unit of n, with a floor for the small sizes.
fn tolerance(n: usize) f64 {
    return @max(1e-5, 8e-9 * @as(f64, @floatFromInt(n)));
}

fn inverseError(n: usize) !f64 {
    var rng: std.Random.DefaultPrng = .init(n);
    const x = try testing.allocator.alloc(f32, n / 2);
    defer testing.allocator.free(x);
    const y = try testing.allocator.alloc(f32, n);
    defer testing.allocator.free(y);
    const want = try testing.allocator.alloc(f64, n);
    defer testing.allocator.free(want);
    fill(&rng, x);
    var m: Mdct = try .init(testing.allocator, n);
    defer m.deinit(testing.allocator);
    m.inverse(x, y);
    directInverse(x, want);
    var worst: f64 = 0;
    for (y, want) |a, b| worst = @max(worst, @abs(@as(f64, a) - b));
    return worst;
}

test "inverse matches the direct formula" {
    for ([_]usize{ 64, 128, 256, 2048 }) |n| {
        const err = try inverseError(n);
        try testing.expect(err < tolerance(n));
    }
}

test "inverse matches the direct formula at 8192" {
    const err = try inverseError(8192);
    try testing.expect(err < tolerance(8192));
}

test "forward matches the direct formula" {
    for ([_]usize{ 64, 256, 2048 }) |n| {
        var rng: std.Random.DefaultPrng = .init(n + 1);
        const x = try testing.allocator.alloc(f32, n);
        defer testing.allocator.free(x);
        const got = try testing.allocator.alloc(f32, n / 2);
        defer testing.allocator.free(got);
        const want = try testing.allocator.alloc(f64, n / 2);
        defer testing.allocator.free(want);
        fill(&rng, x);
        var m: Mdct = try .init(testing.allocator, n);
        defer m.deinit(testing.allocator);
        m.forward(x, got);
        directForward(x, want);
        var worst: f64 = 0;
        for (got, want) |a, b| worst = @max(worst, @abs(@as(f64, a) - b));
        try testing.expect(worst < 1e-6);
    }
}

test "inverse then forward doubles a single bin" {
    const n = 256;
    var m: Mdct = try .init(testing.allocator, n);
    defer m.deinit(testing.allocator);
    var x: [n / 2]f32 = @splat(0);
    x[5] = 1;
    var y: [n]f32 = undefined;
    m.inverse(&x, &y);
    var back: [n / 2]f32 = undefined;
    m.forward(&y, &back);
    // the unfold counts every spectrum value twice, so forward after inverse gives 2
    try testing.expectApproxEqAbs(@as(f32, 2), back[5], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), back[6], 1e-5);
}

test "bytes covers what init asks for" {
    var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
    var m: Mdct = try .init(counting.allocator(), 2048);
    defer m.deinit(counting.allocator());
    try testing.expectEqual(Mdct.bytes(2048), counting.allocated_bytes);
}
