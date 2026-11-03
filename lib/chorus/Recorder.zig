//! Records a capture stream through a `codec.Encoder` into a writer.
//!
//! The capture callback copies frames into a ring. The pump drains the ring into the encoder.
//! It runs in `Context.dispatch` on the app thread. Each pump encodes the frames that the ring
//! holds when the pump starts, so a slow encoder cannot keep `dispatch` busy. While the Recorder
//! records, `Context.timeoutMs` gives the time until the ring is half full. An app that waits on
//! `Context.fd` also waits for that time and then calls `dispatch`. A full ring drops the new
//! frames and counts an overrun. A write error stops the recording. `finish` returns it.
const std = @import("std");
const codec = @import("codec");
const Format = @import("Format.zig");
const Context = @import("Context.zig");
const Stream = @import("Stream.zig");
const Mixer = @import("Mixer.zig");
const Null = @import("backend/Null.zig");
const spsc = @import("spsc.zig");
const Recorder = @This();

context: *Context,
gpa: std.mem.Allocator,
options: Options,
capture: *Stream,
ring: spsc.FrameRing,
encoder: codec.Encoder,
/// Interleaved frames that go from the ring to the encoder.
scratch: []f32,
/// Written by the audio thread.
overruns: std.atomic.Value(u32) = .init(0),
frames_written: u64 = 0,
encoder_errors: u32 = 0,
failure: ?codec.WriteError = null,
finished: bool = false,

pub const Options = struct {
    /// The sample type must be f32.
    format: Format,
    /// A source, or a sink to record what it plays.
    device: ?Mixer.Id = null,
    latency_frames: u32 = 512,
    encode: codec.EncodeOptions,
    /// Audio that the ring can hold. The ring size is a power of two at least this big.
    buffer_ms: u32 = 500,
};

pub const Stats = struct {
    /// Frames that the encoder took.
    frames_written: u64,
    /// Capture blocks that lost frames because the ring was full. The count wraps at 2^32.
    overruns: u32,
    /// Overruns of the capture stream as the audio system reports them. See `Stream.Stats`.
    xruns: u64,
    /// 1 after a write error stopped the recording, else 0.
    encoder_errors: u32,
};

pub const InitError = Stream.OpenError || codec.EncoderInitError || error{ InvalidOptions, CapacityTooLarge };
pub const FinishError = codec.WriteError;

const chunk_frames = 1024;

/// The recording starts at `start`. `writer` must stay valid until `deinit`. A plain writer
/// cannot go back, so a WAV file keeps unknown sizes and a FLAC file has no total sample count.
/// Use `initFile` to record to a file.
pub fn init(ctx: *Context, writer: *std.Io.Writer, options: Options) InitError!*Recorder {
    return create(ctx, .{ .writer = writer }, options);
}

/// Like `init`, but `finish` goes back in `file` and writes the final sizes and the seek data.
/// `file` must stay valid until `deinit`.
pub fn initFile(ctx: *Context, file: *std.Io.File.Writer, options: Options) InitError!*Recorder {
    return create(ctx, .{ .file = file }, options);
}

const Sink = union(enum) {
    writer: *std.Io.Writer,
    file: *std.Io.File.Writer,
};

fn create(ctx: *Context, sink: Sink, options: Options) InitError!*Recorder {
    if (options.buffer_ms == 0) return error.InvalidOptions;
    if (options.format.sample != .f32) return error.UnsupportedFormat;
    try options.format.validate();
    const gpa = ctx.gpa;
    const channels: usize = options.format.channels.count;
    const ring_frames = @as(u64, options.format.rate) * options.buffer_ms / 1000;
    const ring_samples = std.math.cast(u32, ring_frames * channels) orelse return error.CapacityTooLarge;

    const self = try gpa.create(Recorder);
    errdefer gpa.destroy(self);
    var ring: spsc.FrameRing = try .init(gpa, @max(ring_samples, options.format.channels.count));
    errdefer ring.deinit(gpa);
    const scratch = try gpa.alloc(f32, chunk_frames * channels);
    errdefer gpa.free(scratch);
    const info: codec.Info = .{
        .rate = options.format.rate,
        .channels = options.format.channels.count,
    };
    var encoder: codec.Encoder = switch (sink) {
        .writer => |w| try .init(gpa, w, options.encode, info),
        .file => |f| try .initFile(gpa, f, options.encode, info),
    };
    errdefer encoder.deinit();
    self.* = .{
        .context = ctx,
        .gpa = gpa,
        .options = options,
        .capture = undefined,
        .ring = ring,
        .encoder = encoder,
        .scratch = scratch,
    };
    self.capture = try ctx.openStream(.{
        .direction = .capture,
        .format = options.format,
        .device = options.device,
        .latency_frames = options.latency_frames,
        .callback = .{ .ctx = self, .func = onCapture },
    });
    errdefer self.capture.close();
    try ctx.addPump(.{ .ctx = self, .func = pump, .timeout = timeoutHint });
    return self;
}

/// Call it before `Context.deinit`. It writes nothing more. Call `finish` first to get a valid file.
pub fn deinit(self: *Recorder) void {
    self.context.removePump(.{ .ctx = self, .func = pump, .timeout = timeoutHint });
    self.capture.close();
    self.encoder.deinit();
    self.gpa.free(self.scratch);
    self.ring.deinit(self.gpa);
    self.gpa.destroy(self);
}

/// Starts or resumes the capture. It does nothing after `finish` or after a write error.
/// `finish` gives that error.
pub fn start(self: *Recorder) Stream.StartError!void {
    if (self.finished or self.failure != null) return;
    try self.capture.start();
}

/// Stops the stream, drains the ring and finishes the stream of the encoder, which flushes the
/// writer. It gives the first write error of the recording, if any. A second call gives the same
/// result.
pub fn finish(self: *Recorder) FinishError!void {
    if (!self.finished) {
        self.finished = true;
        self.capture.stop();
        self.drain(std.math.maxInt(usize));
        if (self.failure == null) self.encoder.finish() catch |err| self.fail(err);
    }
    if (self.failure) |err| return err;
}

/// App thread only.
pub fn stats(self: *const Recorder) Stats {
    return .{
        .frames_written = self.frames_written,
        .overruns = self.overruns.load(.monotonic),
        .xruns = self.capture.stats().xruns,
        .encoder_errors = self.encoder_errors,
    };
}

fn fail(self: *Recorder, err: codec.WriteError) void {
    self.failure = err;
    self.encoder_errors +%= 1;
    if (!self.finished) self.capture.stop();
}

/// Encodes at most `limit` samples from the ring.
fn drain(self: *Recorder, limit: usize) void {
    if (self.failure != null) return;
    const channels: usize = self.options.format.channels.count;
    var left = limit;
    while (left > 0) {
        const n = self.ring.read(self.scratch[0..@min(self.scratch.len, left)]);
        if (n == 0) return;
        left -= n;
        std.debug.assert(n % channels == 0);
        self.encoder.write(self.scratch[0..n]) catch |err| return self.fail(err);
        self.frames_written += n / channels;
    }
}

fn pump(ptr: ?*anyopaque) void {
    const self: *Recorder = @ptrCast(@alignCast(ptr.?));
    if (self.finished) return;
    self.drain(self.ring.readAvailable());
}

fn timeoutHint(ptr: ?*anyopaque) ?u32 {
    const self: *const Recorder = @ptrCast(@alignCast(ptr.?));
    if (self.finished or self.failure != null or self.capture.state() != .running) return null;
    const channels: u64 = self.options.format.channels.count;
    const rate: u64 = self.options.format.rate;
    const half = rate * self.options.buffer_ms / 1000 / 2;
    const buffered = self.ring.readAvailable() / channels;
    if (buffered >= half) return 0;
    return @intCast(@min((half - buffered) * 1000 / rate, std.math.maxInt(u32)));
}

/// Audio thread. Writes whole frames only.
fn onCapture(ctx: ?*anyopaque, _: *Stream, buffer: Stream.Buffer) Stream.Status {
    const self: *Recorder = @ptrCast(@alignCast(ctx.?));
    const channels: usize = buffer.format.channels.count;
    const samples: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, buffer.bytes));
    const input = samples[0 .. buffer.frames * channels];
    const room = self.ring.writeAvailable() / channels * channels;
    if (input.len > room) _ = self.overruns.fetchAdd(1, .monotonic);
    _ = self.ring.write(input[0..@min(input.len, room)]);
    return .@"continue";
}

const testing = std.testing;

const Fixture = struct {
    ctx: *Context,
    recorder: *Recorder,
    aw: std.Io.Writer.Allocating,

    fn init(fx: *Fixture, null_options: Null.Options, options: Options) !void {
        fx.aw = .init(testing.allocator);
        errdefer fx.aw.deinit();
        fx.ctx = try Context.init(testing.allocator, testing.io, .{ .app_name = "test", .backend = .null, .null_backend = null_options });
        errdefer fx.ctx.deinit();
        fx.recorder = try Recorder.init(fx.ctx, &fx.aw.writer, options);
    }

    fn deinit(fx: *Fixture) void {
        fx.recorder.deinit();
        fx.ctx.deinit();
        fx.aw.deinit();
    }

    fn feed(fx: *Fixture, samples: []const f32) !void {
        try fx.ctx.backend.as(Null).?.feedInput(fx.recorder.capture, std.mem.sliceAsBytes(samples));
    }

    fn run(fx: *Fixture, n: usize) !void {
        for (0..n) |_| _ = try fx.ctx.dispatch();
    }
};

const stereo: Format = .{ .sample = .f32, .rate = 48000, .channels = .stereo };

fn sine(gpa: std.mem.Allocator, channels: usize, frames: usize) ![]f32 {
    const out = try gpa.alloc(f32, channels * frames);
    for (0..frames) |f| {
        for (0..channels) |c| {
            const t: f32 = @floatFromInt(f);
            out[f * channels + c] = 0.5 * @sin(t * 0.03 * @as(f32, @floatFromInt(c + 1)));
        }
    }
    return out;
}

/// Records `input` through the null backend, 256 frames for each dispatch.
fn record(fx: *Fixture, input: []const f32) !void {
    try fx.recorder.start();
    try fx.feed(input);
    try fx.run(input.len / 2 / 256 + 1);
    try fx.recorder.finish();
}

fn decodeAll(gpa: std.mem.Allocator, bytes: []const u8, expect_rate: u32) ![]f32 {
    var dec: codec.Decoder = try .init(gpa, .{ .bytes = bytes }, .auto);
    defer dec.deinit();
    try testing.expectEqual(expect_rate, dec.info().rate);
    try testing.expectEqual(@as(u8, 2), dec.info().channels);
    var out: std.ArrayList(f32) = .empty;
    errdefer out.deinit(gpa);
    var buf: [1024]f32 = undefined;
    while (true) {
        const n = try dec.read(&buf);
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0 .. n * 2]);
    }
    return out.toOwnedSlice(gpa);
}

fn snr(a: []const f32, b: []const f32) f64 {
    var signal: f64 = 0;
    var noise: f64 = 0;
    for (a, b) |x, y| {
        signal += @as(f64, x) * x;
        noise += (@as(f64, x) - y) * (x - y);
    }
    return signal / noise;
}

test "a WAV recording is bit exact to the fed frames" {
    var fx: Fixture = undefined;
    try fx.init(.{ .period_frames = 256 }, .{ .format = stereo, .encode = .{ .wav = .{ .sample = .f32 } } });
    defer fx.deinit();
    const input = try sine(testing.allocator, 2, 256 * 40);
    defer testing.allocator.free(input);
    try record(&fx, input);
    const got = try decodeAll(testing.allocator, fx.aw.written(), 48000);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(f32, input, got);
    try testing.expectEqual(@as(u64, 256 * 40), fx.recorder.stats().frames_written);
    try testing.expectEqual(@as(u32, 0), fx.recorder.stats().overruns);
}

test "a FLAC recording decodes bit exact" {
    var fx: Fixture = undefined;
    try fx.init(.{ .period_frames = 256 }, .{ .format = stereo, .encode = .{ .flac = .{ .level = 5, .bits = 16 } } });
    defer fx.deinit();
    const input = try testing.allocator.alloc(f32, 2 * 256 * 30);
    defer testing.allocator.free(input);
    for (input, 0..) |*s, i| {
        const v: i32 = @intCast((i * 37) % 20000);
        s.* = @as(f32, @floatFromInt(v - 10000)) / 32768.0;
    }
    try record(&fx, input);
    const got = try decodeAll(testing.allocator, fx.aw.written(), 48000);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(f32, input, got);
}

test "Vorbis and Opus recordings decode above an SNR floor" {
    const options = [_]codec.EncodeOptions{ .{ .ogg_vorbis = .{ .quality = 6 } }, .{ .ogg_opus = .{} } };
    for (options) |encode| {
        var fx: Fixture = undefined;
        try fx.init(.{ .period_frames = 256 }, .{ .format = stereo, .encode = encode });
        defer fx.deinit();
        const input = try sine(testing.allocator, 2, 256 * 60);
        defer testing.allocator.free(input);
        try record(&fx, input);
        const got = try decodeAll(testing.allocator, fx.aw.written(), 48000);
        defer testing.allocator.free(got);
        try testing.expectEqual(input.len, got.len);
        try testing.expect(snr(input, got) > 100);
    }
}

test "a stalled pump counts an overrun and keeps the first frames" {
    var fx: Fixture = undefined;
    // 10 ms at 48 kHz is 480 frames, so the ring holds 512 stereo frames.
    try fx.init(.{ .period_frames = 256 }, .{ .format = stereo, .buffer_ms = 10, .encode = .{ .wav = .{ .sample = .f32 } } });
    defer fx.deinit();
    const input = try sine(testing.allocator, 2, 2048);
    defer testing.allocator.free(input);
    try fx.recorder.start();
    fx.recorder.capture.capture(std.mem.sliceAsBytes(input));
    try testing.expectEqual(@as(u32, 6), fx.recorder.stats().overruns);
    try fx.recorder.finish();
    try testing.expectEqual(@as(u64, 512), fx.recorder.stats().frames_written);
    const got = try decodeAll(testing.allocator, fx.aw.written(), 48000);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(f32, input[0 .. 512 * 2], got);
}

test "a write error stops the recording and finish returns it" {
    var fx: Fixture = undefined;
    fx.aw = .init(testing.allocator);
    defer fx.aw.deinit();
    fx.ctx = try Context.init(testing.allocator, testing.io, .{ .app_name = "test", .backend = .null, .null_backend = .{ .period_frames = 256 } });
    defer fx.ctx.deinit();
    var small: [100]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&small);
    fx.recorder = try Recorder.init(fx.ctx, &writer, .{ .format = stereo, .encode = .{ .wav = .{ .sample = .f32 } } });
    defer fx.recorder.deinit();
    const input = try sine(testing.allocator, 2, 256 * 8);
    defer testing.allocator.free(input);
    try fx.recorder.start();
    try fx.feed(input);
    try fx.run(10);
    try testing.expectEqual(@as(u32, 1), fx.recorder.stats().encoder_errors);
    try testing.expectEqual(Stream.State.stopped, fx.recorder.capture.state());
    try testing.expectEqual(@as(?u32, null), fx.ctx.timeoutMs());
    try testing.expectError(error.WriteFailed, fx.recorder.finish());
    try testing.expectError(error.WriteFailed, fx.recorder.finish());
    try testing.expectEqual(@as(u32, 1), fx.recorder.stats().encoder_errors);
}

test "the timeout hint is the time until the ring is half full, only while recording" {
    var fx: Fixture = undefined;
    try fx.init(.{ .period_frames = 256 }, .{ .format = stereo, .buffer_ms = 400, .encode = .{ .wav = .{ .sample = .f32 } } });
    defer fx.deinit();
    try testing.expectEqual(@as(?u32, null), fx.ctx.timeoutMs());
    try fx.recorder.start();
    try testing.expectEqual(@as(?u32, 200), fx.ctx.timeoutMs());
    const input = try sine(testing.allocator, 2, 9600);
    defer testing.allocator.free(input);
    fx.recorder.capture.capture(std.mem.sliceAsBytes(input));
    try testing.expectEqual(@as(?u32, 0), fx.ctx.timeoutMs());
    _ = try fx.ctx.dispatch();
    try testing.expectEqual(@as(?u32, 200), fx.ctx.timeoutMs());
    try fx.recorder.finish();
    try testing.expectEqual(@as(?u32, null), fx.ctx.timeoutMs());
}

test "deinit without finish writes nothing more and leaks nothing" {
    var fx: Fixture = undefined;
    try fx.init(.{ .period_frames = 256 }, .{ .format = stereo, .encode = .{ .ogg_vorbis = .{} } });
    defer fx.aw.deinit();
    defer fx.ctx.deinit();
    const input = try sine(testing.allocator, 2, 256 * 8);
    defer testing.allocator.free(input);
    try fx.recorder.start();
    try fx.feed(input);
    try fx.run(9);
    const size = fx.aw.written().len;
    fx.recorder.deinit();
    try testing.expectEqual(size, fx.aw.written().len);
}

test "start after finish does nothing" {
    var fx: Fixture = undefined;
    try fx.init(.{ .period_frames = 256 }, .{ .format = stereo, .encode = .{ .wav = .{ .sample = .f32 } } });
    defer fx.deinit();
    try fx.recorder.finish();
    try fx.recorder.start();
    try testing.expectEqual(Stream.State.stopped, fx.recorder.capture.state());
    try testing.expectEqual(@as(u64, 0), fx.recorder.stats().frames_written);
    try testing.expectEqual(@as(u64, 0), fx.recorder.stats().xruns);
}

test "bad options are rejected" {
    const ctx = try Context.init(testing.allocator, testing.io, .{ .app_name = "test", .backend = .null });
    defer ctx.deinit();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const wav: codec.EncodeOptions = .{ .wav = .{} };
    try testing.expectError(error.InvalidOptions, Recorder.init(ctx, &aw.writer, .{ .format = stereo, .buffer_ms = 0, .encode = wav }));
    var s16 = stereo;
    s16.sample = .s16;
    try testing.expectError(error.UnsupportedFormat, Recorder.init(ctx, &aw.writer, .{ .format = s16, .encode = wav }));
    var bad_rate = stereo;
    bad_rate.rate = 5;
    try testing.expectError(error.UnsupportedFormat, Recorder.init(ctx, &aw.writer, .{ .format = bad_rate, .encode = wav }));
    try testing.expectError(error.Unsupported, Recorder.init(ctx, &aw.writer, .{ .format = stereo, .encode = .{ .flac = .{ .level = 12 } } }));
}

test "a file recording gets final sizes and seek data" {
    if (!codec.io.has_files) return error.SkipZigTest;
    const options = [_]codec.EncodeOptions{ .{ .wav = .{ .sample = .f32 } }, .{ .flac = .{ .level = 5, .bits = 16 } } };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const frames = 256 * 20;
    const input = try testing.allocator.alloc(f32, 2 * frames);
    defer testing.allocator.free(input);
    for (input, 0..) |*s, i| {
        const v: i32 = @intCast((i * 37) % 20000);
        s.* = @as(f32, @floatFromInt(v - 10000)) / 32768.0;
    }
    for (options, 0..) |encode, i| {
        const ctx = try Context.init(testing.allocator, testing.io, .{ .app_name = "test", .backend = .null, .null_backend = .{ .period_frames = 256 } });
        defer ctx.deinit();
        const name = if (i == 0) "rec.wav" else "rec.flac";
        {
            var file = try tmp.dir.createFile(testing.io, name, .{});
            defer file.close(testing.io);
            var wbuf: [64]u8 = undefined;
            var fw = file.writer(testing.io, &wbuf);
            const recorder = try Recorder.initFile(ctx, &fw, .{ .format = stereo, .encode = encode });
            defer recorder.deinit();
            try recorder.start();
            try ctx.backend.as(Null).?.feedInput(recorder.capture, std.mem.sliceAsBytes(input));
            for (0..frames / 256 + 1) |_| _ = try ctx.dispatch();
            try recorder.finish();
            try testing.expectEqual(@as(u64, frames), recorder.stats().frames_written);
        }
        const bytes = try tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .limited(1 << 22));
        defer testing.allocator.free(bytes);
        var dec: codec.Decoder = try .init(testing.allocator, .{ .bytes = bytes }, .auto);
        defer dec.deinit();
        try testing.expectEqual(@as(?u64, frames), dec.info().total_frames);
        try dec.seek(1000);
        var buf: [64]f32 = undefined;
        const n = try dec.read(&buf);
        try testing.expect(n > 0);
        try testing.expectEqualSlices(f32, input[2000 .. 2000 + n * 2], buf[0 .. n * 2]);
    }
}

test "one pump encodes at most the frames that were in the ring when it started" {
    var fx: Fixture = undefined;
    try fx.init(.{ .period_frames = 256 }, .{ .format = stereo, .encode = .{ .wav = .{ .sample = .f32 } } });
    defer fx.deinit();
    const input = try sine(testing.allocator, 2, chunk_frames * 3);
    defer testing.allocator.free(input);
    try fx.recorder.start();
    fx.recorder.capture.capture(std.mem.sliceAsBytes(input));
    fx.recorder.drain(chunk_frames * 2);
    try testing.expectEqual(@as(u64, chunk_frames), fx.recorder.stats().frames_written);
    _ = try fx.ctx.dispatch();
    try testing.expectEqual(@as(u64, chunk_frames * 3), fx.recorder.stats().frames_written);
}

test "a failed Encoder.finish is returned again and counted once" {
    var fx: Fixture = undefined;
    fx.aw = .init(testing.allocator);
    defer fx.aw.deinit();
    fx.ctx = try Context.init(testing.allocator, testing.io, .{ .app_name = "test", .backend = .null, .null_backend = .{ .period_frames = 256 } });
    defer fx.ctx.deinit();
    var small: [200]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&small);
    fx.recorder = try Recorder.init(fx.ctx, &writer, .{ .format = stereo, .encode = .{ .flac = .{ .level = 5, .bits = 16 } } });
    defer fx.recorder.deinit();
    const input = try testing.allocator.alloc(f32, 2 * 256);
    defer testing.allocator.free(input);
    for (input, 0..) |*s, i| s.* = @as(f32, @floatFromInt(@as(i32, @intCast((i * 7919) % 20000)) - 10000)) / 32768.0;
    try fx.recorder.start();
    try fx.feed(input);
    try fx.run(3);
    try testing.expectEqual(@as(u32, 0), fx.recorder.stats().encoder_errors);
    try testing.expectError(error.WriteFailed, fx.recorder.finish());
    try testing.expectError(error.WriteFailed, fx.recorder.finish());
    try testing.expectEqual(@as(u32, 1), fx.recorder.stats().encoder_errors);
}
