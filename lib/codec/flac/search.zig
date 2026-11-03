//! The model search of the FLAC encoder: it picks the predictor and the Rice coding
//! of one channel of a block, as libFLAC does for the levels 0 to 8.
const std = @import("std");
const lpc = @import("lpc.zig");
const testing = std.testing;

pub const Stereo = enum { off, loose, full };

pub const Level = struct {
    block: u16,
    stereo: Stereo,
    max_lpc: u8,
    max_part: u4,
    /// 1 is a plain tukey(0.5) window. A larger value is subdivide_tukey(parts).
    parts: u8,
};

pub const levels = [9]Level{
    .{ .block = 1152, .stereo = .off, .max_lpc = 0, .max_part = 3, .parts = 1 },
    .{ .block = 1152, .stereo = .loose, .max_lpc = 0, .max_part = 3, .parts = 1 },
    .{ .block = 1152, .stereo = .full, .max_lpc = 0, .max_part = 3, .parts = 1 },
    .{ .block = 4096, .stereo = .off, .max_lpc = 6, .max_part = 4, .parts = 1 },
    .{ .block = 4096, .stereo = .loose, .max_lpc = 8, .max_part = 4, .parts = 1 },
    .{ .block = 4096, .stereo = .full, .max_lpc = 8, .max_part = 5, .parts = 1 },
    .{ .block = 4096, .stereo = .full, .max_lpc = 8, .max_part = 6, .parts = 2 },
    .{ .block = 4096, .stereo = .full, .max_lpc = 12, .max_part = 6, .parts = 2 },
    .{ .block = 4096, .stereo = .full, .max_lpc = 12, .max_part = 6, .parts = 3 },
};

pub const max_part_order = 6;
pub const max_partitions = 1 << max_part_order;
const max_rice = 30;
const max_rice_narrow = 14;
pub const escape: u8 = 255;
/// The escape bit count is a 5 bit field.
const max_escape_bits = 31;

pub const Kind = enum { constant, verbatim, fixed, lpc };

/// How one channel of a frame is coded.
pub const Plan = struct {
    kind: Kind = .verbatim,
    wasted: u8 = 0,
    /// The sample depth after the wasted bits are removed.
    bps: u8,
    order: u8 = 0,
    precision: u8 = 0,
    shift: u8 = 0,
    coefs: [lpc.max_order]i32 = undefined,
    constant: i32 = 0,
    part_order: u4 = 0,
    method: u1 = 0,
    /// The Rice parameter of each partition, or `escape`.
    params: [max_partitions]u8 = undefined,
    esc_bits: [max_partitions]u8 = undefined,
    /// The bits of the residual coding, from the method field on.
    rice_bits: u64 = 0,
    /// The bits of the subframe. An estimate while a model is searched.
    bits: u64 = 0,
};

fn riceParameter(sum: u64, count: u64) u8 {
    if (sum < 2) return 0;
    const q = (sum - 1) / count;
    if (q == 0) return 0;
    return @intCast(@min(@as(u64, max_rice), @as(u64, std.math.log2_int(u64, q)) + 1));
}

fn estimateBits(sum: u64, count: u64) u64 {
    const k = riceParameter(sum, count);
    const body = (1 + @as(u64, k)) * count + (if (k > 0) sum >> @intCast(k - 1) else sum << 1);
    return 4 + (body -| (count >> 1));
}

pub fn partitionCount(n: usize, order: usize, part_order: u4, partition: usize) usize {
    return (n >> part_order) - (if (partition == 0) order else 0);
}

/// The largest partition order up to `limit` that divides the block and leaves more
/// samples in a partition than the predictor order.
fn limitPartOrder(n: usize, order: usize, limit: u4) u4 {
    var po = limit;
    while (po > 0 and (n & ((@as(usize, 1) << po) - 1) != 0 or (n >> po) <= order)) po -= 1;
    return po;
}

const RiceEstimate = struct { part_order: u4, bits: u64 };

const Sums = [2 * max_partitions - 1]u64;

/// Picks the partition order with the fewest estimated bits. `resid` holds the residual
/// of the samples from index `order` on.
fn searchRice(resid: []const i32, n: usize, order: usize, limit: u4, sums: *Sums) RiceEstimate {
    const top = limitPartOrder(n, order, limit);
    const top_base = (@as(usize, 1) << top) - 1;
    var start: usize = 0;
    for (0..@as(usize, 1) << top) |p| {
        const count = partitionCount(n, order, top, p);
        var sum: u64 = 0;
        for (resid[start..][0..count]) |r| sum += @abs(r);
        sums[top_base + p] = sum;
        start += count;
    }
    var o = top;
    while (o > 0) {
        o -= 1;
        const base = (@as(usize, 1) << o) - 1;
        const below = (@as(usize, 1) << (o + 1)) - 1;
        for (0..@as(usize, 1) << o) |p| sums[base + p] = sums[below + 2 * p] + sums[below + 2 * p + 1];
    }
    var best: RiceEstimate = .{ .part_order = top, .bits = std.math.maxInt(u64) };
    o = top;
    while (true) {
        const base = (@as(usize, 1) << o) - 1;
        var bits: u64 = 6;
        for (0..@as(usize, 1) << o) |p| bits += estimateBits(sums[base + p], partitionCount(n, order, o, p));
        if (bits < best.bits) best = .{ .part_order = o, .bits = bits };
        if (o == 0) break;
        o -= 1;
    }
    return best;
}

fn signedBits(r: i32) u8 {
    if (r == 0) return 0;
    const magnitude: u32 = @bitCast(if (r < 0) ~r else r);
    return 33 - @clz(magnitude);
}

fn foldedSum(part: []const i32, k: u8) u64 {
    var sum: u64 = 0;
    for (part) |r| {
        const bits: u32 = @bitCast(r);
        const folded = (bits << 1) ^ @as(u32, @bitCast(r >> 31));
        sum += folded >> @intCast(k);
    }
    return sum;
}

/// Chooses the Rice parameters, or an escape, of each partition at the given order and
/// sets the residual coding fields of `plan`.
pub fn riceCode(plan: *Plan, resid: []const i32, n: usize, order: usize, part_order: u4) void {
    const parts = @as(usize, 1) << part_order;
    var start: usize = 0;
    var total: u64 = 0;
    var wide = false;
    for (0..parts) |p| {
        const count = partitionCount(n, order, part_order, p);
        const part = resid[start..][0..count];
        start += count;
        var sum: u64 = 0;
        var esc: u8 = 0;
        for (part) |r| {
            sum += @abs(r);
            esc = @max(esc, signedBits(r));
        }
        const guess = riceParameter(sum, count);
        var best_k: u8 = 0;
        var best_cost: u64 = std.math.maxInt(u64);
        var k = guess -| 1;
        while (k <= @min(guess + 1, max_rice)) : (k += 1) {
            const cost = (1 + @as(u64, k)) * count + foldedSum(part, k);
            if (cost < best_cost) {
                best_cost = cost;
                best_k = k;
            }
        }
        const esc_cost = 5 + @as(u64, esc) * count;
        if (esc <= max_escape_bits and esc_cost < best_cost) {
            plan.params[p] = escape;
            plan.esc_bits[p] = esc;
            total += esc_cost;
        } else {
            plan.params[p] = best_k;
            total += best_cost;
            if (best_k > max_rice_narrow) wide = true;
        }
    }
    plan.method = @intFromBool(wide);
    plan.part_order = part_order;
    plan.rice_bits = 6 + parts * (4 + @as(u64, plan.method)) + total;
}

/// Finds the cheapest way to code a channel.
pub const Search = struct {
    level: Level,
    /// The coefficient precision before the limit of the sample depth.
    precision: u8,
    window: []f64,
    window_len: usize = 0,
    windowed: []f64,
    work: []i32,
    resid: []i32,
    sums: Sums = undefined,
    lev: lpc.Levinson = .{},

    pub fn plan(self: *Search, signal: []const i32, bps: u8) Plan {
        const n = signal.len;
        var any: u32 = 0;
        for (signal) |x| any |= @as(u32, @bitCast(x));
        const wasted: u5 = if (any == 0) 0 else @intCast(@ctz(any));
        var p: Plan = .{ .bps = bps - wasted, .wasted = wasted };
        const work = self.work[0..n];
        for (work, signal) |*w, s| w.* = s >> wasted;
        const head: u64 = 8 + wasted;
        var same = true;
        for (work) |x| {
            if (x != work[0]) {
                same = false;
                break;
            }
        }
        if (same) {
            p.kind = .constant;
            p.constant = work[0];
            p.bits = head + p.bps;
            return p;
        }
        p.bits = head + @as(u64, n) * p.bps;
        if (n <= lpc.max_fixed_order) return p;
        var best = p;
        self.tryFixed(work, &best);
        if (self.level.max_lpc > 0) self.tryLpc(work, &best);
        if (best.kind == .verbatim) return p;
        self.finish(&best, work);
        return if (best.bits < p.bits) best else p;
    }

    fn rice(self: *Search, resid: []const i32, n: usize, order: usize) RiceEstimate {
        return searchRice(resid, n, order, self.level.max_part, &self.sums);
    }

    fn tryFixed(self: *Search, work: []const i32, best: *Plan) void {
        const n = work.len;
        const choice = lpc.bestFixed(work);
        if (choice.bits >= @as(f64, @floatFromInt(best.bps))) return;
        const resid = self.resid[0 .. n - choice.order];
        lpc.fixedResidual(work, choice.order, resid);
        const est = self.rice(resid, n, choice.order);
        const bits = 8 + @as(u64, best.wasted) + choice.order * @as(u64, best.bps) + est.bits;
        if (bits < best.bits) {
            best.kind = .fixed;
            best.order = @intCast(choice.order);
            best.bits = bits;
        }
    }

    fn tryLpc(self: *Search, work: []const i32, best: *Plan) void {
        const n = work.len;
        const max = @min(@as(usize, self.level.max_lpc), n - 1);
        const lags = max + 1;
        const parts = self.level.parts;
        if (self.window_len != n) {
            lpc.tukey(self.window[0..n], 0.5 / @as(f64, @floatFromInt(parts)));
            self.window_len = n;
        }
        const window = self.window[0..n];
        const buf = self.windowed[0..n];
        var root: [lpc.max_order + 1]f64 = undefined;
        var autoc: [lpc.max_order + 1]f64 = undefined;
        lpc.applyWindow(buf, work, window);
        lpc.autocorrelation(buf, autoc[0..lags]);
        root = autoc;
        self.candidate(work, autoc[0..lags], best);
        var depth: usize = 2;
        while (depth <= parts) : (depth += 1) {
            if (n / depth <= lpc.max_order) continue;
            var have_partial = false;
            for (0..2 * depth) |c| {
                if (c % 2 == 0) {
                    have_partial = lpc.applyPartial(buf, work, window, n / depth / 2, c / 2 * n / depth);
                    if (!have_partial) continue;
                    lpc.autocorrelation(buf[0 .. n / depth], autoc[0..lags]);
                } else {
                    if (depth == 2 or !have_partial) continue;
                    for (autoc[0..lags], root[0..lags]) |*a, r| a.* = r - a.*;
                }
                self.candidate(work, autoc[0..lags], best);
            }
        }
    }

    fn candidate(self: *Search, work: []const i32, autoc: []const f64, best: *Plan) void {
        if (!(autoc[0] > 0.0)) return;
        const n = work.len;
        const bps = best.bps;
        lpc.levinson(autoc, autoc.len - 1, &self.lev);
        const order = lpc.bestOrder(self.lev.err[0..self.lev.orders], n, bps + self.precision);
        if (lpc.expectedBits(self.lev.err[order - 1], n - order) >= @as(f64, @floatFromInt(bps))) return;
        const precision = self.precision;
        var q: [lpc.max_order]i32 = undefined;
        const shift = lpc.quantize(self.lev.coefs[order - 1][0..order], precision, &q) orelse return;
        const resid = self.resid[0 .. n - order];
        if (!lpc.residual(work, q[0..order], shift, resid)) return;
        const est = self.rice(resid, n, order);
        const bits = 8 + @as(u64, best.wasted) + order * (@as(u64, bps) + precision) + 9 + est.bits;
        if (bits < best.bits) {
            best.kind = .lpc;
            best.order = @intCast(order);
            best.precision = precision;
            best.shift = shift;
            best.coefs = q;
            best.bits = bits;
        }
    }

    /// Sets the Rice parameters of the chosen model and its exact size.
    fn finish(self: *Search, p: *Plan, work: []const i32) void {
        const n = work.len;
        const order: usize = p.order;
        const resid = self.resid[0 .. n - order];
        switch (p.kind) {
            .fixed => lpc.fixedResidual(work, order, resid),
            .lpc => {
                const ok = lpc.residual(work, p.coefs[0..order], p.shift, resid);
                std.debug.assert(ok);
            },
            .constant, .verbatim => unreachable,
        }
        riceCode(p, resid, n, order, self.rice(resid, n, order).part_order);
        p.bits = 8 + @as(u64, p.wasted) + order * @as(u64, p.bps) + p.rice_bits;
        if (p.kind == .lpc) p.bits += 9 + order * @as(u64, p.precision);
    }
};

test "rice coding picks the cheapest parameter and escapes when that is smaller" {
    var plan: Plan = .{ .bps = 16 };
    var zeros: [64]i32 = @splat(0);
    riceCode(&plan, &zeros, 64, 0, 2);
    try testing.expectEqual(@as(u8, 2), plan.part_order);
    try testing.expectEqual(@as(u1, 0), plan.method);
    for (0..4) |i| {
        try testing.expectEqual(escape, plan.params[i]);
        try testing.expectEqual(@as(u8, 0), plan.esc_bits[i]);
    }
    try testing.expectEqual(@as(u64, 6 + 4 * (4 + 5)), plan.rice_bits);

    var skewed: [256]i32 = undefined;
    for (&skewed, 0..) |*x, i| x.* = if (i % 16 == 0) 40 else @as(i32, @intCast(i % 3)) - 1;
    riceCode(&plan, &skewed, 256, 0, 0);
    try testing.expect(plan.params[0] < 3);
    try testing.expectEqual(@as(u64, 6) + bruteRice(&skewed, 4), plan.rice_bits);

    var uniform: [256]i32 = undefined;
    var rng: u32 = 99;
    for (&uniform) |*x| {
        rng = rng *% 1664525 +% 1013904223;
        x.* = @as(i32, @intCast(rng >> 21)) - 1024;
    }
    uniform[0] = -1024;
    riceCode(&plan, &uniform, 256, 0, 0);
    try testing.expectEqual(escape, plan.params[0]);
    try testing.expectEqual(@as(u8, 11), plan.esc_bits[0]);
    try testing.expectEqual(@as(u64, 6 + 4 + 5 + 256 * 11), plan.rice_bits);

    var big: [64]i32 = undefined;
    for (&big, 0..) |*x, i| x.* = if (i % 4 == 0) 100000 else @as(i32, @intCast(i % 4)) - 2;
    riceCode(&plan, &big, 64, 0, 0);
    try testing.expectEqual(@as(u1, 1), plan.method);
    try testing.expectEqual(@as(u8, 15), plan.params[0]);
    try testing.expectEqual(@as(u64, 6) + bruteRice(&big, 5), plan.rice_bits);
}

fn bruteRice(resid: []const i32, param_bits: u64) u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..31) |k| {
        var cost: u64 = param_bits + (1 + k) * resid.len;
        for (resid) |r| {
            const folded: u32 = @intCast((r << 1) ^ (r >> 31));
            cost += folded >> @intCast(k);
        }
        best = @min(best, cost);
    }
    return best;
}

test "a partition that needs 32 escape bits is Rice coded" {
    var plan: Plan = .{ .bps = 25 };
    var big: [16]i32 = @splat(1 << 30);
    riceCode(&plan, &big, 16, 0, 0);
    try testing.expect(plan.params[0] != escape);
    try testing.expectEqual(@as(u1, 1), plan.method);
    try testing.expectEqual(@as(u8, 30), plan.params[0]);
    var edge: [16]i32 = @splat((1 << 30) - 1);
    riceCode(&plan, &edge, 16, 0, 0);
    try testing.expectEqual(escape, plan.params[0]);
    try testing.expectEqual(@as(u8, 31), plan.esc_bits[0]);
}
