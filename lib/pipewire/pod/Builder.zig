//! Writes SPA PODs into a caller supplied buffer.
const std = @import("std");
const spa = @import("../spa.zig");

const Builder = @This();

// The wire format uses native byte order, and every PipeWire target is little endian.
comptime {
    std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
}

pub const Error = error{NoSpace};

/// An open container. Pass it to `end`.
pub const Frame = struct {
    start: usize,
    packed_children: bool,
};

buf: []u8,
pos: usize = 0,
/// True inside a Choice or an Array: children have no header and no padding.
packed_mode: bool = false,
child_header: usize = 0,
child_set: bool = false,

pub fn init(buf: []u8) Builder {
    return .{ .buf = buf };
}

pub fn bytesWritten(self: *const Builder) []const u8 {
    return self.buf[0..self.pos];
}

pub fn none(self: *Builder) Error!void {
    _ = try self.reserve(.none, 0);
}

pub fn boolean(self: *Builder, v: bool) Error!void {
    const body = try self.reserve(.bool, 4);
    std.mem.writeInt(i32, body[0..4], @intFromBool(v), .little);
}

pub fn id(self: *Builder, v: u32) Error!void {
    const body = try self.reserve(.id, 4);
    std.mem.writeInt(u32, body[0..4], v, .little);
}

pub fn int(self: *Builder, v: i32) Error!void {
    const body = try self.reserve(.int, 4);
    std.mem.writeInt(i32, body[0..4], v, .little);
}

pub fn long(self: *Builder, v: i64) Error!void {
    const body = try self.reserve(.long, 8);
    std.mem.writeInt(i64, body[0..8], v, .little);
}

pub fn float(self: *Builder, v: f32) Error!void {
    const body = try self.reserve(.float, 4);
    std.mem.writeInt(u32, body[0..4], @bitCast(v), .little);
}

pub fn double(self: *Builder, v: f64) Error!void {
    const body = try self.reserve(.double, 8);
    std.mem.writeInt(u64, body[0..8], @bitCast(v), .little);
}

/// A null string writes a None pod.
pub fn string(self: *Builder, v: ?[]const u8) Error!void {
    const s = v orelse return self.none();
    std.debug.assert(!self.packed_mode);
    const body = try self.reserve(.string, s.len + 1);
    @memcpy(body[0..s.len], s);
    body[s.len] = 0;
}

pub fn bytes(self: *Builder, v: []const u8) Error!void {
    std.debug.assert(!self.packed_mode);
    const body = try self.reserve(.bytes, v.len);
    @memcpy(body, v);
}

pub fn fd(self: *Builder, v: i64) Error!void {
    const body = try self.reserve(.fd, 8);
    std.mem.writeInt(i64, body[0..8], v, .little);
}

pub fn fraction(self: *Builder, v: spa.Fraction) Error!void {
    const body = try self.reserve(.fraction, 8);
    std.mem.writeInt(u32, body[0..4], v.num, .little);
    std.mem.writeInt(u32, body[4..8], v.denom, .little);
}

pub fn rectangle(self: *Builder, v: spa.Rectangle) Error!void {
    const body = try self.reserve(.rectangle, 8);
    std.mem.writeInt(u32, body[0..4], v.width, .little);
    std.mem.writeInt(u32, body[4..8], v.height, .little);
}

pub fn beginStruct(self: *Builder) Error!Frame {
    std.debug.assert(!self.packed_mode);
    const start = self.pos;
    try self.writeWords(&.{ 0, @backingInt(spa.Type.@"struct") });
    return .{ .start = start, .packed_children = false };
}

pub fn beginObject(self: *Builder, object_type: u32, object_id: u32) Error!Frame {
    std.debug.assert(!self.packed_mode);
    const start = self.pos;
    try self.writeWords(&.{ 0, @backingInt(spa.Type.object), object_type, object_id });
    return .{ .start = start, .packed_children = false };
}

/// Writes a property header. The next value written is the property value.
pub fn prop(self: *Builder, key: u32, flags: spa.PropFlags) Error!void {
    std.debug.assert(!self.packed_mode);
    try self.writeWords(&.{ key, @as(u32, @bitCast(flags)) });
}

/// The values written until `end` are packed. Their type and size must be equal.
pub fn beginChoice(self: *Builder, kind: spa.ChoiceType, flags: u32) Error!Frame {
    std.debug.assert(!self.packed_mode);
    const start = self.pos;
    try self.writeWords(&.{ 0, @backingInt(spa.Type.choice), @backingInt(kind), flags, 0, @backingInt(spa.Type.none) });
    self.enterPacked(start + 16);
    return .{ .start = start, .packed_children = true };
}

pub fn beginArray(self: *Builder) Error!Frame {
    std.debug.assert(!self.packed_mode);
    const start = self.pos;
    try self.writeWords(&.{ 0, @backingInt(spa.Type.array), 0, @backingInt(spa.Type.none) });
    self.enterPacked(start + 8);
    return .{ .start = start, .packed_children = true };
}

/// Patches the size of the container. The padding is not part of the size.
pub fn end(self: *Builder, frame: Frame) void {
    const size: u32 = @intCast(self.pos - frame.start - 8);
    std.mem.writeInt(u32, self.buf[frame.start..][0..4], size, .little);
    if (frame.packed_children) {
        self.pos = std.mem.alignForward(usize, self.pos, 8);
        self.packed_mode = false;
    }
}

pub fn dict(self: *Builder, items: []const [2][]const u8) Error!void {
    const frame = try self.beginStruct();
    try self.int(@intCast(items.len));
    for (items) |item| {
        try self.string(item[0]);
        try self.string(item[1]);
    }
    self.end(frame);
}

fn enterPacked(self: *Builder, child_header: usize) void {
    self.packed_mode = true;
    self.child_header = child_header;
    self.child_set = false;
}

fn writeWords(self: *Builder, words: []const u32) Error!void {
    const n = words.len * 4;
    if (n > self.buf.len - self.pos) return error.NoSpace;
    for (words, 0..) |w, i| {
        std.mem.writeInt(u32, self.buf[self.pos + i * 4 ..][0..4], w, .little);
    }
    self.pos += n;
}

/// Writes the header for a value and returns the body to fill.
/// The padding bytes after the body are set to zero.
fn reserve(self: *Builder, ty: spa.Type, len: usize) Error![]u8 {
    if (self.packed_mode) {
        if (!self.child_set) {
            std.mem.writeInt(u32, self.buf[self.child_header..][0..4], @intCast(len), .little);
            std.mem.writeInt(u32, self.buf[self.child_header + 4 ..][0..4], @backingInt(ty), .little);
            self.child_set = true;
        } else {
            const size = std.mem.readInt(u32, self.buf[self.child_header..][0..4], .little);
            const kind = std.mem.readInt(u32, self.buf[self.child_header + 4 ..][0..4], .little);
            std.debug.assert(size == len and kind == @backingInt(ty));
        }
        const padded = std.mem.alignForward(usize, self.pos + len, 8);
        if (padded > self.buf.len) return error.NoSpace;
        const body = self.buf[self.pos..][0..len];
        @memset(self.buf[self.pos + len .. padded], 0);
        self.pos += len;
        return body;
    }
    const total = std.math.add(usize, 8, std.mem.alignForward(usize, len, 8)) catch return error.NoSpace;
    if (total > self.buf.len - self.pos) return error.NoSpace;
    std.mem.writeInt(u32, self.buf[self.pos..][0..4], @intCast(len), .little);
    std.mem.writeInt(u32, self.buf[self.pos + 4 ..][0..4], @backingInt(ty), .little);
    @memset(self.buf[self.pos + 8 + len .. self.pos + total], 0);
    const body = self.buf[self.pos + 8 ..][0..len];
    self.pos += total;
    return body;
}

test "pods are padded to 8 bytes" {
    var buf: [80]u8 = undefined;
    var b = Builder.init(&buf);
    try b.int(7);
    try std.testing.expectEqual(@as(usize, 16), b.bytesWritten().len);
    try b.string("");
    try std.testing.expectEqual(@as(usize, 32), b.bytesWritten().len);
    try b.string("1234567");
    try std.testing.expectEqual(@as(usize, 48), b.bytesWritten().len);
    try b.string("12345678");
    try std.testing.expectEqual(@as(usize, 72), b.bytesWritten().len);
}

test "string with a 1 byte body" {
    var buf: [32]u8 = undefined;
    var b = Builder.init(&buf);
    try b.string("a");
    const want = [_]u8{ 2, 0, 0, 0, 8, 0, 0, 0, 'a', 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &want, b.bytesWritten());
}

test "a buffer of 7 bytes has no space for an int" {
    var buf: [7]u8 = undefined;
    var b = Builder.init(&buf);
    try std.testing.expectError(error.NoSpace, b.int(1));
    try std.testing.expectEqual(@as(usize, 0), b.bytesWritten().len);
}

test "empty array and empty choice write a None child header" {
    var buf: [64]u8 = undefined;
    var b = Builder.init(&buf);
    const a = try b.beginArray();
    b.end(a);
    const c = try b.beginChoice(.@"enum", 0);
    b.end(c);
    const want = [_]u8{
        0x08, 0, 0, 0, 0x0d, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0,
        0x10, 0, 0, 0, 0x13, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0,
        0,    0, 0, 0, 1,    0, 0, 0,
    };
    try std.testing.expectEqualSlices(u8, &want, b.bytesWritten());
}

test "a full buffer stops a packed value" {
    var buf: [24]u8 = undefined;
    var b = Builder.init(&buf);
    const c = try b.beginChoice(.range, 0);
    try std.testing.expectError(error.NoSpace, b.int(1));
    _ = c;
}
