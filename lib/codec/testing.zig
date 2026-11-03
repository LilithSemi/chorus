//! Helpers that the tests of the codec files share.
const std = @import("std");
const codec = @import("../codec.zig");
const io = @import("io.zig");

/// A `codec.SeekableSource` over a byte slice.
pub const MemorySource = struct {
    data: []const u8,
    pos: usize = 0,
    /// Calls of `seekTo`.
    seeks: u32 = 0,

    const vtable: codec.SeekableSource.VTable = .{ .read = read, .seekTo = seekTo, .length = length };

    pub fn source(self: *MemorySource) codec.SeekableSource {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn cast(ctx: ?*anyopaque) *MemorySource {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn read(ctx: ?*anyopaque, buf: []u8) error{ReadFailed}!usize {
        const self = cast(ctx);
        const n = @min(buf.len, self.data.len - self.pos);
        @memcpy(buf[0..n], self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    fn seekTo(ctx: ?*anyopaque, offset: u64) error{ ReadFailed, Unseekable }!void {
        const self = cast(ctx);
        if (offset > self.data.len) return error.ReadFailed;
        self.pos = @intCast(offset);
        self.seeks += 1;
    }

    fn length(ctx: ?*anyopaque) ?u64 {
        return cast(ctx).data.len;
    }
};

/// A vendored FLAC test file.
pub fn embed(comptime name: []const u8) []const u8 {
    return @embedFile("testdata/flac/" ++ name ++ ".flac");
}

/// Reads a decoder to its end, `chunk` frames per call, and returns the interleaved samples.
pub fn readAll(gpa: std.mem.Allocator, dec: anytype, chunk: usize) ![]f32 {
    const channels: usize = dec.info().channels;
    var all: std.ArrayList(f32) = .empty;
    errdefer all.deinit(gpa);
    const buf = try gpa.alloc(f32, chunk * channels);
    defer gpa.free(buf);
    while (true) {
        const n = try dec.read(buf);
        if (n == 0) break;
        try all.appendSlice(gpa, buf[0 .. n * channels]);
    }
    return all.toOwnedSlice(gpa);
}

/// Checks that `Dec.init` over a byte slice fails with `want`.
pub fn expectInitError(comptime Dec: type, want: anyerror, bytes: []const u8) !void {
    var input: io.Input = .init(.{ .bytes = bytes });
    try std.testing.expectError(want, Dec.init(std.testing.allocator, &input));
}
