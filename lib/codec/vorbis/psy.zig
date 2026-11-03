//! The psychoacoustic model of the encoder: the hearing threshold, the spread of a masker and
//! the detector for sudden attacks. All levels are in dB of the MDCT spectrum, where a full
//! scale sine peaks near 0 dB.
const std = @import("std");
const header = @import("header.zig");
const testing = std.testing;

/// The lines of the spectrum that belong to one floor post.
pub const Band = struct {
    start: u32,
    stop: u32,
};

/// The hearing threshold in dB SPL at `hz`, after Terhardt, cut at 60 dB. The formula rises
/// much faster above 14 kHz than the thresholds of real ears do.
pub fn hearingThreshold(hz: f64) f64 {
    const k = std.math.clamp(hz, 20, 20000) / 1000.0;
    const spl = 3.64 * std.math.pow(f64, k, -0.8) - 6.5 * @exp(-0.6 * (k - 3.3) * (k - 3.3)) + 1e-3 * std.math.pow(f64, k, 4);
    return @min(spl, 60);
}

/// The critical band rate in Bark at `hz`.
pub fn bark(hz: f64) f64 {
    return 13 * std.math.atan(0.00076 * hz) + 3.5 * std.math.atan((hz / 7500) * (hz / 7500));
}

/// The level in dB that a masker adds at `dz` Bark above it (negative `dz` is below it),
/// after Schroeder. It is 0 at the masker and falls on both sides, faster downwards.
pub fn spreadDb(dz: f64) f64 {
    const x = dz + 0.474;
    return 15.81 + 7.5 * x - 17.5 * @sqrt(1 + x * x);
}

pub const Model = struct {
    /// One band per floor post, in the order of the post list.
    bands: []Band,
    /// The level in dB that a post can have before one line of its band is audible. It is the
    /// threshold of hearing for the whole band, shared out over the lines of the band.
    ath_db: []f32,
    /// `spread[i * posts + j]` is the dB that the band `j` adds at the post `i`.
    spread: []f32,

    /// `listen_spl` is the sound pressure level that a full scale sine has when it is played.
    pub fn init(arena: std.mem.Allocator, f: header.Floor1, rate: u32, lines: u32, listen_spl: f32) error{OutOfMemory}!Model {
        const posts = f.x.len;
        const bands = try arena.alloc(Band, posts);
        const ath = try arena.alloc(f32, posts);
        const zbark = try arena.alloc(f64, posts);
        const spread = try arena.alloc(f32, posts * posts);

        const nyquist: f64 = @floatFromInt(rate / 2);
        for (f.order, 0..) |index, s| {
            const x: u32 = f.x[index];
            const below: u32 = if (s > 0) f.x[f.order[s - 1]] else x;
            const above: u32 = if (s + 1 < posts) f.x[f.order[s + 1]] else x;
            const start = if (s > 0) (below + x) / 2 else 0;
            const stop = @min(lines, @max(start + 1, if (s + 1 < posts) (x + above) / 2 + 1 else lines));
            bands[index] = .{ .start = @min(start, lines - 1), .stop = stop };
            const hz = @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(lines)) * nyquist;
            const count: f64 = @floatFromInt(stop - bands[index].start);
            ath[index] = @floatCast(hearingThreshold(hz) - listen_spl - 10 * std.math.log10(count));
            zbark[index] = bark(hz);
        }
        for (0..posts) |i| {
            for (0..posts) |j| spread[i * posts + j] = @floatCast(spreadDb(zbark[i] - zbark[j]));
        }
        return .{ .bands = bands, .ath_db = ath, .spread = spread };
    }

    /// Sets `out[i]` to the level of the quantisation noise that the post `i` can carry. It is
    /// the strongest masker, spread to the post, less `margin_db`, and it does not fall under the
    /// threshold of hearing. `levels` holds the level of each band.
    pub fn thresholds(self: *const Model, levels: []const f64, margin_db: f64, out: []f64) void {
        const posts = self.bands.len;
        std.debug.assert(levels.len == posts and out.len == posts);
        for (0..posts) |i| {
            var masked: f64 = -std.math.inf(f64);
            for (levels, self.spread[i * posts ..][0..posts]) |level, s| masked = @max(masked, level + s);
            out[i] = @max(masked - margin_db, self.ath_db[i]);
        }
    }
};

/// The energy of the second difference of `x[from..][0..len]`. Samples before `x[2]` count as 0.
fn highEnergy(x: []const f32, from: usize, len: usize) f64 {
    var sum: f64 = 0;
    var i = @max(from, 2);
    while (i < from + len) : (i += 1) {
        const d = @as(f64, x[i]) - 2 * @as(f64, x[i - 1]) + x[i - 2];
        sum += d * d;
    }
    return sum;
}

/// The jump in energy that counts as an attack, and the energy per sample under which a
/// segment is too quiet to matter.
const attack_ratio = 10.0;
const quiet_energy = 1e-5;

/// True when a segment of `seg` samples has a high band energy far above the two segments
/// before it. The segments tested start at `x[lead]`, and the two before them give the
/// reference, so `lead` is at least `2 * seg`. A last segment can be shorter than `seg`.
pub fn hasAttack(x: []const f32, lead: usize, seg: usize) bool {
    std.debug.assert(lead >= 2 * seg and seg > 0);
    var before = [2]f64{ highEnergy(x, lead - 2 * seg, seg), highEnergy(x, lead - seg, seg) };
    var at = lead;
    while (at < x.len) : (at += seg) {
        const e = highEnergy(x, at, @min(seg, x.len - at));
        const reference = (before[0] + before[1]) / 2;
        if (e > quiet_energy * @as(f64, @floatFromInt(seg)) and e > attack_ratio * reference) return true;
        before = .{ before[1], e };
    }
    return false;
}

fn testFloor(arena: std.mem.Allocator, rate: u32, mode: usize) !header.Floor1 {
    const setup = @import("setup.zig");
    const built = try setup.build(arena, .{ .channels = 1, .rate = rate, .quality = 4 });
    return built.setup.floors[mode].one;
}

test "the hearing threshold is lowest near 3.5 kHz and rises steeply above 14 kHz" {
    try testing.expect(hearingThreshold(3500) < hearingThreshold(1000));
    try testing.expect(hearingThreshold(3500) < hearingThreshold(10000));
    try testing.expect(hearingThreshold(3500) < 0);
    try testing.expect(hearingThreshold(14000) > 35);
    try testing.expect(hearingThreshold(14000) < hearingThreshold(15000));
    try testing.expectEqual(@as(f64, 60), hearingThreshold(20000));
    try testing.expectEqual(hearingThreshold(20), hearingThreshold(1));
}

test "the Bark scale and the spread function have the known values" {
    try testing.expectApproxEqAbs(@as(f64, 0), bark(0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 8.5), bark(1000), 0.1);
    try testing.expectApproxEqAbs(@as(f64, 0), spreadDb(0), 0.01);
    try testing.expectApproxEqAbs(@as(f64, -4.3), spreadDb(1), 0.1);
    try testing.expectApproxEqAbs(@as(f64, -7.9), spreadDb(-1), 0.1);
    var dz: f64 = 0.25;
    while (dz < 20) : (dz += 0.25) {
        try testing.expect(spreadDb(dz) < spreadDb(dz - 0.25));
        try testing.expect(spreadDb(-dz) < spreadDb(-dz + 0.25));
        try testing.expect(spreadDb(-dz) < spreadDb(dz));
    }
}

test "a masker lifts the floor of its neighbours and the threshold lifts the quiet bands" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try testFloor(a, 44100, 1);
    const model: Model = try .init(a, f, 44100, 1024, 90);
    try testing.expectEqual(f.x.len, model.bands.len);
    const level = try a.alloc(f64, f.x.len);
    const out = try a.alloc(f64, f.x.len);
    @memset(level, -60);
    model.thresholds(level, 12, out);
    for (out, model.ath_db) |o, ath| try testing.expectApproxEqAbs(@max(level[0] - 12, @as(f64, ath)), o, 0.01);

    // A loud band at one post lifts the posts near it and leaves the far ones alone.
    var loud: usize = 0;
    for (f.x, 0..) |x, i| {
        if (x == 46) loud = i;
    }
    level[loud] = -10;
    const lifted = try a.alloc(f64, f.x.len);
    model.thresholds(level, 12, lifted);
    try testing.expectApproxEqAbs(@as(f64, -22), lifted[loud], 0.01);
    var near: usize = 0;
    var far: usize = 0;
    for (f.x, 0..) |x, i| {
        if (x == 55) near = i;
        if (x == 650) far = i;
    }
    try testing.expect(lifted[near] > out[near] + 1);
    try testing.expectEqual(out[far], lifted[far]);
}

test "the bands tile the spectrum without gaps" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][3]u32{ .{ 44100, 1, 1024 }, .{ 22050, 1, 512 }, .{ 8000, 1, 256 }, .{ 44100, 0, 128 }, .{ 22050, 0, 64 } };
    for (cases) |case| {
        const lines: u16 = @intCast(case[2]);
        const f = try testFloor(a, case[0], case[1]);
        const model: Model = try .init(a, f, case[0], lines, 90);
        var covered = try a.alloc(u8, lines);
        @memset(covered, 0);
        for (model.bands) |b| {
            try testing.expect(b.start < b.stop and b.stop <= lines);
            for (covered[b.start..b.stop]) |*c| c.* = 1;
        }
        for (covered) |c| try testing.expectEqual(@as(u8, 1), c);
    }
}

test "an attack is a jump in the high band energy" {
    var x: [2048]f32 = @splat(0);
    try testing.expect(!hasAttack(&x, 512, 256));
    x[1200] = 0.5;
    try testing.expect(hasAttack(&x, 512, 256));
    // The impulse inside the two segments before the tested ones is not an attack.
    var y: [2048]f32 = @splat(0);
    y[100] = 0.5;
    try testing.expect(!hasAttack(&y, 512, 256));
    // A last segment that is shorter still counts.
    var z: [1100]f32 = @splat(0);
    z[1090] = 0.5;
    try testing.expect(hasAttack(&z, 512, 256));
}

test "steady noise, a sine and a quiet start are not attacks" {
    var prng: std.Random.DefaultPrng = .init(77);
    const random = prng.random();
    var noise: [8192]f32 = undefined;
    for (&noise) |*v| v.* = (random.float(f32) - 0.5) * 0.5;
    var at: usize = 512;
    while (at + 4096 <= noise.len) : (at += 512) {
        try testing.expect(!hasAttack(noise[at - 512 ..][0..4608], 512, 256));
    }
    var sine: [4096]f32 = undefined;
    for (&sine, 0..) |*v, i| v.* = 0.5 * @sin(0.05 * @as(f32, @floatFromInt(i)));
    try testing.expect(!hasAttack(&sine, 512, 256));
    var faint: [4096]f32 = undefined;
    @memset(&faint, 0);
    faint[2000] = 1e-3;
    try testing.expect(!hasAttack(&faint, 512, 256));
    // The same jump after noise is an attack only when it is loud enough.
    var burst: [4096]f32 = undefined;
    for (&burst, 0..) |*v, i| v.* = if (i < 2000) (random.float(f32) - 0.5) * 0.01 else (random.float(f32) - 0.5) * 0.5;
    try testing.expect(hasAttack(&burst, 512, 256));
}
