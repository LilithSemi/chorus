//! Encodes WAV, FLAC, Ogg FLAC, Ogg Vorbis and Ogg Opus from interleaved f32 behind one type.
const std = @import("std");
const codec = @import("../codec.zig");
const io = @import("io.zig");
const wav = @import("wav.zig");
const flac = @import("flac.zig");
const vorbis = @import("vorbis.zig");
const opus = @import("opus.zig");
const testing = std.testing;

const Encoder = @This();

impl: Impl,

const Impl = union(enum) {
    wav: wav.Encoder,
    flac: flac.Encoder,
    ogg_flac: flac.ogg.Encoder,
    ogg_vorbis: vorbis.Encoder,
    ogg_opus: opus.Encoder,
};

pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, options: codec.EncodeOptions, info: codec.Info) codec.EncoderInitError!Encoder {
    return .{ .impl = switch (options) {
        .wav => |o| .{ .wav = try .init(gpa, writer, .{ .sample = o.sample }, info) },
        .flac => |o| .{ .flac = try .init(gpa, writer, .{ .level = o.level, .bits = o.bits }, info) },
        .ogg_flac => |o| .{ .ogg_flac = try .init(gpa, writer, .{ .level = o.level, .bits = o.bits, .serial = o.serial }, info) },
        .ogg_vorbis => |o| .{ .ogg_vorbis = try .init(gpa, writer, o, info) },
        .ogg_opus => |o| .{ .ogg_opus = try .init(gpa, writer, o, info) },
    } };
}

pub fn initFile(gpa: std.mem.Allocator, file: *std.Io.File.Writer, options: codec.EncodeOptions, info: codec.Info) codec.EncoderInitError!Encoder {
    return .{ .impl = switch (options) {
        .wav => |o| .{ .wav = try .initFile(gpa, file, .{ .sample = o.sample }, info) },
        .flac => |o| .{ .flac = try .initFile(gpa, file, .{ .level = o.level, .bits = o.bits }, info) },
        .ogg_flac => |o| .{ .ogg_flac = try .initFile(gpa, file, .{ .level = o.level, .bits = o.bits, .serial = o.serial }, info) },
        .ogg_vorbis => |o| .{ .ogg_vorbis = try .initFile(gpa, file, o, info) },
        .ogg_opus => |o| .{ .ogg_opus = try .initFile(gpa, file, o, info) },
    } };
}

pub fn deinit(self: *Encoder) void {
    switch (self.impl) {
        inline else => |*e| e.deinit(),
    }
    self.* = undefined;
}

/// Takes whole interleaved frames.
pub fn write(self: *Encoder, frames: []const f32) codec.WriteError!void {
    return switch (self.impl) {
        inline else => |*e| e.write(frames),
    };
}

/// Flushes the stream. A writer made with `initFile` that can seek gets the real header
/// sizes and the FLAC MD5. Other writers keep the unknown values the format defines.
pub fn finish(self: *Encoder) codec.WriteError!void {
    return switch (self.impl) {
        inline else => |*e| e.finish(),
    };
}

/// True after `finish` wrote the real header values. Ogg Vorbis and Ogg Opus have no sizes in their
/// headers, so they give false.
pub fn sizesFixed(self: *const Encoder) bool {
    return switch (self.impl) {
        .ogg_vorbis, .ogg_opus => false,
        inline else => |*e| e.sizes_fixed,
    };
}

fn testInts(gpa: std.mem.Allocator, channels: usize, frames: usize) ![]f32 {
    const out = try gpa.alloc(f32, channels * frames);
    for (0..frames) |f| {
        for (0..channels) |c| {
            const t: f32 = @floatFromInt(f);
            out[f * channels + c] = 0.5 * @sin(t * 0.03 * @as(f32, @floatFromInt(c + 1)));
        }
    }
    return out;
}

const all_options = [_]codec.EncodeOptions{
    .{ .wav = .{ .sample = .s16 } },
    .{ .wav = .{ .sample = .f32 } },
    .{ .flac = .{ .level = 8, .bits = 24 } },
    .{ .flac = .{} },
    .{ .ogg_flac = .{ .level = 2, .bits = 16, .serial = 4 } },
    .{ .ogg_flac = .{ .level = 8, .bits = 24 } },
    .{ .ogg_vorbis = .{ .quality = 6, .serial = 3 } },
    .{ .ogg_opus = .{ .serial = 5 } },
    .{ .ogg_opus = .{ .bitrate = 128000, .vbr = false, .frame_ms = 10 } },
};

test "every format round trips through the Decoder" {
    const gpa = testing.allocator;
    const info: codec.Info = .{ .rate = 48000, .channels = 2, .mask = .{}, .total_frames = null, .bits_per_sample = 16 };
    const input = try testInts(gpa, 2, 10000);
    defer gpa.free(input);
    const tolerance = [_]f32{ 1.0 / 32768.0, 1e-7, 1.0 / 8388608.0, 1.0 / 32768.0, 1.0 / 32768.0, 1.0 / 8388608.0, 0, 0, 0 };
    for (all_options, tolerance) |options, tol| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var enc: Encoder = try .init(gpa, &aw.writer, options, info);
        defer enc.deinit();
        try enc.write(input[0..3000]);
        try enc.write(input[3000..]);
        try enc.finish();
        try testing.expect(!enc.sizesFixed() or options == .wav);

        var dec: codec.Decoder = try .init(gpa, .{ .bytes = aw.written() }, .auto);
        defer dec.deinit();
        try testing.expectEqual(@as(u32, 48000), dec.info().rate);
        const got = try gpa.alloc(f32, input.len + 2);
        defer gpa.free(got);
        var have: usize = 0;
        while (true) {
            const n = try dec.read(got[have..]);
            if (n == 0) break;
            have += n * 2;
        }
        try testing.expectEqual(input.len, have);
        if (options == .ogg_vorbis or options == .ogg_opus) {
            var signal: f64 = 0;
            var noise: f64 = 0;
            for (input, got[0..have]) |a, b| {
                signal += @as(f64, a) * a;
                noise += (@as(f64, a) - b) * (a - b);
            }
            try testing.expect(signal / noise > 100);
            continue;
        }
        for (input, got[0..have]) |a, b| try testing.expect(@abs(a - b) <= tol * 0.51);
    }
}

test "initFile fixes the sizes of every format" {
    if (!io.has_files) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const info: codec.Info = .{ .rate = 44100, .channels = 1, .mask = .{}, .total_frames = null, .bits_per_sample = 16 };
    const input = try testInts(gpa, 1, 9000);
    defer gpa.free(input);
    for (all_options, 0..) |options, i| {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "f{d}", .{i});
        {
            var file = try tmp.dir.createFile(testing.io, name, .{});
            defer file.close(testing.io);
            var wbuf: [64]u8 = undefined;
            var fw = file.writer(testing.io, &wbuf);
            var enc: Encoder = try .initFile(gpa, &fw, options, info);
            defer enc.deinit();
            try enc.write(input);
            try testing.expect(!enc.sizesFixed());
            try enc.finish();
            try testing.expectEqual(options != .ogg_vorbis and options != .ogg_opus, enc.sizesFixed());
        }
        const bytes = try tmp.dir.readFileAlloc(testing.io, name, gpa, .limited(1 << 22));
        defer gpa.free(bytes);
        var dec: codec.Decoder = try .init(gpa, .{ .bytes = bytes }, .auto);
        defer dec.deinit();
        // Opus resamples 44.1 kHz to 48 kHz, so the stream is longer.
        const frames: u64 = if (options == .ogg_opus) (9000 * 48000 + 44099) / 44100 else 9000;
        try testing.expectEqual(@as(?u64, frames), dec.info().total_frames);
    }
}

test "the encoder creation errors are only OutOfMemory and Unsupported" {
    inline for (.{ Encoder.init, Encoder.initFile }) |f| {
        const result = @typeInfo(@typeInfo(@TypeOf(f)).@"fn".return_type.?).error_union.error_set;
        try testing.expect(result == codec.EncoderInitError);
    }
}

test "bad options give Unsupported" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const info: codec.Info = .{ .rate = 44100, .channels = 2, .mask = .{}, .total_frames = null, .bits_per_sample = 16 };
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .flac = .{ .level = 12 } }, info));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .ogg_flac = .{ .bits = 4 } }, info));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .ogg_vorbis = .{ .quality = std.math.nan(f32) } }, info));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .ogg_vorbis = .{} }, .{ .rate = 0, .channels = 2 }));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .ogg_opus = .{} }, .{ .rate = 0, .channels = 2 }));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .ogg_opus = .{ .frame_ms = 7 } }, info));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .ogg_opus = .{ .bitrate = 10 } }, info));
}

test "zero frames round trip in every format" {
    const gpa = testing.allocator;
    const info: codec.Info = .{ .rate = 48000, .channels = 2 };
    for (all_options) |options| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var enc: Encoder = try .init(gpa, &aw.writer, options, info);
        defer enc.deinit();
        try enc.finish();
        var dec: codec.Decoder = try .init(gpa, .{ .bytes = aw.written() }, .auto);
        defer dec.deinit();
        var buf: [8]f32 = undefined;
        try testing.expectEqual(@as(usize, 0), try dec.read(&buf));
        try dec.seek(0);
        try testing.expectEqual(@as(usize, 0), try dec.read(&buf));
    }
}

test "every encoder refuses a partial frame and a write after finish" {
    const gpa = testing.allocator;
    const info: codec.Info = .{ .rate = 48000, .channels = 2 };
    for (all_options) |options| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var enc: Encoder = try .init(gpa, &aw.writer, options, info);
        defer enc.deinit();
        try testing.expectError(error.Unsupported, enc.write(&.{ 0.1, 0.2, 0.3 }));
        try enc.write(&.{ 0.1, 0.2, 0.3, 0.4 });
        try enc.finish();
        const size = aw.written().len;
        try testing.expectError(error.Unsupported, enc.write(&.{ 0.1, 0.2 }));
        try enc.finish();
        try testing.expectEqual(size, aw.written().len);
    }
}

test "a stream of three frames seeks in every format" {
    const gpa = testing.allocator;
    const info: codec.Info = .{ .rate = 48000, .channels = 1 };
    for (all_options) |options| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var enc: Encoder = try .init(gpa, &aw.writer, options, info);
        defer enc.deinit();
        try enc.write(&.{ 0.25, 0.5, -0.5 });
        try enc.finish();
        var dec: codec.Decoder = try .init(gpa, .{ .bytes = aw.written() }, .auto);
        defer dec.deinit();
        var buf: [8]f32 = undefined;
        try testing.expectEqual(@as(usize, 3), try dec.read(&buf));
        const third = buf[2];
        try dec.seek(2);
        try testing.expectEqual(@as(usize, 1), try dec.read(&buf));
        // Opus codes the three samples with a loss, but a seek to the first page decodes the same samples.
        if (options == .ogg_opus) {
            try testing.expectEqual(third, buf[0]);
        } else {
            try testing.expectApproxEqAbs(@as(f32, -0.5), buf[0], @as(f32, if (options == .ogg_vorbis) 0.15 else 0));
        }
        try dec.seek(3);
        try testing.expectEqual(@as(usize, 0), try dec.read(&buf));
        try testing.expectError(error.Truncated, dec.seek(4));
    }
}

test "damaged streams never crash the front end" {
    const gpa = testing.allocator;
    const info: codec.Info = .{ .rate = 44100, .channels = 2 };
    const input = try testInts(gpa, 2, 6000);
    defer gpa.free(input);
    var prng: std.Random.DefaultPrng = .init(0x1234);
    const rnd = prng.random();
    for (all_options) |options| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var enc: Encoder = try .init(gpa, &aw.writer, options, info);
        defer enc.deinit();
        try enc.write(input);
        try enc.finish();
        const good = aw.written();
        const copy = try gpa.dupe(u8, good);
        defer gpa.free(copy);
        for (0..400) |_| {
            @memcpy(copy, good);
            const flips = rnd.intRangeAtMost(usize, 1, 8);
            for (0..flips) |_| {
                const at = if (rnd.boolean()) rnd.uintLessThan(usize, @min(copy.len, 200)) else rnd.uintLessThan(usize, copy.len);
                copy[at] = rnd.int(u8);
            }
            const cut = if (rnd.uintLessThan(u8, 4) == 0) rnd.uintLessThan(usize, copy.len) else copy.len;
            var dec = codec.Decoder.init(gpa, .{ .bytes = copy[0..cut] }, .auto) catch continue;
            defer dec.deinit();
            var buf: [512]f32 = undefined;
            var guard: usize = 0;
            while (guard < 10000) : (guard += 1) {
                const n = dec.read(&buf) catch break;
                if (n == 0) break;
            }
            dec.seek(rnd.uintLessThan(u64, 8000)) catch continue;
            _ = dec.read(&buf) catch 0;
        }
    }
}
