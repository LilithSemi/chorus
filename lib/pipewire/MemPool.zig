//! The memory blocks the server shares with the client, keyed by the id the server chose.
const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const shm = @import("shm.zig");

const MemPool = @This();

pub const Error = error{OutOfMemory};

pub const MapError = error{ UnknownMem, OutOfRange, MapFailed, Overflow };

const min_align = std.heap.page_size_min;
const flag_unmappable = 1 << 6;

pub const Entry = struct {
    type: u32,
    fd: linux.fd_t,
    flags: u32,
};

/// A mapped window. `ptr` points at the requested offset. `base` and `base_len` are what mmap returned.
pub const Mapping = struct {
    ptr: [*]u8,
    len: usize,
    base: [*]align(min_align) u8,
    base_len: usize,

    pub fn unmap(self: Mapping) void {
        _ = linux.munmap(self.base, self.base_len);
    }
};

gpa: std.mem.Allocator,
entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,

pub fn init(gpa: std.mem.Allocator) MemPool {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *MemPool) void {
    var it = self.entries.valueIterator();
    while (it.next()) |e| _ = linux.close(e.fd);
    self.entries.deinit(self.gpa);
    self.* = undefined;
}

/// Takes ownership of `fd`. It is closed when this call fails. An entry with the same id is replaced and its fd is closed.
pub fn add(self: *MemPool, id: u32, ty: u32, fd: linux.fd_t, flags: u32) Error!void {
    errdefer _ = linux.close(fd);
    const old = try self.entries.fetchPut(self.gpa, id, .{ .type = ty, .fd = fd, .flags = flags });
    if (old) |kv| _ = linux.close(kv.value.fd);
}

/// Closes the fd of the entry. An unknown id does nothing.
pub fn remove(self: *MemPool, id: u32) void {
    const kv = self.entries.fetchRemove(id) orelse return;
    _ = linux.close(kv.value.fd);
}

pub fn get(self: *const MemPool, id: u32) ?Entry {
    return self.entries.get(id);
}

/// Maps `size` bytes at `offset` of the block `id`. The caller unmaps the result.
pub fn map(self: *MemPool, id: u32, offset: u32, size: u32, writable: bool) MapError!Mapping {
    const entry = self.get(id) orelse return error.UnknownMem;
    if (entry.flags & flag_unmappable != 0) return error.MapFailed;
    const end = std.math.add(u32, offset, size) catch return error.Overflow;

    var st: linux.Statx = undefined;
    const stat_rc = linux.statx(entry.fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &st);
    if (linux.errno(stat_rc) != .SUCCESS) return error.MapFailed;
    if (end > st.size) return error.OutOfRange;

    const start = std.mem.alignBackward(usize, @as(usize, offset), std.heap.pageSize());
    const total = std.mem.alignForward(usize, @as(usize, end), std.heap.pageSize()) - start;
    const prot: linux.PROT = .{ .READ = true, .WRITE = writable };
    const rc = linux.mmap(null, total, prot, .{ .TYPE = .SHARED }, entry.fd, @intCast(start));
    if (linux.errno(rc) != .SUCCESS) return error.MapFailed;

    const base: [*]align(min_align) u8 = @ptrFromInt(rc);
    return .{
        .ptr = base + (@as(usize, offset) - start),
        .len = size,
        .base = base,
        .base_len = total,
    };
}

/// Maps one `T` at `offset` of the block `id`. The pointer is `align(1)` because the offset may be
/// any byte. The caller checks that the size of the area in the event is at least `@sizeOf(T)`.
pub fn mapAs(self: *MemPool, comptime T: type, id: u32, offset: u32) MapError!struct { ptr: *align(1) T, mapping: Mapping } {
    const m = try self.map(id, offset, @sizeOf(T), true);
    return .{ .ptr = @ptrCast(m.ptr), .mapping = m };
}

fn testMemfd(size: usize) !linux.fd_t {
    const rc = linux.memfd_create("chorus-test", 0);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    const fd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(fd, @intCast(size))));
    return fd;
}

test "map gives a writable window at an unaligned offset" {
    const fd = try testMemfd(3 * std.heap.pageSize());
    var pool = MemPool.init(testing.allocator);
    defer pool.deinit();
    try pool.add(7, 0, fd, 3);

    const m = try pool.map(7, 5000, 100, true);
    defer m.unmap();
    @memset(m.ptr[0..100], 0xAB);

    var buf: [100]u8 = undefined;
    const want: [100]u8 = @splat(0xAB);
    try testing.expectEqual(@as(usize, 100), linux.pread(fd, &buf, buf.len, 5000));
    try testing.expectEqualSlices(u8, &want, &buf);
}

test "map past the end of the block gives OutOfRange" {
    const fd = try testMemfd(3 * std.heap.pageSize());
    var pool = MemPool.init(testing.allocator);
    defer pool.deinit();
    try pool.add(7, 0, fd, 3);

    try testing.expectError(error.OutOfRange, pool.map(7, @intCast(3 * std.heap.pageSize() - 50), 100, false));
}

test "map with offset plus size above u32 gives Overflow" {
    const fd = try testMemfd(std.heap.pageSize());
    var pool = MemPool.init(testing.allocator);
    defer pool.deinit();
    try pool.add(7, 0, fd, 3);

    try testing.expectError(error.Overflow, pool.map(7, 0xFFFF_FFF0, 0x20, false));
}

test "map of an unmappable block gives MapFailed" {
    const fd = try testMemfd(std.heap.pageSize());
    var pool = MemPool.init(testing.allocator);
    defer pool.deinit();
    try pool.add(7, 0, fd, flag_unmappable);

    try testing.expectError(error.MapFailed, pool.map(7, 0, 16, false));
}

test "mapAs reads server_version of a NodeActivation" {
    const fd = try testMemfd(@sizeOf(shm.NodeActivation));
    var pool = MemPool.init(testing.allocator);
    defer pool.deinit();
    try pool.add(3, 0, fd, 3);

    const version = std.mem.toBytes(@as(u32, 1));
    try testing.expectEqual(@as(usize, 4), linux.pwrite(fd, &version, version.len, 544));

    const got = try pool.mapAs(shm.NodeActivation, 3, 0);
    defer got.mapping.unmap();
    try testing.expectEqual(@as(u32, 1), got.ptr.server_version);
}

test "map of an unknown id gives UnknownMem" {
    var pool = MemPool.init(testing.allocator);
    defer pool.deinit();

    try testing.expectError(error.UnknownMem, pool.map(99, 0, 16, false));
}
