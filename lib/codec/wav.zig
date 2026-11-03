//! WAV and RF64 decoding and encoding.
//!
//! The decoder reads PCM (8, 16, 24 and 32 bit), IEEE float (32 and 64 bit) and
//! WAVE_FORMAT_EXTENSIBLE with the PCM or float sub format. The encoder writes
//! the same set. Samples are f32 with the integer scale 2^(bits-1).
const std = @import("std");
const codec = @import("../codec.zig");
const io = @import("io.zig");
const pcm = @import("pcm.zig");
const helpers = @import("testing.zig");
const testing = std.testing;

pub const Sample = pcm.Sample;

const unknown_size: u32 = 0xFFFFFFFF;
const ds64_size = 28;
const tag_pcm: u16 = 1;
const tag_float: u16 = 3;
const tag_extensible: u16 = 0xFFFE;
const guid_tail = [12]u8{ 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71 };

/// The channel mask that flac and libsndfile assume for 1 to 8 channels. Other counts give 0.
pub fn defaultMask(channels: u8) u32 {
    return switch (channels) {
        1 => 0x4,
        2 => 0x3,
        3 => 0x7,
        4 => 0x33,
        5 => 0x607,
        6 => 0x60f,
        7 => 0x70f,
        8 => 0x63f,
        else => 0,
    };
}

const ParseError = error{ Unsupported, BadHeader, Truncated, ReadFailed };

const Parsed = struct {
    info: codec.Info,
    sample: Sample,
    data_start: u64,
    /// Size of the data in bytes. Null when the size is unknown.
    data_len: ?u64,
    mask_fallback: bool,
};

const Fmt = struct {
    info: codec.Info,
    sample: Sample,
    mask_fallback: bool,
};

fn parseFmt(body: []const u8, size: u32) ParseError!Fmt {
    std.debug.assert(body.len >= 16);
    const tag = std.mem.readInt(u16, body[0..2], .little);
    const channels = std.mem.readInt(u16, body[2..4], .little);
    const rate = std.mem.readInt(u32, body[4..8], .little);
    const block_align = std.mem.readInt(u16, body[12..14], .little);
    const bits = std.mem.readInt(u16, body[14..16], .little);
    if (channels == 0 or rate == 0) return error.BadHeader;
    if (channels > 255) return error.Unsupported;

    var is_float = tag == tag_float;
    var valid = bits;
    var mask = defaultMask(@intCast(channels));
    var mask_fallback = false;
    switch (tag) {
        tag_pcm, tag_float => {},
        tag_extensible => {
            if (size < 40 or body.len < 40) return error.BadHeader;
            if (std.mem.readInt(u16, body[16..18], .little) < 22) return error.BadHeader;
            valid = std.mem.readInt(u16, body[18..20], .little);
            if (valid == 0 or valid > bits) return error.BadHeader;
            mask = std.mem.readInt(u32, body[20..24], .little);
            const sub = std.mem.readInt(u32, body[24..28], .little);
            if (!std.mem.eql(u8, body[28..40], &guid_tail)) return error.Unsupported;
            switch (sub) {
                tag_pcm => is_float = false,
                tag_float => is_float = true,
                else => return error.Unsupported,
            }
            if (@popCount(mask) != channels) {
                mask = defaultMask(@intCast(channels));
                mask_fallback = true;
            }
        },
        else => return error.Unsupported,
    }
    const sample: Sample = if (is_float) switch (bits) {
        32 => .f32,
        64 => .f64,
        else => return error.Unsupported,
    } else switch (bits) {
        8 => .u8,
        16 => .s16,
        24 => .s24,
        32 => .s32,
        else => return error.Unsupported,
    };
    if (block_align != @as(u32, channels) * sample.bytes()) return error.BadHeader;
    return .{
        .sample = sample,
        .mask_fallback = mask_fallback,
        .info = .{
            .rate = rate,
            .channels = @intCast(channels),
            .mask = @bitCast(mask),
            .total_frames = null,
            .bits_per_sample = @intCast(if (is_float) bits else valid),
        },
    };
}

fn parse(input: *io.Input) ParseError!Parsed {
    var head: [12]u8 = undefined;
    try input.readExact(&head);
    const rf64 = std.mem.eql(u8, head[0..4], "RF64");
    if (!rf64 and !std.mem.eql(u8, head[0..4], "RIFF")) return error.BadHeader;
    if (!std.mem.eql(u8, head[8..12], "WAVE")) return error.BadHeader;

    var fmt: ?Fmt = null;
    var ds64_data: ?u64 = null;
    while (true) {
        var ch: [8]u8 = undefined;
        const got = try input.readUpTo(&ch);
        if (got == 0) return error.BadHeader;
        if (got < ch.len) return error.Truncated;
        const size = std.mem.readInt(u32, ch[4..8], .little);
        const pad: u64 = size & 1;
        if (std.mem.eql(u8, ch[0..4], "fmt ")) {
            if (size < 16 or fmt != null) return error.BadHeader;
            var body: [40]u8 = undefined;
            const n: usize = @min(size, body.len);
            try input.readExact(body[0..n]);
            try input.skip(size - n + pad);
            fmt = try parseFmt(body[0..n], size);
        } else if (std.mem.eql(u8, ch[0..4], "data")) {
            const f = fmt orelse return error.BadHeader;
            var out: Parsed = .{
                .info = f.info,
                .sample = f.sample,
                .data_start = input.position(),
                .data_len = size,
                .mask_fallback = f.mask_fallback,
            };
            if (size == unknown_size) out.data_len = ds64_data;
            if (input.length()) |len| {
                const held = len -| out.data_start;
                out.data_len = if (out.data_len) |n| @min(n, held) else held;
            }
            if (out.data_len) |n| out.info.total_frames = n / (@as(u64, f.info.channels) * f.sample.bytes());
            return out;
        } else if (rf64 and std.mem.eql(u8, ch[0..4], "ds64")) {
            if (size < ds64_size) return error.BadHeader;
            var body: [ds64_size]u8 = undefined;
            try input.readExact(&body);
            ds64_data = std.mem.readInt(u64, body[8..16], .little);
            try input.skip(size - ds64_size + pad);
        } else {
            if (rf64 and size == unknown_size) return error.Unsupported;
            try input.skip(@as(u64, size) + pad);
        }
    }
}

/// Reads samples from a WAV or RF64 file as interleaved f32.
pub const Decoder = struct {
    gpa: std.mem.Allocator,
    input: *io.Input,
    stream: codec.Info,
    sample: Sample,
    frame_bytes: usize,
    data_start: u64,
    done: u64 = 0,
    buf: []u8,
    /// True when the file mask did not fit the channel count and the default mask replaced it.
    mask_fallback: bool,

    pub fn init(gpa: std.mem.Allocator, input: *io.Input) codec.InitError!Decoder {
        const parsed = try parse(input);
        const frame_bytes = @as(usize, parsed.info.channels) * parsed.sample.bytes();
        const buf = try gpa.alloc(u8, frame_bytes * @max(1, 4096 / frame_bytes));
        return .{
            .gpa = gpa,
            .input = input,
            .stream = parsed.info,
            .sample = parsed.sample,
            .frame_bytes = frame_bytes,
            .data_start = parsed.data_start,
            .buf = buf,
            .mask_fallback = parsed.mask_fallback,
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.gpa.free(self.buf);
        self.* = undefined;
    }

    pub fn info(self: *const Decoder) codec.Info {
        return self.stream;
    }

    /// Writes whole frames into `out` and returns the frame count. 0 means the end.
    /// `out` must hold at least one frame (`info().channels` samples).
    /// A data chunk that ends before its stated size gives error.Truncated.
    pub fn read(self: *Decoder, out: []f32) codec.ReadError!usize {
        const channels: usize = self.stream.channels;
        std.debug.assert(out.len >= channels);
        var want = out.len / channels;
        if (self.stream.total_frames) |total| {
            want = @intCast(@min(want, total - self.done));
        }
        if (want == 0) return 0;
        const per_pass = self.buf.len / self.frame_bytes;
        var frames: usize = 0;
        while (frames < want) {
            const n = @min(want - frames, per_pass);
            const got = try self.input.readUpTo(self.buf[0 .. n * self.frame_bytes]);
            const whole = got / self.frame_bytes;
            pcm.toF32(
                self.sample,
                self.buf[0 .. whole * self.frame_bytes],
                out[frames * channels ..][0 .. whole * channels],
            );
            frames += whole;
            if (whole < n) break;
        }
        self.done += frames;
        if (frames == 0 and self.stream.total_frames != null) return error.Truncated;
        return frames;
    }

    /// Moves to a frame. `frame` equal to the frame count is the end of the data.
    pub fn seek(self: *Decoder, frame: u64) codec.SeekError!void {
        if (!self.input.seekable()) return error.Unseekable;
        if (self.stream.total_frames) |total| {
            if (frame > total) return error.Truncated;
        }
        const bytes = std.math.mul(u64, frame, self.frame_bytes) catch return error.BadData;
        const offset = std.math.add(u64, self.data_start, bytes) catch return error.BadData;
        try self.input.seekTo(offset);
        self.done = frame;
    }
};

pub const Options = struct { sample: Sample = .s16 };

/// Writes interleaved f32 frames as WAV.
///
/// With `init` the writer cannot seek, so the RIFF and data sizes stay 0xFFFFFFFF
/// (unknown) and the file never becomes RF64. Readers take the data to be the
/// rest of the file. With `initFile` the header holds a reserved JUNK chunk.
/// `finish` seeks back and writes the sizes, and turns the chunk into ds64 for
/// RF64 when the data reaches 4 GiB and sets `sizes_fixed`. If the file reports
/// error.Unseekable, `finish` leaves the unknown sizes and writes no pad byte.
/// Every other seek or write error is error.WriteFailed. Odd data gets one pad
/// byte only when the sizes are fixed. The sample format comes from `Options`.
/// `Info.bits_per_sample` and `Info.total_frames` are ignored. A zero `Info.mask` selects the default mask.
/// A mask whose bit count differs from the channel count gives error.Unsupported.
pub const Encoder = struct {
    writer: *std.Io.Writer,
    file: ?*std.Io.File.Writer,
    sample: Sample,
    channels: u8,
    rate: u32,
    mask: u32,
    extensible: bool,
    byte_rate: u32,
    started: bool = false,
    finished: bool = false,
    data_bytes: u64 = 0,
    /// True after `finish` wrote the real sizes into the header.
    sizes_fixed: bool = false,

    const max_header = 12 + 8 + ds64_size + 8 + 40 + 8;

    pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, options: Options, info: codec.Info) codec.EncoderInitError!Encoder {
        _ = gpa;
        return start(writer, null, options, info);
    }

    pub fn initFile(gpa: std.mem.Allocator, file: *std.Io.File.Writer, options: Options, info: codec.Info) codec.EncoderInitError!Encoder {
        _ = gpa;
        return start(&file.interface, file, options, info);
    }

    fn start(writer: *std.Io.Writer, file: ?*std.Io.File.Writer, options: Options, info: codec.Info) codec.EncoderInitError!Encoder {
        if (info.channels == 0 or info.rate == 0) return error.Unsupported;
        const given: u32 = @bitCast(info.mask);
        const default = defaultMask(info.channels);
        const mask = if (given == 0) default else given;
        if (given != 0 and @popCount(given) != info.channels) return error.Unsupported;
        const block_align = @as(u64, info.channels) * options.sample.bytes();
        const byte_rate = std.math.cast(u32, @as(u64, info.rate) * block_align) orelse return error.Unsupported;
        const wide = info.channels > 2 or options.sample.bytes() > 2;
        return .{
            .writer = writer,
            .file = file,
            .sample = options.sample,
            .channels = info.channels,
            .rate = info.rate,
            .mask = mask,
            .byte_rate = byte_rate,
            .extensible = wide or mask != default,
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.* = undefined;
    }

    const Put = struct {
        buf: []u8,
        n: usize = 0,

        fn bytes(p: *Put, b: []const u8) void {
            @memcpy(p.buf[p.n..][0..b.len], b);
            p.n += b.len;
        }

        fn int(p: *Put, comptime T: type, v: T) void {
            std.mem.writeInt(T, p.buf[p.n..][0..@sizeOf(T)], v, .little);
            p.n += @sizeOf(T);
        }
    };

    fn header(self: *const Encoder, buf: *[max_header]u8, final: bool) []const u8 {
        const fmt_len: u32 = if (self.extensible) 40 else if (self.sample.isFloat()) 18 else 16;
        const junk_len: u32 = if (self.file != null) 8 + ds64_size else 0;
        const head_len: u64 = 12 + junk_len + 8 + fmt_len + 8;
        const pad: u64 = self.data_bytes & 1;
        const riff_size: u64 = head_len - 8 + self.data_bytes + pad;
        const rf64 = final and (self.data_bytes >= unknown_size or riff_size >= unknown_size);
        var riff32: u32 = unknown_size;
        var data32: u32 = unknown_size;
        if (final and !rf64) {
            riff32 = @intCast(riff_size);
            data32 = @intCast(self.data_bytes);
        }

        var p: Put = .{ .buf = buf };
        p.bytes(if (rf64) "RF64" else "RIFF");
        p.int(u32, riff32);
        p.bytes("WAVE");
        if (self.file != null) {
            p.bytes(if (rf64) "ds64" else "JUNK");
            p.int(u32, ds64_size);
            if (rf64) {
                p.int(u64, riff_size);
                p.int(u64, self.data_bytes);
                p.int(u64, self.data_bytes / (@as(u64, self.channels) * self.sample.bytes()));
                p.int(u32, 0);
            } else {
                p.bytes(&@as([ds64_size]u8, @splat(0)));
            }
        }
        const block_align: u16 = @as(u16, self.channels) * self.sample.bytes();
        const bits: u16 = @as(u16, self.sample.bytes()) * 8;
        const tag: u16 = if (self.sample.isFloat()) tag_float else tag_pcm;
        p.bytes("fmt ");
        p.int(u32, fmt_len);
        p.int(u16, if (self.extensible) tag_extensible else tag);
        p.int(u16, self.channels);
        p.int(u32, self.rate);
        p.int(u32, self.byte_rate);
        p.int(u16, block_align);
        p.int(u16, bits);
        if (self.extensible) {
            p.int(u16, 22);
            p.int(u16, bits);
            p.int(u32, self.mask);
            p.int(u32, tag);
            p.bytes(&guid_tail);
        } else if (self.sample.isFloat()) {
            p.int(u16, 0);
        }
        p.bytes("data");
        p.int(u32, data32);
        return buf[0..p.n];
    }

    fn begin(self: *Encoder) codec.WriteError!void {
        if (self.started) return;
        var buf: [max_header]u8 = undefined;
        self.writer.writeAll(self.header(&buf, false)) catch return error.WriteFailed;
        self.started = true;
    }

    /// `frames` holds whole interleaved frames.
    pub fn write(self: *Encoder, frames: []const f32) codec.WriteError!void {
        if (self.finished or frames.len % self.channels != 0) return error.Unsupported;
        try self.begin();
        const size = self.sample.bytes();
        var buf: [4096]u8 = undefined;
        const per_pass = buf.len / size;
        var i: usize = 0;
        while (i < frames.len) {
            const n = @min(per_pass, frames.len - i);
            pcm.fromF32(self.sample, frames[i..][0..n], buf[0 .. n * size]);
            self.writer.writeAll(buf[0 .. n * size]) catch return error.WriteFailed;
            i += n;
            self.data_bytes += n * size;
        }
    }

    pub fn finish(self: *Encoder) codec.WriteError!void {
        if (self.finished) return;
        self.finished = true;
        try self.begin();
        self.writer.flush() catch return error.WriteFailed;
        const file = self.file orelse return;
        var end = file.logicalPos();
        if (!try io.rewindWriter(file)) return;
        file.seekTo(end) catch return error.WriteFailed;
        if (self.data_bytes & 1 == 1) {
            self.writer.writeByte(0) catch return error.WriteFailed;
            self.writer.flush() catch return error.WriteFailed;
            end = file.logicalPos();
        }
        file.seekTo(0) catch return error.WriteFailed;
        var buf: [max_header]u8 = undefined;
        file.interface.writeAll(self.header(&buf, true)) catch return error.WriteFailed;
        file.seekTo(end) catch return error.WriteFailed;
        self.sizes_fixed = true;
    }
};

// Tests

fn le(comptime T: type, v: T) [@sizeOf(T)]u8 {
    var out: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &out, v, .little);
    return out;
}

const mono16_fmt = "fmt " ++ le(u32, 16) ++ le(u16, 1) ++ le(u16, 1) ++ le(u32, 8000) ++ le(u32, 16000) ++ le(u16, 2) ++ le(u16, 16);
const good_wav = "RIFF" ++ le(u32, 44) ++ "WAVE" ++ mono16_fmt ++ "data" ++ le(u32, 8) ++ le(i16, 0) ++ le(i16, 16384) ++ le(i16, -32768) ++ le(i16, 8192);

fn testValue(sample: Sample, i: usize) f32 {
    if (sample.isFloat()) return @as(f32, @floatFromInt(i % 150)) * 0.0121 - 0.9;
    const bits: u6 = @min(sample.bytes() * 8, 24);
    const levels: i64 = @as(i64, 1) << bits;
    const raw: i64 = @intCast((i *% 2654435761 +% 13) % @as(usize, @intCast(levels)));
    const level = raw - @divExact(levels, 2);
    return @as(f32, @floatFromInt(level)) / @as(f32, @floatFromInt(@divExact(levels, 2)));
}

fn readAll(dec: *Decoder, out: []f32) !usize {
    const ch: usize = dec.info().channels;
    var done: usize = 0;
    while (done * ch < out.len) {
        const end = @min(out.len, done * ch + 7 * ch);
        const n = try dec.read(out[done * ch .. end]);
        if (n == 0) break;
        done += n;
    }
    return done;
}

fn encodeAll(gpa: std.mem.Allocator, sample: Sample, info: codec.Info, src: []const f32) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var enc: Encoder = try .init(gpa, &aw.writer, .{ .sample = sample }, info);
    defer enc.deinit();
    try enc.write(src[0 .. src.len / 2]);
    try enc.write(src[src.len / 2 ..]);
    try enc.finish();
    return aw.toOwnedSlice();
}

test "round trip every sample format at mono, stereo and 5.1" {
    const gpa = testing.allocator;
    const kinds = [_]Sample{ .u8, .s16, .s24, .s32, .f32, .f64 };
    for (kinds) |kind| for ([_]u8{ 1, 2, 6 }) |ch| {
        const frames = 50;
        var src: [frames * 6]f32 = undefined;
        const n = frames * @as(usize, ch);
        for (src[0..n], 0..) |*s, i| s.* = testValue(kind, i);
        if (!kind.isFloat()) src[0] = -1.0;
        const info: codec.Info = .{
            .rate = 44100,
            .channels = ch,
            .mask = @bitCast(defaultMask(ch)),
            .total_frames = null,
            .bits_per_sample = 0,
        };
        const bytes = try encodeAll(gpa, kind, info, src[0..n]);
        defer gpa.free(bytes);

        var input: io.Input = .init(.{ .bytes = bytes });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        const got = dec.info();
        try testing.expectEqual(@as(u32, 44100), got.rate);
        try testing.expectEqual(ch, got.channels);
        try testing.expectEqual(@as(u32, defaultMask(ch)), @as(u32, @bitCast(got.mask)));
        try testing.expectEqual(@as(?u64, frames), got.total_frames);
        try testing.expectEqual(@as(u8, kind.bytes() * 8), got.bits_per_sample);
        var out: [frames * 6 + 10]f32 = undefined;
        try testing.expectEqual(@as(usize, frames), try readAll(&dec, &out));
        try testing.expectEqualSlices(f32, src[0..n], out[0..n]);
        try testing.expectEqual(@as(usize, 0), try dec.read(&out));
    };
}

test "integer formats keep exact levels" {
    const gpa = testing.allocator;
    const src = [_]f32{ -1.0, -0.5, 0.0, 0.25, 0.5 };
    const info: codec.Info = .{ .rate = 8000, .channels = 1, .mask = .{ .front_center = true }, .total_frames = null, .bits_per_sample = 16 };
    const bytes = try encodeAll(gpa, .s16, info, &src);
    defer gpa.free(bytes);
    try testing.expectEqualSlices(u8, &(le(i16, -32768) ++ le(i16, -16384) ++ le(i16, 0) ++ le(i16, 8192) ++ le(i16, 16384)), bytes[44..]);
    const bytes8 = try encodeAll(gpa, .u8, info, &src);
    defer gpa.free(bytes8);
    try testing.expectEqualSlices(u8, &.{ 0, 64, 128, 160, 192 }, bytes8[44..49]);
}

test "plain writer leaves the sizes unknown and writes no pad byte" {
    const gpa = testing.allocator;
    const src = [_]f32{ 0.0, 0.5, -0.5 };
    const info: codec.Info = .{ .rate = 8000, .channels = 1, .mask = .{ .front_center = true }, .total_frames = null, .bits_per_sample = 8 };
    const bytes = try encodeAll(gpa, .u8, info, &src);
    defer gpa.free(bytes);
    try testing.expectEqual(@as(usize, 47), bytes.len);
    try testing.expectEqualStrings("RIFF", bytes[0..4]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), std.mem.readInt(u32, bytes[4..8], .little));
    try testing.expectEqualStrings("data", bytes[36..40]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), std.mem.readInt(u32, bytes[40..44], .little));
    try testing.expectEqualSlices(u8, &.{ 128, 192, 64 }, bytes[44..47]);

    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    var out: [8]f32 = undefined;
    try testing.expectEqual(@as(?u64, 3), dec.info().total_frames);
    try testing.expectEqual(@as(usize, 3), try dec.read(&out));
    try testing.expectEqualSlices(f32, &.{ 0.0, 0.5, -0.5 }, out[0..3]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out));
}

test "plain writer output decodes from a forward only reader" {
    const gpa = testing.allocator;
    const src = [_]f32{ 0.25, -0.25, 0.5, -0.5 };
    const info: codec.Info = .{ .rate = 48000, .channels = 2, .mask = .{ .front_left = true, .front_right = true }, .total_frames = null, .bits_per_sample = 16 };
    const bytes = try encodeAll(gpa, .s16, info, &src);
    defer gpa.free(bytes);
    var r: std.Io.Reader = .fixed(bytes);
    var input: io.Input = .init(.{ .reader = &r });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, null), dec.info().total_frames);
    var out: [4]f32 = undefined;
    try testing.expectEqual(@as(usize, 2), try dec.read(&out));
    try testing.expectEqualSlices(f32, &src, &out);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out));
    try testing.expectError(error.Unseekable, dec.seek(0));
}

fn fmtSize(bytes: []const u8) u32 {
    const off: usize = if (std.mem.eql(u8, bytes[12..16], "fmt ")) 16 else 48;
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

test "extensible is written for wide formats and odd masks only" {
    const gpa = testing.allocator;
    const src: [12]f32 = @splat(0.0);
    const stereo: codec.Info = .{ .rate = 8000, .channels = 2, .mask = .{ .front_left = true, .front_right = true }, .total_frames = null, .bits_per_sample = 16 };
    {
        const b = try encodeAll(gpa, .s16, stereo, src[0..4]);
        defer gpa.free(b);
        try testing.expectEqual(@as(u32, 16), fmtSize(b));
    }
    {
        const b = try encodeAll(gpa, .s16, .{ .rate = 8000, .channels = 2, .mask = .{}, .total_frames = null, .bits_per_sample = 16 }, src[0..4]);
        defer gpa.free(b);
        try testing.expectEqual(@as(u32, 16), fmtSize(b));
    }
    for ([_]Sample{ .s24, .s32, .f32, .f64 }) |kind| {
        const b = try encodeAll(gpa, kind, stereo, src[0..4]);
        defer gpa.free(b);
        try testing.expectEqual(@as(u32, 40), fmtSize(b));
    }
    {
        var odd = stereo;
        odd.mask = .{ .front_left = true, .front_center = true };
        const b = try encodeAll(gpa, .s16, odd, src[0..4]);
        defer gpa.free(b);
        try testing.expectEqual(@as(u32, 40), fmtSize(b));
        var input: io.Input = .init(.{ .bytes = b });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        try testing.expectEqual(@as(u32, 0x5), @as(u32, @bitCast(dec.info().mask)));
    }
    {
        const surround: codec.Info = .{ .rate = 48000, .channels = 6, .mask = @bitCast(@as(u32, 0x60f)), .total_frames = null, .bits_per_sample = 16 };
        const b = try encodeAll(gpa, .s16, surround, &src);
        defer gpa.free(b);
        try testing.expectEqual(@as(u32, 40), fmtSize(b));
        try testing.expectEqual(@as(u16, 0xFFFE), std.mem.readInt(u16, b[20..22], .little));
        try testing.expectEqual(@as(u16, 22), std.mem.readInt(u16, b[36..38], .little));
        try testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, b[38..40], .little));
        try testing.expectEqual(@as(u32, 0x60f), std.mem.readInt(u32, b[40..44], .little));
        try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71 }, b[44..60]);
    }
    {
        const b = try encodeAll(gpa, .f32, .{ .rate = 8000, .channels = 1, .mask = .{ .front_center = true }, .total_frames = null, .bits_per_sample = 32 }, src[0..2]);
        defer gpa.free(b);
        try testing.expectEqual(@as(u8, 3), b[44]);
    }
}

fn expectHeaderField(comptime T: type, bytes: []const u8, off: usize, want: T) !void {
    try testing.expectEqual(want, std.mem.readInt(T, bytes[off..][0..@sizeOf(T)], .little));
}

test "a seekable file gets its sizes fixed at finish" {
    if (!io.has_files) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(testing.io, "a.wav", .{});
        defer file.close(testing.io);
        var wbuf: [16]u8 = undefined;
        var fw = file.writer(testing.io, &wbuf);
        const info: codec.Info = .{ .rate = 44100, .channels = 2, .mask = .{ .front_left = true, .front_right = true }, .total_frames = null, .bits_per_sample = 16 };
        var enc: Encoder = try .initFile(gpa, &fw, .{ .sample = .s16 }, info);
        defer enc.deinit();
        try enc.write(&.{ 0.5, -0.5, 0.25, -0.25, 0.0, 0.125 });
        try enc.finish();
    }
    const bytes = try tmp.dir.readFileAlloc(testing.io, "a.wav", gpa, .limited(1 << 16));
    defer gpa.free(bytes);
    try testing.expectEqual(@as(usize, 92), bytes.len);
    try testing.expectEqualStrings("RIFF", bytes[0..4]);
    try expectHeaderField(u32, bytes, 4, 84);
    try testing.expectEqualStrings("JUNK", bytes[12..16]);
    try expectHeaderField(u32, bytes, 16, 28);
    try testing.expectEqualStrings("fmt ", bytes[48..52]);
    try testing.expectEqualStrings("data", bytes[72..76]);
    try expectHeaderField(u32, bytes, 76, 12);
    try expectHeaderField(i16, bytes, 80, 16384);

    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 3), dec.info().total_frames);
}

test "data past 4 GiB turns the reserved chunk into ds64" {
    if (!io.has_files) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const big: u64 = 5 << 30;
    {
        var file = try tmp.dir.createFile(testing.io, "a.wav", .{});
        defer file.close(testing.io);
        var wbuf: [16]u8 = undefined;
        var fw = file.writer(testing.io, &wbuf);
        const info: codec.Info = .{ .rate = 44100, .channels = 2, .mask = .{ .front_left = true, .front_right = true }, .total_frames = null, .bits_per_sample = 16 };
        var enc: Encoder = try .initFile(gpa, &fw, .{ .sample = .s16 }, info);
        defer enc.deinit();
        try enc.write(&.{ 0.5, -0.5, 0.25, -0.25, 0.0, 0.125 });
        enc.data_bytes = big;
        try enc.finish();
    }
    const bytes = try tmp.dir.readFileAlloc(testing.io, "a.wav", gpa, .limited(1 << 16));
    defer gpa.free(bytes);
    try testing.expectEqualStrings("RF64", bytes[0..4]);
    try expectHeaderField(u32, bytes, 4, 0xFFFFFFFF);
    try testing.expectEqualStrings("ds64", bytes[12..16]);
    try expectHeaderField(u32, bytes, 16, 28);
    try expectHeaderField(u64, bytes, 20, 72 + big);
    try expectHeaderField(u64, bytes, 28, big);
    try expectHeaderField(u64, bytes, 36, big / 4);
    try expectHeaderField(u32, bytes, 44, 0);
    try expectHeaderField(u32, bytes, 76, 0xFFFFFFFF);

    var r: std.Io.Reader = .fixed(bytes);
    var input: io.Input = .init(.{ .reader = &r });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, big / 4), dec.info().total_frames);
}

test "hand built RF64 with a small data size" {
    const gpa = testing.allocator;
    const wav = "RF64" ++ le(u32, 0xFFFFFFFF) ++ "WAVE" ++ "ds64" ++ le(u32, 28) ++ le(u64, 72) ++ le(u64, 8) ++ le(u64, 4) ++ le(u32, 0) ++
        mono16_fmt ++ "data" ++ le(u32, 0xFFFFFFFF) ++ le(i16, 0) ++ le(i16, 16384) ++ le(i16, -32768) ++ le(i16, 8192);
    var input: io.Input = .init(.{ .bytes = wav });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 4), dec.info().total_frames);
    var out: [8]f32 = undefined;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out));
    try testing.expectEqualSlices(f32, &.{ 0.0, 0.5, -1.0, 0.25 }, out[0..4]);
}

test "hand built RF64 with a huge data size" {
    const gpa = testing.allocator;
    const big: u64 = 5 << 30;
    const wav = "RF64" ++ le(u32, 0xFFFFFFFF) ++ "WAVE" ++ "ds64" ++ le(u32, 28) ++ le(u64, big + 64) ++ le(u64, big) ++ le(u64, big / 2) ++ le(u32, 0) ++
        mono16_fmt ++ "data" ++ le(u32, 0xFFFFFFFF) ++ le(i16, 1000) ++ le(i16, 2000);
    var out: [8]f32 = undefined;
    {
        // The input length is known, so the data length shrinks to what the file holds.
        var input: io.Input = .init(.{ .bytes = wav });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        try testing.expectEqual(@as(?u64, 2), dec.info().total_frames);
        try testing.expectEqual(@as(usize, 2), try dec.read(&out));
        try testing.expectEqual(@as(usize, 0), try dec.read(&out));
        try dec.seek(1);
        try testing.expectEqual(@as(usize, 1), try dec.read(&out));
        try testing.expectEqual(@as(f32, 2000.0 / 32768.0), out[0]);
    }
    {
        var r: std.Io.Reader = .fixed(wav);
        var input: io.Input = .init(.{ .reader = &r });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        try testing.expectEqual(@as(?u64, big / 2), dec.info().total_frames);
        try testing.expectEqual(@as(usize, 2), try dec.read(&out));
        try testing.expectError(error.Truncated, dec.read(&out));
    }
}

test "unknown chunks are skipped with odd padding and data may follow them" {
    const gpa = testing.allocator;
    const wav = "RIFF" ++ le(u32, 0) ++ "WAVE" ++ "LIST" ++ le(u32, 3) ++ "abc" ++ "\x00" ++ mono16_fmt ++
        "fact" ++ le(u32, 4) ++ le(u32, 2) ++ "junk" ++ le(u32, 1) ++ "x" ++ "\x00" ++
        "data" ++ le(u32, 4) ++ le(i16, 16384) ++ le(i16, -16384) ++ "LIST" ++ le(u32, 2) ++ "zz";
    var input: io.Input = .init(.{ .bytes = wav });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 2), dec.info().total_frames);
    var out: [8]f32 = undefined;
    try testing.expectEqual(@as(usize, 2), try dec.read(&out));
    try testing.expectEqualSlices(f32, &.{ 0.5, -0.5 }, out[0..2]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out));
}

test "seek on bytes and on a file" {
    const gpa = testing.allocator;
    var src: [100]f32 = undefined;
    for (&src, 0..) |*s, i| s.* = @as(f32, @floatFromInt(i)) / 128.0;
    const info: codec.Info = .{ .rate = 8000, .channels = 1, .mask = .{ .front_center = true }, .total_frames = null, .bits_per_sample = 16 };
    const bytes = try encodeAll(gpa, .s16, info, &src);
    defer gpa.free(bytes);
    {
        var input: io.Input = .init(.{ .bytes = bytes });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        var out: [4]f32 = undefined;
        try testing.expectEqual(@as(usize, 4), try dec.read(&out));
        try dec.seek(60);
        try testing.expectEqual(@as(usize, 2), try dec.read(out[0..2]));
        try testing.expectEqualSlices(f32, src[60..62], out[0..2]);
        try dec.seek(0);
        try testing.expectEqual(@as(usize, 4), try dec.read(&out));
        try testing.expectEqualSlices(f32, src[0..4], &out);
        try dec.seek(100);
        try testing.expectEqual(@as(usize, 0), try dec.read(&out));
        try testing.expectError(error.Truncated, dec.seek(101));
    }
    if (!io.has_files) return;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "s.wav", .data = bytes });
    var file = try tmp.dir.openFile(testing.io, "s.wav", .{});
    defer file.close(testing.io);
    var rbuf: [16]u8 = undefined;
    var fr = file.reader(testing.io, &rbuf);
    var input: io.Input = .init(.{ .file = &fr });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    var out: [3]f32 = undefined;
    try dec.seek(97);
    try testing.expectEqual(@as(usize, 3), try dec.read(&out));
    try testing.expectEqualSlices(f32, src[97..100], &out);
    try dec.seek(10);
    try testing.expectEqual(@as(usize, 3), try dec.read(&out));
    try testing.expectEqualSlices(f32, src[10..13], &out);
}

test "bad headers give errors" {
    // Truncated fmt chunk.
    try helpers.expectInitError(Decoder, error.Truncated, good_wav[0..30]);
    // Truncated before the RIFF header ends.
    try helpers.expectInitError(Decoder, error.Truncated, good_wav[0..6]);
    // data before fmt.
    try helpers.expectInitError(Decoder, error.BadHeader, "RIFF" ++ le(u32, 0) ++ "WAVE" ++ "data" ++ le(u32, 4) ++ le(i16, 1) ++ le(i16, 2) ++ mono16_fmt);
    // fmt chunk too small.
    try helpers.expectInitError(Decoder, error.BadHeader, "RIFF" ++ le(u32, 0) ++ "WAVE" ++ "fmt " ++ le(u32, 14) ++ le(u16, 1) ++ le(u16, 1) ++ le(u32, 8000) ++ le(u32, 16000) ++ le(u16, 2) ++ "data" ++ le(u32, 0));
    // Block align does not match.
    try helpers.expectInitError(Decoder, error.BadHeader, "RIFF" ++ le(u32, 0) ++ "WAVE" ++ "fmt " ++ le(u32, 16) ++ le(u16, 1) ++ le(u16, 1) ++ le(u32, 8000) ++ le(u32, 16000) ++ le(u16, 3) ++ le(u16, 16) ++ "data" ++ le(u32, 0));
    // No data chunk.
    try helpers.expectInitError(Decoder, error.BadHeader, "RIFF" ++ le(u32, 0) ++ "WAVE" ++ mono16_fmt);
    // Not a RIFF file, and a wrong form type.
    try helpers.expectInitError(Decoder, error.BadHeader, "RIFX" ++ good_wav[4..]);
    try helpers.expectInitError(Decoder, error.BadHeader, "RIFF" ++ le(u32, 0) ++ "AVI " ++ mono16_fmt);
    // Zero channels and zero rate.
    try helpers.expectInitError(Decoder, error.BadHeader, "RIFF" ++ le(u32, 0) ++ "WAVE" ++ "fmt " ++ le(u32, 16) ++ le(u16, 1) ++ le(u16, 0) ++ le(u32, 8000) ++ le(u32, 0) ++ le(u16, 0) ++ le(u16, 16) ++ "data" ++ le(u32, 0));
    try helpers.expectInitError(Decoder, error.BadHeader, "RIFF" ++ le(u32, 0) ++ "WAVE" ++ "fmt " ++ le(u32, 16) ++ le(u16, 1) ++ le(u16, 1) ++ le(u32, 0) ++ le(u32, 0) ++ le(u16, 2) ++ le(u16, 16) ++ "data" ++ le(u32, 0));
    // ADPCM is not supported.
    try helpers.expectInitError(Decoder, error.Unsupported, "RIFF" ++ le(u32, 0) ++ "WAVE" ++ "fmt " ++ le(u32, 16) ++ le(u16, 2) ++ le(u16, 1) ++ le(u32, 8000) ++ le(u32, 16000) ++ le(u16, 2) ++ le(u16, 16) ++ "data" ++ le(u32, 0));
    // 12 bit PCM without extensible is not supported.
    try helpers.expectInitError(Decoder, error.Unsupported, "RIFF" ++ le(u32, 0) ++ "WAVE" ++ "fmt " ++ le(u32, 16) ++ le(u16, 1) ++ le(u16, 1) ++ le(u32, 8000) ++ le(u32, 16000) ++ le(u16, 2) ++ le(u16, 12) ++ "data" ++ le(u32, 0));
    // RF64 chunk of unknown size that is not data.
    try helpers.expectInitError(Decoder, error.Unsupported, "RF64" ++ le(u32, 0xFFFFFFFF) ++ "WAVE" ++ "LIST" ++ le(u32, 0xFFFFFFFF));
    // ds64 too small.
    try helpers.expectInitError(Decoder, error.BadHeader, "RF64" ++ le(u32, 0xFFFFFFFF) ++ "WAVE" ++ "ds64" ++ le(u32, 8) ++ le(u64, 0));
}

fn extFmt(bits: u16, valid: u16, cb: u16, guid_tag: u32, size: u32) [8 + 40]u8 {
    return ("fmt " ++ le(u32, size) ++ le(u16, 0xFFFE) ++ le(u16, 2) ++ le(u32, 8000) ++ le(u32, 8000 * 2 * (bits / 8)) ++
        le(u16, 2 * (bits / 8)) ++ le(u16, bits) ++ le(u16, cb) ++ le(u16, valid) ++ le(u32, 3) ++
        le(u32, guid_tag) ++ le(u16, 0) ++ le(u16, 0x10) ++ [8]u8{ 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71 }).*;
}

test "extensible validation" {
    const head = "RIFF" ++ le(u32, 0) ++ "WAVE";
    const tail = "data" ++ le(u32, 8) ++ le(u32, 0) ++ le(u32, 0x40000000);
    const gpa = testing.allocator;
    {
        const wav = head ++ extFmt(24, 20, 22, 1, 40) ++ tail;
        var input: io.Input = .init(.{ .bytes = wav });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        try testing.expectEqual(@as(u8, 20), dec.info().bits_per_sample);
        try testing.expectEqual(@as(u32, 3), @as(u32, @bitCast(dec.info().mask)));
    }
    try helpers.expectInitError(Decoder, error.BadHeader, head ++ extFmt(24, 25, 22, 1, 40) ++ tail);
    try helpers.expectInitError(Decoder, error.BadHeader, head ++ extFmt(24, 0, 22, 1, 40) ++ tail);
    try helpers.expectInitError(Decoder, error.BadHeader, head ++ extFmt(24, 24, 21, 1, 40) ++ tail);
    try helpers.expectInitError(Decoder, error.BadHeader, head ++ extFmt(24, 24, 22, 1, 36) ++ tail);
    try helpers.expectInitError(Decoder, error.Unsupported, head ++ extFmt(16, 16, 22, 2, 40) ++ tail);
}

test "truncated data gives samples and then Truncated on a forward reader" {
    const gpa = testing.allocator;
    const wav = "RIFF" ++ le(u32, 0) ++ "WAVE" ++ mono16_fmt ++ "data" ++ le(u32, 100) ++ le(i16, 16384) ++ le(i16, 8192) ++ "\x01";
    var r: std.Io.Reader = .fixed(wav);
    var input: io.Input = .init(.{ .reader = &r });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 50), dec.info().total_frames);
    var out: [8]f32 = undefined;
    try testing.expectEqual(@as(usize, 2), try dec.read(&out));
    try testing.expectError(error.Truncated, dec.read(&out));
}

test "a file cut off mid recording ends cleanly with corrected total_frames" {
    const gpa = testing.allocator;
    const wav = "RIFF" ++ le(u32, 0) ++ "WAVE" ++ mono16_fmt ++ "data" ++ le(u32, 100) ++ le(i16, 16384) ++ le(i16, 8192) ++ "\x01";
    var input: io.Input = .init(.{ .bytes = wav });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 2), dec.info().total_frames);
    var out: [8]f32 = undefined;
    try testing.expectEqual(@as(usize, 2), try dec.read(&out));
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.25 }, out[0..2]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out));
}

test "every prefix of a valid file decodes or errors without a crash" {
    const gpa = testing.allocator;
    var src: [40]f32 = undefined;
    for (&src, 0..) |*s, i| s.* = testValue(.s16, i);
    const info: codec.Info = .{ .rate = 8000, .channels = 2, .mask = .{ .front_left = true, .front_right = true }, .total_frames = null, .bits_per_sample = 16 };
    const bytes = try encodeAll(gpa, .s24, info, &src);
    defer gpa.free(bytes);
    for (0..bytes.len) |len| {
        var input: io.Input = .init(.{ .bytes = bytes[0..len] });
        var dec = Decoder.init(gpa, &input) catch continue;
        defer dec.deinit();
        var out: [64]f32 = undefined;
        _ = readAll(&dec, &out) catch continue;
    }
}

test "encoder rejects bad parameters" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const base: codec.Info = .{ .rate = 8000, .channels = 1, .mask = .{}, .total_frames = null, .bits_per_sample = 16 };
    var zero_ch = base;
    zero_ch.channels = 0;
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{}, zero_ch));
    var zero_rate = base;
    zero_rate.rate = 0;
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{}, zero_rate));
    var enc: Encoder = try .init(gpa, &aw.writer, .{}, .{ .rate = 8000, .channels = 2, .mask = .{}, .total_frames = null, .bits_per_sample = 16 });
    defer enc.deinit();
    try testing.expectError(error.Unsupported, enc.write(&.{ 0.0, 0.0, 0.0 }));
    try enc.finish();
    try testing.expectError(error.Unsupported, enc.write(&.{ 0.0, 0.0 }));
}

test "a mask that does not fit the channel count falls back to the default" {
    const gpa = testing.allocator;
    const head = "RIFF" ++ le(u32, 0) ++ "WAVE";
    const tail = "data" ++ le(u32, 4) ++ le(u32, 0);
    // extFmt has 2 channels and mask 3, which fits.
    var ok: io.Input = .init(.{ .bytes = head ++ extFmt(16, 16, 22, 1, 40) ++ tail });
    var d1: Decoder = try .init(gpa, &ok);
    defer d1.deinit();
    try testing.expect(!d1.mask_fallback);
    var bad = extFmt(16, 16, 22, 1, 40);
    std.mem.writeInt(u32, bad[28..32], 0x60f, .little);
    var input: io.Input = .init(.{ .bytes = head ++ bad ++ tail });
    var d2: Decoder = try .init(gpa, &input);
    defer d2.deinit();
    try testing.expect(d2.mask_fallback);
    try testing.expectEqual(@as(u32, 0x3), @as(u32, @bitCast(d2.info().mask)));
}

test "encoder rejects a mask that does not fit the channel count" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const info: codec.Info = .{ .rate = 8000, .channels = 2, .mask = @bitCast(@as(u32, 0x60f)), .total_frames = null, .bits_per_sample = 16 };
    try testing.expectError(error.Unsupported, Encoder.init(testing.allocator, &aw.writer, .{}, info));
}

test "encoder rejects a byte rate that does not fit 32 bits" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const info: codec.Info = .{ .rate = 0xFFFFFFFF, .channels = 2, .mask = .{}, .total_frames = null, .bits_per_sample = 16 };
    try testing.expectError(error.Unsupported, Encoder.init(testing.allocator, &aw.writer, .{}, info));
}

test "sizes_fixed follows the seek result" {
    if (!io.has_files) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const info: codec.Info = .{ .rate = 8000, .channels = 1, .mask = .{ .front_center = true }, .total_frames = null, .bits_per_sample = 16 };
    {
        var file = try tmp.dir.createFile(testing.io, "a.wav", .{});
        defer file.close(testing.io);
        var wbuf: [16]u8 = undefined;
        var fw = file.writer(testing.io, &wbuf);
        var enc: Encoder = try .initFile(gpa, &fw, .{ .sample = .u8 }, info);
        try enc.write(&.{ 0.0, 0.5, -0.5 });
        try testing.expect(!enc.sizes_fixed);
        try enc.finish();
        try testing.expect(enc.sizes_fixed);
    }
    const fixed = try tmp.dir.readFileAlloc(testing.io, "a.wav", gpa, .limited(1 << 16));
    defer gpa.free(fixed);
    try expectHeaderField(u32, fixed, 76, 3);
    // The RIFF size covers the 72 bytes after "RIFF" and its size, the 3 data bytes and the pad.
    try expectHeaderField(u32, fixed, 4, 76);
    try testing.expectEqual(@as(usize, 80 + 4), fixed.len);
    try testing.expectEqual(@as(u8, 0), fixed[fixed.len - 1]);
    {
        var file = try tmp.dir.createFile(testing.io, "b.wav", .{});
        defer file.close(testing.io);
        var wbuf: [16]u8 = undefined;
        var fw = file.writer(testing.io, &wbuf);
        fw.mode = .streaming;
        fw.seek_err = error.Unseekable;
        var enc: Encoder = try .initFile(gpa, &fw, .{ .sample = .u8 }, info);
        try enc.write(&.{ 0.0, 0.5, -0.5 });
        try enc.finish();
        try testing.expect(!enc.sizes_fixed);
    }
    const open = try tmp.dir.readFileAlloc(testing.io, "b.wav", gpa, .limited(1 << 16));
    defer gpa.free(open);
    try testing.expectEqual(@as(usize, 80 + 3), open.len);
    try expectHeaderField(u32, open, 76, 0xFFFFFFFF);
}

test "a failed seek other than Unseekable is WriteFailed" {
    if (!io.has_files) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(testing.io, "c.wav", .{});
    defer file.close(testing.io);
    var wbuf: [16]u8 = undefined;
    var fw = file.writer(testing.io, &wbuf);
    fw.mode = .streaming;
    fw.seek_err = error.AccessDenied;
    const info: codec.Info = .{ .rate = 8000, .channels = 1, .mask = .{ .front_center = true }, .total_frames = null, .bits_per_sample = 16 };
    var enc: Encoder = try .initFile(gpa, &fw, .{}, info);
    try enc.write(&.{0.0});
    try testing.expectError(error.WriteFailed, enc.finish());
    try testing.expect(!enc.sizes_fixed);
}

test "wide samples are written little endian" {
    const gpa = testing.allocator;
    const info: codec.Info = .{ .rate = 8000, .channels = 1, .mask = .{ .front_center = true }, .total_frames = null, .bits_per_sample = 24 };
    const b24 = try encodeAll(gpa, .s24, info, &.{ 0.5, -1.0, 0.25, -0.25 });
    defer gpa.free(b24);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x40, 0x00, 0x00, 0x80, 0x00, 0x00, 0x20, 0x00, 0x00, 0xe0 }, b24[68..]);
    const b32 = try encodeAll(gpa, .s32, info, &.{ 0.5, -1.0, 0.25, -0.25 });
    defer gpa.free(b32);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0x40, 0, 0, 0, 0x80, 0, 0, 0, 0x20, 0, 0, 0, 0xe0 }, b32[68..]);
}

test "a sub format GUID with a wrong tail is unsupported" {
    const head = "RIFF" ++ le(u32, 0) ++ "WAVE";
    const tail = "data" ++ le(u32, 4) ++ le(u32, 0);
    var bad = extFmt(16, 16, 22, 1, 40);
    bad[47] ^= 1;
    try helpers.expectInitError(Decoder, error.Unsupported, head ++ bad ++ tail);
    var bad2 = extFmt(16, 16, 22, 1, 40);
    bad2[33] = 1;
    try helpers.expectInitError(Decoder, error.Unsupported, head ++ bad2 ++ tail);
}

test "decoded samples stay finite and in [-1, 1)" {
    const gpa = testing.allocator;
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const floats = [_]f32{ nan, inf, -inf, 1.0, 0.25, 7e10, -2.0 };
    var data: [floats.len * 4]u8 = undefined;
    for (floats, 0..) |x, i| std.mem.writeInt(u32, data[i * 4 ..][0..4], @bitCast(x), .little);
    const fmt = "fmt " ++ le(u32, 16) ++ le(u16, 3) ++ le(u16, 1) ++ le(u32, 8000) ++ le(u32, 32000) ++ le(u16, 4) ++ le(u16, 32);
    const wav = "RIFF" ++ le(u32, 0) ++ "WAVE" ++ fmt ++ "data" ++ le(u32, data.len) ++ data;
    var input: io.Input = .init(.{ .bytes = wav });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    var out: [floats.len]f32 = undefined;
    try testing.expectEqual(@as(usize, floats.len), try dec.read(&out));
    const top = pcm.max_below_one;
    try testing.expectEqualSlices(f32, &.{ 0.0, top, -1.0, top, 0.25, top, -1.0 }, &out);

    // The s32 range ends at 1 - 2^-31, which rounds to 1.0 in f32 and is clamped below it.
    const s32 = "RIFF" ++ le(u32, 0) ++ "WAVE" ++ "fmt " ++ le(u32, 16) ++ le(u16, 1) ++ le(u16, 1) ++ le(u32, 8000) ++ le(u32, 32000) ++ le(u16, 4) ++ le(u16, 32) ++
        "data" ++ le(u32, 12) ++ le(i32, std.math.maxInt(i32)) ++ le(i32, std.math.minInt(i32)) ++ le(i32, 1 << 30);
    var input2: io.Input = .init(.{ .bytes = s32 });
    var dec2: Decoder = try .init(gpa, &input2);
    defer dec2.deinit();
    var out2: [3]f32 = undefined;
    try testing.expectEqual(@as(usize, 3), try dec2.read(&out2));
    try testing.expectEqualSlices(f32, &.{ top, -1.0, 0.5 }, &out2);
}

test "extensible float decodes from hand built bytes" {
    const gpa = testing.allocator;
    const wav = "RIFF" ++ le(u32, 0) ++ "WAVE" ++ extFmt(32, 32, 22, 3, 40) ++
        "data" ++ le(u32, 8) ++ le(u32, @as(u32, @bitCast(@as(f32, 0.5)))) ++ le(u32, @as(u32, @bitCast(@as(f32, -0.125))));
    var input: io.Input = .init(.{ .bytes = wav });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(u8, 32), dec.info().bits_per_sample);
    try testing.expectEqual(@as(?u64, 1), dec.info().total_frames);
    var out: [4]f32 = undefined;
    try testing.expectEqual(@as(usize, 1), try dec.read(&out));
    try testing.expectEqualSlices(f32, &.{ 0.5, -0.125 }, out[0..2]);
}
