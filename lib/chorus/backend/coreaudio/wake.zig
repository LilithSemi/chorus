//! A non blocking pipe. A listener writes one byte and `dispatch` reads the bytes.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Wake = @This();

/// True on the systems where the pipe exists.
pub const available = builtin.os.tag == .linux or builtin.os.tag == .macos;

read_fd: i32 = -1,
write_fd: i32 = -1,

pub fn open() error{Unavailable}!Wake {
    var fds: [2]i32 = undefined;
    switch (comptime builtin.os.tag) {
        .linux => {
            const rc = linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true });
            if (linux.errno(rc) != .SUCCESS) return error.Unavailable;
        },
        .macos => {
            if (std.c.pipe(&fds) != 0) return error.Unavailable;
            errdefer closeBoth(fds);
            for (fds) |fd| {
                const nonblock: std.c.O = .{ .NONBLOCK = true };
                if (std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(nonblock))) != 0) return error.Unavailable;
                if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) != 0) return error.Unavailable;
            }
        },
        else => return error.Unavailable,
    }
    return .{ .read_fd = fds[0], .write_fd = fds[1] };
}

fn closeBoth(fds: [2]i32) void {
    switch (comptime builtin.os.tag) {
        .linux => {
            _ = linux.close(fds[0]);
            _ = linux.close(fds[1]);
        },
        .macos => {
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
        },
        else => {},
    }
}

pub fn close(self: *Wake) void {
    closeBoth(.{ self.read_fd, self.write_fd });
    self.* = .{};
}

/// Makes `read_fd` readable. A full pipe already holds a wake, so the write needs no retry.
pub fn signal(self: *const Wake) void {
    const byte = [1]u8{1};
    switch (comptime builtin.os.tag) {
        .linux => _ = linux.write(self.write_fd, &byte, 1),
        .macos => _ = std.c.write(self.write_fd, &byte, 1),
        else => {},
    }
}

/// Reads every byte that waits.
pub fn drain(self: *const Wake) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n: isize = switch (comptime builtin.os.tag) {
            .linux => @bitCast(linux.read(self.read_fd, &buf, buf.len)),
            .macos => std.c.read(self.read_fd, &buf, buf.len),
            else => 0,
        };
        if (n <= 0) return;
    }
}

/// True when a byte waits.
pub fn pending(self: *const Wake) bool {
    var pfd = [1]std.posix.pollfd{.{ .fd = self.read_fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&pfd, 0) catch return false;
    return ready == 1;
}

test "a signal makes the read end readable until drain" {
    if (comptime !available) return error.SkipZigTest;
    var wake = try open();
    defer wake.close();
    try std.testing.expect(!wake.pending());
    wake.signal();
    wake.signal();
    try std.testing.expect(wake.pending());
    wake.drain();
    try std.testing.expect(!wake.pending());
}

test "the pipe never blocks" {
    if (comptime !available) return error.SkipZigTest;
    var wake = try open();
    defer wake.close();
    // Far more writes than the pipe holds. A blocking write would hang the test.
    for (0..200_000) |_| wake.signal();
    wake.drain();
    try std.testing.expect(!wake.pending());
    wake.drain();
}

test "close resets the descriptors" {
    if (comptime !available) return error.SkipZigTest;
    var wake = try open();
    try std.testing.expect(wake.read_fd >= 0 and wake.write_fd >= 0);
    wake.close();
    try std.testing.expectEqual(@as(i32, -1), wake.read_fd);
    try std.testing.expectEqual(@as(i32, -1), wake.write_fd);
}
