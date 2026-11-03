//! The MD5 of the samples of a FLAC stream.
const std = @import("std");
const testing = std.testing;

/// Hashes samples as little endian bytes. It collects them in a small buffer first.
pub const Stage = struct {
    md5: std.crypto.hash.Md5 = .init(.{}),
    buf: [4096]u8 = undefined,
    len: usize = 0,

    /// Adds the low `width` bytes of `v`.
    pub fn add(self: *Stage, v: i32, width: usize) void {
        if (self.len + 4 > self.buf.len) {
            self.md5.update(self.buf[0..self.len]);
            self.len = 0;
        }
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(i32, &tmp, v, .little);
        @memcpy(self.buf[self.len..][0..width], tmp[0..width]);
        self.len += width;
    }

    /// The digest of the samples added so far. The stage keeps its state.
    pub fn digest(self: *const Stage) [16]u8 {
        var copy = self.md5;
        copy.update(self.buf[0..self.len]);
        var out: [16]u8 = undefined;
        copy.final(&out);
        return out;
    }
};

test "the stage hashes the low bytes of the samples" {
    var stage: Stage = .{};
    var plain: std.crypto.hash.Md5 = .init(.{});
    for (0..5000) |i| {
        const v: i32 = @as(i32, @intCast(i)) * 7919 - 20000;
        stage.add(v, 3);
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(i32, &tmp, v, .little);
        plain.update(tmp[0..3]);
    }
    var want: [16]u8 = undefined;
    plain.final(&want);
    try testing.expectEqualSlices(u8, &want, &stage.digest());
    // The digest does not change the state.
    try testing.expectEqualSlices(u8, &want, &stage.digest());
    stage.add(1, 3);
    try testing.expect(!std.mem.eql(u8, &want, &stage.digest()));
}
