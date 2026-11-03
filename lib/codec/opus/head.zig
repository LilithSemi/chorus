//! The two header packets of an Ogg Opus stream: OpusHead and OpusTags (RFC 7845).
const std = @import("std");
const comment = @import("../vorbis_comment.zig");
const testing = std.testing;

pub const head_magic = "OpusHead";
pub const tags_magic = "OpusTags";
/// The channel mapping entry for a channel without a stream.
pub const silent: u8 = 255;

pub const Head = struct {
    version: u8,
    channels: u8,
    /// Samples at 48 kHz that the decoder drops from the start of the stream.
    pre_skip: u16,
    /// The sample rate of the source. It is information only, the output is 48 kHz.
    input_rate: u32,
    /// The output gain in Q7.8 dB.
    gain: i16,
    family: u8,
    streams: u8,
    /// The first `coupled` streams have two channels, the others have one.
    coupled: u8,
    /// For each output channel the stream channel that feeds it, or `silent`. Only the first
    /// `channels` entries are used.
    mapping: [255]u8,
    /// The demixing matrix of family 3, `channels * (streams + coupled)` values of 16 bits (Q15) in
    /// little endian, column by column. It points into the bytes given to `parseHead`. The other
    /// families have none.
    matrix: []const u8 = &.{},

    /// The factor that the output gain asks for.
    pub fn gainFactor(self: *const Head) f32 {
        const db = @as(f64, @floatFromInt(self.gain)) / 256.0;
        return @floatCast(std.math.pow(f64, 10.0, db / 20.0));
    }

    /// Family 1 uses the Vorbis channel order and has a speaker layout.
    pub fn hasLayout(self: *const Head) bool {
        return self.family == 0 or (self.family == 1 and self.channels <= 8);
    }
};

/// Reads an OpusHead packet. Bytes after the fields are ignored. The families 2 and 3 (RFC 8486,
/// ambisonics) need one of the allowed channel counts. The other families above 1 are read as
/// family 255.
pub fn parseHead(data: []const u8) error{BadHeader}!Head {
    if (data.len < 19 or !std.mem.eql(u8, data[0..8], head_magic)) return error.BadHeader;
    var h: Head = .{
        .version = data[8],
        .channels = data[9],
        .pre_skip = std.mem.readInt(u16, data[10..12], .little),
        .input_rate = std.mem.readInt(u32, data[12..16], .little),
        .gain = std.mem.readInt(i16, data[16..18], .little),
        .family = data[18],
        .streams = 1,
        .coupled = 0,
        .mapping = @splat(silent),
    };
    if (h.version >> 4 != 0 or h.channels == 0) return error.BadHeader;
    if (h.family == 0) {
        if (h.channels > 2) return error.BadHeader;
        h.coupled = h.channels - 1;
        h.mapping[0] = 0;
        if (h.channels == 2) h.mapping[1] = 1;
        return h;
    }
    if ((h.family == 2 or h.family == 3) and !ambisonicChannels(h.channels)) return error.BadHeader;
    const table: usize = if (h.family == 3) 0 else h.channels;
    if (data.len < 21 + table) return error.BadHeader;
    h.streams = data[19];
    h.coupled = data[20];
    if (h.streams == 0 or h.coupled > h.streams) return error.BadHeader;
    if (@as(u16, h.streams) + h.coupled > 255) return error.BadHeader;
    if (h.family == 1 and h.channels > 8) return error.BadHeader;
    const limit = h.streams + h.coupled;
    if (h.family == 3) {
        const size = 2 * @as(usize, h.channels) * limit;
        if (data.len - 21 < size) return error.BadHeader;
        h.matrix = data[21..][0..size];
        return h;
    }
    for (data[21..][0..h.channels], 0..) |entry, c| {
        if (entry != silent and entry >= limit) return error.BadHeader;
        h.mapping[c] = entry;
    }
    return h;
}

/// True for the channel counts of ambisonics with an optional pair of fixed stereo channels:
/// (n + 1)^2 or (n + 1)^2 + 2 for an order n from 0 to 14.
pub fn ambisonicChannels(channels: u8) bool {
    for (0..15) |n| {
        const square: u16 = @intCast((n + 1) * (n + 1));
        if (channels == square or channels == square + 2) return true;
    }
    return false;
}

/// Writes an OpusHead packet for `h` and returns the bytes used. `out` needs 21 + 255 bytes, and
/// room for the matrix of family 3.
pub fn writeHead(out: []u8, h: *const Head) []u8 {
    @memcpy(out[0..8], head_magic);
    out[8] = h.version;
    out[9] = h.channels;
    std.mem.writeInt(u16, out[10..12], h.pre_skip, .little);
    std.mem.writeInt(u32, out[12..16], h.input_rate, .little);
    std.mem.writeInt(i16, out[16..18], h.gain, .little);
    out[18] = h.family;
    if (h.family == 0) return out[0..19];
    out[19] = h.streams;
    out[20] = h.coupled;
    if (h.family == 3) {
        @memcpy(out[21..][0..h.matrix.len], h.matrix);
        return out[0 .. 21 + h.matrix.len];
    }
    @memcpy(out[21..][0..h.channels], h.mapping[0..h.channels]);
    return out[0 .. 21 + @as(usize, h.channels)];
}

/// Checks the structure of an OpusTags packet. The tags are not kept.
pub fn checkTags(data: []const u8) error{BadHeader}!void {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], tags_magic)) return error.BadHeader;
    const tags = try comment.Comments.parse(data[8..]);
    var it = tags.iterator();
    while (try it.next() != null) {}
}

pub fn isHead(context: ?*anyopaque, data: []const u8) bool {
    _ = context;
    return data.len >= 8 and std.mem.eql(u8, data[0..8], head_magic);
}

fn headBytes(buf: []u8, channels: u8, family: u8, streams: u8, coupled: u8, table: []const u8) []u8 {
    @memcpy(buf[0..8], head_magic);
    buf[8] = 1;
    buf[9] = channels;
    std.mem.writeInt(u16, buf[10..12], 312, .little);
    std.mem.writeInt(u32, buf[12..16], 44100, .little);
    std.mem.writeInt(i16, buf[16..18], -300, .little);
    buf[18] = family;
    if (family == 0) return buf[0..19];
    buf[19] = streams;
    buf[20] = coupled;
    @memcpy(buf[21..][0..table.len], table);
    return buf[0 .. 21 + table.len];
}

test "family 0 headers have no table" {
    var buf: [64]u8 = undefined;
    const h = try parseHead(headBytes(&buf, 2, 0, 0, 0, &.{}));
    try testing.expectEqual(@as(u8, 2), h.channels);
    try testing.expectEqual(@as(u16, 312), h.pre_skip);
    try testing.expectEqual(@as(u32, 44100), h.input_rate);
    try testing.expectEqual(@as(i16, -300), h.gain);
    try testing.expectEqual(@as(u8, 1), h.streams);
    try testing.expectEqual(@as(u8, 1), h.coupled);
    try testing.expectEqualSlices(u8, &.{ 0, 1 }, h.mapping[0..2]);
    try testing.expect(h.hasLayout());
    const mono = try parseHead(headBytes(&buf, 1, 0, 0, 0, &.{}));
    try testing.expectEqual(@as(u8, 0), mono.coupled);
    try testing.expectEqual(silent, mono.mapping[1]);
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 3, 0, 0, 0, &.{})));
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 0, 0, 0, 0, &.{})));
}

test "family 1 and 255 headers carry a mapping" {
    var buf: [300]u8 = undefined;
    const table = [6]u8{ 0, 4, 1, 2, 3, 5 };
    const h = try parseHead(headBytes(&buf, 6, 1, 4, 2, &table));
    try testing.expectEqual(@as(u8, 4), h.streams);
    try testing.expectEqual(@as(u8, 2), h.coupled);
    try testing.expectEqualSlices(u8, &table, h.mapping[0..6]);
    try testing.expect(h.hasLayout());

    var big: [255]u8 = undefined;
    for (&big, 0..) |*e, i| e.* = @intCast(i);
    const wide = try parseHead(headBytes(&buf, 255, 255, 255, 0, &big));
    try testing.expectEqual(@as(u8, 254), wide.mapping[254]);
    try testing.expect(!wide.hasLayout());
    // A reserved family has no layout.
    const nine = try parseHead(headBytes(&buf, 9, 4, 9, 0, big[0..9]));
    try testing.expect(!nine.hasLayout());
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 9, 1, 9, 0, big[0..9])));
}

test "bad headers are refused" {
    var buf: [300]u8 = undefined;
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 2, 1, 0, 0, &.{ 0, 1 })));
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 2, 1, 1, 2, &.{ 0, 1 })));
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 2, 1, 1, 1, &.{ 0, 2 })));
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 2, 255, 200, 56, &.{ 0, 1 })));
    // A table that is cut short.
    const short = headBytes(&buf, 2, 1, 1, 1, &.{ 0, 1 });
    try testing.expectError(error.BadHeader, parseHead(short[0 .. short.len - 1]));
    // A silent channel is allowed.
    const quiet = try parseHead(headBytes(&buf, 2, 1, 1, 0, &.{ 0, silent }));
    try testing.expectEqual(silent, quiet.mapping[1]);
    const first = headBytes(&buf, 1, 0, 0, 0, &.{});
    buf[8] = 16;
    try testing.expectError(error.BadHeader, parseHead(first));
    buf[8] = 15;
    _ = try parseHead(first);
    buf[0] = 'X';
    try testing.expectError(error.BadHeader, parseHead(first));
    try testing.expectError(error.BadHeader, parseHead(first[0..18]));
}

test "extra bytes after the head are ignored" {
    var buf: [64]u8 = @splat(0xaa);
    _ = headBytes(&buf, 1, 0, 0, 0, &.{});
    _ = try parseHead(buf[0..40]);
}

test "the gain factor follows Q7.8 dB" {
    var buf: [64]u8 = undefined;
    var h = try parseHead(headBytes(&buf, 1, 0, 0, 0, &.{}));
    h.gain = 0;
    try testing.expectEqual(@as(f32, 1.0), h.gainFactor());
    h.gain = 6 * 256;
    try testing.expectApproxEqAbs(@as(f32, 1.9952623), h.gainFactor(), 1e-6);
    h.gain = -20 * 256;
    try testing.expectApproxEqAbs(@as(f32, 0.1), h.gainFactor(), 1e-7);
    h.gain = std.math.minInt(i16);
    try testing.expect(h.gainFactor() > 0);
}

test "tags are checked against their lengths" {
    const good = "OpusTags" ++ "\x04\x00\x00\x00abcd" ++ "\x02\x00\x00\x00" ++ "\x03\x00\x00\x00a=b" ++ "\x01\x00\x00\x00c";
    try checkTags(good);
    try checkTags(good ++ "padding");
    try testing.expectError(error.BadHeader, checkTags(good[0 .. good.len - 1]));
    try testing.expectError(error.BadHeader, checkTags("OpusTag" ++ good[8..]));
    try testing.expectError(error.BadHeader, checkTags("OpusTags\x00\x00"));
    try testing.expectError(error.BadHeader, checkTags("OpusTags\xff\xff\xff\xffabc"));
    try testing.expectError(error.BadHeader, checkTags("OpusTags\x00\x00\x00\x00\xff\xff\xff\xff"));
}

test "random and mutated headers give a result or BadHeader" {
    var prng: std.Random.DefaultPrng = .init(0x7845);
    const random = prng.random();
    var buf: [300]u8 = undefined;
    var scratch: [300]u8 = undefined;
    for (0..20000) |_| {
        const len = random.uintLessThan(usize, buf.len);
        random.bytes(buf[0..len]);
        if (len >= 19 and random.boolean()) @memcpy(buf[0..8], head_magic);
        if (len >= 19) buf[8] &= 0x1f;
        if (len >= 21 and random.boolean()) {
            buf[18] = 2 + random.uintLessThan(u8, 2);
            const counts = [_]u8{ 1, 3, 4, 6, 9, 11, 16, 18, 25, 27 };
            buf[9] = counts[random.uintLessThan(usize, counts.len)];
            buf[19] = 1 + random.uintLessThan(u8, 20);
            buf[20] = random.uintLessThan(u8, 20);
        }
        if (parseHead(buf[0..len])) |h| {
            for (h.mapping[0..h.channels]) |e| try testing.expect(h.family == 3 or e == silent or e < @as(u16, h.streams) + h.coupled);
            if (h.family == 3) try testing.expectEqual(2 * @as(usize, h.channels) * (@as(usize, h.streams) + h.coupled), h.matrix.len);
            try testing.expect((h.family != 2 and h.family != 3) or ambisonicChannels(h.channels));
        } else |err| try testing.expect(err == error.BadHeader);
        _ = checkTags(buf[0..len]) catch |err| try testing.expectEqual(error.BadHeader, err);
    }
    const seed = headBytes(&scratch, 6, 1, 4, 2, &.{ 0, 4, 1, 2, 3, 5 });
    for (0..20000) |_| {
        var copy: [64]u8 = undefined;
        @memcpy(copy[0..seed.len], seed);
        copy[random.uintLessThan(usize, seed.len)] ^= random.int(u8);
        _ = parseHead(copy[0..seed.len]) catch |err| try testing.expect(err == error.BadHeader);
    }
}

test "writeHead and parseHead agree" {
    var buf: [300]u8 = undefined;
    var scratch: [300]u8 = undefined;
    const h = try parseHead(headBytes(&buf, 6, 1, 4, 2, &.{ 0, 4, 1, 2, 3, 5 }));
    const bytes = writeHead(&scratch, &h);
    try testing.expectEqualSlices(u8, headBytes(&buf, 6, 1, 4, 2, &.{ 0, 4, 1, 2, 3, 5 }), bytes);
    const mono = try parseHead(headBytes(&buf, 1, 0, 0, 0, &.{}));
    try testing.expectEqual(@as(usize, 19), writeHead(&scratch, &mono).len);
}

test "the ambisonic channel counts are the squares and the squares plus two" {
    const allowed = [_]u8{ 1, 3, 4, 6, 9, 11, 16, 18, 25, 27, 36, 38, 49, 51, 64, 66, 81, 83, 100, 102, 121, 123, 144, 146, 169, 171, 196, 198, 225, 227 };
    var count: usize = 0;
    for (0..256) |c| {
        const want = std.mem.indexOfScalar(u8, &allowed, @intCast(c)) != null;
        try testing.expectEqual(want, ambisonicChannels(@intCast(c)));
        count += @intFromBool(want);
    }
    try testing.expectEqual(allowed.len, count);
}

const zeros: [228]u8 = @splat(0);

test "family 2 headers carry a mapping and need an ambisonic channel count" {
    var buf: [300]u8 = undefined;
    const four = try parseHead(headBytes(&buf, 4, 2, 2, 2, &.{ 0, 1, 2, 3 }));
    try testing.expectEqual(@as(u8, 2), four.family);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, four.mapping[0..4]);
    try testing.expect(!four.hasLayout());
    try testing.expectEqual(@as(usize, 0), four.matrix.len);
    // A mixed order stream leaves a channel silent.
    const mixed = try parseHead(headBytes(&buf, 4, 2, 2, 2, &.{ 0, 1, 2, silent }));
    try testing.expectEqual(silent, mixed.mapping[3]);
    var table: [227]u8 = undefined;
    for (&table, 0..) |*e, i| e.* = @intCast(i);
    const big = try parseHead(headBytes(&buf, 227, 2, 227, 0, &table));
    try testing.expectEqual(@as(u8, 226), big.mapping[226]);
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 2, 2, 1, 1, &.{ 0, 1 })));
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 5, 2, 5, 0, &.{ 0, 1, 2, 3, 4 })));
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 228, 2, 228, 0, zeros[0..228])));
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 4, 2, 2, 2, &.{ 0, 1, 2, 4 })));
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 4, 2, 2, 2, &.{ 0, 1, 2 })));
}

test "family 3 headers carry a demixing matrix" {
    var buf: [400]u8 = undefined;
    var matrix: [32]u8 = undefined;
    for (&matrix, 0..) |*b, i| b.* = @intCast(i);
    const four = try parseHead(headBytes(&buf, 4, 3, 2, 2, &matrix));
    try testing.expectEqual(@as(u8, 3), four.family);
    try testing.expectEqual(@as(u8, 2), four.streams);
    try testing.expectEqual(@as(u8, 2), four.coupled);
    try testing.expectEqualSlices(u8, &matrix, four.matrix);
    try testing.expect(!four.hasLayout());
    // The matrix has as many rows as channels and as many columns as stream channels.
    const wide = try parseHead(headBytes(&buf, 4, 3, 1, 0, matrix[0..8]));
    try testing.expectEqual(@as(usize, 8), wide.matrix.len);
    const longer = headBytes(&buf, 4, 3, 2, 2, &(matrix ++ [_]u8{ 9, 9 }));
    try testing.expectEqualSlices(u8, &matrix, (try parseHead(longer)).matrix);
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 4, 3, 2, 2, matrix[0..31])));
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 5, 3, 2, 2, zeros[0..40])));
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 4, 3, 0, 0, matrix[0..0])));
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 4, 3, 1, 2, &matrix)));
    try testing.expectError(error.BadHeader, parseHead(headBytes(&buf, 4, 3, 2, 2, &.{})));
}

test "writeHead keeps the matrix of family 3" {
    var buf: [400]u8 = undefined;
    var scratch: [400]u8 = undefined;
    var matrix: [18]u8 = undefined;
    for (&matrix, 0..) |*b, i| b.* = @intCast(i * 7);
    const bytes = headBytes(&buf, 3, 3, 2, 1, &matrix);
    const h = try parseHead(bytes);
    try testing.expectEqualSlices(u8, bytes, writeHead(&scratch, &h));
}
