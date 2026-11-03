//! Helpers that the tests of the PipeWire client share.
const std = @import("std");
const linux = std.os.linux;
const pod = @import("../pod.zig");
const FakeServer = @import("FakeServer.zig");

const testing = std.testing;

/// The fields of the first pod of a message body, which must be a Struct.
pub fn fieldsOf(body: []const u8) !pod.StructIter {
    const parsed = try pod.Pod.parse(body);
    return parsed.pod.structIter();
}

pub fn nextInt(it: *pod.StructIter) !i32 {
    return (try it.next()).?.int();
}

/// A Struct of Int values.
pub fn ints(buf: []u8, vals: []const i32) []const u8 {
    var b = pod.Builder.init(buf);
    const f = b.beginStruct() catch unreachable;
    for (vals) |v| b.int(v) catch unreachable;
    b.end(f);
    return b.bytesWritten();
}

/// Checks that the server end gets no message for `ms` milliseconds.
pub fn expectQuiet(server: *FakeServer, ms: i32) !void {
    var pfd = [1]linux.pollfd{.{ .fd = server.server_fd, .events = linux.POLL.IN, .revents = 0 }};
    const rc = linux.poll(&pfd, 1, ms);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    try testing.expectEqual(@as(usize, 0), rc);
}

/// Checks a Core.error for node `node_id` with result `res` and a message.
pub fn expectCoreError(m: FakeServer.OwnedMessage, node_id: u32, res: i32) !void {
    var it = try fieldsOf(m.body);
    try testing.expectEqual(@as(i32, @bitCast(node_id)), try nextInt(&it));
    _ = try nextInt(&it);
    try testing.expectEqual(res, try nextInt(&it));
    const text: []const u8 = (try (try it.next()).?.string()) orelse "";
    try testing.expect(text.len > 0);
}

pub fn newEventfd() !linux.fd_t {
    const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    return @intCast(rc);
}

/// Adds 1 to an eventfd.
pub fn bump(fd: linux.fd_t) !void {
    const one = std.mem.toBytes(@as(u64, 1));
    try testing.expectEqual(@as(usize, 8), linux.write(fd, &one, one.len));
}

/// True while the eventfd holds a count. The read takes the count.
pub fn hasCount(fd: linux.fd_t) bool {
    var buf: [8]u8 = undefined;
    return linux.errno(linux.read(fd, &buf, buf.len)) == .SUCCESS;
}

/// Like `hasCount`, but the count stays.
pub fn hasCountAndRestore(fd: linux.fd_t) bool {
    var buf: [8]u8 = undefined;
    if (linux.errno(linux.read(fd, &buf, buf.len)) != .SUCCESS) return false;
    _ = linux.write(fd, &buf, buf.len);
    return true;
}

pub fn openFds() usize {
    var n: usize = 0;
    for (0..256) |fd| {
        if (linux.errno(linux.fcntl(@intCast(fd), linux.F.GETFD, 0)) == .SUCCESS) n += 1;
    }
    return n;
}

pub fn fdClosed(fd: linux.fd_t) bool {
    return linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)) == .BADF;
}
