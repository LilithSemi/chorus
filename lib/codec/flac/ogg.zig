//! FLAC in Ogg. The first packet is the mapping header, then come the metadata packets
//! and one FLAC frame per packet.
//!
//! Seeking uses the page granules. `seek` works across the links of a chained file, and
//! `read` continues from one link into the next.
//! A stream with more than 1024 header packets gives error.BadHeader.
const std = @import("std");
const codec = @import("../../codec.zig");
const io = @import("../io.zig");
const packets = @import("../ogg.zig");
const ogg_chain = @import("../ogg_chain.zig");
const vorbis_comment = @import("../vorbis_comment.zig");
const decode = @import("decode.zig");
const flac_core = @import("core.zig");
const encode = @import("encode.zig");
const helpers = @import("../testing.zig");
const testing = std.testing;

/// Limit for the header packets, which can hold pictures.
const header_packet_limit = 1 << 22;
/// A stream with more header packets than this gives error.BadHeader.
const max_header_packets = 1024;
const max_frame_bound = 16 << 20;
const mapping_size = encode.mapping_size;

pub fn isMapping(context: ?*anyopaque, packet: []const u8) bool {
    _ = context;
    return packet.len >= 5 and std.mem.eql(u8, packet[0..5], "\x7fFLAC");
}

const initError = ogg_chain.initError;

/// The size of the read buffer. A frame past it gives error.BadData, which only a
/// pathological legal encoding reaches. A frame past the STREAMINFO maximum frame size is
/// counted in the stats, and it is an error with `Options.strict_metadata`.
fn frameBound(si: anytype) usize {
    const bits = @as(u64, si.max_block) * si.channels * 33;
    const natural = bits / 8 + 1024;
    return @intCast(@min(max_frame_bound, @max(si.max_frame, natural)));
}

/// What the header packets of a link tell.
const LinkHeaders = struct {
    streaminfo: [34]u8,
    mask: ?u32,
    /// The first audio packet, or the first packet of the next link when the link has none.
    held: ?packets.Packet,
    /// The size of the biggest packet that the read took, the mapping packet included.
    biggest: usize,
};

/// Reads the header packets that follow the mapping packet `first`, and marks the start of
/// the audio in the reader. The packet limit of the reader must allow header packets.
fn readLinkHeaders(reader: *packets.PacketReader, first: []const u8) codec.InitError!LinkHeaders {
    const m = first;
    if (m.len < 6) return error.BadHeader;
    if (m[5] != 1) return error.Unsupported;
    if (m.len != mapping_size) return error.BadHeader;
    if (!std.mem.eql(u8, m[9..13], "fLaC") or m[13] & 0x7f != 0) return error.BadHeader;
    if (std.mem.readInt(u24, m[14..17], .big) != 34) return error.BadHeader;
    const streaminfo: [34]u8 = m[17..51].*;
    const count: usize = std.mem.readInt(u16, m[7..9], .big);

    var mask: ?u32 = null;
    var held: ?packets.Packet = null;
    var seen: usize = 0;
    var biggest: usize = m.len;
    while (true) : (seen += 1) {
        if (seen >= max_header_packets and (count == 0 or seen < count)) return error.BadHeader;
        const p = (reader.next() catch |err| return initError(err)) orelse {
            if (count != 0 and seen < count) return error.Truncated;
            break;
        };
        const d = p.data;
        biggest = @max(biggest, d.len);
        if (p.bos) {
            if (count != 0 and seen < count) return error.Truncated;
            held = p;
            break;
        }
        if (count != 0 and seen >= count) {
            held = p;
            reader.markAudio(p);
            break;
        }
        if (d.len == 0) return error.BadHeader;
        if (d[0] == 0xff) {
            if (count != 0) return error.BadHeader;
            held = p;
            reader.markAudio(p);
            break;
        }
        if (d.len < 4 or d[0] & 0x7f == 127 or d[0] & 0x7f == 0) return error.BadHeader;
        if (std.mem.readInt(u24, d[1..4], .big) != d.len - 4) return error.BadHeader;
        if (d[0] & 0x7f == 4) mask = try vorbis_comment.channelMask(d[4..]);
    }
    return .{ .streaminfo = streaminfo, .mask = mask, .held = held, .biggest = biggest };
}

/// The FLAC part of a chained Ogg decoder. `ogg_chain.Chain` calls it for each link.
const FlacCodec = struct {
    core: flac_core.Core,
    /// Sample number of the first frame of the link.
    first_sample: ?u64 = null,
    /// Seeks that found a granule that disagrees with the frames and scanned from the start.
    rescans: u32 = 0,
    /// A link before the current one failed the MD5 check.
    md5_bad: bool = false,
    /// A link before the current one passed the MD5 check.
    md5_good: bool = false,
    /// The resync count when the current link started.
    link_resyncs: u32 = 0,

    pub const Headers = LinkHeaders;
    pub const max_header_packet = header_packet_limit;
    pub const isFirst = isMapping;

    pub fn skipBad(self: *FlacCodec) bool {
        if (self.core.options.on_bad_frame != .resync) return false;
        self.core.skipPacket(0);
        return true;
    }

    /// The STREAMINFO total is exact. Without it the last granule less the start of the link is
    /// a hint. The start is the granule of the first audio page less the block sizes of its
    /// frames, which the frame headers give with the STREAMINFO of the link.
    pub fn linkLength(self: *FlacCodec, h: *const LinkHeaders, link: *const packets.Link, reader: *packets.PacketReader) ?ogg_chain.Length {
        const start = self.measureStart(h, reader);
        const head = link.firstBytes();
        if (head.len == mapping_size and isMapping(null, head)) {
            const streaminfo: *const [34]u8 = head[17..51];
            const total = std.mem.readInt(u64, streaminfo[10..18], .big) & ((@as(u64, 1) << 36) - 1);
            if (total != 0) return .{ .frames = total, .trusted = true, .start = start };
        }
        const last = link.last_granule orelse return null;
        return .{ .frames = if (last > start) @intCast(last - start) else 0, .trusted = false, .start = start };
    }

    fn measureStart(self: *FlacCodec, h: *const LinkHeaders, reader: *packets.PacketReader) i64 {
        const si = flac_core.parseStreamInfo(&h.streaminfo) catch return 0;
        // The STREAMINFO and the bit reader of the core belong to the current link.
        const saved_si = self.core.si;
        const saved_bits = self.core.bits;
        defer {
            self.core.si = saved_si;
            self.core.bits = saved_bits;
        }
        self.core.si = si;
        var counted: i64 = 0;
        var next = h.held;
        while (next) |p| {
            if (p.bos) break;
            // A frame that does not parse is skipped by the read and counted here as a frame of
            // the usual size, so the start does not move.
            counted +|= if (self.core.peekFrame(p.data)) |frame| frame.block else si.max_block;
            if (p.granule != -1) return p.granule -| counted;
            next = reader.next() catch break;
        }
        return 0;
    }

    pub fn readHeaders(self: *FlacCodec, reader: *packets.PacketReader, first: []const u8) codec.InitError!LinkHeaders {
        _ = self;
        return readLinkHeaders(reader, first);
    }

    pub fn releaseHeaders(self: *FlacCodec, h: *LinkHeaders) void {
        _ = self;
        _ = h;
    }

    pub fn deinit(self: *FlacCodec) void {
        self.core.deinit();
    }

    pub fn reserve(self: *FlacCodec, h: *const LinkHeaders) codec.InitError!usize {
        try self.core.reserveSamples(&h.streaminfo);
        const si = try flac_core.parseStreamInfo(&h.streaminfo);
        return frameBound(si);
    }

    pub fn enter(self: *FlacCodec, h: *LinkHeaders) codec.InitError!usize {
        const core = &self.core;
        if (core.md5_result == false) self.md5_bad = true;
        if (core.md5_result == true) self.md5_good = true;
        try core.resetStream(&h.streaminfo, h.mask);
        self.link_resyncs = core.stats().resyncs;
        return frameBound(core.si);
    }

    /// Learns from the first audio packet of the link where its frames start.
    pub fn settle(self: *FlacCodec, first: ?packets.Packet) bool {
        self.first_sample = if (first) |p| (if (self.core.peekFrame(p.data)) |f| f.sample else null) else null;
        self.core.origin = self.first_sample orelse 0;
        return if (first) |p| !p.bos else false;
    }

    pub fn sameShape(self: *const FlacCodec, h: *const LinkHeaders) bool {
        const shape = flac_core.streamShape(&h.streaminfo);
        return shape.rate == self.core.si.rate and shape.channels == self.core.si.channels;
    }

    pub fn info(self: *const FlacCodec) codec.Info {
        return self.core.info();
    }

    pub fn canLoad(self: *const FlacCodec) flac_core.FrameError!bool {
        if (self.core.failed) |err| return err;
        return !self.core.at_end;
    }

    pub fn fail(self: *FlacCodec, err: flac_core.FrameError) void {
        self.core.failed = err;
    }

    pub fn decode(self: *FlacCodec, packet: packets.Packet) flac_core.FrameError!bool {
        const data = packet.data;
        const core = &self.core;
        core.loadPacket(data, false) catch |err| {
            if (err == error.BadData and core.options.on_bad_frame == .resync and !core.strict_hit) {
                core.skipPacket(data.len);
                return false;
            }
            core.failed = err;
            return err;
        };
        return true;
    }

    pub fn endOfData(self: *FlacCodec) flac_core.FrameError!bool {
        return self.core.endOfData();
    }

    pub fn endLink(self: *FlacCodec) flac_core.FrameError!void {
        const core = &self.core;
        _ = try core.endData(core.stats().resyncs != self.link_resyncs);
    }

    pub fn read(self: *FlacCodec, comptime T: type, out: []T, loader: anytype) flac_core.FrameError!usize {
        return self.core.readLoop(T, out, loader);
    }

    pub fn beginSeek(self: *FlacCodec) void {
        self.core.clearPosition();
        self.md5_bad = false;
        self.md5_good = false;
    }

    pub fn clearPosition(self: *FlacCodec) void {
        self.core.clearPosition();
    }

    pub fn linkTotal(self: *const FlacCodec) ?u64 {
        return self.core.stream.total_frames;
    }

    pub fn seekEnd(self: *FlacCodec, frames: u64) void {
        self.core.next_sample = frames;
        self.core.at_end = true;
    }

    pub fn failSeek(self: *FlacCodec, err: flac_core.FrameError) void {
        const core = &self.core;
        core.block_len = 0;
        core.block_pos = 0;
        core.next_sample = 0;
        core.failed = err;
    }

    pub fn seekIn(self: *FlacCodec, chain: anytype, local: u64) codec.SeekError!void {
        const core = &self.core;
        // The granules count from the sample number of the first frame of the link.
        const start: i64 = chain.linkStart() orelse 0;
        const wide = std.math.add(i64, std.math.cast(i64, local) orelse return error.Truncated, start) catch return error.Truncated;
        var from_granule = try self.positionAt(chain, wide, start);
        while (true) {
            self.walk(chain, local, from_granule) catch |err| switch (err) {
                error.Mismatch => {
                    // The granule and the frame numbers disagree. Scan from the start.
                    self.rescans +%= 1;
                    from_granule = try self.positionAt(chain, -1, 0);
                    core.clearPosition();
                    continue;
                },
                else => |e| return e,
            };
            return;
        }
    }

    /// Moves the reader to the page at or before `target` and skips to the first frame.
    /// Returns true when the position comes from a granule, which is `start` above the frame
    /// number of the link.
    fn positionAt(self: *FlacCodec, chain: anytype, target: i64, start: i64) codec.SeekError!bool {
        const core = &self.core;
        chain.held = null;
        if (try chain.reader.seekGranule(target)) |g| {
            const relative = std.math.sub(i64, g, start) catch return error.BadData;
            core.next_sample = std.math.cast(u64, relative) orelse return error.BadData;
            return true;
        }
        core.next_sample = 0;
        while (true) {
            const data = switch (try chain.nextData()) {
                .frame => |d| d,
                .link, .end => break,
            };
            if (data.data.len > 0 and data.data[0] == 0xff) {
                chain.held = data;
                break;
            }
        }
        return false;
    }

    fn walk(self: *FlacCodec, chain: anytype, frame: u64, check: bool) (codec.SeekError || error{Mismatch})!void {
        const core = &self.core;
        while (true) {
            const data = switch (try chain.nextData()) {
                .frame => |d| d,
                .link, .end => {
                    if (core.next_sample != frame) {
                        if (check) return error.Mismatch;
                        return error.Truncated;
                    }
                    core.block_len = 0;
                    core.block_pos = 0;
                    return;
                },
            };
            const expected = core.next_sample;
            try core.loadPacket(data.data, true);
            if (check and core.frame_sample -% (self.first_sample orelse 0) != expected) return error.Mismatch;
            if (frame < core.next_sample) {
                core.block_pos = @intCast(frame - (core.next_sample - core.block_len));
                return;
            }
        }
    }
};

const FlacChain = ogg_chain.Chain(FlacCodec);

/// Reads FLAC frames from an Ogg stream.
///
/// All the links of a chained file play as one stream. The frame positions of `seek` count
/// from the start of the first link. A link with the same rate and channel count as the
/// one before it continues without a signal. When the format changes, `read` gives
/// error.StreamChanged after the frames of the old link, and the next `read` continues
/// with the first frame of the new link.
pub const Decoder = struct {
    chain: FlacChain,

    pub fn init(gpa: std.mem.Allocator, input: *io.Input) codec.InitError!Decoder {
        return initOptions(gpa, input, .{});
    }

    pub fn initOptions(gpa: std.mem.Allocator, input: *io.Input, options: flac_core.Options) codec.InitError!Decoder {
        var reader = try packets.PacketReader.init(
            gpa,
            input,
            .{ .accept = .{ .func = isMapping } },
            .{ .max_packet_size = header_packet_limit },
        );
        const first = blk: {
            errdefer reader.deinit();
            break :blk (reader.next() catch |err| return initError(err)) orelse return error.Unsupported;
        };
        return initReader(gpa, input, reader, first.data, options);
    }

    /// Makes a decoder from a reader that has returned `first`, the mapping packet. The
    /// decoder takes the reader, also when this fails.
    ///
    /// On a seekable input this reads every page header of the file once, to find the links.
    /// On a custom source that reads over a network, the cost of `init` grows with the number
    /// of pages.
    pub fn initReader(
        gpa: std.mem.Allocator,
        input: *io.Input,
        reader_in: packets.PacketReader,
        first: []const u8,
        options: flac_core.Options,
    ) codec.InitError!Decoder {
        var reader = reader_in;
        var handed = false;
        errdefer if (!handed) reader.deinit();
        reader.select = .{ .accept = .{ .func = isMapping } };
        reader.begin_group_only = false;
        reader.max_packet = header_packet_limit;
        const h = try readLinkHeaders(&reader, first);
        var core: flac_core.Core = try .initPackets(gpa, input, &h.streaminfo, h.mask, options);
        errdefer if (!handed) core.deinit();
        var held = h.held;
        try ogg_chain.setBound(&reader, &held, frameBound(core.si));
        handed = true;
        return .{ .chain = try FlacChain.init(gpa, input, reader, .{ .core = core }, held) };
    }

    pub fn deinit(self: *Decoder) void {
        self.chain.deinit();
        self.* = undefined;
    }

    /// The rate, channels and mask are the ones of the current link. `total_frames` is the
    /// sum over the links when the input is seekable and every length is known, and it
    /// comes from the last page granule when STREAMINFO has no total. A reader that cannot
    /// seek only knows the current link, so it reports the total of that link.
    pub fn info(self: *const Decoder) codec.Info {
        return self.chain.info();
    }

    pub fn stats(self: *const Decoder) flac_core.Stats {
        return self.chain.codec.core.stats();
    }

    /// False when a link failed the check. True when a link passed and none failed. Null
    /// when no link has an MD5 or after a seek. See `flac.Decoder.md5Matches`.
    pub fn md5Matches(self: *const Decoder) ?bool {
        const c = &self.chain.codec;
        if (c.md5_bad) return false;
        return c.core.md5Matches() orelse if (c.md5_good) true else null;
    }

    /// Writes whole frames of f32 into `out` and returns the frame count. 0 means the end.
    /// `out` must hold at least one frame (`info().channels` samples).
    /// A frame bigger than the STREAMINFO maximum frame size gives error.BadData.
    ///
    /// When the next link of a chained file has another rate or channel count, the call
    /// after the last frame of the old link returns error.StreamChanged and no frames.
    /// `info()` then describes the new link, and the next call continues with its first
    /// frame.
    ///
    /// When the input is seekable and `init` found every link, `init` reads the headers of all
    /// links and reserves the memory for the biggest one, so `read` does not allocate when it
    /// enters a later link. On an input that cannot seek, entering a link can allocate, and an
    /// out of memory error there gives error.ReadFailed.
    pub fn read(self: *Decoder, out: []f32) codec.ReadError!usize {
        return self.chain.read(f32, out);
    }

    /// Like `read`, with the integer sample values.
    pub fn readInt(self: *Decoder, out: []i32) codec.ReadError!usize {
        return self.chain.read(i32, out);
    }

    /// Moves to a frame of the whole stream. `frame` equal to the frame count is the end of
    /// the data. A format change at a link is not reported by a seek: `info()` describes the
    /// link that the frame is in. A chained file whose link lengths are unknown gives
    /// error.Unsupported.
    pub fn seek(self: *Decoder, frame: u64) codec.SeekError!void {
        return self.chain.seek(frame);
    }
};

pub const Options = struct {
    /// 0 to 8, as the levels of the `flac` command line.
    level: u4 = 5,
    /// The sample depth, 8 to 24.
    bits: u8 = 16,
    /// The serial number of the Ogg stream.
    serial: u32 = 0,
};

/// Writes interleaved f32 frames as FLAC in Ogg. The frame coding is the one of
/// `encode.Encoder`, and each frame is one packet.
///
/// The first page holds only the mapping packet, the second page holds the Vorbis comment
/// block, and the audio starts on the third page. A page granule is the sample count at the
/// end of the last frame on the page.
///
/// With `init` the writer cannot seek, so STREAMINFO keeps total samples 0, the frame sizes
/// 0 and an unset MD5, which the format defines as unknown. With `initFile`, `finish` seeks
/// to the start and rewrites the first page with the real values and its page CRC, and sets
/// `sizes_fixed`. If the file reports error.Unseekable, `finish` leaves the unknown values.
pub const Encoder = struct {
    core: encode.Encoder,
    /// True after `finish` wrote the real STREAMINFO values.
    sizes_fixed: bool = false,

    pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, options: Options, info: codec.Info) codec.EncoderInitError!Encoder {
        return .{ .core = try .initOgg(gpa, writer, options.serial, .{ .level = options.level, .bits = options.bits }, info) };
    }

    pub fn initFile(gpa: std.mem.Allocator, file: *std.Io.File.Writer, options: Options, info: codec.Info) codec.EncoderInitError!Encoder {
        return .{ .core = try .initOggFile(gpa, file, options.serial, .{ .level = options.level, .bits = options.bits }, info) };
    }

    pub fn deinit(self: *Encoder) void {
        self.core.deinit();
        self.* = undefined;
    }

    /// `frames` holds whole interleaved frames.
    pub fn write(self: *Encoder, frames: []const f32) codec.WriteError!void {
        return self.core.write(frames);
    }

    pub fn finish(self: *Encoder) codec.WriteError!void {
        try self.core.finish();
        self.sizes_fixed = self.core.sizes_fixed;
    }
};

const embed = helpers.embed;
const readAll = helpers.readAll;

const sample_files = [_][]const u8{
    embed("s01-blocksize-4096"),
    embed("s24-variable-flake"),
    embed("s28-hires-96k-24bit"),
    embed("s43-channels-8"),
    embed("s60-mono"),
    embed("s03b-short-last-frame"),
};

const comment_with_mask = blk: {
    const key = "WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0x4";
    var b: [8 + 4 + key.len]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], 0, .little);
    std.mem.writeInt(u32, b[4..8], 1, .little);
    std.mem.writeInt(u32, b[8..12], key.len, .little);
    @memcpy(b[12..], key);
    break :blk b;
};

/// Cuts the frames of a native FLAC file at their boundaries and writes them to a
/// new Ogg stream. `comment` is the body of the VORBIS_COMMENT packet.
fn mux(gpa: std.mem.Allocator, file: []const u8, comment: []const u8, serial: u32, count: u16) ![]u8 {
    return muxPatched(gpa, file, comment, serial, count, .{});
}

const Patch = struct {
    md5: ?[16]u8 = null,
    max_frame: ?u24 = null,
    skew: i64 = 0,
    /// The skew applies from the frame with this index.
    skew_from: usize = 0,
    total: ?u64 = null,
    /// The indexes of frames that get a damaged byte. The page checksums stay valid.
    damage: []const usize = &.{},
    /// The damage goes in the frame header, so that the frame does not parse.
    ruin_headers: bool = false,
    /// A junk packet of `junk_len` bytes goes before the frame with this index.
    junk_at: ?usize = null,
    junk_len: usize = 0,
};

fn muxPatched(gpa: std.mem.Allocator, file: []const u8, comment: []const u8, serial: u32, count: u16, patch: Patch) ![]u8 {
    var streaminfo: [34]u8 = file[8..42].*;
    var scratch: io.Input = .init(.{ .bytes = file });
    var splitter: flac_core.Core = try .initPackets(gpa, &scratch, &streaminfo, null, .{});
    defer splitter.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var w: packets.PacketWriter = try .init(gpa, &aw.writer, serial, .{});
    defer w.deinit();

    var mapping = encode.mappingPacket(file[8..42], count);
    if (patch.md5) |m| @memcpy(mapping[35..51], &m);
    if (patch.max_frame) |m| std.mem.writeInt(u24, mapping[24..27], m, .big);
    if (patch.total) |t| {
        const mask36 = (@as(u64, 1) << 36) - 1;
        const tail = std.mem.readInt(u64, mapping[27..35], .big);
        std.mem.writeInt(u64, mapping[27..35], (tail & ~mask36) | t, .big);
    }
    try w.writePacket(&mapping, 0);
    try w.flush();
    var header: [4]u8 = undefined;
    header[0] = 0x84;
    std.mem.writeInt(u24, header[1..4], @intCast(comment.len), .big);
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(gpa);
    try block.appendSlice(gpa, &header);
    try block.appendSlice(gpa, comment);
    try w.writePacket(block.items, 0);
    try w.flush();

    // The metadata blocks of the native file end at the first frame sync.
    var pos: usize = 42;
    var last = file[4] & 0x80 != 0;
    while (!last) {
        last = file[pos] & 0x80 != 0;
        pos += 4 + std.mem.readInt(u24, file[pos + 1 ..][0..3], .big);
    }
    var granule: i64 = 0;
    var index: usize = 0;
    while (pos < file.len) : (index += 1) {
        var end = pos + 2;
        const frame = while (end <= file.len) : (end += 1) {
            const at_end = end == file.len;
            if (!at_end and !(end + 1 < file.len and file[end] == 0xff and file[end + 1] & 0xfe == 0xf8)) continue;
            _ = splitter.loadPacket(file[pos..end], true) catch continue;
            break file[pos..end];
        } else return error.NoFrame;
        if (patch.junk_at == index) {
            const junk = try gpa.alloc(u8, patch.junk_len);
            defer gpa.free(junk);
            @memset(junk, 0x55);
            try w.writePacket(junk, -1);
        }
        granule += @intCast(splitter.block_len);
        const skew: i64 = if (index >= patch.skew_from) patch.skew else 0;
        if (std.mem.indexOfScalar(usize, patch.damage, index) != null) {
            const copy = try gpa.dupe(u8, frame);
            defer gpa.free(copy);
            copy[if (patch.ruin_headers) 3 else copy.len / 2] ^= 0x55;
            try w.writePacket(copy, granule + skew);
        } else {
            try w.writePacket(frame, granule + skew);
        }
        pos = end;
    }
    try w.finish();
    return aw.toOwnedSlice();
}

fn nativeSamples(gpa: std.mem.Allocator, file: []const u8) ![]f32 {
    var input: io.Input = .init(.{ .bytes = file });
    var dec: decode.Decoder = try .init(gpa, &input);
    defer dec.deinit();
    return readAll(gpa, &dec, 4096);
}

test "Ogg FLAC decodes to the samples of the native file" {
    const gpa = testing.allocator;
    for (sample_files) |file| {
        const want = try nativeSamples(gpa, file);
        defer gpa.free(want);
        const stream = try mux(gpa, file, &comment_with_mask, 7, 1);
        defer gpa.free(stream);

        var input: io.Input = .init(.{ .bytes = stream });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        const got = try readAll(gpa, &dec, 4096);
        defer gpa.free(got);
        try testing.expect(want.len > 0);
        try testing.expectEqualSlices(f32, want, got);
        try testing.expect(dec.md5Matches() != false);
    }
}

test "Ogg FLAC output does not depend on the read size" {
    const gpa = testing.allocator;
    const stream = try mux(gpa, sample_files[1], &comment_with_mask, 1, 1);
    defer gpa.free(stream);
    var reference: ?[]f32 = null;
    defer if (reference) |r| gpa.free(r);
    for ([_]usize{ 4096, 1, 7 }) |chunk| {
        var input: io.Input = .init(.{ .bytes = stream });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        const got = try readAll(gpa, &dec, chunk);
        if (reference) |r| {
            defer gpa.free(got);
            try testing.expectEqualSlices(f32, r, got);
        } else {
            reference = got;
        }
    }
}

test "Ogg FLAC reports the channel mask and stream parameters" {
    const gpa = testing.allocator;
    const stream = try mux(gpa, sample_files[4], &comment_with_mask, 1, 1);
    defer gpa.free(stream);
    var input: io.Input = .init(.{ .bytes = stream });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const i = dec.info();
    try testing.expectEqual(@as(u32, 44100), i.rate);
    try testing.expectEqual(@as(u8, 1), i.channels);
    var native_input: io.Input = .init(.{ .bytes = sample_files[4] });
    var native: decode.Decoder = try .init(gpa, &native_input);
    defer native.deinit();
    // STREAMINFO has no total, so the last page granule gives it.
    try testing.expectEqual(@as(?u64, null), native.info().total_frames);
    try testing.expectEqual(@as(?u64, 12288), i.total_frames);
    try testing.expectEqual(@as(u32, 4), @as(u32, @bitCast(i.mask)));
}

test "Ogg FLAC with an unknown header count" {
    const gpa = testing.allocator;
    const want = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want);
    const stream = try mux(gpa, sample_files[0], &comment_with_mask, 1, 0);
    defer gpa.free(stream);
    var input: io.Input = .init(.{ .bytes = stream });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const got = try readAll(gpa, &dec, 100);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, want, got);
}

test "Ogg FLAC seek lands on the same samples as a full decode" {
    const gpa = testing.allocator;
    for (sample_files) |file| {
        const want = try nativeSamples(gpa, file);
        defer gpa.free(want);
        const stream = try mux(gpa, file, &comment_with_mask, 3, 1);
        defer gpa.free(stream);
        var input: io.Input = .init(.{ .bytes = stream });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        const channels: usize = dec.info().channels;
        const total: u64 = want.len / channels;
        const targets = [_]u64{ total / 2, 0, total - 1, 1, total / 3, total, 5 };
        for (targets) |t| {
            try dec.seek(t);
            const tail = try readAll(gpa, &dec, 33);
            defer gpa.free(tail);
            try testing.expectEqualSlices(f32, want[@as(usize, @intCast(t)) * channels ..], tail);
        }
        try testing.expectError(error.Truncated, dec.seek(total + 1));
    }
}

test "Ogg FLAC over a forward reader decodes and refuses to seek" {
    const gpa = testing.allocator;
    const want = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want);
    const stream = try mux(gpa, sample_files[0], &comment_with_mask, 1, 1);
    defer gpa.free(stream);
    var reader: std.Io.Reader = .fixed(stream);
    var input: io.Input = .init(.{ .reader = &reader });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectError(error.Unseekable, dec.seek(10));
    const got = try readAll(gpa, &dec, 4096);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, want, got);
}

fn muxChain(gpa: std.mem.Allocator, files: []const []const u8, patches: []const Patch) ![]u8 {
    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(gpa);
    for (files, patches, 0..) |file, patch, i| {
        const part = try muxPatched(gpa, file, &comment_with_mask, @intCast(i + 1), 1, patch);
        defer gpa.free(part);
        try all.appendSlice(gpa, part);
    }
    return all.toOwnedSlice(gpa);
}

const Part = struct {
    samples: []f32,
    changed: bool,
};

/// Reads until the end or until the stream changes.
fn readPart(gpa: std.mem.Allocator, dec: *Decoder, chunk: usize) !Part {
    const channels: usize = dec.info().channels;
    var all: std.ArrayList(f32) = .empty;
    errdefer all.deinit(gpa);
    const buf = try gpa.alloc(f32, chunk * channels);
    defer gpa.free(buf);
    while (true) {
        const n = dec.read(buf) catch |err| switch (err) {
            error.StreamChanged => return .{ .samples = try all.toOwnedSlice(gpa), .changed = true },
            else => |e| return e,
        };
        if (n == 0) break;
        try all.appendSlice(gpa, buf[0 .. n * channels]);
    }
    return .{ .samples = try all.toOwnedSlice(gpa), .changed = false };
}

test "two links with the same format read as one stream" {
    const gpa = testing.allocator;
    const want_a = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want_a);
    const want_b = try nativeSamples(gpa, sample_files[1]);
    defer gpa.free(want_b);
    const want = try std.mem.concat(gpa, f32, &.{ want_a, want_b });
    defer gpa.free(want);
    const chain = try muxChain(gpa, &.{ sample_files[0], sample_files[1] }, &.{ .{}, .{} });
    defer gpa.free(chain);

    for ([_]usize{ 4096, 1, 777 }) |chunk| {
        var input: io.Input = .init(.{ .bytes = chain });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        try testing.expectEqual(@as(?u64, want.len / 2), dec.info().total_frames);
        const got = try readAll(gpa, &dec, chunk);
        defer gpa.free(got);
        try testing.expectEqualSlices(f32, want, got);
    }

    // A source that cannot seek still continues across the links.
    var reader: std.Io.Reader = .fixed(chain);
    var forward_input: io.Input = .init(.{ .reader = &reader });
    var forward: Decoder = try .init(gpa, &forward_input);
    defer forward.deinit();
    const got = try readAll(gpa, &forward, 1000);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, want, got);
    try testing.expectError(error.Unseekable, forward.seek(0));
}

test "a link with other channels gives StreamChanged once" {
    const gpa = testing.allocator;
    const want_a = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want_a);
    const want_b = try nativeSamples(gpa, sample_files[4]);
    defer gpa.free(want_b);
    const chain = try muxChain(gpa, &.{ sample_files[0], sample_files[4] }, &.{ .{}, .{} });
    defer gpa.free(chain);

    var input: io.Input = .init(.{ .bytes = chain });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(u8, 2), dec.info().channels);
    try testing.expectEqual(@as(?u64, want_a.len / 2 + want_b.len), dec.info().total_frames);
    const first = try readPart(gpa, &dec, 1000);
    defer gpa.free(first.samples);
    try testing.expect(first.changed);
    try testing.expectEqualSlices(f32, want_a, first.samples);
    try testing.expectEqual(@as(u8, 1), dec.info().channels);
    const second = try readPart(gpa, &dec, 1000);
    defer gpa.free(second.samples);
    try testing.expect(!second.changed);
    try testing.expectEqualSlices(f32, want_b, second.samples);
    var one: [1]f32 = undefined;
    try testing.expectEqual(@as(usize, 0), try dec.read(&one));

    // The same with a source that cannot seek.
    var reader: std.Io.Reader = .fixed(chain);
    var forward_input: io.Input = .init(.{ .reader = &reader });
    var forward: Decoder = try .init(gpa, &forward_input);
    defer forward.deinit();
    const f1 = try readPart(gpa, &forward, 7);
    defer gpa.free(f1.samples);
    try testing.expect(f1.changed);
    try testing.expectEqualSlices(f32, want_a, f1.samples);
    const f2 = try readPart(gpa, &forward, 7);
    defer gpa.free(f2.samples);
    try testing.expect(!f2.changed);
    try testing.expectEqualSlices(f32, want_b, f2.samples);
}

test "seeks cross the links of a chained file" {
    const gpa = testing.allocator;
    const want_a = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want_a);
    const want_b = try nativeSamples(gpa, sample_files[1]);
    defer gpa.free(want_b);
    const want = try std.mem.concat(gpa, f32, &.{ want_a, want_b });
    defer gpa.free(want);
    const total: u64 = want.len / 2;
    const chain = try muxChain(gpa, &.{ sample_files[0], sample_files[1] }, &.{ .{}, .{} });
    defer gpa.free(chain);

    var input: io.Input = .init(.{ .bytes = chain });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const all = try readAll(gpa, &dec, 4096);
    defer gpa.free(all);
    try testing.expectEqualSlices(f32, want, all);
    // The first target comes after the whole file was read.
    for ([_]u64{ 0, 24576 + 5000, 100, 24575, 24576, total - 1, total, 30000, 1 }) |t| {
        try dec.seek(t);
        const tail = try readAll(gpa, &dec, 999);
        defer gpa.free(tail);
        try testing.expectEqualSlices(f32, want[@intCast(t * 2)..], tail);
    }
    try testing.expectError(error.Truncated, dec.seek(total + 1));
}

test "seeks into a link with another format change the stream" {
    const gpa = testing.allocator;
    const want_a = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want_a);
    const want_b = try nativeSamples(gpa, sample_files[4]);
    defer gpa.free(want_b);
    const chain = try muxChain(gpa, &.{ sample_files[0], sample_files[4] }, &.{ .{}, .{} });
    defer gpa.free(chain);
    const frames_a: u64 = want_a.len / 2;

    var input: io.Input = .init(.{ .bytes = chain });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try dec.seek(frames_a + 100);
    try testing.expectEqual(@as(u8, 1), dec.info().channels);
    const tail_b = try readAll(gpa, &dec, 500);
    defer gpa.free(tail_b);
    try testing.expectEqualSlices(f32, want_b[100..], tail_b);

    try dec.seek(frames_a - 3);
    try testing.expectEqual(@as(u8, 2), dec.info().channels);
    var three: [6]f32 = undefined;
    try testing.expectEqual(@as(usize, 3), try dec.read(&three));
    try testing.expectEqualSlices(f32, want_a[want_a.len - 6 ..], &three);
    try testing.expectError(error.StreamChanged, dec.read(&three));
    try testing.expectEqual(@as(u8, 1), dec.info().channels);
    try testing.expectEqual(@as(usize, 3), try dec.read(three[0..3]));
    try testing.expectEqualSlices(f32, want_b[0..3], three[0..3]);

    try dec.seek(0);
    try testing.expectEqual(@as(u8, 2), dec.info().channels);
    try testing.expectEqual(@as(usize, 3), try dec.read(&three));
    try testing.expectEqualSlices(f32, want_a[0..6], &three);
}

test "STREAMINFO totals make the end of a chained file exact" {
    const gpa = testing.allocator;
    const want_a = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want_a);
    const want_b = try nativeSamples(gpa, sample_files[4]);
    defer gpa.free(want_b);
    const frames_a: u64 = want_a.len / 2;
    const frames_b: u64 = want_b.len;
    const chain = try muxChain(gpa, &.{ sample_files[0], sample_files[4] }, &.{ .{ .total = frames_a }, .{ .total = frames_b } });
    defer gpa.free(chain);

    var input: io.Input = .init(.{ .bytes = chain });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, frames_a + frames_b), dec.info().total_frames);
    var one: [2]f32 = undefined;
    try dec.seek(frames_a + frames_b);
    try testing.expectEqual(@as(usize, 0), try dec.read(&one));
    try testing.expectError(error.Truncated, dec.seek(frames_a + frames_b + 1));
    try dec.seek(frames_a);
    try testing.expectEqual(@as(u8, 1), dec.info().channels);
    try testing.expectEqual(@as(usize, 1), try dec.read(one[0..1]));
    try testing.expectEqual(want_b[0], one[0]);
}

test "bit flips in a chained stream give samples or errors" {
    const gpa = testing.allocator;
    const chain = try muxChain(gpa, &.{ sample_files[5], sample_files[5], sample_files[5] }, &.{ .{}, .{}, .{} });
    defer gpa.free(chain);
    const copy = try gpa.dupe(u8, chain);
    defer gpa.free(copy);
    var out: [256]f32 = undefined;
    for (0..chain.len) |i| {
        copy[i] ^= 0x55;
        defer copy[i] = chain[i];
        for ([_]bool{ true, false }) |seekable| {
            var reader: std.Io.Reader = .fixed(copy);
            var input: io.Input = .init(if (seekable) .{ .bytes = copy } else .{ .reader = &reader });
            var dec = Decoder.init(gpa, &input) catch continue;
            defer dec.deinit();
            var guard: usize = 0;
            while (guard < 1000) : (guard += 1) {
                const n = dec.read(&out) catch |err| switch (err) {
                    error.StreamChanged => continue,
                    else => break,
                };
                if (n == 0) break;
            }
            for ([_]u64{ 10, 70, 130, 0 }) |t| {
                dec.seek(t) catch continue;
                _ = dec.read(&out) catch 0;
            }
        }
    }
}

test "a chained file on disk reads and seeks across its links" {
    if (!io.has_files) return error.SkipZigTest;
    const gpa = testing.allocator;
    const want_a = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want_a);
    const want_b = try nativeSamples(gpa, sample_files[1]);
    defer gpa.free(want_b);
    const want = try std.mem.concat(gpa, f32, &.{ want_a, want_b });
    defer gpa.free(want);
    const chain = try muxChain(gpa, &.{ sample_files[0], sample_files[1] }, &.{ .{}, .{} });
    defer gpa.free(chain);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "chain.oga", .data = chain });
    var file = try tmp.dir.openFile(testing.io, "chain.oga", .{});
    defer file.close(testing.io);
    var buffer: [100]u8 = undefined;
    var fr = file.reader(testing.io, &buffer);
    var input: io.Input = .init(.{ .file = &fr });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, want.len / 2), dec.info().total_frames);
    const got = try readAll(gpa, &dec, 3000);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, want, got);
    for ([_]u64{ 30000, 5, 24576, 24575 }) |t| {
        try dec.seek(t);
        const tail = try readAll(gpa, &dec, 5000);
        defer gpa.free(tail);
        try testing.expectEqualSlices(f32, want[@intCast(t * 2)..], tail);
    }
}

test "links with another sample depth keep their own scale" {
    const gpa = testing.allocator;
    const twelve = embed("s22-bps-12");
    const want_a = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want_a);
    const want_b = try nativeSamples(gpa, twelve);
    defer gpa.free(want_b);
    const want = try std.mem.concat(gpa, f32, &.{ want_a, want_b });
    defer gpa.free(want);
    const chain = try muxChain(gpa, &.{ sample_files[0], twelve }, &.{ .{}, .{} });
    defer gpa.free(chain);
    var input: io.Input = .init(.{ .bytes = chain });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const got = try readAll(gpa, &dec, 100000);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, want, got);
    try testing.expectEqual(@as(u8, 12), dec.info().bits_per_sample);
}

test "the MD5 result covers every link" {
    const gpa = testing.allocator;
    var good: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&good, "cbb1785e7dfb70808257ef014969f118");
    var bad = good;
    bad[0] ^= 1;
    for ([_]struct { md5: [16]u8, want: bool }{ .{ .md5 = good, .want = true }, .{ .md5 = bad, .want = false } }) |c| {
        const chain = try muxChain(gpa, &.{ sample_files[0], sample_files[1] }, &.{ .{ .md5 = c.md5 }, .{} });
        defer gpa.free(chain);
        var input: io.Input = .init(.{ .bytes = chain });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        const got = try readAll(gpa, &dec, 4096);
        defer gpa.free(got);
        try testing.expectEqual(@as(?bool, c.want), dec.md5Matches());
    }
}

test "Ogg FLAC rejects bad headers" {
    const gpa = testing.allocator;
    const good = try mux(gpa, sample_files[4], &comment_with_mask, 1, 1);
    defer gpa.free(good);

    // Version 2 in the mapping packet. The page CRC covers it, so the page is rebuilt.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var w: packets.PacketWriter = try .init(gpa, &aw.writer, 1, .{});
    defer w.deinit();
    var mapping = encode.mappingPacket(sample_files[4][8..42], 1);
    mapping[5] = 2;
    try w.writePacket(&mapping, 0);
    try w.finish();
    var input: io.Input = .init(.{ .bytes = aw.written() });
    try testing.expectError(error.Unsupported, Decoder.init(gpa, &input));

    var cut: io.Input = .init(.{ .bytes = good[0..100] });
    try testing.expectError(error.Truncated, Decoder.init(gpa, &cut));
}

test "Ogg FLAC checks the STREAMINFO MD5 at the end" {
    const gpa = testing.allocator;
    var good: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&good, "cbb1785e7dfb70808257ef014969f118");
    var bad = good;
    bad[0] ^= 1;
    for ([_]struct { md5: [16]u8, want: bool }{ .{ .md5 = good, .want = true }, .{ .md5 = bad, .want = false } }) |c| {
        const stream = try muxPatched(gpa, sample_files[0], &comment_with_mask, 1, 1, .{ .md5 = c.md5 });
        defer gpa.free(stream);
        var input: io.Input = .init(.{ .bytes = stream });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        const got = try readAll(gpa, &dec, 4096);
        defer gpa.free(got);
        try testing.expectEqual(@as(?bool, c.want), dec.md5Matches());
    }
}

const Pk = struct { data: []const u8, granule: i64 = 0 };

fn siBytes(block: u16, max_frame: u24, rate: u32, channels: u8, bps: u8, total: u64) [34]u8 {
    var b: [34]u8 = @splat(0);
    std.mem.writeInt(u16, b[0..2], block, .big);
    std.mem.writeInt(u16, b[2..4], block, .big);
    std.mem.writeInt(u24, b[7..10], max_frame, .big);
    const tail = (@as(u64, rate) << 44) | (@as(u64, channels - 1) << 41) | (@as(u64, bps - 1) << 36) | total;
    std.mem.writeInt(u64, b[10..18], tail, .big);
    return b;
}

fn rawStream(gpa: std.mem.Allocator, first: []const u8, rest: []const Pk) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var w: packets.PacketWriter = try .init(gpa, &aw.writer, 9, .{});
    defer w.deinit();
    try w.writePacket(first, 0);
    try w.flush();
    for (rest) |p| try w.writePacket(p.data, p.granule);
    try w.finish();
    return aw.toOwnedSlice();
}

const comment_block = "\x84\x00\x00\x08" ++ "\x00\x00\x00\x00\x00\x00\x00\x00";

/// A stereo 16 bit verbatim frame of 16384 samples, bigger than one Ogg page.
fn bigFrame(gpa: std.mem.Allocator) ![]u8 {
    const crc = @import("../crc.zig");
    const samples = 16384;
    const frame = try gpa.alloc(u8, 6 + 2 * (1 + samples * 2) + 2);
    errdefer gpa.free(frame);
    @memcpy(frame[0..5], "\xff\xf8\xe0\x18\x00");
    var c8 = crc.flac8.init();
    c8.update(frame[0..5]);
    frame[5] = c8.final();
    var at: usize = 6;
    for (0..2) |ch| {
        frame[at] = 0x02;
        at += 1;
        for (0..samples) |i| {
            const v: u16 = @truncate((i +% ch *% 7) *% 2654435761 >> 8);
            std.mem.writeInt(u16, frame[at..][0..2], v, .big);
            at += 2;
        }
    }
    var c16 = crc.flac16.init();
    c16.update(frame[0..at]);
    std.mem.writeInt(u16, frame[at..][0..2], c16.final(), .big);
    return frame;
}

test "the header packet count is bounded" {
    const gpa = testing.allocator;
    const si = siBytes(16384, 0, 44100, 2, 16, 0);
    const pads: [1100]Pk = @splat(.{ .data = "\x01\x00\x00\x00" });
    const stream = try rawStream(gpa, &encode.mappingPacket(&si, 0), &pads);
    defer gpa.free(stream);
    try helpers.expectInitError(Decoder, error.BadHeader, stream);
}

test "a frame of several pages decodes without allocating in read" {
    const gpa = testing.allocator;
    const si = siBytes(16384, 0, 44100, 2, 16, 16384);
    const frame = try bigFrame(gpa);
    defer gpa.free(frame);
    try testing.expect(frame.len > packets.max_body);
    const stream = try rawStream(gpa, &encode.mappingPacket(&si, 1), &.{ .{ .data = comment_block }, .{ .data = frame, .granule = 16384 } });
    defer gpa.free(stream);

    var failing = testing.FailingAllocator.init(gpa, .{});
    var input: io.Input = .init(.{ .bytes = stream });
    var dec: Decoder = try .init(failing.allocator(), &input);
    defer dec.deinit();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    const got = try readAll(gpa, &dec, 1000);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 2 * 16384), got.len);
    const first: u16 = @truncate((@as(usize, 0) +% 0) *% 2654435761 >> 8);
    try testing.expectEqual(@as(f32, @floatFromInt(@as(i16, @bitCast(first)))) / 32768.0, got[0]);
    const second: u16 = @truncate((@as(usize, 5) +% 7) *% 2654435761 >> 8);
    try testing.expectEqual(@as(f32, @floatFromInt(@as(i16, @bitCast(second)))) / 32768.0, got[11]);
}

test "hostile Ogg FLAC headers give errors" {
    const gpa = testing.allocator;
    const si = siBytes(4096, 0, 44100, 2, 16, 0);
    const map1 = encode.mappingPacket(&si, 1);
    const map3 = encode.mappingPacket(&si, 3);

    const short = try rawStream(gpa, map1[0..50], &.{});
    defer gpa.free(short);
    try helpers.expectInitError(Decoder, error.BadHeader, short);

    var future = map1;
    future[5] = 2;
    const v2 = try rawStream(gpa, future[0..8], &.{});
    defer gpa.free(v2);
    try helpers.expectInitError(Decoder, error.Unsupported, v2);

    const inside = try rawStream(gpa, &map3, &.{ .{ .data = comment_block }, .{ .data = "\xff\xf8" } });
    defer gpa.free(inside);
    try helpers.expectInitError(Decoder, error.BadHeader, inside);

    const early = try rawStream(gpa, &map3, &.{.{ .data = comment_block }});
    defer gpa.free(early);
    try helpers.expectInitError(Decoder, error.Truncated, early);

    const bad_len = try rawStream(gpa, &map1, &.{.{ .data = "\x84\x00\x00\x09" ++ "\x00\x00\x00\x00\x00\x00\x00\x00" }});
    defer gpa.free(bad_len);
    try helpers.expectInitError(Decoder, error.BadHeader, bad_len);

    const bad_type = try rawStream(gpa, &map1, &.{.{ .data = "\x7f\x00\x00\x00" }});
    defer gpa.free(bad_type);
    try helpers.expectInitError(Decoder, error.BadHeader, bad_type);

    const bad_si = try rawStream(gpa, &encode.mappingPacket(&(siBytes(4096, 0, 0, 2, 16, 0)), 1), &.{.{ .data = comment_block }});
    defer gpa.free(bad_si);
    try helpers.expectInitError(Decoder, error.BadHeader, bad_si);
}

test "a packet cut short in the middle of the stream gives an error" {
    const gpa = testing.allocator;
    const si = siBytes(16384, 0, 44100, 2, 16, 16384);
    const frame = try bigFrame(gpa);
    defer gpa.free(frame);
    const stream = try rawStream(gpa, &encode.mappingPacket(&si, 1), &.{ .{ .data = comment_block }, .{ .data = frame[0 .. frame.len - 5], .granule = 16384 } });
    defer gpa.free(stream);
    var input: io.Input = .init(.{ .bytes = stream });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    var out: [64]f32 = undefined;
    try testing.expectError(error.Truncated, dec.read(&out));
}

test "bit flips in an Ogg FLAC stream give samples or errors" {
    const gpa = testing.allocator;
    const stream = try mux(gpa, sample_files[5], &comment_with_mask, 1, 1);
    defer gpa.free(stream);
    const copy = try gpa.dupe(u8, stream);
    defer gpa.free(copy);
    var out: [256]f32 = undefined;
    for (0..stream.len) |i| {
        copy[i] ^= 0x55;
        defer copy[i] = stream[i];
        var input: io.Input = .init(.{ .bytes = copy });
        var dec = Decoder.init(gpa, &input) catch continue;
        defer dec.deinit();
        while (true) {
            const n = dec.read(&out) catch break;
            if (n == 0) break;
        }
        dec.seek(10) catch continue;
        _ = dec.read(&out) catch 0;
    }
}

test "a wrong granule makes seek scan from the start" {
    const gpa = testing.allocator;
    const want = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want);
    const stream = try muxPatched(gpa, sample_files[0], &comment_with_mask, 1, 1, .{ .skew = -3000, .skew_from = 2 });
    defer gpa.free(stream);
    var input: io.Input = .init(.{ .bytes = stream });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try dec.seek(22000);
    try testing.expectEqual(@as(u32, 1), dec.chain.codec.rescans);
    const tail = try readAll(gpa, &dec, 4096);
    defer gpa.free(tail);
    try testing.expectEqualSlices(f32, want[44000..], tail);
}

test "a damaged packet is skipped and the next packet decodes" {
    const gpa = testing.allocator;
    const want = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want);
    // s01 has six frames of 4096 samples. The packets 1 and 4 are damaged.
    const stream = try muxPatched(gpa, sample_files[0], &comment_with_mask, 1, 1, .{ .damage = &.{ 1, 4 } });
    defer gpa.free(stream);
    const frame = 4096 * 2;
    const left = try std.mem.concat(gpa, f32, &.{ want[0..frame], want[2 * frame .. 4 * frame], want[5 * frame ..] });
    defer gpa.free(left);

    var input: io.Input = .init(.{ .bytes = stream });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const got = try readAll(gpa, &dec, 1000);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, left, got);
    try testing.expectEqual(@as(u32, 2), dec.stats().resyncs);
    try testing.expect(dec.stats().skipped_bytes > 2 * 100);
    try testing.expectEqual(@as(?bool, null), dec.md5Matches());

    var reader: std.Io.Reader = .fixed(stream);
    var forward_input: io.Input = .init(.{ .reader = &reader });
    var forward: Decoder = try .init(gpa, &forward_input);
    defer forward.deinit();
    const forward_got = try readAll(gpa, &forward, 77);
    defer gpa.free(forward_got);
    try testing.expectEqualSlices(f32, left, forward_got);

    var fail_input: io.Input = .init(.{ .bytes = stream });
    var fail: Decoder = try .initOptions(gpa, &fail_input, .{ .on_bad_frame = .fail });
    defer fail.deinit();
    var out: [2 * 4096]f32 = undefined;
    try testing.expectEqual(@as(usize, 4096), try fail.read(&out));
    try testing.expectError(error.BadData, fail.read(&out));
}

test "the front end reads Ogg FLAC" {
    const gpa = testing.allocator;
    const Front = @import("../Decoder.zig");
    const want = try nativeSamples(gpa, sample_files[1]);
    defer gpa.free(want);
    const stream = try mux(gpa, sample_files[1], &comment_with_mask, 4, 1);
    defer gpa.free(stream);
    for ([_]codec.Format{ .auto, .ogg_flac }) |format| {
        var dec: Front = try .init(gpa, .{ .bytes = stream }, format);
        defer dec.deinit();
        try testing.expect(dec.impl == .ogg_flac);
        const got = try readAll(gpa, &dec, 4096);
        defer gpa.free(got);
        try testing.expectEqualSlices(f32, want, got);
    }
}

test "a frame past the STREAMINFO maximum is counted, or an error in strict mode" {
    const gpa = testing.allocator;
    const want = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want);
    const stream = try muxPatched(gpa, sample_files[0], &comment_with_mask, 1, 1, .{ .max_frame = 100 });
    defer gpa.free(stream);
    {
        var input: io.Input = .init(.{ .bytes = stream });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        const got = try readAll(gpa, &dec, 4096);
        defer gpa.free(got);
        try testing.expectEqualSlices(f32, want, got);
        try testing.expect(dec.stats().oversized_frames > 0);
    }
    var input: io.Input = .init(.{ .bytes = stream });
    var dec: Decoder = try .initOptions(gpa, &input, .{ .strict_metadata = true, .on_bad_frame = .fail });
    defer dec.deinit();
    var out: [64]f32 = undefined;
    try testing.expectError(error.BadData, dec.read(&out));
}

test "strict metadata gives BadData under the resync policy in Ogg" {
    const gpa = testing.allocator;
    const file = sample_files[0];
    const stream = try muxPatched(gpa, file, &comment_with_mask, 1, 1, .{ .max_frame = 100 });
    defer gpa.free(stream);
    var input: io.Input = .init(.{ .bytes = stream });
    var dec: Decoder = try .initOptions(gpa, &input, .{ .strict_metadata = true });
    defer dec.deinit();
    var out: [64]f32 = undefined;
    try testing.expectError(error.BadData, dec.read(&out));
    try testing.expectEqual(@as(u32, 0), dec.stats().resyncs);
}

test "a first frame in several pages with an unknown header count" {
    const gpa = testing.allocator;
    const si = siBytes(16384, 0, 44100, 2, 16, 16384);
    const frame = try bigFrame(gpa);
    defer gpa.free(frame);
    const stream = try rawStream(gpa, &encode.mappingPacket(&si, 0), &.{ .{ .data = comment_block }, .{ .data = frame, .granule = 16384 } });
    defer gpa.free(stream);
    const native = try std.mem.concat(gpa, u8, &.{ "fLaC\x80\x00\x00\x22", &si, frame });
    defer gpa.free(native);
    const want = try nativeSamples(gpa, native);
    defer gpa.free(want);

    var input: io.Input = .init(.{ .bytes = stream });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const got = try readAll(gpa, &dec, 1000);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 2 * 16384), got.len);
    try testing.expectEqualSlices(f32, want, got);
}

test "a stream that starts at a nonzero frame number seeks without a rescan" {
    const gpa = testing.allocator;
    const want = try nativeSamples(gpa, sample_files[5]);
    defer gpa.free(want);
    const stream = try mux(gpa, sample_files[5], &comment_with_mask, 1, 1);
    defer gpa.free(stream);
    var input: io.Input = .init(.{ .bytes = stream });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    for ([_]u64{ 30, 0, 45 }) |t| {
        try dec.seek(t);
        const tail = try readAll(gpa, &dec, 16);
        defer gpa.free(tail);
        try testing.expectEqualSlices(f32, want[@as(usize, @intCast(t)) * 2 ..], tail);
    }
    try testing.expect(dec.chain.codec.first_sample.? != 0);
    try testing.expectEqual(@as(u32, 0), dec.chain.codec.rescans);
}

test "seeks never read a big header packet again" {
    const gpa = testing.allocator;
    const want = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want);
    const comment = try gpa.alloc(u8, 4 + 100000 + 4);
    defer gpa.free(comment);
    @memset(comment, 'x');
    std.mem.writeInt(u32, comment[0..4], 100000, .little);
    std.mem.writeInt(u32, comment[100004..][0..4], 0, .little);
    const stream = try mux(gpa, sample_files[0], comment, 3, 1);
    defer gpa.free(stream);

    var input: io.Input = .init(.{ .bytes = stream });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const all = try readAll(gpa, &dec, 4096);
    defer gpa.free(all);
    try testing.expectEqualSlices(f32, want, all);

    const total: usize = want.len / 2;
    for ([_]usize{ 1000, 0, total, 12345, total - 1 }) |t| {
        try dec.seek(t);
        const tail = try readAll(gpa, &dec, 4096);
        defer gpa.free(tail);
        try testing.expectEqualSlices(f32, want[t * 2 ..], tail);
    }
}

// Encoder tests

fn testInts(gpa: std.mem.Allocator, channels: usize, frames: usize, bits: u8) ![]i32 {
    const out = try gpa.alloc(i32, channels * frames);
    var rng: std.Random.DefaultPrng = .init(7);
    const amp: f64 = @floatFromInt(@as(u32, 1) << @intCast(bits - 2));
    for (0..frames) |f| {
        for (0..channels) |c| {
            const t: f64 = @floatFromInt(f);
            const tone = @sin(t * 0.05 * @as(f64, @floatFromInt(c + 1))) * amp;
            const noise = (rng.random().float(f64) - 0.5) * amp * 0.1;
            out[f * channels + c] = @intFromFloat(@round(tone + noise));
        }
    }
    return out;
}

fn testFloats(gpa: std.mem.Allocator, ints: []const i32, bits: u8) ![]f32 {
    const out = try gpa.alloc(f32, ints.len);
    const scale: f64 = @floatFromInt(@as(u32, 1) << @intCast(bits - 1));
    for (out, ints) |*o, v| o.* = @floatCast(@as(f64, @floatFromInt(v)) / scale);
    return out;
}

fn testInfo(channels: u8) codec.Info {
    return .{ .rate = 44100, .channels = channels, .mask = .{}, .total_frames = null, .bits_per_sample = 16 };
}

fn encodeBytes(gpa: std.mem.Allocator, options: Options, channels: u8, floats: []const f32, chunk: usize) ![]u8 {
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
    try testing.expect(!enc.sizes_fixed);
    return aw.toOwnedSlice();
}

fn expectOggDecodes(gpa: std.mem.Allocator, bytes: []const u8, channels: u8, bits: u8, ints: []const i32) !void {
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(channels, dec.info().channels);
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

test "Ogg FLAC encoding round trips every level, depth and channel count" {
    const gpa = testing.allocator;
    for ([_]u4{ 0, 3, 5, 8 }) |level| {
        for ([_]u8{ 8, 16, 24 }) |bits| {
            for ([_]u8{ 1, 2, 6 }) |channels| {
                const ints = try testInts(gpa, channels, 9000, bits);
                defer gpa.free(ints);
                const floats = try testFloats(gpa, ints, bits);
                defer gpa.free(floats);
                const bytes = try encodeBytes(gpa, .{ .level = level, .bits = bits, .serial = 99 }, channels, floats, 1237);
                defer gpa.free(bytes);
                try expectOggDecodes(gpa, bytes, channels, bits, ints);
            }
        }
    }
}

test "Ogg FLAC encoding writes the mapping page, the comment page and granules" {
    const gpa = testing.allocator;
    const ints = try testInts(gpa, 2, 20000, 16);
    defer gpa.free(ints);
    const floats = try testFloats(gpa, ints, 16);
    defer gpa.free(floats);
    const bytes = try encodeBytes(gpa, .{ .serial = 0xabcd }, 2, floats, 4000);
    defer gpa.free(bytes);

    const first = try packets.parsePage(bytes);
    try testing.expectEqual(@as(usize, 79), first.size());
    try testing.expect(first.flags.bos and !first.flags.eos);
    try testing.expectEqual(@as(i64, 0), first.granule);
    try testing.expectEqual(@as(u32, 0xabcd), first.serial);
    try testing.expectEqualSlices(u8, "\x7fFLAC\x01\x00\x00\x01fLaC\x00\x00\x00\x22", first.body[0..17]);

    var at = first.size();
    const second = try packets.parsePage(bytes[at..]);
    try testing.expectEqual(@as(i64, 0), second.granule);
    try testing.expectEqual(@as(u8, 0x84), second.body[0]);
    try testing.expectEqualSlices(u8, "chorus", second.body[8..14]);
    at += second.size();

    var seq: u32 = 2;
    var last: i64 = 0;
    var eos = false;
    while (at < bytes.len) : (seq += 1) {
        const page = try packets.parsePage(bytes[at..]);
        try testing.expect(!eos);
        try testing.expectEqual(seq, page.sequence);
        try testing.expectEqual(@as(u32, 0xabcd), page.serial);
        try testing.expect(page.granule >= last);
        try testing.expect(@rem(page.granule, 4096) == 0 or page.granule == 20000);
        last = page.granule;
        eos = page.flags.eos;
        at += page.size();
    }
    try testing.expect(eos);
    try testing.expectEqual(@as(i64, 20000), last);
}

test "Ogg FLAC with a channel mask outside the default keeps the mask" {
    const gpa = testing.allocator;
    const ints = try testInts(gpa, 2, 3000, 16);
    defer gpa.free(ints);
    const floats = try testFloats(gpa, ints, 16);
    defer gpa.free(floats);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var info = testInfo(2);
    info.mask = .{ .front_left = true, .front_center = true };
    var enc: Encoder = try .init(gpa, &aw.writer, .{}, info);
    defer enc.deinit();
    try enc.write(floats);
    try enc.finish();
    var input: io.Input = .init(.{ .bytes = aw.written() });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(info.mask, dec.info().mask);
}

test "a plain writer leaves the Ogg FLAC total and MD5 unknown" {
    const gpa = testing.allocator;
    const ints = try testInts(gpa, 1, 5000, 16);
    defer gpa.free(ints);
    const floats = try testFloats(gpa, ints, 16);
    defer gpa.free(floats);
    const bytes = try encodeBytes(gpa, .{}, 1, floats, 1000);
    defer gpa.free(bytes);
    const tail = std.mem.readInt(u64, bytes[27 + 1 + 17 + 10 ..][0..8], .big);
    try testing.expectEqual(@as(u64, 0), tail & ((@as(u64, 1) << 36) - 1));
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0)), bytes[27 + 1 + 17 + 18 ..][0..16]);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    // STREAMINFO has no total. The last page granule gives it.
    try testing.expectEqual(@as(?u64, 5000), dec.info().total_frames);
    var reader: std.Io.Reader = .fixed(bytes);
    var forward_input: io.Input = .init(.{ .reader = &reader });
    var forward: Decoder = try .init(gpa, &forward_input);
    defer forward.deinit();
    try testing.expectEqual(@as(?u64, null), forward.info().total_frames);
}

fn encodeToFile(gpa: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, ints: []const i32, channels: u8, streaming: @FieldType(std.Io.File.Writer, "seek_err")) !bool {
    const floats = try testFloats(gpa, ints, 16);
    defer gpa.free(floats);
    var file = try dir.createFile(testing.io, name, .{});
    defer file.close(testing.io);
    var wbuf: [64]u8 = undefined;
    var fw = file.writer(testing.io, &wbuf);
    if (streaming) |err| {
        fw.mode = .streaming;
        fw.seek_err = err;
    }
    var enc: Encoder = try .initFile(gpa, &fw, .{ .serial = 5 }, testInfo(channels));
    defer enc.deinit();
    const cut = floats.len / channels / 3 * channels;
    try enc.write(floats[0..cut]);
    try testing.expect(!enc.sizes_fixed);
    try enc.write(floats[cut..]);
    try enc.finish();
    return enc.sizes_fixed;
}

test "a seekable file gets the Ogg FLAC total, MD5 and page CRC fixed" {
    if (!io.has_files) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ints = try testInts(gpa, 2, 30000, 16);
    defer gpa.free(ints);
    try testing.expect(try encodeToFile(gpa, tmp.dir, "a.oga", ints, 2, null));
    const bytes = try tmp.dir.readFileAlloc(testing.io, "a.oga", gpa, .limited(1 << 22));
    defer gpa.free(bytes);

    const first = try packets.parsePage(bytes);
    try testing.expectEqual(@as(usize, 79), first.size());
    const si = first.body[17..51];
    const tail = std.mem.readInt(u64, si[10..18], .big);
    try testing.expectEqual(@as(u64, 30000), tail & ((@as(u64, 1) << 36) - 1));
    try testing.expect(std.mem.readInt(u24, si[4..7], .big) > 0);
    var md5: std.crypto.hash.Md5 = .init(.{});
    for (ints) |x| {
        var b: [2]u8 = undefined;
        std.mem.writeInt(i16, &b, @intCast(x), .little);
        md5.update(&b);
    }
    var want: [16]u8 = undefined;
    md5.final(&want);
    try testing.expectEqualSlices(u8, &want, si[18..34]);

    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 30000), dec.info().total_frames);
    var buf: [2 * 500]i32 = undefined;
    while (try dec.readInt(&buf) != 0) {}
    try testing.expectEqual(@as(?bool, true), dec.md5Matches());
    try testing.expectEqual(@as(u32, 0), dec.stats().oversized_frames);
    try dec.seek(12345);
    var one: [2]i32 = undefined;
    try testing.expectEqual(@as(usize, 1), try dec.readInt(&one));
    try testing.expectEqualSlices(i32, ints[12345 * 2 ..][0..2], &one);
}

test "an unseekable file keeps the unknown Ogg FLAC STREAMINFO" {
    if (!io.has_files) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ints = try testInts(gpa, 2, 9000, 16);
    defer gpa.free(ints);
    try testing.expect(!try encodeToFile(gpa, tmp.dir, "b.oga", ints, 2, error.Unseekable));
    const bytes = try tmp.dir.readFileAlloc(testing.io, "b.oga", gpa, .limited(1 << 22));
    defer gpa.free(bytes);
    const first = try packets.parsePage(bytes);
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0)), first.body[17 + 18 ..][0..16]);
    try expectOggDecodes(gpa, bytes, 2, 16, ints);
}

test "an Ogg FLAC stream with no frames encodes and decodes" {
    const gpa = testing.allocator;
    const bytes = try encodeBytes(gpa, .{ .serial = 6 }, 2, &.{}, 1);
    defer gpa.free(bytes);
    // The mapping page, the comment page and the end page.
    const first = try packets.parsePage(bytes);
    const second = try packets.parsePage(bytes[first.size()..]);
    const last = try packets.parsePage(bytes[first.size() + second.size() ..]);
    try testing.expect(last.flags.eos);
    try testing.expectEqual(@as(i64, 0), last.granule);
    try testing.expectEqual(bytes.len, first.size() + second.size() + last.size());

    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(u8, 2), dec.info().channels);
    try testing.expectEqual(@as(?u64, 0), dec.info().total_frames);
    var out: [8]f32 = undefined;
    try testing.expectEqual(@as(usize, 0), try dec.read(&out));
    try dec.seek(0);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out));
    try testing.expectError(error.Truncated, dec.seek(1));

    const Front = @import("../Decoder.zig");
    var front: Front = try .init(gpa, .{ .bytes = bytes }, .auto);
    defer front.deinit();
    try testing.expect(front.impl == .ogg_flac);
    try testing.expectEqual(@as(usize, 0), try front.read(&out));
}

test "the Ogg FLAC encoder rejects bad parameters" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .level = 9 }, testInfo(2)));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .bits = 32 }, testInfo(2)));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{}, testInfo(0)));
    var enc: Encoder = try .init(gpa, &aw.writer, .{}, testInfo(2));
    defer enc.deinit();
    try testing.expectError(error.Unsupported, enc.write(&.{ 0.0, 0.0, 0.0 }));
    try enc.finish();
    try testing.expectError(error.Unsupported, enc.write(&.{ 0.0, 0.0 }));
}

test "a seek after a read that stopped at a format change enters the right link" {
    const gpa = testing.allocator;
    const want_a = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want_a);
    const chain = try muxChain(gpa, &.{ sample_files[0], sample_files[4] }, &.{ .{}, .{} });
    defer gpa.free(chain);
    const frames_a: u64 = want_a.len / 2;
    var input: io.Input = .init(.{ .bytes = chain });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try dec.seek(frames_a - 3);
    var buf: [20]f32 = undefined;
    try testing.expectEqual(@as(usize, 3), try dec.read(&buf));
    try dec.seek(100);
    try testing.expectEqual(@as(u8, 2), dec.info().channels);
    var out: [8]f32 = undefined;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out));
    try testing.expectEqualSlices(f32, want_a[200..208], &out);
}

test "random seeks and reads over a chain match the joined decodes" {
    const gpa = testing.allocator;
    const files = [_][]const u8{ sample_files[0], sample_files[1], sample_files[4], sample_files[0] };
    var parts: [files.len][]f32 = undefined;
    var chans: [files.len]usize = undefined;
    var bases: [files.len + 1]u64 = undefined;
    bases[0] = 0;
    for (files, 0..) |f, i| {
        parts[i] = try nativeSamples(gpa, f);
        var input: io.Input = .init(.{ .bytes = f });
        var d: decode.Decoder = try .init(gpa, &input);
        chans[i] = d.info().channels;
        d.deinit();
        bases[i + 1] = bases[i] + parts[i].len / chans[i];
    }
    defer for (parts) |p| gpa.free(p);
    const chain = try muxChain(gpa, &files, &.{ .{}, .{}, .{}, .{} });
    defer gpa.free(chain);
    const total = bases[files.len];

    for (1..13) |seed| {
        var input: io.Input = .init(.{ .bytes = chain });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        try testing.expectEqual(@as(?u64, total), dec.info().total_frames);
        var prng: std.Random.DefaultPrng = .init(seed);
        const rnd = prng.random();
        var pos: u64 = 0;
        var buf: [4096 * 2]f32 = undefined;
        for (0..400) |_| {
            if (rnd.uintLessThan(u8, 3) == 0) {
                pos = rnd.uintAtMost(u64, total);
                try dec.seek(pos);
            }
            const ch: usize = dec.info().channels;
            const frames = rnd.uintAtMost(usize, 4096 * 2 / ch - 1) + 1;
            const n = dec.read(buf[0 .. frames * ch]) catch |e| switch (e) {
                error.StreamChanged => continue,
                else => return e,
            };
            if (n == 0) {
                try testing.expectEqual(total, pos);
                continue;
            }
            for (0..n) |i| {
                const p = pos + i;
                var l: usize = 0;
                while (l + 1 < files.len and bases[l + 1] <= p) l += 1;
                try testing.expectEqual(chans[l], ch);
                const local: usize = @intCast(p - bases[l]);
                try testing.expectEqualSlices(f32, parts[l][local * ch ..][0..ch], buf[i * ch ..][0..ch]);
            }
            pos += n;
        }
    }
}

test "a read across a format change allocates nothing when the links are known" {
    const gpa = testing.allocator;
    const want_a = try nativeSamples(gpa, sample_files[4]);
    defer gpa.free(want_a);
    const want_b = try nativeSamples(gpa, sample_files[3]);
    defer gpa.free(want_b);
    const want_c = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want_c);

    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    try big.appendNTimes(gpa, 0, 4);
    std.mem.writeInt(u32, big.items[0..4], 300000, .little);
    try big.appendNTimes(gpa, 'v', 300000);
    try big.appendNTimes(gpa, 0, 4);

    var chain: std.ArrayList(u8) = .empty;
    defer chain.deinit(gpa);
    const parts = [_][]const u8{ sample_files[4], sample_files[3], sample_files[0] };
    for (parts, 0..) |file, i| {
        const comment: []const u8 = if (i == 1) big.items else &comment_with_mask;
        const part = try muxPatched(gpa, file, comment, @intCast(i + 1), 1, .{});
        defer gpa.free(part);
        try chain.appendSlice(gpa, part);
    }

    var failing = testing.FailingAllocator.init(gpa, .{});
    var input: io.Input = .init(.{ .bytes = chain.items });
    var dec: Decoder = try .init(failing.allocator(), &input);
    defer dec.deinit();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    const wants = [_][]const f32{ want_a, want_b, want_c };
    var link: usize = 0;
    var got: usize = 0;
    var buf: [4096 * 2]f32 = undefined;
    while (true) {
        const ch: usize = dec.info().channels;
        const n = dec.read(buf[0 .. 4096 / ch * ch]) catch |err| switch (err) {
            error.StreamChanged => continue,
            else => return err,
        };
        if (n == 0) break;
        const want = wants[link];
        const take = @min(n * ch, want.len - got);
        try testing.expectEqualSlices(f32, want[got..][0..take], buf[0..take]);
        got += take;
        if (got == want.len) {
            link += 1;
            got = 0;
            if (n * ch > take) return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(@as(usize, 3), link);
}

test "a link boundary after counted damage goes on with the next link" {
    const gpa = testing.allocator;
    const want = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want);
    const last = (want.len / 2 + 4095) / 4096 - 1;
    const chain = try muxChain(gpa, &.{ sample_files[0], sample_files[0] }, &.{ .{ .damage = &.{last}, .total = want.len / 2 }, .{} });
    defer gpa.free(chain);
    var input: io.Input = .init(.{ .bytes = chain });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const got = try readAll(gpa, &dec, 4096);
    defer gpa.free(got);
    try testing.expectEqual(@as(u32, 1), dec.stats().resyncs);
    try testing.expect(got.len > want.len);
    try testing.expect(got.len < 2 * want.len);
    try testing.expectEqualSlices(f32, want, got[got.len - want.len ..]);
}

test "a link boundary without damage still gives Truncated for a short link" {
    const gpa = testing.allocator;
    const full = try muxChain(gpa, &.{ sample_files[0], sample_files[0] }, &.{ .{ .total = 100000 }, .{} });
    defer gpa.free(full);
    var input: io.Input = .init(.{ .bytes = full });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    var buf: [8192]f32 = undefined;
    const result = while (true) {
        const n = dec.read(&buf) catch |err| break err;
        if (n == 0) break error.TestUnexpectedResult;
    };
    try testing.expectEqual(error.Truncated, result);
}

test "a packet over the limit is skipped and counted" {
    const gpa = testing.allocator;
    const want = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want);
    const stream = try muxPatched(gpa, sample_files[0], &comment_with_mask, 1, 1, .{ .junk_at = 2, .junk_len = 300000 });
    defer gpa.free(stream);
    var input: io.Input = .init(.{ .bytes = stream });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const got = try readAll(gpa, &dec, 1000);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, want, got);
    try testing.expectEqual(@as(u32, 1), dec.stats().resyncs);

    var strict_input: io.Input = .init(.{ .bytes = stream });
    var strict: Decoder = try .initOptions(gpa, &strict_input, .{ .on_bad_frame = .fail });
    defer strict.deinit();
    try testing.expectError(error.BadData, readAll(gpa, &strict, 1000));
}

test "a link whose granules start above 0 seeks from the granules" {
    const gpa = testing.allocator;
    const want = try nativeSamples(gpa, sample_files[0]);
    defer gpa.free(want);
    const stream = try muxPatched(gpa, sample_files[0], &comment_with_mask, 1, 1, .{ .skew = 5000 });
    defer gpa.free(stream);
    var input: io.Input = .init(.{ .bytes = stream });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const channels: usize = dec.info().channels;
    for ([_]u64{ 12000, 0, 7, 4096, 16000 }) |t| {
        try dec.seek(t);
        const tail = try readAll(gpa, &dec, 4096);
        defer gpa.free(tail);
        try testing.expectEqualSlices(f32, want[@as(usize, @intCast(t)) * channels ..], tail);
    }
    try testing.expectEqual(@as(u32, 0), dec.chain.codec.rescans);
}

test "a frame in the first page that does not parse does not move the start" {
    const gpa = testing.allocator;
    const plain = try muxPatched(gpa, sample_files[0], &comment_with_mask, 1, 1, .{});
    defer gpa.free(plain);
    const ruined = try muxPatched(gpa, sample_files[0], &comment_with_mask, 1, 1, .{ .damage = &.{0}, .ruin_headers = true });
    defer gpa.free(ruined);
    var starts: [2]?i64 = undefined;
    for ([_][]const u8{ plain, ruined }, &starts) |stream, *start| {
        var input: io.Input = .init(.{ .bytes = stream });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        start.* = dec.chain.linkStart();
    }
    try testing.expectEqual(@as(?i64, 0), starts[0]);
    try testing.expectEqual(@as(?i64, 0), starts[1]);
}
