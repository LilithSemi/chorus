//! Helpers that the Vorbis tests share: packed codebooks, hand built setup headers and the
//! header packets of the vendored files.
const std = @import("std");
const ogg = @import("../ogg.zig");
const io = @import("../io.zig");
const codebook = @import("codebook.zig");
const ilog = codebook.ilog;

pub fn embed(comptime name: []const u8) []const u8 {
    return @embedFile("../testdata/vorbis/" ++ name ++ ".ogg");
}

/// The first three packets of the first stream of an Ogg file.
pub const Headers = struct {
    identification: []u8,
    comment: []u8,
    setup: []u8,

    pub fn deinit(self: Headers, gpa: std.mem.Allocator) void {
        gpa.free(self.identification);
        gpa.free(self.comment);
        gpa.free(self.setup);
    }
};

pub fn firstHeaders(gpa: std.mem.Allocator, file: []const u8) !Headers {
    var input: io.Input = .init(.{ .bytes = file });
    var reader: ogg.PacketReader = try .init(gpa, &input, .any, .{});
    defer reader.deinit();
    var out: [3][]u8 = undefined;
    var got: usize = 0;
    errdefer for (out[0..got]) |p| gpa.free(p);
    while (got < 3) {
        const packet = (try reader.next()) orelse return error.TestUnexpectedResult;
        out[got] = try gpa.dupe(u8, packet.data);
        got += 1;
    }
    return .{ .identification = out[0], .comment = out[1], .setup = out[2] };
}

/// Builds the packed float32 of the codebook lookup data.
pub fn packFloat(negative: bool, exponent: u32, mantissa: u32) u32 {
    return (if (negative) @as(u32, 0x80000000) else 0) | (exponent << 21) | mantissa;
}

/// The packed form of a whole number.
pub fn packInt(value: i32) u32 {
    return packFloat(value < 0, 788, @abs(value));
}

pub const BookSpec = struct {
    dimensions: u16 = 1,
    /// One length per entry. 0 marks an unused entry.
    lengths: []const u8,
    /// Writes a presence bit per entry. Needs unordered lengths.
    sparse: bool = false,
    /// Writes the runs form. The lengths must not decrease and none may be 0.
    ordered: bool = false,
    lookup: u4 = 0,
    minimum: u32 = 0,
    delta: u32 = 0,
    /// 1 to 16
    value_bits: u5 = 1,
    sequence_p: bool = false,
    multiplicands: []const u16 = &.{},
};

pub fn writeBook(w: *io.LsbWriter, spec: BookSpec) !void {
    const entries: u32 = @intCast(spec.lengths.len);
    try w.writeBits(0x564342, 24);
    try w.writeBits(spec.dimensions, 16);
    try w.writeBits(entries, 24);
    try w.writeBits(@intFromBool(spec.ordered), 1);
    if (spec.ordered) {
        var current_len: u32 = spec.lengths[0];
        try w.writeBits(current_len - 1, 5);
        var at: u32 = 0;
        while (at < entries) {
            var run: u32 = 0;
            while (at + run < entries and spec.lengths[at + run] == current_len) run += 1;
            try w.writeBits(run, ilog(entries - at));
            at += run;
            current_len += 1;
        }
    } else {
        try w.writeBits(@intFromBool(spec.sparse), 1);
        for (spec.lengths) |len| {
            if (spec.sparse) try w.writeBits(@intFromBool(len != 0), 1);
            if (len != 0) try w.writeBits(len - 1, 5);
        }
    }
    try w.writeBits(spec.lookup, 4);
    if (spec.lookup == 0) return;
    try w.writeBits(spec.minimum, 32);
    try w.writeBits(spec.delta, 32);
    try w.writeBits(spec.value_bits - 1, 4);
    try w.writeBits(@intFromBool(spec.sequence_p), 1);
    for (spec.multiplicands) |m| try w.writeBits(m, spec.value_bits);
}

pub fn writeHeaderStart(w: *io.LsbWriter, kind: u8) !void {
    try w.writeBits(kind, 8);
    for ("vorbis") |c| try w.writeBits(c, 8);
}

/// Two entries of length 1.
pub const book_scalar_2: BookSpec = .{ .lengths = &.{ 1, 1 } };
/// Four entries of length 2.
pub const book_scalar_4: BookSpec = .{ .lengths = &.{ 2, 2, 2, 2 } };
/// Nine entries, a 3 by 3 lattice of two dimensional vectors from -1 to 1.
pub const book_lattice: BookSpec = .{
    .dimensions = 2,
    .lengths = &.{ 3, 3, 3, 3, 3, 3, 3, 4, 4 },
    .lookup = 1,
    .minimum = packInt(-1),
    .delta = packInt(1),
    .value_bits = 2,
    .multiplicands = &.{ 0, 1, 2 },
};
/// Four entries with explicit vectors of two values.
pub const book_explicit: BookSpec = .{
    .dimensions = 2,
    .lengths = &.{ 2, 2, 2, 2 },
    .lookup = 2,
    .minimum = packInt(-4),
    .delta = packInt(1),
    .value_bits = 3,
    .multiplicands = &.{ 0, 1, 2, 3, 4, 5, 6, 7 },
};

/// Knobs of a small valid setup header for two channels. The defaults build:
///   book 0 scalar_4, book 1 lattice, book 2 explicit,
///   one floor, one residue, one mapping, two modes.
pub const SetupOpts = struct {
    time_value: u16 = 0,
    floor_type: u16 = 1,
    /// Floor 1 with no partitions.
    floor1_flat: bool = false,
    floor1_x: [2]u16 = .{ 20, 40 },
    /// A floor with 31 partitions of which this many have dimension 3 and the rest 2.
    floor1_wide: ?u8 = null,
    floor1_multiplier: u3 = 2,
    floor1_masterbook: u8 = 0,
    /// The stored value, which is the book number plus 1. 0 means no book.
    floor1_subbook: u8 = 1,
    floor0_book: u8 = 2,
    floor0_order: u8 = 8,
    floor0_rate: u16 = 44100,
    floor0_bark: u16 = 64,
    residue_type: u16 = 2,
    residue_classes: u8 = 4,
    residue_classbook: u8 = 0,
    residue_stage_book: u8 = 1,
    mapping_type: u16 = 0,
    submaps: u8 = 1,
    mux: [2]u8 = .{ 0, 0 },
    coupling: ?[2]u8 = null,
    reserved: u2 = 0,
    submap_floor: u8 = 0,
    submap_residue: u8 = 0,
    window_type: u16 = 0,
    transform_type: u16 = 0,
    mode_mapping: u8 = 0,
    framing: u1 = 1,
};

pub fn buildSetup(gpa: std.mem.Allocator, opts: SetupOpts) ![]u8 {
    var w: io.LsbWriter = .init(gpa);
    errdefer w.deinit();
    try writeHeaderStart(&w, 5);
    try w.writeBits(2, 8);
    try writeBook(&w, book_scalar_4);
    try writeBook(&w, book_lattice);
    try writeBook(&w, book_explicit);
    try w.writeBits(0, 6);
    try w.writeBits(opts.time_value, 16);

    try w.writeBits(0, 6);
    try w.writeBits(opts.floor_type, 16);
    if (opts.floor_type == 0) {
        try w.writeBits(opts.floor0_order, 8);
        try w.writeBits(opts.floor0_rate, 16);
        try w.writeBits(opts.floor0_bark, 16);
        try w.writeBits(8, 6);
        try w.writeBits(100, 8);
        try w.writeBits(0, 4);
        try w.writeBits(opts.floor0_book, 8);
    } else {
        if (opts.floor1_wide) |wide| {
            try w.writeBits(31, 5);
            for (0..31) |i| try w.writeBits(@intFromBool(i < wide), 4);
            // class 0 has dimension 2 and class 1 has dimension 3, neither has a book
            try w.writeBits(1, 3);
            try w.writeBits(0, 2);
            try w.writeBits(0, 8);
            try w.writeBits(2, 3);
            try w.writeBits(0, 2);
            try w.writeBits(0, 8);
        } else if (opts.floor1_flat) {
            try w.writeBits(0, 5);
        } else {
            try w.writeBits(1, 5);
            try w.writeBits(0, 4);
            // one class of dimension 2 with two subclasses
            try w.writeBits(1, 3);
            try w.writeBits(1, 2);
            try w.writeBits(opts.floor1_masterbook, 8);
            try w.writeBits(opts.floor1_subbook, 8);
            try w.writeBits(0, 8);
        }
        try w.writeBits(opts.floor1_multiplier - 1, 2);
        try w.writeBits(if (opts.floor1_wide != null) 15 else 6, 4);
        if (opts.floor1_wide) |wide| {
            for (0..2 * 31 + wide) |i| try w.writeBits(@intCast(i + 1), 15);
        } else if (!opts.floor1_flat) {
            try w.writeBits(opts.floor1_x[0], 6);
            try w.writeBits(opts.floor1_x[1], 6);
        }
    }

    try w.writeBits(0, 6);
    try w.writeBits(opts.residue_type, 16);
    try w.writeBits(0, 24);
    try w.writeBits(64, 24);
    try w.writeBits(7, 24);
    try w.writeBits(opts.residue_classes - 1, 6);
    try w.writeBits(opts.residue_classbook, 8);
    for (0..opts.residue_classes) |class| {
        try w.writeBits(if (class == 0) 0 else 1, 3);
        try w.writeBits(0, 1);
    }
    for (1..opts.residue_classes) |_| try w.writeBits(opts.residue_stage_book, 8);

    try w.writeBits(0, 6);
    try w.writeBits(opts.mapping_type, 16);
    if (opts.submaps > 1) {
        try w.writeBits(1, 1);
        try w.writeBits(opts.submaps - 1, 4);
    } else try w.writeBits(0, 1);
    if (opts.coupling) |c| {
        try w.writeBits(1, 1);
        try w.writeBits(0, 8);
        try w.writeBits(c[0], 1);
        try w.writeBits(c[1], 1);
    } else try w.writeBits(0, 1);
    try w.writeBits(opts.reserved, 2);
    if (opts.submaps > 1) for (opts.mux) |m| try w.writeBits(m, 4);
    for (0..opts.submaps) |i| {
        try w.writeBits(0, 8);
        try w.writeBits(if (i == 0) opts.submap_floor else 0, 8);
        try w.writeBits(if (i == 0) opts.submap_residue else 0, 8);
    }

    try w.writeBits(1, 6);
    try w.writeBits(0, 1);
    try w.writeBits(opts.window_type, 16);
    try w.writeBits(opts.transform_type, 16);
    try w.writeBits(0, 8);
    try w.writeBits(1, 1);
    try w.writeBits(0, 16);
    try w.writeBits(0, 16);
    try w.writeBits(opts.mode_mapping, 8);
    try w.writeBits(opts.framing, 1);
    return w.list.toOwnedSlice(gpa);
}

/// An identification header packet.
pub fn buildIdentification(channels: u8, rate: u32, exp0: u4, exp1: u4) [30]u8 {
    var p: [30]u8 = @splat(0);
    p[0] = 1;
    @memcpy(p[1..7], "vorbis");
    p[11] = channels;
    std.mem.writeInt(u32, p[12..16], rate, .little);
    std.mem.writeInt(u32, p[16..20], 0, .little);
    std.mem.writeInt(u32, p[20..24], 128000, .little);
    std.mem.writeInt(u32, p[24..28], 0, .little);
    p[28] = @as(u8, exp1) << 4 | exp0;
    p[29] = 1;
    return p;
}

/// Packs `spec` and parses it back, with all memory from `arena`.
pub fn parseBook(arena: std.mem.Allocator, spec: BookSpec) !codebook.Codebook {
    var w: io.LsbWriter = .init(std.testing.allocator);
    defer w.deinit();
    try writeBook(&w, spec);
    var r: io.LsbReader = .init(w.bytes());
    var budget: codebook.Budget = .{ .max = 1 << 20 };
    return codebook.Codebook.parse(arena, &r, &budget);
}

/// Writes the codeword of `entry`, first bit first.
pub fn putCode(w: *io.LsbWriter, book: codebook.Codebook, entry: usize) !void {
    const len = book.lengths[entry];
    var k: u6 = 0;
    while (k < len) : (k += 1) {
        try w.writeBits((book.codes[entry] >> @intCast(len - 1 - k)) & 1, 1);
    }
}
