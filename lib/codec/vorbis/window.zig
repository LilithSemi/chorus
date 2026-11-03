//! The Vorbis power sine window and the overlap of neighbouring blocks.
const std = @import("std");
const testing = std.testing;
const mdct = @import("mdct.zig");

/// Fills `out` with the rising half window for `out.len` samples.
pub fn slope(out: []f32) void {
    const len: f64 = @floatFromInt(out.len);
    for (out, 0..) |*v, i| {
        const s = @sin(std.math.pi / 2.0 * (@as(f64, @floatFromInt(i)) + 0.5) / len);
        v.* = @floatCast(@sin(std.math.pi / 2.0 * s * s));
    }
}

/// The rising slopes of the short and the long block size, made once.
pub const Windows = struct {
    bs0: usize,
    bs1: usize,
    short: []f32,
    long: []f32,

    pub fn bytes(bs0: usize, bs1: usize) usize {
        return (bs0 / 2 + bs1 / 2) * 4;
    }

    pub fn init(gpa: std.mem.Allocator, bs0: usize, bs1: usize) error{OutOfMemory}!Windows {
        std.debug.assert(bs0 <= bs1 and std.math.isPowerOfTwo(bs0) and std.math.isPowerOfTwo(bs1));
        const short = try gpa.alloc(f32, bs0 / 2);
        errdefer gpa.free(short);
        const long = try gpa.alloc(f32, bs1 / 2);
        slope(short);
        slope(long);
        return .{ .bs0 = bs0, .bs1 = bs1, .short = short, .long = long };
    }

    pub fn deinit(self: *Windows, gpa: std.mem.Allocator) void {
        gpa.free(self.short);
        gpa.free(self.long);
        self.* = undefined;
    }

    /// Fills `out` (the block size) with the window of a block. A long block next to a short
    /// block has the short slope on that side.
    pub fn fill(self: *const Windows, out: []f32, is_long: bool, prev_long: bool, next_long: bool) void {
        const n = out.len;
        std.debug.assert(n == if (is_long) self.bs1 else self.bs0);
        const full = if (is_long) self.long else self.short;
        var left_n = n / 2;
        var left_start: usize = 0;
        var right_n = n / 2;
        var right_start = n / 2;
        if (is_long and !prev_long) {
            left_n = self.bs0 / 2;
            left_start = n / 4 - self.bs0 / 4;
        }
        if (is_long and !next_long) {
            right_n = self.bs0 / 2;
            right_start = 3 * n / 4 - self.bs0 / 4;
        }
        const left = if (left_n == full.len) full else self.short;
        const right = if (right_n == full.len) full else self.short;
        const left_end = left_start + left_n;
        const right_end = right_start + right_n;
        @memset(out[0..left_start], 0);
        @memcpy(out[left_start..left_end], left);
        @memset(out[left_end..right_start], 1);
        for (0..right_n) |i| out[right_start + i] = right[right_n - 1 - i];
        @memset(out[right_end..], 0);
    }
};

/// Adds the second half of the previous windowed block to the first half of the current one.
/// `out` gets prev.len / 4 + cur.len / 4 samples and the count is returned.
pub fn overlapAdd(prev: []const f32, cur: []const f32, out: []f32) usize {
    const len = prev.len / 4 + cur.len / 4;
    std.debug.assert(out.len >= len);
    const shift = @as(isize, @intCast(cur.len / 4)) - @as(isize, @intCast(prev.len / 4));
    for (out[0..len], 0..) |*o, k| {
        const a = if (prev.len / 2 + k < prev.len) prev[prev.len / 2 + k] else 0;
        const ci = @as(isize, @intCast(k)) + shift;
        const b = if (ci >= 0 and ci < cur.len) cur[@intCast(ci)] else 0;
        o.* = a + b;
    }
    return len;
}

fn mixedBlocks(gpa: std.mem.Allocator, sizes: []const usize, bs0: usize, bs1: usize, signal: []const f32, expect_from: usize) !void {
    var windows: Windows = try .init(gpa, bs0, bs1);
    defer windows.deinit(gpa);
    var short: mdct.Mdct = try .init(gpa, bs0);
    defer short.deinit(gpa);
    var long: mdct.Mdct = try .init(gpa, bs1);
    defer long.deinit(gpa);

    const buf = try gpa.alloc(f32, 3 * bs1);
    defer gpa.free(buf);
    const win = buf[0..bs1];
    const spec = buf[bs1..][0 .. bs1 / 2];
    var prev = try gpa.alloc(f32, bs1);
    defer gpa.free(prev);
    var cur = try gpa.alloc(f32, bs1);
    defer gpa.free(cur);
    const block = try gpa.alloc(f32, bs1);
    defer gpa.free(block);
    var prev_n: usize = 0;
    var center: usize = 0;
    for (sizes, 0..) |n, j| {
        const is_long = n == bs1;
        const prev_long = j > 0 and sizes[j - 1] == bs1;
        const next_long = j + 1 < sizes.len and sizes[j + 1] == bs1;
        if (j > 0) center += prev_n / 4 + n / 4 else center = bs1 / 2;
        windows.fill(win[0..n], is_long, prev_long, next_long);
        const start = center - n / 2;
        for (0..n) |i| block[i] = signal[start + i] * win[i];
        const m = if (is_long) &long else &short;
        m.forward(block[0..n], spec[0 .. n / 2]);
        m.inverse(spec[0 .. n / 2], cur[0..n]);
        for (0..n) |i| cur[i] *= win[i];
        if (j > 0) {
            const out = buf[2 * bs1 ..];
            const len = overlapAdd(prev[0..prev_n], cur[0..n], out);
            try testing.expectEqual(prev_n / 4 + n / 4, len);
            const first = center - len;
            for (0..len) |k| {
                if (first + k >= expect_from) try testing.expectApproxEqAbs(signal[first + k], out[k], 2e-5);
            }
        }
        std.mem.swap([]f32, &prev, &cur);
        prev_n = n;
    }
}

test "mixed block sizes overlap add to the input" {
    var rng: std.Random.DefaultPrng = .init(7);
    const sizes = [_]usize{ 256, 256, 2048, 2048, 256, 256, 256, 2048, 256, 2048, 2048, 2048, 256 };
    var signal: [20000]f32 = undefined;
    for (&signal) |*v| v.* = rng.random().float(f32) * 2 - 1;
    try mixedBlocks(testing.allocator, &sizes, 256, 2048, &signal, 0);
}

test "block sizes 64 and 8192 reconstruct" {
    var rng: std.Random.DefaultPrng = .init(8);
    const signal = try testing.allocator.alloc(f32, 80000);
    defer testing.allocator.free(signal);
    for (signal) |*v| v.* = rng.random().float(f32) * 2 - 1;
    const sizes = [_]usize{ 64, 64, 8192, 64, 8192, 8192, 64, 64, 64, 8192 };
    try mixedBlocks(testing.allocator, &sizes, 64, 8192, signal, 0);
}

test "bytes equals what init allocates" {
    var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
    var w: Windows = try .init(counting.allocator(), 256, 2048);
    defer w.deinit(counting.allocator());
    try testing.expectEqual(Windows.bytes(256, 2048), counting.allocated_bytes);
}

test "slope values" {
    var t: [32]f32 = undefined;
    slope(&t);
    try testing.expectApproxEqAbs(@as(f32, 0.0009460463), t[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f32, 0.0085006468), t[1], 1e-9);
    for (0..16) |i| {
        try testing.expectApproxEqAbs(@as(f32, 1), t[i] * t[i] + t[31 - i] * t[31 - i], 1e-6);
    }
}

test "long window next to short blocks" {
    var windows: Windows = try .init(testing.allocator, 64, 256);
    defer windows.deinit(testing.allocator);
    var w: [256]f32 = undefined;
    windows.fill(&w, true, false, true);
    // left slope sits at 64 - 16 = 48 to 80, right half is the full slope
    for (w[0..48]) |v| try testing.expectEqual(@as(f32, 0), v);
    for (w[80..128]) |v| try testing.expectEqual(@as(f32, 1), v);
    try testing.expect(w[48] > 0 and w[48] < 0.01);
    try testing.expect(w[79] > 0.99 and w[79] < 1);
    try testing.expect(w[129] < 1 and w[129] > 0.99);
    try testing.expect(w[255] > 0 and w[255] < 0.001);
    windows.fill(&w, true, true, false);
    // right slope sits at 192 - 16 = 176 to 208
    for (w[128..176]) |v| try testing.expectEqual(@as(f32, 1), v);
    for (w[208..256]) |v| try testing.expectEqual(@as(f32, 0), v);
    try testing.expect(w[176] > 0.99 and w[176] < 1);
    try testing.expect(w[207] > 0 and w[207] < 0.01);
    var s: [64]f32 = undefined;
    windows.fill(&s, false, false, false);
    try testing.expectEqual(s[0], s[63]);
    try testing.expect(s[0] < 0.01 and s[31] > 0.99);
}
