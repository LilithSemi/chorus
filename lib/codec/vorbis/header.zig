//! The three Vorbis header packets: identification, comment and setup.
const std = @import("std");
const io = @import("../io.zig");
const vorbis_comment = @import("../vorbis_comment.zig");
const codebook = @import("codebook.zig");
const Codebook = codebook.Codebook;
const Budget = codebook.Budget;
const take = codebook.take;
const takeBit = codebook.takeBit;
const ilog = codebook.ilog;

pub const min_blocksize = 64;
pub const max_blocksize = 8192;
pub const max_books = 256;
/// The most points that a floor 1 X list holds, with the two implicit ones.
pub const max_floor1_points = 65;
pub const max_residue_classes = 64;

pub const Identification = struct {
    channels: u8,
    rate: u32,
    /// The bitrate fields are hints. 0 or less means unknown.
    bitrate_maximum: i32,
    bitrate_nominal: i32,
    bitrate_minimum: i32,
    /// The short block size.
    blocksize_0: u16,
    /// The long block size.
    blocksize_1: u16,
};

pub const Floor0 = struct {
    order: u8,
    rate: u16,
    bark_map_size: u16,
    amplitude_bits: u8,
    amplitude_offset: u8,
    /// Book numbers. Each book has a lookup.
    books: []const u8,
};

pub const Floor1Class = struct {
    dimensions: u8,
    subclasses: u8,
    /// Only read when `subclasses` is not 0.
    masterbook: u8,
    /// The book of each subclass, or -1 for none. Entries from `1 << subclasses` on are -1.
    subclass_books: [8]i16,
};

pub const Floor1 = struct {
    /// The class of each partition.
    partition_classes: []const u8,
    classes: []const Floor1Class,
    /// 1 to 4
    multiplier: u8,
    rangebits: u8,
    /// The X values in list order. `x[0]` is 0 and `x[1]` is `1 << rangebits`.
    x: []const u16,
    /// The indexes of `x`, sorted by value.
    order: []const u8,
    /// For `i >= 2`, the index below `i` of the greatest X below `x[i]`. 0 for `i < 2`.
    low: []const u8,
    /// For `i >= 2`, the index below `i` of the least X above `x[i]`. 0 for `i < 2`.
    high: []const u8,

    /// The number of Y levels: 256, 128, 86 or 64.
    pub fn range(self: Floor1) u16 {
        return ([_]u16{ 256, 128, 86, 64 })[self.multiplier - 1];
    }
};

pub const Floor = union(enum) {
    zero: Floor0,
    one: Floor1,
};

pub const Residue = struct {
    /// 0, 1 or 2
    kind: u2,
    begin: u32,
    end: u32,
    partition_size: u32,
    classifications: u8,
    classbook: u8,
    /// For each class, the book of each of the 8 passes, or -1 for none. Each book has a lookup.
    books: []const [8]i16,
};

pub const Coupling = struct {
    magnitude: u8,
    angle: u8,
};

pub const Submap = struct {
    floor: u8,
    residue: u8,
};

pub const Mapping = struct {
    submaps: []const Submap,
    /// In stream order. The decoder undoes them in reverse.
    coupling: []const Coupling,
    /// The submap of each channel.
    mux: []const u8,
};

pub const Mode = struct {
    /// True for the long block size.
    long: bool,
    mapping: u8,
};

pub const ParseError = error{ BadHeader, OutOfMemory };

/// The packet type byte and the string "vorbis" start every header packet.
fn headerBody(packet: []const u8, kind: u8) error{BadHeader}![]const u8 {
    if (packet.len < 7 or packet[0] != kind) return error.BadHeader;
    if (!std.mem.eql(u8, packet[1..7], "vorbis")) return error.BadHeader;
    return packet[7..];
}

pub fn parseIdentification(packet: []const u8) error{BadHeader}!Identification {
    const body = try headerBody(packet, 1);
    if (body.len < 23) return error.BadHeader;
    if (std.mem.readInt(u32, body[0..4], .little) != 0) return error.BadHeader;
    const channels = body[4];
    const rate = std.mem.readInt(u32, body[5..9], .little);
    if (channels == 0 or rate == 0) return error.BadHeader;
    const sizes = body[21];
    const exp_0: u4 = @truncate(sizes);
    const exp_1: u4 = @truncate(sizes >> 4);
    if (exp_0 < 6 or exp_0 > 13 or exp_1 < 6 or exp_1 > 13 or exp_0 > exp_1) return error.BadHeader;
    if (body[22] & 1 != 1) return error.BadHeader;
    return .{
        .channels = channels,
        .rate = rate,
        .bitrate_maximum = std.mem.readInt(i32, body[9..13], .little),
        .bitrate_nominal = std.mem.readInt(i32, body[13..17], .little),
        .bitrate_minimum = std.mem.readInt(i32, body[17..21], .little),
        .blocksize_0 = @as(u16, 1) << exp_0,
        .blocksize_1 = @as(u16, 1) << exp_1,
    };
}

/// Checks the comment header, including its framing bit. The result borrows `packet`.
pub fn parseComment(packet: []const u8) error{BadHeader}!vorbis_comment.Comments {
    const comments = try vorbis_comment.Comments.parse(try headerBody(packet, 3));
    var it = comments.iterator();
    while (try it.next() != null) {}
    if (it.rest.len == 0 or it.rest[0] & 1 != 1) return error.BadHeader;
    return comments;
}

/// The parsed setup header. Every slice points into memory that the caller's allocator
/// gave, and the setup frees nothing. The caller owns that memory, for example an arena.
pub const Setup = struct {
    channels: u8,
    /// The bytes of the setup packet that hold the header, including the framing bit.
    size: usize,
    /// The bytes that the parse asked the allocator for, without alignment padding.
    bytes: usize,
    books: []const Codebook,
    floors: []const Floor,
    residues: []const Residue,
    mappings: []const Mapping,
    modes: []const Mode,

    /// Reads a setup packet for a stream of `channels` channels. Everything comes from `a`.
    /// A parse that asks for more than `max_bytes` gives error.BadHeader before it
    /// allocates the part that is too big. A failed parse leaves its memory with the caller.
    pub fn parse(a: std.mem.Allocator, packet: []const u8, channels: u8, max_bytes: usize) ParseError!Setup {
        if (channels == 0) return error.BadHeader;
        const body = try headerBody(packet, 5);
        var budget: Budget = .{ .max = max_bytes };
        var r: io.LsbReader = .init(body);

        const books = try budget.alloc(a, Codebook, try take(&r, 8) + 1);
        for (books) |*book| book.* = try Codebook.parse(a, &r, &budget);

        var times = try take(&r, 6) + 1;
        while (times > 0) : (times -= 1) {
            if (try take(&r, 16) != 0) return error.BadHeader;
        }

        const floors = try budget.alloc(a, Floor, try take(&r, 6) + 1);
        for (floors) |*floor| floor.* = try parseFloor(a, &budget, &r, books);

        const residues = try budget.alloc(a, Residue, try take(&r, 6) + 1);
        for (residues) |*residue| residue.* = try parseResidue(a, &budget, &r, books);

        const mappings = try budget.alloc(a, Mapping, try take(&r, 6) + 1);
        for (mappings) |*mapping| mapping.* = try parseMapping(a, &budget, &r, channels, floors.len, residues.len);

        const modes = try budget.alloc(a, Mode, try take(&r, 6) + 1);
        for (modes) |*mode| {
            const long = try takeBit(&r);
            if (try take(&r, 16) != 0 or try take(&r, 16) != 0) return error.BadHeader;
            const mapping = try take(&r, 8);
            if (mapping >= mappings.len) return error.BadHeader;
            mode.* = .{ .long = long, .mapping = @intCast(mapping) };
        }
        if (!try takeBit(&r)) return error.BadHeader;

        return .{
            .channels = channels,
            .size = 7 + r.bytePosition(),
            .bytes = budget.used,
            .books = books,
            .floors = floors,
            .residues = residues,
            .mappings = mappings,
            .modes = modes,
        };
    }

    /// The size of a `std.heap.FixedBufferAllocator` buffer that `parse` of this packet
    /// fits in, alignment included. The buffer must start at an address that is a multiple
    /// of 16. `gpa` only backs the measuring and gets everything back.
    pub fn measure(gpa: std.mem.Allocator, packet: []const u8, channels: u8, max_bytes: usize) ParseError!usize {
        var counter: CountingAllocator = .{ .gpa = gpa };
        defer counter.deinit();
        _ = try parse(counter.allocator(), packet, channels, max_bytes);
        return counter.offset;
    }

    /// The width of the mode number in an audio packet.
    pub fn modeBits(self: *const Setup) u6 {
        return ilog(@intCast(self.modes.len - 1));
    }
};

/// Hands out real memory from `gpa` and adds up the size that a bump allocator over a
/// buffer aligned to 16 would use.
const CountingAllocator = struct {
    gpa: std.mem.Allocator,
    offset: usize = 0,
    blocks: std.ArrayList(Block) = .empty,

    const Alignment = std.mem.Alignment;
    const Block = struct { memory: []u8, alignment: Alignment };
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn deinit(self: *CountingAllocator) void {
        for (self.blocks.items) |b| self.gpa.rawFree(b.memory, b.alignment, 0);
        self.blocks.deinit(self.gpa);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        std.debug.assert(alignment.toByteUnits() <= 16);
        const start = std.mem.alignForward(usize, self.offset, alignment.toByteUnits());
        const end = std.math.add(usize, start, len) catch return null;
        const ptr = self.gpa.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.blocks.append(self.gpa, .{ .memory = ptr[0..len], .alignment = alignment }) catch {
            self.gpa.rawFree(ptr[0..len], alignment, ret_addr);
            return null;
        };
        self.offset = end;
        return ptr;
    }

    fn resize(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(_: *anyopaque, _: []u8, _: Alignment, _: usize) void {}
};

fn parseFloor(a: std.mem.Allocator, budget: *Budget, r: *io.LsbReader, books: []const Codebook) ParseError!Floor {
    switch (try take(r, 16)) {
        0 => {
            const order = try take(r, 8);
            const rate = try take(r, 16);
            const bark_map_size = try take(r, 16);
            const amplitude_bits = try take(r, 6);
            const amplitude_offset = try take(r, 8);
            const list = try budget.alloc(a, u8, try take(r, 4) + 1);
            if (order == 0 or rate == 0 or bark_map_size == 0) return error.BadHeader;
            for (list) |*b| {
                const n = try take(r, 8);
                if (n >= books.len or books[n].lookup == .none) return error.BadHeader;
                b.* = @intCast(n);
            }
            return .{ .zero = .{
                .order = @intCast(order),
                .rate = @intCast(rate),
                .bark_map_size = @intCast(bark_map_size),
                .amplitude_bits = @intCast(amplitude_bits),
                .amplitude_offset = @intCast(amplitude_offset),
                .books = list,
            } };
        },
        1 => return .{ .one = try parseFloor1(a, budget, r, books.len) },
        else => return error.BadHeader,
    }
}

/// Fills `order` with the indices of `x` sorted by value. For `i >= 2` it sets `low[i]` and
/// `high[i]` to the nearest earlier posts below and above `x[i]`. `x[0]` must be the least
/// value and `x[1]` the greatest.
pub fn floor1Neighbours(x: []const u16, order: []u8, low: []u8, high: []u8) void {
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u8, order, x, struct {
        fn lessThan(values: []const u16, lhs: u8, rhs: u8) bool {
            return values[lhs] < values[rhs];
        }
    }.lessThan);
    @memset(low, 0);
    @memset(high, 0);
    for (2..x.len) |i| {
        var lo: usize = 0;
        var hi: usize = 1;
        for (0..i) |n| {
            if (x[n] < x[i] and x[n] > x[lo]) lo = n;
            if (x[n] > x[i] and x[n] < x[hi]) hi = n;
        }
        low[i] = @intCast(lo);
        high[i] = @intCast(hi);
    }
}

fn parseFloor1(a: std.mem.Allocator, budget: *Budget, r: *io.LsbReader, book_count: usize) ParseError!Floor1 {
    const partition_classes = try budget.alloc(a, u8, try take(r, 5));
    var class_count: usize = 0;
    for (partition_classes) |*c| {
        c.* = @intCast(try take(r, 4));
        class_count = @max(class_count, @as(usize, c.*) + 1);
    }
    const classes = try budget.alloc(a, Floor1Class, class_count);
    for (classes) |*class| {
        const dimensions = try take(r, 3) + 1;
        const subclasses = try take(r, 2);
        var masterbook: u32 = 0;
        if (subclasses != 0) {
            masterbook = try take(r, 8);
            if (masterbook >= book_count) return error.BadHeader;
        }
        var subclass_books: [8]i16 = @splat(-1);
        for (subclass_books[0 .. @as(usize, 1) << @intCast(subclasses)]) |*b| {
            const stored = try take(r, 8);
            if (stored != 0 and stored - 1 >= book_count) return error.BadHeader;
            b.* = @as(i16, @intCast(stored)) - 1;
        }
        class.* = .{
            .dimensions = @intCast(dimensions),
            .subclasses = @intCast(subclasses),
            .masterbook = @intCast(masterbook),
            .subclass_books = subclass_books,
        };
    }
    const multiplier = try take(r, 2) + 1;
    const rangebits: u6 = @intCast(try take(r, 4));

    var points: usize = 2;
    for (partition_classes) |c| points += classes[c].dimensions;
    if (points > max_floor1_points) return error.BadHeader;
    const x = try budget.alloc(a, u16, points);
    x[0] = 0;
    x[1] = @as(u16, 1) << @intCast(rangebits);
    for (x[2..]) |*v| v.* = @intCast(try take(r, rangebits));

    const order = try budget.alloc(a, u8, points);
    const low = try budget.alloc(a, u8, points);
    const high = try budget.alloc(a, u8, points);
    floor1Neighbours(x, order, low, high);
    for (order[1..], 1..) |o, i| {
        if (x[order[i - 1]] == x[o]) return error.BadHeader;
    }
    return .{
        .partition_classes = partition_classes,
        .classes = classes,
        .multiplier = @intCast(multiplier),
        .rangebits = rangebits,
        .x = x,
        .order = order,
        .low = low,
        .high = high,
    };
}

fn parseResidue(a: std.mem.Allocator, budget: *Budget, r: *io.LsbReader, books: []const Codebook) ParseError!Residue {
    const kind = try take(r, 16);
    if (kind > 2) return error.BadHeader;
    const begin = try take(r, 24);
    const end = try take(r, 24);
    const partition_size = try take(r, 24) + 1;
    const classifications = try take(r, 6) + 1;
    const classbook = try take(r, 8);
    if (classbook >= books.len) return error.BadHeader;

    // The class codeword holds one class per dimension of the class book.
    const class_book = books[classbook];
    if (class_book.dimensions == 0) return error.BadHeader;
    var combinations: u64 = 1;
    for (0..class_book.dimensions) |_| {
        combinations *= classifications;
        if (combinations > class_book.entries) return error.BadHeader;
    }

    const cascade = try budget.alloc(a, u8, classifications);
    for (cascade) |*c| {
        const low = try take(r, 3);
        const high = if (try takeBit(r)) try take(r, 5) else 0;
        c.* = @intCast(high * 8 + low);
    }
    const class_books = try budget.alloc(a, [8]i16, classifications);
    for (class_books, cascade) |*row, bits| {
        row.* = @splat(-1);
        for (row, 0..) |*slot, pass| {
            if (bits >> @intCast(pass) & 1 == 0) continue;
            const n = try take(r, 8);
            if (n >= books.len or books[n].lookup == .none) return error.BadHeader;
            slot.* = @intCast(n);
        }
    }
    return .{
        .kind = @intCast(kind),
        .begin = begin,
        .end = end,
        .partition_size = partition_size,
        .classifications = @intCast(classifications),
        .classbook = @intCast(classbook),
        .books = class_books,
    };
}

fn parseMapping(
    a: std.mem.Allocator,
    budget: *Budget,
    r: *io.LsbReader,
    channels: u8,
    floor_count: usize,
    residue_count: usize,
) ParseError!Mapping {
    if (try take(r, 16) != 0) return error.BadHeader;
    const submap_count: u32 = if (try takeBit(r)) try take(r, 4) + 1 else 1;
    var coupling: []Coupling = &.{};
    if (try takeBit(r)) {
        coupling = try budget.alloc(a, Coupling, try take(r, 8) + 1);
        const width = ilog(channels - 1);
        for (coupling) |*c| {
            const magnitude = try take(r, width);
            const angle = try take(r, width);
            if (magnitude >= channels or angle >= channels or magnitude == angle) return error.BadHeader;
            c.* = .{ .magnitude = @intCast(magnitude), .angle = @intCast(angle) };
        }
    }
    if (try take(r, 2) != 0) return error.BadHeader;
    const mux = try budget.alloc(a, u8, channels);
    @memset(mux, 0);
    if (submap_count > 1) {
        for (mux) |*m| {
            const v = try take(r, 4);
            if (v >= submap_count) return error.BadHeader;
            m.* = @intCast(v);
        }
    }
    const submaps = try budget.alloc(a, Submap, submap_count);
    for (submaps) |*s| {
        _ = try take(r, 8);
        const floor = try take(r, 8);
        const residue = try take(r, 8);
        if (floor >= floor_count or residue >= residue_count) return error.BadHeader;
        s.* = .{ .floor = @intCast(floor), .residue = @intCast(residue) };
    }
    return .{ .submaps = submaps, .coupling = coupling, .mux = mux };
}

const helpers = @import("testing.zig");
const testing = std.testing;

const test_budget = 16 << 20;

fn tryParse(packet: []const u8, channels: u8) ParseError!void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = try Setup.parse(arena.allocator(), packet, channels, test_budget);
}

fn expectBadSetup(opts: helpers.SetupOpts) !void {
    const packet = try helpers.buildSetup(testing.allocator, opts);
    defer testing.allocator.free(packet);
    try testing.expectError(error.BadHeader, tryParse(packet, 2));
}

test "identification header fields" {
    const packet = helpers.buildIdentification(2, 44100, 8, 11);
    const id = try parseIdentification(&packet);
    try testing.expectEqual(@as(u8, 2), id.channels);
    try testing.expectEqual(@as(u32, 44100), id.rate);
    try testing.expectEqual(@as(u16, 256), id.blocksize_0);
    try testing.expectEqual(@as(u16, 2048), id.blocksize_1);
    try testing.expectEqual(@as(i32, 0), id.bitrate_maximum);
    try testing.expectEqual(@as(i32, 128000), id.bitrate_nominal);
    try testing.expectEqual(@as(i32, 0), id.bitrate_minimum);
    const equal = helpers.buildIdentification(1, 8000, 9, 9);
    try testing.expectEqual(@as(u16, 512), (try parseIdentification(&equal)).blocksize_1);
    const wide = helpers.buildIdentification(255, 1, 6, 13);
    const wid = try parseIdentification(&wide);
    try testing.expectEqual(@as(u16, 64), wid.blocksize_0);
    try testing.expectEqual(@as(u16, 8192), wid.blocksize_1);
}

test "identification header negative bitrates are signed" {
    var packet = helpers.buildIdentification(2, 44100, 8, 11);
    std.mem.writeInt(i32, packet[16..20], -1, .little);
    try testing.expectEqual(@as(i32, -1), (try parseIdentification(&packet)).bitrate_maximum);
}

test "identification header checks" {
    const good = helpers.buildIdentification(2, 44100, 8, 11);
    var p = good;
    p[0] = 3;
    try testing.expectError(error.BadHeader, parseIdentification(&p));
    p = good;
    p[3] = 'x';
    try testing.expectError(error.BadHeader, parseIdentification(&p));
    p = good;
    p[7] = 1;
    try testing.expectError(error.BadHeader, parseIdentification(&p));
    p = good;
    p[11] = 0;
    try testing.expectError(error.BadHeader, parseIdentification(&p));
    p = good;
    @memset(p[12..16], 0);
    try testing.expectError(error.BadHeader, parseIdentification(&p));
    for ([_][2]u4{ .{ 5, 11 }, .{ 8, 14 }, .{ 12, 8 }, .{ 0, 0 }, .{ 15, 15 } }) |e| {
        const bad = helpers.buildIdentification(2, 44100, e[0], e[1]);
        try testing.expectError(error.BadHeader, parseIdentification(&bad));
    }
    p = good;
    p[29] = 0;
    try testing.expectError(error.BadHeader, parseIdentification(&p));
    p = good;
    p[29] = 2;
    try testing.expectError(error.BadHeader, parseIdentification(&p));
    for (0..good.len) |cut| try testing.expectError(error.BadHeader, parseIdentification(good[0..cut]));
}

test "comment header needs the framing bit" {
    const packet = "\x03vorbis" ++ "\x06\x00\x00\x00chorus" ++ "\x01\x00\x00\x00" ++ "\x07\x00\x00\x00A=bcdef" ++ "\x01";
    const comments = try parseComment(packet);
    try testing.expectEqualStrings("chorus", comments.vendor);
    try testing.expectEqual(@as(u32, 1), comments.count);
    var it = comments.iterator();
    const tag = (try it.next()).?;
    try testing.expectEqualStrings("A", tag.name);
    try testing.expectEqualStrings("bcdef", tag.value);

    try testing.expectError(error.BadHeader, parseComment(packet[0 .. packet.len - 1]));
    var bad = packet.*;
    bad[bad.len - 1] = 0;
    try testing.expectError(error.BadHeader, parseComment(&bad));
    bad = packet.*;
    bad[0] = 5;
    try testing.expectError(error.BadHeader, parseComment(&bad));
    bad = packet.*;
    bad[7] = 200;
    try testing.expectError(error.BadHeader, parseComment(&bad));
    try testing.expectError(error.BadHeader, parseComment("\x03vorbis"));
    // A count that is larger than the tags the packet holds.
    bad = packet.*;
    bad[7 + 4 + 6] = 2;
    try testing.expectError(error.BadHeader, parseComment(&bad));
}

test "a small hand built setup parses to the last byte" {
    const packet = try helpers.buildSetup(testing.allocator, .{});
    defer testing.allocator.free(packet);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const setup = try Setup.parse(arena.allocator(), packet, 2, test_budget);
    try testing.expectEqual(packet.len, setup.size);
    try testing.expectEqual(@as(usize, 3), setup.books.len);
    try testing.expectEqual(codebook.Lookup.lattice, setup.books[1].lookup);

    try testing.expectEqual(@as(usize, 1), setup.floors.len);
    const f = setup.floors[0].one;
    try testing.expectEqual(@as(u8, 2), f.multiplier);
    try testing.expectEqual(@as(u16, 128), f.range());
    try testing.expectEqual(@as(u8, 6), f.rangebits);
    try testing.expectEqualSlices(u8, &.{0}, f.partition_classes);
    try testing.expectEqualSlices(u16, &.{ 0, 64, 20, 40 }, f.x);
    try testing.expectEqualSlices(u8, &.{ 0, 2, 3, 1 }, f.order);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 2 }, f.low);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 1 }, f.high);
    try testing.expectEqual(@as(usize, 1), f.classes.len);
    try testing.expectEqual(@as(u8, 2), f.classes[0].dimensions);
    try testing.expectEqual(@as(u8, 1), f.classes[0].subclasses);
    try testing.expectEqual(@as(i16, 0), f.classes[0].subclass_books[0]);
    try testing.expectEqual(@as(i16, -1), f.classes[0].subclass_books[1]);

    try testing.expectEqual(@as(usize, 1), setup.residues.len);
    const res = setup.residues[0];
    try testing.expectEqual(@as(u2, 2), res.kind);
    try testing.expectEqual(@as(u32, 0), res.begin);
    try testing.expectEqual(@as(u32, 64), res.end);
    try testing.expectEqual(@as(u32, 8), res.partition_size);
    try testing.expectEqual(@as(u8, 4), res.classifications);
    try testing.expectEqual(@as(usize, 4), res.books.len);
    try testing.expectEqual(@as(i16, -1), res.books[0][0]);
    try testing.expectEqual(@as(i16, 1), res.books[3][0]);
    try testing.expectEqual(@as(i16, -1), res.books[3][1]);

    try testing.expectEqual(@as(usize, 1), setup.mappings.len);
    const m = setup.mappings[0];
    try testing.expectEqual(@as(usize, 0), m.coupling.len);
    try testing.expectEqualSlices(u8, &.{ 0, 0 }, m.mux);
    try testing.expectEqual(@as(usize, 1), m.submaps.len);
    try testing.expectEqual(@as(u8, 0), m.submaps[0].floor);

    try testing.expectEqual(@as(usize, 2), setup.modes.len);
    try testing.expect(!setup.modes[0].long);
    try testing.expect(setup.modes[1].long);
    try testing.expectEqual(@as(u6, 1), setup.modeBits());
}

test "floor 0, residue 0 and a lookup type 2 book parse" {
    const packet = try helpers.buildSetup(testing.allocator, .{ .floor_type = 0, .residue_type = 0 });
    defer testing.allocator.free(packet);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const setup = try Setup.parse(arena.allocator(), packet, 2, test_budget);
    try testing.expectEqual(packet.len, setup.size);
    const f = setup.floors[0].zero;
    try testing.expectEqual(@as(u8, 8), f.order);
    try testing.expectEqual(@as(u16, 44100), f.rate);
    try testing.expectEqual(@as(u16, 64), f.bark_map_size);
    try testing.expectEqual(@as(u8, 8), f.amplitude_bits);
    try testing.expectEqual(@as(u8, 100), f.amplitude_offset);
    try testing.expectEqualSlices(u8, &.{2}, f.books);
    try testing.expectEqual(codebook.Lookup.explicit, setup.books[f.books[0]].lookup);
    try testing.expectEqual(@as(u2, 0), setup.residues[0].kind);
}

test "floor 1 with no partitions has the two implicit points" {
    const packet = try helpers.buildSetup(testing.allocator, .{ .floor1_flat = true, .floor1_multiplier = 4 });
    defer testing.allocator.free(packet);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const setup = try Setup.parse(arena.allocator(), packet, 2, test_budget);
    const f = setup.floors[0].one;
    try testing.expectEqual(@as(usize, 0), f.partition_classes.len);
    try testing.expectEqual(@as(usize, 0), f.classes.len);
    try testing.expectEqualSlices(u16, &.{ 0, 64 }, f.x);
    try testing.expectEqual(@as(u16, 64), f.range());
}

test "a mapping with submaps and coupling parses" {
    const packet = try helpers.buildSetup(testing.allocator, .{ .submaps = 2, .mux = .{ 1, 0 }, .coupling = .{ 0, 1 } });
    defer testing.allocator.free(packet);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const setup = try Setup.parse(arena.allocator(), packet, 2, test_budget);
    const m = setup.mappings[0];
    try testing.expectEqual(@as(usize, 1), m.coupling.len);
    try testing.expectEqual(@as(u8, 0), m.coupling[0].magnitude);
    try testing.expectEqual(@as(u8, 1), m.coupling[0].angle);
    try testing.expectEqualSlices(u8, &.{ 1, 0 }, m.mux);
    try testing.expectEqual(@as(usize, 2), m.submaps.len);
}

test "setup limits give BadHeader" {
    try expectBadSetup(.{ .time_value = 1 });
    try expectBadSetup(.{ .floor_type = 2 });
    try expectBadSetup(.{ .residue_type = 3 });
    try expectBadSetup(.{ .mapping_type = 1 });
    try expectBadSetup(.{ .reserved = 1 });
    try expectBadSetup(.{ .coupling = .{ 1, 1 } });
    try expectBadSetup(.{ .submaps = 2, .mux = .{ 2, 0 } });
    try expectBadSetup(.{ .submap_floor = 1 });
    try expectBadSetup(.{ .submap_residue = 1 });
    try expectBadSetup(.{ .window_type = 1 });
    try expectBadSetup(.{ .transform_type = 1 });
    try expectBadSetup(.{ .mode_mapping = 1 });
    try expectBadSetup(.{ .framing = 0 });
    // floor 1 books and X list
    try expectBadSetup(.{ .floor1_masterbook = 3 });
    try expectBadSetup(.{ .floor1_subbook = 4 });
    try expectBadSetup(.{ .floor1_x = .{ 20, 20 } });
    try expectBadSetup(.{ .floor1_x = .{ 0, 5 } });
    // floor 0 book without a lookup, or past the book count
    try expectBadSetup(.{ .floor_type = 0, .floor0_book = 0 });
    try expectBadSetup(.{ .floor_type = 0, .floor0_book = 3 });
    try expectBadSetup(.{ .floor_type = 0, .floor0_order = 0 });
    try expectBadSetup(.{ .floor_type = 0, .floor0_rate = 0 });
    try expectBadSetup(.{ .floor_type = 0, .floor0_bark = 0 });
    // residue books
    try expectBadSetup(.{ .residue_stage_book = 0 });
    try expectBadSetup(.{ .residue_stage_book = 3 });
    try expectBadSetup(.{ .residue_classbook = 3 });
    // 5 classes with a class book of dimension 1 and 4 entries
    try expectBadSetup(.{ .residue_classes = 5 });
}

test "a setup that is cut anywhere gives BadHeader" {
    const packet = try helpers.buildSetup(testing.allocator, .{});
    defer testing.allocator.free(packet);
    for (0..packet.len) |cut| {
        try testing.expectError(error.BadHeader, tryParse(packet[0..cut], 2));
    }
}

test "coupling needs two channels and one channel has no coupling bits" {
    const packet = try helpers.buildSetup(testing.allocator, .{ .coupling = .{ 0, 1 } });
    defer testing.allocator.free(packet);
    try testing.expectError(error.BadHeader, tryParse(packet, 1));
    try testing.expectError(error.BadHeader, tryParse(packet, 0));
}

test "floor 1 with 65 points parses and 66 points do not" {
    const ok = try helpers.buildSetup(testing.allocator, .{ .floor1_wide = 1 });
    defer testing.allocator.free(ok);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const setup = try Setup.parse(arena.allocator(), ok, 2, test_budget);
    try testing.expectEqual(@as(usize, 65), setup.floors[0].one.x.len);
    try testing.expectEqual(@as(usize, 31), setup.floors[0].one.partition_classes.len);
    try expectBadSetup(.{ .floor1_wide = 2 });
}

const Expect = struct {
    name: []const u8,
    channels: u8,
    rate: u32,
    blocksize_0: u16,
    blocksize_1: u16,
    books: usize,
    /// Floor types in setup order, with 1 for floor 1 and 0 for floor 0.
    floors: []const u8,
    residues: []const u2,
    mappings: usize,
    modes: usize,
    setup_bytes: usize,
};

const expected = [_]Expect{
    .{ .name = "mono8k", .channels = 1, .rate = 8000, .blocksize_0 = 512, .blocksize_1 = 512, .books = 19, .floors = &.{1}, .residues = &.{1}, .mappings = 1, .modes = 1, .setup_bytes = 2476 },
    .{ .name = "stereo44", .channels = 2, .rate = 44100, .blocksize_0 = 256, .blocksize_1 = 2048, .books = 42, .floors = &.{ 1, 1 }, .residues = &.{ 2, 2 }, .mappings = 2, .modes = 2, .setup_bytes = 4140 },
    .{ .name = "noise48", .channels = 2, .rate = 48000, .blocksize_0 = 256, .blocksize_1 = 2048, .books = 44, .floors = &.{ 1, 1 }, .residues = &.{ 2, 2 }, .mappings = 2, .modes = 2, .setup_bytes = 3908 },
    .{ .name = "surround48", .channels = 6, .rate = 48000, .blocksize_0 = 256, .blocksize_1 = 2048, .books = 43, .floors = &.{ 1, 1, 1 }, .residues = &.{ 2, 2, 1 }, .mappings = 2, .modes = 2, .setup_bytes = 7235 },
    .{ .name = "impulse22", .channels = 1, .rate = 22050, .blocksize_0 = 512, .blocksize_1 = 1024, .books = 35, .floors = &.{ 1, 1 }, .residues = &.{ 1, 1 }, .mappings = 2, .modes = 2, .setup_bytes = 3257 },
    .{ .name = "short44", .channels = 2, .rate = 44100, .blocksize_0 = 256, .blocksize_1 = 2048, .books = 42, .floors = &.{ 1, 1 }, .residues = &.{ 2, 2 }, .mappings = 2, .modes = 2, .setup_bytes = 4140 },
    .{ .name = "silence44", .channels = 2, .rate = 44100, .blocksize_0 = 256, .blocksize_1 = 2048, .books = 42, .floors = &.{ 1, 1 }, .residues = &.{ 2, 2 }, .mappings = 2, .modes = 2, .setup_bytes = 4140 },
    .{ .name = "square32", .channels = 2, .rate = 32000, .blocksize_0 = 256, .blocksize_1 = 2048, .books = 44, .floors = &.{ 1, 1 }, .residues = &.{ 2, 2 }, .mappings = 2, .modes = 2, .setup_bytes = 3683 },
    .{ .name = "chain", .channels = 2, .rate = 44100, .blocksize_0 = 256, .blocksize_1 = 2048, .books = 38, .floors = &.{ 1, 1 }, .residues = &.{ 2, 2 }, .mappings = 2, .modes = 2, .setup_bytes = 3796 },
};

fn vectorFile(comptime name: []const u8) []const u8 {
    return helpers.embed(name);
}

fn checkVector(e: Expect, file: []const u8) !void {
    const headers = try helpers.firstHeaders(testing.allocator, file);
    defer headers.deinit(testing.allocator);
    const id = try parseIdentification(headers.identification);
    try testing.expectEqual(e.channels, id.channels);
    try testing.expectEqual(e.rate, id.rate);
    try testing.expectEqual(e.blocksize_0, id.blocksize_0);
    try testing.expectEqual(e.blocksize_1, id.blocksize_1);
    const comments = try parseComment(headers.comment);
    try testing.expect(comments.vendor.len > 0);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const setup = try Setup.parse(arena.allocator(), headers.setup, id.channels, test_budget);
    try testing.expectEqual(e.setup_bytes, headers.setup.len);
    try testing.expectEqual(headers.setup.len, setup.size);
    try testing.expectEqual(e.books, setup.books.len);
    try testing.expectEqual(e.floors.len, setup.floors.len);
    for (e.floors, setup.floors) |want, got| {
        try testing.expectEqual(want == 1, got == .one);
    }
    try testing.expectEqual(e.residues.len, setup.residues.len);
    for (e.residues, setup.residues) |want, got| try testing.expectEqual(want, got.kind);
    try testing.expectEqual(e.mappings, setup.mappings.len);
    try testing.expectEqual(e.modes, setup.modes.len);
    for (setup.mappings) |m| {
        try testing.expectEqual(@as(usize, e.channels), m.mux.len);
    }
}

test "every vendored file parses to the last byte with the framing bit" {
    inline for (expected) |e| try checkVector(e, vectorFile(e.name));
}

test "the stereo setup has the structure that libvorbis writes at quality 4" {
    const headers = try helpers.firstHeaders(testing.allocator, helpers.embed("stereo44"));
    defer headers.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const setup = try Setup.parse(arena.allocator(), headers.setup, 2, test_budget);
    const short = setup.floors[0].one;
    const long = setup.floors[1].one;
    try testing.expectEqual(@as(usize, 4), short.partition_classes.len);
    try testing.expectEqual(@as(usize, 13), short.x.len);
    try testing.expectEqual(@as(u8, 7), short.rangebits);
    try testing.expectEqual(@as(usize, 8), long.partition_classes.len);
    try testing.expectEqual(@as(usize, 29), long.x.len);
    try testing.expectEqual(@as(u8, 10), long.rangebits);
    try testing.expectEqual(@as(u8, 2), long.multiplier);
    try testing.expectEqualSlices(u16, &.{ 0, 1024, 93, 23, 372, 6, 46, 186, 750, 14, 33, 65, 130, 260, 556, 3, 10, 18, 28, 39, 55, 79, 111, 158, 220, 312, 464, 650, 850 }, long.x);
    try testing.expectEqual(@as(u32, 224), setup.residues[0].end);
    try testing.expectEqual(@as(u32, 16), setup.residues[0].partition_size);
    try testing.expectEqual(@as(u32, 1760), setup.residues[1].end);
    try testing.expectEqual(@as(u32, 32), setup.residues[1].partition_size);
    try testing.expectEqual(@as(u8, 10), setup.residues[1].classifications);
    for (setup.mappings) |m| {
        try testing.expectEqual(@as(usize, 1), m.coupling.len);
        try testing.expectEqual(@as(u8, 0), m.coupling[0].magnitude);
        try testing.expectEqual(@as(u8, 1), m.coupling[0].angle);
        try testing.expectEqual(@as(usize, 1), m.submaps.len);
    }
    try testing.expect(!setup.modes[0].long);
    try testing.expect(setup.modes[1].long);
    try testing.expectEqual(@as(u8, 0), setup.modes[0].mapping);
    try testing.expectEqual(@as(u8, 1), setup.modes[1].mapping);
}

test "the surround setup has two submaps and four coupling steps" {
    const headers = try helpers.firstHeaders(testing.allocator, helpers.embed("surround48"));
    defer headers.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const setup = try Setup.parse(arena.allocator(), headers.setup, 6, test_budget);
    const pairs = [_][2]u8{ .{ 0, 2 }, .{ 3, 4 }, .{ 0, 1 }, .{ 0, 3 } };
    for (setup.mappings, 0..) |m, i| {
        try testing.expectEqual(pairs.len, m.coupling.len);
        for (pairs, m.coupling) |want, got| {
            try testing.expectEqual(want[0], got.magnitude);
            try testing.expectEqual(want[1], got.angle);
        }
        try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 1 }, m.mux);
        try testing.expectEqual(@as(usize, 2), m.submaps.len);
        try testing.expectEqual(@as(u8, @intCast(i)), m.submaps[0].floor);
        try testing.expectEqual(@as(u8, 2), m.submaps[1].floor);
        try testing.expectEqual(@as(u8, 2), m.submaps[1].residue);
    }
    try testing.expectEqual(@as(u2, 1), setup.residues[2].kind);
}

test "flipped bits in the vendored headers never crash the parsers" {
    var prng: std.Random.DefaultPrng = .init(0x5652424f);
    const rand = prng.random();
    inline for (expected) |e| {
        const headers = try helpers.firstHeaders(testing.allocator, vectorFile(e.name));
        defer headers.deinit(testing.allocator);
        const copy = try testing.allocator.dupe(u8, headers.setup);
        defer testing.allocator.free(copy);
        for (0..150) |_| {
            const at = rand.intRangeLessThan(usize, 0, copy.len);
            const old = copy[at];
            copy[at] ^= @as(u8, 1) << rand.int(u3);
            _ = tryParse(copy, e.channels) catch |err| try testing.expectEqual(error.BadHeader, err);
            copy[at] = old;
        }
        for (0..20) |_| {
            const cut = rand.intRangeLessThan(usize, 0, copy.len);
            try testing.expectError(error.BadHeader, tryParse(copy[0..cut], e.channels));
        }
        const id = try testing.allocator.dupe(u8, headers.identification);
        defer testing.allocator.free(id);
        for (0..id.len * 8) |bit| {
            id[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
            _ = parseIdentification(id) catch |err| try testing.expectEqual(error.BadHeader, err);
            id[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        }
        const comment = try testing.allocator.dupe(u8, headers.comment);
        defer testing.allocator.free(comment);
        for (0..comment.len * 8) |bit| {
            comment[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
            _ = parseComment(comment) catch |err| try testing.expectEqual(error.BadHeader, err);
            comment[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        }
    }
}

test "random setup bytes never crash the parser" {
    var prng: std.Random.DefaultPrng = .init(0x53455550);
    const rand = prng.random();
    var buf: [400]u8 = undefined;
    for (0..1500) |_| {
        rand.bytes(&buf);
        @memcpy(buf[0..7], "\x05vorbis");
        // Bytes 7 and 8 start a book: the count and the first sync byte.
        buf[7] = rand.intRangeAtMost(u8, 0, 3);
        buf[8] = 0x42;
        buf[9] = 0x43;
        buf[10] = 0x56;
        buf[14] &= 0x01;
        buf[15] = 0;
        const channels = rand.intRangeAtMost(u8, 0, 8);
        _ = tryParse(buf[0..rand.intRangeAtMost(usize, 7, buf.len)], channels) catch |err| try testing.expectEqual(error.BadHeader, err);
    }
}

test "a FixedBufferAllocator of exactly the size from measure parses every vendored file" {
    inline for (expected) |e| {
        const headers = try helpers.firstHeaders(testing.allocator, vectorFile(e.name));
        defer headers.deinit(testing.allocator);
        const need = try Setup.measure(testing.allocator, headers.setup, e.channels, test_budget);
        try testing.expect(need >= e.books);

        const buf = try testing.allocator.alignedAlloc(u8, .@"16", need);
        defer testing.allocator.free(buf);
        var fba: std.heap.FixedBufferAllocator = .init(buf);
        const setup = try Setup.parse(fba.allocator(), headers.setup, e.channels, test_budget);
        try testing.expectEqual(e.books, setup.books.len);
        try testing.expectEqual(need, fba.end_index);

        const small = try testing.allocator.alignedAlloc(u8, .@"16", need - 1);
        defer testing.allocator.free(small);
        var short: std.heap.FixedBufferAllocator = .init(small);
        try testing.expectError(error.OutOfMemory, Setup.parse(short.allocator(), headers.setup, e.channels, test_budget));
    }
}

test "the byte budget of a setup is exact" {
    const headers = try helpers.firstHeaders(testing.allocator, helpers.embed("stereo44"));
    defer headers.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const setup = try Setup.parse(arena.allocator(), headers.setup, 2, test_budget);
    try testing.expect(setup.bytes > 10000);
    try testing.expect(setup.bytes < 1 << 20);
    _ = try Setup.parse(arena.allocator(), headers.setup, 2, setup.bytes);
    try testing.expectError(error.BadHeader, Setup.parse(arena.allocator(), headers.setup, 2, setup.bytes - 1));
}

test "a setup of many huge books is stopped by the budget before it allocates them" {
    var w: io.LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try helpers.writeHeaderStart(&w, 5);
    try w.writeBits(255, 8);
    for (0..256) |_| {
        // Dimension 0, one entry of length 1 and 2^23 entries of length 24.
        const entries: u32 = (1 << 23) + 1;
        try w.writeBits(0x564342, 24);
        try w.writeBits(0, 16);
        try w.writeBits(entries, 24);
        try w.writeBits(1, 1);
        try w.writeBits(0, 5);
        try w.writeBits(1, codebook.ilog(entries));
        for (2..24) |_| try w.writeBits(0, codebook.ilog(entries - 1));
        try w.writeBits(entries - 1, codebook.ilog(entries - 1));
        try w.writeBits(0, 4);
    }
    try testing.expect(w.bytes().len < 21000);
    const budget = 1 << 20;
    var buf: [budget + 4096]u8 align(16) = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    try testing.expectError(error.BadHeader, Setup.parse(fba.allocator(), w.bytes(), 2, budget));
}
