//! Opus packet framing: the TOC byte and the frame packing of codes 0 to 3, also in the
//! self delimited form of multistream packets. Ported from libopus src/opus.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");

pub const max_frames = 48;
/// The most bytes that a frame can have.
pub const max_frame_bytes = 1275;
/// The most samples of a packet, at 48 kHz. This is 120 ms.
pub const max_samples = 5760;

pub const Error = error{InvalidPacket};

pub const Mode = enum { silk, hybrid, celt };

pub const Bandwidth = enum { narrow, medium, wide, super_wide, full };

/// The first byte of a packet.
pub const Toc = struct {
    byte: u8,

    pub fn config(self: Toc) u5 {
        return @intCast(self.byte >> 3);
    }

    pub fn mode(self: Toc) Mode {
        if (self.byte & 0x80 != 0) return .celt;
        if (self.byte & 0x60 == 0x60) return .hybrid;
        return .silk;
    }

    pub fn bandwidth(self: Toc) Bandwidth {
        const index: u2 = @truncate(self.byte >> 5);
        return switch (self.mode()) {
            .celt => switch (index) {
                0 => .narrow,
                1 => .wide,
                2 => .super_wide,
                3 => .full,
            },
            .hybrid => if (self.byte & 0x10 != 0) .full else .super_wide,
            .silk => switch (index) {
                0 => .narrow,
                1 => .medium,
                else => .wide,
            },
        };
    }

    /// The channels of the stream, 1 or 2.
    pub fn channels(self: Toc) u8 {
        return if (self.byte & 0x04 != 0) 2 else 1;
    }

    /// The frame count code, 0 to 3.
    pub fn code(self: Toc) u2 {
        return @truncate(self.byte);
    }

    /// The samples of one frame for each channel at the sample rate `rate`, which is at most 192 kHz.
    pub fn frameSamples(self: Toc, rate: u32) u32 {
        std.debug.assert(rate <= 192000);
        const lm: u5 = @truncate(self.byte >> 3 & 3);
        return switch (self.mode()) {
            .celt => (rate << lm) / 400,
            .hybrid => if (self.byte & 0x08 != 0) rate / 50 else rate / 100,
            .silk => if (lm == 3) rate * 60 / 1000 else (rate << lm) / 100,
        };
    }
};

/// A parsed packet. The frames and the padding point into the bytes that `parse` got.
pub const Packet = struct {
    toc: Toc,
    count: usize,
    frames: [max_frames][]const u8,
    /// The offset of the first frame.
    payload_offset: usize,
    /// The bytes that the packet takes, with its padding. With self delimited framing
    /// the next packet of a multistream packet starts here.
    packet_offset: usize,
    padding: []const u8,

    pub fn frame(self: *const Packet, index: usize) []const u8 {
        std.debug.assert(index < self.count);
        return self.frames[index];
    }
};

pub const SizeField = struct {
    /// The bytes of the field, 1 or 2.
    bytes: usize,
    size: u16,
};

/// Reads a frame length: one byte below 252, else two bytes. Null when the bytes are missing.
pub fn parseSize(data: []const u8) ?SizeField {
    if (data.len < 1) return null;
    if (data[0] < 252) return .{ .bytes = 1, .size = data[0] };
    if (data.len < 2) return null;
    return .{ .bytes = 2, .size = 4 * @as(u16, data[1]) + data[0] };
}

/// Writes a frame length of 0 to 1275 and returns the bytes used.
pub fn encodeSize(size: u16, out: *[2]u8) usize {
    std.debug.assert(size <= max_frame_bytes);
    if (size < 252) {
        out[0] = @intCast(size);
        return 1;
    }
    out[0] = @intCast(252 + (size & 3));
    out[1] = @intCast((size - out[0]) >> 2);
    return 2;
}

/// The frames in a packet from its first two bytes.
pub fn frameCount(data: []const u8) Error!u32 {
    if (data.len < 1) return error.InvalidPacket;
    return switch (data[0] & 3) {
        0 => 1,
        3 => if (data.len < 2) error.InvalidPacket else data[1] & 0x3f,
        else => 2,
    };
}

/// The samples of a packet for each channel at `rate`.
pub fn samples(data: []const u8, rate: u32) Error!u32 {
    const count = try frameCount(data);
    const total = count * (Toc{ .byte = data[0] }).frameSamples(rate);
    if (@as(u64, total) * 25 > @as(u64, rate) * 3) return error.InvalidPacket;
    return total;
}

/// Splits a packet into frames. With `self_delimited` the packet has one more length field
/// and can be followed by other data.
pub fn parse(data: []const u8, self_delimited: bool) Error!Packet {
    if (data.len == 0 or data.len > std.math.maxInt(i32)) return error.InvalidPacket;
    const toc: Toc = .{ .byte = data[0] };
    const frame_samples: i32 = @intCast(toc.frameSamples(48000));
    var pos: usize = 1;
    // The bytes between `pos` and the padding.
    var len: i32 = @intCast(data.len - 1);
    var last_size = len;
    var pad: i32 = 0;
    var cbr = false;
    var count: i32 = undefined;
    var size: [max_frames]i32 = undefined;

    switch (data[0] & 3) {
        0 => count = 1,
        1 => {
            count = 2;
            cbr = true;
            if (!self_delimited) {
                if (len & 1 != 0) return error.InvalidPacket;
                last_size = @divTrunc(len, 2);
                size[0] = last_size;
            }
        },
        2 => {
            count = 2;
            const field = parseSize(data[pos..]) orelse return error.InvalidPacket;
            len -= @intCast(field.bytes);
            if (field.size > len) return error.InvalidPacket;
            size[0] = field.size;
            pos += field.bytes;
            last_size = len - field.size;
        },
        3 => {
            if (len < 1) return error.InvalidPacket;
            const ch = data[pos];
            pos += 1;
            count = ch & 0x3f;
            if (count <= 0 or frame_samples * count > max_samples) return error.InvalidPacket;
            len -= 1;
            if (ch & 0x40 != 0) {
                while (true) {
                    if (len <= 0) return error.InvalidPacket;
                    const p = data[pos];
                    pos += 1;
                    len -= 1;
                    const step: i32 = if (p == 255) 254 else p;
                    len -= step;
                    pad += step;
                    if (p != 255) break;
                }
            }
            if (len < 0) return error.InvalidPacket;
            cbr = ch & 0x80 == 0;
            if (!cbr) {
                last_size = len;
                for (0..@intCast(count - 1)) |i| {
                    const field = parseSize(data[pos..][0..@intCast(len)]) orelse return error.InvalidPacket;
                    len -= @intCast(field.bytes);
                    if (field.size > len) return error.InvalidPacket;
                    size[i] = field.size;
                    pos += field.bytes;
                    last_size -= @as(i32, @intCast(field.bytes)) + field.size;
                }
                if (last_size < 0) return error.InvalidPacket;
            } else if (!self_delimited) {
                last_size = @divTrunc(len, count);
                if (last_size * count != len) return error.InvalidPacket;
                for (0..@intCast(count - 1)) |i| size[i] = last_size;
            }
        },
        else => unreachable,
    }

    const n: usize = @intCast(count);
    if (self_delimited) {
        const field = parseSize(data[pos..][0..@intCast(len)]) orelse return error.InvalidPacket;
        len -= @intCast(field.bytes);
        if (field.size > len) return error.InvalidPacket;
        size[n - 1] = field.size;
        pos += field.bytes;
        if (cbr) {
            if (@as(i32, field.size) * count > len) return error.InvalidPacket;
            for (0..n - 1) |i| size[i] = field.size;
        } else if (@as(i32, @intCast(field.bytes)) + field.size > last_size) {
            return error.InvalidPacket;
        }
    } else {
        if (last_size > max_frame_bytes) return error.InvalidPacket;
        size[n - 1] = last_size;
    }

    var out: Packet = .{
        .toc = toc,
        .count = n,
        .frames = undefined,
        .payload_offset = pos,
        .packet_offset = 0,
        .padding = &.{},
    };
    for (0..n) |i| {
        const end = pos + @as(usize, @intCast(size[i]));
        if (end > data.len) return error.InvalidPacket;
        out.frames[i] = data[pos..end];
        pos = end;
    }
    const pad_len: usize = @intCast(pad);
    if (pos + pad_len > data.len) return error.InvalidPacket;
    out.padding = data[pos..][0..pad_len];
    out.packet_offset = pos + pad_len;
    return out;
}

const testing = std.testing;
const Xorshift = @import("test_util.zig").Xorshift;

fn expectFrames(p: Packet, want: []const []const u8) !void {
    try testing.expectEqual(want.len, p.count);
    for (want, 0..) |w, i| try testing.expectEqualSlices(u8, w, p.frame(i));
}

test "toc fields of each mode" {
    const silk_nb_10: Toc = .{ .byte = 0x00 };
    try testing.expectEqual(Mode.silk, silk_nb_10.mode());
    try testing.expectEqual(Bandwidth.narrow, silk_nb_10.bandwidth());
    try testing.expectEqual(@as(u32, 480), silk_nb_10.frameSamples(48000));
    try testing.expectEqual(@as(u8, 1), silk_nb_10.channels());
    try testing.expectEqual(@as(u2, 0), silk_nb_10.code());

    const silk_mb_60: Toc = .{ .byte = (4 + 3) << 3 | 0x04 | 1 };
    try testing.expectEqual(Mode.silk, silk_mb_60.mode());
    try testing.expectEqual(Bandwidth.medium, silk_mb_60.bandwidth());
    try testing.expectEqual(@as(u32, 2880), silk_mb_60.frameSamples(48000));
    try testing.expectEqual(@as(u32, 960), silk_mb_60.frameSamples(16000));
    try testing.expectEqual(@as(u8, 2), silk_mb_60.channels());
    try testing.expectEqual(@as(u2, 1), silk_mb_60.code());

    const silk_wb_40: Toc = .{ .byte = (8 + 2) << 3 };
    try testing.expectEqual(Bandwidth.wide, silk_wb_40.bandwidth());
    try testing.expectEqual(@as(u32, 1920), silk_wb_40.frameSamples(48000));

    const hybrid_swb_10: Toc = .{ .byte = 12 << 3 };
    try testing.expectEqual(Mode.hybrid, hybrid_swb_10.mode());
    try testing.expectEqual(Bandwidth.super_wide, hybrid_swb_10.bandwidth());
    try testing.expectEqual(@as(u32, 480), hybrid_swb_10.frameSamples(48000));

    const hybrid_fb_20: Toc = .{ .byte = 15 << 3 | 2 };
    try testing.expectEqual(Mode.hybrid, hybrid_fb_20.mode());
    try testing.expectEqual(Bandwidth.full, hybrid_fb_20.bandwidth());
    try testing.expectEqual(@as(u32, 960), hybrid_fb_20.frameSamples(48000));
    try testing.expectEqual(@as(u32, 320), hybrid_fb_20.frameSamples(16000));

    const celt_nb_25: Toc = .{ .byte = 16 << 3 };
    try testing.expectEqual(Mode.celt, celt_nb_25.mode());
    try testing.expectEqual(Bandwidth.narrow, celt_nb_25.bandwidth());
    try testing.expectEqual(@as(u32, 120), celt_nb_25.frameSamples(48000));

    const celt_wb_5: Toc = .{ .byte = 21 << 3 };
    try testing.expectEqual(Bandwidth.wide, celt_wb_5.bandwidth());
    try testing.expectEqual(@as(u32, 240), celt_wb_5.frameSamples(48000));

    const celt_swb_10: Toc = .{ .byte = 26 << 3 };
    try testing.expectEqual(Bandwidth.super_wide, celt_swb_10.bandwidth());
    try testing.expectEqual(@as(u32, 480), celt_swb_10.frameSamples(48000));

    const celt_fb_20: Toc = .{ .byte = 31 << 3 | 0x04 | 3 };
    try testing.expectEqual(Bandwidth.full, celt_fb_20.bandwidth());
    try testing.expectEqual(@as(u32, 960), celt_fb_20.frameSamples(48000));
    try testing.expectEqual(@as(u8, 2), celt_fb_20.channels());
    try testing.expectEqual(@as(u2, 3), celt_fb_20.code());
}

test "frame sizes of every config match the table" {
    const want = [_]u32{
        480, 960, 1920, 2880, 480, 960, 1920, 2880, 480, 960, 1920, 2880, 480, 960, 480, 960,
        120, 240, 480,  960,  120, 240, 480,  960,  120, 240, 480,  960,  120, 240, 480, 960,
    };
    for (want, 0..) |w, config| {
        const toc: Toc = .{ .byte = @intCast(config << 3) };
        try testing.expectEqual(w, toc.frameSamples(48000));
    }
}

test "code 0 is one frame that takes the rest" {
    const p = try parse(&.{ 0x08, 1, 2, 3 }, false);
    try expectFrames(p, &.{&.{ 1, 2, 3 }});
    try testing.expectEqual(@as(usize, 1), p.payload_offset);
    try testing.expectEqual(@as(usize, 4), p.packet_offset);
    const empty = try parse(&.{0x08}, false);
    try expectFrames(empty, &.{&.{}});
    try testing.expectError(error.InvalidPacket, parse(&.{}, false));
}

test "code 1 is two equal frames" {
    const p = try parse(&.{ 0x09, 1, 2, 3, 4 }, false);
    try expectFrames(p, &.{ &.{ 1, 2 }, &.{ 3, 4 } });
    try testing.expectError(error.InvalidPacket, parse(&.{ 0x09, 1, 2, 3 }, false));
    const empty = try parse(&.{0x09}, false);
    try expectFrames(empty, &.{ &.{}, &.{} });
}

test "code 2 is two frames with the first one sized" {
    const p = try parse(&.{ 0x0a, 2, 9, 9, 7 }, false);
    try expectFrames(p, &.{ &.{ 9, 9 }, &.{7} });
    const zero = try parse(&.{ 0x0a, 0, 5 }, false);
    try expectFrames(zero, &.{ &.{}, &.{5} });
    try testing.expectError(error.InvalidPacket, parse(&.{ 0x0a, 5, 1 }, false));
    try testing.expectError(error.InvalidPacket, parse(&.{0x0a}, false));
    // A two byte size needs the second byte.
    try testing.expectError(error.InvalidPacket, parse(&.{ 0x0a, 252 }, false));
    var big: [3 + 256 + 3]u8 = @splat(7);
    big[0] = 0x0a;
    big[1] = 252;
    big[2] = 1;
    const q = try parse(&big, false);
    try testing.expectEqual(@as(usize, 256), q.frame(0).len);
    try testing.expectEqual(@as(usize, 3), q.frame(1).len);
    try testing.expectEqual(@as(usize, 3), q.payload_offset);
}

test "code 3 with equal frames" {
    const p = try parse(&.{ 0x0b, 0x03, 1, 2, 3, 4, 5, 6 }, false);
    try expectFrames(p, &.{ &.{ 1, 2 }, &.{ 3, 4 }, &.{ 5, 6 } });
    try testing.expectEqual(@as(usize, 2), p.payload_offset);
    try testing.expectError(error.InvalidPacket, parse(&.{ 0x0b, 0x03, 1, 2, 3, 4 }, false));
    try testing.expectError(error.InvalidPacket, parse(&.{0x0b}, false));
    try testing.expectError(error.InvalidPacket, parse(&.{ 0x0b, 0x00 }, false));
}

test "code 3 with sized frames" {
    const p = try parse(&.{ 0x0b, 0x83, 1, 0, 9, 8, 8, 8 }, false);
    try expectFrames(p, &.{ &.{9}, &.{}, &.{ 8, 8, 8 } });
    // The last frame takes what is left, and it can be empty.
    const q = try parse(&.{ 0x0b, 0x82, 2, 5, 5 }, false);
    try expectFrames(q, &.{ &.{ 5, 5 }, &.{} });
    try testing.expectError(error.InvalidPacket, parse(&.{ 0x0b, 0x82, 3, 5, 5 }, false));
    try testing.expectError(error.InvalidPacket, parse(&.{ 0x0b, 0x82 }, false));
}

test "code 3 padding" {
    const p = try parse(&.{ 0x0b, 0x42, 2, 1, 2, 3, 4, 0xee, 0xff }, false);
    try expectFrames(p, &.{ &.{ 1, 2 }, &.{ 3, 4 } });
    try testing.expectEqual(@as(usize, 3), p.payload_offset);
    try testing.expectEqualSlices(u8, &.{ 0xee, 0xff }, p.padding);
    try testing.expectEqual(@as(usize, 9), p.packet_offset);

    // Each 255 adds 254 bytes and the next byte adds its own value.
    var long: [4 + 257 + 1]u8 = @splat(0);
    long[0] = 0x0b;
    long[1] = 0x41;
    long[2] = 255;
    long[3] = 3;
    long[4] = 42;
    const q = try parse(&long, false);
    try testing.expectEqual(@as(usize, 1), q.count);
    try testing.expectEqual(@as(usize, 1), q.frame(0).len);
    try testing.expectEqual(@as(usize, 257), q.padding.len);

    // A padding claim larger than the packet is invalid.
    try testing.expectError(error.InvalidPacket, parse(&.{ 0x0b, 0x41, 255, 255, 255, 1 }, false));
    try testing.expectError(error.InvalidPacket, parse(&.{ 0x0b, 0x41, 5, 1 }, false));
    try testing.expectError(error.InvalidPacket, parse(&.{ 0x0b, 0x41 }, false));
    try testing.expectError(error.InvalidPacket, parse(&.{ 0x0b, 0x41, 255 }, false));
}

test "a long padding chain does not overflow" {
    var big: [100_000]u8 = @splat(255);
    big[0] = 0x0b;
    big[1] = 0x41;
    try testing.expectError(error.InvalidPacket, parse(&big, false));
    var ok: [2 + 10 + 1 + 10 * 254]u8 = @splat(0);
    ok[0] = 0x0b;
    ok[1] = 0x41;
    @memset(ok[2..12], 255);
    ok[12] = 0;
    const p = try parse(&ok, false);
    try testing.expectEqual(@as(usize, 2540), p.padding.len);
    try testing.expectEqual(@as(usize, 0), p.frame(0).len);
}

test "frame count times duration is limited to 120 ms" {
    // 20 ms frames: 6 fit and 7 do not.
    const celt_20: u8 = 31 << 3 | 3;
    var six = zeroFrames(celt_20, 6);
    try testing.expectEqual(@as(usize, 6), (try parse(&six, false)).count);
    var seven = zeroFrames(celt_20, 7);
    try testing.expectError(error.InvalidPacket, parse(&seven, false));
    // 60 ms frames: 2 fit and 3 do not.
    const silk_60: u8 = 3 << 3 | 3;
    try testing.expectEqual(@as(usize, 2), (try parse(&.{ silk_60, 2, 0, 0 }, false)).count);
    try testing.expectError(error.InvalidPacket, parse(&.{ silk_60, 3, 0, 0, 0 }, false));
    // 2.5 ms frames: 48 fit and 49 do not.
    const celt_25: u8 = 28 << 3 | 3;
    var f48 = zeroFrames(celt_25, 48);
    try testing.expectEqual(@as(usize, 48), (try parse(&f48, false)).count);
    var f49 = zeroFrames(celt_25, 49);
    try testing.expectError(error.InvalidPacket, parse(&f49, false));
}

test "a frame of more than 1275 bytes is invalid" {
    var buf: [1 + 1277]u8 = @splat(1);
    buf[0] = 0x08;
    try testing.expectError(error.InvalidPacket, parse(buf[0..1277], false));
    const p = try parse(buf[0..1276], false);
    try testing.expectEqual(@as(usize, 1275), p.frame(0).len);
    // Code 1 halves of 1276 bytes are too long.
    var two: [1 + 2552]u8 = @splat(1);
    two[0] = 0x09;
    try testing.expectError(error.InvalidPacket, parse(&two, false));
    try testing.expectEqual(@as(usize, 2), (try parse(two[0..2551], false)).count);
}

test "self delimited packets" {
    const c0 = try parse(&.{ 0x08, 3, 1, 2, 3, 0xaa }, true);
    try expectFrames(c0, &.{&.{ 1, 2, 3 }});
    try testing.expectEqual(@as(usize, 5), c0.packet_offset);
    try testing.expectEqual(@as(usize, 2), c0.payload_offset);

    const c1 = try parse(&.{ 0x09, 2, 1, 2, 3, 4, 0xaa }, true);
    try expectFrames(c1, &.{ &.{ 1, 2 }, &.{ 3, 4 } });
    try testing.expectEqual(@as(usize, 6), c1.packet_offset);

    const c2 = try parse(&.{ 0x0a, 1, 2, 7, 8, 9 }, true);
    try expectFrames(c2, &.{ &.{7}, &.{ 8, 9 } });
    try testing.expectEqual(@as(usize, 6), c2.packet_offset);

    const cbr = try parse(&.{ 0x0b, 0x02, 2, 1, 2, 3, 4, 0xaa }, true);
    try expectFrames(cbr, &.{ &.{ 1, 2 }, &.{ 3, 4 } });
    try testing.expectEqual(@as(usize, 7), cbr.packet_offset);

    const vbr = try parse(&.{ 0x0b, 0x82, 1, 2, 5, 6, 7 }, true);
    try expectFrames(vbr, &.{ &.{5}, &.{ 6, 7 } });
    try testing.expectEqual(@as(usize, 7), vbr.packet_offset);

    // The padding counts in the length of the packet.
    const pad = try parse(&.{ 0x0b, 0x42, 3, 1, 1, 2, 0, 0, 0, 0xaa }, true);
    try expectFrames(pad, &.{ &.{1}, &.{2} });
    try testing.expectEqual(@as(usize, 9), pad.packet_offset);
    try testing.expectEqual(@as(usize, 3), pad.padding.len);

    try testing.expectError(error.InvalidPacket, parse(&.{ 0x08, 4, 1, 2, 3 }, true));
    try testing.expectError(error.InvalidPacket, parse(&.{ 0x09, 3, 1, 2, 3, 4, 5 }, true));
    try testing.expectError(error.InvalidPacket, parse(&.{ 0x0b, 0x82, 1, 3, 5, 6 }, true));
    try testing.expectError(error.InvalidPacket, parse(&.{0x08}, true));
}

test "size field round trip" {
    var out: [2]u8 = undefined;
    for (0..max_frame_bytes + 1) |size| {
        const n = encodeSize(@intCast(size), &out);
        try testing.expectEqual(@as(usize, if (size < 252) 1 else 2), n);
        const got = parseSize(out[0..n]).?;
        try testing.expectEqual(n, got.bytes);
        try testing.expectEqual(size, got.size);
    }
    try testing.expectEqual(@as(?SizeField, null), parseSize(&.{}));
    try testing.expectEqual(@as(?SizeField, null), parseSize(&.{252}));
}

test "frame and sample counts of a packet" {
    try testing.expectEqual(@as(u32, 960), try samples(&.{ 31 << 3, 0 }, 48000));
    try testing.expectEqual(@as(u32, 1920), try samples(&.{ 31 << 3 | 1, 0 }, 48000));
    try testing.expectEqual(@as(u32, 5760), try samples(&.{ 31 << 3 | 3, 6 }, 48000));
    try testing.expectEqual(@as(u32, 960), try samples(&.{ 31 << 3 | 3, 2 }, 24000));
    try testing.expectError(error.InvalidPacket, samples(&.{ 31 << 3 | 3, 7 }, 48000));
    try testing.expectError(error.InvalidPacket, samples(&.{31 << 3 | 3}, 48000));
    try testing.expectError(error.InvalidPacket, samples(&.{}, 48000));
    try testing.expectEqual(@as(u32, 2), try frameCount(&.{ 0x0a, 0 }));
}

const Digest = struct {
    h: u64 = 1469598103934665603,

    fn mix(self: *Digest, value: anytype) void {
        const v: i64 = @intCast(value);
        for (0..8) |i| {
            self.h ^= @as(u64, @bitCast(v >> @intCast(8 * i))) & 255;
            self.h *%= 1099511628211;
        }
    }
};

test "parsing agrees with libopus on generated packets" {
    // The expected digest comes from a C program over opus_packet_parse_impl of libopus 1.6.1.
    var x: Xorshift = .{ .s = 12345 };
    var d: Digest = .{};
    var valid: [2][4]u32 = @splat(@splat(0));
    for (0..20000) |_| {
        var data: [1600]u8 = undefined;
        const t = x.next();
        const len: usize = if (t % 5 == 0) x.next() % 1500 else x.next() % 40;
        for (data[0..len]) |*b| {
            const r = x.next();
            b.* = if (r % 10 < 5) @intCast((r >> 8) % 13) else if (r % 10 < 7) @intCast(250 + (r >> 8) % 6) else @truncate(r >> 8);
        }
        if (len >= 2 and x.next() % 4 == 0) {
            const hi = x.next() & 0xc0;
            const lo = 1 + x.next() % 3;
            data[1] = @intCast(hi | lo);
        }
        for ([_]bool{ false, true }) |sd| {
            if (parse(data[0..len], sd)) |p| {
                d.mix(p.count);
                valid[@intFromBool(sd)][data[0] & 3] += 1;
                d.mix(p.toc.byte);
                var at = p.payload_offset;
                for (0..p.count) |i| {
                    d.mix(p.frame(i).len);
                    d.mix(at);
                    at += p.frame(i).len;
                }
                d.mix(p.payload_offset);
                d.mix(p.packet_offset);
                d.mix(@intFromPtr(p.padding.ptr) - @intFromPtr(&data));
                d.mix(p.padding.len);
            } else |_| d.mix(-4);
        }
        if (len > 0) {
            const toc: Toc = .{ .byte = data[0] };
            d.mix(toc.frameSamples(48000));
            d.mix(toc.frameSamples(16000));
        }
    }
    try testing.expectEqual(@as(u64, 0xe63ca1b007463da8), d.h);
    try testing.expectEqual([2][4]u32{ .{ 4936, 2164, 2343, 1026 }, .{ 2529, 1813, 1429, 817 } }, valid);
}

fn checkInvariants(data: []const u8, sd: bool) !void {
    const p = parse(data, sd) catch return;
    try testing.expect(p.count >= 1 and p.count <= max_frames);
    var at = p.payload_offset;
    for (0..p.count) |i| {
        const f = p.frame(i);
        try testing.expect(f.len <= max_frame_bytes);
        try testing.expectEqual(@intFromPtr(data.ptr) + at, @intFromPtr(f.ptr));
        at += f.len;
    }
    try testing.expect(at <= data.len);
    try testing.expectEqual(at + p.padding.len, p.packet_offset);
    try testing.expect(p.packet_offset <= data.len);
    if (!sd) try testing.expectEqual(data.len, p.packet_offset);
    try testing.expect(p.count * p.toc.frameSamples(48000) <= max_samples);
}

test "every toc and count byte with short tails parse without a crash" {
    var buf: [10]u8 = @splat(0);
    for (0..256) |toc| {
        for (0..256) |second| {
            for ([_]usize{ 1, 2, 3, 5, 10 }) |len| {
                buf[0] = @intCast(toc);
                buf[1] = @intCast(second);
                for (buf[2..]) |*b| b.* = @truncate(second *% 7 +% toc);
                try checkInvariants(buf[0..len], false);
                try checkInvariants(buf[0..len], true);
            }
        }
    }
}

test "random and mutated packets keep the invariants" {
    var prng: std.Random.DefaultPrng = .init(0x4f505553);
    const rand = prng.random();
    var buf: [1400]u8 = undefined;
    for (0..20000) |_| {
        const len = if (rand.boolean()) rand.uintLessThan(usize, 24) else rand.uintLessThan(usize, buf.len);
        rand.bytes(buf[0..len]);
        try checkInvariants(buf[0..len], false);
        try checkInvariants(buf[0..len], true);
    }
    // Valid packets with one flipped bit.
    const base = [_]u8{ 0x0b, 0xc3, 2, 3, 1, 1, 1, 2, 2, 2, 3 };
    var mutated = base;
    for (0..base.len * 8) |bit| {
        mutated[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        try checkInvariants(&mutated, false);
        try checkInvariants(&mutated, true);
        mutated[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
    }
}

/// A code 3 packet of `n` empty frames of a CBR stream with one byte each.
fn zeroFrames(toc: u8, comptime n: usize) [2 + n]u8 {
    var out: [2 + n]u8 = @splat(0);
    out[0] = toc;
    out[1] = n;
    return out;
}
