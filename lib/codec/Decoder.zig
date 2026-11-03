//! Decodes WAV, FLAC, Ogg FLAC, Ogg Vorbis and Ogg Opus to interleaved f32 behind one type.
const std = @import("std");
const codec = @import("../codec.zig");
const io = @import("io.zig");
const wav = @import("wav.zig");
const flac = @import("flac.zig");
const ogg = @import("ogg.zig");
const vorbis = @import("vorbis.zig");
const opus = @import("opus.zig");
const helpers = @import("testing.zig");
const testing = std.testing;

const Decoder = @This();

/// The smallest buffer that a reader needs for `.auto` to sniff the format.
pub const min_buffer = 16;

pub const Options = struct {
    flac: flac.Options = .{},
    vorbis: vorbis.Options = .{},
    opus: opus.Options = .{},
};

gpa: std.mem.Allocator,
input: *io.Input,
impl: Impl,

const Impl = union(enum) {
    wav: wav.Decoder,
    flac: flac.Decoder,
    ogg_flac: flac.ogg.Decoder,
    ogg_vorbis: vorbis.Decoder,
    ogg_opus: opus.Decoder,
};

/// Makes a decoder over `source`, which it reads until `deinit`. `.auto` picks the format
/// from the first bytes, which needs a `Source.reader` or `Source.file` buffer of at least
/// `min_buffer` (16) bytes, else error.Unsupported. For Ogg the first packet of the first
/// stream selects the codec, and the decoder reads it through its own buffer. A chained Ogg
/// FLAC, Ogg Vorbis or Ogg Opus file plays as one stream, see `flac.ogg.Decoder`,
/// `vorbis.Decoder` and `opus.Decoder`.
pub fn init(gpa: std.mem.Allocator, source: codec.Source, format: codec.Format) codec.InitError!Decoder {
    return initOptions(gpa, source, format, .{});
}

pub fn initOptions(gpa: std.mem.Allocator, source: codec.Source, format: codec.Format, options: Options) codec.InitError!Decoder {
    const kind = switch (format) {
        .auto => try sniff(source),
        else => format,
    };
    const input = try gpa.create(io.Input);
    errdefer gpa.destroy(input);
    input.* = .init(source);
    const impl: Impl = switch (kind) {
        .wav => .{ .wav = try .init(gpa, input) },
        .flac => .{ .flac = try .initOptions(gpa, input, options.flac) },
        .ogg_flac => .{ .ogg_flac = try .initOptions(gpa, input, options.flac) },
        .ogg_vorbis => .{ .ogg_vorbis = try .initOptions(gpa, input, options.vorbis) },
        .ogg_opus => .{ .ogg_opus = try .initOptions(gpa, input, options.opus) },
        .ogg => try initOgg(gpa, input, options),
        .auto => unreachable,
    };
    return .{ .gpa = gpa, .input = input, .impl = impl };
}

fn isKnownMapping(context: ?*anyopaque, packet: []const u8) bool {
    return flac.ogg.isMapping(context, packet) or vorbis.isIdentification(context, packet) or opus.isHead(context, packet);
}

/// Looks at every begin page before the first data page and hands the first stream with a known
/// mapping to its codec.
fn initOgg(gpa: std.mem.Allocator, input: *io.Input, options: Options) codec.InitError!Impl {
    var reader: ogg.PacketReader = try .init(gpa, input, .{ .accept = .{ .func = isKnownMapping } }, .{ .begin_group_only = true });
    const first = blk: {
        errdefer reader.deinit();
        const packet = reader.next() catch |err| return switch (err) {
            error.BadData => error.BadHeader,
            else => |e| e,
        };
        break :blk packet orelse return error.Unsupported;
    };
    if (vorbis.isIdentification(null, first.data)) {
        return .{ .ogg_vorbis = try .initReader(gpa, input, reader, first.data, options.vorbis) };
    }
    if (opus.isHead(null, first.data)) {
        return .{ .ogg_opus = try .initReader(gpa, input, reader, first.data, options.opus) };
    }
    return .{ .ogg_flac = try .initReader(gpa, input, reader, first.data, options.flac) };
}

pub fn deinit(self: *Decoder) void {
    switch (self.impl) {
        inline else => |*d| d.deinit(),
    }
    self.gpa.destroy(self.input);
    self.* = undefined;
}

/// For a chained Ogg file `info()` changes when `read` gives error.StreamChanged.
pub fn info(self: *const Decoder) codec.Info {
    return switch (self.impl) {
        inline else => |*d| d.info(),
    };
}

/// Writes whole interleaved frames into `out` and returns the frame count. 0 means the end.
/// `out` must hold at least one frame (`info().channels` samples).
///
/// In a chained Ogg file, when the next link has another rate, channel count or channel layout, the
/// call after the last frame of the old link returns error.StreamChanged and no frames.
/// `info()` then describes the new link, and the next call continues with its first frame.
/// Links with the same rate and channel count continue without a signal.
///
/// When the input is seekable and the links are known, entering a later link allocates
/// nothing. On a forward-only input it can allocate, and an out of memory error there gives
/// error.ReadFailed.
pub fn read(self: *Decoder, out: []f32) codec.ReadError!usize {
    return switch (self.impl) {
        inline else => |*d| d.read(out),
    };
}

/// Moves to a frame. A plain reader gives error.Unseekable.
pub fn seek(self: *Decoder, frame: u64) codec.SeekError!void {
    return switch (self.impl) {
        inline else => |*d| d.seek(frame),
    };
}

fn peekReader(r: *std.Io.Reader, n: usize) error{ Short, ReadFailed }![]const u8 {
    if (r.buffer.len < min_buffer) return error.Short;
    return r.peek(n) catch |err| switch (err) {
        error.EndOfStream => error.Short,
        error.ReadFailed => error.ReadFailed,
    };
}

/// A custom source has no buffer, so it is read into `buf` and moved back to the start.
fn peek(source: codec.Source, buf: *[12]u8, n: usize) error{ Short, ReadFailed }![]const u8 {
    switch (source) {
        .bytes => |b| return if (b.len < n) error.Short else b[0..n],
        .reader => |r| return peekReader(r, n),
        .file => |f| return peekReader(&f.interface, n),
        .custom => |c| {
            var got: usize = 0;
            while (got < n) {
                const k = c.read(buf[got..n]) catch return error.ReadFailed;
                if (k == 0) break;
                got += k;
            }
            c.seekTo(0) catch return error.ReadFailed;
            return if (got < n) error.Short else buf[0..n];
        },
    }
}

fn sniff(source: codec.Source) codec.InitError!codec.Format {
    var buf: [12]u8 = undefined;
    const head = peek(source, &buf, 4) catch |err| switch (err) {
        error.Short => return error.Unsupported,
        error.ReadFailed => return error.ReadFailed,
    };
    if (std.mem.eql(u8, head, "fLaC") or std.mem.eql(u8, head[0..3], "ID3")) return .flac;
    if (std.mem.eql(u8, head, "OggS")) return .ogg;
    if (std.mem.eql(u8, head, "RIFF") or std.mem.eql(u8, head, "RF64")) {
        const wave = peek(source, &buf, 12) catch |err| switch (err) {
            error.Short => return error.Unsupported,
            error.ReadFailed => return error.ReadFailed,
        };
        if (std.mem.eql(u8, wave[8..12], "WAVE")) return .wav;
    }
    return error.Unsupported;
}

const flac_vector = helpers.embed("s01-blocksize-4096");
const mono_vector = helpers.embed("s60-mono");
const opus_vector = @embedFile("testdata/opus/stereo48.opus");
const opus_chain = @embedFile("testdata/opus/chain.opus");

fn tinyWav(gpa: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const info_: codec.Info = .{
        .rate = 8000,
        .channels = 1,
        .mask = @bitCast(wav.defaultMask(1)),
        .total_frames = null,
        .bits_per_sample = 0,
    };
    var enc: wav.Encoder = try .init(gpa, &aw.writer, .{ .sample = .s16 }, info_);
    defer enc.deinit();
    try enc.write(&.{ 0.0, 0.5, -0.5, 0.25 });
    try enc.finish();
    return aw.toOwnedSlice();
}

fn muxVorbisLike(gpa: std.mem.Allocator, first: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var w: codec.ogg.PacketWriter = try .init(gpa, &aw.writer, 5, .{});
    defer w.deinit();
    try w.writePacket(first, 0);
    try w.finish();
    return aw.toOwnedSlice();
}

test "auto sniffs WAV" {
    const gpa = testing.allocator;
    const bytes = try tinyWav(gpa);
    defer gpa.free(bytes);
    var dec: Decoder = try .init(gpa, .{ .bytes = bytes }, .auto);
    defer dec.deinit();
    try testing.expect(dec.impl == .wav);
    try testing.expectEqual(@as(u32, 8000), dec.info().rate);
    const got = try helpers.readAll(gpa, &dec, 3);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, &.{ 0.0, 0.5, -0.5, 0.25 }, got);
}

test "auto sniffs native FLAC and matches the format decoder" {
    const gpa = testing.allocator;
    var dec: Decoder = try .init(gpa, .{ .bytes = flac_vector }, .auto);
    defer dec.deinit();
    try testing.expect(dec.impl == .flac);
    const got = try helpers.readAll(gpa, &dec, 4096);
    defer gpa.free(got);

    var input: io.Input = .init(.{ .bytes = flac_vector });
    var direct: flac.Decoder = try .init(gpa, &input);
    defer direct.deinit();
    const buf = try gpa.alloc(f32, got.len);
    defer gpa.free(buf);
    try testing.expectEqual(got.len / 2, try direct.read(buf));
    try testing.expectEqualSlices(f32, buf, got);
}

test "auto sniffs Ogg FLAC, Ogg Vorbis and Ogg Opus" {
    const gpa = testing.allocator;
    const zeros: [34]u8 = @splat(0);
    const header = "\x7fFLAC\x01\x00\x00\x00fLaC" ++ "\x00\x00\x00\x22" ++ zeros;
    const flac_like = try muxVorbisLike(gpa, header);
    defer gpa.free(flac_like);
    // The STREAMINFO is all zero, so the header is refused after it is recognized.
    try testing.expectError(error.BadHeader, Decoder.init(gpa, .{ .bytes = flac_like }, .auto));

    // The channel count is 0, so the identification header is refused after it is recognized.
    const vorbis_like = try muxVorbisLike(gpa, "\x01vorbis" ++ zeros[0..23]);
    defer gpa.free(vorbis_like);
    try testing.expectError(error.BadHeader, Decoder.init(gpa, .{ .bytes = vorbis_like }, .auto));
    // The channel count is 0, so the OpusHead is refused after it is recognized.
    const opus_like = try muxVorbisLike(gpa, "OpusHead\x01\x00" ++ zeros[0..9]);
    defer gpa.free(opus_like);
    try testing.expectError(error.BadHeader, Decoder.init(gpa, .{ .bytes = opus_like }, .auto));
}

fn oggFlacBytes(gpa: std.mem.Allocator, frames: usize) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const info_: codec.Info = .{ .rate = 44100, .channels = 2, .mask = .{}, .total_frames = null, .bits_per_sample = 16 };
    var enc: codec.Encoder = try .init(gpa, &aw.writer, .{ .ogg_flac = .{ .serial = 3 } }, info_);
    defer enc.deinit();
    const samples = try gpa.alloc(f32, frames * 2);
    defer gpa.free(samples);
    for (samples, 0..) |*s, i| s.* = 0.5 * @sin(@as(f32, @floatFromInt(i)) * 0.01);
    try enc.write(samples);
    try enc.finish();
    return aw.toOwnedSlice();
}

test "Ogg is sniffed through the buffer of the Input, not the buffer of the caller" {
    const gpa = testing.allocator;
    const bytes = try oggFlacBytes(gpa, 9000);
    defer gpa.free(bytes);
    var whole: Decoder = try .init(gpa, .{ .bytes = bytes }, .auto);
    defer whole.deinit();
    const want = try helpers.readAll(gpa, &whole, 4096);
    defer gpa.free(want);
    try testing.expectEqual(@as(usize, 18000), want.len);

    // The mapping packet and the first page are bigger than the 16 byte buffer.
    for ([_]codec.Format{ .auto, .ogg }) |format| {
        var buffer: [min_buffer]u8 = undefined;
        var t: Trickle = .init(bytes, &buffer);
        var dec: Decoder = try .init(gpa, .{ .reader = &t.reader }, format);
        defer dec.deinit();
        try testing.expect(dec.impl == .ogg_flac);
        try testing.expectEqual(@as(u8, 2), dec.info().channels);
        const got = try helpers.readAll(gpa, &dec, 100);
        defer gpa.free(got);
        try testing.expectEqualSlices(f32, want, got);
    }
}

test "a long Ogg first packet is unsupported, or a bad header for a known codec" {
    const gpa = testing.allocator;
    var opus_head: [300]u8 = @splat(0);
    @memcpy(opus_head[0..8], "OpusHead");
    var other: [300]u8 = @splat('x');
    const Case = struct { head: []const u8, err: anyerror };
    for ([_]Case{
        .{ .head = &opus_head, .err = error.BadHeader },
        .{ .head = &other, .err = error.Unsupported },
    }) |case| {
        const bytes = try muxVorbisLike(gpa, case.head);
        defer gpa.free(bytes);
        for ([_]codec.Format{ .auto, .ogg }) |format| {
            try testing.expectError(case.err, Decoder.init(gpa, .{ .bytes = bytes }, format));
        }
    }
}

test "a Skeleton stream before the FLAC stream is skipped" {
    const gpa = testing.allocator;
    const flac_bytes = try oggFlacBytes(gpa, 9000);
    defer gpa.free(flac_bytes);
    var want_dec: Decoder = try .init(gpa, .{ .bytes = flac_bytes }, .auto);
    defer want_dec.deinit();
    const want = try helpers.readAll(gpa, &want_dec, 4096);
    defer gpa.free(want);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    {
        var w: codec.ogg.PacketWriter = try .init(gpa, &aw.writer, 77, .{});
        defer w.deinit();
        var head: [64]u8 = @splat(0);
        @memcpy(head[0..8], "fishead\x00");
        try w.writePacket(&head, 0);
        try w.flush();
    }
    try aw.writer.writeAll(flac_bytes);
    const bytes = aw.written();
    for ([_]codec.Format{ .auto, .ogg }) |format| {
        var dec: Decoder = try .init(gpa, .{ .bytes = bytes }, format);
        defer dec.deinit();
        try testing.expect(dec.impl == .ogg_flac);
        const got = try helpers.readAll(gpa, &dec, 4096);
        defer gpa.free(got);
        try testing.expectEqualSlices(f32, want, got);
    }
}

test "an unknown Ogg codec or a bad OpusHead does not read the whole input" {
    const gpa = testing.allocator;
    const Case = struct { magic: []const u8, err: anyerror };
    for ([_]Case{
        .{ .magic = "Speex   ", .err = error.Unsupported },
        .{ .magic = "OpusHead", .err = error.BadHeader },
    }) |case| try expectNoFullRead(gpa, case.magic, case.err);
}

fn expectNoFullRead(gpa: std.mem.Allocator, magic: []const u8, want: anyerror) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var w: codec.ogg.PacketWriter = try .init(gpa, &aw.writer, 5, .{});
    defer w.deinit();
    var head: [300]u8 = @splat(0);
    @memcpy(head[0..8], magic);
    try w.writePacket(&head, 0);
    try w.flush();
    const chunk: [4000]u8 = @splat(7);
    try w.writePacket(&chunk, 4000);
    try w.flush();
    const second_end = aw.written().len;
    for (0..1000) |i| try w.writePacket(&chunk, @intCast(8000 + i * 4000));
    try w.finish();
    const bytes = aw.written();
    try testing.expect(bytes.len > 3_000_000);

    for ([_]codec.Format{ .auto, .ogg }) |format| {
        var buffer: [min_buffer]u8 = undefined;
        var t: Trickle = .init(bytes, &buffer);
        try testing.expectError(want, Decoder.init(gpa, .{ .reader = &t.reader }, format));
        // The page window may read ahead by up to one page.
        try testing.expect(t.pos <= second_end + ogg.max_page_size);
    }
}

test "the Ogg format refuses input that is not Ogg" {
    const gpa = testing.allocator;
    try testing.expectError(error.Unsupported, Decoder.init(gpa, .{ .bytes = flac_vector }, .ogg));
    try testing.expectError(error.Unsupported, Decoder.init(gpa, .{ .bytes = "" }, .ogg));
}

test "a custom source decodes every format and seeks" {
    const gpa = testing.allocator;
    const wav_bytes = try tinyWav(gpa);
    defer gpa.free(wav_bytes);
    const ogg_bytes = try oggFlacBytes(gpa, 9000);
    defer gpa.free(ogg_bytes);
    const Case = struct { bytes: []const u8, tag: std.meta.Tag(Impl) };
    for ([_]Case{
        .{ .bytes = wav_bytes, .tag = .wav },
        .{ .bytes = flac_vector, .tag = .flac },
        .{ .bytes = ogg_bytes, .tag = .ogg_flac },
        .{ .bytes = vorbis_vector, .tag = .ogg_vorbis },
        .{ .bytes = opus_vector, .tag = .ogg_opus },
    }) |case| {
        var whole: Decoder = try .init(gpa, .{ .bytes = case.bytes }, .auto);
        defer whole.deinit();
        const want = try helpers.readAll(gpa, &whole, 4096);
        defer gpa.free(want);

        var mem: helpers.MemorySource = .{ .data = case.bytes };
        const src = mem.source();
        var dec: Decoder = try .init(gpa, .{ .custom = &src }, .auto);
        defer dec.deinit();
        try testing.expect(dec.impl == case.tag);
        const got = try helpers.readAll(gpa, &dec, 4096);
        defer gpa.free(got);
        try testing.expectEqualSlices(f32, want, got);
        const channels: usize = dec.info().channels;
        try dec.seek(1);
        const tail = try helpers.readAll(gpa, &dec, 4096);
        defer gpa.free(tail);
        try testing.expectEqualSlices(f32, want[channels..], tail);
        try testing.expect(mem.seeks > 0);
    }
}

test "initOptions passes the FLAC options to the decoder" {
    const gpa = testing.allocator;
    const copy = try gpa.dupe(u8, flac_vector);
    defer gpa.free(copy);
    // The last frame of the six.
    copy[copy.len - 20] ^= 0x55;
    var dec: Decoder = try .init(gpa, .{ .bytes = copy }, .auto);
    defer dec.deinit();
    const got = try helpers.readAll(gpa, &dec, 4096);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 5 * 4096 * 2), got.len);
    try testing.expectEqual(@as(u32, 1), dec.impl.flac.stats().resyncs);

    var strict: Decoder = try .initOptions(gpa, .{ .bytes = copy }, .auto, .{ .flac = .{ .on_bad_frame = .fail } });
    defer strict.deinit();
    try testing.expectError(error.BadData, helpers.readAll(gpa, &strict, 4096));
}

test "auto refuses unknown and short input" {
    const gpa = testing.allocator;
    try testing.expectError(error.Unsupported, Decoder.init(gpa, .{ .bytes = "" }, .auto));
    try testing.expectError(error.Unsupported, Decoder.init(gpa, .{ .bytes = "fL" }, .auto));
    try testing.expectError(error.Unsupported, Decoder.init(gpa, .{ .bytes = "plain text, not audio" }, .auto));
    try testing.expectError(error.Unsupported, Decoder.init(gpa, .{ .bytes = "RIFF\x00\x00\x00\x00AVI " }, .auto));
    try testing.expectError(error.Unsupported, Decoder.init(gpa, .{ .bytes = "RIFF\x00\x00" }, .auto));
}

test "an explicit format skips the sniff" {
    const gpa = testing.allocator;
    try testing.expectError(error.BadHeader, Decoder.init(gpa, .{ .bytes = flac_vector }, .wav));
    var dec: Decoder = try .init(gpa, .{ .bytes = mono_vector }, .flac);
    defer dec.deinit();
    try testing.expect(dec.impl == .flac);
}

test "sniffing works over a forward reader without losing bytes" {
    const gpa = testing.allocator;
    var reader: std.Io.Reader = .fixed(flac_vector);
    var dec: Decoder = try .init(gpa, .{ .reader = &reader }, .auto);
    defer dec.deinit();
    try testing.expectError(error.Unseekable, dec.seek(1));
    const got = try helpers.readAll(gpa, &dec, 7);
    defer gpa.free(got);

    var whole: Decoder = try .init(gpa, .{ .bytes = flac_vector }, .auto);
    defer whole.deinit();
    const want = try helpers.readAll(gpa, &whole, 4096);
    defer gpa.free(want);
    try testing.expectEqualSlices(f32, want, got);
}

test "seek through the front end" {
    const gpa = testing.allocator;
    var dec: Decoder = try .init(gpa, .{ .bytes = flac_vector }, .auto);
    defer dec.deinit();
    const all = try helpers.readAll(gpa, &dec, 4096);
    defer gpa.free(all);
    try dec.seek(1000);
    const tail = try helpers.readAll(gpa, &dec, 500);
    defer gpa.free(tail);
    try testing.expectEqualSlices(f32, all[2000..], tail);
}

/// A reader with a chosen buffer size over a byte slice.
const Trickle = struct {
    data: []const u8,
    pos: usize = 0,
    reader: std.Io.Reader,

    fn init(data: []const u8, buffer: []u8) Trickle {
        return .{ .data = data, .reader = .{
            .vtable = &.{ .stream = stream },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        } };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Trickle = @alignCast(@fieldParentPtr("reader", r));
        if (self.pos >= self.data.len) return error.EndOfStream;
        const n = @min(@backingInt(limit), self.data.len - self.pos);
        try w.writeAll(self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
};

test "a reader with a buffer under 16 bytes cannot sniff" {
    const gpa = testing.allocator;
    const bytes = try tinyWav(gpa);
    defer gpa.free(bytes);
    var small: [4]u8 = undefined;
    var t: Trickle = .init(bytes, &small);
    try testing.expectError(error.Unsupported, Decoder.init(gpa, .{ .reader = &t.reader }, .auto));

    var enough: [16]u8 = undefined;
    var t2: Trickle = .init(bytes, &enough);
    var dec: Decoder = try .init(gpa, .{ .reader = &t2.reader }, .auto);
    defer dec.deinit();
    try testing.expect(dec.impl == .wav);
    const got = try helpers.readAll(gpa, &dec, 2);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, &.{ 0.0, 0.5, -0.5, 0.25 }, got);
}

test "auto sniffs RF64" {
    const gpa = testing.allocator;
    const rf64 = "RF64\xff\xff\xff\xffWAVE" ++
        "ds64\x1c\x00\x00\x00" ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x08\x00\x00\x00\x00\x00\x00\x00" ++ "\x04\x00\x00\x00\x00\x00\x00\x00" ++ "\x00\x00\x00\x00" ++
        "fmt \x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x80\x3e\x00\x00\x02\x00\x10\x00" ++
        "data\xff\xff\xff\xff" ++ "\x00\x00\x00\x40\x00\xc0\x00\x20";
    var dec: Decoder = try .init(gpa, .{ .bytes = rf64 }, .auto);
    defer dec.deinit();
    try testing.expect(dec.impl == .wav);
    try testing.expectEqual(@as(?u64, 4), dec.info().total_frames);
    const got = try helpers.readAll(gpa, &dec, 4);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, &.{ 0.0, 0.5, -0.5, 0.25 }, got);
}

test "auto sniffs a FLAC file behind an ID3v2 tag" {
    const gpa = testing.allocator;
    const tagged = try std.mem.concat(gpa, u8, &.{ "ID3\x04\x00\x00\x00\x00\x00\x0a", "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", flac_vector });
    defer gpa.free(tagged);
    var dec: Decoder = try .init(gpa, .{ .bytes = tagged }, .auto);
    defer dec.deinit();
    try testing.expect(dec.impl == .flac);
    const got = try helpers.readAll(gpa, &dec, 4096);
    defer gpa.free(got);

    var plain: Decoder = try .init(gpa, .{ .bytes = flac_vector }, .auto);
    defer plain.deinit();
    const want = try helpers.readAll(gpa, &plain, 4096);
    defer gpa.free(want);
    try testing.expectEqualSlices(f32, want, got);

    const hostile = "ID3\x04\x00\x00\x7f\x7f\x7f\x7fshort";
    try testing.expectError(error.Truncated, Decoder.init(gpa, .{ .bytes = hostile }, .auto));
}

const vorbis_vector = @embedFile("testdata/vorbis/stereo44.ogg");
const vorbis_chain = @embedFile("testdata/vorbis/chain.ogg");

test "auto, ogg and ogg_vorbis open Ogg Vorbis and match the format decoder" {
    const gpa = testing.allocator;
    var direct_input: io.Input = .init(.{ .bytes = vorbis_vector });
    var direct: vorbis.Decoder = try .init(gpa, &direct_input);
    defer direct.deinit();
    const want = try helpers.readAll(gpa, &direct, 4096);
    defer gpa.free(want);
    try testing.expectEqual(@as(usize, 44100 * 2), want.len);
    for ([_]codec.Format{ .auto, .ogg, .ogg_vorbis }) |format| {
        var dec: Decoder = try .init(gpa, .{ .bytes = vorbis_vector }, format);
        defer dec.deinit();
        try testing.expect(dec.impl == .ogg_vorbis);
        try testing.expectEqual(@as(u32, 44100), dec.info().rate);
        const got = try helpers.readAll(gpa, &dec, 1000);
        defer gpa.free(got);
        try testing.expectEqualSlices(f32, want, got);
    }
}

test "Ogg Vorbis is sniffed through the buffer of the Input" {
    const gpa = testing.allocator;
    var whole: Decoder = try .init(gpa, .{ .bytes = vorbis_vector }, .auto);
    defer whole.deinit();
    const want = try helpers.readAll(gpa, &whole, 4096);
    defer gpa.free(want);
    for ([_]codec.Format{ .auto, .ogg, .ogg_vorbis }) |format| {
        var buffer: [min_buffer]u8 = undefined;
        var t: Trickle = .init(vorbis_vector, &buffer);
        var dec: Decoder = try .init(gpa, .{ .reader = &t.reader }, format);
        defer dec.deinit();
        try testing.expect(dec.impl == .ogg_vorbis);
        const got = try helpers.readAll(gpa, &dec, 100);
        defer gpa.free(got);
        try testing.expectEqualSlices(f32, want, got);
    }
}

test "an explicit Ogg format refuses the other Ogg codec" {
    const gpa = testing.allocator;
    const flac_bytes = try oggFlacBytes(gpa, 9000);
    defer gpa.free(flac_bytes);
    try testing.expectError(error.Unsupported, Decoder.init(gpa, .{ .bytes = flac_bytes }, .ogg_vorbis));
    try testing.expectError(error.Unsupported, Decoder.init(gpa, .{ .bytes = vorbis_vector }, .ogg_flac));
    try testing.expectError(error.Unsupported, Decoder.init(gpa, .{ .bytes = flac_vector }, .ogg_vorbis));
}

test "initOptions passes the Vorbis options to the decoder" {
    const gpa = testing.allocator;
    const small: Options = .{ .vorbis = .{ .max_setup_bytes = 100 } };
    try testing.expectError(error.BadHeader, Decoder.initOptions(gpa, .{ .bytes = vorbis_vector }, .auto, small));
    try testing.expectError(error.BadHeader, Decoder.initOptions(gpa, .{ .bytes = vorbis_vector }, .ogg_vorbis, small));
}

test "a chained Ogg Vorbis file gives StreamChanged through the front end" {
    const gpa = testing.allocator;
    var dec: Decoder = try .init(gpa, .{ .bytes = vorbis_chain }, .auto);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 22050 + 11025), dec.info().total_frames);
    var buf: [2048]f32 = undefined;
    var first: usize = 0;
    while (true) {
        const n = dec.read(&buf) catch |err| {
            try testing.expectEqual(error.StreamChanged, err);
            break;
        };
        try testing.expect(n != 0);
        first += n;
    }
    try testing.expectEqual(@as(usize, 22050), first);
    try testing.expectEqual(@as(u8, 1), dec.info().channels);
    var second: usize = 0;
    while (true) {
        const n = try dec.read(&buf);
        if (n == 0) break;
        second += n;
    }
    try testing.expectEqual(@as(usize, 11025), second);
    try dec.seek(22050 + 100);
    try testing.expectEqual(@as(usize, 11025 - 100), try countFrames(&dec));
}

fn countFrames(dec: *Decoder) !usize {
    var buf: [1024]f32 = undefined;
    var frames: usize = 0;
    while (true) {
        const n = try dec.read(&buf);
        if (n == 0) return frames;
        frames += n;
    }
}

test "a Skeleton stream before the Vorbis stream is skipped" {
    const gpa = testing.allocator;
    var plain: Decoder = try .init(gpa, .{ .bytes = vorbis_vector }, .auto);
    defer plain.deinit();
    const want = try helpers.readAll(gpa, &plain, 4096);
    defer gpa.free(want);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    {
        var w: codec.ogg.PacketWriter = try .init(gpa, &aw.writer, 77, .{});
        defer w.deinit();
        var head: [64]u8 = @splat(0);
        @memcpy(head[0..8], "fishead\x00");
        try w.writePacket(&head, 0);
        try w.flush();
    }
    try aw.writer.writeAll(vorbis_vector);
    for ([_]codec.Format{ .auto, .ogg, .ogg_vorbis }) |format| {
        var dec: Decoder = try .init(gpa, .{ .bytes = aw.written() }, format);
        defer dec.deinit();
        try testing.expect(dec.impl == .ogg_vorbis);
        const got = try helpers.readAll(gpa, &dec, 4096);
        defer gpa.free(got);
        try testing.expectEqualSlices(f32, want, got);
    }
}

test "a Vorbis first packet with garbage fails without reading the whole input" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var w: codec.ogg.PacketWriter = try .init(gpa, &aw.writer, 5, .{});
    defer w.deinit();
    var head: [300]u8 = @splat(0);
    @memcpy(head[0..7], "\x01vorbis");
    try w.writePacket(&head, 0);
    try w.flush();
    const chunk: [4000]u8 = @splat(7);
    try w.writePacket(&chunk, 4000);
    try w.flush();
    const second_end = aw.written().len;
    for (0..1000) |i| try w.writePacket(&chunk, @intCast(8000 + i * 4000));
    try w.finish();
    const bytes = aw.written();
    try testing.expect(bytes.len > 3_000_000);

    for ([_]codec.Format{ .auto, .ogg, .ogg_vorbis }) |format| {
        var buffer: [min_buffer]u8 = undefined;
        var t: Trickle = .init(bytes, &buffer);
        try testing.expectError(error.BadHeader, Decoder.init(gpa, .{ .reader = &t.reader }, format));
        try testing.expect(t.pos <= second_end + ogg.max_page_size);
    }
}

test "auto, ogg and ogg_opus open an Ogg Opus file and match the format decoder" {
    const gpa = testing.allocator;
    var input: io.Input = .init(.{ .bytes = opus_vector });
    var direct: opus.Decoder = try .init(gpa, &input);
    defer direct.deinit();
    const want = try helpers.readAll(gpa, &direct, 4096);
    defer gpa.free(want);
    try testing.expectEqual(@as(usize, 48000 * 2), want.len);

    for ([_]codec.Format{ .auto, .ogg, .ogg_opus }) |format| {
        var dec: Decoder = try .init(gpa, .{ .bytes = opus_vector }, format);
        defer dec.deinit();
        try testing.expect(dec.impl == .ogg_opus);
        try testing.expectEqual(@as(u32, 48000), dec.info().rate);
        try testing.expectEqual(@as(?u64, 48000), dec.info().total_frames);
        const got = try helpers.readAll(gpa, &dec, 4096);
        defer gpa.free(got);
        try testing.expectEqualSlices(f32, want, got);
    }
    // A forward-only reader with a buffer of the minimum size.
    var buffer: [min_buffer]u8 = undefined;
    var t: Trickle = .init(opus_vector, &buffer);
    var dec: Decoder = try .init(gpa, .{ .reader = &t.reader }, .auto);
    defer dec.deinit();
    try testing.expect(dec.impl == .ogg_opus);
    const got = try helpers.readAll(gpa, &dec, 4096);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, want, got);
    try testing.expectError(error.Unsupported, Decoder.init(gpa, .{ .bytes = vorbis_vector }, .ogg_opus));
}

test "a chained Ogg Opus file reports the format change through the front end" {
    const gpa = testing.allocator;
    var dec: Decoder = try .init(gpa, .{ .bytes = opus_chain }, .auto);
    defer dec.deinit();
    try testing.expectEqual(@as(u8, 2), dec.info().channels);
    var buf: [2000]f32 = undefined;
    var frames: usize = 0;
    var changes: usize = 0;
    while (true) {
        const width: usize = dec.info().channels;
        const n = dec.read(buf[0 .. 1000 / width * width]) catch |err| switch (err) {
            error.StreamChanged => {
                changes += 1;
                continue;
            },
            else => return err,
        };
        if (n == 0) break;
        frames += n;
    }
    try testing.expectEqual(@as(usize, 1), changes);
    try testing.expectEqual(@as(usize, 48000), frames);
    try testing.expectEqual(@as(u8, 1), dec.info().channels);
}
