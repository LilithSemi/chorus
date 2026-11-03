//! Residue types 0, 1 and 2: reading the spectrum vectors of one submap from an audio packet.
const std = @import("std");
const io = @import("../io.zig");
const codebook = @import("codebook.zig");
const header = @import("header.zig");
const Codebook = codebook.Codebook;

/// The buffers that `decode` needs, in elements. Both can be shared by all submaps.
pub const Scratch = struct {
    /// The length of `classes`.
    classes: usize,
    /// The length of `vec`.
    vec: usize,
};

/// The most that any residue of the setup needs for blocks of up to `max_n_half` spectrum lines.
pub fn scratch(setup: *const header.Setup, max_n_half: usize) Scratch {
    var s: Scratch = .{ .classes = 0, .vec = 0 };
    for (setup.residues) |res| {
        s.classes = @max(s.classes, classesNeeded(res, setup.books, max_n_half, setup.channels));
        for (res.books) |row| for (row) |b| {
            if (b >= 0) s.vec = @max(s.vec, setup.books[@intCast(b)].dimensions);
        };
    }
    return s;
}

const Plan = struct {
    begin: usize,
    parts: usize,
    /// The vectors that carry classes: all of them, or one for type 2.
    vectors: usize,
    words: usize,
    per_word: usize,

    fn stride(self: Plan) usize {
        return self.words * self.per_word;
    }
};

fn plan(res: header.Residue, books: []const Codebook, n_half: usize, ch_s: usize) ?Plan {
    const per_word: usize = books[res.classbook].dimensions;
    std.debug.assert(per_word > 0);
    const actual = if (res.kind == 2) n_half * ch_s else n_half;
    const begin = @min(res.begin, actual);
    const end = @min(res.end, actual);
    if (end <= begin) return null;
    const parts = (end - begin) / res.partition_size;
    if (parts == 0) return null;
    return .{
        .begin = begin,
        .parts = parts,
        .vectors = if (res.kind == 2) 1 else ch_s,
        .words = (parts + per_word - 1) / per_word,
        .per_word = per_word,
    };
}

fn classesNeeded(res: header.Residue, books: []const Codebook, n_half: usize, ch_s: usize) usize {
    const p = plan(res, books, n_half, ch_s) orelse return 0;
    return p.vectors * p.stride();
}

/// Where the values of a partition go.
const Sink = struct {
    vectors: []const []f32,
    bundle: []const u8,
    interleaved: bool,

    fn add(self: Sink, j: usize, pos: usize, value: f32) void {
        if (self.interleaved) {
            const ch = self.bundle[pos % self.bundle.len];
            self.vectors[ch][pos / self.bundle.len] += value;
        } else {
            self.vectors[self.bundle[j]][pos] += value;
        }
    }
};

/// Adds the residue of one submap to the channel vectors, which the caller has zeroed and
/// which hold `n_half` values each. `bundle` lists the channels of the submap. `no_residue`
/// is indexed by channel and marks the channels without a floor. A packet that ends inside
/// the residue leaves the rest of the vectors as they are. `classes` and `vec` come from `scratch`.
pub fn decode(
    res: header.Residue,
    books: []const Codebook,
    r: *io.LsbReader,
    n_half: usize,
    vectors: []const []f32,
    bundle: []const u8,
    no_residue: []const bool,
    classes: []u8,
    vec: []f32,
) void {
    const ch_s = bundle.len;
    var active = false;
    for (bundle) |ch| active = active or !no_residue[ch];
    if (!active) return;
    const p = plan(res, books, n_half, ch_s) orelse return;
    std.debug.assert(classes.len >= p.vectors * p.stride());

    // libvorbis starts each residue 2 partition at channel 0. When a partition does not
    // hold whole frames, it reads the values in a different order than the spec. This
    // decoder follows the spec.
    const interleaved = res.kind == 2;
    const sink: Sink = .{ .vectors = vectors, .bundle = bundle, .interleaved = interleaved };
    const classbook = &books[res.classbook];
    const classifications: u32 = res.classifications;
    var limit: u64 = 1;
    for (0..p.per_word) |_| limit = @min(limit * classifications, std.math.maxInt(u32));

    for (0..8) |pass| {
        var part: usize = 0;
        while (part < p.parts) {
            if (pass == 0) {
                // With no stage books the spec still reads the class words here and libvorbis does not. This follows the spec.
                for (0..p.vectors) |j| {
                    if (!interleaved and no_residue[bundle[j]]) continue;
                    var word = classbook.decode(r) catch return;
                    if (word >= limit) return;
                    var i = p.per_word;
                    while (i > 0) {
                        i -= 1;
                        classes[j * p.stride() + part + i] = @intCast(word % classifications);
                        word /= classifications;
                    }
                }
            }
            var k: usize = 0;
            while (k < p.per_word and part < p.parts) : ({
                k += 1;
                part += 1;
            }) {
                const offset = p.begin + part * res.partition_size;
                for (0..p.vectors) |j| {
                    if (!interleaved and no_residue[bundle[j]]) continue;
                    const class = classes[j * p.stride() + part];
                    const book = res.books[class][pass];
                    if (book < 0) continue;
                    readPartition(res.kind, &books[@intCast(book)], r, vec, sink, j, offset, res.partition_size) catch return;
                }
            }
        }
    }
}

fn readPartition(
    kind: u2,
    book: *const Codebook,
    r: *io.LsbReader,
    vec: []f32,
    sink: Sink,
    j: usize,
    offset: usize,
    n: usize,
) error{Truncated}!void {
    const dim: usize = book.dimensions;
    std.debug.assert(dim > 0 and vec.len >= dim);
    const e = vec[0..dim];
    if (kind == 0) {
        const step = n / dim;
        for (0..step) |i| {
            book.vector(try book.decode(r), e);
            for (e, 0..) |v, d| sink.add(j, offset + i + d * step, v);
        }
        return;
    }
    var i: usize = 0;
    while (i < n) {
        book.vector(try book.decode(r), e);
        for (e) |v| {
            if (i >= n) break;
            sink.add(j, offset + i, v);
            i += 1;
        }
    }
}

const testing = std.testing;
const vtesting = @import("testing.zig");

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    /// 0: four entry class book, 1: explicit vectors of two, 2: lattice of two, 3: sixteen wide scalar
    books: [4]Codebook,

    fn init() !Fixture {
        var self: Fixture = .{ .arena_state = .init(testing.allocator), .books = undefined };
        const arena = self.arena_state.allocator();
        self.books = .{
            try vtesting.parseBook(arena, vtesting.book_scalar_4),
            try vtesting.parseBook(arena, vtesting.book_explicit),
            try vtesting.parseBook(arena, vtesting.book_lattice),
            try vtesting.parseBook(arena, vtesting.book_scalar_4),
        };
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.arena_state.deinit();
    }
};

fn simpleResidue(kind: u2, end: u32, size: u32) header.Residue {
    return .{
        .kind = kind,
        .begin = 0,
        .end = end,
        .partition_size = size,
        .classifications = 2,
        .classbook = 0,
        .books = &.{
            .{ -1, -1, -1, -1, -1, -1, -1, -1 },
            .{ 1, -1, -1, -1, -1, -1, -1, -1 },
        },
    };
}

// Explicit book entry e is the vector (2e - 4, 2e - 3).
test "residue 1 adds the vectors of a partition in order" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try vtesting.putCode(&w, fx.books[0], 1);
    try vtesting.putCode(&w, fx.books[1], 3);
    try vtesting.putCode(&w, fx.books[1], 0);
    try vtesting.putCode(&w, fx.books[0], 0);
    var r: io.LsbReader = .init(w.bytes());
    var v: [8]f32 = @splat(0);
    var classes: [8]u8 = undefined;
    var vec: [2]f32 = undefined;
    decode(simpleResidue(1, 8, 4), &fx.books, &r, 8, &.{&v}, &.{0}, &.{false}, &classes, &vec);
    try testing.expectEqualSlices(f32, &.{ 2, 3, -4, -3, 0, 0, 0, 0 }, &v);
}

test "residue 0 interleaves the vector across the partition" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try vtesting.putCode(&w, fx.books[0], 1);
    try vtesting.putCode(&w, fx.books[1], 3);
    try vtesting.putCode(&w, fx.books[1], 0);
    var r: io.LsbReader = .init(w.bytes());
    var v: [8]f32 = @splat(0);
    var classes: [2]u8 = undefined;
    var vec: [2]f32 = undefined;
    decode(simpleResidue(0, 4, 4), &fx.books, &r, 8, &.{&v}, &.{0}, &.{false}, &classes, &vec);
    try testing.expectEqualSlices(f32, &.{ 2, -4, 3, -3, 0, 0, 0, 0 }, &v);
}

test "residue begin and end are clamped and later passes add" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var res = simpleResidue(1, 100, 4);
    res.begin = 4;
    res.books = &.{
        .{ -1, -1, -1, -1, -1, -1, -1, -1 },
        .{ 1, 1, -1, -1, -1, -1, -1, -1 },
    };
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    // pass 0 reads the class word and the data, pass 1 only the data
    try vtesting.putCode(&w, fx.books[0], 1);
    try vtesting.putCode(&w, fx.books[1], 3);
    try vtesting.putCode(&w, fx.books[1], 3);
    try vtesting.putCode(&w, fx.books[1], 2);
    try vtesting.putCode(&w, fx.books[1], 1);
    var r: io.LsbReader = .init(w.bytes());
    var v: [8]f32 = @splat(0);
    var classes: [2]u8 = undefined;
    var vec: [2]f32 = undefined;
    decode(res, &fx.books, &r, 8, &.{&v}, &.{0}, &.{false}, &classes, &vec);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0, 2, 4, 0, 2 }, &v);
    try testing.expectEqual(w.nbits, r.pos);
}

test "residue class words hold several classes, first class in the highest digit" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var res = simpleResidue(1, 8, 4);
    res.classifications = 3;
    res.classbook = 2;
    res.books = &.{
        .{ -1, -1, -1, -1, -1, -1, -1, -1 },
        .{ 1, -1, -1, -1, -1, -1, -1, -1 },
        .{ 2, -1, -1, -1, -1, -1, -1, -1 },
    };
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    // entry 5 is 1 * 3 + 2, so the classes are 1 and 2
    try vtesting.putCode(&w, fx.books[2], 5);
    try vtesting.putCode(&w, fx.books[1], 2);
    try vtesting.putCode(&w, fx.books[1], 1);
    // lattice entry e is (m[e % 3] - 1, m[e / 3 % 3] - 1)
    try vtesting.putCode(&w, fx.books[2], 1);
    try vtesting.putCode(&w, fx.books[2], 6);
    var r: io.LsbReader = .init(w.bytes());
    var v: [8]f32 = @splat(0);
    var classes: [2]u8 = undefined;
    var vec: [2]f32 = undefined;
    decode(res, &fx.books, &r, 8, &.{&v}, &.{0}, &.{false}, &classes, &vec);
    try testing.expectEqualSlices(f32, &.{ 0, 1, -2, -1, 0, -1, -1, 1 }, &v);
}

test "residue 2 equals residue 1 on the interleaved vector" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var res = simpleResidue(2, 100, 4);
    res.books = &.{
        .{ 1, 1, -1, -1, -1, -1, -1, -1 },
        .{ 1, -1, -1, -1, -1, -1, -1, -1 },
    };
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    // 16 values in 4 partitions, classes 0, 1, 1, 0
    const classes_in = [_]usize{ 0, 1, 1, 0 };
    var seed: usize = 1;
    for (classes_in) |class| {
        try vtesting.putCode(&w, fx.books[0], class);
        for (0..2) |_| {
            seed = (seed * 5 + 3) % 4;
            try vtesting.putCode(&w, fx.books[1], seed);
        }
    }
    for (0..2) |_| {
        for (0..2) |_| {
            seed = (seed * 5 + 3) % 4;
            try vtesting.putCode(&w, fx.books[1], seed);
        }
    }

    var a: [8]f32 = @splat(0);
    var b: [8]f32 = @splat(0);
    var classes: [4]u8 = undefined;
    var vec: [2]f32 = undefined;
    var r: io.LsbReader = .init(w.bytes());
    decode(res, &fx.books, &r, 8, &.{ &a, &b }, &.{ 0, 1 }, &.{ false, false }, &classes, &vec);
    const end_two = r.pos;

    var one: [16]f32 = @splat(0);
    res.kind = 1;
    r = .init(w.bytes());
    decode(res, &fx.books, &r, 16, &.{&one}, &.{0}, &.{false}, &classes, &vec);
    try testing.expectEqual(end_two, r.pos);
    try testing.expectEqual(w.nbits, r.pos);
    for (0..8) |i| {
        try testing.expectEqual(one[i * 2], a[i]);
        try testing.expectEqual(one[i * 2 + 1], b[i]);
    }
    var sum: f32 = 0;
    for (one) |x| sum += @abs(x);
    try testing.expect(sum > 0);
}

test "residue 1 skips the class word of a channel without a floor" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try vtesting.putCode(&w, fx.books[0], 1);
    try vtesting.putCode(&w, fx.books[1], 3);
    try vtesting.putCode(&w, fx.books[1], 0);
    var r: io.LsbReader = .init(w.bytes());
    var a: [4]f32 = @splat(0);
    var b: [4]f32 = @splat(0);
    var classes: [8]u8 = undefined;
    var vec: [2]f32 = undefined;
    decode(simpleResidue(1, 4, 4), &fx.books, &r, 4, &.{ &a, &b }, &.{ 0, 1 }, &.{ true, false }, &classes, &vec);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &a);
    try testing.expectEqualSlices(f32, &.{ 2, 3, -4, -3 }, &b);
}

test "residue 2 reads nothing when every channel is without a floor" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var r: io.LsbReader = .init(&.{ 0xff, 0xff });
    var a: [4]f32 = @splat(0);
    var b: [4]f32 = @splat(0);
    var classes: [8]u8 = undefined;
    var vec: [2]f32 = undefined;
    decode(simpleResidue(2, 100, 4), &fx.books, &r, 4, &.{ &a, &b }, &.{ 0, 1 }, &.{ true, true }, &classes, &vec);
    try testing.expectEqual(@as(usize, 0), r.pos);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &a);
}

test "residue 2 decodes all channels once one is active" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try vtesting.putCode(&w, fx.books[0], 1);
    try vtesting.putCode(&w, fx.books[1], 3);
    try vtesting.putCode(&w, fx.books[1], 0);
    var r: io.LsbReader = .init(w.bytes());
    var a: [2]f32 = @splat(0);
    var b: [2]f32 = @splat(0);
    var classes: [8]u8 = undefined;
    var vec: [2]f32 = undefined;
    decode(simpleResidue(2, 100, 4), &fx.books, &r, 2, &.{ &a, &b }, &.{ 0, 1 }, &.{ true, false }, &classes, &vec);
    // the interleaved vector is 2 3 -4 -3
    try testing.expectEqualSlices(f32, &.{ 2, -4 }, &a);
    try testing.expectEqualSlices(f32, &.{ 3, -3 }, &b);
}

test "residue stops at the end of the packet and keeps what it has" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    // the class word and three vectors fill the byte, the fourth vector is missing
    try vtesting.putCode(&w, fx.books[0], 1);
    try vtesting.putCode(&w, fx.books[1], 3);
    try vtesting.putCode(&w, fx.books[1], 0);
    try vtesting.putCode(&w, fx.books[1], 1);
    var r: io.LsbReader = .init(w.bytes());
    var v: [8]f32 = @splat(0);
    var classes: [2]u8 = undefined;
    var vec: [2]f32 = undefined;
    decode(simpleResidue(1, 8, 8), &fx.books, &r, 8, &.{&v}, &.{0}, &.{false}, &classes, &vec);
    try testing.expectEqualSlices(f32, &.{ 2, 3, -4, -3, -2, -1, 0, 0 }, &v);
}

test "residue stops at a class word past the class count" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var res = simpleResidue(1, 8, 4);
    res.classifications = 3;
    res.books = &.{
        .{ -1, -1, -1, -1, -1, -1, -1, -1 },
        .{ 1, -1, -1, -1, -1, -1, -1, -1 },
        .{ 1, -1, -1, -1, -1, -1, -1, -1 },
    };
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try vtesting.putCode(&w, fx.books[0], 3);
    try vtesting.putCode(&w, fx.books[1], 3);
    try vtesting.putCode(&w, fx.books[1], 3);
    var r: io.LsbReader = .init(w.bytes());
    var v: [8]f32 = @splat(0);
    var classes: [2]u8 = undefined;
    var vec: [2]f32 = undefined;
    decode(res, &fx.books, &r, 8, &.{&v}, &.{0}, &.{false}, &classes, &vec);
    try testing.expectEqualSlices(f32, &@as([8]f32, @splat(0)), &v);
    try testing.expectEqual(@as(usize, 2), r.pos);
}

test "residue with an empty range reads nothing" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var res = simpleResidue(1, 3, 4);
    var r: io.LsbReader = .init(&.{0xff});
    var v: [8]f32 = @splat(0);
    var classes: [2]u8 = undefined;
    var vec: [2]f32 = undefined;
    decode(res, &fx.books, &r, 8, &.{&v}, &.{0}, &.{false}, &classes, &vec);
    try testing.expectEqual(@as(usize, 0), r.pos);
    res.begin = 6;
    res.end = 2;
    decode(res, &fx.books, &r, 8, &.{&v}, &.{0}, &.{false}, &classes, &vec);
    try testing.expectEqual(@as(usize, 0), r.pos);
}

test "residue scratch sizes follow the setup" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const packet = try vtesting.buildSetup(testing.allocator, .{});
    defer testing.allocator.free(packet);
    const setup = try header.Setup.parse(arena_state.allocator(), packet, 2, 1 << 20);
    // residue type 2, end 64, partition size 8: 2 * 32 lines make 64 limited to 64 values, 8 parts
    try testing.expectEqual(Scratch{ .classes = 8, .vec = 2 }, scratch(&setup, 32));
    try testing.expectEqual(Scratch{ .classes = 8, .vec = 2 }, scratch(&setup, 1024));
    try testing.expectEqual(Scratch{ .classes = 4, .vec = 2 }, scratch(&setup, 16));
}

fn putPartitions(w: *io.LsbWriter, fx: *const Fixture, entries: []const usize) !void {
    var i: usize = 0;
    while (i < entries.len) : (i += 2) {
        try vtesting.putCode(w, fx.books[0], 1);
        try vtesting.putCode(w, fx.books[1], entries[i]);
        try vtesting.putCode(w, fx.books[1], entries[i + 1]);
    }
}

test "residue 2 limit follows the channel count" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try putPartitions(&w, &fx, &.{ 3, 0, 1, 2, 3, 3 });
    var a: [4]f32 = @splat(0);
    var b: [4]f32 = @splat(0);
    var c: [4]f32 = @splat(0);
    var classes: [4]u8 = undefined;
    var vec: [2]f32 = undefined;
    var r: io.LsbReader = .init(w.bytes());
    // 3 channels of 4 lines make 12 values and 3 partitions
    decode(simpleResidue(2, 100, 4), &fx.books, &r, 4, &.{ &a, &b, &c }, &.{ 0, 1, 2 }, &.{ false, false, false }, &classes, &vec);
    try testing.expectEqualSlices(f32, &.{ 2, -3, 0, 3 }, &a);
    try testing.expectEqualSlices(f32, &.{ 3, -2, 1, 2 }, &b);
    try testing.expectEqualSlices(f32, &.{ -4, -1, 2, 3 }, &c);
    try testing.expectEqual(w.nbits, r.pos);

    // one channel of 8 lines makes 8 values and 2 partitions
    var w1: io.LsbWriter = .init(testing.allocator);
    defer w1.deinit();
    try putPartitions(&w1, &fx, &.{ 3, 0, 1, 2 });
    var one: [8]f32 = @splat(0);
    r = .init(w1.bytes());
    decode(simpleResidue(2, 100, 4), &fx.books, &r, 8, &.{&one}, &.{0}, &.{false}, &classes, &vec);
    try testing.expectEqualSlices(f32, &.{ 2, 3, -4, -3, -2, -1, 0, 1 }, &one);
    try testing.expectEqual(w1.nbits, r.pos);
}

test "residue end limits the partitions to whole partitions" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try putPartitions(&w, &fx, &.{ 3, 0, 1, 2, 3, 3 });
    var classes: [4]u8 = undefined;
    var vec: [2]f32 = undefined;
    // 15 lines hold 3 partitions of 4 and so do 12
    for ([_]u32{ 15, 12 }) |end| {
        var v: [16]f32 = @splat(0);
        var r: io.LsbReader = .init(w.bytes());
        decode(simpleResidue(1, end, 4), &fx.books, &r, 16, &.{&v}, &.{0}, &.{false}, &classes, &vec);
        try testing.expectEqualSlices(f32, &.{ 2, 3, -4, -3, -2, -1, 0, 1, 2, 3, 2, 3, 0, 0, 0, 0 }, &v);
        try testing.expectEqual(w.nbits, r.pos);
    }
}

test "residue partition size that is not a multiple of the dimension is cut" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try putPartitions(&w, &fx, &.{ 3, 0, 3, 0 });
    var classes: [4]u8 = undefined;
    var vec: [2]f32 = undefined;
    var v: [8]f32 = @splat(0);
    var r: io.LsbReader = .init(w.bytes());
    decode(simpleResidue(1, 6, 3), &fx.books, &r, 8, &.{&v}, &.{0}, &.{false}, &classes, &vec);
    // each partition takes two vectors, the fourth value of the second vector is dropped
    try testing.expectEqualSlices(f32, &.{ 2, 3, -4, 2, 3, -4, 0, 0 }, &v);
    try testing.expectEqual(w.nbits, r.pos);

    // type 0 reads one vector of two values for a partition of three
    var w0: io.LsbWriter = .init(testing.allocator);
    defer w0.deinit();
    try vtesting.putCode(&w0, fx.books[0], 1);
    try vtesting.putCode(&w0, fx.books[1], 3);
    try vtesting.putCode(&w0, fx.books[0], 1);
    try vtesting.putCode(&w0, fx.books[1], 0);
    var v0: [8]f32 = @splat(0);
    r = .init(w0.bytes());
    decode(simpleResidue(0, 6, 3), &fx.books, &r, 8, &.{&v0}, &.{0}, &.{false}, &classes, &vec);
    try testing.expectEqualSlices(f32, &.{ 2, 3, 0, -4, -3, 0, 0, 0 }, &v0);
    try testing.expectEqual(w0.nbits, r.pos);
}

test "residue end past the vector size leaves out the partial partition" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try putPartitions(&w, &fx, &.{ 3, 0, 3, 0 });
    var classes: [4]u8 = undefined;
    var vec: [2]f32 = undefined;
    var v: [8]f32 = @splat(0);
    var r: io.LsbReader = .init(w.bytes());
    // 8 lines hold 2 partitions of 3 and a rest of 2
    decode(simpleResidue(1, 100, 3), &fx.books, &r, 8, &.{&v}, &.{0}, &.{false}, &classes, &vec);
    try testing.expectEqualSlices(f32, &.{ 2, 3, -4, 2, 3, -4, 0, 0 }, &v);
    try testing.expectEqual(w.nbits, r.pos);
}
