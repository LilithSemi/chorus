//! Converts between the format of a user and the native format of a device.
const std = @import("std");
const Format = @import("Format.zig");
const dsp = @import("dsp.zig");
const Pipeline = @This();

pub const Direction = enum { playback, capture };
pub const Status = enum { @"continue", drain, stop };

pub const Options = struct {
    direction: Direction,
    user: Format,
    native: Format,
    /// Largest native buffer in frames that pull or push gets.
    max_frames: u32,
    quality: dsp.resample.Quality = .good,
};

/// The user side. Fills (playback) or reads (capture) `frames` frames of `bytes` in the user format.
pub const User = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, bytes: []u8, frames: u32) Status,
};

const dither_seed = 0x63686f7275732121;

options: Options,
max_user_frames: u32,
remap: dsp.remap.Remap,
resampler: ?dsp.resample.Resampler,
dither: dsp.convert.Dither,
user_bytes: []u8,
user_f32: []f32,
/// Playback: remapped user frames not yet resampled. Capture: native frames in user channels.
mid_f32: []f32,
native_f32: []f32,
pending_start: usize,
pending_len: usize,

pub fn init(gpa: std.mem.Allocator, options: Options) error{OutOfMemory}!Pipeline {
    std.debug.assert(options.max_frames > 0);
    const user = options.user;
    const native = options.native;
    const rate_scaled = (@as(u64, options.max_frames) * user.rate + native.rate - 1) / native.rate;
    const max_user_frames: u32 = @intCast(rate_scaled + 1);
    const uch: usize = user.channels.count;
    const nch: usize = native.channels.count;

    var resampler: ?dsp.resample.Resampler = null;
    if (user.rate != native.rate) {
        const playback = options.direction == .playback;
        resampler = try .init(gpa, .{
            .channels = if (playback) native.channels.count else user.channels.count,
            .in_rate = if (playback) user.rate else native.rate,
            .out_rate = if (playback) native.rate else user.rate,
            .quality = options.quality,
            .block_frames = max_user_frames,
        });
    }
    errdefer if (resampler) |*r| r.deinit(gpa);

    const user_bytes = try gpa.alloc(u8, max_user_frames * user.frameBytes());
    errdefer gpa.free(user_bytes);
    const user_f32 = try gpa.alloc(f32, max_user_frames * uch);
    errdefer gpa.free(user_f32);
    const mid_len = switch (options.direction) {
        .playback => max_user_frames * nch,
        .capture => options.max_frames * uch,
    };
    const mid_f32 = try gpa.alloc(f32, mid_len);
    errdefer gpa.free(mid_f32);
    const native_f32 = try gpa.alloc(f32, options.max_frames * nch);
    errdefer gpa.free(native_f32);

    return .{
        .options = options,
        .max_user_frames = max_user_frames,
        .remap = switch (options.direction) {
            .playback => .init(user.channels, native.channels),
            .capture => .init(native.channels, user.channels),
        },
        .resampler = resampler,
        .dither = .init(dither_seed),
        .user_bytes = user_bytes,
        .user_f32 = user_f32,
        .mid_f32 = mid_f32,
        .native_f32 = native_f32,
        .pending_start = 0,
        .pending_len = 0,
    };
}

pub fn deinit(self: *Pipeline, gpa: std.mem.Allocator) void {
    if (self.resampler) |*r| r.deinit(gpa);
    gpa.free(self.user_bytes);
    gpa.free(self.user_f32);
    gpa.free(self.mid_f32);
    gpa.free(self.native_f32);
    self.* = undefined;
}

/// Drops pending playback input and resampler history, so old audio does not play after a restart.
pub fn reset(self: *Pipeline) void {
    self.pending_start = 0;
    self.pending_len = 0;
    if (self.resampler) |*r| r.reset();
}

/// True when user and native formats are equal. Then the user writes the native buffer directly.
pub fn passthrough(self: *const Pipeline) bool {
    return self.options.user.eql(self.options.native);
}

/// Playback. Fills `native` (whole native frames, at most max_frames). Returns the last user status.
pub fn pull(self: *Pipeline, user: User, native: []u8) Status {
    const native_fmt = self.options.native;
    const user_fmt = self.options.user;
    std.debug.assert(native.len % native_fmt.frameBytes() == 0);
    const total = native.len / native_fmt.frameBytes();
    std.debug.assert(total <= self.options.max_frames);

    if (self.passthrough()) {
        const status = user.func(user.ctx, native, @intCast(total));
        if (status == .stop) dsp.convert.silence(native_fmt.sample, native);
        return status;
    }

    const uch: usize = user_fmt.channels.count;
    const nch: usize = native_fmt.channels.count;
    var status: Status = .@"continue";
    var filled: usize = 0;
    while (filled < total) {
        if (self.pending_len == 0) {
            if (status != .@"continue") break;
            const frames = if (self.resampler == null) total - filled else self.max_user_frames;
            const bytes = self.user_bytes[0 .. frames * user_fmt.frameBytes()];
            status = user.func(user.ctx, bytes, @intCast(frames));
            if (status == .stop) break;
            const samples = self.user_f32[0 .. frames * uch];
            dsp.convert.toF32(user_fmt.sample, bytes, samples);
            if (self.resampler == null) {
                self.remap.process(samples, self.native_f32[filled * nch ..][0 .. frames * nch]);
                filled += frames;
                continue;
            }
            self.remap.process(samples, self.mid_f32[0 .. frames * nch]);
            self.pending_start = 0;
            self.pending_len = frames;
        }
        const resampler = &self.resampler.?;
        const in = self.mid_f32[self.pending_start * nch ..][0 .. self.pending_len * nch];
        const result = resampler.process(in, self.native_f32[filled * nch .. total * nch]);
        std.debug.assert(result.in_frames + result.out_frames > 0);
        self.pending_start += result.in_frames;
        self.pending_len -= result.in_frames;
        filled += result.out_frames;
    }

    if (status == .stop) {
        self.pending_len = 0;
        dsp.convert.silence(native_fmt.sample, native);
        return status;
    }
    @memset(self.native_f32[filled * nch .. total * nch], 0);
    dsp.convert.fromF32(native_fmt.sample, self.native_f32[0 .. total * nch], native, &self.dither);
    return status;
}

/// Capture. Sends `native` to the user in one or more calls. Returns the last user status.
/// Input left after a non-continue status is dropped.
pub fn push(self: *Pipeline, user: User, native: []const u8) Status {
    const native_fmt = self.options.native;
    const user_fmt = self.options.user;
    std.debug.assert(native.len % native_fmt.frameBytes() == 0);
    const total = native.len / native_fmt.frameBytes();
    std.debug.assert(total <= self.options.max_frames);
    if (self.passthrough()) {
        const bytes = self.user_bytes[0 .. total * native_fmt.frameBytes()];
        @memcpy(bytes, native);
        return user.func(user.ctx, bytes, @intCast(total));
    }

    const uch: usize = user_fmt.channels.count;
    const nch: usize = native_fmt.channels.count;

    const native_samples = self.native_f32[0 .. total * nch];
    dsp.convert.toF32(native_fmt.sample, native, native_samples);
    const mid = self.mid_f32[0 .. total * uch];
    self.remap.process(native_samples, mid);

    var status: Status = .@"continue";
    if (self.resampler) |*resampler| {
        var consumed: usize = 0;
        while (consumed < total and status == .@"continue") {
            const out = self.user_f32[0 .. self.max_user_frames * uch];
            const result = resampler.process(mid[consumed * uch ..], out);
            std.debug.assert(result.in_frames + result.out_frames > 0);
            consumed += result.in_frames;
            if (result.out_frames > 0) status = self.send(user, result.out_frames);
        }
    } else if (total > 0) {
        @memcpy(self.user_f32[0 .. total * uch], mid);
        status = self.send(user, total);
    }
    return status;
}

fn send(self: *Pipeline, user: User, frames: usize) Status {
    const user_fmt = self.options.user;
    const bytes = self.user_bytes[0 .. frames * user_fmt.frameBytes()];
    const samples = self.user_f32[0 .. frames * user_fmt.channels.count];
    dsp.convert.fromF32(user_fmt.sample, samples, bytes, &self.dither);
    return user.func(user.ctx, bytes, @intCast(frames));
}

const Recorder = struct {
    value: f32 = 0.5,
    frames: usize = 0,
    calls: usize = 0,
    status: Status = .@"continue",
    last: f32 = 0,

    fn user(self: *Recorder) User {
        return .{ .ctx = self, .func = fill };
    }

    fn fill(ctx: *anyopaque, bytes: []u8, frames: u32) Status {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        const out = std.mem.bytesAsSlice(f32, bytes);
        for (out) |*v| v.* = self.value;
        self.frames += frames;
        self.calls += 1;
        return self.status;
    }

    fn read(ctx: *anyopaque, bytes: []u8, frames: u32) Status {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        const in = std.mem.bytesAsSlice(f32, bytes);
        if (in.len > 0) self.last = in[in.len - 1];
        self.frames += frames;
        self.calls += 1;
        return self.status;
    }
};

const f32_stereo_48k: Format = .{ .sample = .f32, .rate = 48000, .channels = .stereo };

test "equal formats pass the native buffer straight to the user" {
    const gpa = std.testing.allocator;
    var p: Pipeline = try .init(gpa, .{ .direction = .playback, .user = f32_stereo_48k, .native = f32_stereo_48k, .max_frames = 4 });
    defer p.deinit(gpa);
    try std.testing.expect(p.passthrough());
    var rec: Recorder = .{};
    var native: [4 * 8]u8 = undefined;
    try std.testing.expectEqual(Status.@"continue", p.pull(rec.user(), &native));
    try std.testing.expectEqual(@as(usize, 4), rec.frames);
    try std.testing.expectEqual(@as(f32, 0.5), std.mem.bytesAsSlice(f32, &native)[7]);
}

test "f32 user audio becomes s16 native audio" {
    const gpa = std.testing.allocator;
    const native_fmt: Format = .{ .sample = .s16, .rate = 48000, .channels = .stereo };
    var p: Pipeline = try .init(gpa, .{ .direction = .playback, .user = f32_stereo_48k, .native = native_fmt, .max_frames = 8 });
    defer p.deinit(gpa);
    var rec: Recorder = .{};
    var native: [8 * 4]u8 = undefined;
    _ = p.pull(rec.user(), &native);
    // Playback output is dithered, so each sample may move by one step.
    for (0..16) |i| {
        const v = std.mem.readInt(i16, native[i * 2 ..][0..2], .little);
        try std.testing.expect(v >= 16383 and v <= 16385);
    }
}

test "mono user audio is copied to both native channels" {
    const gpa = std.testing.allocator;
    const user_fmt: Format = .{ .sample = .f32, .rate = 48000, .channels = .mono };
    var p: Pipeline = try .init(gpa, .{ .direction = .playback, .user = user_fmt, .native = f32_stereo_48k, .max_frames = 2 });
    defer p.deinit(gpa);
    var rec: Recorder = .{ .value = 0.25 };
    var native: [2 * 8]u8 align(4) = undefined;
    _ = p.pull(rec.user(), &native);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.25, 0.25, 0.25 }, std.mem.bytesAsSlice(f32, &native));
}

test "playback from 48 kHz to 44.1 kHz asks for about 48000 frames per second" {
    const gpa = std.testing.allocator;
    const native_fmt: Format = .{ .sample = .f32, .rate = 44100, .channels = .stereo };
    var p: Pipeline = try .init(gpa, .{ .direction = .playback, .user = f32_stereo_48k, .native = native_fmt, .max_frames = 441 });
    defer p.deinit(gpa);
    var rec: Recorder = .{};
    var native: [441 * 8]u8 = undefined;
    var frame: usize = 0;
    for (0..100) |_| {
        _ = p.pull(rec.user(), &native);
        const out = std.mem.bytesAsSlice(f32, &native);
        for (out, 0..) |v, i| {
            if (frame + i / 2 >= 64) try std.testing.expectApproxEqAbs(@as(f32, 0.5), v, 1e-3);
        }
        frame += 441;
    }
    try std.testing.expect(rec.frames >= 48000 and rec.frames <= 49000);
}

test "a stop status gives a silent buffer" {
    const gpa = std.testing.allocator;
    const native_fmt: Format = .{ .sample = .u8, .rate = 48000, .channels = .stereo };
    var p: Pipeline = try .init(gpa, .{ .direction = .playback, .user = f32_stereo_48k, .native = native_fmt, .max_frames = 4 });
    defer p.deinit(gpa);
    var rec: Recorder = .{ .status = .stop };
    var native: [8]u8 = undefined;
    try std.testing.expectEqual(Status.stop, p.pull(rec.user(), &native));
    try std.testing.expectEqualSlices(u8, &(@as([8]u8, @splat(0x80))), &native);
}

test "a drain status keeps the audio that the user wrote" {
    const gpa = std.testing.allocator;
    var p: Pipeline = try .init(gpa, .{ .direction = .playback, .user = f32_stereo_48k, .native = f32_stereo_48k, .max_frames = 2 });
    defer p.deinit(gpa);
    var rec: Recorder = .{ .status = .drain };
    var native: [2 * 8]u8 align(4) = undefined;
    try std.testing.expectEqual(Status.drain, p.pull(rec.user(), &native));
    try std.testing.expectEqual(@as(f32, 0.5), std.mem.bytesAsSlice(f32, &native)[3]);
}

test "capture from s16 stereo 44.1 kHz gives f32 mono 48 kHz" {
    const gpa = std.testing.allocator;
    const native_fmt: Format = .{ .sample = .s16, .rate = 44100, .channels = .stereo };
    const user_fmt: Format = .{ .sample = .f32, .rate = 48000, .channels = .mono };
    var p: Pipeline = try .init(gpa, .{ .direction = .capture, .user = user_fmt, .native = native_fmt, .max_frames = 441 });
    defer p.deinit(gpa);
    var native: [441 * 4]u8 = undefined;
    for (0..441 * 2) |i| std.mem.writeInt(i16, native[i * 2 ..][0..2], 16384, .little);
    var rec: Recorder = .{};
    const user: User = .{ .ctx = &rec, .func = Recorder.read };
    for (0..100) |_| _ = p.push(user, &native);
    try std.testing.expect(rec.frames >= 47900 and rec.frames <= 48000);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), rec.last, 1e-3);
}

test "equal capture formats reach the user bit for bit" {
    const gpa = std.testing.allocator;
    const fmt: Format = .{ .sample = .s16, .rate = 48000, .channels = .stereo };
    var p: Pipeline = try .init(gpa, .{ .direction = .capture, .user = fmt, .native = fmt, .max_frames = 4 });
    defer p.deinit(gpa);
    const Sink = struct {
        seen: [16]u8 = undefined,
        calls: usize = 0,

        fn read(ctx: *anyopaque, bytes: []u8, frames: u32) Status {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            std.debug.assert(bytes.len == frames * 4);
            @memcpy(self.seen[0..bytes.len], bytes);
            self.calls += 1;
            return .@"continue";
        }
    };
    const values = [_]i16{ 1, -1, 12345, -32768, 32767, 0, -2, 7 };
    var native: [16]u8 = undefined;
    for (values, 0..) |v, i| std.mem.writeInt(i16, native[i * 2 ..][0..2], v, .little);
    var sink: Sink = .{};
    const user: User = .{ .ctx = &sink, .func = Sink.read };
    try std.testing.expectEqual(Status.@"continue", p.push(user, &native));
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    try std.testing.expectEqualSlices(u8, &native, &sink.seen);
}

test "a stop through the resampler gives silence and clears pending audio" {
    const gpa = std.testing.allocator;
    const native_fmt: Format = .{ .sample = .f32, .rate = 44100, .channels = .stereo };
    var p: Pipeline = try .init(gpa, .{ .direction = .playback, .user = f32_stereo_48k, .native = native_fmt, .max_frames = 441 });
    defer p.deinit(gpa);
    var rec: Recorder = .{};
    var native: [441 * 8]u8 align(4) = undefined;
    try std.testing.expectEqual(Status.@"continue", p.pull(rec.user(), &native));
    rec.status = .stop;
    try std.testing.expectEqual(Status.stop, p.pull(rec.user(), &native));
    for (native) |b| try std.testing.expectEqual(@as(u8, 0), b);
    rec.status = .@"continue";
    try std.testing.expectEqual(Status.@"continue", p.pull(rec.user(), &native));
    const out = std.mem.bytesAsSlice(f32, &native);
    for (out[out.len - 200 ..]) |v| try std.testing.expectApproxEqAbs(@as(f32, 0.5), v, 1e-3);
}

test "drain through the resampler keeps rendered audio and stops asking the user" {
    const gpa = std.testing.allocator;
    const native_fmt: Format = .{ .sample = .f32, .rate = 44100, .channels = .stereo };
    var p: Pipeline = try .init(gpa, .{ .direction = .playback, .user = f32_stereo_48k, .native = native_fmt, .max_frames = 441 });
    defer p.deinit(gpa);
    var rec: Recorder = .{ .status = .drain };
    var native: [441 * 8]u8 align(4) = undefined;
    try std.testing.expectEqual(Status.drain, p.pull(rec.user(), &native));
    try std.testing.expectEqual(@as(usize, 1), rec.calls);
    const out = std.mem.bytesAsSlice(f32, &native);
    for (out[100 * 2 .. 300 * 2]) |v| try std.testing.expectApproxEqAbs(@as(f32, 0.5), v, 1e-3);
}

test "capture stops calling the user after a stop status" {
    const gpa = std.testing.allocator;
    const native_fmt: Format = .{ .sample = .s16, .rate = 44100, .channels = .stereo };
    const user_fmt: Format = .{ .sample = .f32, .rate = 48000, .channels = .mono };
    var p: Pipeline = try .init(gpa, .{ .direction = .capture, .user = user_fmt, .native = native_fmt, .max_frames = 441 });
    defer p.deinit(gpa);
    var native: [441 * 4]u8 = undefined;
    for (0..441 * 2) |i| std.mem.writeInt(i16, native[i * 2 ..][0..2], 16384, .little);
    var rec: Recorder = .{ .status = .stop };
    const user: User = .{ .ctx = &rec, .func = Recorder.read };
    try std.testing.expectEqual(Status.stop, p.push(user, &native));
    try std.testing.expectEqual(@as(usize, 1), rec.calls);
}
