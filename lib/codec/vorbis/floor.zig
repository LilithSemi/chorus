//! Floor types 0 and 1: reading a floor from an audio packet and building its curve.
const std = @import("std");
const io = @import("../io.zig");
const codebook = @import("codebook.zig");
const header = @import("header.zig");
const Codebook = codebook.Codebook;
const ilog = codebook.ilog;

/// The buffers a channel needs for its floor, in elements. `vec` can be shared by all channels.
pub const Scratch = struct {
    /// The length of `final_y` and `step2` of a floor 1 channel.
    points: usize,
    /// The length of the coefficient list of a floor 0 channel.
    coeffs: usize,
    /// The length of the vector buffer of floor 0.
    vec: usize,
};

/// The most that any floor of the setup needs.
pub fn scratch(setup: *const header.Setup) Scratch {
    var s: Scratch = .{ .points = 0, .coeffs = 0, .vec = 0 };
    for (setup.floors) |floor| switch (floor) {
        .one => |f| s.points = @max(s.points, f.x.len),
        .zero => |f| {
            s.coeffs = @max(s.coeffs, f.order);
            for (f.books) |b| s.vec = @max(s.vec, setup.books[b].dimensions);
        },
    };
    return s;
}

/// Reads a floor 1 from the packet. `final_y` and `step2` need `f.x.len` elements and keep
/// the result for `floor1Curve`. Returns false when the floor is unused, which includes
/// an end of packet.
pub fn decodeFloor1(
    f: header.Floor1,
    books: []const Codebook,
    r: *io.LsbReader,
    final_y: []i32,
    step2: []bool,
) bool {
    const values = f.x.len;
    std.debug.assert(final_y.len >= values and step2.len >= values);
    const present = r.readBit() catch return false;
    if (!present) return false;

    const range: i32 = f.range();
    // Clamping the Y values here and each final_y below is the variant the spec allows. It keeps renderPoint in i32 range.
    const width: u6 = ilog(@intCast(range - 1));
    for (final_y[0..2]) |*y| {
        const raw = r.readBits(width) catch return false;
        y.* = @min(@as(i32, @intCast(raw)), range - 1);
    }

    var offset: usize = 2;
    for (f.partition_classes) |class_index| {
        const class = f.classes[class_index];
        const mask: u32 = (@as(u32, 1) << @intCast(class.subclasses)) - 1;
        var selector: u32 = 0;
        if (class.subclasses > 0) selector = books[class.masterbook].decode(r) catch return false;
        for (final_y[offset..][0..class.dimensions]) |*y| {
            const book = class.subclass_books[selector & mask];
            selector >>= @intCast(class.subclasses);
            y.* = if (book >= 0) @intCast(books[@intCast(book)].decode(r) catch return false) else 0;
        }
        offset += class.dimensions;
    }

    step2[0] = true;
    step2[1] = true;
    for (2..values) |i| {
        const lo = f.low[i];
        const hi = f.high[i];
        const predicted = renderPoint(f.x[lo], final_y[lo], f.x[hi], final_y[hi], f.x[i]);
        const val = final_y[i];
        const high_room = range - predicted;
        const low_room = predicted;
        const room = 2 * @min(high_room, low_room);
        if (val == 0) {
            step2[i] = false;
            final_y[i] = predicted;
            continue;
        }
        step2[lo] = true;
        step2[hi] = true;
        step2[i] = true;
        const level = if (val >= room)
            (if (high_room > low_room) val - low_room + predicted else predicted - val + high_room - 1)
        else if (val & 1 == 1)
            predicted - @divTrunc(val + 1, 2)
        else
            predicted + @divTrunc(val, 2);
        final_y[i] = std.math.clamp(level, 0, range - 1);
    }
    return true;
}

pub fn renderPoint(x0: i32, y0: i32, x1: i32, y1: i32, x: i32) i32 {
    const dy = y1 - y0;
    const off = @divTrunc(@as(i32, @intCast(@abs(dy))) * (x - x0), x1 - x0);
    return if (dy < 0) y0 - off else y0 + off;
}

/// Writes the floor 1 curve to `out`, which has one element per spectrum line.
pub fn floor1Curve(f: header.Floor1, final_y: []const i32, step2: []const bool, out: []f32) void {
    const mult: i32 = f.multiplier;
    const n: i32 = @intCast(out.len);
    var lx: i32 = 0;
    var ly: i32 = final_y[0] * mult;
    var hx: i32 = 0;
    var hy: i32 = ly;
    for (f.order[1..]) |i| {
        if (!step2[i]) continue;
        hy = final_y[i] * mult;
        hx = f.x[i];
        renderLine(lx, ly, hx, hy, out);
        lx = hx;
        ly = hy;
    }
    if (hx < n) renderLine(hx, hy, n, hy, out);
}

/// Sets `out[x0 .. x1]` without `x1` to the dB values of the line, as far as `out` goes.
fn renderLine(x0: i32, y0: i32, x1: i32, y1: i32, out: []f32) void {
    const dy = y1 - y0;
    const adx = x1 - x0;
    if (adx <= 0) return;
    const base = @divTrunc(dy, adx);
    const sy = if (dy < 0) base - 1 else base + 1;
    const ady = @as(i32, @intCast(@abs(dy))) - @as(i32, @intCast(@abs(base))) * adx;
    const end: usize = @intCast(@min(x1, @as(i32, @intCast(out.len))));
    var x: usize = @intCast(x0);
    var y = y0;
    var err: i32 = 0;
    if (x < end) out[x] = dbLevel(y);
    x += 1;
    while (x < end) : (x += 1) {
        err += ady;
        if (err >= adx) {
            err -= adx;
            y += sy;
        } else y += base;
        out[x] = dbLevel(y);
    }
}

fn dbLevel(y: i32) f32 {
    return inverse_db[@intCast(std.math.clamp(y, 0, 255))];
}

/// Reads a floor 0 from the packet. `coeffs` needs `f.order` elements and `vec` the largest
/// book dimension of the floor. Returns the amplitude, or null when the floor is unused.
/// A book number past the book list and an amplitude wider than 32 bits also give null.
pub fn decodeFloor0(
    f: header.Floor0,
    books: []const Codebook,
    r: *io.LsbReader,
    coeffs: []f64,
    vec: []f32,
) ?u32 {
    std.debug.assert(coeffs.len >= f.order);
    if (f.amplitude_bits > 32) return null;
    const amplitude = r.readBits(@intCast(f.amplitude_bits)) catch return null;
    if (amplitude == 0) return null;
    const number = r.readBits(ilog(@intCast(f.books.len))) catch return null;
    if (number >= f.books.len) return null;
    const book = &books[f.books[number]];
    const dim: usize = book.dimensions;
    std.debug.assert(dim > 0 and vec.len >= dim);

    var count: usize = 0;
    var last: f64 = 0;
    while (count < f.order) {
        const entry = book.decode(r) catch return null;
        book.vector(entry, vec[0..dim]);
        for (vec[0..dim]) |v| {
            if (count < f.order) coeffs[count] = v + last;
            count += 1;
        }
        last = @as(f64, vec[dim - 1]) + last;
    }
    return amplitude;
}

fn bark(x: f64) f64 {
    return 13.1 * std.math.atan(0.00074 * x) + 2.24 * std.math.atan(1.85e-8 * x * x) + 0.0001 * x;
}

/// Fills the map of a floor 0 for a block of `map.len - 1` spectrum lines. The last element is -1.
pub fn barkMap(f: header.Floor0, map: []i32) void {
    const n = map.len - 1;
    const size: f64 = @floatFromInt(f.bark_map_size);
    const scale = size / bark(0.5 * @as(f64, @floatFromInt(f.rate)));
    for (map[0..n], 0..) |*m, i| {
        const freq = @as(f64, @floatFromInt(f.rate)) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(2 * n));
        const v: i32 = @intFromFloat(@floor(bark(freq) * scale));
        m.* = @min(@as(i32, f.bark_map_size) - 1, v);
    }
    map[n] = -1;
}

/// Writes the floor 0 curve to `out`, which has `map.len - 1` elements. The coefficients
/// are replaced by their cosines.
pub fn floor0Curve(f: header.Floor0, map: []const i32, amplitude: u32, coeffs: []f64, out: []f32) void {
    std.debug.assert(map.len == out.len + 1);
    const order: usize = f.order;
    for (coeffs[0..order]) |*c| c.* = @cos(c.*);
    const offset: f64 = @floatFromInt(f.amplitude_offset);
    const full: f64 = @floatFromInt((@as(u64, 1) << @intCast(f.amplitude_bits)) - 1);
    const loudness = @as(f64, @floatFromInt(amplitude)) * offset / full;

    var i: usize = 0;
    while (i < out.len) {
        const m = map[i];
        const w = std.math.pi * @as(f64, @floatFromInt(m)) / @as(f64, @floatFromInt(f.bark_map_size));
        const cw = @cos(w);
        var p: f64 = undefined;
        var q: f64 = undefined;
        if (order & 1 == 1) {
            p = 1 - cw * cw;
            q = 0.25;
        } else {
            p = (1 - cw) / 2;
            q = (1 + cw) / 2;
        }
        var j: usize = 1;
        while (j < order) : (j += 2) p *= 4 * (coeffs[j] - cw) * (coeffs[j] - cw);
        j = 0;
        while (j < order) : (j += 2) q *= 4 * (coeffs[j] - cw) * (coeffs[j] - cw);
        const linear = @exp(0.11512925 * (loudness / @sqrt(p + q) - offset));
        const value: f32 = if (std.math.isNan(linear)) 0 else @floatCast(@min(linear, std.math.floatMax(f32)));
        while (i < out.len and map[i] == m) : (i += 1) out[i] = value;
    }
}

const inverse_db = [256]f32{
    1.0649863e-07, 1.1341951e-07, 1.2079015e-07, 1.2863978e-07,
    1.3699951e-07, 1.4590251e-07, 1.5538408e-07, 1.6548181e-07,
    1.7623575e-07, 1.8768855e-07, 1.9988561e-07, 2.128753e-07,
    2.2670913e-07, 2.4144197e-07, 2.5713223e-07, 2.7384213e-07,
    2.9163793e-07, 3.1059021e-07, 3.3077411e-07, 3.5226968e-07,
    3.7516214e-07, 3.9954229e-07, 4.2550680e-07, 4.5315863e-07,
    4.8260743e-07, 5.1396998e-07, 5.4737065e-07, 5.8294187e-07,
    6.2082472e-07, 6.6116941e-07, 7.0413592e-07, 7.4989464e-07,
    7.9862701e-07, 8.5052630e-07, 9.0579828e-07, 9.6466216e-07,
    1.0273513e-06, 1.0941144e-06, 1.1652161e-06, 1.2409384e-06,
    1.3215816e-06, 1.4074654e-06, 1.4989305e-06, 1.5963394e-06,
    1.7000785e-06, 1.8105592e-06, 1.9282195e-06, 2.0535261e-06,
    2.1869758e-06, 2.3290978e-06, 2.4804557e-06, 2.6416497e-06,
    2.8133190e-06, 2.9961443e-06, 3.1908506e-06, 3.3982101e-06,
    3.6190449e-06, 3.8542308e-06, 4.1047004e-06, 4.3714470e-06,
    4.6555282e-06, 4.9580707e-06, 5.2802740e-06, 5.6234160e-06,
    5.9888572e-06, 6.3780469e-06, 6.7925283e-06, 7.2339451e-06,
    7.7040476e-06, 8.2047000e-06, 8.7378876e-06, 9.3057248e-06,
    9.9104632e-06, 1.0554501e-05, 1.1240392e-05, 1.1970856e-05,
    1.2748789e-05, 1.3577278e-05, 1.4459606e-05, 1.5399272e-05,
    1.6400004e-05, 1.7465768e-05, 1.8600792e-05, 1.9809576e-05,
    2.1096914e-05, 2.2467911e-05, 2.3928002e-05, 2.5482978e-05,
    2.7139006e-05, 2.8902651e-05, 3.0780908e-05, 3.2781225e-05,
    3.4911534e-05, 3.7180282e-05, 3.9596466e-05, 4.2169667e-05,
    4.4910090e-05, 4.7828601e-05, 5.0936773e-05, 5.4246931e-05,
    5.7772202e-05, 6.1526565e-05, 6.5524908e-05, 6.9783085e-05,
    7.4317983e-05, 7.9147585e-05, 8.4291040e-05, 8.9768747e-05,
    9.5602426e-05, 0.00010181521, 0.00010843174, 0.00011547824,
    0.00012298267, 0.00013097477, 0.00013948625, 0.00014855085,
    0.00015820453, 0.00016848555, 0.00017943469, 0.00019109536,
    0.00020351382, 0.00021673929, 0.00023082423, 0.00024582449,
    0.00026179955, 0.00027881276, 0.00029693158, 0.00031622787,
    0.00033677814, 0.00035866388, 0.00038197188, 0.00040679456,
    0.00043323036, 0.00046138411, 0.00049136745, 0.00052329927,
    0.00055730621, 0.00059352311, 0.00063209358, 0.00067317058,
    0.00071691700, 0.00076350630, 0.00081312324, 0.00086596457,
    0.00092223983, 0.00098217216, 0.0010459992,  0.0011139742,
    0.0011863665,  0.0012634633,  0.0013455702,  0.0014330129,
    0.0015261382,  0.0016253153,  0.0017309374,  0.0018434235,
    0.0019632195,  0.0020908006,  0.0022266726,  0.0023713743,
    0.0025254795,  0.0026895994,  0.0028643847,  0.0030505286,
    0.0032487691,  0.0034598925,  0.0036847358,  0.0039241906,
    0.0041792066,  0.0044507950,  0.0047400328,  0.0050480668,
    0.0053761186,  0.0057254891,  0.0060975636,  0.0064938176,
    0.0069158225,  0.0073652516,  0.0078438871,  0.0083536271,
    0.0088964928,  0.009474637,   0.010090352,   0.010746080,
    0.011444421,   0.012188144,   0.012980198,   0.013823725,
    0.014722068,   0.015678791,   0.016697687,   0.017782797,
    0.018938423,   0.020169149,   0.021479854,   0.022875735,
    0.024362330,   0.025945531,   0.027631618,   0.029427276,
    0.031339626,   0.033376252,   0.035545228,   0.037855157,
    0.040315199,   0.042935108,   0.045725273,   0.048696758,
    0.051861348,   0.055231591,   0.058820850,   0.062643361,
    0.066714279,   0.071049749,   0.075666962,   0.080584227,
    0.085821044,   0.091398179,   0.097337747,   0.10366330,
    0.11039993,    0.11757434,    0.12521498,    0.13335215,
    0.14201813,    0.15124727,    0.16107617,    0.17154380,
    0.18269168,    0.19456402,    0.20720788,    0.22067342,
    0.23501402,    0.25028656,    0.26655159,    0.28387361,
    0.30232132,    0.32196786,    0.34289114,    0.36517414,
    0.38890521,    0.41417847,    0.44109412,    0.46975890,
    0.50028648,    0.53279791,    0.56742212,    0.60429640,
    0.64356699,    0.68538959,    0.72993007,    0.77736504,
    0.82788260,    0.88168307,    0.9389798,     1.0,
};

const testing = std.testing;
const vtesting = @import("testing.zig");

const wide_lengths: [128]u8 = @splat(7);
const test_x = [_]u16{ 0, 64, 20, 40 };
const test_low = [_]u8{ 0, 0, 0, 2 };
const test_high = [_]u8{ 0, 0, 1, 1 };
const test_order = [_]u8{ 0, 2, 3, 1 };
const test_classes = [_]header.Floor1Class{.{
    .dimensions = 2,
    .subclasses = 1,
    .masterbook = 0,
    .subclass_books = .{ 1, -1, -1, -1, -1, -1, -1, -1 },
}};

fn testFloor1() header.Floor1 {
    return .{
        .partition_classes = &.{0},
        .classes = &test_classes,
        .multiplier = 2,
        .rangebits = 6,
        .x = &test_x,
        .order = &test_order,
        .low = &test_low,
        .high = &test_high,
    };
}

const Floor1Case = struct { y0: u32, y1: u32, a: usize, b: usize, expect: [4]i32, flags: [4]bool };

fn runFloor1Case(f: header.Floor1, c: Floor1Case) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const books = [_]Codebook{
        try vtesting.parseBook(arena, vtesting.book_scalar_4),
        try vtesting.parseBook(arena, .{ .lengths = &wide_lengths }),
    };
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try w.writeBits(1, 1);
    try w.writeBits(c.y0, 7);
    try w.writeBits(c.y1, 7);
    try vtesting.putCode(&w, books[0], 0);
    try vtesting.putCode(&w, books[1], c.a);
    try vtesting.putCode(&w, books[1], c.b);
    var r: io.LsbReader = .init(w.bytes());
    var y: [4]i32 = undefined;
    var flags: [4]bool = undefined;
    try testing.expect(decodeFloor1(f, &books, &r, &y, &flags));
    try testing.expectEqualSlices(i32, &c.expect, &y);
    try testing.expectEqualSlices(bool, &c.flags, &flags);
}

test "floor 1 odd and even offsets from the prediction" {
    // x 20 predicts 10 + 90 * 20 / 64 = 38 and gives 38 - 2. x 40 then predicts 65 and gives 65 - 1.
    try runFloor1Case(testFloor1(), .{ .y0 = 10, .y1 = 100, .a = 3, .b = 1, .expect = .{ 10, 100, 36, 64 }, .flags = .{ true, true, true, true } });
}

test "floor 1 value past the room on the high side" {
    // Room is 76 and 77 is past it. The high room is larger, so the value is 77 - 38 + 38.
    // A zero value takes the prediction and clears its flag.
    try runFloor1Case(testFloor1(), .{ .y0 = 10, .y1 = 100, .a = 77, .b = 0, .expect = .{ 10, 100, 77, 87 }, .flags = .{ true, true, true, false } });
}

test "floor 1 value past the room on the low side" {
    // The prediction is 100 - 28 = 72 with a high room of 56, and 113 is past the room of 112.
    try runFloor1Case(testFloor1(), .{ .y0 = 100, .y1 = 10, .a = 113, .b = 0, .expect = .{ 100, 10, 14, 13 }, .flags = .{ true, true, true, false } });
}

test "floor 1 end of packet and the absent flag give an unused floor" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const books = [_]Codebook{
        try vtesting.parseBook(arena, vtesting.book_scalar_4),
        try vtesting.parseBook(arena, .{ .lengths = &wide_lengths }),
    };
    var y: [4]i32 = undefined;
    var flags: [4]bool = undefined;
    var r: io.LsbReader = .init(&.{0});
    try testing.expect(!decodeFloor1(testFloor1(), &books, &r, &y, &flags));
    // present, two Y values and the master word, then nothing for the Y of the partition
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try w.writeBits(1, 1);
    try w.writeBits(5, 7);
    try w.writeBits(6, 7);
    try vtesting.putCode(&w, books[0], 0);
    r = .init(w.bytes());
    try testing.expect(!decodeFloor1(testFloor1(), &books, &r, &y, &flags));
}

test "floor 1 Y values of multiplier 3 use seven bits and stay below 86" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const f: header.Floor1 = .{
        .partition_classes = &.{},
        .classes = &.{},
        .multiplier = 3,
        .rangebits = 6,
        .x = &.{ 0, 64 },
        .order = &.{ 0, 1 },
        .low = &.{ 0, 0 },
        .high = &.{ 0, 0 },
    };
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try w.writeBits(1, 1);
    try w.writeBits(127, 7);
    try w.writeBits(84, 7);
    var r: io.LsbReader = .init(w.bytes());
    var y: [2]i32 = undefined;
    var flags: [2]bool = undefined;
    try testing.expect(decodeFloor1(f, &.{}, &r, &y, &flags));
    try testing.expectEqualSlices(i32, &.{ 85, 84 }, &y);
    try testing.expectEqual(@as(usize, 15), r.pos);
}

fn lineFloor(comptime multiplier: u8, comptime x1: u16) header.Floor1 {
    return .{
        .partition_classes = &.{},
        .classes = &.{},
        .multiplier = multiplier,
        .rangebits = 3,
        .x = &.{ 0, x1 },
        .order = &.{ 0, 1 },
        .low = &.{ 0, 0 },
        .high = &.{ 0, 0 },
    };
}

test "render line follows the integer rules for a rising and a falling line" {
    var out: [5]f32 = undefined;
    // 10 to 17 over 5 steps: base 1, step 2, error 2: levels 10 11 12 14 15.
    floor1Curve(lineFloor(1, 5), &.{ 10, 17 }, &.{ true, true }, &out);
    for (out, [_]usize{ 10, 11, 12, 14, 15 }) |v, level| try testing.expectEqual(inverse_db[level], v);
    // 17 to 10: base -1, step -2, error 2: levels 17 16 15 13 12.
    floor1Curve(lineFloor(1, 5), &.{ 17, 10 }, &.{ true, true }, &out);
    for (out, [_]usize{ 17, 16, 15, 13, 12 }) |v, level| try testing.expectEqual(inverse_db[level], v);
}

test "floor 1 curve has a flat tail, a truncation and a multiplier" {
    var out: [7]f32 = undefined;
    floor1Curve(lineFloor(2, 5), &.{ 5, 8 }, &.{ true, true }, &out);
    // levels are doubled: 10 to 16 over 5 steps: base 1, step 2, error 1: 10 11 12 13 14, then 16 flat
    for (out, [_]usize{ 10, 11, 12, 13, 14, 16, 16 }) |v, level| try testing.expectEqual(inverse_db[level], v);
    var short: [3]f32 = undefined;
    floor1Curve(lineFloor(2, 5), &.{ 5, 8 }, &.{ true, true }, &short);
    for (short, [_]usize{ 10, 11, 12 }) |v, level| try testing.expectEqual(inverse_db[level], v);
}

test "floor 1 curve skips points with a cleared flag" {
    // Points (0,4) (4,40) (8,12) with the middle one off give one line from 4 to 12 over 8 steps.
    const f: header.Floor1 = .{
        .partition_classes = &.{},
        .classes = &.{},
        .multiplier = 1,
        .rangebits = 3,
        .x = &.{ 0, 8, 4 },
        .order = &.{ 0, 2, 1 },
        .low = &.{ 0, 0, 0 },
        .high = &.{ 0, 0, 1 },
    };
    var out: [8]f32 = undefined;
    floor1Curve(f, &.{ 4, 12, 40 }, &.{ true, true, false }, &out);
    for (out, [_]usize{ 4, 5, 6, 7, 8, 9, 10, 11 }) |v, level| try testing.expectEqual(inverse_db[level], v);
}

test "inverse dB table ends and steps" {
    try testing.expectEqual(@as(f32, 1.0), inverse_db[255]);
    try testing.expectEqual(@as(f32, 1.0649863e-07), inverse_db[0]);
    for (inverse_db, 0..) |v, i| {
        const direct = @exp(0.11512925 * (@as(f64, @floatFromInt(i)) - 255) * 140 / 256);
        try testing.expectApproxEqRel(@as(f32, @floatCast(direct)), v, 1e-6);
    }
}

test "floor 0 decode adds the last value to each vector" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const books = [_]Codebook{try vtesting.parseBook(arena, vtesting.book_lattice)};
    const f: header.Floor0 = .{
        .order = 4,
        .rate = 44100,
        .bark_map_size = 64,
        .amplitude_bits = 6,
        .amplitude_offset = 100,
        .books = &.{0},
    };
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try w.writeBits(10, 6);
    try w.writeBits(0, 1);
    // entry 2 is (1, -1), entry 7 is (0, 1) and becomes (-1, 0)
    try vtesting.putCode(&w, books[0], 2);
    try vtesting.putCode(&w, books[0], 7);
    var r: io.LsbReader = .init(w.bytes());
    var coeffs: [4]f64 = undefined;
    var vec: [2]f32 = undefined;
    try testing.expectEqual(@as(?u32, 10), decodeFloor0(f, &books, &r, &coeffs, &vec));
    try testing.expectEqualSlices(f64, &.{ 1, -1, -1, 0 }, &coeffs);

    // an odd order drops the extra value of the last vector
    var odd = f;
    odd.order = 3;
    r = .init(w.bytes());
    var c3: [3]f64 = undefined;
    try testing.expectEqual(@as(?u32, 10), decodeFloor0(odd, &books, &r, &c3, &vec));
    try testing.expectEqualSlices(f64, &.{ 1, -1, -1 }, &c3);
}

test "floor 0 is unused for zero amplitude, a bad book number and a short packet" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const books = [_]Codebook{try vtesting.parseBook(arena, vtesting.book_lattice)};
    const f: header.Floor0 = .{
        .order = 4,
        .rate = 44100,
        .bark_map_size = 64,
        .amplitude_bits = 6,
        .amplitude_offset = 100,
        .books = &.{0},
    };
    var coeffs: [4]f64 = undefined;
    var vec: [2]f32 = undefined;
    var r: io.LsbReader = .init(&.{ 0, 0 });
    try testing.expectEqual(@as(?u32, null), decodeFloor0(f, &books, &r, &coeffs, &vec));
    // amplitude 1, book number 1 of 1 book
    r = .init(&.{ 0b0100_0001, 0 });
    try testing.expectEqual(@as(?u32, null), decodeFloor0(f, &books, &r, &coeffs, &vec));
    // amplitude 1, book 0, then no vector
    r = .init(&.{0b0000_0001});
    try testing.expectEqual(@as(?u32, null), decodeFloor0(f, &books, &r, &coeffs, &vec));
}

test "floor 0 curve of an odd order matches the formula by hand" {
    // order 1, map = 32 of 64 gives w = pi / 2 and cos w = 0, so p = 1, q = (cos c0)^2 = 0.25
    var map = [_]i32{ 32, 32, -1 };
    const f: header.Floor0 = .{
        .order = 1,
        .rate = 44100,
        .bark_map_size = 64,
        .amplitude_bits = 6,
        .amplitude_offset = 100,
        .books = &.{0},
    };
    var coeffs = [_]f64{std.math.pi / 3.0};
    var out: [2]f32 = undefined;
    floor0Curve(f, &map, 63, &coeffs, &out);
    const expect: f32 = @floatCast(@exp(0.11512925 * (100.0 / @sqrt(1.25) - 100.0)));
    try testing.expectApproxEqRel(expect, out[0], 1e-6);
    try testing.expectEqual(out[0], out[1]);
}

fn directCurve(f: header.Floor0, map: []const i32, amplitude: u32, c: []const f64, i: usize) f64 {
    const w = std.math.pi * @as(f64, @floatFromInt(map[i])) / @as(f64, @floatFromInt(f.bark_map_size));
    var p: f64 = 1;
    var q: f64 = 1;
    if (f.order % 2 == 1) {
        p = 1 - @cos(w) * @cos(w);
        q = 0.25;
        var j: usize = 0;
        while (j < (f.order - 1) / 2) : (j += 1) {
            p *= 4 * (@cos(c[2 * j + 1]) - @cos(w)) * (@cos(c[2 * j + 1]) - @cos(w));
        }
        j = 0;
        while (j < (f.order + 1) / 2) : (j += 1) {
            q *= 4 * (@cos(c[2 * j]) - @cos(w)) * (@cos(c[2 * j]) - @cos(w));
        }
    } else {
        p = (1 - @cos(w)) / 2;
        q = (1 + @cos(w)) / 2;
        var j: usize = 0;
        while (j <= (f.order - 2) / 2) : (j += 1) {
            p *= 4 * (@cos(c[2 * j + 1]) - @cos(w)) * (@cos(c[2 * j + 1]) - @cos(w));
            q *= 4 * (@cos(c[2 * j]) - @cos(w)) * (@cos(c[2 * j]) - @cos(w));
        }
    }
    const off: f64 = @floatFromInt(f.amplitude_offset);
    const full: f64 = @floatFromInt((@as(u64, 1) << @intCast(f.amplitude_bits)) - 1);
    return @exp(0.11512925 * (@as(f64, @floatFromInt(amplitude)) * off / (full * @sqrt(p + q)) - off));
}

test "floor 0 curve matches the direct formula for odd and even orders" {
    var f: header.Floor0 = .{
        .order = 6,
        .rate = 32000,
        .bark_map_size = 40,
        .amplitude_bits = 7,
        .amplitude_offset = 80,
        .books = &.{0},
    };
    const c = [_]f64{ 0.3, 0.9, 1.2, 1.7, 2.2, 2.8, 3.0 };
    var map: [65]i32 = undefined;
    barkMap(f, &map);
    try testing.expectEqual(@as(i32, -1), map[64]);
    try testing.expectEqual(@as(i32, 0), map[0]);
    try testing.expectEqual(@as(i32, 39), map[63]);
    for (map[1..64], map[0..63]) |next, prev| try testing.expect(next >= prev);
    for ([_]u8{ 6, 7 }) |order| {
        f.order = order;
        var work = c;
        var out: [64]f32 = undefined;
        floor0Curve(f, &map, 90, &work, &out);
        for (out, 0..) |v, i| {
            const want: f32 = @floatCast(directCurve(f, &map, 90, &c, i));
            try testing.expectApproxEqRel(want, v, 1e-5);
        }
    }
}

test "bark map follows the bark formula" {
    const f: header.Floor0 = .{
        .order = 2,
        .rate = 44100,
        .bark_map_size = 100,
        .amplitude_bits = 6,
        .amplitude_offset = 1,
        .books = &.{0},
    };
    var map: [257]i32 = undefined;
    barkMap(f, &map);
    // line 128 is 11025 Hz
    const want: i32 = @intFromFloat(@floor(bark(11025.0) * 100.0 / bark(22050.0)));
    try testing.expectEqual(want, map[128]);
    try testing.expect(want > 60 and want < 99);
}

test "floor scratch sizes follow the setup" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const packet = try vtesting.buildSetup(testing.allocator, .{});
    defer testing.allocator.free(packet);
    const setup = try header.Setup.parse(arena_state.allocator(), packet, 2, 1 << 20);
    try testing.expectEqual(Scratch{ .points = 4, .coeffs = 0, .vec = 0 }, scratch(&setup));
    const packet0 = try vtesting.buildSetup(testing.allocator, .{ .floor_type = 0 });
    defer testing.allocator.free(packet0);
    const setup0 = try header.Setup.parse(arena_state.allocator(), packet0, 2, 1 << 20);
    try testing.expectEqual(Scratch{ .points = 0, .coeffs = 8, .vec = 2 }, scratch(&setup0));
}

const swapped_x = [_]u16{ 0, 64, 40, 20 };
const swapped_low = [_]u8{ 0, 0, 0, 0 };
const swapped_high = [_]u8{ 0, 0, 1, 2 };
const swapped_order = [_]u8{ 0, 3, 2, 1 };

test "floor 1 nonzero post turns on the flag of its low neighbour" {
    // Post 2 is zero and post 3 is not, and post 2 is the low neighbour of post 3.
    // x 20 predicts 38, x 40 then predicts 10 + (62 * 20) / 44 = 38 + 28 = 66, and 1 gives 65.
    try runFloor1Case(testFloor1(), .{ .y0 = 10, .y1 = 100, .a = 0, .b = 1, .expect = .{ 10, 100, 38, 65 }, .flags = .{ true, true, true, true } });
}

test "floor 1 nonzero post turns on the flag of its high neighbour" {
    var f = testFloor1();
    f.x = &swapped_x;
    f.low = &swapped_low;
    f.high = &swapped_high;
    f.order = &swapped_order;
    // Post 2 (x 40) predicts 10 + 90 * 40 / 64 = 66 and is zero. Post 3 (x 20) has post 2 as its
    // high neighbour, predicts 10 + 56 * 20 / 40 = 38 and gives 38 - 1.
    try runFloor1Case(f, .{ .y0 = 10, .y1 = 100, .a = 0, .b = 1, .expect = .{ 10, 100, 66, 37 }, .flags = .{ true, true, true, true } });
}

test "floor 1 value equal to the room takes the room branch" {
    // The prediction is 72 and the high room 56, so the room is 112. The value 112 gives
    // 72 - 112 + 56 - 1. The next post predicts 15 - 5 * 20 / 44 = 15 - 2.
    try runFloor1Case(testFloor1(), .{ .y0 = 100, .y1 = 10, .a = 112, .b = 0, .expect = .{ 100, 10, 15, 13 }, .flags = .{ true, true, true, false } });
}

test "floor 1 class with four subclasses selects books by the master value" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const master: [16]u8 = @splat(4);
    const narrow: [64]u8 = @splat(6);
    const books = [_]Codebook{
        try vtesting.parseBook(arena, .{ .lengths = &master }),
        try vtesting.parseBook(arena, .{ .lengths = &wide_lengths }),
        try vtesting.parseBook(arena, .{ .lengths = &narrow }),
    };
    const classes = [_]header.Floor1Class{.{
        .dimensions = 2,
        .subclasses = 2,
        .masterbook = 0,
        .subclass_books = .{ -1, 1, 2, -1, -1, -1, -1, -1 },
    }};
    var f = testFloor1();
    f.classes = &classes;
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try w.writeBits(1, 1);
    try w.writeBits(10, 7);
    try w.writeBits(100, 7);
    // 9 is 0b1001: the first Y uses subclass 1, the second uses subclass 2
    try vtesting.putCode(&w, books[0], 9);
    try vtesting.putCode(&w, books[1], 3);
    try vtesting.putCode(&w, books[2], 1);
    var r: io.LsbReader = .init(w.bytes());
    var y: [4]i32 = undefined;
    var flags: [4]bool = undefined;
    try testing.expect(decodeFloor1(f, &books, &r, &y, &flags));
    try testing.expectEqualSlices(i32, &.{ 10, 100, 36, 64 }, &y);
    try testing.expectEqual(w.nbits, r.pos);
}

test "render line steps when the error equals the width" {
    var out: [4]f32 = undefined;
    // 0 to 2 over 4: base 0, step 1, error 2 then 4. The step comes at an error of exactly 4.
    floor1Curve(lineFloor(1, 4), &.{ 0, 2 }, &.{ true, true }, &out);
    for (out, [_]usize{ 0, 0, 1, 1 }) |v, level| try testing.expectEqual(inverse_db[level], v);
}

test "floor 0 carries the running sum over three vectors" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const books = [_]Codebook{try vtesting.parseBook(arena, vtesting.book_lattice)};
    const f: header.Floor0 = .{
        .order = 6,
        .rate = 44100,
        .bark_map_size = 64,
        .amplitude_bits = 6,
        .amplitude_offset = 100,
        .books = &.{0},
    };
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try w.writeBits(10, 6);
    try w.writeBits(0, 1);
    // (1, -1) then (0, 1) + -1 = (-1, 0), the sum is now 0, then (1, -1) + 0
    try vtesting.putCode(&w, books[0], 2);
    try vtesting.putCode(&w, books[0], 7);
    try vtesting.putCode(&w, books[0], 2);
    var r: io.LsbReader = .init(w.bytes());
    var coeffs: [6]f64 = undefined;
    var vec: [2]f32 = undefined;
    try testing.expectEqual(@as(?u32, 10), decodeFloor0(f, &books, &r, &coeffs, &vec));
    try testing.expectEqualSlices(f64, &.{ 1, -1, -1, 0, 1, -1 }, &coeffs);
}
