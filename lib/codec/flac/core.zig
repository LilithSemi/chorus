//! The frame decoder behind `decode.Decoder` and `ogg.Decoder`. It reads a native FLAC
//! stream, or it takes frames as separate packets. Memory is allocated at init and on
//! seek only.
const std = @import("std");
const codec = @import("../../codec.zig");
const io = @import("../io.zig");
const crc = @import("../crc.zig");
const wav = @import("../wav.zig");
const pcm = @import("../pcm.zig");
const vorbis_comment = @import("../vorbis_comment.zig");
const Md5Stage = @import("md5.zig").Stage;

/// The errors of decoding frames. `codec.ReadError` adds the change of stream.
pub const FrameError = codec.DecodeError;

pub const BadFramePolicy = enum {
    /// A frame that fails is skipped. The decoder looks for the next frame that has a valid
    /// header and a valid CRC, and goes on there. The samples of the lost frame are not
    /// replaced by anything.
    resync,
    /// A frame that fails gives error.BadData.
    fail,
};

pub const Options = struct {
    /// A frame fails with a wrong CRC or with data that is not a frame. A stream that ends
    /// inside a frame always gives error.Truncated.
    ///
    /// A scan for the next frame can read to the end of the input when no later frame matches.
    on_bad_frame: BadFramePolicy = .resync,
    /// Turn a frame larger than the STREAMINFO maximum and samples beyond a nonzero
    /// STREAMINFO total into a bad frame. By default they are only counted.
    /// Without it, `read` can return more frames than `info().total_frames`.
    /// Such a frame gives error.BadData with every `on_bad_frame` policy. Only a frame that
    /// is corrupt, for example with a wrong CRC, is skipped by `.resync`.
    strict_metadata: bool = false,
};

pub const Stats = struct {
    /// Frames that failed with a wrong CRC-16.
    crc_errors: u32 = 0,
    /// Times that the decoder skipped a bad frame and looked for the next one.
    resyncs: u32 = 0,
    /// Bytes skipped by `resyncs`.
    skipped_bytes: u64 = 0,
    /// Frames larger than the STREAMINFO maximum frame size.
    oversized_frames: u32 = 0,
    /// Samples decoded beyond the STREAMINFO total.
    excess_samples: u64 = 0,
    /// Samples that the stereo decorrelation put outside the sample depth. `readInt` clamps
    /// them to the depth and `read` clamps them to [-1, 1).
    clipped_samples: u64 = 0,
    /// Seeks done on the Input.
    input_seeks: u32 = 0,
};

pub const SeekPoint = struct {
    sample: u64,
    /// Bytes from the first frame header.
    offset: u64,
};

const store_size = 16 * 1024;

const bisect_limit = 32 * 1024;
const min_block_size = 16;

const placeholder: u64 = std.math.maxInt(u64);

const StreamInfo = struct {
    min_block: u32,
    max_block: u32,
    min_frame: u32,
    max_frame: u32,
    rate: u32,
    channels: u8,
    bps: u8,
    /// 0 means unknown.
    total: u64,
    md5: [16]u8,
};

const Meta = struct {
    si: StreamInfo,
    mask: u32,
    seek_points: []SeekPoint,
    first_frame: u64,
};

/// A comment block bigger than this is skipped, and its channel mask is not read.
const max_comment_block = 1 << 20;

/// Reads a VORBIS_COMMENT block of `len` bytes and returns its channel mask, if it has one.
fn readCommentBlock(gpa: std.mem.Allocator, input: *io.Input, len: u32) codec.InitError!?u32 {
    if (len > max_comment_block) {
        try input.skip(len);
        return null;
    }
    const body = try gpa.alloc(u8, len);
    defer gpa.free(body);
    try input.readExact(body);
    return vorbis_comment.channelMask(body);
}

pub fn parseStreamInfo(body: *const [34]u8) codec.InitError!StreamInfo {
    const tail = std.mem.readInt(u64, body[10..18], .big);
    const si: StreamInfo = .{
        .min_block = std.mem.readInt(u16, body[0..2], .big),
        .max_block = std.mem.readInt(u16, body[2..4], .big),
        .min_frame = std.mem.readInt(u24, body[4..7], .big),
        .max_frame = std.mem.readInt(u24, body[7..10], .big),
        .rate = @intCast(tail >> 44),
        .channels = @intCast(((tail >> 41) & 7) + 1),
        .bps = @intCast(((tail >> 36) & 31) + 1),
        .total = tail & ((@as(u64, 1) << 36) - 1),
        .md5 = body[18..34].*,
    };
    if (si.min_block < min_block_size or si.max_block < si.min_block) return error.BadHeader;
    if (si.rate == 0 or si.bps < 4) return error.BadHeader;
    return si;
}

fn streamInfo(si: StreamInfo, mask: u32) codec.Info {
    return .{
        .rate = si.rate,
        .channels = si.channels,
        .mask = @bitCast(mask),
        .total_frames = if (si.total != 0) si.total else null,
        .bits_per_sample = si.bps,
    };
}

/// The rate and the channel count in the body of a STREAMINFO block.
pub fn streamShape(streaminfo: *const [34]u8) struct { rate: u32, channels: u8 } {
    const tail = std.mem.readInt(u64, streaminfo[10..18], .big);
    return .{ .rate = @intCast(tail >> 44), .channels = @intCast(((tail >> 41) & 7) + 1) };
}

fn finalMask(channels: u8, mask: ?u32) u32 {
    const default = wav.defaultMask(channels);
    const m = mask orelse return default;
    return if (@popCount(m) == channels) m else default;
}

fn readMetadata(gpa: std.mem.Allocator, input: *io.Input) codec.InitError!Meta {
    var magic: [4]u8 = undefined;
    try input.readExact(&magic);
    if (std.mem.eql(u8, magic[0..3], "ID3")) {
        var rest: [6]u8 = undefined;
        try input.readExact(&rest);
        var size: u64 = 0;
        for (rest[2..6]) |b| {
            if (b & 0x80 != 0) return error.BadHeader;
            size = (size << 7) | b;
        }
        if (rest[1] & 0x10 != 0) size += 10;
        try input.skip(size);
        try input.readExact(&magic);
    }
    if (!std.mem.eql(u8, &magic, "fLaC")) return error.Unsupported;

    var points: std.ArrayList(SeekPoint) = .empty;
    errdefer points.deinit(gpa);
    var si: ?StreamInfo = null;
    var mask: ?u32 = null;
    var have_seektable = false;
    while (true) {
        var h: [4]u8 = undefined;
        try input.readExact(&h);
        const last = h[0] & 0x80 != 0;
        const kind = h[0] & 0x7f;
        const len = std.mem.readInt(u24, h[1..4], .big);
        if (kind == 127) return error.BadHeader;
        if ((si == null) != (kind == 0)) return error.BadHeader;
        switch (kind) {
            0 => {
                if (len != 34) return error.BadHeader;
                var body: [34]u8 = undefined;
                try input.readExact(&body);
                si = try parseStreamInfo(&body);
            },
            3 => {
                if (have_seektable or len % 18 != 0) return error.BadHeader;
                have_seektable = true;
                var prev: ?u64 = null;
                for (0..len / 18) |_| {
                    var p: [18]u8 = undefined;
                    try input.readExact(&p);
                    const sample = std.mem.readInt(u64, p[0..8], .big);
                    if (sample == placeholder) continue;
                    if (prev) |q| {
                        if (sample <= q) return error.BadHeader;
                    }
                    prev = sample;
                    try points.append(gpa, .{ .sample = sample, .offset = std.mem.readInt(u64, p[8..16], .big) });
                }
            },
            4 => mask = try readCommentBlock(gpa, input, len),
            else => try input.skip(len),
        }
        if (last) break;
    }
    const stream = si.?;
    return .{
        .si = stream,
        .mask = finalMask(stream.channels, mask),
        .seek_points = try points.toOwnedSlice(gpa),
        .first_frame = input.position(),
    };
}

const Assignment = enum { independent, left_side, right_side, mid_side };

const Header = struct {
    block_size: u32,
    channels: u8,
    assignment: Assignment,
    sample: u64,
};

/// Reads FLAC frames from an Input.
pub const Core = struct {
    gpa: std.mem.Allocator,
    input: *io.Input,
    options: Options,
    stream: codec.Info,
    si: StreamInfo,
    seek_points: []SeekPoint,
    first_frame: u64,
    bits: io.BitReader,
    store: []u8,
    samples: []i64,
    block_len: usize = 0,
    block_pos: usize = 0,
    /// Stream sample number after the last decoded frame.
    next_sample: u64 = 0,
    failed: ?FrameError = null,
    short_seen: bool = false,
    /// The next frame follows a skipped one, so its number gives `next_sample`.
    resync_next: bool = false,
    /// The last frame failed because it broke a limit of the metadata under `strict_metadata`.
    strict_hit: bool = false,
    /// The frame number of the first frame minus the position in the stream.
    origin: u64 = 0,
    stats_: Stats = .{},
    at_end: bool = false,
    frame_sample: u64 = 0,
    md5: Md5Stage = .{},
    md5_valid: bool,
    md5_result: ?bool = null,

    pub fn init(gpa: std.mem.Allocator, input: *io.Input) codec.InitError!Core {
        return initOptions(gpa, input, .{});
    }

    pub fn initOptions(gpa: std.mem.Allocator, input: *io.Input, options: Options) codec.InitError!Core {
        const meta = try readMetadata(gpa, input);
        errdefer gpa.free(meta.seek_points);
        const store = try gpa.alloc(u8, store_size);
        errdefer gpa.free(store);
        return build(gpa, input, options, meta, store, .initInput(input, store));
    }

    /// Makes a decoder for frames that come as separate byte slices, such as Ogg packets.
    /// `streaminfo` is the STREAMINFO block body. The decoder has no seek table and does
    /// not touch `input`. Feed it with `loadPacket`.
    pub fn initPackets(
        gpa: std.mem.Allocator,
        input: *io.Input,
        streaminfo: *const [34]u8,
        comment_mask: ?u32,
        options: Options,
    ) codec.InitError!Core {
        const si = try parseStreamInfo(streaminfo);
        const meta: Meta = .{
            .si = si,
            .mask = finalMask(si.channels, comment_mask),
            .seek_points = &.{},
            .first_frame = 0,
        };
        return build(gpa, input, options, meta, &.{}, .initBytes(&.{}));
    }

    /// Starts a new stream in a decoder made by `initPackets`. It keeps the options and the
    /// stats, and it reuses the sample buffer when that is big enough.
    pub fn resetStream(self: *Core, streaminfo: *const [34]u8, comment_mask: ?u32) codec.InitError!void {
        const si = try parseStreamInfo(streaminfo);
        const need = @as(usize, si.channels) * si.max_block;
        if (need > self.samples.len) {
            const bigger = try self.gpa.alloc(i64, need);
            self.gpa.free(self.samples);
            self.samples = bigger;
        }
        self.si = si;
        self.stream = streamInfo(si, finalMask(si.channels, comment_mask));
        self.block_len = 0;
        self.block_pos = 0;
        self.next_sample = 0;
        self.failed = null;
        self.short_seen = false;
        self.at_end = false;
        self.frame_sample = 0;
        self.md5 = .{};
        self.md5_valid = !std.mem.allEqual(u8, &si.md5, 0);
        self.md5_result = null;
    }

    /// Makes the sample buffer big enough for the stream in `streaminfo`, so `resetStream` for
    /// that stream does not allocate.
    pub fn reserveSamples(self: *Core, streaminfo: *const [34]u8) codec.InitError!void {
        const si = try parseStreamInfo(streaminfo);
        const need = @as(usize, si.channels) * si.max_block;
        if (need <= self.samples.len) return;
        const bigger = try self.gpa.alloc(i64, need);
        self.gpa.free(self.samples);
        self.samples = bigger;
    }

    /// The sample number and the block size in the header of the frame in `packet`. Null when
    /// the header is bad.
    pub fn peekFrame(self: *Core, packet: []const u8) ?struct { sample: u64, block: u32 } {
        if (packet.len == 0 or packet[0] != 0xff) return null;
        const short_seen = self.short_seen;
        defer self.short_seen = short_seen;
        self.short_seen = false;
        self.bits = .initBytes(packet);
        self.bits.crcStart();
        const h = self.readHeader() catch return null;
        return .{ .sample = h.sample, .block = h.block_size };
    }

    fn build(
        gpa: std.mem.Allocator,
        input: *io.Input,
        options: Options,
        meta: Meta,
        store: []u8,
        bits: io.BitReader,
    ) codec.InitError!Core {
        const si = meta.si;
        const samples = try gpa.alloc(i64, @as(usize, si.channels) * si.max_block);
        return .{
            .gpa = gpa,
            .input = input,
            .options = options,
            .stream = streamInfo(si, meta.mask),
            .si = si,
            .seek_points = meta.seek_points,
            .first_frame = meta.first_frame,
            .bits = bits,
            .store = store,
            .samples = samples,
            .md5_valid = !std.mem.allEqual(u8, &si.md5, 0),
        };
    }

    pub fn deinit(self: *Core) void {
        self.gpa.free(self.samples);
        self.gpa.free(self.store);
        self.gpa.free(self.seek_points);
        self.* = undefined;
    }

    pub fn info(self: *const Core) codec.Info {
        return self.stream;
    }

    /// The seek points of the stream, without placeholders.
    pub fn seekPoints(self: *const Core) []const SeekPoint {
        return self.seek_points;
    }

    pub fn stats(self: *const Core) Stats {
        return self.stats_;
    }

    /// After the end of the stream: whether the decoded samples match the MD5 of the
    /// STREAMINFO. Null before the end, after a seek, or when the stream has no MD5.
    pub fn md5Matches(self: *const Core) ?bool {
        return self.md5_result;
    }

    pub fn chan(self: *Core, c: usize) []i64 {
        const max: usize = self.si.max_block;
        return self.samples[c * max ..][0..max];
    }

    /// Writes whole frames of f32 into `out` and returns the frame count. 0 means the end.
    /// `out` must hold at least one frame (`info().channels` samples).
    /// When the stream has more samples than the STREAMINFO total and `Options.strict_metadata`
    /// is off, the frames past the total are returned too.
    pub fn read(self: *Core, out: []f32) FrameError!usize {
        return self.readAs(f32, out);
    }

    /// Like `read`, with the integer sample values.
    pub fn readInt(self: *Core, out: []i32) FrameError!usize {
        return self.readAs(i32, out);
    }

    fn readAs(self: *Core, comptime T: type, out: []T) FrameError!usize {
        return self.readLoop(T, out, self);
    }

    /// The copy loop of `read`. `loader.loadBlock()` decodes the next frame into the
    /// block and returns false at the end of the data.
    pub fn readLoop(self: *Core, comptime T: type, out: []T, loader: anytype) FrameError!usize {
        const channels: usize = self.si.channels;
        std.debug.assert(out.len >= channels);
        const want = out.len / channels;
        var done: usize = 0;
        while (done < want) {
            if (self.block_pos == self.block_len) {
                const more = loader.loadBlock() catch |err| {
                    if (done > 0) return done;
                    return err;
                };
                if (!more) break;
            }
            // A chained stream can change the depth between blocks.
            const half: i64 = @as(i64, 1) << @intCast(self.si.bps - 1);
            const scale: f64 = 1.0 / @as(f64, @floatFromInt(half));
            const take = @min(want - done, self.block_len - self.block_pos);
            for (0..channels) |c| {
                const src = self.chan(c)[self.block_pos..][0..take];
                for (src, 0..) |v, i| {
                    out[(done + i) * channels + c] = if (T == f32)
                        pcm.clampUnit(@floatCast(@as(f64, @floatFromInt(v)) * scale))
                    else
                        @intCast(std.math.clamp(v, -half, half - 1));
                }
            }
            done += take;
            self.block_pos += take;
        }
        return done;
    }

    const Mode = enum {
        /// Decode the next frame and count the problems in the stats.
        read,
        /// Pass a frame during a seek.
        walk,
        /// Check a frame during a seek: a CRC mismatch is an error and the metadata is not checked.
        probe,
        /// Like `read`, for a frame that is found after a skipped one. It takes its position
        /// from the frame number.
        scan,
    };

    const Point = struct { pos: u64, sample: u64 };

    fn bitsSeek(self: *Core, at: u64) io.Input.SeekError!void {
        if (self.bits.moveTo(at)) return;
        try self.input.seekTo(at);
        self.bits.reset();
        self.stats_.input_seeks +|= 1;
    }

    /// Moves to a frame. `frame` equal to the frame count is the end of the data.
    pub fn seek(self: *Core, frame: u64) codec.SeekError!void {
        if (!self.input.seekable()) return error.Unseekable;
        self.seekInner(frame) catch |err| {
            self.block_len = 0;
            self.block_pos = 0;
            self.next_sample = 0;
            self.failed = switch (err) {
                error.BadData => error.BadData,
                error.Truncated => error.Truncated,
                else => error.ReadFailed,
            };
            return err;
        };
    }

    fn seekInner(self: *Core, frame: u64) codec.SeekError!void {
        const total = self.si.total;
        if (total != 0 and frame > total) return error.Truncated;
        self.clearPosition();
        if (total != 0 and frame == total) {
            self.next_sample = total;
            self.at_end = true;
            return;
        }
        const length = self.input.length();
        const start: Point = .{ .pos = self.first_frame, .sample = 0 };
        var lo = start;
        var hi = length;
        for (self.seek_points) |p| {
            const pos = std.math.add(u64, self.first_frame, p.offset) catch break;
            if (length) |len| {
                if (pos >= len) break;
            }
            if (p.sample <= frame) {
                lo = .{ .pos = pos, .sample = p.sample };
            } else {
                hi = pos;
                break;
            }
        }
        var from_table = lo.pos != start.pos or lo.sample != start.sample;
        if (from_table and !try self.pointHolds(lo)) {
            from_table = false;
            lo = start;
            hi = length;
        }
        self.seekFrom(lo, hi, frame) catch |err| switch (err) {
            error.BadData, error.Truncated => {
                if (!from_table) return err;
                try self.seekFrom(start, length, frame);
            },
            else => return err,
        };
    }

    /// Whether a frame with the sample number of the point starts at its position.
    fn pointHolds(self: *Core, p: Point) codec.SeekError!bool {
        try self.bitsSeek(p.pos);
        self.short_seen = false;
        if (self.decodeFrame(.probe)) |_| {
            return self.frame_sample == p.sample;
        } else |err| switch (err) {
            error.ReadFailed => return err,
            else => return false,
        }
    }

    fn seekFrom(self: *Core, start: Point, end: ?u64, target: u64) codec.SeekError!void {
        var lo = start;
        var hi = end;
        while (hi) |h| {
            if (h <= lo.pos or h - lo.pos <= bisect_limit) break;
            const mid = lo.pos + (h - lo.pos) / 2;
            if (try self.probe(mid, h)) |c| {
                if (c.sample <= target) lo = c else hi = c.pos;
            } else {
                hi = mid;
            }
        }
        try self.bitsSeek(lo.pos);
        self.next_sample = lo.sample;
        self.short_seen = false;
        while (true) {
            if (!try self.decodeFrame(.walk)) {
                if (self.next_sample != target) return error.Truncated;
                self.block_len = 0;
                self.block_pos = 0;
                return;
            }
            if (target < self.next_sample) {
                self.block_pos = @intCast(target - (self.next_sample - self.block_len));
                return;
            }
        }
    }

    /// Finds the first frame that starts in [from, limit) and decodes with valid CRCs.
    fn probe(self: *Core, from: u64, limit: u64) codec.SeekError!?Point {
        try self.bitsSeek(from);
        while (self.bits.bytePosition() < limit) {
            const byte = self.bits.readBits(8) catch |err| switch (err) {
                error.Truncated => return null,
                else => |e| return e,
            };
            if (byte != 0xff) continue;
            if (self.bits.peekByte()) |next| {
                if (next != 0xf8 and next != 0xf9) continue;
            }
            const here = self.bits.bytePosition() - 1;
            try self.bitsSeek(here);
            self.short_seen = false;
            if (self.decodeFrame(.probe)) |_| {
                return .{ .pos = here, .sample = self.frame_sample };
            } else |err| switch (err) {
                error.ReadFailed => return err,
                else => {},
            }
            try self.bitsSeek(here + 1);
        }
        return null;
    }

    pub fn loadBlock(self: *Core) FrameError!bool {
        if (self.failed) |err| return err;
        if (self.at_end) return false;
        const more = self.loadFrame() catch |err| {
            self.failed = err;
            return err;
        };
        if (!more) return self.endOfData();
        return true;
    }

    fn loadFrame(self: *Core) FrameError!bool {
        const start = self.bits.bytePosition();
        return self.decodeFrame(.read) catch |err| {
            if (err != error.BadData or self.options.on_bad_frame == .fail or self.strict_hit) return err;
            return self.resync(start);
        };
    }

    /// Skips the failed frame that began at `start`, looks for the next frame that has a
    /// valid header and a valid CRC, and decodes it. False when the data ends first.
    fn resync(self: *Core, start: u64) FrameError!bool {
        const b = &self.bits;
        self.stats_.resyncs +|= 1;
        self.resync_next = true;
        try self.rewind(start + 1);
        while (true) {
            const byte = b.readBits(8) catch |err| switch (err) {
                error.Truncated => {
                    self.stats_.skipped_bytes +|= b.bytePosition() - start;
                    return false;
                },
                error.ReadFailed => return error.ReadFailed,
            };
            if (byte != 0xff) continue;
            if (b.peekByte()) |next| {
                if (next != 0xf8 and next != 0xf9) continue;
            }
            const here = b.bytePosition() - 1;
            _ = b.moveTo(here);
            if (self.decodeFrame(.scan)) |_| {
                self.stats_.skipped_bytes +|= here - start;
                return true;
            } else |err| switch (err) {
                error.ReadFailed => return err,
                error.BadData => if (self.strict_hit) return err,
                error.Truncated => {},
            }
            try self.rewind(here + 1);
        }
    }

    /// Goes back to the byte at `at`, which a failed frame read past. A source that cannot
    /// seek goes back only inside the buffered bytes, else it goes on from where it is.
    fn rewind(self: *Core, at: u64) FrameError!void {
        if (self.bits.moveTo(at)) return;
        if (!self.input.seekable()) {
            _ = self.bits.moveTo(self.bits.bytePosition());
            return;
        }
        self.bitsSeek(at) catch |err| return switch (err) {
            error.Truncated => error.Truncated,
            error.Unseekable, error.ReadFailed => error.ReadFailed,
        };
    }

    /// Ends the stream when no frame is left. A stream shorter than its STREAMINFO total
    /// gives error.Truncated.
    pub fn endOfData(self: *Core) FrameError!bool {
        return self.endData(false);
    }

    /// Like `endOfData`. With `damaged` a shortfall against the STREAMINFO total is not an
    /// error, because the decoder skipped frames of the stream.
    pub fn endData(self: *Core, damaged: bool) FrameError!bool {
        if (!damaged and self.si.total != 0 and self.next_sample < self.si.total) {
            self.failed = error.Truncated;
            return error.Truncated;
        }
        self.at_end = true;
        self.finish();
        return false;
    }

    /// Decodes the frame in `packet`. A packet holds one whole frame and nothing else.
    /// `walk` leaves the stats alone, for the frames that a seek passes.
    pub fn loadPacket(self: *Core, packet: []const u8, walk: bool) FrameError!void {
        self.bits = .initBytes(packet);
        if (packet.len == 0 or packet[0] != 0xff) return error.BadData;
        _ = try self.decodeFrame(if (walk) .walk else .read);
        if (self.bits.bytePosition() != packet.len) return error.BadData;
    }

    /// Counts a packet of `len` bytes that the caller skipped because it failed with
    /// error.BadData. The next frame takes its position from its frame number.
    pub fn skipPacket(self: *Core, len: usize) void {
        self.stats_.resyncs +|= 1;
        self.stats_.skipped_bytes +|= len;
        self.resync_next = true;
    }

    /// Forgets the position state. A seek calls it before it moves.
    pub fn clearPosition(self: *Core) void {
        self.failed = null;
        self.resync_next = false;
        self.at_end = false;
        self.short_seen = false;
        self.md5_valid = false;
        self.md5_result = null;
        self.block_len = 0;
        self.block_pos = 0;
    }

    fn finish(self: *Core) void {
        if (self.md5_result != null or !self.md5_valid) return;
        self.md5_result = std.mem.eql(u8, &self.md5.digest(), &self.si.md5);
    }

    fn md5Frame(self: *Core, block: usize) void {
        const width: usize = (self.si.bps + 7) / 8;
        const channels: usize = self.si.channels;
        for (0..block) |i| {
            for (0..channels) |c| self.md5.add(@truncate(self.chan(c)[i]), width);
        }
    }

    fn readHeader(self: *Core) FrameError!Header {
        const b = &self.bits;
        const b0 = try readByte(b);
        const b1 = try readByte(b);
        if (b0 != 0xff or (b1 & 0xfe) != 0xf8) return error.BadData;
        const variable = (b1 & 1) != 0 or self.si.min_block != self.si.max_block;
        const b2 = try readByte(b);
        const b3 = try readByte(b);
        if (b3 & 1 != 0) return error.BadData;
        const bs_code = b2 >> 4;
        const rate_code = b2 & 15;
        const ch_code = b3 >> 4;
        const size_code = (b3 >> 1) & 7;

        const number = try readUtf8(b, variable);

        const block_size: u32 = switch (bs_code) {
            0 => return error.BadData,
            1 => 192,
            2...5 => @as(u32, 576) << @intCast(bs_code - 2),
            6 => @as(u32, try readByte(b)) + 1,
            7 => blk: {
                const v = try read16(b);
                if (v == 0xffff) return error.BadData;
                break :blk @as(u32, v) + 1;
            },
            else => @as(u32, 256) << @intCast(bs_code - 8),
        };
        const rate: u32 = switch (rate_code) {
            0 => self.si.rate,
            1 => 88200,
            2 => 176400,
            3 => 192000,
            4 => 8000,
            5 => 16000,
            6 => 22050,
            7 => 24000,
            8 => 32000,
            9 => 44100,
            10 => 48000,
            11 => 96000,
            12 => @as(u32, try readByte(b)) * 1000,
            13 => try read16(b),
            14 => @as(u32, try read16(b)) * 10,
            else => return error.BadData,
        };
        var assignment: Assignment = .independent;
        var channels: u8 = ch_code + 1;
        switch (ch_code) {
            0...7 => {},
            8 => {
                assignment = .left_side;
                channels = 2;
            },
            9 => {
                assignment = .right_side;
                channels = 2;
            },
            10 => {
                assignment = .mid_side;
                channels = 2;
            },
            else => return error.BadData,
        }
        const bps: u8 = switch (size_code) {
            0 => self.si.bps,
            1 => 8,
            2 => 12,
            4 => 16,
            5 => 20,
            6 => 24,
            7 => 32,
            else => return error.BadData,
        };

        const want = b.crc8();
        if (try readByte(b) != want) return error.BadData;

        if (rate == 0 or rate != self.si.rate) return error.BadData;
        if (channels != self.si.channels or bps != self.si.bps) return error.BadData;
        if (block_size > self.si.max_block or self.short_seen) return error.BadData;
        return .{
            .block_size = block_size,
            .channels = channels,
            .assignment = assignment,
            .sample = if (variable) number else number * self.si.max_block,
        };
    }

    /// Reads an ID3v1 or APE tag at the end of the frames. True when one starts here.
    fn atTrailer(self: *Core) FrameError!bool {
        var head: [8]u8 = undefined;
        for (&head, 0..) |*h, i| {
            h.* = try readByte(&self.bits);
            if (i == 0 and h.* != 'T' and h.* != 'A') return false;
            if (i == 2 and head[0] == 'T') return std.mem.eql(u8, head[0..3], "TAG");
        }
        return std.mem.eql(u8, &head, "APETAGEX");
    }

    /// Decodes the next frame into the channel buffers. False at the end of the frames.
    /// `.probe` makes a CRC mismatch an error and skips the checks against the metadata.
    /// Only `.read` counts problems in the stats.
    fn decodeFrame(self: *Core, mode: Mode) FrameError!bool {
        const probing = mode == .probe;
        const counting = mode == .read or mode == .scan;
        self.strict_hit = false;
        const b = &self.bits;
        if (!try b.hasMore()) return false;
        if ((b.peekByte() orelse return false) != 0xff) {
            if (probing or mode == .scan or !try self.atTrailer()) return error.BadData;
            self.at_end = true;
            return false;
        }
        b.crcStart();
        const start = b.bytePosition();
        const h = try self.readHeader();
        const bs: usize = h.block_size;
        const jump = mode == .scan or (mode == .read and self.resync_next);
        const base: u64 = if (jump) h.sample -% self.origin else self.next_sample;
        var excess: u64 = 0;
        var scan_over = false;
        if (!probing and self.si.total != 0 and base + bs > self.si.total) {
            if (self.options.strict_metadata and mode == .scan) {
                scan_over = true;
            } else if (self.options.strict_metadata) {
                self.strict_hit = true;
                return error.BadData;
            }
            excess = base + bs - @max(base, self.si.total);
        }

        const bps: u8 = self.si.bps;
        for (0..h.channels) |c| {
            const side = switch (h.assignment) {
                .independent => false,
                .left_side, .mid_side => c == 1,
                .right_side => c == 0,
            };
            try self.decodeSubframe(self.chan(c)[0..bs], bps + @intFromBool(side));
        }
        switch (h.assignment) {
            .independent => {},
            .left_side => {
                const l = self.chan(0)[0..bs];
                for (self.chan(1)[0..bs], l) |*s, left| s.* = left - s.*;
            },
            .right_side => {
                const r = self.chan(1)[0..bs];
                for (self.chan(0)[0..bs], r) |*s, right| s.* += right;
            },
            .mid_side => {
                const side = self.chan(1)[0..bs];
                for (self.chan(0)[0..bs], side) |*m, *s| {
                    const mid = (m.* << 1) | (s.* & 1);
                    m.* = (mid + s.*) >> 1;
                    s.* = (mid - s.*) >> 1;
                }
            },
        }

        if (counting and h.assignment != .independent) {
            self.stats_.clipped_samples +|= self.countClipped(bs);
        }

        b.alignByte();
        const want = b.crc16();
        const got = try read16(b);
        if (got != want) {
            if (mode == .read) self.stats_.crc_errors +|= 1;
            return error.BadData;
        }
        if (scan_over) {
            self.strict_hit = true;
            return error.BadData;
        }
        const oversized = self.si.max_frame != 0 and b.bytePosition() - start > self.si.max_frame;
        if (oversized and !probing and self.options.strict_metadata) {
            self.strict_hit = true;
            return error.BadData;
        }

        if (oversized and counting) self.stats_.oversized_frames +|= 1;
        if (counting) self.stats_.excess_samples +|= excess;
        if (jump) self.resync_next = false;
        self.frame_sample = h.sample;
        self.short_seen = bs < min_block_size;
        self.block_len = bs;
        self.block_pos = 0;
        self.next_sample = base + bs;
        if (self.md5_valid and counting) self.md5Frame(bs);
        return true;
    }

    /// Counts the samples of the two channels of a block that are outside the sample depth.
    fn countClipped(self: *Core, bs: usize) u64 {
        const half: i64 = @as(i64, 1) << @intCast(self.si.bps - 1);
        var n: u64 = 0;
        for (0..2) |c| {
            for (self.chan(c)[0..bs]) |v| n += @intFromBool(v < -half or v >= half);
        }
        return n;
    }

    fn decodeSubframe(self: *Core, out: []i64, bps: u8) FrameError!void {
        const b = &self.bits;
        if (try b.readBits(1) != 0) return error.BadData;
        const kind: u8 = @intCast(try b.readBits(6));
        var wasted: u8 = 0;
        if (try b.readBits(1) == 1) {
            const zeros = try b.readUnary(bps);
            if (zeros >= bps) return error.BadData;
            wasted = @intCast(zeros + 1);
        }
        if (wasted >= bps) return error.BadData;
        const depth: u6 = @intCast(bps - wasted);
        switch (kind) {
            0 => @memset(out, try b.readSigned(depth)),
            1 => for (out) |*s| {
                s.* = try b.readSigned(depth);
            },
            8...12 => {
                const order = kind - 8;
                if (order >= out.len) return error.BadData;
                for (out[0..order]) |*s| s.* = try b.readSigned(depth);
                try self.readResidual(out, order);
                try restoreFixed(out, order, depth);
            },
            32...63 => {
                const order: usize = (kind & 31) + 1;
                if (order >= out.len) return error.BadData;
                for (out[0..order]) |*s| s.* = try b.readSigned(depth);
                const precision_code = try b.readBits(4);
                if (precision_code == 15) return error.BadData;
                const precision: u6 = @intCast(precision_code + 1);
                const shift = try b.readSigned(5);
                if (shift < 0) return error.BadData;
                var coefs: [32]i64 = undefined;
                for (coefs[0..order]) |*c| c.* = try b.readSigned(precision);
                try self.readResidual(out, order);
                try restoreLpc(out, coefs[0..order], @intCast(shift), depth);
            },
            else => return error.BadData,
        }
        if (wasted > 0) {
            const k: u6 = @intCast(wasted);
            for (out) |*s| s.* <<= k;
        }
    }

    fn readResidual(self: *Core, out: []i64, order: usize) FrameError!void {
        const b = &self.bits;
        const method = try b.readBits(2);
        if (method > 1) return error.BadData;
        const part_order: u5 = @intCast(try b.readBits(4));
        const parts = @as(usize, 1) << part_order;
        if (out.len % parts != 0) return error.BadData;
        const part_len = out.len >> part_order;
        if (part_len < order) return error.BadData;
        const param_bits: u7 = if (method == 0) 4 else 5;
        const escape: u64 = (@as(u64, 1) << @intCast(param_bits)) - 1;
        var at = order;
        for (0..parts) |p| {
            const n = if (p == 0) part_len - order else part_len;
            const k = try b.readBits(param_bits);
            if (k == escape) {
                const raw: u6 = @intCast(try b.readBits(5));
                if (raw == 0) {
                    @memset(out[at..][0..n], 0);
                } else {
                    for (out[at..][0..n]) |*s| s.* = try b.readSigned(raw);
                }
            } else {
                const kk: u7 = @intCast(k);
                const max_q = @as(u64, 0xfffffffe) >> @intCast(k);
                for (out[at..][0..n]) |*s| {
                    const q = try b.readUnary(max_q);
                    const r = if (kk > 0) try b.readBits(kk) else 0;
                    const u = (q << @intCast(k)) | r;
                    if (u > 0xfffffffe) return error.BadData;
                    const half: i64 = @intCast(u >> 1);
                    s.* = half ^ -@as(i64, @intCast(u & 1));
                }
            }
            at += n;
        }
    }
};

fn readByte(b: *io.BitReader) FrameError!u8 {
    return @intCast(try b.readBits(8));
}

fn read16(b: *io.BitReader) FrameError!u16 {
    return @intCast(try b.readBits(16));
}

fn readUtf8(b: *io.BitReader, variable: bool) FrameError!u64 {
    const lead = try readByte(b);
    var value: u64 = undefined;
    var extra: u3 = undefined;
    if (lead < 0x80) {
        value = lead;
        extra = 0;
    } else if (lead & 0xe0 == 0xc0) {
        value = lead & 0x1f;
        extra = 1;
    } else if (lead & 0xf0 == 0xe0) {
        value = lead & 0x0f;
        extra = 2;
    } else if (lead & 0xf8 == 0xf0) {
        value = lead & 0x07;
        extra = 3;
    } else if (lead & 0xfc == 0xf8) {
        value = lead & 0x03;
        extra = 4;
    } else if (lead & 0xfe == 0xfc) {
        value = lead & 0x01;
        extra = 5;
    } else if (lead == 0xfe and variable) {
        value = 0;
        extra = 6;
    } else {
        return error.BadData;
    }
    for (0..extra) |_| {
        const c = try readByte(b);
        if (c & 0xc0 != 0x80) return error.BadData;
        value = (value << 6) | (c & 0x3f);
    }
    return value;
}

fn inRange(depth: u6) struct { lo: i64, hi: i64 } {
    const half = @as(i64, 1) << @intCast(depth - 1);
    return .{ .lo = -half, .hi = half - 1 };
}

fn restoreFixed(out: []i64, order: usize, depth: u6) FrameError!void {
    const r = inRange(depth);
    for (order..out.len) |i| {
        const pred: i64 = switch (order) {
            0 => 0,
            1 => out[i - 1],
            2 => 2 * out[i - 1] - out[i - 2],
            3 => 3 * out[i - 1] - 3 * out[i - 2] + out[i - 3],
            else => 4 * out[i - 1] - 6 * out[i - 2] + 4 * out[i - 3] - out[i - 4],
        };
        const v = pred + out[i];
        if (v < r.lo or v > r.hi) return error.BadData;
        out[i] = v;
    }
}

fn restoreLpc(out: []i64, coefs: []const i64, shift: u6, depth: u6) FrameError!void {
    const r = inRange(depth);
    for (coefs.len..out.len) |i| {
        var sum: i64 = 0;
        for (coefs, 0..) |c, j| sum += c * out[i - 1 - j];
        const v = (sum >> shift) + out[i];
        if (v < r.lo or v > r.hi) return error.BadData;
        out[i] = v;
    }
}
