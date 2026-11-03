//! Byte input and bit level reading and writing.
const std = @import("std");
const Source = @import("../codec.zig").Source;
const crc = @import("crc.zig");
const helpers = @import("testing.zig");
const builtin = @import("builtin");
const testing = std.testing;

pub const has_files = builtin.os.tag != .freestanding;

/// Byte input over a Source. Tracks the position of the bytes and reader variants.
pub const Input = struct {
    source: Source,
    pos: u64 = 0,

    pub const Error = error{ Truncated, ReadFailed };
    pub const SeekError = error{ Unseekable, Truncated, ReadFailed };

    pub fn init(source: Source) Input {
        return .{ .source = source };
    }

    /// Reads up to `buf.len` bytes. A result of 0 means the end of the input.
    pub fn readUpTo(self: *Input, buf: []u8) error{ReadFailed}!usize {
        const n = switch (self.source) {
            .bytes => |bytes| blk: {
                const start: usize = @intCast(self.pos);
                const n = @min(buf.len, bytes.len - start);
                @memcpy(buf[0..n], bytes[start..][0..n]);
                break :blk n;
            },
            .reader => |r| try r.readSliceShort(buf),
            .file => |f| try f.interface.readSliceShort(buf),
            .custom => |c| try c.read(buf),
        };
        self.pos += n;
        return n;
    }

    pub fn readExact(self: *Input, buf: []u8) Error!void {
        var got: usize = 0;
        while (got < buf.len) {
            const n = try self.readUpTo(buf[got..]);
            if (n == 0) return error.Truncated;
            got += n;
        }
    }

    pub fn skip(self: *Input, n: u64) Error!void {
        var left = n;
        while (left > 0) {
            const step: usize = @intCast(@min(left, std.math.maxInt(usize)));
            const got = switch (self.source) {
                .bytes => |bytes| @min(step, bytes.len - @as(usize, @intCast(self.pos))),
                .reader => |r| try r.discardShort(step),
                .file => |f| try f.interface.discardShort(step),
                .custom => |c| blk: {
                    var scratch: [256]u8 = undefined;
                    break :blk try c.read(scratch[0..@min(step, scratch.len)]);
                },
            };
            if (got == 0) return error.Truncated;
            self.pos += got;
            left -= got;
        }
    }

    pub fn seekable(self: *const Input) bool {
        return switch (self.source) {
            .bytes => true,
            .reader => false,
            .file => |f| f.seek_err == null and f.mode != .failure,
            .custom => true,
        };
    }

    pub fn seekTo(self: *Input, offset: u64) SeekError!void {
        switch (self.source) {
            .bytes => |bytes| {
                if (offset > bytes.len) return error.Truncated;
                self.pos = offset;
            },
            .reader => return error.Unseekable,
            .custom => |c| {
                if (c.length()) |len| {
                    if (offset > len) return error.Truncated;
                }
                c.seekTo(offset) catch |err| switch (err) {
                    error.Unseekable => return error.Unseekable,
                    error.ReadFailed => return error.ReadFailed,
                };
                self.pos = offset;
            },
            .file => |f| {
                if (!self.seekable()) return error.Unseekable;
                if (self.length()) |len| {
                    if (offset > len) return error.Truncated;
                }
                f.seekTo(offset) catch |err| switch (err) {
                    error.Unseekable, error.AccessDenied => return error.Unseekable,
                    error.EndOfStream => return error.Truncated,
                    error.ReadFailed, error.Canceled, error.Unexpected => return error.ReadFailed,
                };
            },
        }
    }

    /// Absolute offset for a file. Bytes consumed since init for bytes and reader.
    pub fn position(self: *const Input) u64 {
        return switch (self.source) {
            .file => |f| f.logicalPos(),
            else => self.pos,
        };
    }

    /// Total size in bytes when it is known.
    pub fn length(self: *Input) ?u64 {
        return switch (self.source) {
            .bytes => |bytes| bytes.len,
            .reader => null,
            .file => |f| f.size orelse f.getSize() catch null,
            .custom => |c| c.length(),
        };
    }
};

/// Moves a file writer to its start so that the caller can write the header again. False
/// when the file cannot seek. Any other seek error is error.WriteFailed.
pub fn rewindWriter(file: *std.Io.File.Writer) error{WriteFailed}!bool {
    file.seekTo(0) catch |err| switch (err) {
        error.Unseekable => return false,
        else => return error.WriteFailed,
    };
    return true;
}

/// Reads bits MSB first from a byte slice, or from an Input through a refill buffer.
pub const BitReader = struct {
    buf: []const u8,
    idx: usize = 0,
    bit: u4 = 0,
    base: u64 = 0,
    refill: ?Refill = null,
    sum8: crc.flac8 = .init(),
    sum16: crc.flac16 = .init(),
    on8: bool = false,
    on16: bool = false,
    mark: usize = 0,

    const Refill = struct { input: *Input, store: []u8 };

    pub const Error = Input.Error;

    pub fn initBytes(bytes: []const u8) BitReader {
        return .{ .buf = bytes };
    }

    /// `store` must not be empty.
    pub fn initInput(input: *Input, store: []u8) BitReader {
        return .{ .buf = store[0..0], .base = input.position(), .refill = .{ .input = input, .store = store } };
    }

    /// Drops buffered bytes and follows the Input position. Call it after `Input.seekTo`.
    pub fn reset(self: *BitReader) void {
        const refill = self.refill orelse return;
        self.buf = refill.store[0..0];
        self.idx = 0;
        self.bit = 0;
        self.base = refill.input.position();
        self.on8 = false;
        self.on16 = false;
    }

    fn ensure(self: *BitReader) Error!void {
        if (self.idx < self.buf.len) return;
        const refill = self.refill orelse return error.Truncated;
        self.fold(self.buf.len);
        const n = try refill.input.readUpTo(refill.store);
        if (n == 0) return error.Truncated;
        self.base += self.buf.len;
        self.buf = refill.store[0..n];
        self.idx = 0;
        self.mark = 0;
    }

    fn fold(self: *BitReader, upto: usize) void {
        if (self.mark < upto) {
            const part = self.buf[self.mark..upto];
            if (self.on8) self.sum8.update(part);
            if (self.on16) self.sum16.update(part);
            self.mark = upto;
        }
    }

    /// Starts a CRC window at the next byte. The reader must be on a byte boundary.
    pub fn crcStart(self: *BitReader) void {
        self.sum8 = .init();
        self.sum16 = .init();
        self.on8 = true;
        self.on16 = true;
        self.mark = self.idx;
    }

    /// CRC-8 of the whole bytes read since `crcStart`. It stops the CRC-8 of the window.
    pub fn crc8(self: *BitReader) u8 {
        self.fold(self.idx);
        self.on8 = false;
        return self.sum8.final();
    }

    /// CRC-16 of the whole bytes read since `crcStart`. It stops the CRC-16 of the window.
    pub fn crc16(self: *BitReader) u16 {
        self.fold(self.idx);
        self.on16 = false;
        return self.sum16.final();
    }

    /// False at the end of the input. Tries to refill when no byte is buffered.
    pub fn hasMore(self: *BitReader) error{ReadFailed}!bool {
        if (self.idx < self.buf.len) return true;
        const refill = self.refill orelse return false;
        self.fold(self.buf.len);
        const n = try refill.input.readUpTo(refill.store);
        self.base += self.buf.len;
        self.buf = refill.store[0..n];
        self.idx = 0;
        self.mark = 0;
        return n != 0;
    }

    /// The next buffered byte, or null when the buffer is empty. It does not refill.
    pub fn peekByte(self: *const BitReader) ?u8 {
        if (self.idx < self.buf.len) return self.buf[self.idx];
        return null;
    }

    /// Moves to a stream position inside the buffered bytes. False when it is outside.
    pub fn moveTo(self: *BitReader, position: u64) bool {
        if (position < self.base or position > self.base + self.buf.len) return false;
        self.idx = @intCast(position - self.base);
        self.bit = 0;
        self.on8 = false;
        self.on16 = false;
        return true;
    }

    /// Reads `n` bits, at most 64.
    pub fn readBits(self: *BitReader, n: u7) Error!u64 {
        std.debug.assert(n <= 64);
        var out: u64 = 0;
        var left: u4 = undefined;
        var remaining: u7 = n;
        while (remaining > 0) {
            try self.ensure();
            left = @intCast(@min(8 - @as(u4, self.bit), remaining));
            const byte: u16 = self.buf[self.idx];
            const shift: u4 = 8 - self.bit - left;
            const chunk: u64 = (byte >> @intCast(shift)) & ((@as(u16, 1) << @intCast(left)) - 1);
            out = (out << @intCast(left)) | chunk;
            self.bit += left;
            if (self.bit == 8) {
                self.idx += 1;
                self.bit = 0;
            }
            remaining -= left;
        }
        return out;
    }

    pub fn readSigned(self: *BitReader, n: u6) Error!i64 {
        if (n == 0) return 0;
        const shift: u6 = @intCast(64 - @as(u7, n));
        const v = try self.readBits(n);
        return @as(i64, @bitCast(v << shift)) >> shift;
    }

    /// Counts zero bits up to the next one bit and consumes that bit. A count above `max`
    /// gives error.BadData.
    pub fn readUnary(self: *BitReader, max: u64) (Error || error{BadData})!u64 {
        var count: u64 = 0;
        while (true) {
            try self.ensure();
            const rest: u8 = self.buf[self.idx] << @intCast(self.bit);
            if (rest == 0) {
                count += 8 - @as(u64, self.bit);
                if (count > max) return error.BadData;
                self.idx += 1;
                self.bit = 0;
                continue;
            }
            const zeros = @clz(rest);
            count += zeros;
            if (count > max) return error.BadData;
            self.bit += zeros + 1;
            if (self.bit == 8) {
                self.idx += 1;
                self.bit = 0;
            }
            return count;
        }
    }

    /// Reads a Rice code with parameter `k` and undoes the FLAC zigzag mapping.
    pub fn readRice(self: *BitReader, k: u6) (Error || error{BadData})!i64 {
        const q = try self.readUnary(@as(u64, std.math.maxInt(u64)) >> k);
        const r = try self.readBits(k);
        const hi = std.math.shlExact(u64, q, k) catch return error.BadData;
        const u = hi | r;
        const half: i64 = @intCast(u >> 1);
        return half ^ -@as(i64, @intCast(u & 1));
    }

    pub fn alignByte(self: *BitReader) void {
        if (self.bit != 0) {
            self.bit = 0;
            self.idx += 1;
        }
    }

    /// Index of the byte that holds the next unread bit.
    pub fn bytePosition(self: *const BitReader) u64 {
        return self.base + self.idx;
    }
};

/// Writes bits MSB first into a growing byte list.
pub const BitWriter = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,
    acc: u8 = 0,
    nbits: u4 = 0,

    pub fn init(gpa: std.mem.Allocator) BitWriter {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *BitWriter) void {
        self.list.deinit(self.gpa);
    }

    /// Writes the low `n` bits of `value`.
    pub fn writeBits(self: *BitWriter, value: u64, n: u7) std.mem.Allocator.Error!void {
        var remaining: u7 = n;
        while (remaining > 0) {
            const take: u4 = @intCast(@min(8 - @as(u4, self.nbits), remaining));
            remaining -= take;
            const chunk: u16 = @intCast((value >> @intCast(remaining)) & ((@as(u64, 1) << @intCast(take)) - 1));
            self.acc = @intCast((@as(u16, self.acc) << take) | chunk);
            self.nbits += take;
            if (self.nbits == 8) {
                try self.list.append(self.gpa, self.acc);
                self.acc = 0;
                self.nbits = 0;
            }
        }
    }

    pub fn writeSigned(self: *BitWriter, value: i64, n: u6) std.mem.Allocator.Error!void {
        try self.writeBits(@bitCast(value), n);
    }

    /// Writes `q` zero bits and one 1 bit.
    pub fn writeUnary(self: *BitWriter, q: u64) std.mem.Allocator.Error!void {
        var left = q;
        while (left > 0) {
            const step: u6 = @intCast(@min(left, 63));
            try self.writeBits(0, step);
            left -= step;
        }
        try self.writeBits(1, 1);
    }

    pub fn writeRice(self: *BitWriter, value: i64, k: u6) std.mem.Allocator.Error!void {
        const bits: u64 = @bitCast(value);
        const u = (bits *% 2) ^ @as(u64, @bitCast(value >> 63));
        try self.writeUnary(u >> k);
        try self.writeBits(u, k);
    }

    /// Pads the current byte with zero bits.
    pub fn alignByte(self: *BitWriter) std.mem.Allocator.Error!void {
        if (self.nbits != 0) try self.writeBits(0, @intCast(8 - @as(u4, self.nbits)));
    }

    /// The complete bytes written so far.
    pub fn bytes(self: *const BitWriter) []const u8 {
        return self.list.items;
    }
};

/// Reads bits LSB first from a byte slice, the bit order of Vorbis. A read past the end
/// gives error.Truncated, and every later read gives it too.
pub const LsbReader = struct {
    bytes: []const u8,
    /// The index of the next bit.
    pos: usize = 0,

    pub const Error = error{Truncated};

    pub fn init(bytes: []const u8) LsbReader {
        return .{ .bytes = bytes };
    }

    pub fn bitsLeft(self: *const LsbReader) usize {
        return self.bytes.len * 8 - self.pos;
    }

    /// The next `n` bits without consuming them, at most 32. Bits past the end read as 0.
    pub fn peek(self: *const LsbReader, n: u6) u32 {
        std.debug.assert(n <= 32);
        const first = self.pos / 8;
        var acc: u64 = 0;
        for (0..5) |i| {
            if (first + i >= self.bytes.len) break;
            acc |= @as(u64, self.bytes[first + i]) << @intCast(8 * i);
        }
        const mask = (@as(u64, 1) << n) - 1;
        return @intCast((acc >> @intCast(self.pos % 8)) & mask);
    }

    /// Consumes `n` bits, at most 32.
    pub fn skip(self: *LsbReader, n: u6) Error!void {
        std.debug.assert(n <= 32);
        if (n > self.bitsLeft()) {
            self.pos = self.bytes.len * 8;
            return error.Truncated;
        }
        self.pos += n;
    }

    /// Reads `n` bits, at most 32. The first bit read is bit 0 of the result.
    pub fn readBits(self: *LsbReader, n: u6) Error!u32 {
        const value = self.peek(n);
        try self.skip(n);
        return value;
    }

    pub fn readBit(self: *LsbReader) Error!bool {
        return try self.readBits(1) == 1;
    }

    /// The number of bytes that hold the bits read so far.
    pub fn bytePosition(self: *const LsbReader) usize {
        return (self.pos + 7) / 8;
    }
};

/// Writes bits LSB first into a growing byte list. Unused bits of the last byte are 0.
pub const LsbWriter = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,
    nbits: usize = 0,

    pub fn init(gpa: std.mem.Allocator) LsbWriter {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *LsbWriter) void {
        self.list.deinit(self.gpa);
    }

    /// Writes the low `n` bits of `value`, at most 32.
    pub fn writeBits(self: *LsbWriter, value: u32, n: u6) std.mem.Allocator.Error!void {
        std.debug.assert(n <= 32);
        var done: u6 = 0;
        while (done < n) {
            const used: u4 = @intCast(self.nbits % 8);
            if (used == 0) try self.list.append(self.gpa, 0);
            const take: u6 = @min(8 - @as(u6, used), n - done);
            const chunk: u8 = @intCast((value >> @intCast(done)) & ((@as(u32, 1) << @intCast(take)) - 1));
            self.list.items[self.list.items.len - 1] |= chunk << @intCast(used);
            self.nbits += take;
            done += take;
        }
    }

    /// The bytes written so far, with the last byte padded by zero bits.
    pub fn bytes(self: *const LsbWriter) []const u8 {
        return self.list.items;
    }
};

test "Input over bytes" {
    var in: Input = .init(.{ .bytes = "abcdefghij" });
    try testing.expect(in.seekable());
    try testing.expectEqual(@as(?u64, 10), in.length());
    var b: [3]u8 = undefined;
    try in.readExact(&b);
    try testing.expectEqualStrings("abc", &b);
    try testing.expectEqual(@as(u64, 3), in.position());
    try in.skip(4);
    try testing.expectEqual(@as(usize, 3), try in.readUpTo(&b));
    try testing.expectEqualStrings("hij", &b);
    try testing.expectEqual(@as(usize, 0), try in.readUpTo(&b));
    try testing.expectError(error.Truncated, in.readExact(&b));
    try testing.expectError(error.Truncated, in.skip(1));
    try in.seekTo(1);
    try in.readExact(&b);
    try testing.expectEqualStrings("bcd", &b);
    try testing.expectError(error.Truncated, in.seekTo(11));
}

test "Input over a reader is forward only" {
    var r: std.Io.Reader = .fixed("abcdefghij");
    var in: Input = .init(.{ .reader = &r });
    try testing.expect(!in.seekable());
    try testing.expectEqual(@as(?u64, null), in.length());
    var b: [4]u8 = undefined;
    try in.readExact(&b);
    try in.skip(2);
    try testing.expectEqual(@as(u64, 6), in.position());
    try testing.expectError(error.Unseekable, in.seekTo(0));
    try testing.expectEqual(@as(usize, 4), try in.readUpTo(&b));
    try testing.expectEqualStrings("ghij", &b);
    try testing.expectError(error.Truncated, in.readExact(&b));
}

test "Input over a file seeks" {
    if (!has_files) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "0123456789" });
    var file = try tmp.dir.openFile(testing.io, "f", .{});
    defer file.close(testing.io);
    var buf: [4]u8 = undefined;
    var fr = file.reader(testing.io, &buf);
    var in: Input = .init(.{ .file = &fr });
    try testing.expect(in.seekable());
    try testing.expectEqual(@as(?u64, 10), in.length());
    var b: [3]u8 = undefined;
    try in.readExact(&b);
    try testing.expectEqualStrings("012", &b);
    try in.skip(2);
    try testing.expectEqual(@as(u64, 5), in.position());
    try in.seekTo(8);
    try testing.expectEqual(@as(usize, 2), try in.readUpTo(&b));
    try testing.expectEqualStrings("89", b[0..2]);
    try in.seekTo(0);
    try in.readExact(&b);
    try testing.expectEqualStrings("012", &b);
    try testing.expectError(error.Truncated, in.skip(100));
}

test "Input over a custom source seeks" {
    var mem: helpers.MemorySource = .{ .data = "abcdefghij" };
    const src = mem.source();
    var in: Input = .init(.{ .custom = &src });
    try testing.expect(in.seekable());
    try testing.expectEqual(@as(?u64, 10), in.length());
    var b: [3]u8 = undefined;
    try in.readExact(&b);
    try testing.expectEqualStrings("abc", &b);
    try in.skip(4);
    try testing.expectEqual(@as(u64, 7), in.position());
    try testing.expectEqual(@as(usize, 3), try in.readUpTo(&b));
    try testing.expectEqualStrings("hij", &b);
    try testing.expectError(error.Truncated, in.readExact(&b));
    try testing.expectError(error.Truncated, in.skip(1));
    try in.seekTo(1);
    try testing.expectEqual(@as(u64, 1), in.position());
    try in.readExact(&b);
    try testing.expectEqualStrings("bcd", &b);
    try testing.expectError(error.Truncated, in.seekTo(11));
    try testing.expectEqual(@as(u32, 1), mem.seeks);
}

test "Input over a custom source skips more than its scratch buffer" {
    var data: [1000]u8 = undefined;
    for (&data, 0..) |*d, i| d.* = @truncate(i);
    var mem: helpers.MemorySource = .{ .data = &data };
    const src = mem.source();
    var in: Input = .init(.{ .custom = &src });
    try in.skip(700);
    var b: [1]u8 = undefined;
    try in.readExact(&b);
    try testing.expectEqual(data[700], b[0]);
    try testing.expectError(error.Truncated, in.skip(500));
}

test "Input over a streaming file is unseekable" {
    if (!has_files) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "0123456789" });
    var file = try tmp.dir.openFile(testing.io, "f", .{});
    defer file.close(testing.io);
    var buf: [4]u8 = undefined;
    var fr = file.readerStreaming(testing.io, &buf);
    var in: Input = .init(.{ .file = &fr });
    try testing.expect(!in.seekable());
    try testing.expectError(error.Unseekable, in.seekTo(2));
}

test "BitReader reads MSB first across bytes" {
    var br: BitReader = .initBytes(&.{ 0b1010_1100, 0b0101_0011, 0xff });
    try testing.expectEqual(@as(u64, 0b101), try br.readBits(3));
    try testing.expectEqual(@as(u64, 0b01100_0101), try br.readBits(9));
    try testing.expectEqual(@as(u64, 0), try br.readBits(0));
    try testing.expectEqual(@as(usize, 1), br.bytePosition());
    br.alignByte();
    try testing.expectEqual(@as(usize, 2), br.bytePosition());
    try testing.expectEqual(@as(u64, 0xff), try br.readBits(8));
    try testing.expectError(error.Truncated, br.readBits(1));
}

test "BitReader reads signed values and unary" {
    var br: BitReader = .initBytes(&.{ 0b1110_0000, 0b0001_0000, 0b1000_0000 });
    try testing.expectEqual(@as(i64, -1), try br.readSigned(3));
    try testing.expectEqual(@as(i64, 0), try br.readSigned(5));
    try testing.expectEqual(@as(u64, 3), try br.readUnary(10));
    try testing.expectEqual(@as(u64, 4), try br.readUnary(10));
    try testing.expectEqual(@as(i64, 0), try br.readSigned(0));
}

test "BitReader unary stops at the bound" {
    // Five zero bits and a one, twice.
    var br: BitReader = .initBytes(&.{ 0b0000_0100, 0b0001_0000 });
    try testing.expectError(error.BadData, br.readUnary(4));
    var again: BitReader = .initBytes(&.{ 0b0000_0100, 0b0001_0000 });
    try testing.expectEqual(@as(u64, 5), try again.readUnary(5));
    try testing.expectEqual(@as(u64, 5), try again.readUnary(5));
    // A long run of zero bytes is refused without reading it all.
    var zeros: [64]u8 = @splat(0);
    var long: BitReader = .initBytes(&zeros);
    try testing.expectError(error.BadData, long.readUnary(100));
    try testing.expect(long.bytePosition() < 20);
}

test "BitReader unary with no terminator is Truncated" {
    var br: BitReader = .initBytes(&.{ 0, 0 });
    try testing.expectError(error.Truncated, br.readUnary(100));
}

test "BitReader reads 63 bit values" {
    var br: BitReader = .initBytes(&.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe });
    try testing.expectEqual(@as(u64, std.math.maxInt(u63)), try br.readBits(63));
    try testing.expectError(error.Truncated, br.readBits(2));
}

test "BitReader rice decodes the FLAC zigzag" {
    // k = 2: value 0 -> "1 00", value -1 -> "1 01", value 1 -> "1 10", value -2 -> "1 11".
    var br: BitReader = .initBytes(&.{ 0b1001_0111, 0b0111_0000 });
    try testing.expectEqual(@as(i64, 0), try br.readRice(2));
    try testing.expectEqual(@as(i64, -1), try br.readRice(2));
    try testing.expectEqual(@as(i64, 1), try br.readRice(2));
    try testing.expectEqual(@as(i64, -2), try br.readRice(2));
}

test "BitReader rice overflow is BadData" {
    var data: [18]u8 = @splat(0);
    data[9] = 0x80;
    var br: BitReader = .initBytes(&data);
    try testing.expectError(error.BadData, br.readRice(63));
}

test "BitReader refills from an Input" {
    var data: [1000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 13);
    var in: Input = .init(.{ .bytes = &data });
    var store: [7]u8 = undefined;
    var br: BitReader = .initInput(&in, &store);
    for (data, 0..) |want, i| {
        try testing.expectEqual(@as(u64, want), try br.readBits(8));
        try testing.expectEqual(i + 1, br.bytePosition());
    }
    try testing.expectError(error.Truncated, br.readBits(1));
}

test "BitReader over an Input reads across refill boundaries" {
    var data: [64]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 77 +% 5);
    var in: Input = .init(.{ .bytes = &data });
    var store: [3]u8 = undefined;
    var a: BitReader = .initInput(&in, &store);
    var b: BitReader = .initBytes(&data);
    var n: u6 = 1;
    for (0..20) |_| {
        try testing.expectEqual(try b.readBits(n), try a.readBits(n));
        n = n % 31 + 3;
    }
}

test "BitWriter packs MSB first and aligns with zeros" {
    var bw: BitWriter = .init(testing.allocator);
    defer bw.deinit();
    try bw.writeBits(0b101, 3);
    try bw.writeBits(0b01100_0101, 9);
    try testing.expectEqualSlices(u8, &.{0b1010_1100}, bw.bytes());
    try bw.alignByte();
    try bw.writeBits(0xff, 8);
    try testing.expectEqualSlices(u8, &.{ 0b1010_1100, 0b0101_0000, 0xff }, bw.bytes());
}

test "BitWriter and BitReader round trip across byte boundaries" {
    var bw: BitWriter = .init(testing.allocator);
    defer bw.deinit();
    const widths = [_]u6{ 1, 7, 8, 9, 15, 16, 17, 31, 32, 33, 47, 63, 3, 5 };
    for (widths, 0..) |w, i| {
        const v: u64 = (@as(u64, 0x9e3779b97f4a7c15) *% (i + 1)) & ((@as(u64, 1) << w) - 1);
        try bw.writeBits(v, w);
    }
    try bw.writeSigned(-5, 4);
    try bw.writeSigned(std.math.minInt(i32), 32);
    try bw.writeSigned(7, 4);
    try bw.writeUnary(0);
    try bw.writeUnary(70);
    try bw.alignByte();
    var br: BitReader = .initBytes(bw.bytes());
    for (widths, 0..) |w, i| {
        const v: u64 = (@as(u64, 0x9e3779b97f4a7c15) *% (i + 1)) & ((@as(u64, 1) << w) - 1);
        try testing.expectEqual(v, try br.readBits(w));
    }
    try testing.expectEqual(@as(i64, -5), try br.readSigned(4));
    try testing.expectEqual(@as(i64, std.math.minInt(i32)), try br.readSigned(32));
    try testing.expectEqual(@as(i64, 7), try br.readSigned(4));
    try testing.expectEqual(@as(u64, 0), try br.readUnary(100));
    try testing.expectEqual(@as(u64, 70), try br.readUnary(100));
}

test "rice round trip for negative and large values" {
    var bw: BitWriter = .init(testing.allocator);
    defer bw.deinit();
    const values = [_]i64{ 0, -1, 1, -2, 2, 100, -100, 65535, -65536, std.math.maxInt(i32), std.math.minInt(i32) };
    for (values) |v| try bw.writeRice(v, 5);
    for (values[0..7]) |v| try bw.writeRice(v, 0);
    try bw.writeRice(std.math.maxInt(i64), 62);
    try bw.writeRice(std.math.minInt(i64), 63);
    try bw.alignByte();
    var br: BitReader = .initBytes(bw.bytes());
    for (values) |v| try testing.expectEqual(v, try br.readRice(5));
    for (values[0..7]) |v| try testing.expectEqual(v, try br.readRice(0));
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), try br.readRice(62));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try br.readRice(63));
}

test "rice codes have the expected bits" {
    var bw: BitWriter = .init(testing.allocator);
    defer bw.deinit();
    // Zigzag 5 with k = 1: quotient 2, remainder 1 -> "001 1".
    try bw.writeRice(-3, 1);
    try bw.alignByte();
    try testing.expectEqualSlices(u8, &.{0b0011_0000}, bw.bytes());
}

test "BitReader reports Truncated mid rice code" {
    var br: BitReader = .initBytes(&.{0b0000_0001});
    try testing.expectError(error.Truncated, br.readRice(4));
}

test "BitReader reset follows an Input seek" {
    var data: [100]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i);
    var in: Input = .init(.{ .bytes = &data });
    try in.skip(10);
    var store: [8]u8 = undefined;
    var br: BitReader = .initInput(&in, &store);
    try testing.expectEqual(@as(u64, 10), br.bytePosition());
    try testing.expectEqual(@as(u64, 10), try br.readBits(8));
    try testing.expectEqual(@as(u64, 11), br.bytePosition());
    try in.seekTo(50);
    br.reset();
    try testing.expectEqual(@as(u64, 50), br.bytePosition());
    try testing.expectEqual(@as(u64, 50), try br.readBits(8));
    try testing.expectEqual(@as(u64, 51), try br.readBits(8));
    try in.seekTo(3);
    br.reset();
    try testing.expectEqual(@as(u64, 3), br.bytePosition());
    try testing.expectEqual(@as(u64, 3), try br.readBits(8));
}

test "64 bit reads and writes" {
    var bw: BitWriter = .init(testing.allocator);
    defer bw.deinit();
    try bw.writeBits(0xfedc_ba98_7654_3210, 64);
    try bw.writeBits(5, 3);
    try bw.writeBits(std.math.maxInt(u64), 64);
    try bw.alignByte();
    var br: BitReader = .initBytes(bw.bytes());
    try testing.expectEqual(@as(u64, 0xfedc_ba98_7654_3210), try br.readBits(64));
    try testing.expectEqual(@as(u64, 5), try br.readBits(3));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), try br.readBits(64));
}

test "unary with a long zero run across refills" {
    var data: [41]u8 = undefined;
    @memset(&data, 0);
    data[40] = 0x08;
    var in: Input = .init(.{ .bytes = &data });
    var store: [5]u8 = undefined;
    var br: BitReader = .initInput(&in, &store);
    try testing.expectEqual(@as(u64, 40 * 8 + 4), try br.readUnary(1000));
    try testing.expectEqual(@as(u64, 40), br.bytePosition());
}

test "libogg page checksum vector" {
    // Single 17 byte packet page from libogg's framing self test.
    var page = [_]u8{
        0x4f, 0x67, 0x67, 0x53, 0, 0x06, 0, 0, 0, 0, 0,  0,  0,  0,
        0x01, 0x02, 0x03, 0x04, 0, 0,    0, 0, 0, 0, 0,  0,  1,  17,
        0,    1,    2,    3,    4, 5,    6, 7, 8, 9, 10, 11, 12, 13,
        14,   15,   16,
    };
    const stored = std.mem.readInt(u32, &.{ 0x15, 0xed, 0xec, 0x91 }, .little);
    try testing.expectEqual(@as(u32, 0x91eced15), stored);
    try testing.expectEqual(stored, @import("crc.zig").ogg.hash(&page));
}

test "BitReader CRC window spans refills" {
    var data: [300]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 29 +% 3);
    var in: Input = .init(.{ .bytes = &data });
    var store: [7]u8 = undefined;
    var br: BitReader = .initInput(&in, &store);
    for (0..5) |_| _ = try br.readBits(8);
    br.crcStart();
    for (0..100) |_| _ = try br.readBits(8);
    try testing.expectEqual(crc.flac8.hash(data[5..105]), br.crc8());
    for (0..40) |_| _ = try br.readBits(8);
    try testing.expectEqual(crc.flac16.hash(data[5..145]), br.crc16());
    // A new window starts clean and a partial byte is not counted.
    br.crcStart();
    _ = try br.readBits(8);
    _ = try br.readBits(3);
    try testing.expectEqual(crc.flac16.hash(data[145..146]), br.crc16());
}

test "BitReader CRC window over bytes" {
    var br: BitReader = .initBytes("123456789");
    br.crcStart();
    for (0..9) |_| _ = try br.readBits(8);
    try testing.expectEqual(@as(u8, 0xf4), br.crc8());
    try testing.expectEqual(@as(u16, 0xfee8), br.crc16());
}

test "BitReader hasMore, peekByte and moveTo" {
    var data: [20]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i);
    var in: Input = .init(.{ .bytes = &data });
    var store: [8]u8 = undefined;
    var br: BitReader = .initInput(&in, &store);
    try testing.expectEqual(@as(?u8, null), br.peekByte());
    try testing.expect(try br.hasMore());
    try testing.expectEqual(@as(?u8, 0), br.peekByte());
    try testing.expect(br.moveTo(5));
    try testing.expectEqual(@as(u64, 5), try br.readBits(8));
    try testing.expect(!br.moveTo(9));
    try testing.expect(br.moveTo(8));
    try testing.expectEqual(@as(u64, 8), try br.readBits(8));
    try testing.expect(!br.moveTo(0));
    try testing.expect(br.moveTo(9));
    try testing.expectEqual(@as(u64, 9), try br.readBits(8));
    try in.seekTo(0);
    br.reset();
    for (0..20) |_| try testing.expect(try br.hasMore() and (try br.readBits(8)) < 20);
    try testing.expect(!try br.hasMore());
}

test "LsbReader reads LSB first across bytes" {
    var r: LsbReader = .init(&.{ 0b1010_0101, 0b0000_0011, 0xff, 0x12, 0x34 });
    try testing.expectEqual(@as(u32, 0b101), try r.readBits(3));
    try testing.expectEqual(@as(u32, 0b110100), try r.readBits(6));
    try testing.expectEqual(@as(u32, 0), try r.readBits(0));
    try testing.expectEqual(@as(usize, 2), r.bytePosition());
    try testing.expect(try r.readBit());
    try testing.expectEqual(@as(u32, 0), try r.readBits(5));
    try testing.expectEqual(@as(u32, 0x6825fe), try r.readBits(25));
    try testing.expectEqual(@as(usize, 0), r.bitsLeft());
}

test "LsbReader reads 32 bits at any offset" {
    var r: LsbReader = .init(&.{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 });
    try r.skip(7);
    try testing.expectEqual(@as(u32, 0x0a080604), try r.readBits(32));
}

test "LsbReader end of packet is sticky" {
    var r: LsbReader = .init(&.{0xff});
    try testing.expectEqual(@as(u32, 7), try r.readBits(3));
    try testing.expectError(error.Truncated, r.readBits(6));
    try testing.expectEqual(@as(usize, 0), r.bitsLeft());
    try testing.expectError(error.Truncated, r.readBits(1));
    try testing.expectEqual(@as(u32, 0), try r.readBits(0));
    var empty: LsbReader = .init(&.{});
    try testing.expectError(error.Truncated, empty.readBit());
    try testing.expectEqual(@as(u32, 0), empty.peek(32));
}

test "LsbWriter packs LSB first and pads with zeros" {
    var w: LsbWriter = .init(testing.allocator);
    defer w.deinit();
    try w.writeBits(0b101, 3);
    try w.writeBits(0b0_10100, 6);
    try w.writeBits(0xdeadbeef, 32);
    try testing.expectEqual(@as(usize, 6), w.bytes().len);
    var r: LsbReader = .init(w.bytes());
    try testing.expectEqual(@as(u32, 0b101), try r.readBits(3));
    try testing.expectEqual(@as(u32, 0b0_10100), try r.readBits(6));
    try testing.expectEqual(@as(u32, 0xdeadbeef), try r.readBits(32));
    try testing.expectEqual(@as(u8, 0xa5), w.bytes()[0]);
}

test "readExact loops over short reads of a custom source" {
    const Dribble = struct {
        data: []const u8,
        pos: usize = 0,

        const vtable: @import("../codec.zig").SeekableSource.VTable = .{ .read = read, .seekTo = seekTo, .length = length };

        fn read(ctx: ?*anyopaque, buf: []u8) error{ReadFailed}!usize {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const n = @min(@min(buf.len, 1), self.data.len - self.pos);
            @memcpy(buf[0..n], self.data[self.pos..][0..n]);
            self.pos += n;
            return n;
        }

        fn seekTo(ctx: ?*anyopaque, offset: u64) error{ ReadFailed, Unseekable }!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.pos = @intCast(offset);
        }

        fn length(ctx: ?*anyopaque) ?u64 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return self.data.len;
        }
    };
    var d: Dribble = .{ .data = "abcdefghij" };
    const src: @import("../codec.zig").SeekableSource = .{ .ctx = &d, .vtable = &Dribble.vtable };
    var in: Input = .init(.{ .custom = &src });
    var b: [6]u8 = undefined;
    try in.readExact(&b);
    try testing.expectEqualStrings("abcdef", &b);
    try testing.expectError(error.Truncated, in.readExact(&b));
    try testing.expectEqual(@as(u64, 10), in.position());
}
