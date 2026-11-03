//! FLAC encoding (RFC 9639).
//!
//! The encoder follows the libFLAC compression levels 0 to 8: the block size, the fixed
//! or LPC predictors, the stereo search and the Rice partition limits are the ones of
//! the `flac` command line. Frames use fixed block sizes.
const std = @import("std");
const codec = @import("../../codec.zig");
const io = @import("../io.zig");
const crc = @import("../crc.zig");
const wav = @import("../wav.zig");
const pcm = @import("../pcm.zig");
const Md5Stage = @import("md5.zig").Stage;
const packets = @import("../ogg.zig");
const decode = @import("decode.zig");
const lpc = @import("lpc.zig");
const search = @import("search.zig");
const testing = std.testing;

const Level = search.Level;
const Plan = search.Plan;
const Search = search.Search;
const levels = search.levels;
const partitionCount = search.partitionCount;
const escape = search.escape;

pub const Options = struct {
    /// 0 to 8, as the levels of the `flac` command line.
    level: u4 = 5,
    /// The sample depth of the stream, 8 to 24. FLAC allows 4 to 32 bits, but f32 input
    /// holds 24 bits, so other depths give error.Unsupported.
    bits: u8 = 16,
};

const min_bits = 8;
const max_bits = 24;
const max_channels = 8;
const max_rate = (1 << 20) - 1;
const streaminfo_offset = 8;

const comment_max = 80;

/// The size of the first packet of an Ogg FLAC stream.
pub const mapping_size = 51;

/// Builds the first packet of an Ogg FLAC stream: the mapping header for version 1.0 with
/// `header_count` packets after this one, then "fLaC" and the STREAMINFO block.
pub fn mappingPacket(streaminfo: *const [34]u8, header_count: u16) [mapping_size]u8 {
    var m: [mapping_size]u8 = undefined;
    @memcpy(m[0..7], "\x7fFLAC\x01\x00");
    std.mem.writeInt(u16, m[7..9], header_count, .big);
    @memcpy(m[9..13], "fLaC");
    m[13] = 0;
    std.mem.writeInt(u24, m[14..17], 34, .big);
    m[17..51].* = streaminfo.*;
    return m;
}

const Assignment = enum { independent, left_side, right_side, mid_side };

fn basePrecision(bits: u8, block: usize) u8 {
    if (bits < 16) return @max(lpc.min_precision, 2 + bits / 2);
    if (bits == 16) {
        if (block <= 192) return 7;
        if (block <= 384) return 8;
        if (block <= 576) return 9;
        if (block <= 1152) return 10;
        if (block <= 2304) return 11;
        if (block <= 4608) return 12;
        return 13;
    }
    if (block <= 384) return lpc.max_precision - 2;
    if (block <= 1152) return lpc.max_precision - 1;
    return lpc.max_precision;
}

const Field = struct { code: u4, bits: u5 = 0, value: u32 = 0 };

fn blockField(n: usize) Field {
    const table = [_]struct { size: u16, code: u4 }{
        .{ .size = 192, .code = 1 },    .{ .size = 576, .code = 2 },
        .{ .size = 1152, .code = 3 },   .{ .size = 2304, .code = 4 },
        .{ .size = 4608, .code = 5 },   .{ .size = 256, .code = 8 },
        .{ .size = 512, .code = 9 },    .{ .size = 1024, .code = 10 },
        .{ .size = 2048, .code = 11 },  .{ .size = 4096, .code = 12 },
        .{ .size = 8192, .code = 13 },  .{ .size = 16384, .code = 14 },
        .{ .size = 32768, .code = 15 },
    };
    for (table) |e| if (e.size == n) return .{ .code = e.code };
    if (n <= 256) return .{ .code = 6, .bits = 8, .value = @intCast(n - 1) };
    return .{ .code = 7, .bits = 16, .value = @intCast(n - 1) };
}

fn rateField(rate: u32) Field {
    const table = [_]struct { rate: u32, code: u4 }{
        .{ .rate = 88200, .code = 1 },  .{ .rate = 176400, .code = 2 },
        .{ .rate = 192000, .code = 3 }, .{ .rate = 8000, .code = 4 },
        .{ .rate = 16000, .code = 5 },  .{ .rate = 22050, .code = 6 },
        .{ .rate = 24000, .code = 7 },  .{ .rate = 32000, .code = 8 },
        .{ .rate = 44100, .code = 9 },  .{ .rate = 48000, .code = 10 },
        .{ .rate = 96000, .code = 11 },
    };
    for (table) |e| if (e.rate == rate) return .{ .code = e.code };
    if (rate % 1000 == 0 and rate / 1000 <= 255) return .{ .code = 12, .bits = 8, .value = rate / 1000 };
    if (rate <= 65535) return .{ .code = 13, .bits = 16, .value = rate };
    if (rate % 10 == 0 and rate / 10 <= 65535) return .{ .code = 14, .bits = 16, .value = rate / 10 };
    return .{ .code = 0 };
}

fn sizeCode(bits: u8) u3 {
    return switch (bits) {
        8 => 1,
        12 => 2,
        16 => 4,
        20 => 5,
        24 => 6,
        else => 0,
    };
}

fn writeUtf8(bw: *io.BitWriter, v: u32) std.mem.Allocator.Error!void {
    const x: u64 = v;
    if (x < 0x80) return bw.writeBits(x, 8);
    var extra: u6 = 1;
    while (extra < 5 and x >= (@as(u64, 1) << (5 * extra + 6))) extra += 1;
    const lead: u64 = (@as(u64, 0xff00) >> (extra + 1)) & 0xff;
    try bw.writeBits(lead | (x >> (extra * 6)), 8);
    var i = extra;
    while (i > 0) {
        i -= 1;
        try bw.writeBits(0x80 | ((x >> (i * 6)) & 0x3f), 8);
    }
}

/// Picks the assignment with the smallest sum of first differences, which is the
/// estimate of the order 1 fixed predictor. Ties go to the lower assignment.
fn looseChoice(left: []const i32, right: []const i32, mid: []const i32, side: []const i32) Assignment {
    const sums = [4]u64{ diffSum(left), diffSum(right), diffSum(mid), diffSum(side) };
    var best = sums[0] + sums[1];
    var assign: Assignment = .independent;
    if (sums[0] + sums[3] < best) {
        best = sums[0] + sums[3];
        assign = .left_side;
    }
    if (sums[1] + sums[3] < best) {
        best = sums[1] + sums[3];
        assign = .right_side;
    }
    if (sums[2] + sums[3] < best) assign = .mid_side;
    return assign;
}

fn diffSum(signal: []const i32) u64 {
    var sum: u64 = 0;
    for (1..signal.len) |i| sum += @abs(signal[i] - signal[i - 1]);
    return sum;
}

fn pair(assign: Assignment, left: []const i32, right: []const i32, mid: []const i32, side: []const i32) [2][]const i32 {
    return switch (assign) {
        .independent => .{ left, right },
        .left_side => .{ left, side },
        .right_side => .{ side, right },
        .mid_side => .{ mid, side },
    };
}

/// The index of the side channel in a coded pair, which has one more bit per sample.
fn sideChannel(assign: Assignment) ?usize {
    return switch (assign) {
        .independent => null,
        .left_side, .mid_side => 1,
        .right_side => 0,
    };
}

/// Writes interleaved f32 frames as FLAC.
///
/// Samples become integers of `Options.bits` bits by scaling with 2^(bits-1), rounding and
/// clamping, and NaN becomes 0. No dither is added, so the stream is lossless relative to
/// those integers. A zero `Info.mask` selects the default mask. A mask whose bit count
/// differs from the channel count gives error.Unsupported. A mask that is not the default
/// is stored in a Vorbis comment. `Info.bits_per_sample` and `Info.total_frames` are ignored.
///
/// With `init` the writer cannot seek. STREAMINFO is written with total samples 0, the
/// frame sizes 0 and an unset MD5, which the format defines as unknown. With `initFile`,
/// `finish` seeks back and writes the total, the MD5 and the block and frame sizes, and
/// sets `sizes_fixed`. If the file reports error.Unseekable, `finish` leaves the unknown
/// values. Every other seek or write error is error.WriteFailed.
pub const Encoder = struct {
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    file: ?*std.Io.File.Writer,
    level: Level,
    bits: u8,
    channels: u8,
    rate: u32,
    mask: u32,
    block: usize,
    /// One block of every channel, one channel after the other.
    pending: []i32,
    pending_len: usize = 0,
    /// The mid and the side signal of the block.
    ms: []i32,
    search: Search,
    bw: io.BitWriter,
    md5: Md5Stage = .{},
    started: bool = false,
    finished: bool = false,
    frames_written: u64 = 0,
    total: u64 = 0,
    last_block: usize = 0,
    min_frame: u32 = std.math.maxInt(u32),
    max_frame: u32 = 0,
    /// True after `finish` wrote the real STREAMINFO values.
    sizes_fixed: bool = false,
    /// Set for Ogg FLAC: frames go to this writer as packets.
    ogg: ?packets.PacketWriter = null,
    serial: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, options: Options, info: codec.Info) codec.EncoderInitError!Encoder {
        return create(gpa, writer, null, null, options, info);
    }

    pub fn initFile(gpa: std.mem.Allocator, file: *std.Io.File.Writer, options: Options, info: codec.Info) codec.EncoderInitError!Encoder {
        return create(gpa, &file.interface, file, null, options, info);
    }

    /// Like `init`, with the stream in an Ogg stream of the given serial number.
    pub fn initOgg(gpa: std.mem.Allocator, writer: *std.Io.Writer, serial: u32, options: Options, info: codec.Info) codec.EncoderInitError!Encoder {
        return create(gpa, writer, null, serial, options, info);
    }

    pub fn initOggFile(gpa: std.mem.Allocator, file: *std.Io.File.Writer, serial: u32, options: Options, info: codec.Info) codec.EncoderInitError!Encoder {
        return create(gpa, &file.interface, file, serial, options, info);
    }

    fn create(gpa: std.mem.Allocator, writer: *std.Io.Writer, file: ?*std.Io.File.Writer, ogg_serial: ?u32, options: Options, info: codec.Info) codec.EncoderInitError!Encoder {
        if (options.level > 8 or options.bits < min_bits or options.bits > max_bits) return error.Unsupported;
        if (info.channels == 0 or info.channels > max_channels) return error.Unsupported;
        if (info.rate == 0 or info.rate > max_rate) return error.Unsupported;
        const given: u32 = @bitCast(info.mask);
        const default = wav.defaultMask(info.channels);
        if (given != 0 and @popCount(given) != info.channels) return error.Unsupported;
        const level = levels[options.level];
        const block: usize = level.block;
        const channels: usize = info.channels;

        const pending = try gpa.alloc(i32, channels * block);
        errdefer gpa.free(pending);
        const ms = try gpa.alloc(i32, 2 * block);
        errdefer gpa.free(ms);
        const window = try gpa.alloc(f64, block);
        errdefer gpa.free(window);
        const windowed = try gpa.alloc(f64, block);
        errdefer gpa.free(windowed);
        const work = try gpa.alloc(i32, block);
        errdefer gpa.free(work);
        const resid = try gpa.alloc(i32, block);
        errdefer gpa.free(resid);
        var pw: ?packets.PacketWriter = null;
        if (ogg_serial) |serial| pw = try .init(gpa, writer, serial, .{});
        errdefer if (pw) |*p| p.deinit();
        var bw: io.BitWriter = .init(gpa);
        errdefer bw.deinit();
        try bw.list.ensureTotalCapacity(gpa, channels * (block * 4 + 8) + 32);

        return .{
            .gpa = gpa,
            .writer = writer,
            .file = file,
            .level = level,
            .bits = options.bits,
            .channels = info.channels,
            .rate = info.rate,
            .mask = if (given == 0) default else given,
            .block = block,
            .pending = pending,
            .ms = ms,
            .search = .{
                .level = level,
                .precision = basePrecision(options.bits, block),
                .window = window,
                .windowed = windowed,
                .work = work,
                .resid = resid,
            },
            .bw = bw,
            .ogg = pw,
            .serial = ogg_serial orelse 0,
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.gpa.free(self.pending);
        self.gpa.free(self.ms);
        self.gpa.free(self.search.window);
        self.gpa.free(self.search.windowed);
        self.gpa.free(self.search.work);
        self.gpa.free(self.search.resid);
        self.bw.deinit();
        if (self.ogg) |*p| p.deinit();
        self.* = undefined;
    }

    fn streamInfo(self: *const Encoder, digest: ?[16]u8) [34]u8 {
        var b: [34]u8 = @splat(0);
        var min_block: u16 = @intCast(self.block);
        var max_block: u16 = min_block;
        var total: u64 = 0;
        if (digest) |d| {
            if (self.frames_written == 1) {
                min_block = @intCast(@max(self.last_block, 16));
                max_block = min_block;
            }
            if (self.frames_written > 0) {
                std.mem.writeInt(u24, b[4..7], @intCast(@min(self.min_frame, std.math.maxInt(u24))), .big);
                std.mem.writeInt(u24, b[7..10], @intCast(@min(self.max_frame, std.math.maxInt(u24))), .big);
            }
            if (self.total < (@as(u64, 1) << 36)) total = self.total;
            b[18..34].* = d;
        }
        std.mem.writeInt(u16, b[0..2], min_block, .big);
        std.mem.writeInt(u16, b[2..4], max_block, .big);
        const tail = (@as(u64, self.rate) << 44) | (@as(u64, self.channels - 1) << 41) |
            (@as(u64, self.bits - 1) << 36) | total;
        std.mem.writeInt(u64, b[10..18], tail, .big);
        return b;
    }

    /// Writes the Vorbis comment block, with its header, and returns its length.
    fn commentBlock(self: *const Encoder, out: *[comment_max]u8, tagged: bool) usize {
        const vendor = "chorus";
        var text_buf: [48]u8 = undefined;
        const text = if (tagged)
            std.fmt.bufPrint(&text_buf, "WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0x{X}", .{self.mask}) catch unreachable
        else
            text_buf[0..0];
        const entries: u32 = @intFromBool(tagged);
        const body_len: u24 = @intCast(4 + vendor.len + 4 + if (tagged) 4 + text.len else 0);
        out[0] = 0x84;
        std.mem.writeInt(u24, out[1..4], body_len, .big);
        var len: usize = 4;
        std.mem.writeInt(u32, out[len..][0..4], vendor.len, .little);
        @memcpy(out[len + 4 ..][0..vendor.len], vendor);
        len += 4 + vendor.len;
        std.mem.writeInt(u32, out[len..][0..4], entries, .little);
        len += 4;
        if (tagged) {
            std.mem.writeInt(u32, out[len..][0..4], @intCast(text.len), .little);
            @memcpy(out[len + 4 ..][0..text.len], text);
            len += 4 + text.len;
        }
        return len;
    }

    fn begin(self: *Encoder) codec.WriteError!void {
        if (self.started) return;
        self.started = true;
        const tagged = self.mask != wav.defaultMask(self.channels);
        var comment: [comment_max]u8 = undefined;
        if (self.ogg) |*pw| {
            const map = mappingPacket(&self.streamInfo(null), 1);
            try pw.writePacket(&map, 0);
            try pw.flush();
            const n = self.commentBlock(&comment, tagged);
            try pw.writePacket(comment[0..n], 0);
            try pw.flush();
            return;
        }
        var head: [42 + comment_max]u8 = undefined;
        @memcpy(head[0..4], "fLaC");
        head[4] = if (tagged) 0 else 0x80;
        std.mem.writeInt(u24, head[5..8], 34, .big);
        head[8..42].* = self.streamInfo(null);
        var len: usize = 42;
        if (tagged) len += self.commentBlock(head[42..][0..comment_max], true);
        self.writer.writeAll(head[0..len]) catch return error.WriteFailed;
    }

    /// `frames` holds whole interleaved frames.
    pub fn write(self: *Encoder, frames: []const f32) codec.WriteError!void {
        return self.writeWith(frames, null);
    }

    /// `forced` pins the stereo assignment of a two channel stream.
    fn writeWith(self: *Encoder, frames: []const f32, forced: ?Assignment) codec.WriteError!void {
        const ch: usize = self.channels;
        if (self.finished or frames.len % ch != 0) return error.Unsupported;
        try self.begin();
        const scale: f64 = @floatFromInt(@as(u32, 1) << @intCast(self.bits - 1));
        const width: usize = (self.bits + 7) / 8;
        var at: usize = 0;
        while (at < frames.len) {
            const take = @min(self.block - self.pending_len, (frames.len - at) / ch);
            for (0..take) |f| {
                for (0..ch) |c| {
                    const v: i32 = @intCast(pcm.quantize(frames[at + f * ch + c], scale));
                    self.pending[c * self.block + self.pending_len + f] = v;
                    if (self.file != null) self.md5.add(v, width);
                }
            }
            at += take * ch;
            self.pending_len += take;
            if (self.pending_len == self.block) try self.flushBlock(forced);
        }
    }

    fn flushBlock(self: *Encoder, forced: ?Assignment) codec.WriteError!void {
        const n = self.pending_len;
        try self.encodeFrame(n, forced);
        self.pending_len = 0;
        self.total += n;
        self.last_block = n;
    }

    pub fn finish(self: *Encoder) codec.WriteError!void {
        if (self.finished) return;
        self.finished = true;
        try self.begin();
        if (self.pending_len > 0) try self.flushBlock(null);
        if (self.ogg) |*pw| try pw.finish();
        self.writer.flush() catch return error.WriteFailed;
        const file = self.file orelse return;
        const end = file.logicalPos();
        if (!try io.rewindWriter(file)) return;
        const digest = self.md5.digest();
        if (self.ogg != null) {
            var page: [27 + 1 + mapping_size]u8 = undefined;
            const body = mappingPacket(&self.streamInfo(digest), 1);
            const lacing = [_]u8{mapping_size};
            const header: packets.Header = .{ .flags = .{ .bos = true }, .granule = 0, .serial = self.serial, .sequence = 0 };
            const n = packets.buildPage(&page, header, &lacing, &body) catch unreachable;
            file.interface.writeAll(page[0..n]) catch return error.WriteFailed;
        } else {
            file.seekTo(streaminfo_offset) catch return error.WriteFailed;
            file.interface.writeAll(&self.streamInfo(digest)) catch return error.WriteFailed;
        }
        file.interface.flush() catch return error.WriteFailed;
        file.seekTo(end) catch return error.WriteFailed;
        self.sizes_fixed = true;
    }

    fn encodeFrame(self: *Encoder, n: usize, forced: ?Assignment) codec.WriteError!void {
        if (self.frames_written >= (1 << 31)) return error.Unsupported;
        const block = self.block;
        const ch: usize = self.channels;
        const bits = self.bits;
        const planner = &self.search;
        var plans: [max_channels]Plan = undefined;
        var sigs: [max_channels][]const i32 = undefined;
        var assign: Assignment = .independent;

        if (ch == 2 and (forced != null or self.level.stereo != .off)) {
            const left = self.pending[0..n];
            const right = self.pending[block..][0..n];
            const mid = self.ms[0..n];
            const side = self.ms[block..][0..n];
            for (mid, side, left, right) |*m, *s, l, r| {
                m.* = (l + r) >> 1;
                s.* = l - r;
            }
            const mode = forced orelse if (self.level.stereo == .loose) looseChoice(left, right, mid, side) else null;
            if (mode) |m| {
                assign = m;
                sigs[0..2].* = pair(m, left, right, mid, side);
                for (0..2) |c| plans[c] = planner.plan(sigs[c], if (sideChannel(m) == c) bits + 1 else bits);
            } else {
                const pl = planner.plan(left, bits);
                const pr = planner.plan(right, bits);
                const pm = planner.plan(mid, bits);
                const ps = planner.plan(side, bits + 1);
                var best = pl.bits + pr.bits;
                plans[0..2].* = .{ pl, pr };
                if (pl.bits + ps.bits < best) {
                    best = pl.bits + ps.bits;
                    assign = .left_side;
                    plans[0..2].* = .{ pl, ps };
                }
                if (pr.bits + ps.bits < best) {
                    best = pr.bits + ps.bits;
                    assign = .right_side;
                    plans[0..2].* = .{ ps, pr };
                }
                if (pm.bits + ps.bits < best) {
                    assign = .mid_side;
                    plans[0..2].* = .{ pm, ps };
                }
                sigs[0..2].* = pair(assign, left, right, mid, side);
            }
        } else {
            for (0..ch) |c| {
                sigs[c] = self.pending[c * block ..][0..n];
                plans[c] = planner.plan(sigs[c], bits);
            }
        }

        self.bw.list.clearRetainingCapacity();
        self.bw.acc = 0;
        self.bw.nbits = 0;
        try self.writeHeader(n, assign);
        for (0..ch) |c| try self.writeSubframe(&plans[c], sigs[c]);
        try self.bw.alignByte();
        try self.bw.writeBits(crc.flac16.hash(self.bw.bytes()), 16);
        if (self.ogg) |*pw| {
            try pw.writePacket(self.bw.bytes(), @intCast(self.total + n));
        } else {
            self.writer.writeAll(self.bw.bytes()) catch return error.WriteFailed;
        }
        const size: u32 = @intCast(self.bw.bytes().len);
        self.min_frame = @min(self.min_frame, size);
        self.max_frame = @max(self.max_frame, size);
        self.frames_written += 1;
    }

    fn writeHeader(self: *Encoder, n: usize, assign: Assignment) std.mem.Allocator.Error!void {
        const bw = &self.bw;
        const bs = blockField(n);
        const rate = rateField(self.rate);
        try bw.writeBits(0b111111111111100, 15);
        try bw.writeBits(0, 1);
        try bw.writeBits(bs.code, 4);
        try bw.writeBits(rate.code, 4);
        try bw.writeBits(switch (assign) {
            .independent => self.channels - 1,
            .left_side => 8,
            .right_side => 9,
            .mid_side => 10,
        }, 4);
        try bw.writeBits(sizeCode(self.bits), 3);
        try bw.writeBits(0, 1);
        try writeUtf8(bw, @intCast(self.frames_written));
        if (bs.bits > 0) try bw.writeBits(bs.value, @intCast(bs.bits));
        if (rate.bits > 0) try bw.writeBits(rate.value, @intCast(rate.bits));
        try bw.writeBits(crc.flac8.hash(bw.bytes()), 8);
    }

    fn writeSubframe(self: *Encoder, p: *const Plan, signal: []const i32) std.mem.Allocator.Error!void {
        const bw = &self.bw;
        const n = signal.len;
        const work = self.search.work[0..n];
        for (work, signal) |*w, s| w.* = s >> @intCast(p.wasted);
        const order: usize = p.order;
        const bps: u6 = @intCast(p.bps);
        try bw.writeBits(0, 1);
        try bw.writeBits(switch (p.kind) {
            .constant => 0,
            .verbatim => 1,
            .fixed => 8 + @as(u64, p.order),
            .lpc => 32 + @as(u64, p.order) - 1,
        }, 6);
        if (p.wasted > 0) {
            try bw.writeBits(1, 1);
            try bw.writeUnary(p.wasted - 1);
        } else {
            try bw.writeBits(0, 1);
        }
        switch (p.kind) {
            .constant => try bw.writeSigned(p.constant, bps),
            .verbatim => for (work) |x| try bw.writeSigned(x, bps),
            .fixed, .lpc => {
                for (work[0..order]) |x| try bw.writeSigned(x, bps);
                const resid = self.search.resid[0 .. n - order];
                if (p.kind == .fixed) {
                    lpc.fixedResidual(work, order, resid);
                } else {
                    try bw.writeBits(p.precision - 1, 4);
                    try bw.writeBits(p.shift, 5);
                    for (p.coefs[0..order]) |c| try bw.writeSigned(c, @intCast(p.precision));
                    const ok = lpc.residual(work, p.coefs[0..order], p.shift, resid);
                    std.debug.assert(ok);
                }
                try self.writeResidual(p, resid, n, order);
            },
        }
    }

    fn writeResidual(self: *Encoder, p: *const Plan, resid: []const i32, n: usize, order: usize) std.mem.Allocator.Error!void {
        const bw = &self.bw;
        const width: u6 = 4 + @as(u6, p.method);
        const escape_code = (@as(u64, 1) << width) - 1;
        try bw.writeBits(p.method, 2);
        try bw.writeBits(p.part_order, 4);
        var start: usize = 0;
        for (0..@as(usize, 1) << p.part_order) |part| {
            const count = partitionCount(n, order, p.part_order, part);
            const samples = resid[start..][0..count];
            start += count;
            if (p.params[part] == escape) {
                try bw.writeBits(escape_code, width);
                try bw.writeBits(p.esc_bits[part], 5);
                for (samples) |r| try bw.writeSigned(r, @intCast(p.esc_bits[part]));
            } else {
                try bw.writeBits(p.params[part], width);
                for (samples) |r| try bw.writeRice(r, @intCast(p.params[part]));
            }
        }
    }
};

// Tests

const Signal = enum { sine, noise, silence, square, music, constant };

fn makeInts(gpa: std.mem.Allocator, kind: Signal, channels: usize, frames: usize, bits: u8) ![]i32 {
    const out = try gpa.alloc(i32, channels * frames);
    const half: i64 = @as(i64, 1) << @intCast(bits - 1);
    var rng: u64 = 0x9e3779b97f4a7c15 ^ (@as(u64, bits) << 8) ^ channels;
    for (0..frames) |f| {
        for (0..channels) |c| {
            const t: f64 = @floatFromInt(f);
            const w: f64 = 2.0 * std.math.pi / 44100.0;
            const freq: f64 = 440.0 * @as(f64, @floatFromInt(c + 1));
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            const r: i64 = @intCast(rng >> 40);
            const v: i64 = switch (kind) {
                .sine => @intFromFloat(@round(0.8 * @as(f64, @floatFromInt(half)) * @sin(w * freq * t))),
                .noise => @mod(r, half * 2) - half,
                .silence => 0,
                .square => if (((f + c * 13) / 50) % 2 == 0) half - 1 else -half,
                .music => blk: {
                    const a = @as(f64, @floatFromInt(half)) * 0.25;
                    const s = a * (@sin(w * freq * t) + @sin(w * freq * 2.7 * t + 1.0) + 0.5 * @sin(w * freq * 0.31 * t));
                    const noise: i64 = @mod(r, @max(1, @divTrunc(half, 256))) - @divTrunc(half, 512);
                    break :blk @as(i64, @intFromFloat(@round(s))) + noise;
                },
                .constant => @divTrunc(half, 3),
            };
            out[f * channels + c] = @intCast(std.math.clamp(v, -half, half - 1));
        }
    }
    return out;
}

fn toFloats(gpa: std.mem.Allocator, ints: []const i32, bits: u8) ![]f32 {
    const out = try gpa.alloc(f32, ints.len);
    const scale: f32 = @floatFromInt(@as(i64, 1) << @intCast(bits - 1));
    for (out, ints) |*o, i| o.* = @as(f32, @floatFromInt(i)) / scale;
    return out;
}

fn testInfo(channels: u8) codec.Info {
    return .{ .rate = 44100, .channels = channels, .mask = .{}, .total_frames = null, .bits_per_sample = 16 };
}

fn encodeInts(gpa: std.mem.Allocator, options: Options, channels: u8, ints: []const i32, chunk: usize) ![]u8 {
    const floats = try toFloats(gpa, ints, options.bits);
    defer gpa.free(floats);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var enc: Encoder = try .init(gpa, &aw.writer, options, testInfo(channels));
    defer enc.deinit();
    var at: usize = 0;
    while (at < floats.len) {
        const end = @min(floats.len, at + chunk * channels);
        try enc.write(floats[at..end]);
        at = end;
    }
    try enc.finish();
    return aw.toOwnedSlice();
}

fn expectDecodes(gpa: std.mem.Allocator, bytes: []const u8, channels: u8, bits: u8, ints: []const i32) !void {
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: decode.Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(u8, channels), dec.info().channels);
    try testing.expectEqual(bits, dec.info().bits_per_sample);
    const got = try gpa.alloc(i32, ints.len + channels);
    defer gpa.free(got);
    var have: usize = 0;
    while (true) {
        const end = @min(got.len, have + 1000 * @as(usize, channels));
        const n = try dec.readInt(got[have..end]);
        if (n == 0) break;
        have += n * channels;
    }
    try testing.expectEqualSlices(i32, ints, got[0..have]);
}

fn roundTrip(gpa: std.mem.Allocator, options: Options, channels: u8, kind: Signal, frames: usize) !usize {
    const ints = try makeInts(gpa, kind, channels, frames, options.bits);
    defer gpa.free(ints);
    const bytes = try encodeInts(gpa, options, channels, ints, 777);
    defer gpa.free(bytes);
    try expectDecodes(gpa, bytes, channels, options.bits, ints);
    return bytes.len;
}

test "every level round trips every signal in stereo" {
    for (0..9) |level| {
        for ([_]Signal{ .sine, .noise, .silence, .square, .music, .constant }) |kind| {
            _ = try roundTrip(testing.allocator, .{ .level = @intCast(level), .bits = 16 }, 2, kind, 9000);
        }
    }
}

test "one to eight channels round trip at 8, 16 and 24 bits" {
    for ([_]u4{ 0, 4, 8 }) |level| {
        for ([_]u8{ 8, 16, 24 }) |bits| {
            for (1..9) |channels| {
                _ = try roundTrip(testing.allocator, .{ .level = level, .bits = bits }, @intCast(channels), .music, 5000);
            }
        }
    }
}

test "every bit depth from 8 to 24 round trips" {
    for (8..25) |bits| {
        for ([_]u8{ 1, 2 }) |channels| {
            _ = try roundTrip(testing.allocator, .{ .level = 5, .bits = @intCast(bits) }, channels, .music, 3000);
            _ = try roundTrip(testing.allocator, .{ .level = 8, .bits = @intCast(bits) }, channels, .noise, 1500);
        }
    }
}

test "full scale square and noise round trip at 24 bits in every level" {
    for (0..9) |level| {
        for ([_]Signal{ .square, .noise }) |kind| {
            _ = try roundTrip(testing.allocator, .{ .level = @intCast(level), .bits = 24 }, 2, kind, 4500);
        }
    }
}

test "short streams and short last blocks round trip" {
    for ([_]usize{ 0, 1, 2, 3, 4, 5, 15, 16, 17, 100, 1151, 1152, 1153, 4096, 4097 }) |frames| {
        for ([_]u4{ 0, 5, 8 }) |level| {
            for ([_]u8{ 1, 2, 3 }) |channels| {
                _ = try roundTrip(testing.allocator, .{ .level = level, .bits = 16 }, channels, .music, frames);
            }
        }
    }
}

test "every stereo assignment round trips and is written" {
    const gpa = testing.allocator;
    const codes = [_]struct { mode: Assignment, code: u8 }{
        .{ .mode = .independent, .code = 1 },
        .{ .mode = .left_side, .code = 8 },
        .{ .mode = .right_side, .code = 9 },
        .{ .mode = .mid_side, .code = 10 },
    };
    for ([_]u8{ 8, 16, 24 }) |bits| {
        for (codes) |entry| {
            const ints = try makeInts(gpa, .music, 2, 4096, bits);
            defer gpa.free(ints);
            const floats = try toFloats(gpa, ints, bits);
            defer gpa.free(floats);
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            var enc: Encoder = try .init(gpa, &aw.writer, .{ .level = 5, .bits = bits }, testInfo(2));
            defer enc.deinit();
            try enc.writeWith(floats, entry.mode);
            try enc.finish();
            const bytes = aw.written();
            try testing.expectEqual(entry.code, bytes[42 + 3] >> 4);
            try expectDecodes(gpa, bytes, 2, bits, ints);
        }
    }
}

test "level 5 picks mid side for a signal with a loud common part" {
    const gpa = testing.allocator;
    const ints = try gpa.alloc(i32, 2 * 4096);
    defer gpa.free(ints);
    var rng: u32 = 12345;
    for (0..4096) |f| {
        rng = rng *% 1664525 +% 1013904223;
        const common: i32 = @as(i32, @intCast(rng >> 18)) - 8192;
        ints[f * 2] = common + @as(i32, @intCast(f % 5));
        ints[f * 2 + 1] = common - @as(i32, @intCast(f % 3));
    }
    const bytes = try encodeInts(gpa, .{ .level = 5, .bits = 16 }, 2, ints, 4096);
    defer gpa.free(bytes);
    try testing.expect(bytes[42 + 3] >> 4 >= 8);
    try expectDecodes(gpa, bytes, 2, 16, ints);
}

test "compression sanity" {
    const gpa = testing.allocator;
    const music = try makeInts(gpa, .music, 2, 20000, 16);
    defer gpa.free(music);
    const small = try encodeInts(gpa, .{ .level = 8, .bits = 16 }, 2, music, 4096);
    defer gpa.free(small);
    const big = try encodeInts(gpa, .{ .level = 0, .bits = 16 }, 2, music, 4096);
    defer gpa.free(big);
    try testing.expect(small.len <= big.len);
    try testing.expect(small.len < music.len * 2 * 8 / 10);

    const sine = try makeInts(gpa, .sine, 1, 20000, 16);
    defer gpa.free(sine);
    const bytes = try encodeInts(gpa, .{ .level = 5, .bits = 16 }, 1, sine, 4096);
    defer gpa.free(bytes);
    try testing.expect(bytes.len * 100 < sine.len * 2 * 40);
}

test "constant blocks and wasted bits are coded compactly" {
    const gpa = testing.allocator;
    const flat = try makeInts(gpa, .constant, 1, 4096, 16);
    defer gpa.free(flat);
    const flat_bytes = try encodeInts(gpa, .{ .level = 5, .bits = 16 }, 1, flat, 4096);
    defer gpa.free(flat_bytes);
    // 42 header bytes, then 6 frame header bytes, 3 subframe bytes and 2 CRC bytes.
    try testing.expectEqual(@as(usize, 42 + 6 + 3 + 2), flat_bytes.len);
    try expectDecodes(gpa, flat_bytes, 1, 16, flat);

    const silent = try makeInts(gpa, .silence, 2, 4096, 16);
    defer gpa.free(silent);
    const silent_bytes = try encodeInts(gpa, .{ .level = 8, .bits = 16 }, 2, silent, 4096);
    defer gpa.free(silent_bytes);
    try testing.expect(silent_bytes.len < 42 + 20);
    try expectDecodes(gpa, silent_bytes, 2, 16, silent);

    const noise = try makeInts(gpa, .noise, 1, 4096, 12);
    defer gpa.free(noise);
    const shifted = try gpa.alloc(i32, noise.len);
    defer gpa.free(shifted);
    for (shifted, noise) |*s, n| s.* = n * 16;
    const plain_bytes = try encodeInts(gpa, .{ .level = 3, .bits = 16 }, 1, shifted, 4096);
    defer gpa.free(plain_bytes);
    try expectDecodes(gpa, plain_bytes, 1, 16, shifted);
    // 12 bit noise in 16 bit samples: the 4 low bits are dropped.
    try testing.expect(plain_bytes.len < 42 + 4096 * 13 / 8 + 20);
}

test "full scale noise falls back to verbatim subframes" {
    const gpa = testing.allocator;
    const noise = try makeInts(gpa, .noise, 2, 9000, 16);
    defer gpa.free(noise);
    for ([_]u4{ 0, 2, 5, 8 }) |level| {
        const bytes = try encodeInts(gpa, .{ .level = level, .bits = 16 }, 2, noise, 4096);
        defer gpa.free(bytes);
        const block: usize = if (level <= 2) 1152 else 4096;
        const n_frames = (9000 + block - 1) / block;
        try testing.expect(bytes.len <= 42 + noise.len * 2 + n_frames * 22);
        try expectDecodes(gpa, bytes, 2, 16, noise);
    }
}

test "uniform noise uses escape partitions and still decodes" {
    const gpa = testing.allocator;
    const ints = try gpa.alloc(i32, 4096);
    defer gpa.free(ints);
    var rng: u32 = 7;
    for (ints) |*x| {
        rng = rng *% 1664525 +% 1013904223;
        x.* = @as(i32, @intCast(rng >> 21)) - 1024;
    }
    const bytes = try encodeInts(gpa, .{ .level = 0, .bits = 16 }, 1, ints, 4096);
    defer gpa.free(bytes);
    try expectDecodes(gpa, bytes, 1, 16, ints);
    // 11 bit samples cost 11 bits each with escape and about 11.5 with Rice codes.
    try testing.expect(bytes.len < 42 + 4096 * 112 / 80 + 30);
}

test "plain writer leaves the total and the MD5 unset" {
    const gpa = testing.allocator;
    const ints = try makeInts(gpa, .music, 2, 6000, 16);
    defer gpa.free(ints);
    const bytes = try encodeInts(gpa, .{ .level = 5, .bits = 16 }, 2, ints, 1000);
    defer gpa.free(bytes);
    try testing.expectEqualStrings("fLaC", bytes[0..4]);
    try testing.expectEqual(@as(u8, 0x80), bytes[4]);
    try testing.expectEqual(@as(u24, 34), std.mem.readInt(u24, bytes[5..8], .big));
    try testing.expectEqual(@as(u16, 4096), std.mem.readInt(u16, bytes[8..10], .big));
    try testing.expectEqual(@as(u16, 4096), std.mem.readInt(u16, bytes[10..12], .big));
    try testing.expectEqual(@as(u24, 0), std.mem.readInt(u24, bytes[12..15], .big));
    try testing.expectEqual(@as(u24, 0), std.mem.readInt(u24, bytes[15..18], .big));
    const tail = std.mem.readInt(u64, bytes[18..26], .big);
    try testing.expectEqual(@as(u64, 44100), tail >> 44);
    try testing.expectEqual(@as(u64, 1), (tail >> 41) & 7);
    try testing.expectEqual(@as(u64, 15), (tail >> 36) & 31);
    try testing.expectEqual(@as(u64, 0), tail & ((@as(u64, 1) << 36) - 1));
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0)), bytes[26..42]);

    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: decode.Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, null), dec.info().total_frames);
}

fn encodeToFile(gpa: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, options: Options, ints: []const i32, channels: u8, streaming: @FieldType(std.Io.File.Writer, "seek_err")) !bool {
    const floats = try toFloats(gpa, ints, options.bits);
    defer gpa.free(floats);
    var file = try dir.createFile(testing.io, name, .{});
    defer file.close(testing.io);
    var wbuf: [64]u8 = undefined;
    var fw = file.writer(testing.io, &wbuf);
    if (streaming) |err| {
        fw.mode = .streaming;
        fw.seek_err = err;
    }
    var enc: Encoder = try .initFile(gpa, &fw, options, testInfo(channels));
    defer enc.deinit();
    const cut = floats.len / channels / 3 * channels;
    try enc.write(floats[0..cut]);
    try testing.expect(!enc.sizes_fixed);
    try enc.write(floats[cut..]);
    try enc.finish();
    return enc.sizes_fixed;
}

test "a seekable file gets the total, the MD5 and the sizes fixed" {
    if (!io.has_files) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ints = try makeInts(gpa, .music, 2, 10000, 16);
    defer gpa.free(ints);
    try testing.expect(try encodeToFile(gpa, tmp.dir, "a.flac", .{ .level = 5, .bits = 16 }, ints, 2, null));
    const bytes = try tmp.dir.readFileAlloc(testing.io, "a.flac", gpa, .limited(1 << 22));
    defer gpa.free(bytes);
    try testing.expectEqual(@as(u16, 4096), std.mem.readInt(u16, bytes[8..10], .big));
    try testing.expectEqual(@as(u16, 4096), std.mem.readInt(u16, bytes[10..12], .big));
    const min_frame = std.mem.readInt(u24, bytes[12..15], .big);
    const max_frame = std.mem.readInt(u24, bytes[15..18], .big);
    try testing.expect(min_frame > 0 and min_frame <= max_frame);
    try testing.expect(max_frame < bytes.len);
    const tail = std.mem.readInt(u64, bytes[18..26], .big);
    try testing.expectEqual(@as(u64, 10000), tail & ((@as(u64, 1) << 36) - 1));
    var want: [16]u8 = undefined;
    var md5: std.crypto.hash.Md5 = .init(.{});
    for (ints) |x| {
        var b: [2]u8 = undefined;
        std.mem.writeInt(i16, &b, @intCast(x), .little);
        md5.update(&b);
    }
    md5.final(&want);
    try testing.expectEqualSlices(u8, &want, bytes[26..42]);

    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: decode.Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 10000), dec.info().total_frames);
    var buf: [2 * 500]i32 = undefined;
    while (try dec.readInt(&buf) != 0) {}
    try testing.expectEqual(@as(?bool, true), dec.md5Matches());
    try testing.expectEqual(@as(u32, 0), dec.stats().oversized_frames);
}

test "a stream shorter than one block records its own block and frame size" {
    if (!io.has_files) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ints = try makeInts(gpa, .music, 1, 300, 16);
    defer gpa.free(ints);
    try testing.expect(try encodeToFile(gpa, tmp.dir, "b.flac", .{ .level = 8, .bits = 16 }, ints, 1, null));
    const bytes = try tmp.dir.readFileAlloc(testing.io, "b.flac", gpa, .limited(1 << 22));
    defer gpa.free(bytes);
    try testing.expectEqual(@as(u16, 300), std.mem.readInt(u16, bytes[8..10], .big));
    try testing.expectEqual(@as(u16, 300), std.mem.readInt(u16, bytes[10..12], .big));
    const frame_len = bytes.len - 42;
    try testing.expectEqual(@as(u24, @intCast(frame_len)), std.mem.readInt(u24, bytes[12..15], .big));
    try testing.expectEqual(@as(u24, @intCast(frame_len)), std.mem.readInt(u24, bytes[15..18], .big));
}

test "an unseekable file keeps the unknown STREAMINFO" {
    if (!io.has_files) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ints = try makeInts(gpa, .music, 2, 5000, 16);
    defer gpa.free(ints);
    try testing.expect(!try encodeToFile(gpa, tmp.dir, "c.flac", .{ .level = 3, .bits = 16 }, ints, 2, error.Unseekable));
    const bytes = try tmp.dir.readFileAlloc(testing.io, "c.flac", gpa, .limited(1 << 22));
    defer gpa.free(bytes);
    try testing.expectEqual(@as(u24, 0), std.mem.readInt(u24, bytes[12..15], .big));
    const tail = std.mem.readInt(u64, bytes[18..26], .big);
    try testing.expectEqual(@as(u64, 0), tail & ((@as(u64, 1) << 36) - 1));
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0)), bytes[26..42]);
    try expectDecodes(gpa, bytes, 2, 16, ints);
}

test "a failed seek other than Unseekable is WriteFailed" {
    if (!io.has_files) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ints = try makeInts(gpa, .music, 1, 100, 16);
    defer gpa.free(ints);
    const floats = try toFloats(gpa, ints, 16);
    defer gpa.free(floats);
    var file = try tmp.dir.createFile(testing.io, "d.flac", .{});
    defer file.close(testing.io);
    var wbuf: [64]u8 = undefined;
    var fw = file.writer(testing.io, &wbuf);
    fw.mode = .streaming;
    fw.seek_err = error.AccessDenied;
    var enc: Encoder = try .initFile(gpa, &fw, .{}, testInfo(1));
    defer enc.deinit();
    try enc.write(floats);
    try testing.expectError(error.WriteFailed, enc.finish());
    try testing.expect(!enc.sizes_fixed);
}

test "a channel mask that is not the default is stored as a comment" {
    const gpa = testing.allocator;
    const ints = try makeInts(gpa, .music, 6, 500, 16);
    defer gpa.free(ints);
    const floats = try toFloats(gpa, ints, 16);
    defer gpa.free(floats);
    const odd: codec.ChannelMask = @bitCast(@as(u32, 0x3f));
    const cases = [_]struct { mask: codec.ChannelMask, tagged: bool, want: u32 }{
        .{ .mask = .{}, .tagged = false, .want = 0x60f },
        .{ .mask = @bitCast(@as(u32, 0x60f)), .tagged = false, .want = 0x60f },
        .{ .mask = odd, .tagged = true, .want = 0x3f },
    };
    for (cases) |case| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var info = testInfo(6);
        info.mask = case.mask;
        var enc: Encoder = try .init(gpa, &aw.writer, .{}, info);
        defer enc.deinit();
        try enc.write(floats);
        try enc.finish();
        const bytes = aw.written();
        try testing.expectEqual(!case.tagged, bytes[4] & 0x80 != 0);
        var input: io.Input = .init(.{ .bytes = bytes });
        var dec: decode.Decoder = try .init(gpa, &input);
        defer dec.deinit();
        try testing.expectEqual(case.want, @as(u32, @bitCast(dec.info().mask)));
        try expectDecodes(gpa, bytes, 6, 16, ints);
    }
}

test "the frame header carries the rate and block size codes" {
    const gpa = testing.allocator;
    const rates = [_]struct { rate: u32, code: u8 }{
        .{ .rate = 44100, .code = 9 },
        .{ .rate = 192000, .code = 3 },
        .{ .rate = 11000, .code = 12 },
        .{ .rate = 12345, .code = 13 },
        .{ .rate = 400010, .code = 14 },
        .{ .rate = 1000001, .code = 0 },
    };
    const ints = try makeInts(gpa, .sine, 1, 300, 16);
    defer gpa.free(ints);
    const floats = try toFloats(gpa, ints, 16);
    defer gpa.free(floats);
    for (rates) |entry| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var info = testInfo(1);
        info.rate = entry.rate;
        var enc: Encoder = try .init(gpa, &aw.writer, .{ .level = 8 }, info);
        defer enc.deinit();
        try enc.write(floats);
        try enc.finish();
        const bytes = aw.written();
        // Block size 300 uses the 16 bit field (code 7) and the frame number is one byte.
        try testing.expectEqual(@as(u8, 0xff), bytes[42]);
        try testing.expectEqual(@as(u8, 0xf8), bytes[43]);
        try testing.expectEqual(@as(u8, 7), bytes[44] >> 4);
        try testing.expectEqual(entry.code, bytes[44] & 15);
        try testing.expectEqual(@as(u8, 4 << 1), bytes[45] & 0xf);
        try testing.expectEqual(@as(u8, 0), bytes[46]);
        try testing.expectEqual(@as(u16, 299), std.mem.readInt(u16, bytes[47..49], .big));
        var input: io.Input = .init(.{ .bytes = bytes });
        var dec: decode.Decoder = try .init(gpa, &input);
        defer dec.deinit();
        try testing.expectEqual(entry.rate, dec.info().rate);
        try expectDecodes(gpa, bytes, 1, 16, ints);
    }
}

test "the encoder rejects bad parameters" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .level = 9 }, testInfo(2)));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .bits = 7 }, testInfo(2)));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .bits = 25 }, testInfo(2)));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .bits = 32 }, testInfo(2)));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{}, testInfo(0)));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{}, testInfo(9)));
    var info = testInfo(2);
    info.rate = 0;
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{}, info));
    info.rate = 1 << 20;
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{}, info));
    info = testInfo(2);
    info.mask = @bitCast(@as(u32, 0x7));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{}, info));
}

test "write takes whole frames and stops after finish" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc: Encoder = try .init(gpa, &aw.writer, .{}, testInfo(2));
    defer enc.deinit();
    try testing.expectError(error.Unsupported, enc.write(&.{ 0.0, 0.0, 0.0 }));
    try enc.write(&.{ 0.5, -0.5 });
    try enc.finish();
    try enc.finish();
    try testing.expectError(error.Unsupported, enc.write(&.{ 0.0, 0.0 }));
}

test "input rounds, clamps and maps NaN to silence" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc: Encoder = try .init(gpa, &aw.writer, .{ .bits = 8 }, testInfo(1));
    defer enc.deinit();
    try enc.write(&.{ 1.5, -1.5, std.math.nan(f32), 0.5, 0.2, -0.2, 1.0, -1.0 });
    try enc.finish();
    try expectDecodes(gpa, aw.written(), 1, 8, &.{ 127, -128, 0, 64, 26, -26, 127, -128 });
}

test "encoding does not allocate after init" {
    var buf: [1 << 20]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const gpa = fba.allocator();
    var out: [1 << 16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    var enc: Encoder = try .init(gpa, &w, .{ .level = 8 }, testInfo(2));
    defer enc.deinit();
    const used = fba.end_index;
    const ints = try makeInts(testing.allocator, .music, 2, 9000, 16);
    defer testing.allocator.free(ints);
    const floats = try toFloats(testing.allocator, ints, 16);
    defer testing.allocator.free(floats);
    try enc.write(floats);
    try enc.finish();
    try testing.expectEqual(used, fba.end_index);
}

test "every level round trips short inputs in 1, 2, 6 and 8 channels" {
    for (0..9) |level| {
        for ([_]u8{ 1, 2, 6, 8 }) |channels| {
            for ([_]usize{ 50, 1300 }) |frames| {
                _ = try roundTrip(testing.allocator, .{ .level = @intCast(level), .bits = 16 }, channels, .music, frames);
            }
        }
    }
}

test "loose levels pick the assignment from the first differences" {
    const gpa = testing.allocator;
    // Equal channels: the side signal is flat, so the first tie goes to left/side.
    const ints = try gpa.alloc(i32, 2 * 4096);
    defer gpa.free(ints);
    var rng: u32 = 5;
    for (0..4096) |f| {
        rng = rng *% 1664525 +% 1013904223;
        const v = @as(i32, @intCast(rng >> 18)) - 8192;
        ints[f * 2] = v;
        ints[f * 2 + 1] = v;
    }
    for ([_]u4{ 1, 4 }) |level| {
        const bytes = try encodeInts(gpa, .{ .level = level, .bits = 16 }, 2, ints, 4096);
        defer gpa.free(bytes);
        try testing.expectEqual(@as(u8, 8), bytes[42 + 3] >> 4);
        try expectDecodes(gpa, bytes, 2, 16, ints);
    }
}
