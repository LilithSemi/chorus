//! Checksums used by Ogg and FLAC.
const std = @import("std");

/// Ogg page CRC. MSB first, no reflection, no final xor.
pub const ogg = std.hash.crc.Generic(u32, .{
    .polynomial = 0x04c11db7,
    .initial = 0,
    .reflect_input = false,
    .reflect_output = false,
    .xor_output = 0,
});

/// FLAC frame header CRC (CRC-8/SMBUS).
pub const flac8 = std.hash.crc.@"CRC-8/SMBUS";

/// FLAC frame CRC (CRC-16/UMTS).
pub const flac16 = std.hash.crc.@"CRC-16/UMTS";

/// Bit by bit CRC with no reflection, used to check the table driven code.
fn reference(comptime T: type, poly: T, init: T, data: []const u8) T {
    const bits = @typeInfo(T).int.bits;
    var reg = init;
    for (data) |byte| {
        reg ^= @as(T, byte) << (bits - 8);
        for (0..8) |_| {
            const top = reg >> (bits - 1) != 0;
            reg <<= 1;
            if (top) reg ^= poly;
        }
    }
    return reg;
}

test "flac crcs match the catalog check values" {
    try std.testing.expectEqual(@as(u8, 0xf4), flac8.hash("123456789"));
    try std.testing.expectEqual(@as(u16, 0xfee8), flac16.hash("123456789"));
}

test "ogg crc matches the cksum check value without its final xor" {
    // CRC-32/CKSUM has check 0x765e7680 with a final xor of 0xffffffff.
    try std.testing.expectEqual(@as(u32, 0x765e7680 ^ 0xffffffff), ogg.hash("123456789"));
}

test "crcs match a bit by bit reference" {
    var data: [300]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    for ([_]usize{ 0, 1, 2, 17, 255, 300 }) |n| {
        try std.testing.expectEqual(reference(u8, 0x07, 0, data[0..n]), flac8.hash(data[0..n]));
        try std.testing.expectEqual(reference(u16, 0x8005, 0, data[0..n]), flac16.hash(data[0..n]));
        try std.testing.expectEqual(reference(u32, 0x04c11db7, 0, data[0..n]), ogg.hash(data[0..n]));
    }
}

test "incremental update equals one shot" {
    const data = "OggS the quick brown fox";
    var c = ogg.init();
    c.update(data[0..7]);
    c.update(data[7..]);
    try std.testing.expectEqual(ogg.hash(data), c.final());
}

test "ogg page checksum is computed with the crc field zeroed" {
    var page = [_]u8{
        'O', 'g', 'g', 'S', 0,   0x02, 0, 0, 0, 0, 0, 0, 0, 0,
        1,   2,   3,   4,   0,   0,    0, 0, 0, 0, 0, 0, 1, 5,
        'h', 'e', 'l', 'l', 'o',
    };
    const sum = ogg.hash(&page);
    try std.testing.expectEqual(reference(u32, 0x04c11db7, 0, &page), sum);
    std.mem.writeInt(u32, page[22..26], sum, .little);
    var copy = page;
    @memset(copy[22..26], 0);
    try std.testing.expectEqual(std.mem.readInt(u32, page[22..26], .little), ogg.hash(&copy));
}
