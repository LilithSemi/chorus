//! A lock free ring for one producer thread and one consumer thread.
//! Neither side allocates, locks or blocks. Only `init` and `deinit` allocate.
const std = @import("std");
const builtin = @import("builtin");

/// Commands and events use `Spsc(Command)`. Audio uses `FrameRing`, with one `f32` per sample.
pub fn Spsc(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        mask: u32,
        /// Free running index, written by the consumer only.
        read_index: std.atomic.Value(u32) align(64) = .init(0),
        /// Free running index, written by the producer only.
        write_index: std.atomic.Value(u32) align(64) = .init(0),

        pub const Slices = [2][]const T;
        pub const WriteSlices = [2][]T;
        pub const InitError = error{ OutOfMemory, CapacityTooLarge };

        /// The capacity is `min_capacity` rounded up to a power of two.
        pub fn init(gpa: std.mem.Allocator, min_capacity: u32) InitError!Self {
            if (min_capacity > 1 << 30) return error.CapacityTooLarge;
            const rounded = std.math.ceilPowerOfTwo(u32, @max(min_capacity, 1)) catch return error.CapacityTooLarge;
            return .{ .buffer = try gpa.alloc(T, rounded), .mask = rounded - 1 };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.buffer);
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) u32 {
            return self.mask + 1;
        }

        /// Producer side. Items that the producer can still write.
        pub fn writeAvailable(self: *const Self) u32 {
            const used = self.write_index.load(.monotonic) -% self.read_index.load(.acquire);
            return self.capacity() - used;
        }

        /// Consumer side. Items that the consumer can read.
        pub fn readAvailable(self: *const Self) u32 {
            return self.write_index.load(.acquire) -% self.read_index.load(.monotonic);
        }

        /// Producer side. Copies as many items as fit and returns that count.
        pub fn write(self: *Self, items: []const T) u32 {
            const n: u32 = @intCast(@min(items.len, self.writeAvailable()));
            const view = self.writeSlices();
            const first: usize = @min(n, view[0].len);
            @memcpy(view[0][0..first], items[0..first]);
            @memcpy(view[1][0 .. n - first], items[first..n]);
            self.commit(n);
            return n;
        }

        /// Producer side. Returns false when the ring is full.
        pub fn push(self: *Self, item: T) bool {
            if (self.writeAvailable() == 0) return false;
            const start = self.write_index.load(.monotonic);
            self.buffer[start & self.mask] = item;
            self.write_index.store(start +% 1, .release);
            return true;
        }

        /// Producer side. The free space as two slices, in order. The second slice is empty unless
        /// the space wraps. Fill them and call `commit`.
        pub fn writeSlices(self: *Self) WriteSlices {
            const n = self.writeAvailable();
            const start = self.write_index.load(.monotonic) & self.mask;
            const first = @min(n, self.capacity() - start);
            return .{ self.buffer[start..][0..first], self.buffer[0 .. n - first] };
        }

        /// Producer side. Publishes `n` items that the caller wrote into `writeSlices`.
        pub fn commit(self: *Self, n: u32) void {
            std.debug.assert(n <= self.writeAvailable());
            self.write_index.store(self.write_index.load(.monotonic) +% n, .release);
        }

        /// Consumer side. The readable items as two slices, in order. The second slice is empty
        /// unless the data wraps. The slices stay valid until `skip`.
        pub fn peek(self: *const Self) Slices {
            const n = self.readAvailable();
            const start = self.read_index.load(.monotonic) & self.mask;
            const first = @min(n, self.capacity() - start);
            return .{ self.buffer[start..][0..first], self.buffer[0 .. n - first] };
        }

        /// Consumer side. Releases `n` items that `peek` showed.
        pub fn skip(self: *Self, n: u32) void {
            std.debug.assert(n <= self.readAvailable());
            self.read_index.store(self.read_index.load(.monotonic) +% n, .release);
        }

        /// Consumer side. Copies up to `out.len` items and returns that count.
        pub fn read(self: *Self, out: []T) u32 {
            const n: u32 = @intCast(@min(out.len, self.readAvailable()));
            const view = self.peek();
            const first: usize = @min(n, view[0].len);
            @memcpy(out[0..first], view[0][0..first]);
            @memcpy(out[first..n], view[1][0 .. n - first]);
            self.skip(n);
            return n;
        }

        /// Consumer side. Returns null when the ring is empty.
        pub fn pop(self: *Self) ?T {
            if (self.readAvailable() == 0) return null;
            const start = self.read_index.load(.monotonic);
            const item = self.buffer[start & self.mask];
            self.read_index.store(start +% 1, .release);
            return item;
        }
    };
}

/// A ring of audio samples.
pub const FrameRing = Spsc(f32);

const testing = std.testing;

test "capacity rounds up to a power of two" {
    var ring: Spsc(u8) = try .init(testing.allocator, 5);
    defer ring.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 8), ring.capacity());
    try testing.expectEqual(@as(u32, 8), ring.writeAvailable());
    try testing.expectEqual(@as(u32, 0), ring.readAvailable());
}

test "full and empty" {
    var ring: Spsc(u32) = try .init(testing.allocator, 4);
    defer ring.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, null), ring.pop());
    for (0..4) |i| try testing.expect(ring.push(@intCast(i + 10)));
    try testing.expect(!ring.push(99));
    try testing.expectEqual(@as(u32, 0), ring.writeAvailable());
    try testing.expectEqual(@as(u32, 4), ring.readAvailable());
    try testing.expectEqual(@as(u32, 0), ring.write(&.{1}));
    for (0..4) |i| try testing.expectEqual(@as(?u32, @intCast(i + 10)), ring.pop());
    try testing.expectEqual(@as(?u32, null), ring.pop());
}

test "write and read wrap around with two slices" {
    var ring: Spsc(u8) = try .init(testing.allocator, 8);
    defer ring.deinit(testing.allocator);
    var scratch: [8]u8 = undefined;
    try testing.expectEqual(@as(u32, 6), ring.write(&.{ 0, 1, 2, 3, 4, 5 }));
    try testing.expectEqual(@as(u32, 6), ring.read(&scratch));
    try testing.expectEqual(@as(u32, 6), ring.write(&.{ 10, 11, 12, 13, 14, 15 }));
    const view = ring.peek();
    try testing.expectEqualSlices(u8, &.{ 10, 11 }, view[0]);
    try testing.expectEqualSlices(u8, &.{ 12, 13, 14, 15 }, view[1]);
    ring.skip(3);
    try testing.expectEqual(@as(u32, 3), ring.read(&scratch));
    try testing.expectEqualSlices(u8, &.{ 13, 14, 15 }, scratch[0..3]);
}

test "write slices fill across the wrap" {
    var ring: Spsc(u8) = try .init(testing.allocator, 8);
    defer ring.deinit(testing.allocator);
    var scratch: [8]u8 = undefined;
    try testing.expectEqual(@as(u32, 5), ring.write(&.{ 1, 2, 3, 4, 5 }));
    try testing.expectEqual(@as(u32, 5), ring.read(&scratch));
    const free = ring.writeSlices();
    try testing.expectEqual(@as(usize, 3), free[0].len);
    try testing.expectEqual(@as(usize, 5), free[1].len);
    @memset(free[0], 7);
    @memset(free[1][0..2], 8);
    ring.commit(5);
    try testing.expectEqual(@as(u32, 5), ring.readAvailable());
    try testing.expectEqual(@as(u32, 5), ring.read(&scratch));
    try testing.expectEqualSlices(u8, &.{ 7, 7, 7, 8, 8 }, scratch[0..5]);
}

test "indices wrap at the u32 limit" {
    var ring: Spsc(u16) = try .init(testing.allocator, 4);
    defer ring.deinit(testing.allocator);
    ring.read_index.store(std.math.maxInt(u32) - 1, .monotonic);
    ring.write_index.store(std.math.maxInt(u32) - 1, .monotonic);
    try testing.expectEqual(@as(u32, 4), ring.write(&.{ 1, 2, 3, 4 }));
    try testing.expectEqual(@as(u32, 4), ring.readAvailable());
    try testing.expectEqual(@as(?u16, 1), ring.pop());
    try testing.expectEqual(@as(?u16, 2), ring.pop());
    try testing.expectEqual(@as(?u16, 3), ring.pop());
    try testing.expectEqual(@as(?u16, 4), ring.pop());
    try testing.expectEqual(@as(u32, 4), ring.writeAvailable());
}

test "a producer thread and a consumer thread keep every item in order" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const total: u32 = 200_000;
    var ring: Spsc(u32) = try .init(testing.allocator, 64);
    defer ring.deinit(testing.allocator);
    const Producer = struct {
        fn run(r: *Spsc(u32)) void {
            var next: u32 = 0;
            var chunk: [7]u32 = undefined;
            while (next < total) {
                const want: u32 = @min(chunk.len, total - next);
                for (chunk[0..want], 0..) |*item, i| item.* = next + @as(u32, @intCast(i));
                const done = r.write(chunk[0..want]);
                next += done;
                if (done == 0) std.Thread.yield() catch continue;
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&ring});
    var expected: u32 = 0;
    var bad: u32 = 0;
    var out: [5]u32 = undefined;
    while (expected < total) {
        const n = ring.read(&out);
        if (n == 0) {
            std.Thread.yield() catch continue;
            continue;
        }
        for (out[0..n]) |item| {
            if (item != expected) bad += 1;
            expected += 1;
        }
    }
    thread.join();
    try testing.expectEqual(@as(u32, 0), bad);
    try testing.expectEqual(total, expected);
    try testing.expectEqual(@as(u32, 0), ring.readAvailable());
}

test "a producer and a consumer that use slices keep every item in order" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const total: u32 = 200_000;
    var ring: Spsc(u32) = try .init(testing.allocator, 64);
    defer ring.deinit(testing.allocator);
    const Producer = struct {
        fn run(r: *Spsc(u32)) void {
            var next: u32 = 0;
            while (next < total) {
                const free = r.writeSlices();
                var done: u32 = 0;
                for (free) |part| for (part) |*item| {
                    if (next + done >= total) break;
                    item.* = next + done;
                    done += 1;
                };
                r.commit(done);
                next += done;
                if (done == 0) std.Thread.yield() catch continue;
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&ring});
    var expected: u32 = 0;
    var bad: u32 = 0;
    while (expected < total) {
        const view = ring.peek();
        const n: u32 = @intCast(view[0].len + view[1].len);
        if (n == 0) {
            std.Thread.yield() catch continue;
            continue;
        }
        for (view) |part| for (part) |item| {
            if (item != expected) bad += 1;
            expected += 1;
        };
        ring.skip(n);
    }
    thread.join();
    try testing.expectEqual(@as(u32, 0), bad);
    try testing.expectEqual(total, expected);
}
