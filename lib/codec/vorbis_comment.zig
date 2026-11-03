//! Vorbis comments: a vendor string and a list of tags. FLAC, Vorbis and Opus use this
//! layout. The parser borrows the bytes that it reads.
const std = @import("std");
const testing = std.testing;

/// The tag that holds the WAVE speaker mask of the channels.
pub const channel_mask_key = "WAVEFORMATEXTENSIBLE_CHANNEL_MASK";

/// One entry of the form `name=value`. An entry without `=` has an empty value.
pub const Tag = struct {
    name: []const u8,
    value: []const u8,
};

pub const Comments = struct {
    vendor: []const u8,
    /// The number of tags that the header states.
    count: u32,
    /// The bytes after the count.
    rest: []const u8,

    /// Reads the vendor and the tag count. `body` starts at the length of the vendor string.
    /// Bytes after the last tag are allowed.
    pub fn parse(body: []const u8) error{BadHeader}!Comments {
        if (body.len < 4) return error.BadHeader;
        const vendor_len = std.mem.readInt(u32, body[0..4], .little);
        if (vendor_len > body.len - 4) return error.BadHeader;
        const after = body[4 + vendor_len ..];
        if (after.len < 4) return error.BadHeader;
        return .{
            .vendor = body[4..][0..vendor_len],
            .count = std.mem.readInt(u32, after[0..4], .little),
            .rest = after[4..],
        };
    }

    pub fn iterator(self: Comments) Iterator {
        return .{ .rest = self.rest, .left = self.count };
    }

    pub const Iterator = struct {
        rest: []const u8,
        left: u32,

        /// The next tag, or null after the last one. A tag that the bytes do not hold gives
        /// error.BadHeader.
        pub fn next(self: *Iterator) error{BadHeader}!?Tag {
            if (self.left == 0) return null;
            if (self.rest.len < 4) return error.BadHeader;
            const n = std.mem.readInt(u32, self.rest[0..4], .little);
            if (n > self.rest.len - 4) return error.BadHeader;
            const entry = self.rest[4..][0..n];
            self.rest = self.rest[4 + n ..];
            self.left -= 1;
            const at = std.mem.indexOfScalar(u8, entry, '=') orelse return .{ .name = entry, .value = entry[n..] };
            return .{ .name = entry[0..at], .value = entry[at + 1 ..] };
        }
    };

    /// The value of the channel mask tag, as hex with or without "0x". Null when there is
    /// no such tag or its value is not a hex number. The last such tag counts. It reads
    /// every tag, so a header that is cut gives error.BadHeader.
    pub fn channelMask(self: Comments) error{BadHeader}!?u32 {
        var mask: ?u32 = null;
        var it = self.iterator();
        while (try it.next()) |tag| {
            if (!std.ascii.eqlIgnoreCase(tag.name, channel_mask_key)) continue;
            var value = tag.value;
            if (value.len > 2 and value[0] == '0' and (value[1] == 'x' or value[1] == 'X')) value = value[2..];
            mask = std.fmt.parseInt(u32, value, 16) catch null;
        }
        return mask;
    }
};

/// The channel mask of a comment header. See `Comments.channelMask`.
pub fn channelMask(body: []const u8) error{BadHeader}!?u32 {
    return (try Comments.parse(body)).channelMask();
}

fn build(comptime vendor: []const u8, comptime tags: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = &std.mem.toBytes(std.mem.nativeToLittle(u32, vendor.len)) ++ vendor;
        out = out ++ std.mem.toBytes(std.mem.nativeToLittle(u32, tags.len));
        for (tags) |t| out = out ++ std.mem.toBytes(std.mem.nativeToLittle(u32, t.len)) ++ t;
        return out;
    }
}

test "the vendor and the tags are borrowed from the bytes" {
    const body = comptime build("chorus", &.{ "TITLE=A song", "ARTIST=", "noequals", "title=second" });
    const c = try Comments.parse(body);
    try testing.expectEqualStrings("chorus", c.vendor);
    try testing.expectEqual(@as(u32, 4), c.count);
    try testing.expect(c.vendor.ptr == body.ptr + 4);
    var it = c.iterator();
    const first = (try it.next()).?;
    try testing.expectEqualStrings("TITLE", first.name);
    try testing.expectEqualStrings("A song", first.value);
    try testing.expect(first.value.ptr == body.ptr + 4 + 6 + 4 + 4 + 6);
    const second = (try it.next()).?;
    try testing.expectEqualStrings("ARTIST", second.name);
    try testing.expectEqualStrings("", second.value);
    const third = (try it.next()).?;
    try testing.expectEqualStrings("noequals", third.name);
    try testing.expectEqualStrings("", third.value);
    const fourth = (try it.next()).?;
    try testing.expectEqualStrings("title", fourth.name);
    try testing.expectEqualStrings("second", fourth.value);
    try testing.expectEqual(@as(?Tag, null), try it.next());
}

test "a value may hold an equals sign and any bytes" {
    const body = comptime build("", &.{"K=a=b\x00\xff"});
    var it = (try Comments.parse(body)).iterator();
    const tag = (try it.next()).?;
    try testing.expectEqualStrings("K", tag.name);
    try testing.expectEqualStrings("a=b\x00\xff", tag.value);
}

test "the channel mask is read from the tag" {
    const key = channel_mask_key;
    try testing.expectEqual(@as(?u32, 0x3f), try channelMask(comptime build("v", &.{ "TITLE=x", key ++ "=0x3F" })));
    try testing.expectEqual(@as(?u32, 0x60f), try channelMask(comptime build("v", &.{key ++ "=60f"})));
    try testing.expectEqual(@as(?u32, 0x4), try channelMask(comptime build("v", &.{"waveformatextensible_channel_mask=0X4"})));
    try testing.expectEqual(@as(?u32, null), try channelMask(comptime build("v", &.{ "TITLE=x", "MASK=3" })));
    try testing.expectEqual(@as(?u32, null), try channelMask(comptime build("v", &.{})));
    try testing.expectEqual(@as(?u32, null), try channelMask(comptime build("v", &.{key ++ "=zz"})));
    try testing.expectEqual(@as(?u32, null), try channelMask(comptime build("v", &.{key ++ "="})));
    try testing.expectEqual(@as(?u32, null), try channelMask(comptime build("v", &.{key ++ "=0x1ffffffff"})));
    // The last tag counts.
    try testing.expectEqual(@as(?u32, 0x7), try channelMask(comptime build("v", &.{ key ++ "=3", key ++ "=7" })));
    try testing.expectEqual(@as(?u32, null), try channelMask(comptime build("v", &.{ key ++ "=3", key ++ "=no" })));
}

test "damaged headers give BadHeader" {
    const good = comptime build("vendor", &.{ "A=1", "B=2" });
    try testing.expectError(error.BadHeader, Comments.parse(good[0..3]));
    // The vendor string is cut.
    try testing.expectError(error.BadHeader, Comments.parse(good[0..8]));
    // No tag count.
    try testing.expectError(error.BadHeader, Comments.parse(good[0..12]));
    // The second tag is cut.
    try testing.expectError(error.BadHeader, channelMask(good[0 .. good.len - 1]));
    // More tags than data.
    try testing.expectError(error.BadHeader, channelMask("\x00\x00\x00\x00\x09\x00\x00\x00"));
    // A tag longer than the data.
    try testing.expectError(error.BadHeader, channelMask("\x00\x00\x00\x00\x01\x00\x00\x00\xff\xff\xff\xffab"));
    // A vendor length that does not fit.
    try testing.expectError(error.BadHeader, Comments.parse("\xff\xff\xff\xffabc"));
    // Bytes after the last tag are allowed.
    try testing.expectEqual(@as(?u32, null), try channelMask(good ++ "padding"));
}
