//! Vorbis codebooks: parsing, the Huffman codes and the vector lookup tables.
const std = @import("std");
const io = @import("../io.zig");
const helpers = @import("testing.zig");
const testing = std.testing;

pub const ParseError = error{ BadHeader, OutOfMemory };

/// The bit that marks a leaf in a tree slot.
const leaf_flag: u32 = 1 << 31;
const max_fast_bits = 8;
const sync_pattern = 0x564342;

pub const Lookup = enum(u2) { none = 0, lattice = 1, explicit = 2 };

/// Counts the bytes that a parse asks for. A request past `max` gives error.BadHeader
/// before the allocation happens.
pub const Budget = struct {
    max: usize,
    used: usize = 0,

    pub fn alloc(self: *Budget, a: std.mem.Allocator, comptime T: type, n: usize) ParseError![]T {
        const size = std.math.mul(usize, n, @sizeOf(T)) catch return error.BadHeader;
        const total = std.math.add(usize, self.used, size) catch return error.BadHeader;
        if (total > self.max) return error.BadHeader;
        self.used = total;
        return a.alloc(T, n);
    }
};

/// The stored fields of a codebook. `build` derives the rest.
pub const Spec = struct {
    dimensions: u16,
    /// One length per entry, 0 for an unused entry.
    lengths: []const u8,
    lookup: Lookup = .none,
    /// The packed float32 of the stream.
    minimum_packed: u32 = 0,
    delta_packed: u32 = 0,
    /// 1 to 16
    value_bits: u8 = 1,
    sequence_p: bool = false,
    multiplicands: []const u16 = &.{},
};

pub const Codebook = struct {
    dimensions: u16,
    entries: u32,
    /// The number of entries with a codeword.
    used: u32,
    /// The length of each codeword in bits. 0 marks an unused entry.
    lengths: []const u8,
    /// The codeword of each used entry. The first bit read is the highest of `lengths[i]` bits.
    codes: []const u32,
    lookup: Lookup,
    minimum_packed: u32,
    delta_packed: u32,
    value_bits: u8,
    minimum: f32,
    delta: f32,
    sequence_p: bool,
    /// The number of multiplicands.
    lookup_values: u32,
    multiplicands: []const u16,
    fast_bits: u4,
    /// Indexed by the next `fast_bits` bits, first bit read lowest. Holds `entry << 6 | length`,
    /// or 0 when the codeword is longer than `fast_bits`.
    fast: []const u32,
    /// Two slots per inner node. A slot is a node index, or `leaf_flag | entry`.
    tree: []const u32,

    /// Reads one codebook. All memory comes from `arena` and counts against `budget`. The
    /// caller frees it all at once. An end of packet gives error.BadHeader.
    pub fn parse(arena: std.mem.Allocator, r: *io.LsbReader, budget: *Budget) ParseError!Codebook {
        if (try take(r, 24) != sync_pattern) return error.BadHeader;
        const dimensions: u16 = @intCast(try take(r, 16));
        const entries = try take(r, 24);
        if (ilog(dimensions) + ilog(entries) > 24) return error.BadHeader;

        var lengths: []u8 = undefined;
        if (try takeBit(r)) {
            lengths = try budget.alloc(arena, u8, entries);
            @memset(lengths, 0);
            var at: u32 = 0;
            var length: u32 = try take(r, 5) + 1;
            while (at < entries) {
                const number = try take(r, ilog(entries - at));
                if (number > entries - at) return error.BadHeader;
                if (number > 0) {
                    if (length > 32 or (number - 1) >> @intCast(length - 1) > 1) return error.BadHeader;
                    @memset(lengths[at..][0..number], @intCast(length));
                }
                at += number;
                length += 1;
            }
        } else {
            const sparse = try takeBit(r);
            const per_entry: usize = if (sparse) 1 else 5;
            if (r.bitsLeft() / per_entry < entries) return error.BadHeader;
            lengths = try budget.alloc(arena, u8, entries);
            @memset(lengths, 0);
            for (lengths) |*len| {
                if (sparse and !try takeBit(r)) continue;
                len.* = @intCast(try take(r, 5) + 1);
            }
        }

        const lookup_type = try take(r, 4);
        var spec: Spec = .{ .dimensions = dimensions, .lengths = lengths, .lookup = std.enums.fromInt(Lookup, lookup_type) orelse return error.BadHeader };
        if (spec.lookup != .none) {
            spec.minimum_packed = try take(r, 32);
            spec.delta_packed = try take(r, 32);
            spec.value_bits = @intCast(try take(r, 4) + 1);
            spec.sequence_p = try takeBit(r);
            const count = lookupValues(spec.lookup, entries, dimensions);
            if (r.bitsLeft() / spec.value_bits < count) return error.BadHeader;
            const multiplicands = try budget.alloc(arena, u16, count);
            for (multiplicands) |*m| m.* = @intCast(try take(r, @intCast(spec.value_bits)));
            spec.multiplicands = multiplicands;
        }
        return build(arena, budget, spec);
    }

    /// Builds the codes, the fast table and the tree from stored fields. The result borrows
    /// `spec.lengths` and `spec.multiplicands`. An encoder can use this without packing a book.
    pub fn build(arena: std.mem.Allocator, budget: *Budget, spec: Spec) ParseError!Codebook {
        if (spec.lengths.len >= 1 << 24) return error.BadHeader;
        const entries: u32 = @intCast(spec.lengths.len);
        if (ilog(spec.dimensions) + ilog(entries) > 24) return error.BadHeader;
        var minimum: f32 = 0;
        var delta: f32 = 0;
        var lookup_values: u32 = 0;
        if (spec.lookup != .none) {
            if (spec.dimensions == 0 or spec.value_bits < 1 or spec.value_bits > 16) return error.BadHeader;
            minimum = float32Unpack(spec.minimum_packed);
            delta = float32Unpack(spec.delta_packed);
            lookup_values = lookupValues(spec.lookup, entries, spec.dimensions);
            if (spec.multiplicands.len != lookup_values) return error.BadHeader;
        }

        var used: u32 = 0;
        for (spec.lengths) |len| used += @intFromBool(len != 0);
        const codes = try budget.alloc(arena, u32, entries);
        try assignCodes(spec.lengths, codes);
        var fast_bits: u4 = 1;
        for (spec.lengths) |len| fast_bits = @max(fast_bits, @min(len, max_fast_bits));
        const fast = try budget.alloc(arena, u32, @as(usize, 1) << fast_bits);
        @memset(fast, 0);
        var tree: []u32 = &.{};
        if (used == 1) {
            for (spec.lengths, 0..) |len, i| {
                if (len != 0) @memset(fast, @as(u32, @intCast(i)) << 6 | 1);
            }
        } else if (used > 1) {
            for (spec.lengths, codes, 0..) |len, code, i| {
                if (len == 0 or len > fast_bits) continue;
                const first = @bitReverse(code) >> @intCast(32 - @as(u32, len));
                var idx: usize = first;
                while (idx < fast.len) : (idx += @as(usize, 1) << @intCast(len)) {
                    fast[idx] = @as(u32, @intCast(i)) << 6 | len;
                }
            }
            tree = try budget.alloc(arena, u32, 2 * (used - 1));
            @memset(tree, 0);
            try buildTree(spec.lengths, codes, tree);
        }
        return .{
            .dimensions = spec.dimensions,
            .entries = entries,
            .used = used,
            .lengths = spec.lengths,
            .codes = codes,
            .lookup = spec.lookup,
            .minimum_packed = spec.minimum_packed,
            .delta_packed = spec.delta_packed,
            .value_bits = spec.value_bits,
            .minimum = minimum,
            .delta = delta,
            .sequence_p = spec.sequence_p,
            .lookup_values = lookup_values,
            .multiplicands = spec.multiplicands,
            .fast_bits = fast_bits,
            .fast = fast,
            .tree = tree,
        };
    }

    /// Reads one codeword and returns its entry number. An end of packet, or a book with
    /// no used entry, gives error.Truncated.
    pub fn decode(self: *const Codebook, r: *io.LsbReader) error{Truncated}!u32 {
        if (self.used == 0) {
            r.pos = r.bytes.len * 8;
            return error.Truncated;
        }
        const hit = self.fast[r.peek(self.fast_bits)];
        if (hit != 0) {
            try r.skip(@intCast(hit & 63));
            return hit >> 6;
        }
        var node: u32 = 0;
        while (true) {
            const bit: u32 = @intFromBool(try r.readBit());
            const next = self.tree[node * 2 + bit];
            if (next & leaf_flag != 0) return next & ~leaf_flag;
            if (next == 0) return error.Truncated;
            node = next;
        }
    }

    /// Writes the vector of `entry` to `out`. The book needs a lookup, `out.len` must be
    /// the dimensions and `entry` must be below `entries`.
    pub fn vector(self: *const Codebook, entry: u32, out: []f32) void {
        std.debug.assert(self.lookup != .none);
        std.debug.assert(out.len == self.dimensions);
        std.debug.assert(entry < self.entries);
        var last: f32 = 0;
        var divisor: u64 = 1;
        for (out, 0..) |*o, i| {
            const index: usize = switch (self.lookup) {
                .lattice => @intCast((entry / divisor) % self.lookup_values),
                .explicit => @as(usize, entry) * self.dimensions + i,
                .none => unreachable,
            };
            divisor = @min(divisor * self.lookup_values, 1 << 32);
            const value = @as(f32, @floatFromInt(self.multiplicands[index])) * self.delta + self.minimum + last;
            o.* = value;
            if (self.sequence_p) last = value;
        }
    }
};

fn lookupValues(lookup: Lookup, entries: u32, dimensions: u16) u32 {
    return switch (lookup) {
        .none => 0,
        .lattice => lookup1Values(entries, dimensions),
        .explicit => entries * dimensions,
    };
}

/// Reads `n` bits. An end of packet gives error.BadHeader.
pub fn take(r: *io.LsbReader, n: u6) error{BadHeader}!u32 {
    return r.readBits(n) catch error.BadHeader;
}

pub fn takeBit(r: *io.LsbReader) error{BadHeader}!bool {
    return r.readBit() catch error.BadHeader;
}

/// The position of the highest set bit, counting from 1. `ilog(0)` is 0.
pub fn ilog(x: u32) u6 {
    return @intCast(32 - @clz(x));
}

/// The value of a packed Vorbis float. The binary exponent is clamped to -63..63 as in libvorbis.
pub fn float32Unpack(x: u32) f32 {
    const mantissa: f64 = @floatFromInt(x & 0x1fffff);
    const exponent: i32 = @intCast((x & 0x7fe00000) >> 21);
    const scaled = std.math.ldexp(mantissa, std.math.clamp(exponent - 788, -63, 63));
    return @floatCast(if (x & 0x80000000 != 0) -scaled else scaled);
}

/// The greatest `v` with `v^dimensions <= entries`. 0 when either is 0.
pub fn lookup1Values(entries: u32, dimensions: u32) u32 {
    if (entries == 0 or dimensions == 0) return 0;
    if (dimensions == 1) return entries;
    var v: u32 = 1;
    while (powFits(v + 1, dimensions, entries)) v += 1;
    return v;
}

fn powFits(base: u32, exponent: u32, limit: u32) bool {
    var acc: u64 = 1;
    for (0..exponent) |_| {
        acc *= base;
        if (acc > limit) return false;
    }
    return true;
}

/// Gives each used entry the lowest free codeword of its length, in entry order. The tree
/// must be full. The one exception is a single used entry of length 1.
pub fn assignCodes(lengths: []const u8, codes: []u32) error{BadHeader}!void {
    std.debug.assert(lengths.len == codes.len);
    // available[i] is the lowest free codeword of length i, aligned to the top of 32 bits.
    var available: [33]u32 = @splat(0);
    var used: usize = 0;
    var single_length: u8 = 0;
    for (lengths, codes) |len, *code| {
        code.* = 0;
        if (len == 0) continue;
        if (len > 32) return error.BadHeader;
        used += 1;
        single_length = len;
        if (used == 1) {
            for (1..@as(usize, len) + 1) |i| available[i] = @as(u32, 1) << @intCast(32 - i);
            continue;
        }
        var y: usize = len;
        while (y > 0 and available[y] == 0) y -= 1;
        if (y == 0) return error.BadHeader;
        const aligned = available[y];
        available[y] = 0;
        code.* = aligned >> @intCast(32 - @as(u32, len));
        var t: usize = len;
        while (t > y) : (t -= 1) available[t] = aligned + (@as(u32, 1) << @intCast(32 - t));
    }
    if (used == 0 or (used == 1 and single_length == 1)) return;
    for (available[1..]) |a| {
        if (a != 0) return error.BadHeader;
    }
}

fn buildTree(lengths: []const u8, codes: []const u32, tree: []u32) error{BadHeader}!void {
    var next: u32 = 1;
    for (lengths, codes, 0..) |len, code, entry| {
        if (len == 0) continue;
        var node: u32 = 0;
        var depth: u8 = len;
        while (depth > 0) {
            depth -= 1;
            const slot: usize = node * 2 + ((code >> @intCast(depth)) & 1);
            if (depth == 0) {
                if (tree[slot] != 0) return error.BadHeader;
                tree[slot] = leaf_flag | @as(u32, @intCast(entry));
                break;
            }
            if (tree[slot] & leaf_flag != 0) return error.BadHeader;
            if (tree[slot] == 0) {
                if (next >= tree.len / 2) return error.BadHeader;
                tree[slot] = next;
                next += 1;
            }
            node = tree[slot];
        }
    }
}

const test_budget = 1 << 20;

fn parseDefault(arena: std.mem.Allocator, r: *io.LsbReader) ParseError!Codebook {
    var budget: Budget = .{ .max = test_budget };
    return Codebook.parse(arena, r, &budget);
}

fn parseSpec(arena: std.mem.Allocator, spec: helpers.BookSpec) !Codebook {
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try helpers.writeBook(&w, spec);
    var r: io.LsbReader = .init(w.bytes());
    const book = try parseDefault(arena, &r);
    try testing.expectEqual(w.bytes().len, r.bytePosition());
    return book;
}

fn packCode(w: *io.LsbWriter, code: u32, len: u8) !void {
    // A codeword goes out most significant bit first.
    var i: u8 = len;
    while (i > 0) {
        i -= 1;
        try w.writeBits((code >> @intCast(i)) & 1, 1);
    }
}

test "codeword assignment follows the specification example" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const book = try parseSpec(arena.allocator(), .{ .lengths = &.{ 2, 4, 4, 4, 4, 2, 3, 3 } });
    try testing.expectEqualSlices(u32, &.{ 0b00, 0b0100, 0b0101, 0b0110, 0b0111, 0b10, 0b110, 0b111 }, book.codes);
    try testing.expectEqual(@as(u32, 8), book.used);

    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    for ([_]u32{ 5, 1, 7, 0, 4, 6, 2, 3 }) |e| try packCode(&w, book.codes[e], book.lengths[e]);
    var r: io.LsbReader = .init(w.bytes());
    for ([_]u32{ 5, 1, 7, 0, 4, 6, 2, 3 }) |e| try testing.expectEqual(e, try book.decode(&r));
}

test "a book with one entry of length 1 reads one bit and accepts both values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const book = try parseSpec(arena.allocator(), .{ .lengths = &.{ 0, 0, 1 }, .sparse = true });
    try testing.expectEqual(@as(u32, 1), book.used);
    var r: io.LsbReader = .init(&.{0b0000_0010});
    try testing.expectEqual(@as(u32, 2), try book.decode(&r));
    try testing.expectEqual(@as(usize, 1), r.pos);
    try testing.expectEqual(@as(u32, 2), try book.decode(&r));
    try testing.expectEqual(@as(usize, 2), r.pos);
}

test "a book with one entry of length 2 is under specified" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.BadHeader, parseSpec(arena.allocator(), .{ .lengths = &.{2} }));
}

test "over specified and under specified trees are rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.BadHeader, parseSpec(arena.allocator(), .{ .lengths = &.{ 1, 1, 1 } }));
    try testing.expectError(error.BadHeader, parseSpec(arena.allocator(), .{ .lengths = &.{ 1, 2 } }));
    try testing.expectError(error.BadHeader, parseSpec(arena.allocator(), .{ .lengths = &.{ 2, 2, 2 } }));
}

test "a book with no used entries parses and every read is an end of packet" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const book = try parseSpec(arena.allocator(), .{ .lengths = &.{ 0, 0, 0 }, .sparse = true });
    try testing.expectEqual(@as(u32, 0), book.used);
    var r: io.LsbReader = .init(&.{ 0xff, 0xff });
    try testing.expectError(error.Truncated, book.decode(&r));
}

test "codes of length 32 decode through the tree walk" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var lengths: [33]u8 = undefined;
    for (lengths[0..32], 1..) |*l, i| l.* = @intCast(i);
    lengths[32] = 32;
    const book = try parseSpec(arena.allocator(), .{ .lengths = &lengths });
    try testing.expectEqual(@as(u32, 0xffffffff), book.codes[32]);
    try testing.expectEqual(@as(u32, 0xfffffffe), book.codes[31]);

    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try packCode(&w, book.codes[32], 32);
    try packCode(&w, book.codes[31], 32);
    try packCode(&w, book.codes[0], 1);
    try packCode(&w, book.codes[11], 12);
    var r: io.LsbReader = .init(w.bytes());
    try testing.expectEqual(@as(u32, 32), try book.decode(&r));
    try testing.expectEqual(@as(u32, 31), try book.decode(&r));
    try testing.expectEqual(@as(u32, 0), try book.decode(&r));
    try testing.expectEqual(@as(u32, 11), try book.decode(&r));
}

test "a codeword cut by the end of the packet is an end of packet" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const book = try parseSpec(arena.allocator(), .{ .lengths = &.{ 1, 2, 3, 3 } });
    var r: io.LsbReader = .init(&.{0b1100_0000});
    // Two bits of a three bit codeword remain.
    try r.skip(6);
    try testing.expectError(error.Truncated, book.decode(&r));
    try testing.expectError(error.Truncated, book.decode(&r));
}

test "ordered lengths and sparse lengths build the same codes as the plain form" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ordered = try parseSpec(arena.allocator(), .{ .lengths = &.{ 1, 2, 3, 3 }, .ordered = true });
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 3 }, ordered.lengths);
    try testing.expectEqualSlices(u32, &.{ 0b0, 0b10, 0b110, 0b111 }, ordered.codes);

    const gap = try parseSpec(arena.allocator(), .{ .lengths = &.{ 1, 3, 3, 3, 3 }, .ordered = true });
    try testing.expectEqualSlices(u8, &.{ 1, 3, 3, 3, 3 }, gap.lengths);

    const sparse = try parseSpec(arena.allocator(), .{ .lengths = &.{ 2, 0, 1, 0, 2 }, .sparse = true });
    try testing.expectEqualSlices(u8, &.{ 2, 0, 1, 0, 2 }, sparse.lengths);
    try testing.expectEqual(@as(u32, 3), sparse.used);
    try testing.expectEqual(@as(u32, 0b00), sparse.codes[0]);
    try testing.expectEqual(@as(u32, 0b1), sparse.codes[2]);
    try testing.expectEqual(@as(u32, 0b01), sparse.codes[4]);
}

test "ordered runs that overrun the entry count or pass length 32 are rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    // Five entries and a first run of 6 entries.
    try w.writeBits(0x564342, 24);
    try w.writeBits(1, 16);
    try w.writeBits(5, 24);
    try w.writeBits(1, 1);
    try w.writeBits(0, 5);
    try w.writeBits(6, 3);
    var r: io.LsbReader = .init(w.bytes());
    try testing.expectError(error.BadHeader, parseDefault(arena.allocator(), &r));

    // A run of one entry at length 33.
    var w2: io.LsbWriter = .init(testing.allocator);
    defer w2.deinit();
    try w2.writeBits(0x564342, 24);
    try w2.writeBits(1, 16);
    try w2.writeBits(2, 24);
    try w2.writeBits(1, 1);
    try w2.writeBits(31, 5);
    try w2.writeBits(0, 2);
    try w2.writeBits(1, 2);
    try w2.writeBits(1, 1);
    var r2: io.LsbReader = .init(w2.bytes());
    try testing.expectError(error.BadHeader, parseDefault(arena.allocator(), &r2));
}

test "a bad sync pattern, a cut book and a lookup type above 2 are rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try helpers.writeBook(&w, helpers.book_lattice);
    const good = try testing.allocator.dupe(u8, w.bytes());
    defer testing.allocator.free(good);

    var bad = try testing.allocator.dupe(u8, good);
    defer testing.allocator.free(bad);
    bad[0] ^= 1;
    var r: io.LsbReader = .init(bad);
    try testing.expectError(error.BadHeader, parseDefault(arena.allocator(), &r));

    for (0..good.len) |cut| {
        var rc: io.LsbReader = .init(good[0..cut]);
        try testing.expectError(error.BadHeader, parseDefault(arena.allocator(), &rc));
    }

    var w3: io.LsbWriter = .init(testing.allocator);
    defer w3.deinit();
    try helpers.writeBook(&w3, .{ .lengths = &.{ 1, 1 }, .lookup = 3 });
    var r3: io.LsbReader = .init(w3.bytes());
    try testing.expectError(error.BadHeader, parseDefault(arena.allocator(), &r3));
}

test "a book with a lookup and no dimensions is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.BadHeader, parseSpec(arena.allocator(), .{
        .dimensions = 0,
        .lengths = &.{ 1, 1 },
        .lookup = 1,
        .multiplicands = &.{ 0, 1 },
    }));
    const scalar = try parseSpec(arena.allocator(), .{ .dimensions = 0, .lengths = &.{ 1, 1 } });
    try testing.expectEqual(@as(u16, 0), scalar.dimensions);
}

test "a book whose table would be too large is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    // ilog(4096) + ilog(4095) = 13 + 12 = 25
    try w.writeBits(0x564342, 24);
    try w.writeBits(4096, 16);
    try w.writeBits(4095, 24);
    var r: io.LsbReader = .init(w.bytes());
    try testing.expectError(error.BadHeader, parseDefault(arena.allocator(), &r));
    // ilog(2048) + ilog(4095) = 12 + 12 = 24 passes this check and then runs out of bytes.
    var w2: io.LsbWriter = .init(testing.allocator);
    defer w2.deinit();
    try w2.writeBits(0x564342, 24);
    try w2.writeBits(2048, 16);
    try w2.writeBits(4095, 24);
    var r2: io.LsbReader = .init(w2.bytes());
    try testing.expectError(error.BadHeader, parseDefault(arena.allocator(), &r2));
}

test "lookup1Values is the greatest root and exact at the edges" {
    try testing.expectEqual(@as(u32, 0), lookup1Values(0, 3));
    try testing.expectEqual(@as(u32, 1), lookup1Values(1, 8));
    try testing.expectEqual(@as(u32, 9), lookup1Values(81, 2));
    try testing.expectEqual(@as(u32, 8), lookup1Values(80, 2));
    try testing.expectEqual(@as(u32, 9), lookup1Values(99, 2));
    try testing.expectEqual(@as(u32, 10), lookup1Values(100, 2));
    try testing.expectEqual(@as(u32, 3), lookup1Values(6561, 8));
    try testing.expectEqual(@as(u32, 2), lookup1Values(6560, 8));
    try testing.expectEqual(@as(u32, 5), lookup1Values(625, 4));
    try testing.expectEqual(@as(u32, 17), lookup1Values(289, 2));
    try testing.expectEqual(@as(u32, 65535), lookup1Values(std.math.maxInt(u32), 2));
    try testing.expectEqual(@as(u32, 2), lookup1Values(1 << 24, 24));
    try testing.expectEqual(@as(u32, 1), lookup1Values((1 << 24) - 1, 24));
    try testing.expectEqual(@as(u32, 777), lookup1Values(777, 1));
    try testing.expectEqual(@as(u32, 0), lookup1Values(10, 0));
    for (1..9) |dim| {
        for (1..3000) |entries| {
            var v: u64 = 1;
            while (std.math.pow(u64, v + 1, dim) <= entries) v += 1;
            try testing.expectEqual(@as(u32, @intCast(v)), lookup1Values(@intCast(entries), @intCast(dim)));
        }
    }
}

test "float32Unpack reads the Vorbis packed float" {
    try testing.expectEqual(@as(f32, 1.0), float32Unpack(helpers.packFloat(false, 788, 1)));
    try testing.expectEqual(@as(f32, -8.0), float32Unpack(helpers.packInt(-8)));
    try testing.expectEqual(@as(f32, 0.5), float32Unpack(helpers.packFloat(false, 787, 1)));
    try testing.expectEqual(@as(f32, 0.0), float32Unpack(0));
    try testing.expectEqual(@as(f32, 3.0 * 0x1p-10), float32Unpack(helpers.packFloat(false, 778, 3)));
    try testing.expectEqual(@as(f32, 0x1fffff), float32Unpack(helpers.packFloat(false, 788, 0x1fffff)));
    // The exponent is clamped to -63..63 like libvorbis.
    try testing.expectEqual(@as(f32, 0x1fffff) * 0x1p63, float32Unpack(helpers.packFloat(false, 1023, 0x1fffff)));
    try testing.expectEqual(@as(f32, -3) * 0x1p63, float32Unpack(helpers.packFloat(true, 900, 3)));
    try testing.expectEqual(@as(f32, 5) * 0x1p-63, float32Unpack(helpers.packFloat(false, 1, 5)));
    try testing.expectEqual(@as(f32, 5) * 0x1p-63, float32Unpack(helpers.packFloat(false, 725, 5)));
}

test "lookup type 1 builds lattice vectors with the digit order of the specification" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const book = try parseSpec(arena.allocator(), helpers.book_lattice);
    try testing.expectEqual(@as(u32, 3), book.lookup_values);
    var v: [2]f32 = undefined;
    book.vector(5, &v);
    try testing.expectEqualSlices(f32, &.{ 1, 0 }, &v);
    book.vector(0, &v);
    try testing.expectEqualSlices(f32, &.{ -1, -1 }, &v);
    book.vector(8, &v);
    try testing.expectEqualSlices(f32, &.{ 1, 1 }, &v);
    book.vector(3, &v);
    try testing.expectEqualSlices(f32, &.{ -1, 0 }, &v);
}

test "lookup type 1 with sequence_p adds the previous element" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var spec = helpers.book_lattice;
    spec.sequence_p = true;
    spec.delta = helpers.packFloat(false, 787, 1);
    const book = try parseSpec(arena.allocator(), spec);
    var v: [2]f32 = undefined;
    // Entry 7 has digits 1 and 2: 0.5 - 1, then 1 - 1 + (-0.5).
    book.vector(7, &v);
    try testing.expectEqualSlices(f32, &.{ -0.5, -0.5 }, &v);
}

test "lookup type 1 stops multiplying the divisor for many dimensions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // 3 entries and 40 dimensions: lookup1_values is 1, so every digit is multiplicand 0.
    const book = try parseSpec(arena.allocator(), .{
        .dimensions = 40,
        .lengths = &.{ 2, 2, 1 },
        .lookup = 1,
        .minimum = helpers.packInt(2),
        .delta = helpers.packInt(1),
        .value_bits = 4,
        .multiplicands = &.{5},
    });
    try testing.expectEqual(@as(u32, 1), book.lookup_values);
    var v: [40]f32 = undefined;
    book.vector(2, &v);
    for (v) |x| try testing.expectEqual(@as(f32, 7), x);
}

test "lookup type 2 reads explicit vectors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const book = try parseSpec(arena.allocator(), helpers.book_explicit);
    try testing.expectEqual(@as(u32, 8), book.lookup_values);
    var v: [2]f32 = undefined;
    book.vector(0, &v);
    try testing.expectEqualSlices(f32, &.{ -4, -3 }, &v);
    book.vector(3, &v);
    try testing.expectEqualSlices(f32, &.{ 2, 3 }, &v);

    var spec = helpers.book_explicit;
    spec.sequence_p = true;
    const seq = try parseSpec(arena.allocator(), spec);
    seq.vector(3, &v);
    try testing.expectEqualSlices(f32, &.{ 2, 5 }, &v);
}

test "a lookup that the bytes cannot hold is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    // 2 entries of 8 dimensions need 16 values of 16 bits, and none follow.
    try helpers.writeBook(&w, .{ .dimensions = 8, .lengths = &.{ 1, 1 }, .lookup = 2, .value_bits = 16 });
    var r: io.LsbReader = .init(w.bytes());
    try testing.expectError(error.BadHeader, parseDefault(arena.allocator(), &r));
}

test "a long code walks the tree and a short code uses the fast table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // One code of length 1 and 256 codes of length 9 fill the tree exactly.
    var lengths: [257]u8 = undefined;
    lengths[0] = 1;
    @memset(lengths[1..], 9);
    const book = try parseSpec(arena.allocator(), .{ .lengths = &lengths });
    try testing.expectEqual(@as(u32, 257), book.used);
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    const order = [_]u32{ 0, 1, 77, 256, 0, 64 };
    for (order) |e| try packCode(&w, book.codes[e], book.lengths[e]);
    var r: io.LsbReader = .init(w.bytes());
    for (order) |e| try testing.expectEqual(e, try book.decode(&r));
}

test "parsing random bytes never crashes and frees what it allocates" {
    var prng: std.Random.DefaultPrng = .init(0x564942);
    const rand = prng.random();
    var buf: [96]u8 = undefined;
    for (0..4000) |_| {
        rand.bytes(&buf);
        // Most inputs fail at the sync pattern, so give half of them a valid start
        // and a small entry count.
        if (rand.boolean()) {
            buf[0] = 0x42;
            buf[1] = 0x43;
            buf[2] = 0x56;
            buf[6] &= 0x01;
            buf[7] = 0;
        }
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var r: io.LsbReader = .init(buf[0..rand.intRangeAtMost(usize, 0, buf.len)]);
        if (parseDefault(arena.allocator(), &r)) |book| {
            var dec: io.LsbReader = .init(&buf);
            if (book.used > 0) {
                _ = book.decode(&dec) catch |err| try testing.expectEqual(error.Truncated, err);
            }
        } else |err| try testing.expectEqual(error.BadHeader, err);
    }
}

fn writeAttackBook(w: *io.LsbWriter) !void {
    // Dimension 0, one entry of length 1, then 2^23 entries of length 24: Kraft sum 1.
    const entries: u32 = (1 << 23) + 1;
    try w.writeBits(0x564342, 24);
    try w.writeBits(0, 16);
    try w.writeBits(entries, 24);
    try w.writeBits(1, 1);
    try w.writeBits(0, 5);
    try w.writeBits(1, ilog(entries));
    const left = entries - 1;
    for (2..24) |_| try w.writeBits(0, ilog(left));
    try w.writeBits(left, ilog(left));
    try w.writeBits(0, 4);
}

test "a short book that declares millions of entries is stopped by the budget" {
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try writeAttackBook(&w);
    try testing.expect(w.bytes().len < 100);
    // The buffer holds exactly the budget plus padding, so any allocation past the budget
    // would fail with OutOfMemory and not with BadHeader.
    var buf: [(1 << 20) + 4096]u8 align(16) = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    var budget: Budget = .{ .max = 1 << 20 };
    var r: io.LsbReader = .init(w.bytes());
    try testing.expectError(error.BadHeader, Codebook.parse(fba.allocator(), &r, &budget));
    try testing.expect(budget.used <= budget.max);
}

test "the budget counts every allocation of a book" {
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try helpers.writeBook(&w, helpers.book_lattice);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var big: Budget = .{ .max = 1 << 20 };
    var r: io.LsbReader = .init(w.bytes());
    _ = try Codebook.parse(arena.allocator(), &r, &big);
    const need = big.used;
    try testing.expect(need > 0);
    var exact: Budget = .{ .max = need };
    var r2: io.LsbReader = .init(w.bytes());
    _ = try Codebook.parse(arena.allocator(), &r2, &exact);
    var short: Budget = .{ .max = need - 1 };
    var r3: io.LsbReader = .init(w.bytes());
    try testing.expectError(error.BadHeader, Codebook.parse(arena.allocator(), &r3, &short));
}

test "an ordered run that holds more codewords than the length allows is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Two codewords of length 1 fit. Three do not.
    const two = try parseSpec(arena.allocator(), .{ .lengths = &.{ 1, 1 }, .ordered = true });
    try testing.expectEqual(@as(u32, 2), two.used);
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try w.writeBits(0x564342, 24);
    try w.writeBits(1, 16);
    try w.writeBits(8, 24);
    try w.writeBits(1, 1);
    try w.writeBits(0, 5);
    try w.writeBits(3, 4);
    var r: io.LsbReader = .init(w.bytes());
    try testing.expectError(error.BadHeader, parseDefault(arena.allocator(), &r));
}

test "a book rebuilt from its stored fields has the same codes" {
    const headers = try helpers.firstHeaders(testing.allocator, helpers.embed("stereo44"));
    defer headers.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var r: io.LsbReader = .init(headers.setup[7..]);
    const count = try take(&r, 8) + 1;
    var lattice_seen = false;
    for (0..count) |_| {
        const book = try parseDefault(arena.allocator(), &r);
        var budget: Budget = .{ .max = test_budget };
        const again = try Codebook.build(arena.allocator(), &budget, .{
            .dimensions = book.dimensions,
            .lengths = book.lengths,
            .lookup = book.lookup,
            .minimum_packed = book.minimum_packed,
            .delta_packed = book.delta_packed,
            .value_bits = book.value_bits,
            .sequence_p = book.sequence_p,
            .multiplicands = book.multiplicands,
        });
        try testing.expectEqualSlices(u32, book.codes, again.codes);
        try testing.expectEqualSlices(u32, book.fast, again.fast);
        try testing.expectEqualSlices(u32, book.tree, again.tree);
        try testing.expectEqual(book.minimum, again.minimum);
        lattice_seen = lattice_seen or book.lookup == .lattice;
    }
    try testing.expect(lattice_seen);
}
