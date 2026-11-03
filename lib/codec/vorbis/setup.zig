//! The Vorbis headers that the encoder writes. `writeSetup` is the inverse of `Setup.parse`.
//! `build` makes the setup that the encoder uses, with its own codebooks.
const std = @import("std");
const io = @import("../io.zig");
const codebook = @import("codebook.zig");
const header = @import("header.zig");
const Codebook = codebook.Codebook;
const ilog = codebook.ilog;

pub const WriteError = error{ OutOfMemory, BadSetup };

const sync_pattern = 0x564342;

/// Packs a whole number in the float32 form of the codebooks.
pub fn packInt(value: i32) u32 {
    const sign: u32 = if (value < 0) 0x80000000 else 0;
    return sign | (788 << 21) | @abs(value);
}

/// The 30 bytes of the identification header.
pub fn writeIdentification(id: header.Identification) [30]u8 {
    var p: [30]u8 = @splat(0);
    p[0] = 1;
    @memcpy(p[1..7], "vorbis");
    p[11] = id.channels;
    std.mem.writeInt(u32, p[12..16], id.rate, .little);
    std.mem.writeInt(i32, p[16..20], id.bitrate_maximum, .little);
    std.mem.writeInt(i32, p[20..24], id.bitrate_nominal, .little);
    std.mem.writeInt(i32, p[24..28], id.bitrate_minimum, .little);
    p[28] = @as(u8, std.math.log2_int(u16, id.blocksize_1)) << 4 | std.math.log2_int(u16, id.blocksize_0);
    p[29] = 1;
    return p;
}

/// A comment header with the vendor string and no comments. The caller frees the result.
pub fn writeComment(gpa: std.mem.Allocator, vendor: []const u8) error{OutOfMemory}![]u8 {
    const out = try gpa.alloc(u8, 7 + 4 + vendor.len + 4 + 1);
    out[0] = 3;
    @memcpy(out[1..7], "vorbis");
    std.mem.writeInt(u32, out[7..11], @intCast(vendor.len), .little);
    @memcpy(out[11..][0..vendor.len], vendor);
    std.mem.writeInt(u32, out[11 + vendor.len ..][0..4], 0, .little);
    out[out.len - 1] = 1;
    return out;
}

/// Writes the setup packet for `setup`. It reads back with `Setup.parse` to the same
/// structure, and the packet of a parsed libvorbis setup comes back with the same bytes.
/// The caller frees the result.
pub fn writeSetup(gpa: std.mem.Allocator, setup: *const header.Setup) WriteError![]u8 {
    var w: io.LsbWriter = .init(gpa);
    errdefer w.deinit();
    try w.writeBits(5, 8);
    for ("vorbis") |c| try w.writeBits(c, 8);

    if (setup.books.len == 0 or setup.books.len > header.max_books) return error.BadSetup;
    try w.writeBits(@intCast(setup.books.len - 1), 8);
    for (setup.books) |*book| try writeBook(&w, book);

    // One time domain entry, which is always 0.
    try w.writeBits(0, 6);
    try w.writeBits(0, 16);

    try writeCount(&w, setup.floors.len);
    for (setup.floors) |floor| switch (floor) {
        .zero => |f| try writeFloor0(&w, f),
        .one => |f| try writeFloor1(&w, f),
    };
    try writeCount(&w, setup.residues.len);
    for (setup.residues) |res| try writeResidue(&w, res);
    try writeCount(&w, setup.mappings.len);
    for (setup.mappings) |m| try writeMapping(&w, m, setup.channels);
    try writeCount(&w, setup.modes.len);
    for (setup.modes) |mode| {
        try w.writeBits(@intFromBool(mode.long), 1);
        try w.writeBits(0, 16);
        try w.writeBits(0, 16);
        try w.writeBits(mode.mapping, 8);
    }
    try w.writeBits(1, 1);
    return w.list.toOwnedSlice(gpa);
}

fn writeCount(w: *io.LsbWriter, n: usize) WriteError!void {
    if (n == 0 or n > 64) return error.BadSetup;
    try w.writeBits(@intCast(n - 1), 6);
}

/// Writes one codebook. The lengths are written in the runs form when they never decrease
/// and none is 0, and in the sparse form when some entry is unused, as libvorbis does.
pub fn writeBook(w: *io.LsbWriter, book: *const Codebook) WriteError!void {
    const entries = book.lengths.len;
    if (entries >= 1 << 24) return error.BadSetup;
    try w.writeBits(sync_pattern, 24);
    try w.writeBits(book.dimensions, 16);
    try w.writeBits(@intCast(entries), 24);

    var ordered = entries > 0 and book.lengths[0] != 0;
    for (1..entries) |i| {
        if (book.lengths[i - 1] == 0 or book.lengths[i] < book.lengths[i - 1]) ordered = false;
    }
    if (ordered) {
        if (book.lengths[entries - 1] > 32) return error.BadSetup;
        try w.writeBits(1, 1);
        try w.writeBits(book.lengths[0] - 1, 5);
        var count: usize = 0;
        for (1..entries) |i| {
            const last = book.lengths[i - 1];
            const this = book.lengths[i];
            if (this > last) {
                for (last..this) |_| {
                    try w.writeBits(@intCast(i - count), ilog(@intCast(entries - count)));
                    count = i;
                }
            }
        }
        try w.writeBits(@intCast(entries - count), ilog(@intCast(entries - count)));
    } else {
        try w.writeBits(0, 1);
        var sparse = false;
        for (book.lengths) |len| sparse = sparse or len == 0;
        try w.writeBits(@intFromBool(sparse), 1);
        for (book.lengths) |len| {
            if (len > 32) return error.BadSetup;
            if (sparse) try w.writeBits(@intFromBool(len != 0), 1);
            if (len != 0) try w.writeBits(len - 1, 5);
        }
    }

    try w.writeBits(@backingInt(book.lookup), 4);
    if (book.lookup == .none) return;
    if (book.value_bits < 1 or book.value_bits > 16) return error.BadSetup;
    if (book.multiplicands.len != book.lookup_values) return error.BadSetup;
    try w.writeBits(book.minimum_packed, 32);
    try w.writeBits(book.delta_packed, 32);
    try w.writeBits(book.value_bits - 1, 4);
    try w.writeBits(@intFromBool(book.sequence_p), 1);
    for (book.multiplicands) |m| {
        if (m >= @as(u32, 1) << @intCast(book.value_bits)) return error.BadSetup;
        try w.writeBits(m, @intCast(book.value_bits));
    }
}

fn writeFloor0(w: *io.LsbWriter, f: header.Floor0) WriteError!void {
    if (f.books.len == 0 or f.books.len > 16 or f.amplitude_bits > 63) return error.BadSetup;
    try w.writeBits(0, 16);
    try w.writeBits(f.order, 8);
    try w.writeBits(f.rate, 16);
    try w.writeBits(f.bark_map_size, 16);
    try w.writeBits(f.amplitude_bits, 6);
    try w.writeBits(f.amplitude_offset, 8);
    try w.writeBits(@intCast(f.books.len - 1), 4);
    for (f.books) |b| try w.writeBits(b, 8);
}

fn writeFloor1(w: *io.LsbWriter, f: header.Floor1) WriteError!void {
    if (f.partition_classes.len > 31 or f.multiplier < 1 or f.multiplier > 4 or f.rangebits > 15) return error.BadSetup;
    if (f.x.len < 2) return error.BadSetup;
    try w.writeBits(1, 16);
    try w.writeBits(@intCast(f.partition_classes.len), 5);
    for (f.partition_classes) |c| {
        if (c >= f.classes.len) return error.BadSetup;
        try w.writeBits(c, 4);
    }
    for (f.classes) |class| {
        if (class.dimensions < 1 or class.dimensions > 8 or class.subclasses > 3) return error.BadSetup;
        try w.writeBits(class.dimensions - 1, 3);
        try w.writeBits(class.subclasses, 2);
        if (class.subclasses != 0) try w.writeBits(class.masterbook, 8);
        for (class.subclass_books[0 .. @as(usize, 1) << @intCast(class.subclasses)]) |b| {
            if (b < -1 or b > 254) return error.BadSetup;
            try w.writeBits(@intCast(b + 1), 8);
        }
    }
    try w.writeBits(f.multiplier - 1, 2);
    try w.writeBits(f.rangebits, 4);
    for (f.x[2..]) |x| {
        if (x >= @as(u32, 1) << @intCast(f.rangebits)) return error.BadSetup;
        try w.writeBits(x, @intCast(f.rangebits));
    }
}

fn writeResidue(w: *io.LsbWriter, res: header.Residue) WriteError!void {
    if (res.kind > 2 or res.classifications == 0 or res.classifications > header.max_residue_classes) return error.BadSetup;
    if (res.books.len != res.classifications or res.partition_size == 0) return error.BadSetup;
    if (res.begin >= 1 << 24 or res.end >= 1 << 24 or res.partition_size > 1 << 24) return error.BadSetup;
    try w.writeBits(res.kind, 16);
    try w.writeBits(res.begin, 24);
    try w.writeBits(res.end, 24);
    try w.writeBits(res.partition_size - 1, 24);
    try w.writeBits(res.classifications - 1, 6);
    try w.writeBits(res.classbook, 8);
    for (res.books) |row| {
        var cascade: u32 = 0;
        for (row, 0..) |b, pass| {
            if (b >= 0) cascade |= @as(u32, 1) << @intCast(pass);
        }
        try w.writeBits(cascade & 7, 3);
        try w.writeBits(@intFromBool(cascade >> 3 != 0), 1);
        if (cascade >> 3 != 0) try w.writeBits(cascade >> 3, 5);
    }
    for (res.books) |row| {
        for (row) |b| {
            if (b >= 0) try w.writeBits(@intCast(b), 8);
        }
    }
}

fn writeMapping(w: *io.LsbWriter, m: header.Mapping, channels: u8) WriteError!void {
    if (m.submaps.len == 0 or m.submaps.len > 16 or m.mux.len != channels) return error.BadSetup;
    if (m.coupling.len > 256) return error.BadSetup;
    try w.writeBits(0, 16);
    try w.writeBits(@intFromBool(m.submaps.len > 1), 1);
    if (m.submaps.len > 1) try w.writeBits(@intCast(m.submaps.len - 1), 4);
    try w.writeBits(@intFromBool(m.coupling.len > 0), 1);
    if (m.coupling.len > 0) {
        try w.writeBits(@intCast(m.coupling.len - 1), 8);
        const width = ilog(channels - 1);
        for (m.coupling) |c| {
            try w.writeBits(c.magnitude, width);
            try w.writeBits(c.angle, width);
        }
    }
    try w.writeBits(0, 2);
    if (m.submaps.len > 1) {
        for (m.mux) |v| try w.writeBits(v, 4);
    }
    for (m.submaps) |s| {
        try w.writeBits(0, 8);
        try w.writeBits(s.floor, 8);
        try w.writeBits(s.residue, 8);
    }
}

const no_parent = std.math.maxInt(u32);

/// Sets `out` to the lengths of a Huffman code for `weights`. The tree is complete and no
/// length passes 32. Equal weights give the same lengths on every run.
pub fn huffmanLengths(gpa: std.mem.Allocator, weights: []const f64, out: []u8) error{OutOfMemory}!void {
    std.debug.assert(weights.len >= 2 and weights.len == out.len);
    const n = weights.len;
    const weight = try gpa.alloc(f64, 2 * n - 1);
    defer gpa.free(weight);
    const parent = try gpa.alloc(u32, 2 * n - 1);
    defer gpa.free(parent);

    var heaviest: f64 = 0;
    for (weights) |w| heaviest = @max(heaviest, w);
    const base = heaviest * 0x1p-20;
    var least = base;
    while (true) {
        for (weights, 0..) |w, i| weight[i] = @max(w, least);
        @memset(parent, no_parent);
        for (n..2 * n - 1) |count| {
            var first: usize = no_parent;
            var second: usize = no_parent;
            for (0..count) |i| {
                if (parent[i] != no_parent) continue;
                if (first == no_parent or weight[i] < weight[first]) {
                    second = first;
                    first = i;
                } else if (second == no_parent or weight[i] < weight[second]) {
                    second = i;
                }
            }
            weight[count] = weight[first] + weight[second];
            parent[first] = @intCast(count);
            parent[second] = @intCast(count);
        }
        var deepest: u32 = 0;
        for (out, 0..) |*len, i| {
            var depth: u32 = 0;
            var at: usize = i;
            while (parent[at] != no_parent) : (at = parent[at]) depth += 1;
            len.* = @intCast(@min(depth, 255));
            deepest = @max(deepest, depth);
        }
        if (deepest <= 32) return;
        least *= 16;
    }
}

/// The long block size for a sample rate.
pub fn blocksizeFor(rate: u32) u16 {
    if (rate >= 32000) return 2048;
    if (rate >= 16000) return 1024;
    return 512;
}

/// The short block size that goes with a long one.
pub fn shortBlocksizeFor(long: u16) u16 {
    return @max(long / 8, 128);
}

/// What a quality level sets.
pub const Tuning = struct {
    /// The distance in dB from the masking level down to the floor. A smaller margin
    /// gives a finer residue and more bits.
    margin_db: f32,
    /// The highest frequency that is coded.
    lowpass_hz: f32,
    /// The sound pressure level in dB of a full scale sine. A louder playback makes more of the
    /// quiet parts audible.
    listen_spl: f32,
    /// The number of residue classes. A quality that needs fewer levels has a smaller setup.
    classes: u8,
    /// A floor post within this many steps of its prediction is not coded.
    tolerance: u8,

    /// The first spectrum line above the lowpass.
    pub fn endLines(self: Tuning, rate: u32, lines: u32) u32 {
        const nyquist: f32 = @floatFromInt(rate / 2);
        if (self.lowpass_hz >= nyquist) return lines;
        const end: u32 = @intFromFloat(@ceil(self.lowpass_hz / nyquist * @as(f32, @floatFromInt(lines))));
        return @min(lines, end);
    }

    /// The largest level that one channel codes. Coupling can double a level.
    pub fn levelLimit(self: Tuning) f32 {
        return @floatFromInt(class_limits[self.classes - 1] / 2);
    }
};

const QualityRow = struct { margin_db: f32, lowpass_hz: f32, listen_spl: f32, classes: u8 };

/// The rows for the qualities -1 to 10. A quality between two rows mixes them.
const quality_rows = [_]QualityRow{
    .{ .margin_db = 6.0, .lowpass_hz = 13000, .listen_spl = 80, .classes = 7 },
    .{ .margin_db = 8.2, .lowpass_hz = 14000, .listen_spl = 83, .classes = 7 },
    .{ .margin_db = 10.4, .lowpass_hz = 15000, .listen_spl = 86, .classes = 7 },
    .{ .margin_db = 12.6, .lowpass_hz = 16000, .listen_spl = 89, .classes = 7 },
    .{ .margin_db = 14.8, .lowpass_hz = 17000, .listen_spl = 92, .classes = 8 },
    .{ .margin_db = 17.0, .lowpass_hz = 18000, .listen_spl = 95, .classes = 8 },
    .{ .margin_db = 19.2, .lowpass_hz = 19000, .listen_spl = 98, .classes = 8 },
    .{ .margin_db = 21.4, .lowpass_hz = 20000, .listen_spl = 101, .classes = 8 },
    .{ .margin_db = 23.6, .lowpass_hz = 21000, .listen_spl = 104, .classes = 9 },
    .{ .margin_db = 25.8, .lowpass_hz = 22000, .listen_spl = 107, .classes = 9 },
    .{ .margin_db = 28.0, .lowpass_hz = 23000, .listen_spl = 110, .classes = 9 },
    .{ .margin_db = 30.2, .lowpass_hz = 24000, .listen_spl = 113, .classes = 9 },
};

/// The quality scale is the one of oggenc, -1 to 10. A value outside it is clamped.
pub fn tuning(quality: f32) Tuning {
    const pos = std.math.clamp(if (std.math.isNan(quality)) 4 else quality, -1, 10) + 1;
    const index: usize = @min(@as(usize, @intFromFloat(pos)), quality_rows.len - 2);
    const t = pos - @as(f32, @floatFromInt(index));
    const lo = quality_rows[index];
    const hi = quality_rows[index + 1];
    return .{
        .margin_db = lo.margin_db + t * (hi.margin_db - lo.margin_db),
        .lowpass_hz = lo.lowpass_hz + t * (hi.lowpass_hz - lo.lowpass_hz),
        .listen_spl = lo.listen_spl + t * (hi.listen_spl - lo.listen_spl),
        .classes = if (t == 0) lo.classes else hi.classes,
        .tolerance = 1,
    };
}

pub const Design = struct {
    channels: u8,
    rate: u32,
    quality: f32,
};

pub const Built = struct {
    id: header.Identification,
    setup: header.Setup,
    /// What the quality sets.
    tuning: Tuning,
};

const FloorLayout = struct {
    rangebits: u8,
    partition_classes: []const u8,
    class_dims: []const u8,
    class_subs: []const u8,
    /// The X values after the two implicit ones.
    x: []const u16,
};

const layout_1024: FloorLayout = .{
    .rangebits = 10,
    .partition_classes = &.{ 0, 1, 2, 2, 3, 3, 4, 4 },
    .class_dims = &.{ 3, 4, 3, 4, 3 },
    .class_subs = &.{ 0, 1, 1, 2, 2 },
    .x = &.{ 93, 23, 372, 6, 46, 186, 750, 14, 33, 65, 130, 260, 556, 3, 10, 18, 28, 39, 55, 79, 111, 158, 220, 312, 464, 650, 850 },
};

const layout_512: FloorLayout = .{
    .rangebits = 9,
    .partition_classes = &.{ 0, 1, 1, 2, 3, 3 },
    .class_dims = &.{ 2, 3, 3, 3 },
    .class_subs = &.{ 0, 1, 2, 2 },
    .x = &.{ 46, 186, 16, 33, 65, 93, 130, 278, 7, 23, 39, 55, 79, 110, 156, 232, 360 },
};

const layout_256: FloorLayout = .{
    .rangebits = 8,
    .partition_classes = &.{ 0, 1, 1, 2, 3, 3 },
    .class_dims = &.{ 2, 3, 3, 3 },
    .class_subs = &.{ 0, 1, 2, 2 },
    .x = &.{ 24, 92, 8, 16, 32, 46, 66, 140, 4, 12, 20, 28, 38, 56, 78, 116, 180 },
};

const layout_128: FloorLayout = .{
    .rangebits = 7,
    .partition_classes = &.{ 0, 1, 1, 2, 3, 3 },
    .class_dims = &.{ 2, 3, 3, 3 },
    .class_subs = &.{ 0, 1, 2, 2 },
    .x = &.{ 12, 46, 4, 8, 16, 23, 33, 70, 2, 6, 10, 14, 19, 28, 39, 58, 90 },
};

const layout_64: FloorLayout = .{
    .rangebits = 6,
    .partition_classes = &.{ 0, 1, 1, 2, 3, 3 },
    .class_dims = &.{ 2, 3, 3, 3 },
    .class_subs = &.{ 0, 1, 2, 2 },
    .x = &.{ 6, 23, 2, 4, 8, 11, 16, 35, 1, 3, 5, 7, 9, 14, 19, 29, 45 },
};

/// The floor layout for a block of `lines` spectrum lines.
fn layoutFor(lines: u32) FloorLayout {
    return switch (lines) {
        1024 => layout_1024,
        512 => layout_512,
        256 => layout_256,
        128 => layout_128,
        else => layout_64,
    };
}

/// The largest |q| that each residue class holds, class 0 being all zero. A class with a
/// larger limit uses a lattice book of the given dimension.
const class_limits = [_]u16{ 0, 1, 2, 4, 8, 16, 40, 128, 511 };
const class_dims = [_]u16{ 0, 4, 2, 2, 2, 2, 1, 1, 1 };
const classes_per_word = 2;

fn couplingPairs(channels: u8) []const [2]u8 {
    return switch (channels) {
        2 => &.{.{ 0, 1 }},
        3 => &.{.{ 0, 2 }},
        4 => &.{ .{ 0, 1 }, .{ 2, 3 } },
        5, 6, 7 => &.{ .{ 0, 2 }, .{ 3, 4 } },
        8 => &.{ .{ 0, 2 }, .{ 3, 4 }, .{ 5, 6 } },
        else => &.{},
    };
}

const BuildError = error{ OutOfMemory, BadSetup };

const Books = struct {
    arena: std.mem.Allocator,
    budget: codebook.Budget = .{ .max = 1 << 28 },
    list: std.ArrayList(Codebook) = .empty,

    fn add(self: *Books, book: Codebook) BuildError!u8 {
        if (self.list.items.len >= header.max_books) return error.BadSetup;
        try self.list.append(self.arena, book);
        return @intCast(self.list.items.len - 1);
    }

    fn scalar(self: *Books, dimensions: u16, weights: []const f64) BuildError!u8 {
        const lengths = try self.arena.alloc(u8, weights.len);
        try huffmanLengths(self.arena, weights, lengths);
        const book = Codebook.build(self.arena, &self.budget, .{ .dimensions = dimensions, .lengths = lengths }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadHeader => return error.BadSetup,
        };
        return self.add(book);
    }

    /// A lattice book of `dimensions` values in -k to k, with short codes for small values.
    fn lattice(self: *Books, dimensions: u16, k: u16) BuildError!u8 {
        const base: usize = 2 * @as(usize, k) + 1;
        var entries: usize = 1;
        for (0..dimensions) |_| entries *= base;
        const weights = try self.arena.alloc(f64, entries);
        const scale = @max(0.4, 0.4 * @as(f64, @floatFromInt(k)));
        for (weights, 0..) |*w, entry| {
            var rest = entry;
            var total: f64 = 0;
            for (0..dimensions) |_| {
                const digit: i64 = @intCast(rest % base);
                rest /= base;
                total += @floatFromInt(@abs(digit - k));
            }
            w.* = @exp(-total / scale);
        }
        const lengths = try self.arena.alloc(u8, entries);
        try huffmanLengths(self.arena, weights, lengths);
        const multiplicands = try self.arena.alloc(u16, base);
        for (multiplicands, 0..) |*m, i| m.* = @intCast(i);
        const book = Codebook.build(self.arena, &self.budget, .{
            .dimensions = dimensions,
            .lengths = lengths,
            .lookup = .lattice,
            .minimum_packed = packInt(-@as(i32, k)),
            .delta_packed = packInt(1),
            .value_bits = ilog(2 * @as(u32, k)),
            .multiplicands = multiplicands,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadHeader => return error.BadSetup,
        };
        return self.add(book);
    }
};

/// The weights of the wrapped floor values 0 to `entries - 1`, small values first.
fn floorWeights(arena: std.mem.Allocator, entries: usize) error{OutOfMemory}![]f64 {
    const weights = try arena.alloc(f64, entries);
    for (weights, 0..) |*w, v| w.* = if (v == 0) 3 else @exp(-0.18 * @as(f64, @floatFromInt(v)));
    return weights;
}

/// How often each subclass is picked, for the weights of a master book.
fn subclassPrior(subclasses: u8, sub: usize) f64 {
    return switch (subclasses) {
        1 => ([_]f64{ 0.9, 0.1 })[sub],
        else => ([_]f64{ 0.4, 0.3, 0.25, 0.05 })[sub],
    };
}

const Master = struct { dimensions: u8, subclasses: u8, book: u8 };

/// The books of the floors. Every floor shares the value books and the master books.
const FloorBooks = struct {
    full: u8,
    mid: u8,
    small: u8,
    masters: [8]Master = undefined,
    master_count: usize = 0,

    fn init(arena: std.mem.Allocator, books: *Books) BuildError!FloorBooks {
        return .{
            .full = try books.scalar(1, try floorWeights(arena, 128)),
            .mid = try books.scalar(1, try floorWeights(arena, 32)),
            .small = try books.scalar(1, try floorWeights(arena, 8)),
        };
    }
};

fn buildFloor(arena: std.mem.Allocator, books: *Books, shared: *FloorBooks, layout: FloorLayout) BuildError!header.Floor1 {
    const full = shared.full;
    const mid = shared.mid;
    const small = shared.small;

    const classes = try arena.alloc(header.Floor1Class, layout.class_dims.len);
    for (classes, layout.class_dims, layout.class_subs) |*class, dims, subs| {
        class.* = .{ .dimensions = dims, .subclasses = subs, .masterbook = 0, .subclass_books = @splat(-1) };
        switch (subs) {
            0 => class.subclass_books[0] = full,
            1 => class.subclass_books[0..2].* = .{ mid, full },
            else => class.subclass_books[0..4].* = .{ -1, small, mid, full },
        }
        if (subs == 0) continue;
        var found = false;
        for (shared.masters[0..shared.master_count]) |m| {
            if (m.dimensions == dims and m.subclasses == subs) {
                class.masterbook = m.book;
                found = true;
            }
        }
        if (found) continue;
        const entries = @as(usize, 1) << @intCast(@as(usize, dims) * subs);
        const weights = try arena.alloc(f64, entries);
        for (weights, 0..) |*w, cval| {
            w.* = 1;
            for (0..dims) |post| {
                const sub = (cval >> @intCast(post * subs)) & ((@as(usize, 1) << @intCast(subs)) - 1);
                w.* *= subclassPrior(subs, sub);
            }
        }
        class.masterbook = try books.scalar(1, weights);
        shared.masters[shared.master_count] = .{ .dimensions = dims, .subclasses = subs, .book = class.masterbook };
        shared.master_count += 1;
    }

    const count = layout.x.len + 2;
    const x = try arena.alloc(u16, count);
    x[0] = 0;
    x[1] = @as(u16, 1) << @intCast(layout.rangebits);
    @memcpy(x[2..], layout.x);
    const order = try arena.alloc(u8, count);
    const low = try arena.alloc(u8, count);
    const high = try arena.alloc(u8, count);
    header.floor1Neighbours(x, order, low, high);
    return .{
        .partition_classes = layout.partition_classes,
        .classes = classes,
        .multiplier = 2,
        .rangebits = layout.rangebits,
        .x = x,
        .order = order,
        .low = low,
        .high = high,
    };
}

/// The chance that a partition of `size` values falls in class `class`, if the values
/// follow a Laplace law that the floor margin sets.
fn classPrior(margin_db: f32, size: u32, class: usize) f64 {
    const scale = 0.6 * std.math.pow(f64, 10, margin_db / 20.0);
    const below = if (class == 0) 0.0 else partitionFits(scale, size, class_limits[class - 1]);
    return @max(1e-3, partitionFits(scale, size, class_limits[class]) - below);
}

fn partitionFits(scale: f64, size: u32, limit: u16) f64 {
    const one = 1 - @exp(-(@as(f64, @floatFromInt(limit)) + 0.5) / scale);
    return std.math.pow(f64, one, @floatFromInt(size));
}

/// The residue partition size. Residue 2 puts the channels side by side, and libvorbis
/// expects a partition to start at the first channel of a frame, so the size is a multiple of
/// the channel count. It is also a multiple of 4, the dimension of the biggest book, and it
/// divides the number of values of a block, so that the last partition is whole.
fn partitionSize(channels: u8, lines: u32) u32 {
    const count: u32 = channels;
    const wanted: u32 = if (lines >= 1024) 32 else 16;
    var size = count / std.math.gcd(count, 4) * 4;
    while (@abs(@as(i32, @intCast(size * 2)) - @as(i32, @intCast(wanted))) < @abs(@as(i32, @intCast(wanted)) - @as(i32, @intCast(size)))) size *= 2;
    return size;
}

/// The floor and the residue of one block size.
const SizeSetup = struct {
    floor: header.Floor1,
    residue: header.Residue,
};

fn buildSize(
    arena: std.mem.Allocator,
    books: *Books,
    shared: *FloorBooks,
    stage_books: []const [8]i16,
    d: Design,
    tun: Tuning,
    blocksize: u16,
) BuildError!SizeSetup {
    const lines: u32 = blocksize / 2;
    const floor = try buildFloor(arena, books, shared, layoutFor(lines));

    const classes: usize = tun.classes;
    const partition_size = partitionSize(d.channels, lines);
    const words = std.math.pow(usize, classes, classes_per_word);
    const word_weights = try arena.alloc(f64, words);
    for (word_weights, 0..) |*w, word| {
        w.* = 1;
        var rest = word;
        for (0..classes_per_word) |_| {
            w.* *= classPrior(tun.margin_db, partition_size, rest % classes);
            rest /= classes;
        }
    }
    const classbook = try books.scalar(classes_per_word, word_weights);

    const total: u32 = lines * d.channels;
    const wanted = tun.endLines(d.rate, lines) * d.channels;
    const end = @min(total, (wanted + partition_size - 1) / partition_size * partition_size);
    return .{
        .floor = floor,
        .residue = .{
            .kind = 2,
            .begin = 0,
            .end = end,
            .partition_size = partition_size,
            .classifications = tun.classes,
            .classbook = classbook,
            .books = stage_books,
        },
    };
}

/// Makes the identification and setup for the encoder: a short and a long block size, each
/// with its own mode, mapping, floor 1 and residue 2 over all channels in one submap, and
/// lossless coupling of pairs. Mode 0 is the short block, mode 1 the long one. All memory
/// comes from `arena`.
pub fn build(arena: std.mem.Allocator, d: Design) BuildError!Built {
    if (d.channels == 0 or d.rate == 0) return error.BadSetup;
    const long = blocksizeFor(d.rate);
    const short = shortBlocksizeFor(long);
    const tun = tuning(d.quality);
    var books: Books = .{ .arena = arena };

    var shared: FloorBooks = try .init(arena, &books);
    const stage_books = try arena.alloc([8]i16, tun.classes);
    for (stage_books, 0..) |*row, c| {
        row.* = @splat(-1);
        if (c == 0) continue;
        row[0] = try books.lattice(class_dims[c], class_limits[c]);
    }
    const small = try buildSize(arena, &books, &shared, stage_books, d, tun, short);
    const big = try buildSize(arena, &books, &shared, stage_books, d, tun, long);

    const pairs = couplingPairs(d.channels);
    const coupling = try arena.alloc(header.Coupling, pairs.len);
    for (coupling, pairs) |*c, p| c.* = .{ .magnitude = p[0], .angle = p[1] };
    const mux = try arena.alloc(u8, d.channels);
    @memset(mux, 0);

    const floors = try arena.alloc(header.Floor, 2);
    floors[0] = .{ .one = small.floor };
    floors[1] = .{ .one = big.floor };
    const residues = try arena.alloc(header.Residue, 2);
    residues[0] = small.residue;
    residues[1] = big.residue;
    const submaps = try arena.alloc(header.Submap, 2);
    submaps[0] = .{ .floor = 0, .residue = 0 };
    submaps[1] = .{ .floor = 1, .residue = 1 };
    const mappings = try arena.alloc(header.Mapping, 2);
    mappings[0] = .{ .submaps = submaps[0..1], .coupling = coupling, .mux = mux };
    mappings[1] = .{ .submaps = submaps[1..2], .coupling = coupling, .mux = mux };
    const modes = try arena.alloc(header.Mode, 2);
    modes[0] = .{ .long = false, .mapping = 0 };
    modes[1] = .{ .long = true, .mapping = 1 };

    return .{
        .id = .{
            .channels = d.channels,
            .rate = d.rate,
            .bitrate_maximum = 0,
            .bitrate_nominal = 0,
            .bitrate_minimum = 0,
            .blocksize_0 = short,
            .blocksize_1 = long,
        },
        .setup = .{
            .channels = d.channels,
            .size = 0,
            .bytes = books.budget.used,
            .books = books.list.items,
            .floors = floors,
            .residues = residues,
            .mappings = mappings,
            .modes = modes,
        },
        .tuning = tun,
    };
}

const helpers = @import("testing.zig");
const testing = std.testing;

const vendored = [_][]const u8{ "mono8k", "stereo44", "noise48", "surround48", "impulse22", "short44", "silence44", "square32", "chain" };

fn expectBooksEqual(a: Codebook, b: Codebook) !void {
    try testing.expectEqual(a.dimensions, b.dimensions);
    try testing.expectEqualSlices(u8, a.lengths, b.lengths);
    try testing.expectEqual(a.lookup, b.lookup);
    try testing.expectEqual(a.minimum_packed, b.minimum_packed);
    try testing.expectEqual(a.delta_packed, b.delta_packed);
    try testing.expectEqual(a.value_bits, b.value_bits);
    try testing.expectEqual(a.sequence_p, b.sequence_p);
    try testing.expectEqualSlices(u16, a.multiplicands, b.multiplicands);
}

fn expectSetupsEqual(a: header.Setup, b: header.Setup) !void {
    try testing.expectEqual(a.books.len, b.books.len);
    for (a.books, b.books) |x, y| try expectBooksEqual(x, y);
    try testing.expectEqual(a.floors.len, b.floors.len);
    for (a.floors, b.floors) |x, y| {
        try testing.expectEqual(std.meta.activeTag(x), std.meta.activeTag(y));
        switch (x) {
            .zero => |f| {
                const g = y.zero;
                try testing.expectEqual(f.order, g.order);
                try testing.expectEqual(f.rate, g.rate);
                try testing.expectEqual(f.bark_map_size, g.bark_map_size);
                try testing.expectEqual(f.amplitude_bits, g.amplitude_bits);
                try testing.expectEqual(f.amplitude_offset, g.amplitude_offset);
                try testing.expectEqualSlices(u8, f.books, g.books);
            },
            .one => |f| {
                const g = y.one;
                try testing.expectEqualSlices(u8, f.partition_classes, g.partition_classes);
                try testing.expectEqual(f.classes.len, g.classes.len);
                for (f.classes, g.classes) |c, d| {
                    try testing.expectEqual(c.dimensions, d.dimensions);
                    try testing.expectEqual(c.subclasses, d.subclasses);
                    try testing.expectEqual(c.masterbook, d.masterbook);
                    try testing.expectEqualSlices(i16, &c.subclass_books, &d.subclass_books);
                }
                try testing.expectEqual(f.multiplier, g.multiplier);
                try testing.expectEqual(f.rangebits, g.rangebits);
                try testing.expectEqualSlices(u16, f.x, g.x);
            },
        }
    }
    try testing.expectEqual(a.residues.len, b.residues.len);
    for (a.residues, b.residues) |x, y| {
        try testing.expectEqual(x.kind, y.kind);
        try testing.expectEqual(x.begin, y.begin);
        try testing.expectEqual(x.end, y.end);
        try testing.expectEqual(x.partition_size, y.partition_size);
        try testing.expectEqual(x.classifications, y.classifications);
        try testing.expectEqual(x.classbook, y.classbook);
        try testing.expectEqualSlices([8]i16, x.books, y.books);
    }
    try testing.expectEqual(a.mappings.len, b.mappings.len);
    for (a.mappings, b.mappings) |x, y| {
        try testing.expectEqualSlices(header.Submap, x.submaps, y.submaps);
        try testing.expectEqualSlices(header.Coupling, x.coupling, y.coupling);
        try testing.expectEqualSlices(u8, x.mux, y.mux);
    }
    try testing.expectEqualSlices(header.Mode, a.modes, b.modes);
}

test "the setup writer gives back the bytes of every vendored setup" {
    const gpa = testing.allocator;
    inline for (vendored) |name| {
        const headers = try helpers.firstHeaders(gpa, helpers.embed(name));
        defer headers.deinit(gpa);
        const id = try header.parseIdentification(headers.identification);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const parsed = try header.Setup.parse(arena.allocator(), headers.setup, id.channels, 16 << 20);
        const written = try writeSetup(gpa, &parsed);
        defer gpa.free(written);
        try testing.expectEqualSlices(u8, headers.setup[0..parsed.size], written);
    }
}

test "each vendored book is written and read back with the same fields" {
    const gpa = testing.allocator;
    inline for (vendored) |name| {
        const headers = try helpers.firstHeaders(gpa, helpers.embed(name));
        defer headers.deinit(gpa);
        const id = try header.parseIdentification(headers.identification);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const parsed = try header.Setup.parse(arena.allocator(), headers.setup, id.channels, 16 << 20);
        for (parsed.books) |book| {
            var w: io.LsbWriter = .init(gpa);
            defer w.deinit();
            try writeBook(&w, &book);
            var r: io.LsbReader = .init(w.bytes());
            var budget: codebook.Budget = .{ .max = 16 << 20 };
            const again = try Codebook.parse(arena.allocator(), &r, &budget);
            try expectBooksEqual(book, again);
        }
    }
}

test "a floor 0 setup and a lookup type 2 book survive the writer" {
    const gpa = testing.allocator;
    const packet = try helpers.buildSetup(gpa, .{ .floor_type = 0, .floor0_book = 2 });
    defer gpa.free(packet);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const parsed = try header.Setup.parse(arena.allocator(), packet, 2, 1 << 20);
    const written = try writeSetup(gpa, &parsed);
    defer gpa.free(written);
    const again = try header.Setup.parse(arena.allocator(), written, 2, 1 << 20);
    try expectSetupsEqual(parsed, again);
}

test "a multiplicand past the value bits is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var budget: codebook.Budget = .{ .max = 1 << 20 };
    const lengths = [_]u8{ 1, 1 };
    const wide = [_]u16{ 0, 3 };
    const book = try Codebook.build(arena.allocator(), &budget, .{
        .dimensions = 1,
        .lengths = &lengths,
        .lookup = .lattice,
        .minimum_packed = helpers.packInt(0),
        .delta_packed = helpers.packInt(1),
        .value_bits = 1,
        .multiplicands = &wide,
    });
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try testing.expectError(error.BadSetup, writeBook(&w, &book));
    var ok = book;
    ok.value_bits = 2;
    try writeBook(&w, &ok);
}

fn kraftSum(lengths: []const u8) u64 {
    var sum: u64 = 0;
    for (lengths) |l| sum += @as(u64, 1) << @intCast(32 - l);
    return sum;
}

test "huffman lengths make a complete tree with short codes for heavy entries" {
    const gpa = testing.allocator;
    var lengths: [8]u8 = undefined;
    try huffmanLengths(gpa, &.{ 1, 1 }, lengths[0..2]);
    try testing.expectEqualSlices(u8, &.{ 1, 1 }, lengths[0..2]);

    try huffmanLengths(gpa, &.{ 8, 4, 2, 1, 1 }, lengths[0..5]);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 4 }, lengths[0..5]);

    try huffmanLengths(gpa, &.{ 1, 1, 1, 1, 1, 1, 1, 1 }, &lengths);
    try testing.expectEqualSlices(u8, &.{ 3, 3, 3, 3, 3, 3, 3, 3 }, &lengths);

    var big: [300]u8 = undefined;
    var weights: [300]f64 = undefined;
    for (&weights, 0..) |*w, i| w.* = std.math.exp(-0.02 * @as(f64, @floatFromInt(i)));
    try huffmanLengths(gpa, &weights, &big);
    try testing.expectEqual(@as(u64, 1) << 32, kraftSum(&big));
    for (big) |l| try testing.expect(l >= 1 and l <= 32);
    for (big[1..], 0..) |l, i| try testing.expect(l >= big[i]);
}

test "huffman lengths stay within 32 bits for extreme weights" {
    const gpa = testing.allocator;
    var lengths: [60]u8 = undefined;
    var weights: [60]f64 = undefined;
    for (&weights, 0..) |*w, i| w.* = std.math.pow(f64, 0.25, @floatFromInt(i));
    try huffmanLengths(gpa, &weights, &lengths);
    try testing.expectEqual(@as(u64, 1) << 32, kraftSum(&lengths));
    for (lengths) |l| try testing.expect(l >= 1 and l <= 32);
}

fn expectComplete(book: Codebook) !void {
    try testing.expect(book.used >= 2);
    try testing.expectEqual(@as(u64, 1) << 32, kraftSum(book.lengths));
    for (book.lengths) |l| try testing.expect(l >= 1 and l <= 32);
}

test "the block sizes follow the sample rate" {
    try testing.expectEqual(@as(u16, 512), blocksizeFor(8000));
    try testing.expectEqual(@as(u16, 512), blocksizeFor(15999));
    try testing.expectEqual(@as(u16, 1024), blocksizeFor(16000));
    try testing.expectEqual(@as(u16, 1024), blocksizeFor(22050));
    try testing.expectEqual(@as(u16, 1024), blocksizeFor(26000));
    try testing.expectEqual(@as(u16, 1024), blocksizeFor(31999));
    try testing.expectEqual(@as(u16, 2048), blocksizeFor(32000));
    try testing.expectEqual(@as(u16, 2048), blocksizeFor(44100));
    try testing.expectEqual(@as(u16, 2048), blocksizeFor(192000));
    try testing.expectEqual(@as(u16, 256), shortBlocksizeFor(2048));
    try testing.expectEqual(@as(u16, 128), shortBlocksizeFor(1024));
    try testing.expectEqual(@as(u16, 128), shortBlocksizeFor(512));
}

test "the setup has two modes, two floors and nine residue classes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const built = try build(arena.allocator(), .{ .channels = 2, .rate = 44100, .quality = 8 });
    try testing.expectEqual(@as(u16, 256), built.id.blocksize_0);
    try testing.expectEqual(@as(u16, 2048), built.id.blocksize_1);
    const s = built.setup;
    try testing.expectEqual(@as(usize, 2), s.modes.len);
    try testing.expect(!s.modes[0].long);
    try testing.expect(s.modes[1].long);
    try testing.expectEqual(@as(u8, 0), s.modes[0].mapping);
    try testing.expectEqual(@as(u8, 1), s.modes[1].mapping);
    try testing.expectEqual(@as(usize, 2), s.floors.len);
    try testing.expectEqual(@as(usize, 2), s.residues.len);
    try testing.expectEqual(@as(usize, 2), s.mappings.len);
    for (s.mappings, 0..) |m, i| {
        try testing.expectEqual(@as(usize, 1), m.submaps.len);
        try testing.expectEqual(@as(u8, @intCast(i)), m.submaps[0].floor);
        try testing.expectEqual(@as(u8, @intCast(i)), m.submaps[0].residue);
        try testing.expectEqualSlices(header.Coupling, &.{.{ .magnitude = 0, .angle = 1 }}, m.coupling);
    }

    const f = s.floors[1].one;
    try testing.expectEqual(@as(usize, 29), f.x.len);
    try testing.expectEqual(@as(u8, 10), f.rangebits);
    try testing.expectEqual(@as(u8, 2), f.multiplier);
    try testing.expectEqualSlices(u16, &.{ 0, 1024, 93, 23, 372, 6, 46, 186, 750 }, f.x[0..9]);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 2, 3, 3, 4, 4 }, f.partition_classes);
    const short_floor = s.floors[0].one;
    try testing.expectEqual(@as(usize, 19), short_floor.x.len);
    try testing.expectEqual(@as(u8, 7), short_floor.rangebits);

    const r = s.residues[1];
    try testing.expectEqual(@as(u2, 2), r.kind);
    try testing.expectEqual(@as(u8, 9), r.classifications);
    try testing.expectEqual(@as(u32, 0), r.begin);
    try testing.expectEqual(@as(u32, 32), r.partition_size);
    try testing.expect(r.end % r.partition_size == 0 and r.end <= 2048);
    try testing.expectEqual(@as(u32, 16), s.residues[0].partition_size);
    try testing.expect(s.residues[0].end <= 256);
    const class_book = s.books[r.classbook];
    try testing.expectEqual(@as(u16, 2), class_book.dimensions);
    try testing.expectEqual(@as(u32, 81), class_book.entries);
    try testing.expectEqual(@as(u32, 81), s.books[s.residues[0].classbook].entries);
    // Both residues use the same lattice books.
    try testing.expectEqualSlices([8]i16, s.residues[0].books, r.books);
    const ranges = [_]u16{ 0, 1, 2, 4, 8, 16, 40, 128, 511 };
    for (r.books, ranges) |row, k| {
        if (k == 0) {
            try testing.expectEqualSlices(i16, &@as([8]i16, @splat(-1)), &row);
            continue;
        }
        try testing.expectEqualSlices(i16, &@as([7]i16, @splat(-1)), row[1..]);
        const book = s.books[@intCast(row[0])];
        try testing.expectEqual(codebook.Lookup.lattice, book.lookup);
        try testing.expectEqual(@as(f32, -@as(f32, @floatFromInt(k))), book.minimum);
        try testing.expectEqual(@as(f32, 1), book.delta);
        try testing.expectEqual(@as(u32, 2 * k + 1), book.lookup_values);
        try testing.expect(!book.sequence_p);
    }
}

test "the floor X lists and the residue follow the block size" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const mid = try build(arena.allocator(), .{ .channels = 1, .rate = 22050, .quality = 4 });
    try testing.expectEqual(@as(u16, 1024), mid.id.blocksize_1);
    try testing.expectEqual(@as(u16, 128), mid.id.blocksize_0);
    try testing.expectEqual(@as(usize, 19), mid.setup.floors[1].one.x.len);
    try testing.expectEqual(@as(u8, 9), mid.setup.floors[1].one.rangebits);
    try testing.expectEqual(@as(u8, 6), mid.setup.floors[0].one.rangebits);
    try testing.expectEqual(@as(usize, 0), mid.setup.mappings[1].coupling.len);
    const short = try build(arena.allocator(), .{ .channels = 1, .rate = 8000, .quality = 4 });
    try testing.expectEqual(@as(u16, 512), short.id.blocksize_1);
    try testing.expectEqual(@as(usize, 19), short.setup.floors[1].one.x.len);
    try testing.expectEqual(@as(u8, 8), short.setup.floors[1].one.rangebits);
    try testing.expectEqual(@as(u32, 16), short.setup.residues[1].partition_size);
    try testing.expectEqual(@as(u32, 256), short.setup.residues[1].end);
}

test "every floor layout has distinct posts inside the range" {
    const layouts = [_]FloorLayout{ layout_1024, layout_512, layout_256, layout_128, layout_64 };
    for (layouts) |layout| {
        const limit = @as(u32, 1) << @intCast(layout.rangebits);
        var posts: usize = 0;
        for (layout.partition_classes) |c| posts += layout.class_dims[c];
        try testing.expectEqual(layout.x.len, posts);
        for (layout.x, 0..) |x, i| {
            try testing.expect(x > 0 and x < limit);
            for (layout.x[0..i]) |y| try testing.expect(x != y);
        }
    }
}

test "coupling pairs follow the Vorbis channel order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pairs = [_][]const [2]u8{
        &.{},                       &.{.{ 0, 1 }},              &.{.{ 0, 2 }},              &.{ .{ 0, 1 }, .{ 2, 3 } },
        &.{ .{ 0, 2 }, .{ 3, 4 } }, &.{ .{ 0, 2 }, .{ 3, 4 } }, &.{ .{ 0, 2 }, .{ 3, 4 } }, &.{ .{ 0, 2 }, .{ 3, 4 }, .{ 5, 6 } },
    };
    for (1..9) |channels| {
        const built = try build(arena.allocator(), .{ .channels = @intCast(channels), .rate = 44100, .quality = 4 });
        for (built.setup.mappings) |mapping| {
            const got = mapping.coupling;
            try testing.expectEqual(pairs[channels - 1].len, got.len);
            for (got, pairs[channels - 1]) |c, want| {
                try testing.expectEqual(want[0], c.magnitude);
                try testing.expectEqual(want[1], c.angle);
            }
            try testing.expectEqual(channels, mapping.mux.len);
        }
    }
}

test "every book of the encoder setup is a complete tree" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_]u32{ 8000, 22050, 44100, 96000 }) |rate| {
        for ([_]f32{ -1, 4, 10 }) |quality| {
            const built = try build(arena.allocator(), .{ .channels = 2, .rate = rate, .quality = quality });
            for (built.setup.books) |book| try expectComplete(book);
        }
    }
}

test "the encoder setup writes and parses back to the same structure" {
    const gpa = testing.allocator;
    for ([_]u8{ 1, 2, 3, 6, 8, 9 }) |channels| {
        for ([_]u32{ 8000, 22050, 44100, 48000 }) |rate| {
            for ([_]f32{ -1, 4, 10 }) |quality| {
                var arena: std.heap.ArenaAllocator = .init(gpa);
                defer arena.deinit();
                const built = try build(arena.allocator(), .{ .channels = channels, .rate = rate, .quality = quality });
                const packet = try writeSetup(gpa, &built.setup);
                defer gpa.free(packet);
                const parsed = try header.Setup.parse(arena.allocator(), packet, channels, 16 << 20);
                try testing.expectEqual(packet.len, parsed.size);
                try expectSetupsEqual(built.setup, parsed);
                const id = writeIdentification(built.id);
                try testing.expectEqual(built.id, try header.parseIdentification(&id));
            }
        }
    }
}

test "the tuning gives more bits to a higher quality" {
    var last = tuning(-1);
    var q: f32 = -0.5;
    while (q <= 10) : (q += 0.5) {
        const now = tuning(q);
        try testing.expect(now.margin_db > last.margin_db);
        try testing.expect(now.lowpass_hz > last.lowpass_hz);
        try testing.expect(now.listen_spl > last.listen_spl);
        try testing.expect(now.classes >= last.classes);
        try testing.expect(now.endLines(44100, 1024) >= last.endLines(44100, 1024));
        try testing.expect(now.levelLimit() >= last.levelLimit());
        last = now;
    }
    try testing.expectEqual(@as(u32, 1024), last.endLines(44100, 1024));
    try testing.expectEqual(tuning(-1).margin_db, tuning(-5).margin_db);
    try testing.expectEqual(last.margin_db, tuning(99).margin_db);
    try testing.expectEqual(tuning(4).margin_db, tuning(std.math.nan(f32)).margin_db);
    try testing.expectEqual(@as(u32, 256), tuning(10).endLines(8000, 256));
}

test "the quality rows give the margin, the lowpass and the classes" {
    try testing.expectEqual(@as(f32, 6.0), tuning(-1).margin_db);
    try testing.expectEqual(@as(f32, 17.0), tuning(4).margin_db);
    try testing.expectEqual(@as(f32, 30.2), tuning(10).margin_db);
    try testing.expectEqual(@as(f32, 18000), tuning(4).lowpass_hz);
    try testing.expectApproxEqAbs(@as(f32, 18.1), tuning(4.5).margin_db, 1e-4);
    try testing.expectEqual(@as(u8, 7), tuning(-1).classes);
    try testing.expectEqual(@as(u8, 7), tuning(2).classes);
    try testing.expectEqual(@as(u8, 8), tuning(2.5).classes);
    try testing.expectEqual(@as(u8, 9), tuning(6.5).classes);
    try testing.expectEqual(@as(u8, 8), tuning(3).classes);
    try testing.expectEqual(@as(u8, 8), tuning(6).classes);
    try testing.expectEqual(@as(u8, 9), tuning(7).classes);
    try testing.expectEqual(@as(u8, 9), tuning(10).classes);
    try testing.expectEqual(@as(f32, 20), tuning(0).levelLimit());
    try testing.expectEqual(@as(f32, 64), tuning(4).levelLimit());
    try testing.expectEqual(@as(f32, 255), tuning(10).levelLimit());
    // 18000 Hz at 44100 Hz and 1024 lines.
    try testing.expectEqual(@as(u32, 836), tuning(4).endLines(44100, 1024));
}

test "fewer classes make a smaller setup" {
    const gpa = testing.allocator;
    var last: usize = 0;
    for ([_]f32{ -1, 3, 7 }) |quality| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const built = try build(arena.allocator(), .{ .channels = 2, .rate = 44100, .quality = quality });
        const packet = try writeSetup(gpa, &built.setup);
        defer gpa.free(packet);
        try testing.expect(packet.len > last);
        last = packet.len;
        try testing.expectEqual(tuning(quality).classes, built.setup.residues[0].classifications);
    }
}

test "the comment header holds the vendor and no comments" {
    const packet = try writeComment(testing.allocator, "Chorus");
    defer testing.allocator.free(packet);
    const comments = try header.parseComment(packet);
    try testing.expectEqualStrings("Chorus", comments.vendor);
    var it = comments.iterator();
    try testing.expect((try it.next()) == null);
}

test "a residue partition holds whole frames and whole vectors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_]u32{ 8000, 44100 }) |rate| {
        for ([_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 16, 100, 255 }) |channels| {
            const built = try build(arena.allocator(), .{ .channels = channels, .rate = rate, .quality = 4 });
            for (built.setup.residues, [2]u32{ built.id.blocksize_0, built.id.blocksize_1 }) |res, n| {
                try testing.expectEqual(@as(u32, 0), res.partition_size % channels);
                try testing.expectEqual(@as(u32, 0), res.partition_size % 4);
                try testing.expectEqual(@as(u32, 0), (n / 2 * channels) % res.partition_size);
                try testing.expect(res.end <= n / 2 * channels);
                try testing.expect(res.end >= res.partition_size);
            }
        }
    }
    const six = try build(arena.allocator(), .{ .channels = 6, .rate = 48000, .quality = 4 });
    try testing.expectEqual(@as(u32, 12), six.setup.residues[0].partition_size);
    try testing.expectEqual(@as(u32, 24), six.setup.residues[1].partition_size);
}
