//! One client connection to the PipeWire native protocol socket. It frames messages
//! and passes file descriptors with SCM_RIGHTS. The socket is non blocking.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const Connection = @This();

pub const Error = error{
    OutOfMemory,
    ConnectionRefused,
    FileNotFound,
    AccessDenied,
    Disconnected,
    Protocol,
    TooManyFds,
    MessageTooLarge,
    Unexpected,
};

pub const Message = struct {
    id: u32,
    opcode: u8,
    seq: u32,
    body: []const u8,
    fds: []const linux.fd_t,
};

const header_size = 16;
const max_body = 0xFFFFFF;
const seq_mask = 0x3FFFFFFF;
/// Fds in one sendmsg or recvmsg.
pub const max_fds_per_call = 28;
const max_queued_fds = 1024;
const grow_step = 32768;
const max_in_buffer = 16 * 1024 * 1024;
const endian = builtin.cpu.arch.endian();

// Not in std.os.linux.
const F_DUPFD_CLOEXEC = 1030;

const OutFd = struct {
    /// Offset in `out` of the message this fd belongs to.
    pos: usize,
    fd: linux.fd_t,
};

const Held = struct { total: usize, n_fds: usize };

gpa: std.mem.Allocator,
sock: linux.fd_t,
seq: u32 = 0,
out: std.ArrayList(u8) = .empty,
out_fds: std.ArrayList(OutFd) = .empty,
in: []u8 = &.{},
in_start: usize = 0,
in_len: usize = 0,
in_fds: std.ArrayList(linux.fd_t) = .empty,
held: ?Held = null,
/// Set after the control data of a read was cut short. Every later call gives `Protocol`.
broken: bool = false,

pub fn connect(gpa: std.mem.Allocator, path: [:0]const u8) Error!Connection {
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    // A path that does not fit cannot name an existing socket.
    if (path.len >= addr.path.len) return error.FileNotFound;
    @memcpy(addr.path[0..path.len], path);
    var name_len: usize = @offsetOf(linux.sockaddr.un, "path") + path.len;
    if (path.len > 0 and path[0] == '@') {
        addr.path[0] = 0;
    } else {
        name_len += 1;
    }

    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    try check(rc);
    const sock: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(sock);
    while (true) {
        const c = linux.connect(sock, &addr, @intCast(name_len));
        switch (linux.errno(c)) {
            .SUCCESS => break,
            .INTR => continue,
            // A unix socket gives EAGAIN when the listen backlog is full.
            .AGAIN => return error.ConnectionRefused,
            else => |e| return mapErrno(e),
        }
    }
    return fromFd(gpa, sock);
}

/// Takes ownership of `sock`.
pub fn fromFd(gpa: std.mem.Allocator, sock: linux.fd_t) Connection {
    return .{ .gpa = gpa, .sock = sock };
}

pub fn deinit(self: *Connection) void {
    _ = linux.close(self.sock);
    for (self.in_fds.items) |f| closeFd(f);
    for (self.out_fds.items) |o| closeFd(o.fd);
    self.in_fds.deinit(self.gpa);
    self.out_fds.deinit(self.gpa);
    self.out.deinit(self.gpa);
    self.gpa.free(self.in);
    self.* = undefined;
}

pub fn fd(self: *const Connection) linux.fd_t {
    return self.sock;
}

/// Queues one message. `body` is copied. `fds` are duplicated with CLOEXEC, the caller keeps its own.
/// Returns the seq of the message.
pub fn send(self: *Connection, id: u32, opcode: u8, body: []const u8, fds: []const linux.fd_t) Error!u32 {
    if (body.len > max_body) return error.MessageTooLarge;
    if (fds.len > max_queued_fds - self.out_fds.items.len) return error.TooManyFds;
    try self.out.ensureUnusedCapacity(self.gpa, header_size + body.len);
    try self.out_fds.ensureUnusedCapacity(self.gpa, fds.len);

    const start = self.out.items.len;
    const fds_before = self.out_fds.items.len;
    errdefer {
        for (self.out_fds.items[fds_before..]) |o| closeFd(o.fd);
        self.out_fds.shrinkRetainingCapacity(fds_before);
    }
    for (fds) |f| {
        const rc = linux.fcntl(f, F_DUPFD_CLOEXEC, 0);
        try check(rc);
        self.out_fds.appendAssumeCapacity(.{ .pos = start, .fd = @intCast(rc) });
    }

    const used = self.seq;
    self.seq = (used + 1) & seq_mask;
    var header: [header_size]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], id, endian);
    std.mem.writeInt(u32, header[4..8], @as(u32, opcode) << 24 | @as(u32, @intCast(body.len)), endian);
    std.mem.writeInt(u32, header[8..12], used, endian);
    std.mem.writeInt(u32, header[12..16], @intCast(fds.len), endian);
    self.out.appendSliceAssumeCapacity(&header);
    self.out.appendSliceAssumeCapacity(body);
    return used;
}

/// Writes queued messages. Returns true when the queue is empty, false when the socket is full.
pub fn flush(self: *Connection) Error!bool {
    if (self.broken) return error.Protocol;
    while (self.out.items.len > 0) {
        var chunk = self.out.items.len;
        var group: usize = 0;
        if (self.out_fds.items.len > 0) {
            const first = self.out_fds.items[0].pos;
            if (first > 0) {
                chunk = first;
            } else {
                while (group < self.out_fds.items.len and self.out_fds.items[group].pos == 0) group += 1;
                if (group > max_fds_per_call) {
                    // The rest of the fds go with the next bytes.
                    chunk = @min(4, chunk);
                } else if (group < self.out_fds.items.len) {
                    chunk = self.out_fds.items[group].pos;
                }
            }
        }
        const n_fds = @min(group, max_fds_per_call);
        var fd_buf: [max_fds_per_call]linux.fd_t = undefined;
        for (self.out_fds.items[0..n_fds], 0..) |o, i| fd_buf[i] = o.fd;

        const sent = sendRaw(self.sock, self.out.items[0..chunk], fd_buf[0..n_fds]) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => |e| return e,
        };
        for (self.out_fds.items[0..n_fds]) |o| closeFd(o.fd);
        dropFront(OutFd, &self.out_fds, n_fds);
        dropFront(u8, &self.out, sent);
        for (self.out_fds.items) |*o| o.pos -|= sent;
    }
    return true;
}

/// Next complete message, or null when more bytes are needed and the socket has none now.
/// The message is valid until the next call to receive. Fds in it stay owned by the Connection
/// unless taken with takeFd, and are closed on the next receive.
/// When the control data of a read is cut short, the fds of that read are closed and the
/// connection is broken: this and every later `receive` or `flush` gives `Protocol`.
pub fn receive(self: *Connection) Error!?Message {
    if (self.broken) return error.Protocol;
    self.release();
    while (true) {
        var want: usize = header_size;
        const avail = self.in[self.in_start..self.in_len];
        if (avail.len >= header_size) {
            const word1 = std.mem.readInt(u32, avail[4..8], endian);
            const size: usize = word1 & max_body;
            const n_fds: usize = std.mem.readInt(u32, avail[12..16], endian);
            if (n_fds > max_queued_fds) return error.Protocol;
            want = header_size + size;
            if (avail.len >= want and self.in_fds.items.len >= n_fds) {
                self.held = .{ .total = want, .n_fds = n_fds };
                return .{
                    .id = std.mem.readInt(u32, avail[0..4], endian),
                    .opcode = @intCast(word1 >> 24),
                    .seq = std.mem.readInt(u32, avail[8..12], endian),
                    .body = avail[header_size..want],
                    .fds = self.in_fds.items[0..n_fds],
                };
            }
        }
        try self.reserveIn(want);
        try self.in_fds.ensureUnusedCapacity(self.gpa, max_fds_per_call);

        var fd_buf: [max_fds_per_call]linux.fd_t = undefined;
        const got = recvRaw(self.sock, self.in[self.in_len..], &fd_buf) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => |e| return e,
        };
        if (got.truncated) {
            for (fd_buf[0..got.n_fds]) |f| closeFd(f);
            self.broken = true;
            return error.Protocol;
        }
        self.in_fds.appendSliceAssumeCapacity(fd_buf[0..got.n_fds]);
        if (self.in_fds.items.len > max_queued_fds) return error.Protocol;
        if (got.n_bytes == 0) return error.Disconnected;
        self.in_len += got.n_bytes;
    }
}

/// Gives the caller ownership of fd number `index` of `msg`, which must be the message of the
/// latest `receive`. The caller must close it.
pub fn takeFd(self: *Connection, msg: Message, index: usize) Error!linux.fd_t {
    const held = self.held orelse return error.Protocol;
    if (msg.fds.ptr != self.in_fds.items.ptr or index >= held.n_fds) return error.Protocol;
    const f = self.in_fds.items[index];
    if (f < 0) return error.Protocol;
    self.in_fds.items[index] = -1;
    return f;
}

/// Drops the message that the last receive returned.
fn release(self: *Connection) void {
    const held = self.held orelse return;
    self.held = null;
    for (self.in_fds.items[0..held.n_fds]) |f| closeFd(f);
    dropFront(linux.fd_t, &self.in_fds, held.n_fds);
    self.in_start += held.total;
    if (self.in_start == self.in_len) {
        self.in_start = 0;
        self.in_len = 0;
    }
}

/// Makes room for a message of `want` bytes counted from `in_start`.
fn reserveIn(self: *Connection, want: usize) Error!void {
    if (self.in_start > 0) {
        const keep = self.in_len - self.in_start;
        std.mem.copyForwards(u8, self.in[0..keep], self.in[self.in_start..self.in_len]);
        self.in_start = 0;
        self.in_len = keep;
    }
    const need = @max(want, self.in_len + 1);
    if (need <= self.in.len) return;
    const new_len = std.mem.alignForward(usize, need, grow_step);
    if (new_len > max_in_buffer) return error.Protocol;
    self.in = try self.gpa.realloc(self.in, new_len);
}

fn dropFront(comptime T: type, list: *std.ArrayList(T), n: usize) void {
    const rest = list.items.len - n;
    std.mem.copyForwards(T, list.items[0..rest], list.items[n..]);
    list.shrinkRetainingCapacity(rest);
}

fn closeFd(f: linux.fd_t) void {
    if (f >= 0) _ = linux.close(f);
}

fn check(rc: usize) Error!void {
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |e| mapErrno(e),
    };
}

fn mapErrno(e: linux.E) Error {
    return switch (e) {
        .NOENT => error.FileNotFound,
        .CONNREFUSED => error.ConnectionRefused,
        .ACCES, .PERM => error.AccessDenied,
        .PIPE, .CONNRESET, .NOTCONN => error.Disconnected,
        .NOMEM, .NOBUFS => error.OutOfMemory,
        else => error.Unexpected,
    };
}

const cmsg_align = @sizeOf(usize);
const cmsg_header = std.mem.alignForward(usize, @sizeOf(linux.cmsghdr), cmsg_align);
const cmsg_space = cmsg_header + std.mem.alignForward(usize, max_fds_per_call * @sizeOf(linux.fd_t), cmsg_align);

const MSG_CTRUNC = 0x8;

/// Sends `bytes` with `fds` attached. Both Connection and the test server use it.
pub fn sendRaw(sock: linux.fd_t, bytes: []const u8, fds: []const linux.fd_t) (Error || error{WouldBlock})!usize {
    std.debug.assert(fds.len <= max_fds_per_call);
    var iov = [1]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    var control: [cmsg_space]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var control_len: usize = 0;
    if (fds.len > 0) {
        const data_len = fds.len * @sizeOf(linux.fd_t);
        control_len = cmsg_header + std.mem.alignForward(usize, data_len, cmsg_align);
        @memset(control[0..control_len], 0);
        const hdr: *linux.cmsghdr = @ptrCast(&control);
        hdr.* = .{ .len = cmsg_header + data_len, .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
        @memcpy(control[cmsg_header..][0..data_len], std.mem.sliceAsBytes(fds));
    }
    var msg: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = if (fds.len > 0) &control else null,
        .controllen = control_len,
        .flags = 0,
    };
    while (true) {
        const rc = linux.sendmsg(sock, &msg, linux.MSG.NOSIGNAL);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => |e| return mapErrno(e),
        }
    }
}

pub const Received = struct { n_bytes: usize, n_fds: usize, truncated: bool };

/// Reads bytes and fds. The fds have CLOEXEC set. Both Connection and the test server use it.
/// When `truncated` is set the fds that did not fit in the control data were closed by the kernel.
pub fn recvRaw(sock: linux.fd_t, buf: []u8, fds_out: *[max_fds_per_call]linux.fd_t) (Error || error{WouldBlock})!Received {
    var iov = [1]std.posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
    var control: [cmsg_space]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var msg: linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const rc = while (true) {
        const r = linux.recvmsg(sock, &msg, linux.MSG.CMSG_CLOEXEC);
        switch (linux.errno(r)) {
            .SUCCESS => break r,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => |e| return mapErrno(e),
        }
    };

    var n_fds: usize = 0;
    var off: usize = 0;
    const control_len = @min(msg.controllen, control.len);
    while (off + cmsg_header <= control_len) {
        const hdr: *const linux.cmsghdr = @ptrCast(@alignCast(&control[off]));
        if (hdr.len < cmsg_header) break;
        const end = @min(off + hdr.len, control_len);
        if (hdr.level == linux.SOL.SOCKET and hdr.type == linux.SCM.RIGHTS) {
            const count = @min((end - off - cmsg_header) / @sizeOf(linux.fd_t), max_fds_per_call - n_fds);
            const bytes = control[off + cmsg_header ..][0 .. count * @sizeOf(linux.fd_t)];
            @memcpy(std.mem.sliceAsBytes(fds_out[n_fds..][0..count]), bytes);
            n_fds += count;
        }
        off += std.mem.alignForward(usize, hdr.len, cmsg_align);
    }
    return .{ .n_bytes = rc, .n_fds = n_fds, .truncated = msg.flags & MSG_CTRUNC != 0 };
}

const FakeServer = @import("testing/FakeServer.zig");
const pod = @import("pod.zig");

fn structInt(buf: []u8, v: i32) ![]const u8 {
    var b = pod.Builder.init(buf);
    const f = try b.beginStruct();
    try b.int(v);
    b.end(f);
    return b.bytesWritten();
}

fn fdIsOpen(f: linux.fd_t) bool {
    return linux.errno(linux.fcntl(f, linux.F.GETFD, 0)) == .SUCCESS;
}

fn newMemfd() linux.fd_t {
    const rc = linux.memfd_create("t", linux.MFD.CLOEXEC);
    std.debug.assert(linux.errno(rc) == .SUCCESS);
    return @intCast(rc);
}

test "send writes the exact header and body, seq counts up" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();

    var buf: [64]u8 = undefined;
    const body = try structInt(&buf, 4);
    try std.testing.expectEqual(@as(u32, 0), try conn.send(5, 7, body, &.{}));
    try std.testing.expectEqual(@as(u32, 1), try conn.send(0, 1, body, &.{}));
    try std.testing.expectEqual(@as(u32, 2), try conn.send(9, 255, body, &.{}));
    try std.testing.expect(try conn.flush());

    var m = try fs.expect(5, 7);
    defer m.deinit(gpa);
    const want = [_]u8{
        5, 0, 0, 0, // id
        24, 0, 0, 7, // size, then opcode in the top byte
        0, 0, 0, 0, // seq
        0, 0, 0, 0, // n_fds
    };
    try std.testing.expectEqualSlices(u8, &want, &m.header);
    try std.testing.expectEqualSlices(u8, body, m.body);

    var m1 = try fs.expect(0, 1);
    defer m1.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), m1.seq);
    var m2 = try fs.expect(9, 255);
    defer m2.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), m2.seq);
    try std.testing.expectEqual(@as(u32, 24), m2.size);
}

test "two fds in one message refer to the same file" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();

    const mem = newMemfd();
    var buf: [64]u8 = undefined;
    const body = try structInt(&buf, 1);
    _ = try conn.send(3, 2, body, &.{ mem, mem });
    // The queue holds its own copies, so the caller can close right away.
    _ = linux.close(mem);
    try std.testing.expect(try conn.flush());

    var m = try fs.expect(3, 2);
    defer m.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), m.n_fds);
    try std.testing.expectEqual(@as(usize, 2), m.fds.len);
    try std.testing.expect(m.fds[0] != m.fds[1]);
    try std.testing.expectEqual(@as(usize, 2), linux.write(m.fds[0], "hi", 2));
    var got: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), linux.pread(m.fds[1], &got, 2, 0));
    try std.testing.expectEqualStrings("hi", &got);
}

test "more than 28 fds are split over several sendmsg calls" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();

    const mem = newMemfd();
    defer _ = linux.close(mem);
    var fds: [30]linux.fd_t = @splat(mem);
    var buf: [64]u8 = undefined;
    const body = try structInt(&buf, 1);
    _ = try conn.send(3, 2, body, &fds);
    _ = try conn.send(3, 3, body, &.{});
    try std.testing.expect(try conn.flush());

    var m = try fs.expect(3, 2);
    defer m.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 30), m.fds.len);
    var m2 = try fs.expect(3, 3);
    defer m2.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), m2.fds.len);
}

test "two messages in one write, then null" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();

    var buf: [64]u8 = undefined;
    const body1 = try structInt(&buf, 11);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    try fs.encode(&wire, 4, 9, body1, 0);
    var buf2: [64]u8 = undefined;
    const body2 = try structInt(&buf2, 22);
    try fs.encode(&wire, 6, 3, body2, 0);
    try fs.sendRaw(wire.items, &.{});

    const a = (try conn.receive()).?;
    try std.testing.expectEqual(@as(u32, 4), a.id);
    try std.testing.expectEqual(@as(u8, 9), a.opcode);
    try std.testing.expectEqual(@as(u32, 0), a.seq);
    try std.testing.expectEqualSlices(u8, body1, a.body);
    const b = (try conn.receive()).?;
    try std.testing.expectEqual(@as(u32, 6), b.id);
    try std.testing.expectEqual(@as(u8, 3), b.opcode);
    try std.testing.expectEqual(@as(u32, 1), b.seq);
    try std.testing.expectEqualSlices(u8, body2, b.body);
    try std.testing.expect((try conn.receive()) == null);
}

test "a message that arrives in two parts" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();

    var buf: [64]u8 = undefined;
    const body = try structInt(&buf, 77);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    try fs.encode(&wire, 4, 9, body, 0);
    try fs.sendRaw(wire.items[0..20], &.{});
    try std.testing.expect((try conn.receive()) == null);
    try fs.sendRaw(wire.items[20..], &.{});
    const m = (try conn.receive()).?;
    try std.testing.expectEqual(@as(u32, 4), m.id);
    try std.testing.expectEqualSlices(u8, body, m.body);
}

test "a header split inside the first bytes" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();

    var buf: [64]u8 = undefined;
    const body = try structInt(&buf, 77);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    try fs.encode(&wire, 4, 9, body, 0);
    try fs.sendRaw(wire.items[0..5], &.{});
    try std.testing.expect((try conn.receive()) == null);
    try fs.sendRaw(wire.items[5..], &.{});
    try std.testing.expect((try conn.receive()) != null);
}

test "a footer after the struct stays in the body and framing continues" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();

    var buf: [128]u8 = undefined;
    var b = pod.Builder.init(&buf);
    const s = try b.beginStruct();
    try b.string("hi");
    b.end(s);
    const body_len = b.bytesWritten().len;
    const footer = try b.beginStruct();
    try b.id(0);
    const inner = try b.beginStruct();
    try b.long(62);
    b.end(inner);
    b.end(footer);
    const whole = b.bytesWritten();
    try std.testing.expect(whole.len > body_len);

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    try fs.encode(&wire, 0, 0, whole, 0);
    var buf2: [64]u8 = undefined;
    const next = try structInt(&buf2, 5);
    try fs.encode(&wire, 1, 1, next, 0);
    try fs.sendRaw(wire.items, &.{});

    const m = (try conn.receive()).?;
    try std.testing.expectEqualSlices(u8, whole, m.body);
    const parsed = try pod.Pod.parse(m.body);
    try std.testing.expectEqual(@as(usize, whole.len - body_len), parsed.rest.len);
    const m2 = (try conn.receive()).?;
    try std.testing.expectEqual(@as(u32, 1), m2.id);
    try std.testing.expectEqualSlices(u8, next, m2.body);
}

test "receive gives Disconnected when the server closes" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();
    fs.deinit();
    try std.testing.expectError(error.Disconnected, conn.receive());
}

test "a message still in the buffer is returned before Disconnected" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();
    var buf: [64]u8 = undefined;
    const body = try structInt(&buf, 1);
    try fs.send(2, 2, body, &.{});
    fs.deinit();
    try std.testing.expect((try conn.receive()) != null);
    try std.testing.expectError(error.Disconnected, conn.receive());
}

test "an fd that is not taken closes on the next receive" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();

    const mem = newMemfd();
    defer _ = linux.close(mem);
    var buf: [64]u8 = undefined;
    const body = try structInt(&buf, 1);
    try fs.send(2, 4, body, &.{mem});
    try fs.send(2, 5, body, &.{});

    const m = (try conn.receive()).?;
    try std.testing.expectEqual(@as(usize, 1), m.fds.len);
    const held = m.fds[0];
    try std.testing.expect(fdIsOpen(held));
    _ = (try conn.receive()).?;
    try std.testing.expect(!fdIsOpen(held));
}

test "a taken fd stays open" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();

    const mem = newMemfd();
    defer _ = linux.close(mem);
    var buf: [64]u8 = undefined;
    const body = try structInt(&buf, 1);
    try fs.send(2, 4, body, &.{mem});
    try fs.send(2, 5, body, &.{});

    const m = (try conn.receive()).?;
    const taken = try conn.takeFd(m, 0);
    defer _ = linux.close(taken);
    try std.testing.expectError(error.Protocol, conn.takeFd(m, 0));
    try std.testing.expectError(error.Protocol, conn.takeFd(m, 1));
    _ = (try conn.receive()).?;
    try std.testing.expect(fdIsOpen(taken));
}

test "a message waits for its fds" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();

    const mem = newMemfd();
    defer _ = linux.close(mem);
    var buf: [64]u8 = undefined;
    const body = try structInt(&buf, 1);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    try fs.encode(&wire, 2, 4, body, 1);
    try fs.sendRaw(wire.items[0 .. wire.items.len - 1], &.{});
    try fs.sendRaw(wire.items[wire.items.len - 1 ..], &.{mem});
    const m = (try conn.receive()).?;
    try std.testing.expectEqual(@as(usize, 1), m.fds.len);
}

test "unfinished messages leave nothing behind on deinit" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    const mem = newMemfd();
    defer _ = linux.close(mem);
    var buf: [64]u8 = undefined;
    const body = try structInt(&buf, 1);
    _ = try conn.send(1, 1, body, &.{mem});
    const queued = conn.out_fds.items[0].fd;
    try fs.send(2, 4, body, &.{mem});
    const m = (try conn.receive()).?;
    const received = m.fds[0];
    const sock = conn.sock;
    try std.testing.expect(fdIsOpen(queued));
    try std.testing.expect(fdIsOpen(received));
    try std.testing.expect(fdIsOpen(sock));
    conn.deinit();
    try std.testing.expect(!fdIsOpen(queued));
    try std.testing.expect(!fdIsOpen(received));
    try std.testing.expect(!fdIsOpen(sock));
}

test "a body larger than 0xFFFFFF is refused" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();
    const big = try gpa.alloc(u8, 0x1000000);
    defer gpa.free(big);
    try std.testing.expectError(error.MessageTooLarge, conn.send(0, 1, big, &.{}));
}

test "a body of exactly 0xFFFFFF bytes is queued" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();
    const big = try gpa.alloc(u8, 0xFFFFFF);
    defer gpa.free(big);
    try std.testing.expectEqual(@as(u32, 0), try conn.send(0, 1, big, &.{}));
    try std.testing.expectEqual(@as(usize, 16 + 0xFFFFFF), conn.out.items.len);
}

test "truncated control data breaks the connection" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();

    const mem = newMemfd();
    defer _ = linux.close(mem);
    // 30 fds in one sendmsg do not fit in the 28 fd control buffer of the reader.
    const n = 30;
    const hdr_len = comptime std.mem.alignForward(usize, @sizeOf(linux.cmsghdr), @sizeOf(usize));
    var control: [hdr_len + n * 4 + 8]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
    const hdr: *linux.cmsghdr = @ptrCast(&control);
    hdr.* = .{ .len = hdr_len + n * 4, .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
    const fds: [n]linux.fd_t = @splat(mem);
    @memcpy(control[hdr_len..][0 .. n * 4], std.mem.sliceAsBytes(&fds));
    var iov = [1]std.posix.iovec_const{.{ .base = "x", .len = 1 }};
    var msg: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = std.mem.alignForward(usize, hdr_len + n * 4, @sizeOf(usize)),
        .flags = 0,
    };
    try std.testing.expectEqual(@as(usize, 1), linux.sendmsg(fs.server_fd, &msg, 0));

    try std.testing.expectError(error.Protocol, conn.receive());
    try std.testing.expectEqual(@as(usize, 0), conn.in_fds.items.len);
    try std.testing.expectError(error.Protocol, conn.receive());
    try std.testing.expectError(error.Protocol, conn.flush());
}

test "compaction keeps a partial message after a complete one" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();

    var buf: [64]u8 = undefined;
    const body1 = try structInt(&buf, 1);
    var buf2: [64]u8 = undefined;
    const body2 = try structInt(&buf2, 2);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    try fs.encode(&wire, 1, 1, body1, 0);
    const first_len = wire.items.len;
    try fs.encode(&wire, 2, 2, body2, 0);
    try fs.sendRaw(wire.items[0 .. first_len + 10], &.{});

    const a = (try conn.receive()).?;
    try std.testing.expectEqualSlices(u8, body1, a.body);
    try std.testing.expect((try conn.receive()) == null);
    try std.testing.expectEqual(@as(usize, 0), conn.in_start);
    try std.testing.expectEqual(@as(usize, 10), conn.in_len);
    try fs.sendRaw(wire.items[first_len + 10 ..], &.{});
    const b = (try conn.receive()).?;
    try std.testing.expectEqual(@as(u32, 2), b.id);
    try std.testing.expectEqualSlices(u8, body2, b.body);
}

test "a body larger than the first buffer arrives intact" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();

    const body = try gpa.alloc(u8, 40000);
    defer gpa.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 7);
    var small: [64]u8 = undefined;
    const next_body = try structInt(&small, 3);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    try fs.encode(&wire, 8, 3, body, 0);
    try fs.encode(&wire, 9, 4, next_body, 0);

    // Send in pieces so the reader grows its buffer while data arrives.
    var off: usize = 0;
    while (off + 10000 < 16 + body.len) : (off += 10000) {
        try fs.sendRaw(wire.items[off..][0..10000], &.{});
        try std.testing.expect((try conn.receive()) == null);
    }
    try fs.sendRaw(wire.items[off..], &.{});
    const m = (try conn.receive()).?;
    try std.testing.expectEqual(@as(u32, 8), m.id);
    try std.testing.expectEqualSlices(u8, body, m.body);
    try std.testing.expect(conn.in.len > 32768);
    const next = (try conn.receive()).?;
    try std.testing.expectEqual(@as(u32, 9), next.id);
    try std.testing.expectEqualSlices(u8, next_body, next.body);
}

test "a header with too many fds is a protocol error" {
    const gpa = std.testing.allocator;
    var fs = try FakeServer.init(gpa);
    defer fs.deinit();
    var conn = Connection.fromFd(gpa, fs.client_fd);
    defer conn.deinit();
    var hdr: [16]u8 = @splat(0);
    std.mem.writeInt(u32, hdr[12..16], 5000, builtin.cpu.arch.endian());
    try fs.sendRaw(&hdr, &.{});
    try std.testing.expectError(error.Protocol, conn.receive());
}

test "connect to a missing socket" {
    try std.testing.expectError(error.FileNotFound, Connection.connect(std.testing.allocator, "/nonexistent/chorus-test-socket"));
}
