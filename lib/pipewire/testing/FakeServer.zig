//! The server end of a socket pair, for tests. It parses and writes the wire format on
//! its own, so a bug in `Connection` does not hide behind a matching bug here.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Connection = @import("../Connection.zig");

const FakeServer = @This();

pub const OwnedMessage = struct {
    header: [16]u8,
    id: u32,
    opcode: u8,
    size: u32,
    seq: u32,
    n_fds: u32,
    body: []u8,
    fds: []linux.fd_t,

    pub fn deinit(self: *OwnedMessage, gpa: std.mem.Allocator) void {
        for (self.fds) |f| _ = linux.close(f);
        gpa.free(self.body);
        gpa.free(self.fds);
    }
};

const endian = builtin.cpu.arch.endian();
const timeout_ms = 2000;

gpa: std.mem.Allocator,
/// The client end. Give it to `Connection.fromFd`, which then owns it.
client_fd: linux.fd_t,
server_fd: linux.fd_t,
seq: u32 = 0,
rbuf: std.ArrayList(u8) = .empty,
rfds: std.ArrayList(linux.fd_t) = .empty,

pub fn init(gpa: std.mem.Allocator) !FakeServer {
    var pair: [2]linux.fd_t = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair);
    if (linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    // Only the client end is non blocking.
    const flags = linux.fcntl(pair[0], linux.F.GETFL, 0);
    const nonblock: usize = 1 << @bitOffsetOf(linux.O, "NONBLOCK");
    if (linux.errno(linux.fcntl(pair[0], linux.F.SETFL, flags | nonblock)) != .SUCCESS) {
        _ = linux.close(pair[0]);
        _ = linux.close(pair[1]);
        return error.SocketPairFailed;
    }
    return .{ .gpa = gpa, .client_fd = pair[0], .server_fd = pair[1] };
}

/// Closes the server end and every fd not handed out. The client end is not closed.
pub fn deinit(self: *FakeServer) void {
    _ = linux.close(self.server_fd);
    for (self.rfds.items) |f| _ = linux.close(f);
    self.rfds.deinit(self.gpa);
    self.rbuf.deinit(self.gpa);
    self.* = undefined;
}

/// Appends one framed message with the next seq to `out`. `n_fds` is the count the header claims.
pub fn encode(self: *FakeServer, out: *std.ArrayList(u8), id: u32, opcode: u8, body: []const u8, n_fds: u32) !void {
    var header: [16]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], id, endian);
    std.mem.writeInt(u32, header[4..8], @as(u32, opcode) << 24 | @as(u32, @intCast(body.len)), endian);
    std.mem.writeInt(u32, header[8..12], self.seq, endian);
    std.mem.writeInt(u32, header[12..16], n_fds, endian);
    self.seq = (self.seq + 1) & 0x3FFFFFFF;
    try out.appendSlice(self.gpa, &header);
    try out.appendSlice(self.gpa, body);
}

/// Writes the bytes as they are. The fds ride with the first byte, at most 28 of them.
pub fn sendRaw(self: *FakeServer, bytes: []const u8, fds: []const linux.fd_t) !void {
    var rest = bytes;
    var with = fds;
    while (rest.len > 0) {
        const n = try Connection.sendRaw(self.server_fd, rest, with);
        rest = rest[n..];
        with = &.{};
    }
}

pub fn send(self: *FakeServer, id: u32, opcode: u8, body: []const u8, fds: []const linux.fd_t) !void {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(self.gpa);
    try self.encode(&wire, id, opcode, body, @intCast(fds.len));
    try self.sendRaw(wire.items, fds);
}

/// Waits up to two seconds for a whole message.
pub fn readMessage(self: *FakeServer) !OwnedMessage {
    while (true) {
        if (self.rbuf.items.len >= 16) {
            const word1 = std.mem.readInt(u32, self.rbuf.items[4..8], endian);
            const size: usize = word1 & 0xFFFFFF;
            const n_fds = std.mem.readInt(u32, self.rbuf.items[12..16], endian);
            if (self.rbuf.items.len >= 16 + size and self.rfds.items.len >= n_fds) return self.take(size, n_fds);
        }
        try self.fill();
    }
}

pub fn expect(self: *FakeServer, id: u32, opcode: u8) !OwnedMessage {
    var m = try self.readMessage();
    errdefer m.deinit(self.gpa);
    try std.testing.expectEqual(id, m.id);
    try std.testing.expectEqual(opcode, m.opcode);
    return m;
}

fn take(self: *FakeServer, size: usize, n_fds: u32) !OwnedMessage {
    const body = try self.gpa.dupe(u8, self.rbuf.items[16..][0..size]);
    errdefer self.gpa.free(body);
    const fds = try self.gpa.dupe(linux.fd_t, self.rfds.items[0..n_fds]);
    errdefer self.gpa.free(fds);
    const h = self.rbuf.items[0..16];
    const word1 = std.mem.readInt(u32, h[4..8], endian);
    const msg: OwnedMessage = .{
        .header = h.*,
        .id = std.mem.readInt(u32, h[0..4], endian),
        .opcode = @intCast(word1 >> 24),
        .size = word1 & 0xFFFFFF,
        .seq = std.mem.readInt(u32, h[8..12], endian),
        .n_fds = n_fds,
        .body = body,
        .fds = fds,
    };
    const used = 16 + size;
    std.mem.copyForwards(u8, self.rbuf.items[0..], self.rbuf.items[used..]);
    self.rbuf.shrinkRetainingCapacity(self.rbuf.items.len - used);
    const left = self.rfds.items.len - n_fds;
    std.mem.copyForwards(linux.fd_t, self.rfds.items[0..], self.rfds.items[n_fds..]);
    self.rfds.shrinkRetainingCapacity(left);
    return msg;
}

fn fill(self: *FakeServer) !void {
    var pfd = [1]linux.pollfd{.{ .fd = self.server_fd, .events = linux.POLL.IN }};
    const ready = linux.poll(&pfd, 1, timeout_ms);
    if (linux.errno(ready) != .SUCCESS) return error.PollFailed;
    if (ready == 0) return error.Timeout;

    var chunk: [4096]u8 = undefined;
    var fd_buf: [Connection.max_fds_per_call]linux.fd_t = undefined;
    const got = Connection.recvRaw(self.server_fd, &chunk, &fd_buf) catch |err| switch (err) {
        error.WouldBlock => return,
        else => |e| return e,
    };
    try self.rfds.appendSlice(self.gpa, fd_buf[0..got.n_fds]);
    if (got.n_bytes == 0) return error.Disconnected;
    try self.rbuf.appendSlice(self.gpa, chunk[0..got.n_bytes]);
}
