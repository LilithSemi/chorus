//! Tests through the Chorus API against the CoreAudio service of a Mac. They play silence only,
//! never capture, and never change a device, a volume or a mute. A playback test skips when no
//! callback arrives in 2 s, as in an ssh session with no console login.
const std = @import("std");
const Format = @import("../../Format.zig");
const Mixer = @import("../../Mixer.zig");
const Stream = @import("../../Stream.zig");
const Context = @import("../../Context.zig");
const Backend = @import("../Backend.zig");

const gpa = std.testing.allocator;
const stereo: Format = .{ .sample = .f32, .rate = 48000, .channels = .stereo };

const Silence = struct {
    /// Frames to play before the callback asks for a drain.
    limit: u64,
    written: std.atomic.Value(u64) = .init(0),
    calls: std.atomic.Value(u32) = .init(0),

    fn callback(self: *Silence) Stream.Callback {
        return .{ .ctx = self, .func = run };
    }

    fn run(ctx: ?*anyopaque, stream: *Stream, buffer: Stream.Buffer) Stream.Status {
        _ = stream;
        const self: *Silence = @ptrCast(@alignCast(ctx.?));
        @memset(buffer.bytes, 0);
        _ = self.calls.fetchAdd(1, .monotonic);
        const total = self.written.fetchAdd(buffer.frames, .monotonic) + buffer.frames;
        return if (total >= self.limit) .drain else .@"continue";
    }
};

fn nowMs() i64 {
    return std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds();
}

fn openContext() !*Context {
    return Context.init(gpa, std.testing.io, .{ .app_name = "chorus-live-test", .backend = .coreaudio }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
}

/// Dispatches until `done` is true or `timeout_ms` has passed. It gives the result of `done`.
fn pump(ctx: *Context, timeout_ms: i64, done: *const fn (*Context, *Stream, *Silence) bool, stream: *Stream, silence: *Silence) !bool {
    const deadline = nowMs() + timeout_ms;
    while (true) {
        _ = try ctx.dispatch();
        if (done(ctx, stream, silence)) return true;
        if (nowMs() >= deadline) return false;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
}

fn hasCallback(_: *Context, _: *Stream, silence: *Silence) bool {
    return silence.calls.load(.monotonic) > 0;
}

fn isStopped(_: *Context, stream: *Stream, _: *Silence) bool {
    return stream.state() == .stopped;
}

test "the default output plays silence and drains to stopped" {
    if (!Backend.coreaudio_enabled) return error.SkipZigTest;
    const ctx = try openContext();
    defer ctx.deinit();
    var silence: Silence = .{ .limit = stereo.rate / 4 };
    const stream = ctx.openStream(.{
        .direction = .playback,
        .format = stereo,
        .role = .media,
        .callback = silence.callback(),
    }) catch |err| switch (err) {
        error.Disconnected, error.UnknownDevice => return error.SkipZigTest,
        else => return err,
    };
    defer stream.close();
    const native = stream.nativeFormat();
    try std.testing.expect(native.rate >= 8000 and native.rate <= 384000);
    try stream.start();
    if (!try pump(ctx, 2000, hasCallback, stream, &silence)) {
        stream.stop();
        return error.SkipZigTest;
    }
    try std.testing.expect(try pump(ctx, 5000, isStopped, stream, &silence));
    try std.testing.expect(silence.written.load(.monotonic) >= silence.limit);
    try std.testing.expect(stream.stats().frames > 0);
}

test "the Mixer lists the default output without any change" {
    if (!Backend.coreaudio_enabled) return error.SkipZigTest;
    const ctx = try openContext();
    defer ctx.deinit();
    const mixer = ctx.mixer();
    const sink_id = mixer.default(.sink) orelse return error.SkipZigTest;
    const sink = mixer.endpoint(sink_id).?;
    try std.testing.expectEqual(Mixer.Kind.sink, sink.kind);
    try std.testing.expect(sink.name.len > 0);
    try std.testing.expect(sink.description.len > 0);
    for (sink.volume.slice()) |value| try std.testing.expect(value >= 0 and value <= Mixer.max_volume);
    if (mixer.default(.source)) |source_id| {
        try std.testing.expectEqual(Mixer.Kind.source, mixer.endpoint(source_id).?.kind);
    }
}

test "auto picks the CoreAudio backend" {
    if (!Backend.coreaudio_enabled) return error.SkipZigTest;
    const ctx = Context.init(gpa, std.testing.io, .{ .app_name = "chorus-live-test" }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer ctx.deinit();
    try std.testing.expectEqual(Backend.Kind.coreaudio, ctx.info().backend);
}
