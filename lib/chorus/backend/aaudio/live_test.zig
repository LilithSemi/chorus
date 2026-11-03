//! Tests through the Chorus API against the AAudio service of a device. They run from `adb shell`
//! and have no JavaVM, so the Mixer has the default endpoints only. Each test skips when the
//! service or the device is missing.
const std = @import("std");
const linux = std.os.linux;
const Format = @import("../../Format.zig");
const Stream = @import("../../Stream.zig");
const Context = @import("../../Context.zig");
const Backend = @import("../Backend.zig");

const gpa = std.testing.allocator;
const stereo: Format = .{ .sample = .f32, .rate = 48000, .channels = .stereo };

const Tone = struct {
    phase: f32 = 0,
    written: u64 = 0,
    /// Frames to play before the callback asks for a drain.
    limit: u64,
    heard: std.atomic.Value(u32) = .init(0),

    fn callback(self: *Tone) Stream.Callback {
        return .{ .ctx = self, .func = run };
    }

    fn run(ctx: ?*anyopaque, stream: *Stream, buffer: Stream.Buffer) Stream.Status {
        const self: *Tone = @ptrCast(@alignCast(ctx.?));
        if (stream.options.direction == .capture) {
            _ = self.heard.fetchAdd(buffer.frames, .monotonic);
            return .@"continue";
        }
        const step = 2.0 * std.math.pi * 440.0 / @as(f32, @floatFromInt(buffer.format.rate));
        const count = buffer.format.channels.count;
        var frame: usize = 0;
        while (frame < buffer.frames) : (frame += 1) {
            const value = 0.25 * @sin(self.phase);
            self.phase = @mod(self.phase + step, 2.0 * std.math.pi);
            for (0..count) |channel| put(buffer, frame * count + channel, value);
        }
        self.written += buffer.frames;
        return if (self.written >= self.limit) .drain else .@"continue";
    }

    fn put(buffer: Stream.Buffer, index: usize, value: f32) void {
        switch (buffer.format.sample) {
            .f32 => std.mem.bytesAsSlice(f32, buffer.bytes)[index] = value,
            .s16 => std.mem.bytesAsSlice(i16, buffer.bytes)[index] = @intFromFloat(value * 32767.0),
            .s32 => std.mem.bytesAsSlice(i32, buffer.bytes)[index] = @intFromFloat(value * 2147483647.0),
            .s24 => {
                const sample: u32 = @bitCast(@as(i32, @intFromFloat(value * 8388607.0)));
                buffer.bytes[index * 3 ..][0..3].* = .{ @truncate(sample), @truncate(sample >> 8), @truncate(sample >> 16) };
            },
            .u8, .f64 => unreachable,
        }
    }
};

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn openContext() !*Context {
    return Context.init(gpa, std.testing.io, .{ .app_name = "chorus-live-test", .backend = .aaudio }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
}

/// Playback skips when there is no audio service. Capture fails, because adb shell holds
/// RECORD_AUDIO and a denied microphone also gives Disconnected without a JavaVM.
fn openStream(ctx: *Context, options: Stream.Options) !*Stream {
    return ctx.openStream(options) catch |err| {
        std.log.warn("{t} open failed with {t}", .{ options.direction, err });
        if (options.direction == .playback and err == error.Disconnected) return error.SkipZigTest;
        if (options.direction == .capture and err == error.Disconnected) {
            std.log.warn("check the audio service and the RECORD_AUDIO permission of the shell", .{});
        }
        return err;
    };
}

/// Dispatches for up to 5 s. It waits for the stopped state, or for `wanted` frames when given.
fn pump(ctx: *Context, stream: *Stream, wanted: ?u64) !bool {
    const deadline = nowMs() + 5000;
    while (true) {
        _ = try ctx.dispatch();
        const done = if (wanted) |frames| stream.stats().frames >= frames else stream.state() == .stopped;
        if (done) return true;
        if (nowMs() >= deadline) return false;
        var pfd = [1]linux.pollfd{.{ .fd = ctx.fd() orelse -1, .events = linux.POLL.IN, .revents = 0 }};
        _ = linux.poll(&pfd, 1, 5);
    }
}

fn playOnce(sample: Format.Sample) !void {
    const ctx = try openContext();
    defer ctx.deinit();
    const format: Format = .{ .sample = sample, .rate = stereo.rate, .channels = stereo.channels };
    var tone: Tone = .{ .limit = stereo.rate / 2 };
    const stream = try openStream(ctx, .{
        .direction = .playback,
        .format = format,
        .role = .media,
        .callback = tone.callback(),
    });
    defer stream.close();
    try std.testing.expectEqual(stereo.rate, stream.format().rate);
    const native = stream.nativeFormat();
    try std.testing.expect(native.rate >= 8000 and native.rate <= 384000);
    try std.testing.expect(native.sample == .f32 or native.sample == .s16);
    try stream.start();
    try std.testing.expect(try pump(ctx, stream, null));
    try std.testing.expect(tone.written >= tone.limit);
    try std.testing.expect(stream.stats().frames >= @as(u64, native.rate) * 4 / 10);
}

test "a media stream plays a tone and drains to stopped" {
    if (!Backend.aaudio_enabled) return error.SkipZigTest;
    try playOnce(.f32);
}

test "every sample format that the backend maps opens and plays" {
    if (!Backend.aaudio_enabled) return error.SkipZigTest;
    for ([_]Format.Sample{ .s16, .f32, .s24, .s32 }) |sample| try playOnce(sample);
}

test "a capture stream gets frames from the microphone" {
    if (!Backend.aaudio_enabled) return error.SkipZigTest;
    const ctx = try openContext();
    defer ctx.deinit();
    var tone: Tone = .{ .limit = 0 };
    const stream = try openStream(ctx, .{
        .direction = .capture,
        .format = stereo,
        .callback = tone.callback(),
    });
    defer stream.close();
    const native = stream.nativeFormat();
    try std.testing.expect(native.rate >= 8000 and native.rate <= 384000);
    try std.testing.expect(native.sample == .f32 or native.sample == .s16);
    try stream.start();
    const reached = try pump(ctx, stream, @as(u64, native.rate) * 3 / 10);
    stream.stop();
    try std.testing.expect(reached);
    try std.testing.expect(tone.heard.load(.monotonic) > 0);
}

test "auto picks the AAudio backend" {
    if (!Backend.aaudio_enabled) return error.SkipZigTest;
    const ctx = try Context.init(gpa, std.testing.io, .{ .app_name = "chorus-live-test" });
    defer ctx.deinit();
    try std.testing.expectEqual(Backend.Kind.aaudio, ctx.info().backend);
}
