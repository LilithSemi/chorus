//! PVQ codeword enumeration ported from libopus celt/cwrs.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const range = @import("../range.zig");

const rows = 15;
const cols = 177;

/// `u_table[a][b]` is U(a, b) for `a <= 14` and `b <= 176`, or 0 where it does not fit in 32 bits.
const u_table = buildU();

fn buildU() [rows][cols]u32 {
    @setEvalBranchQuota(100_000);
    var full: [rows][cols]u128 = undefined;
    for (0..rows) |a| {
        for (0..cols) |b| {
            full[a][b] = if (a == 0)
                @intFromBool(b == 0)
            else if (b == 0)
                0
            else
                full[a - 1][b] + full[a][b - 1] + full[a - 1][b - 1];
        }
    }
    var out: [rows][cols]u32 = undefined;
    for (0..rows) |a| {
        for (0..cols) |b| {
            out[a][b] = if (full[a][b] <= std.math.maxInt(u32)) @intCast(full[a][b]) else 0;
        }
    }
    return out;
}

/// Number of pulse vectors that use fewer than `k` pulses in `n - 1` dimensions.
pub fn pvqU(n: u32, k: u32) u32 {
    return u_table[@min(n, k)][@max(n, k)];
}

/// Number of `n` dimensional integer vectors with `k` pulses.
pub fn pvqV(n: u32, k: u32) u32 {
    return pvqU(n, k) +% pvqU(n, k + 1);
}

/// True when V(n, k) fits in 32 bits.
pub fn fits(n: u32, k: u32) bool {
    const max_n = [15]u32{ 32767, 32767, 32767, 1476, 283, 109, 60, 40, 29, 24, 20, 18, 16, 14, 13 };
    const max_k = [15]u32{ 32767, 32767, 32767, 32767, 1172, 238, 95, 53, 36, 27, 22, 18, 16, 15, 13 };
    if (n >= 14) {
        if (k >= 14) return false;
        return n <= max_n[k];
    }
    return k <= max_k[n];
}

/// True when `(n, k)` is a valid size for `decode`: two or more dimensions, at least one
/// pulse, a count that fits in 32 bits and a lookup that stays inside the table.
pub fn inDomain(n: u32, k: u32) bool {
    return n >= 2 and n <= cols - 1 and k >= 1 and k <= cols - 2 and fits(n, k);
}

pub const Error = error{InvalidPulses};

/// The index of the pulse vector `y` among all vectors with the same dimension and pulse count.
pub fn index(y: []const i32) u32 {
    std.debug.assert(y.len >= 2);
    const n: u32 = @intCast(y.len);
    var j = n - 1;
    var i: u32 = @intFromBool(y[j] < 0);
    var k: u32 = @abs(y[j]);
    while (true) {
        j -= 1;
        i += pvqU(n - j, k);
        k += @abs(y[j]);
        if (y[j] < 0) i += pvqU(n - j, k + 1);
        if (j == 0) break;
    }
    return i;
}

/// Codes `y`, which holds `k` pulses, with the range encoder.
pub fn encode(enc: *range.Encoder, y: []const i32, k: u32) void {
    std.debug.assert(inDomain(@intCast(y.len), k));
    enc.encodeUint(index(y), pvqV(@intCast(y.len), k));
}

/// Writes the pulse vector with index `i_in` into `y` and returns the sum of its squares.
/// `i_in` must be below V(y.len, k) and `(y.len, k)` must pass `inDomain`.
pub fn unrank(y: []i32, k_in: u32, i_in: u32) u32 {
    std.debug.assert(inDomain(@intCast(y.len), k_in));
    var n: u32 = @intCast(y.len);
    var k = k_in;
    var i = i_in;
    var yy: u32 = 0;
    var pos: usize = 0;
    while (n > 2) : (n -= 1) {
        var val: i32 = undefined;
        if (k >= n) {
            const row = &u_table[n];
            var p = row[k + 1];
            const s: u32 = if (i >= p) std.math.maxInt(u32) else 0;
            i -= p & s;
            const k0 = k;
            const q = row[n];
            if (q > i) {
                k = n;
                while (true) {
                    k -= 1;
                    p = u_table[k][n];
                    if (p <= i) break;
                }
            } else {
                p = row[k];
                while (p > i) {
                    k -= 1;
                    p = row[k];
                }
            }
            i -= p;
            val = signed(k0 - k, s);
        } else {
            const p = u_table[k][n];
            const q = u_table[k + 1][n];
            if (p <= i and i < q) {
                i -= p;
                val = 0;
            } else {
                const s: u32 = if (i >= q) std.math.maxInt(u32) else 0;
                i -= q & s;
                const k0 = k;
                var pp: u32 = undefined;
                while (true) {
                    k -= 1;
                    pp = u_table[k][n];
                    if (pp <= i) break;
                }
                i -= pp;
                val = signed(k0 - k, s);
            }
        }
        y[pos] = val;
        pos += 1;
        yy += @intCast(val * val);
    }
    const p = 2 * k + 1;
    var s: u32 = if (i >= p) std.math.maxInt(u32) else 0;
    i -= p & s;
    const k0 = k;
    k = (i + 1) >> 1;
    if (k != 0) i -= 2 * k - 1;
    var val = signed(k0 - k, s);
    y[pos] = val;
    yy += @intCast(val * val);
    s = 0 -% i;
    val = signed(k, s);
    y[pos + 1] = val;
    yy += @intCast(val * val);
    return yy;
}

/// `mag` with the sign flipped when `s` is all ones.
fn signed(mag: u32, s: u32) i32 {
    const m: i32 = @intCast(mag);
    const mask: i32 = @bitCast(s);
    return (m +% mask) ^ mask;
}

/// Reads one pulse vector of `y.len` dimensions and `k` pulses from the range decoder.
/// Returns the sum of squares of the pulses.
pub fn decode(dec: *range.Decoder, y: []i32, k: u32) Error!u32 {
    if (y.len > cols or !inDomain(@intCast(y.len), k)) return error.InvalidPulses;
    const n: u32 = @intCast(y.len);
    return unrank(y, k, dec.uint(pvqV(n, k)));
}

const fnv = @import("../test_util.zig").fnv;
const Rng = @import("../test_util.zig").Xorshift;
const rng_seed = 0x12345678;

test "V and U agree with libopus tables" {
    var h: u32 = 2166136261;
    var count: u32 = 0;
    var n: u32 = 2;
    while (n <= 176) : (n += 1) {
        var k: u32 = 1;
        while (k <= 60) : (k += 1) {
            if (!fits(n, k)) continue;
            h = fnv(h, pvqV(n, k));
            h = fnv(h, pvqU(n, k));
            h = fnv(h, pvqU(n, k + 1));
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 1352), count);
    try std.testing.expectEqual(@as(u32, 300416625), h);
    try std.testing.expectEqual(@as(u32, 3375210671), pvqU(10, 24));
    try std.testing.expectEqual(@as(u32, 13), pvqU(3, 3));
    try std.testing.expectEqual(@as(u32, 41), pvqU(5, 3));
}

test "encode and decode match libopus on 3000 seeded vectors" {
    var rng = Rng{ .s = rng_seed };
    var h: u32 = 2166136261;
    var c: u32 = 0;
    while (c < 3000) : (c += 1) {
        var n: u32 = 0;
        var k: u32 = 0;
        while (true) {
            n = 2 + rng.next() % (if (c & 7 == 0) @as(u32, 175) else 60);
            k = 1 + rng.next() % (if (rng.next() & 1 != 0) @as(u32, 8) else 40);
            if (fits(n, k)) break;
        }
        var y: [256]i32 = @splat(0);
        var sg: [256]i32 = @splat(0);
        var p: u32 = 0;
        while (p < k) : (p += 1) {
            const pos = rng.next() % n;
            if (sg[pos] == 0) sg[pos] = if (rng.next() & 1 != 0) 1 else -1;
            y[pos] += sg[pos];
        }
        const idx = index(y[0..n]);
        var buf: [32]u8 = @splat(0);
        var enc = range.Encoder.init(&buf);
        encode(&enc, y[0..n], k);
        enc.done();
        for (buf) |b| h = fnv(h, b);
        var dec = range.Decoder.init(&buf);
        var out: [256]i32 = @splat(0);
        const yy = try decode(&dec, out[0..n], k);
        try std.testing.expectEqualSlices(i32, y[0..n], out[0..n]);
        h = fnv(h, n);
        h = fnv(h, k);
        h = fnv(h, idx);
        h = fnv(h, yy);
        h = fnv(h, dec.finalRange());
        for (y[0..n]) |v| h = fnv(h, @bitCast(v));
        if (c == 0) {
            try std.testing.expectEqual(@as(u32, 14), n);
            try std.testing.expectEqual(@as(u32, 649468779), idx);
            try std.testing.expectEqual(@as(u32, 20), yy);
        }
    }
    try std.testing.expectEqual(@as(u32, 3752919806), h);
}

test "unrank inverts index for random indices" {
    var rng = Rng{ .s = 99 };
    var c: u32 = 0;
    while (c < 2000) : (c += 1) {
        var n: u32 = 0;
        var k: u32 = 0;
        while (true) {
            n = 2 + rng.next() % 176;
            k = 1 + rng.next() % 60;
            if (inDomain(n, k)) break;
        }
        const i = rng.next() % pvqV(n, k);
        var y: [256]i32 = @splat(0);
        const yy = unrank(y[0..n], k, i);
        var sum: u32 = 0;
        var sq: u32 = 0;
        for (y[0..n]) |v| {
            sum += @abs(v);
            sq += @intCast(v * v);
        }
        try std.testing.expectEqual(k, sum);
        try std.testing.expectEqual(sq, yy);
        try std.testing.expectEqual(i, index(y[0..n]));
    }
}

test "decode rejects sizes outside the table" {
    var buf: [8]u8 = @splat(0);
    var dec = range.Decoder.init(&buf);
    var y: [4]i32 = @splat(0);
    try std.testing.expectError(error.InvalidPulses, decode(&dec, y[0..1], 3));
    try std.testing.expectError(error.InvalidPulses, decode(&dec, y[0..4], 0));
    try std.testing.expectError(error.InvalidPulses, decode(&dec, y[0..4], 200));
}

test "unrank matches libopus up to 128 pulses" {
    var rnd: Rng = .{ .s = 0x0BADF00D };
    var h: u32 = 2166136261;
    var cnt: u32 = 0;
    var n: u32 = 2;
    while (n <= 176) : (n += 1) {
        var k: u32 = 1;
        while (k <= 128) : (k += 1) {
            if (!fits(n, k)) continue;
            const v = pvqV(n, k);
            for (0..4) |t| {
                const i: u32 = if (t == 0) 0 else if (t == 1) v - 1 else blk: {
                    break :blk rnd.next() % v;
                };
                var y: [256]i32 = undefined;
                const yy = unrank(y[0..n], k, i);
                h = fnv(h, n);
                h = fnv(h, k);
                h = fnv(h, i);
                h = fnv(h, yy);
                for (y[0..n]) |x| h = fnv(h, @bitCast(x));
                try std.testing.expectEqual(i, index(y[0..n]));
                cnt += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(u32, 6636), cnt);
    try std.testing.expectEqual(@as(u32, 3117685601), h);
}
