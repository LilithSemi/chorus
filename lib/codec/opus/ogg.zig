//! Ogg Opus decoding (RFC 7845). The output is 48 kHz f32. The pre-skip of the header and the
//! granule of the end page cut the start and the end, and the output gain of the header is
//! applied. `ogg_chain.Chain` plays the links of a chained file as one stream.
//!
//! Streams of channel mapping family 0 and 1 with up to 8 channels have `Info.mask` and the
//! WAVE channel order, as the Vorbis decoder gives them. Other streams keep the channel order
//! of the header and have an empty mask. Family 2 (ambisonics) is read like family 255. Family 3
//! multiplies the stream channels by the demixing matrix of the header, as the projection decoder
//! of libopus does when the matrix has as many rows as stream channels. Any other shape follows
//! RFC 8486 and uses every column.
const std = @import("std");
const codec = @import("../../codec.zig");
const io = @import("../io.zig");
const packets = @import("../ogg.zig");
const ogg_chain = @import("../ogg_chain.zig");
const vorbis = @import("../vorbis.zig");
const opus = @import("../opus.zig");
const packet = @import("packet.zig");
const glue = @import("glue.zig");
const head_file = @import("head.zig");
const helpers = @import("../testing.zig");
const testing = std.testing;

pub const Stats = struct {
    /// Packets that did not decode and were replaced by concealment. A seek does not count
    /// the packets it replaces.
    resyncs: u32 = 0,
};

/// The limit for the header packets, which can hold pictures.
const header_packet_limit = 1 << 22;
/// The most bytes of an Opus packet for one stream that a reader should accept.
const stream_packet_limit = 61440;
const out_rate = 48000;
/// The frames of the longest packet, 120 ms.
const max_frames = packet.max_samples;
/// A seek starts to decode 200 ms before its target. RFC 7845 asks for at least 80 ms. The
/// CELT and SILK states settle slowly, and the error after 80 ms is large.
const pre_roll = 9600;
const max_gain: f32 = 0x1.fffffep-1;
/// The frames that a lost packet is replaced with when no packet came before.
const first_guess = 960;

pub const isHead = head_file.isHead;

const Route = struct {
    /// The stream that feeds the channel, or `head_file.silent`.
    stream: u8,
    /// The channel inside the stream.
    side: u8,
    /// The channel position in the output frame.
    dest: u8,
};

const LinkHeaders = struct {
    head: head_file.Head,
    /// The first audio packet, or the first packet of the next link when the link has none.
    held: ?packets.Packet,
    /// The size of the biggest packet that the read took.
    biggest: usize,
    /// The slot of the codec that holds the demixing matrix, and the number of values in it.
    slot: u1 = 0,
    matrix_len: usize = 0,
};

const PacketError = error{BadPacket};

/// The Opus part of a chained Ogg decoder. `ogg_chain.Chain` calls it for each link.
const OpusCodec = struct {
    gpa: std.mem.Allocator,
    options: opus.Options,
    head: head_file.Head = undefined,
    gain: f32 = 1.0,
    decs: []glue.PacketDecoder = &.{},
    /// One stream decoded, before it goes to the output channels.
    scratch: []f32 = &.{},
    /// The frames of the current packet in output order.
    out: []f32 = &.{},
    routes: [255]Route = undefined,
    has_silent: bool = false,
    /// Two slots for the demixing matrices of family 3. A link reads its matrix into the slot that
    /// the current link does not use.
    slots: [2][]i16 = .{ &.{}, &.{} },
    cur_slot: ?u1 = null,
    /// The most values of a matrix that a link needs.
    slot_target: usize = 0,
    /// The matrix of the current link, column by column.
    matrix: []const i16 = &.{},
    /// The streams of one packet side by side, before the matrix of family 3 makes the output.
    stage: []f32 = &.{},

    pend_pos: usize = 0,
    pend_end: usize = 0,
    /// The frames that the next packets drop: the pre-skip, or the frames up to a seek target.
    skip_left: u64 = 0,
    /// The frames of the last packet that decoded, which replaces a lost packet.
    last_n: usize = first_guess,
    /// The frames that the packets of the current page have made.
    page_frames: u64 = 0,
    /// The granule of the last page that ended a packet, or 0 before the first one.
    prev_granule: i64 = 0,
    /// The frames of the last packet before the cuts.
    block_n: usize = 0,
    /// Pages or packets were lost, so the next packet is preceded by concealment.
    lost_pending: bool = false,
    /// Something was lost since the last reset of the position.
    had_loss: bool = false,
    /// The granule of the first output frame, once it is known.
    start: ?i64 = null,
    failed: ?ogg_chain.FrameError = null,
    at_end: bool = false,
    resyncs: u32 = 0,
    /// Seeks that found granules that disagree with the frames and decoded from the start.
    rescans: u32 = 0,
    seeking: bool = false,
    bad_run: bool = false,

    pub const Headers = LinkHeaders;
    pub const max_header_packet = header_packet_limit;
    pub const isFirst = isHead;

    pub fn readHeaders(self: *OpusCodec, reader: *packets.PacketReader, first: []const u8) codec.InitError!LinkHeaders {
        var head = try head_file.parseHead(first);
        const slot: u1 = if (self.cur_slot) |s| 1 - s else 0;
        const matrix_len = head.matrix.len / 2;
        if (matrix_len > 0) {
            try self.growSlot(slot, matrix_len);
            for (self.slots[slot][0..matrix_len], 0..) |*v, i| v.* = std.mem.readInt(i16, head.matrix[2 * i ..][0..2], .little);
            head.matrix = &.{};
        }
        var biggest = first.len;
        const tags = (reader.next() catch |err| return ogg_chain.initError(err)) orelse return error.Truncated;
        if (tags.bos) return error.Truncated;
        biggest = @max(biggest, tags.data.len);
        head_file.checkTags(tags.data) catch return error.BadHeader;

        var held: ?packets.Packet = null;
        if (reader.next() catch |err| return ogg_chain.initError(err)) |p| {
            biggest = @max(biggest, p.data.len);
            held = p;
            if (!p.bos) reader.markAudio(p);
        }
        return .{ .head = head, .held = held, .biggest = biggest, .slot = slot, .matrix_len = matrix_len };
    }

    /// Makes the slot able to hold `n` values. The values in it are lost.
    fn growSlot(self: *OpusCodec, slot: u1, n: usize) error{OutOfMemory}!void {
        if (self.slots[slot].len >= n) return;
        self.gpa.free(self.slots[slot]);
        self.slots[slot] = &.{};
        self.slots[slot] = try self.gpa.alloc(i16, n);
    }

    /// The slots belong to the codec, so there is nothing to give back.
    pub fn releaseHeaders(self: *OpusCodec, h: *LinkHeaders) void {
        _ = self;
        _ = h;
    }

    pub fn deinit(self: *OpusCodec) void {
        self.gpa.free(self.decs);
        self.gpa.free(self.scratch);
        self.gpa.free(self.out);
        self.gpa.free(self.stage);
        for (self.slots) |s| self.gpa.free(s);
        self.* = undefined;
    }

    fn packetBound(h: *const LinkHeaders) usize {
        return @as(usize, stream_packet_limit) * h.head.streams;
    }

    /// Makes the buffers big enough for the link. The decoders and the output hold nothing that
    /// has to stay, because `enter` sets them up again.
    fn ensure(self: *OpusCodec, h: *const LinkHeaders) error{OutOfMemory}!void {
        if (self.decs.len < h.head.streams) {
            self.decs = try self.gpa.realloc(self.decs, h.head.streams);
        }
        if (self.scratch.len == 0) self.scratch = try self.gpa.alloc(f32, 2 * max_frames);
        const need = max_frames * @as(usize, h.head.channels);
        if (self.out.len < need) {
            self.gpa.free(self.out);
            self.out = &.{};
            self.out = try self.gpa.alloc(f32, need);
        }
        if (h.head.family == 3) {
            const need_stage = max_frames * (@as(usize, h.head.streams) + h.head.coupled);
            if (self.stage.len < need_stage) {
                self.gpa.free(self.stage);
                self.stage = &.{};
                self.stage = try self.gpa.alloc(f32, need_stage);
            }
        }
        self.pend_pos = 0;
        self.pend_end = 0;
    }

    pub fn reserve(self: *OpusCodec, h: *const LinkHeaders) codec.InitError!usize {
        self.slot_target = @max(self.slot_target, h.matrix_len);
        try self.ensure(h);
        return packetBound(h);
    }

    pub fn enter(self: *OpusCodec, h: *LinkHeaders) codec.InitError!usize {
        try self.ensure(h);
        self.slot_target = @max(self.slot_target, h.matrix_len);
        self.cur_slot = h.slot;
        self.matrix = self.slots[h.slot][0..h.matrix_len];
        try self.growSlot(1 - h.slot, self.slot_target);
        self.head = h.head;
        self.gain = h.head.gainFactor();
        self.has_silent = false;
        const coupled: usize = self.head.coupled;
        const family_one = self.head.family == 1;
        const channels: usize = self.head.channels;
        for (self.routes[0..channels], 0..) |*r, c| {
            const entry = self.head.mapping[c];
            const dest: u8 = @intCast(if (family_one) vorbis.decode.waveChannel(channels, c) else c);
            if (entry == head_file.silent) {
                r.* = .{ .stream = head_file.silent, .side = 0, .dest = dest };
                self.has_silent = true;
            } else if (entry < 2 * coupled) {
                r.* = .{ .stream = entry / 2, .side = entry % 2, .dest = dest };
            } else {
                r.* = .{ .stream = @intCast(entry - coupled), .side = 0, .dest = dest };
            }
        }
        for (self.decs[0..self.head.streams], 0..) |*d, s| {
            d.* = glue.PacketDecoder.init(if (s < coupled) 2 else 1, self.options) catch return error.BadHeader;
            d.limit_output = false;
        }
        self.resetStream();
        self.start = null;
        self.at_end = false;
        return packetBound(h);
    }

    pub fn settle(self: *OpusCodec, first: ?packets.Packet) bool {
        _ = self;
        return if (first) |p| !p.bos else false;
    }

    pub fn sameShape(self: *const OpusCodec, h: *const LinkHeaders) bool {
        return h.head.channels == self.head.channels and h.head.hasLayout() == self.head.hasLayout();
    }

    pub fn info(self: *const OpusCodec) codec.Info {
        return .{
            .rate = out_rate,
            .channels = self.head.channels,
            .mask = @bitCast(if (self.head.hasLayout()) vorbis.decode.channelMask(self.head.channels) else 0),
        };
    }

    pub fn canLoad(self: *const OpusCodec) ogg_chain.FrameError!bool {
        if (self.failed) |err| return err;
        return !self.at_end;
    }

    pub fn fail(self: *OpusCodec, err: ogg_chain.FrameError) void {
        self.failed = err;
    }

    /// Puts the decoders in their start state and the position at the pre-skip of the link.
    fn resetStream(self: *OpusCodec) void {
        for (self.decs[0..self.head.streams]) |*d| d.reset();
        self.pend_pos = 0;
        self.pend_end = 0;
        self.skip_left = self.head.pre_skip;
        self.last_n = first_guess;
        self.page_frames = 0;
        self.prev_granule = 0;
        self.block_n = 0;
        self.lost_pending = false;
        self.had_loss = false;
    }

    fn markLoss(self: *OpusCodec) void {
        self.lost_pending = true;
        self.had_loss = true;
    }

    fn streamChannels(self: *const OpusCodec, s: usize) usize {
        return if (s < self.head.coupled) 2 else 1;
    }

    /// Copies `frames` frames of the stream `s` from `scratch` to the output channels that
    /// it feeds, starting at the frame `at`. A stream of family 3 goes to its columns of `stage`.
    fn place(self: *OpusCodec, s: usize, frames: usize, at: usize) void {
        const channels: usize = self.head.channels;
        const width = self.streamChannels(s);
        if (self.head.family == 3) {
            const columns = @as(usize, self.head.streams) + self.head.coupled;
            const first = if (s < self.head.coupled) 2 * s else self.head.coupled + s;
            for (0..frames) |i| {
                @memcpy(self.stage[(at + i) * columns + first ..][0..width], self.scratch[i * width ..][0..width]);
            }
            return;
        }
        for (self.routes[0..channels]) |r| {
            if (r.stream != s) continue;
            for (0..frames) |i| {
                self.out[(at + i) * channels + r.dest] = self.scratch[i * width + r.side];
            }
        }
    }

    /// Makes the output of family 3 from the streams in `stage`: each output channel is a row of
    /// the demixing matrix applied to the stream channels.
    fn project(self: *OpusCodec, frames: usize) void {
        const channels: usize = self.head.channels;
        const columns = @as(usize, self.head.streams) + self.head.coupled;
        const scale: f32 = 1.0 / 32768.0;
        for (0..frames) |i| {
            const x = self.stage[i * columns ..][0..columns];
            for (0..channels) |row| {
                var acc: f32 = 0;
                for (x, 0..) |v, col| {
                    const coef: f32 = @floatFromInt(self.matrix[col * channels + row]);
                    acc += scale * coef * v;
                }
                self.out[i * channels + row] = acc;
            }
        }
    }

    /// Completes the output frames after the streams were placed: the demixing of family 3, or
    /// the clearing of the channels that no stream feeds.
    fn complete(self: *OpusCodec, frames: usize) void {
        if (self.head.family == 3) return self.project(frames);
        if (!self.has_silent) return;
        const channels: usize = self.head.channels;
        for (self.routes[0..channels]) |r| {
            if (r.stream != head_file.silent) continue;
            for (0..frames) |i| self.out[i * channels + r.dest] = 0;
        }
    }

    fn concealInto(self: *OpusCodec, frames: usize, at: usize) PacketError!void {
        for (0..self.head.streams) |s| {
            const buf = self.scratch[0 .. frames * self.streamChannels(s)];
            _ = self.decs[s].decode(null, false, buf) catch return error.BadPacket;
            self.place(s, frames, at);
        }
    }

    /// The frames per channel of an Ogg packet, when every stream in it parses and all of
    /// them have the same length.
    fn validate(self: *const OpusCodec, data: []const u8) PacketError!usize {
        var rest = data;
        var frames: ?usize = null;
        const streams: usize = self.head.streams;
        for (0..streams) |s| {
            const last = s + 1 == streams;
            const p = packet.parse(rest, !last) catch return error.BadPacket;
            const n = p.count * @as(usize, p.toc.frameSamples(out_rate));
            if (frames) |f| {
                if (f != n) return error.BadPacket;
            }
            frames = n;
            if (!last) {
                if (p.packet_offset > rest.len) return error.BadPacket;
                rest = rest[p.packet_offset..];
            }
        }
        return frames.?;
    }

    fn decodeInto(self: *OpusCodec, data: []const u8, frames: usize, at: usize) PacketError!void {
        var rest = data;
        const streams: usize = self.head.streams;
        for (0..streams) |s| {
            const buf = self.scratch[0 .. frames * self.streamChannels(s)];
            if (s + 1 == streams) {
                _ = self.decs[s].decode(rest, false, buf) catch return error.BadPacket;
            } else {
                const p = packet.parse(rest, true) catch return error.BadPacket;
                _ = self.decs[s].decodeParsed(&p, buf) catch return error.BadPacket;
                rest = rest[p.packet_offset..];
            }
            self.place(s, frames, at);
        }
    }

    /// Makes the frames of one Ogg packet in `out` and returns their count. An empty packet
    /// is a lost one and gives concealment.
    fn render(self: *OpusCodec, data: []const u8) PacketError!usize {
        if (data.len == 0) {
            self.had_loss = true;
            self.lost_pending = false;
            try self.concealInto(self.last_n, 0);
            self.complete(self.last_n);
            return self.last_n;
        }
        const frames = try self.validate(data);
        var lead: usize = 0;
        if (self.lost_pending) {
            lead = @min(self.last_n, max_frames - frames);
            if (lead > 0) try self.concealInto(lead, 0);
            self.lost_pending = false;
        }
        try self.decodeInto(data, frames, lead);
        self.last_n = frames;
        self.complete(lead + frames);
        return lead + frames;
    }

    /// Replaces a packet that does not decode with concealment.
    fn replace(self: *OpusCodec) ogg_chain.FrameError!usize {
        self.had_loss = true;
        self.lost_pending = false;
        self.concealInto(self.last_n, 0) catch {
            self.failed = error.BadData;
            return error.BadData;
        };
        self.complete(self.last_n);
        return self.last_n;
    }

    pub fn decode(self: *OpusCodec, p: packets.Packet) ogg_chain.FrameError!bool {
        self.bad_run = false;
        if (p.after_gap) self.markLoss();
        const n = self.render(p.data) catch switch (self.options.on_bad_packet) {
            .resync => blk: {
                if (!self.seeking) self.resyncs +|= 1;
                break :blk try self.replace();
            },
            .fail => {
                self.failed = error.BadData;
                return error.BadData;
            },
        };
        const channels: usize = self.head.channels;
        const samples = self.out[0 .. n * channels];
        for (samples) |*s| {
            const v = s.* * self.gain;
            s.* = if (std.math.isNan(v)) 0 else std.math.clamp(v, -1.0, max_gain);
        }
        self.block_n = n;
        self.page_frames += n;
        var hi = n;
        if (p.granule != -1) {
            if (p.eos) {
                const keep = @max(0, p.granule -| self.prev_granule);
                const cut = self.page_frames -| @as(u64, @intCast(keep));
                hi -= @intCast(@min(cut, hi));
            }
            self.page_frames = 0;
            self.prev_granule = p.granule;
        }
        const drop: usize = @intCast(@min(self.skip_left, hi));
        self.skip_left -= drop;
        self.pend_pos = drop;
        self.pend_end = hi;
        return true;
    }

    /// The reader dropped a packet that is bigger than the limit. It counts like a packet that
    /// does not decode.
    pub fn skipBad(self: *OpusCodec) bool {
        if (self.options.on_bad_packet != .resync) return false;
        if (!self.seeking and !self.bad_run) self.resyncs +|= 1;
        self.bad_run = true;
        self.markLoss();
        return true;
    }

    pub fn endOfData(self: *OpusCodec) ogg_chain.FrameError!bool {
        self.at_end = true;
        return false;
    }

    /// Stops the reads until the next link is entered.
    pub fn endLink(self: *OpusCodec) ogg_chain.FrameError!void {
        self.at_end = true;
    }

    pub fn read(self: *OpusCodec, comptime T: type, out: []T, loader: anytype) ogg_chain.FrameError!usize {
        comptime std.debug.assert(T == f32);
        const channels: usize = self.head.channels;
        std.debug.assert(out.len >= channels);
        const want = out.len / channels;
        var done: usize = 0;
        while (done < want) {
            if (self.pend_pos == self.pend_end) {
                const more = loader.loadBlock() catch |err| {
                    if (done > 0) return done;
                    return err;
                };
                if (!more) break;
                continue;
            }
            const take = @min(want - done, self.pend_end - self.pend_pos);
            @memcpy(out[done * channels ..][0 .. take * channels], self.out[self.pend_pos * channels ..][0 .. take * channels]);
            done += take;
            self.pend_pos += take;
        }
        return done;
    }

    pub fn beginSeek(self: *OpusCodec) void {
        self.resetStream();
        self.failed = null;
        self.at_end = false;
    }

    pub fn clearPosition(self: *OpusCodec) void {
        self.resetStream();
    }

    pub fn linkTotal(self: *const OpusCodec) ?u64 {
        _ = self;
        return null;
    }

    pub fn seekEnd(self: *OpusCodec, frames: u64) void {
        _ = frames;
        self.resetStream();
        self.at_end = true;
    }

    pub fn failSeek(self: *OpusCodec, err: ogg_chain.FrameError) void {
        self.resetStream();
        self.failed = err;
    }

    /// Moves the reader to the page at or before `target`. Null when there is none, and the
    /// reader is then at the first audio page.
    fn seekPage(chain: anytype, target: i64) codec.SeekError!?i64 {
        if (chain.scanned) return chain.reader.seekLinkGranule(chain.cur, target);
        return chain.reader.seekGranule(target);
    }

    fn restart(chain: anytype) codec.SeekError!void {
        chain.held = null;
        _ = try seekPage(chain, -1);
    }

    /// The granule where the first audio page starts: its granule less the frames of its
    /// packets. A page that ends before the frames it holds starts at 0. `first` is the first
    /// audio packet, and the reader follows it.
    fn pageStart(first: ?packets.Packet, reader: *packets.PacketReader) error{ OutOfMemory, ReadFailed }!i64 {
        var frames: i64 = 0;
        var guess: i64 = first_guess;
        var next = first;
        while (next) |p| {
            if (p.bos) break;
            guess = if (packet.samples(p.data, out_rate)) |n| n else |_| guess;
            frames +|= guess;
            if (p.granule != -1) return @max(0, p.granule -| frames);
            next = reader.next() catch |err| switch (err) {
                error.OutOfMemory, error.ReadFailed => |e| return e,
                error.BadData, error.Truncated => break,
            };
        }
        return 0;
    }

    /// The length is the last granule less the granule of the first output frame. It is a hint
    /// for a damaged stream.
    pub fn linkLength(self: *OpusCodec, h: *const LinkHeaders, link: *const packets.Link, reader: *packets.PacketReader) ?ogg_chain.Length {
        _ = self;
        const last = link.last_granule orelse return null;
        const start = (pageStart(h.held, reader) catch return null) +| h.head.pre_skip;
        return .{ .frames = if (last > start) @intCast(last - start) else 0, .trusted = false, .start = start };
    }

    /// The granule of the first output frame of the current link.
    fn startOffset(self: *OpusCodec, chain: anytype) codec.SeekError!i64 {
        if (self.start) |s| return s;
        if (chain.linkStart()) |s| {
            self.start = s;
            return s;
        }
        try restart(chain);
        const first = switch (try chain.nextData()) {
            .frame => |p| p,
            .link, .end => return self.head.pre_skip,
        };
        const s = (try pageStart(first, &chain.reader)) +| self.head.pre_skip;
        self.start = s;
        return s;
    }

    /// Moves to the last page that ends at least the pre-roll before `target`, and returns its
    /// granule. Null when there is no such page. The decoders start there with no state.
    fn positionAt(self: *OpusCodec, chain: anytype, target: i64) codec.SeekError!?i64 {
        chain.held = null;
        const found = seekPage(chain, target -| pre_roll) catch |err| switch (err) {
            error.BadData => {
                self.rescans +|= 1;
                return null;
            },
            else => |e| return e,
        };
        const granule = found orelse return null;
        return if (granule < 0) null else granule;
    }

    const Walk = error{Mismatch};

    /// Decodes forward until the frames that `skip_left` counts are dropped and a frame of the
    /// target is ready. `at` is the granule of the first packet. With `check`, a page granule
    /// that disagrees with the frames, or a loss, gives error.Mismatch.
    fn walk(self: *OpusCodec, chain: anytype, at: i64, check: bool) (codec.SeekError || Walk)!void {
        var time = at;
        while (true) {
            const p = switch (try chain.nextData()) {
                .frame => |p| p,
                .link => |p| {
                    chain.held = p;
                    return self.walkEnd();
                },
                .end => return self.walkEnd(),
            };
            _ = try self.decode(p);
            if (check) {
                if (self.had_loss) return error.Mismatch;
                time +|= @intCast(self.block_n);
                if (p.granule != -1 and !p.eos and p.granule != time) return error.Mismatch;
            }
            if (self.pend_pos < self.pend_end) return;
        }
    }

    fn walkEnd(self: *OpusCodec) codec.SeekError!void {
        if (self.skip_left != 0) return error.Truncated;
        self.pend_pos = 0;
        self.pend_end = 0;
    }

    pub fn seekIn(self: *OpusCodec, chain: anytype, local: u64) codec.SeekError!void {
        self.seeking = true;
        defer self.seeking = false;
        const base = try self.startOffset(chain);
        const target = std.math.add(i64, std.math.cast(i64, local) orelse return error.Truncated, base) catch return error.Truncated;
        const first = base - self.head.pre_skip;
        self.resetStream();
        if (try self.positionAt(chain, target)) |at| {
            self.skip_left = @intCast(target - at);
            self.prev_granule = at;
            if (self.walk(chain, at, true)) |_| return else |err| switch (err) {
                error.Mismatch => self.rescans +|= 1,
                else => |e| return e,
            }
        }
        // The target is near the start, or the granules and the frames disagree.
        try restart(chain);
        self.resetStream();
        self.skip_left = @as(u64, self.head.pre_skip) + local;
        self.walk(chain, first, false) catch |err| switch (err) {
            error.Mismatch => return error.BadData,
            else => |e| return e,
        };
    }
};

const OpusChain = ogg_chain.Chain(OpusCodec);

/// Reads Ogg Opus. All the links of a chained file play as one stream. The frame positions
/// of `seek` count from the start of the first link, in frames at 48 kHz. A link with the same
/// channel count and layout as the one before it continues without a signal. When they
/// change, `read` gives error.StreamChanged after the frames of the old link, and the next
/// `read` continues with the first frame of the new link.
pub const Decoder = struct {
    chain: OpusChain,

    pub fn init(gpa: std.mem.Allocator, input: *io.Input) codec.InitError!Decoder {
        return initOptions(gpa, input, .{});
    }

    pub fn initOptions(gpa: std.mem.Allocator, input: *io.Input, options: opus.Options) codec.InitError!Decoder {
        var reader = try packets.PacketReader.init(
            gpa,
            input,
            .{ .accept = .{ .func = isHead } },
            .{ .max_packet_size = header_packet_limit },
        );
        const first = blk: {
            errdefer reader.deinit();
            break :blk (reader.next() catch |err| return ogg_chain.initError(err)) orelse return error.Unsupported;
        };
        return initReader(gpa, input, reader, first.data, options);
    }

    /// Makes a decoder from a reader that has returned `first`, the OpusHead packet. The
    /// decoder takes the reader, also when this fails.
    ///
    /// On a seekable input this reads every page header of the file once, to find the links.
    pub fn initReader(
        gpa: std.mem.Allocator,
        input: *io.Input,
        reader_in: packets.PacketReader,
        first: []const u8,
        options: opus.Options,
    ) codec.InitError!Decoder {
        var reader = reader_in;
        var handed = false;
        errdefer if (!handed) reader.deinit();
        reader.select = .{ .accept = .{ .func = isHead } };
        reader.begin_group_only = false;
        reader.max_packet = header_packet_limit;
        var inner: OpusCodec = .{ .gpa = gpa, .options = options };
        errdefer if (!handed) inner.deinit();
        var h = try inner.readHeaders(&reader, first);
        var held = h.held;
        const bound = try inner.enter(&h);
        try ogg_chain.setBound(&reader, &held, bound);
        handed = true;
        return .{ .chain = try OpusChain.init(gpa, input, reader, inner, held) };
    }

    pub fn deinit(self: *Decoder) void {
        self.chain.deinit();
        self.* = undefined;
    }

    /// The rate is 48000. The channels and the mask are the ones of the current link.
    /// `total_frames` is the sum over the links when the input is seekable and every link has
    /// a page granule. It is the last granule less the pre-skip and the start of the first
    /// page, and a hint for a damaged stream. A reader that cannot seek gives null.
    pub fn info(self: *const Decoder) codec.Info {
        return self.chain.info();
    }

    pub fn stats(self: *const Decoder) Stats {
        return .{ .resyncs = self.chain.codec.resyncs };
    }

    /// Writes whole frames of f32 into `out` and returns the frame count. 0 means the end.
    /// `out` must hold at least one frame (`info().channels` samples).
    ///
    /// When the next link of a chained file has another channel count or layout, the call
    /// after the last frame of the old link returns error.StreamChanged and no frames.
    /// `info()` then describes the new link, and the next call continues with its first frame.
    ///
    /// When the input is seekable and `init` found every link, `read` does not allocate when
    /// it enters a later link. On an input that cannot seek, entering a link can allocate,
    /// and an out of memory error there gives error.ReadFailed.
    pub fn read(self: *Decoder, out: []f32) codec.ReadError!usize {
        return self.chain.read(f32, out);
    }

    /// Moves to a frame of the whole stream. `frame` equal to the frame count is the end of
    /// the data. A format change at a link is not reported by a seek: `info()` describes the
    /// link that the frame is in. A chained file whose link lengths are unknown gives
    /// error.Unsupported.
    ///
    /// The decoding starts 200 ms before the frame with no state, so the frames after a seek
    /// differ a little from the frames of a read from the start, unless the decoding starts at
    /// the first audio page.
    /// A seek allocates nothing unless it enters a link that `init` did not see.
    pub fn seek(self: *Decoder, frame: u64) codec.SeekError!void {
        return self.chain.seek(frame);
    }
};

fn embed(comptime name: []const u8) []const u8 {
    return @embedFile("../testdata/opus/" ++ name);
}

const Vector = struct {
    name: []const u8,
    file: []const u8,
    ref: []const u8,
    channels: u8,
    frames: usize,
    mask: u32,
};

const vectors = [_]Vector{
    .{ .name = "mono16k", .file = embed("mono16k.opus"), .ref = embed("mono16k.f32"), .channels = 1, .frames = 48591, .mask = 0x4 },
    .{ .name = "stereo48", .file = embed("stereo48.opus"), .ref = embed("stereo48.f32"), .channels = 2, .frames = 48000, .mask = 0x3 },
    .{ .name = "surround51", .file = embed("surround51.opus"), .ref = embed("surround51.f32"), .channels = 6, .frames = 24000, .mask = 0x3f },
    .{ .name = "frames60", .file = embed("frames60.opus"), .ref = embed("frames60.f32"), .channels = 1, .frames = 48000, .mask = 0x4 },
};

fn refSample(ref: []const u8, index: usize) f32 {
    return @bitCast(std.mem.readInt(u32, ref[index * 4 ..][0..4], .little));
}

/// The biggest difference between the samples of `got` and the reference, which holds every
/// 32nd frame. `order` gives the output position of each reference channel.
fn maxError(ref: []const u8, channels: usize, got: []const f32, order: []const u8) !f32 {
    const ref_frames = ref.len / 4 / channels;
    try testing.expect(got.len / channels >= (ref_frames - 1) * 32 + 1);
    var worst: f32 = 0;
    for (0..ref_frames) |i| {
        for (0..channels) |c| {
            const diff = @abs(refSample(ref, i * channels + c) - got[i * 32 * channels + order[c]]);
            worst = @max(worst, diff);
        }
    }
    return worst;
}

fn openBytes(gpa: std.mem.Allocator, input: *io.Input, bytes: []const u8) !Decoder {
    input.* = .init(.{ .bytes = bytes });
    return Decoder.init(gpa, input);
}

const identity: [8]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7 };

const chain_file = embed("chain.opus");
const chain_a_ref = embed("chain_a.f32");
const chain_b_ref = embed("chain_b.f32");

/// The libopus decode of FFmpeg is in WAVE order, like the output of the decoder, and the
/// samples differ by at most this much. The observed worst case is 1.53e-5, about half a step
/// of 16 bit audio.
const tolerance: f32 = 3e-5;

fn expectUnit(samples: []const f32) !void {
    for (samples) |s| try testing.expect(s >= -1.0 and s < 1.0);
}

test "each file decodes to its libopus reference" {
    const gpa = testing.allocator;
    for (vectors) |v| {
        var input: io.Input = undefined;
        var dec = try openBytes(gpa, &input, v.file);
        defer dec.deinit();
        const info = dec.info();
        try testing.expectEqual(@as(u32, 48000), info.rate);
        try testing.expectEqual(v.channels, info.channels);
        try testing.expectEqual(v.mask, @as(u32, @bitCast(info.mask)));
        try testing.expectEqual(@as(u8, 0), info.bits_per_sample);
        try testing.expectEqual(@as(?u64, v.frames), info.total_frames);
        const got = try helpers.readAll(gpa, &dec, 1000);
        defer gpa.free(got);
        try testing.expectEqual(v.frames * v.channels, got.len);
        try testing.expect(try maxError(v.ref, v.channels, got, &identity) <= tolerance);
        try expectUnit(got);
        try testing.expectEqual(@as(u32, 0), dec.stats().resyncs);
    }
}

test "a stream shorter than the pre-skip keeps the frames of its granule" {
    const gpa = testing.allocator;
    var input: io.Input = undefined;
    var dec = try openBytes(gpa, &input, embed("short.opus"));
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 96), dec.info().total_frames);
    const got = try helpers.readAll(gpa, &dec, 50);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 96), got.len);
    try expectUnit(got);
    var power: f64 = 0;
    for (got) |s| power += @as(f64, s) * s;
    try testing.expect(power > 0.01);
}

test "the output does not depend on the read size" {
    const gpa = testing.allocator;
    var input: io.Input = undefined;
    var whole = try openBytes(gpa, &input, vectors[2].file);
    defer whole.deinit();
    const want = try helpers.readAll(gpa, &whole, 5000);
    defer gpa.free(want);
    for ([_]usize{ 1, 7, 333 }) |chunk| {
        var input2: io.Input = undefined;
        var dec = try openBytes(gpa, &input2, vectors[2].file);
        defer dec.deinit();
        const got = try helpers.readAll(gpa, &dec, chunk);
        defer gpa.free(got);
        try testing.expectEqualSlices(f32, want, got);
    }
}

const LinkParts = struct { first: []f32, second: []f32 };

/// Reads a two link file and returns the samples before and after the StreamChanged.
fn readTwoLinks(gpa: std.mem.Allocator, dec: *Decoder) !LinkParts {
    var parts: [2]std.ArrayList(f32) = .{ .empty, .empty };
    errdefer for (&parts) |*p| p.deinit(gpa);
    var link: usize = 0;
    var buf: [1000]f32 = undefined;
    while (true) {
        const channels: usize = dec.info().channels;
        const n = dec.read(buf[0 .. 500 / channels * channels]) catch |err| switch (err) {
            error.StreamChanged => {
                link += 1;
                if (link > 1) return error.TestUnexpectedResult;
                continue;
            },
            else => return err,
        };
        if (n == 0) break;
        try parts[link].appendSlice(gpa, buf[0 .. n * channels]);
    }
    try testing.expectEqual(@as(usize, 1), link);
    const first = try parts[0].toOwnedSlice(gpa);
    errdefer gpa.free(first);
    return .{ .first = first, .second = try parts[1].toOwnedSlice(gpa) };
}

test "a chain with another channel count gives StreamChanged and then link two" {
    const gpa = testing.allocator;
    var input: io.Input = undefined;
    var dec = try openBytes(gpa, &input, chain_file);
    defer dec.deinit();
    try testing.expectEqual(@as(u8, 2), dec.info().channels);
    try testing.expectEqual(@as(?u64, 48000), dec.info().total_frames);
    const parts = try readTwoLinks(gpa, &dec);
    defer gpa.free(parts.first);
    defer gpa.free(parts.second);
    try testing.expectEqual(@as(usize, 24000 * 2), parts.first.len);
    try testing.expectEqual(@as(usize, 24000), parts.second.len);
    try testing.expect(try maxError(chain_a_ref, 2, parts.first, &identity) <= tolerance);
    try testing.expect(try maxError(chain_b_ref, 1, parts.second, &identity) <= tolerance);
    try testing.expectEqual(@as(u8, 1), dec.info().channels);
    try testing.expectEqual(@as(u32, 0), dec.stats().resyncs);
}

test "a forward-only reader decodes, crosses links and refuses to seek" {
    const gpa = testing.allocator;
    var input: io.Input = undefined;
    var whole = try openBytes(gpa, &input, vectors[1].file);
    defer whole.deinit();
    const want = try helpers.readAll(gpa, &whole, 4096);
    defer gpa.free(want);

    var reader: std.Io.Reader = .fixed(vectors[1].file);
    var forward: io.Input = .init(.{ .reader = &reader });
    var dec: Decoder = try .init(gpa, &forward);
    defer dec.deinit();
    try testing.expectError(error.Unseekable, dec.seek(10));
    try testing.expectEqual(@as(?u64, null), dec.info().total_frames);
    const got = try helpers.readAll(gpa, &dec, 999);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, want, got);

    var reader2: std.Io.Reader = .fixed(chain_file);
    var forward2: io.Input = .init(.{ .reader = &reader2 });
    var chain: Decoder = try .init(gpa, &forward2);
    defer chain.deinit();
    const parts = try readTwoLinks(gpa, &chain);
    defer gpa.free(parts.first);
    defer gpa.free(parts.second);
    try testing.expectEqual(@as(usize, 24000 * 2), parts.first.len);
    try testing.expectEqual(@as(usize, 24000), parts.second.len);
    try testing.expect(try maxError(chain_b_ref, 1, parts.second, &identity) <= tolerance);
}

test "reads after init do not allocate, also across a format change" {
    const gpa = testing.allocator;
    const Case = struct { file: []const u8, frames: usize };
    for ([_]Case{
        .{ .file = chain_file, .frames = 48000 },
        .{ .file = vectors[2].file, .frames = 24000 },
    }) |case| {
        var failing = testing.FailingAllocator.init(gpa, .{});
        var input: io.Input = .init(.{ .bytes = case.file });
        var dec: Decoder = try .init(failing.allocator(), &input);
        defer dec.deinit();
        failing.fail_index = failing.alloc_index;
        failing.resize_fail_index = failing.resize_index;
        var buf: [512]f32 = undefined;
        var total: usize = 0;
        while (true) {
            const channels: usize = dec.info().channels;
            const n = dec.read(buf[0 .. 256 / channels * channels]) catch |err| switch (err) {
                error.StreamChanged => continue,
                else => return err,
            };
            if (n == 0) break;
            total += n;
        }
        try testing.expectEqual(case.frames, total);
        try dec.seek(1234);
        const width: usize = dec.info().channels;
        try testing.expectEqual(@as(usize, 1), try dec.read(buf[0..width]));
    }
}

const Pk = struct { data: []u8, granule: i64, eos: bool };

fn freePks(gpa: std.mem.Allocator, pks: []Pk) void {
    for (pks) |p| gpa.free(p.data);
    gpa.free(pks);
}

fn demux(gpa: std.mem.Allocator, file: []const u8) ![]Pk {
    var input: io.Input = .init(.{ .bytes = file });
    var reader: packets.PacketReader = try .init(gpa, &input, .any, .{});
    defer reader.deinit();
    var list: std.ArrayList(Pk) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p.data);
        list.deinit(gpa);
    }
    while (try reader.next()) |p| {
        const data = try gpa.dupe(u8, p.data);
        errdefer gpa.free(data);
        try list.append(gpa, .{ .data = data, .granule = p.granule, .eos = p.eos });
    }
    return list.toOwnedSlice(gpa);
}

fn clonePks(gpa: std.mem.Allocator, pks: []const Pk) ![]Pk {
    const out = try gpa.alloc(Pk, pks.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |p| gpa.free(p.data);
        gpa.free(out);
    }
    for (pks, out) |p, *o| {
        o.* = .{ .data = try gpa.dupe(u8, p.data), .granule = p.granule, .eos = p.eos };
        done += 1;
    }
    return out;
}

/// Writes the packets as one stream. A page ends after each packet that has a granule, and
/// the last packet is on the end page.
fn muxPks(gpa: std.mem.Allocator, pks: []const Pk, serial: u32) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var w: packets.PacketWriter = try .init(gpa, &aw.writer, serial, .{});
    defer w.deinit();
    for (pks, 0..) |p, i| {
        try w.writePacket(p.data, p.granule);
        if (p.granule != -1 and i + 1 < pks.len) try w.flush();
    }
    try w.finish();
    return aw.toOwnedSlice();
}

/// Gives every audio packet the granule of the frames up to its end, plus `shift`, so each
/// packet has its own page. The last granule is cut by `trim` frames.
fn spreadGranules(pks: []Pk, shift: i64, trim: i64) void {
    var granule: i64 = shift;
    for (pks[2..]) |*p| {
        granule += packet.samples(p.data, out_rate) catch first_guess;
        p.granule = granule;
    }
    pks[pks.len - 1].granule -= trim;
}

fn decodeBytes(gpa: std.mem.Allocator, bytes: []const u8, options: opus.Options) ![]f32 {
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .initOptions(gpa, &input, options);
    defer dec.deinit();
    return helpers.readAll(gpa, &dec, 1000);
}

// The files have one or two pages, so a seek decodes from the first page and equals a read.
test "seeks in the files land on the samples of a full decode" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x4f707573);
    for (vectors) |v| {
        var input: io.Input = undefined;
        var dec = try openBytes(gpa, &input, v.file);
        defer dec.deinit();
        const want = try helpers.readAll(gpa, &dec, 4096);
        defer gpa.free(want);
        const channels: usize = v.channels;
        const total: u64 = v.frames;
        var targets: [23]u64 = undefined;
        targets[0] = 0;
        targets[1] = total;
        targets[2] = total - 1;
        for (targets[3..]) |*t| t.* = prng.random().uintLessThan(u64, total);
        for (targets) |t| {
            try dec.seek(t);
            const got = try helpers.readAll(gpa, &dec, 700);
            defer gpa.free(got);
            try testing.expectEqualSlices(f32, want[@as(usize, @intCast(t)) * channels ..], got);
        }
        try testing.expectError(error.Truncated, dec.seek(total + 1));
        try testing.expectEqual(@as(u32, 0), dec.chain.codec.rescans);
    }
}

/// Decoding starts 200 ms before a target, so the samples differ from a full decode while the
/// decoder state settles. The worst difference seen over the four files was 6.3e-3.
const seek_tolerance: f32 = 1e-2;

fn expectSeeksNear(dec: *Decoder, want: []const f32, channels: usize, targets: []const u64) !void {
    const gpa = testing.allocator;
    for (targets) |t| {
        try dec.seek(t);
        const got = try helpers.readAll(gpa, dec, 700);
        defer gpa.free(got);
        const tail = want[@as(usize, @intCast(t)) * channels ..];
        try testing.expectEqual(tail.len, got.len);
        for (tail, got) |a, b| try testing.expect(@abs(a - b) <= seek_tolerance);
    }
}

test "seeks in files with a page for each packet start 200 ms early and stay close" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x4f707573);
    for (vectors) |v| {
        const pks = try demux(gpa, v.file);
        defer freePks(gpa, pks);
        spreadGranules(pks, 0, 0);
        const bytes = try muxPks(gpa, pks, 1);
        defer gpa.free(bytes);
        var input: io.Input = undefined;
        var dec = try openBytes(gpa, &input, bytes);
        defer dec.deinit();
        const want = try helpers.readAll(gpa, &dec, 4096);
        defer gpa.free(want);
        const channels: usize = v.channels;
        const total: u64 = dec.info().total_frames.?;
        try testing.expectEqual(total * channels, want.len);
        var targets: [24]u64 = undefined;
        targets[0] = 0;
        targets[1] = total - 1;
        for (targets[2..]) |*t| t.* = prng.random().uintLessThan(u64, total);
        try expectSeeksNear(&dec, want, channels, &targets);
        // The first seek starts at the first page, so it equals a read.
        try dec.seek(0);
        const start = try helpers.readAll(gpa, &dec, 999);
        defer gpa.free(start);
        try testing.expectEqualSlices(f32, want, start);
        try dec.seek(total);
        var one: [8]f32 = undefined;
        try testing.expectEqual(@as(usize, 0), try dec.read(one[0..channels]));
        try testing.expectError(error.Truncated, dec.seek(total + 1));
        try testing.expectEqual(@as(u32, 0), dec.chain.codec.rescans);
    }
}

test "seeks cross the links of a chained file" {
    const gpa = testing.allocator;
    var input: io.Input = undefined;
    var dec = try openBytes(gpa, &input, chain_file);
    defer dec.deinit();
    const parts = try readTwoLinks(gpa, &dec);
    defer gpa.free(parts.first);
    defer gpa.free(parts.second);
    var prng: std.Random.DefaultPrng = .init(11);
    for (0..24) |_| {
        const t = prng.random().uintLessThan(u64, 48000);
        try dec.seek(t);
        try testing.expectEqual(@as(u8, if (t < 24000) 2 else 1), dec.info().channels);
        var all: std.ArrayList(f32) = .empty;
        defer all.deinit(gpa);
        var buf: [1000]f32 = undefined;
        const channels: usize = dec.info().channels;
        while (true) {
            const n = dec.read(buf[0 .. 1000 / channels * channels]) catch |err| switch (err) {
                error.StreamChanged => break,
                else => return err,
            };
            if (n == 0) break;
            try all.appendSlice(gpa, buf[0 .. n * channels]);
        }
        const want = if (t < 24000) parts.first[@as(usize, @intCast(t)) * 2 ..] else parts.second[@as(usize, @intCast(t - 24000))..];
        try testing.expectEqualSlices(f32, want, all.items);
    }
    try dec.seek(24000);
    try testing.expectEqual(@as(u8, 1), dec.info().channels);
    var one: [1]f32 = undefined;
    try testing.expectEqual(@as(usize, 1), try dec.read(&one));
    try testing.expectEqual(parts.second[0], one[0]);
    try testing.expectEqual(@as(u32, 0), dec.chain.codec.rescans);
}

fn headFor(channels: u8, family: u8, streams: u8, coupled: u8, table: []const u8) head_file.Head {
    var h: head_file.Head = .{
        .version = 1,
        .channels = channels,
        .pre_skip = 0,
        .input_rate = 48000,
        .gain = 0,
        .family = family,
        .streams = streams,
        .coupled = coupled,
        .mapping = @splat(head_file.silent),
    };
    @memcpy(h.mapping[0..table.len], table);
    return h;
}

const tags_packet = "OpusTags" ++ "\x04\x00\x00\x00test" ++ "\x00\x00\x00\x00";

/// Makes a stream from a head and audio packets. A page ends after each packet. The granules
/// count the frames of the packets, and the last one is cut by `trim`.
fn buildStream(gpa: std.mem.Allocator, h: *const head_file.Head, audio: []const []const u8, trim: i64) ![]u8 {
    return buildStreamAs(gpa, h, audio, trim, 7);
}

fn buildStreamAs(gpa: std.mem.Allocator, h: *const head_file.Head, audio: []const []const u8, trim: i64, serial: u32) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var w: packets.PacketWriter = try .init(gpa, &aw.writer, serial, .{});
    defer w.deinit();
    var buf: [2048]u8 = undefined;
    try w.writePacket(head_file.writeHead(&buf, h), 0);
    try w.flush();
    try w.writePacket(tags_packet, 0);
    try w.flush();
    var granule: i64 = 0;
    for (audio, 0..) |a, i| {
        granule += if (a.len == 0) first_guess else packet.samples(a, out_rate) catch first_guess;
        const last = i + 1 == audio.len;
        try w.writePacket(a, if (last) granule - trim else granule);
        if (!last) try w.flush();
    }
    try w.finish();
    return aw.toOwnedSlice();
}

/// The audio packets of a demuxed file, `count` of them.
fn audioOf(pks: []const Pk, count: usize) []const Pk {
    return pks[2..][0..count];
}

fn packetSlices(gpa: std.mem.Allocator, pks: []const Pk) ![][]const u8 {
    const out = try gpa.alloc([]const u8, pks.len);
    for (pks, out) |p, *o| o.* = p.data;
    return out;
}

/// Decodes packets one by one with a PacketDecoder, which is what a stream of one Opus
/// stream gives.
fn refDecode(gpa: std.mem.Allocator, channels: u32, audio: []const []const u8) ![]f32 {
    return refDecodeLimit(gpa, channels, audio, true);
}

fn refDecodeLimit(gpa: std.mem.Allocator, channels: u32, audio: []const []const u8, limit: bool) ![]f32 {
    const dec = try gpa.create(glue.PacketDecoder);
    defer gpa.destroy(dec);
    dec.* = try .init(channels, .{});
    dec.limit_output = limit;
    var all: std.ArrayList(f32) = .empty;
    errdefer all.deinit(gpa);
    var buf: [2 * max_frames]f32 = undefined;
    for (audio) |a| {
        const n = try dec.decode(a, false, &buf);
        try all.appendSlice(gpa, buf[0 .. n * channels]);
    }
    return all.toOwnedSlice(gpa);
}

/// Rewrites a packet with code 3 framing and the extra length field of a packet that is not
/// the last of a multistream packet.
fn selfDelimit(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    const p = try packet.parse(data, false);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, (data[0] & 0xfc) | 3);
    try out.append(gpa, 0x80 | @as(u8, @intCast(p.count)));
    var size: [2]u8 = undefined;
    for (0..p.count) |i| {
        const n = packet.encodeSize(@intCast(p.frame(i).len), &size);
        try out.appendSlice(gpa, size[0..n]);
    }
    for (0..p.count) |i| try out.appendSlice(gpa, p.frame(i));
    return out.toOwnedSlice(gpa);
}

fn readFrames(gpa: std.mem.Allocator, bytes: []const u8, channels: usize) ![]f32 {
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(channels, @as(usize, dec.info().channels));
    return helpers.readAll(gpa, &dec, 777);
}

test "a mapping table routes, swaps, repeats and silences the channels of one stream" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    const audio = try packetSlices(gpa, audioOf(pks, 20));
    defer gpa.free(audio);
    const ref = try refDecode(gpa, 2, audio);
    defer gpa.free(ref);
    try testing.expectEqual(@as(usize, 20 * 960 * 2), ref.len);

    const silent = head_file.silent;
    const cases = [_][]const u8{ &.{ 0, 1 }, &.{ 1, 0 }, &.{ 0, silent }, &.{ silent, 1, 0 }, &.{ 1, 1, 0, 0 } };
    for (cases) |table| {
        const channels: u8 = @intCast(table.len);
        const h = headFor(channels, 255, 1, 1, table);
        const bytes = try buildStream(gpa, &h, audio, 0);
        defer gpa.free(bytes);
        const got = try readFrames(gpa, bytes, channels);
        defer gpa.free(got);
        try testing.expectEqual(@as(usize, 20 * 960) * channels, got.len);
        for (0..20 * 960) |i| {
            for (table, 0..) |entry, c| {
                const want: f32 = if (entry == silent) 0 else ref[i * 2 + entry];
                try testing.expectEqual(want, got[i * channels + c]);
            }
        }
        var input: io.Input = .init(.{ .bytes = bytes });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(dec.info().mask)));
        try testing.expectEqual(@as(?u64, 20 * 960), dec.info().total_frames);
    }
}

test "streams in one packet decode with self delimited framing" {
    const gpa = testing.allocator;
    const stereo = try demux(gpa, vectors[1].file);
    defer freePks(gpa, stereo);
    const mono = try demux(gpa, vectors[0].file);
    defer freePks(gpa, mono);
    const count = 30;
    const a = try packetSlices(gpa, audioOf(stereo, count));
    defer gpa.free(a);
    const b = try packetSlices(gpa, audioOf(mono, count));
    defer gpa.free(b);
    const joined = try gpa.alloc([]const u8, count);
    defer gpa.free(joined);
    var made: usize = 0;
    defer for (joined[0..made]) |j| gpa.free(j);
    for (0..count) |i| {
        try testing.expectEqual(@as(u32, 960), try packet.samples(a[i], out_rate));
        try testing.expectEqual(@as(u32, 960), try packet.samples(b[i], out_rate));
        const delimited = try selfDelimit(gpa, a[i]);
        defer gpa.free(delimited);
        joined[i] = try std.mem.concat(gpa, u8, &.{ delimited, b[i] });
        made += 1;
    }
    const ref_a = try refDecode(gpa, 2, a);
    defer gpa.free(ref_a);
    const ref_b = try refDecode(gpa, 1, b);
    defer gpa.free(ref_b);

    // Family 1 with 3 channels: L, C, R in the Vorbis order, so the output is L, R, C.
    const h = headFor(3, 1, 2, 1, &.{ 0, 2, 1 });
    const bytes = try buildStream(gpa, &h, joined, 0);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(u32, 0x7), @as(u32, @bitCast(dec.info().mask)));
    const got = try helpers.readAll(gpa, &dec, 500);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, count * 960 * 3), got.len);
    for (0..count * 960) |i| {
        try testing.expectEqual(ref_a[i * 2], got[i * 3]);
        try testing.expectEqual(ref_a[i * 2 + 1], got[i * 3 + 1]);
        try testing.expectEqual(ref_b[i], got[i * 3 + 2]);
    }
    try testing.expectEqual(@as(u32, 0), dec.stats().resyncs);

    // A stream with another duration makes the whole packet bad.
    const long = try demux(gpa, vectors[3].file);
    defer freePks(gpa, long);
    const delimited = try selfDelimit(gpa, a[5]);
    defer gpa.free(delimited);
    const old = joined[5];
    defer gpa.free(old);
    joined[5] = try std.mem.concat(gpa, u8, &.{ delimited, long[2].data });
    const bad = try buildStream(gpa, &h, joined, 0);
    defer gpa.free(bad);
    var input2: io.Input = .init(.{ .bytes = bad });
    var dec2: Decoder = try .init(gpa, &input2);
    defer dec2.deinit();
    const damaged = try helpers.readAll(gpa, &dec2, 500);
    defer gpa.free(damaged);
    try testing.expectEqual(@as(usize, count * 960 * 3), damaged.len);
    try testing.expectEqual(@as(u32, 1), dec2.stats().resyncs);
    try expectUnit(damaged);
}

test "the output gain scales the samples and stays below full scale" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    const audio = try packetSlices(gpa, audioOf(pks, 20));
    defer gpa.free(audio);
    const ref = try refDecodeLimit(gpa, 2, audio, false);
    defer gpa.free(ref);
    var loud = false;
    for ([_]i16{ 1536, -1536, 5120, std.math.minInt(i16), std.math.maxInt(i16) }) |gain| {
        var h = headFor(2, 0, 1, 1, &.{ 0, 1 });
        h.gain = gain;
        const bytes = try buildStream(gpa, &h, audio, 0);
        defer gpa.free(bytes);
        const got = try readFrames(gpa, bytes, 2);
        defer gpa.free(got);
        try testing.expectEqual(ref.len, got.len);
        const factor = h.gainFactor();
        for (ref, got) |r, g| {
            try testing.expectEqual(std.math.clamp(r * factor, -1.0, max_gain), g);
            if (@abs(r * factor) >= 1.0) loud = true;
        }
        try expectUnit(got);
    }
    try testing.expect(loud);
}

test "the pre-skip and the end granule cut the frames" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    const audio = try packetSlices(gpa, audioOf(pks, 20));
    defer gpa.free(audio);
    const ref = try refDecode(gpa, 2, audio);
    defer gpa.free(ref);
    const Case = struct { skip: u16, trim: i64, frames: usize };
    for ([_]Case{
        .{ .skip = 0, .trim = 0, .frames = 19200 },
        .{ .skip = 312, .trim = 0, .frames = 19200 - 312 },
        .{ .skip = 1000, .trim = 500, .frames = 19200 - 1500 },
        .{ .skip = 0, .trim = 960, .frames = 19200 - 960 },
        .{ .skip = 960, .trim = 0, .frames = 19200 - 960 },
        .{ .skip = 961, .trim = 0, .frames = 19200 - 961 },
        .{ .skip = 19200, .trim = 0, .frames = 0 },
        .{ .skip = 60000, .trim = 0, .frames = 0 },
    }) |c| {
        var h = headFor(2, 0, 1, 1, &.{ 0, 1 });
        h.pre_skip = c.skip;
        const bytes = try buildStream(gpa, &h, audio, c.trim);
        defer gpa.free(bytes);
        var input: io.Input = .init(.{ .bytes = bytes });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        try testing.expectEqual(@as(?u64, c.frames), dec.info().total_frames);
        const got = try helpers.readAll(gpa, &dec, 333);
        defer gpa.free(got);
        try testing.expectEqual(c.frames * 2, got.len);
        // The first packet is not dropped when the trim is longer than the last packet.
        const from: usize = @as(usize, @min(c.skip, 19200)) * 2;
        try testing.expectEqualSlices(f32, ref[from..][0..got.len], got);
    }
}

test "a start that is cut from the file gives the same frames" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    spreadGranules(pks, 0, 0);
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    const want = try decodeBytes(gpa, bytes, .{});
    defer gpa.free(want);

    spreadGranules(pks, 50000, 0);
    const shifted = try muxPks(gpa, pks, 1);
    defer gpa.free(shifted);
    var input: io.Input = .init(.{ .bytes = shifted });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 48648), dec.info().total_frames);
    const got = try helpers.readAll(gpa, &dec, 2000);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, want, got);
    try expectSeeksNear(&dec, want, 2, &.{ 0, 1, 7777, 30000, 48647 });
}

test "an end granule ahead of the frames adds nothing" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    spreadGranules(pks, 0, -5000);
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    const got = try decodeBytes(gpa, bytes, .{});
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, (48648 - 0) * 2), got.len);
}

test "an end trim longer than the last packet cuts only that packet" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    const audio = try packetSlices(gpa, audioOf(pks, 20));
    defer gpa.free(audio);
    const h = headFor(2, 0, 1, 1, &.{ 0, 1 });
    const bytes = try buildStream(gpa, &h, audio, 2000);
    defer gpa.free(bytes);
    const got = try readFrames(gpa, bytes, 2);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, (19200 - 960) * 2), got.len);
}

fn stereoPackets(gpa: std.mem.Allocator, pks: []const Pk, count: usize) ![][]const u8 {
    return packetSlices(gpa, audioOf(pks, count));
}

test "a packet that does not parse is concealed, counted and the stream goes on" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    const audio = try stereoPackets(gpa, pks, 30);
    defer gpa.free(audio);
    const h = headFor(2, 0, 1, 1, &.{ 0, 1 });
    const clean_bytes = try buildStream(gpa, &h, audio, 0);
    defer gpa.free(clean_bytes);
    const clean = try decodeBytes(gpa, clean_bytes, .{});
    defer gpa.free(clean);

    audio[10] = &.{ 0x03, 0x00 };
    const bytes = try buildStream(gpa, &h, audio, 0);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const got = try helpers.readAll(gpa, &dec, 500);
    defer gpa.free(got);
    try testing.expectEqual(clean.len, got.len);
    try testing.expectEqual(@as(u32, 1), dec.stats().resyncs);
    try testing.expectEqualSlices(f32, clean[0 .. 10 * 960 * 2], got[0 .. 10 * 960 * 2]);
    try expectUnit(got);
    // The concealed packet is not silent, it continues the signal before it.
    var power: f64 = 0;
    for (got[10 * 960 * 2 ..][0 .. 960 * 2]) |s| power += @as(f64, s) * s;
    try testing.expect(power > 0);

    try testing.expectError(error.BadData, decodeBytes(gpa, bytes, .{ .on_bad_packet = .fail }));
}

test "an empty packet is a loss that the concealment fills" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    const audio = try stereoPackets(gpa, pks, 30);
    defer gpa.free(audio);
    audio[10] = &.{};
    const h = headFor(2, 0, 1, 1, &.{ 0, 1 });
    const bytes = try buildStream(gpa, &h, audio, 0);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const got = try helpers.readAll(gpa, &dec, 500);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 30 * 960 * 2), got.len);
    try testing.expectEqual(@as(u32, 0), dec.stats().resyncs);
    try expectUnit(got);
    const fail = try decodeBytes(gpa, bytes, .{ .on_bad_packet = .fail });
    defer gpa.free(fail);
    try testing.expectEqualSlices(f32, got, fail);
}

/// Removes the page `index` from a stream.
fn dropPage(gpa: std.mem.Allocator, bytes: []const u8, index: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var at: usize = 0;
    var n: usize = 0;
    while (at < bytes.len) : (n += 1) {
        const page = try packets.parsePage(bytes[at..]);
        if (n != index) try out.appendSlice(gpa, bytes[at..][0..page.size()]);
        at += page.size();
    }
    return out.toOwnedSlice(gpa);
}

test "a lost page is replaced by concealment" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    const audio = try stereoPackets(gpa, pks, 30);
    defer gpa.free(audio);
    const h = headFor(2, 0, 1, 1, &.{ 0, 1 });
    const bytes = try buildStream(gpa, &h, audio, 0);
    defer gpa.free(bytes);
    const clean = try decodeBytes(gpa, bytes, .{});
    defer gpa.free(clean);
    // Two header pages, then one page for each packet.
    const cut = try dropPage(gpa, bytes, 2 + 10);
    defer gpa.free(cut);
    const got = try decodeBytes(gpa, cut, .{});
    defer gpa.free(got);
    try testing.expectEqual(clean.len, got.len);
    try testing.expectEqualSlices(f32, clean[0 .. 10 * 960 * 2], got[0 .. 10 * 960 * 2]);
    try expectUnit(got);
    var power: f64 = 0;
    for (got[10 * 960 * 2 ..][0 .. 960 * 2]) |s| power += @as(f64, s) * s;
    try testing.expect(power > 0);
}

test "a packet over the limit is replaced and counted" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    const audio = try stereoPackets(gpa, pks, 12);
    defer gpa.free(audio);
    const big = try gpa.alloc(u8, stream_packet_limit + 1);
    defer gpa.free(big);
    @memset(big, 0);
    audio[6] = big;
    const h = headFor(2, 0, 1, 1, &.{ 0, 1 });
    const bytes = try buildStream(gpa, &h, audio, 0);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const got = try helpers.readAll(gpa, &dec, 500);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 12 * 960 * 2), got.len);
    try testing.expectEqual(@as(u32, 1), dec.stats().resyncs);
    try expectUnit(got);
    var strict: io.Input = .init(.{ .bytes = bytes });
    var dec2: Decoder = try .initOptions(gpa, &strict, .{ .on_bad_packet = .fail });
    defer dec2.deinit();
    try testing.expectError(error.BadData, helpers.readAll(gpa, &dec2, 500));
}

fn expectInitError(want: anyerror, bytes: []const u8) !void {
    var input: io.Input = .init(.{ .bytes = bytes });
    try testing.expectError(want, Decoder.init(testing.allocator, &input));
}

test "hostile headers give errors" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[0].file);
    defer freePks(gpa, pks);
    const audio = try stereoPackets(gpa, pks, 3);
    defer gpa.free(audio);
    var h = headFor(1, 0, 1, 0, &.{0});
    h.channels = 0;
    const no_channels = try buildStream(gpa, &h, audio, 0);
    defer gpa.free(no_channels);
    try expectInitError(error.BadHeader, no_channels);

    h = headFor(3, 0, 1, 2, &.{ 0, 1, 2 });
    const family_zero = try buildStream(gpa, &h, audio, 0);
    defer gpa.free(family_zero);
    try expectInitError(error.BadHeader, family_zero);

    // A family 3 header without its demixing matrix.
    h = headFor(4, 3, 2, 2, &.{ 0, 1, 2, 3 });
    const ambisonic = try buildStream(gpa, &h, audio, 0);
    defer gpa.free(ambisonic);
    try expectInitError(error.BadHeader, ambisonic);

    h = headFor(2, 255, 1, 1, &.{ 0, 3 });
    const wild = try buildStream(gpa, &h, audio, 0);
    defer gpa.free(wild);
    try expectInitError(error.BadHeader, wild);

    // The tags packet is not tags.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var w: packets.PacketWriter = try .init(gpa, &aw.writer, 7, .{});
    defer w.deinit();
    var buf: [300]u8 = undefined;
    h = headFor(1, 0, 1, 0, &.{0});
    try w.writePacket(head_file.writeHead(&buf, &h), 0);
    try w.flush();
    try w.writePacket("OpusTags\xff\xff\xff\xff", 0);
    try w.finish();
    try expectInitError(error.BadHeader, aw.written());

    // Only the head, then the end of the file.
    var only: std.Io.Writer.Allocating = .init(gpa);
    defer only.deinit();
    var w2: packets.PacketWriter = try .init(gpa, &only.writer, 7, .{});
    defer w2.deinit();
    try w2.writePacket(head_file.writeHead(&buf, &h), 0);
    try w2.finish();
    try expectInitError(error.Truncated, only.written());

    // A head with no audio has no frames.
    var none: std.Io.Writer.Allocating = .init(gpa);
    defer none.deinit();
    var w3: packets.PacketWriter = try .init(gpa, &none.writer, 7, .{});
    defer w3.deinit();
    try w3.writePacket(head_file.writeHead(&buf, &h), 0);
    try w3.flush();
    try w3.writePacket(tags_packet, 0);
    try w3.finish();
    var input: io.Input = .init(.{ .bytes = none.written() });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    var one: [1]f32 = undefined;
    try testing.expectEqual(@as(usize, 0), try dec.read(&one));
    try dec.seek(0);
    try testing.expectEqual(@as(usize, 0), try dec.read(&one));
}

fn drain(dec: *Decoder) !void {
    var buf: [1024]f32 = undefined;
    while (true) {
        const width: usize = dec.info().channels;
        const n = dec.read(buf[0 .. 512 / width * width]) catch |err| switch (err) {
            error.StreamChanged => continue,
            else => return,
        };
        if (n == 0) return;
        try expectUnit(buf[0 .. n * width]);
    }
}

test "bit flips in the headers give errors or finite samples" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x7845);
    const random = prng.random();
    const base = try demux(gpa, vectors[2].file);
    defer freePks(gpa, base);
    for (0..300) |_| {
        const pks = try clonePks(gpa, base);
        defer freePks(gpa, pks);
        const target = random.uintLessThan(usize, 2);
        const p = &pks[target];
        const at = random.uintLessThan(usize, @min(p.data.len, 40));
        p.data[at] ^= @as(u8, 1) << random.int(u3);
        const bytes = try muxPks(gpa, pks, 1);
        defer gpa.free(bytes);
        var input: io.Input = .init(.{ .bytes = bytes });
        var dec = Decoder.init(gpa, &input) catch continue;
        defer dec.deinit();
        try drain(&dec);
    }
}

test "random and damaged audio packets give finite samples" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x4f70);
    const random = prng.random();
    const base = try demux(gpa, vectors[2].file);
    defer freePks(gpa, base);
    for (0..60) |round| {
        const pks = try clonePks(gpa, base);
        defer freePks(gpa, pks);
        for (pks[2..]) |*p| {
            if (random.uintLessThan(u8, 4) != 0) continue;
            if (random.boolean()) {
                p.data[random.uintLessThan(usize, p.data.len)] ^= random.int(u8);
            } else {
                const len = random.uintLessThan(usize, 400);
                const data = try gpa.realloc(p.data, len);
                p.data = data;
                random.bytes(data);
            }
        }
        const bytes = try muxPks(gpa, pks, 1);
        defer gpa.free(bytes);
        for ([_]opus.Options{ .{}, .{ .on_bad_packet = .fail }, .{ .phase_inversion = false } }) |options| {
            var input: io.Input = .init(.{ .bytes = bytes });
            var dec = Decoder.initOptions(gpa, &input, options) catch continue;
            defer dec.deinit();
            try drain(&dec);
            if (round % 8 == 0 and dec.info().total_frames != null) {
                const total = dec.info().total_frames.?;
                dec.seek(random.uintLessThan(u64, total + 1)) catch continue;
                try drain(&dec);
            }
        }
    }
}

test "a file cut anywhere gives frames or an error" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x1234);
    const random = prng.random();
    for (vectors) |v| {
        for (0..12) |_| {
            const len = random.uintLessThan(usize, v.file.len);
            var input: io.Input = .init(.{ .bytes = v.file[0..len] });
            var dec = Decoder.init(gpa, &input) catch continue;
            defer dec.deinit();
            try drain(&dec);
        }
    }
}

test "random multistream packets give finite samples" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x5151);
    const random = prng.random();
    const h = headFor(5, 255, 4, 1, &.{ 0, 1, 2, 3, 4 });
    for (0..40) |_| {
        const audio = try gpa.alloc([]const u8, 6);
        defer gpa.free(audio);
        var made: usize = 0;
        defer for (audio[0..made]) |a| gpa.free(a);
        for (audio) |*a| {
            const data = try gpa.alloc(u8, 1 + random.uintLessThan(usize, 600));
            random.bytes(data);
            // Code 0 and 20 ms CELT frames parse most of the time.
            if (random.boolean()) data[0] = 0xe0 | (data[0] & 0x04);
            a.* = data;
            made += 1;
        }
        const bytes = try buildStream(gpa, &h, audio, 0);
        defer gpa.free(bytes);
        var input: io.Input = .init(.{ .bytes = bytes });
        var dec = try Decoder.init(gpa, &input);
        defer dec.deinit();
        try drain(&dec);
    }
}

fn concatBytes(gpa: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.mem.concat(gpa, u8, parts);
}

test "links with the same shape continue and another layout gives StreamChanged" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    const audio = try stereoPackets(gpa, pks, 10);
    defer gpa.free(audio);
    const plain = headFor(2, 0, 1, 1, &.{ 0, 1 });
    const wild = headFor(2, 255, 1, 1, &.{ 0, 1 });
    const one = try buildStreamAs(gpa, &plain, audio, 0, 1);
    defer gpa.free(one);
    const two = try buildStreamAs(gpa, &plain, audio, 0, 2);
    defer gpa.free(two);
    const three = try buildStreamAs(gpa, &wild, audio, 0, 3);
    defer gpa.free(three);
    const single = try decodeBytes(gpa, one, .{});
    defer gpa.free(single);

    const same = try concatBytes(gpa, &.{ one, two });
    defer gpa.free(same);
    var input: io.Input = .init(.{ .bytes = same });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 2 * 9600), dec.info().total_frames);
    const got = try helpers.readAll(gpa, &dec, 1000);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, single, got[0..single.len]);
    try testing.expectEqualSlices(f32, single, got[single.len..]);
    try dec.seek(9600 - 5);
    var buf: [40]f32 = undefined;
    try testing.expectEqual(@as(usize, 20), try dec.read(&buf));
    try testing.expectEqualSlices(f32, single[single.len - 10 ..], buf[0..10]);
    try testing.expectEqualSlices(f32, single[0..10], buf[10..20]);

    const changed = try concatBytes(gpa, &.{ one, three });
    defer gpa.free(changed);
    var input2: io.Input = .init(.{ .bytes = changed });
    var dec2: Decoder = try .init(gpa, &input2);
    defer dec2.deinit();
    try testing.expectEqual(@as(u32, 0x3), @as(u32, @bitCast(dec2.info().mask)));
    const parts = try readTwoLinks(gpa, &dec2);
    defer gpa.free(parts.first);
    defer gpa.free(parts.second);
    try testing.expectEqualSlices(f32, single, parts.first);
    try testing.expectEqualSlices(f32, single, parts.second);
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(dec2.info().mask)));
}

test "a granule that runs backward makes the seek decode from the start" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    spreadGranules(pks, 0, 0);
    pks[pks.len / 2].granule += 20000;
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const want = try helpers.readAll(gpa, &dec, 4096);
    defer gpa.free(want);
    try expectSeeksNear(&dec, want, 2, &.{ 40000, 10, 47000, 12345 });
    try testing.expect(dec.chain.codec.rescans > 0);
}

test "a seek across a lost page still gives frames" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    spreadGranules(pks, 0, 0);
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    const cut = try dropPage(gpa, bytes, 2 + 20);
    defer gpa.free(cut);
    var input: io.Input = .init(.{ .bytes = cut });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    for ([_]u64{ 40000, 19000, 21000, 47000 }) |t| {
        try dec.seek(t);
        const got = try helpers.readAll(gpa, &dec, 4096);
        defer gpa.free(got);
        try testing.expect(got.len > 0);
        try expectUnit(got);
    }
}

test "the output gain comes before the limit" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x6c696d69);
    const random = prng.random();
    // Random CELT packets decode to samples above full scale.
    var loud: ?[]u8 = null;
    defer if (loud) |l| gpa.free(l);
    var peak: f32 = 0;
    for (0..4000) |_| {
        const data = try gpa.alloc(u8, 60 + random.uintLessThan(usize, 200));
        random.bytes(data);
        data[0] = 0xf8;
        const raw = refDecodeLimit(gpa, 1, &.{data}, false) catch {
            gpa.free(data);
            continue;
        };
        defer gpa.free(raw);
        var top: f32 = 0;
        for (raw) |s| top = @max(top, @abs(s));
        if (top > peak) {
            peak = top;
            if (loud) |l| gpa.free(l);
            loud = data;
        } else gpa.free(data);
        if (peak > 1.3) break;
    }
    try testing.expect(peak > 1.3);
    const audio: [1][]const u8 = .{loud.?};
    const raw = try refDecodeLimit(gpa, 1, &audio, false);
    defer gpa.free(raw);
    var h = headFor(1, 0, 1, 0, &.{0});
    h.gain = -1536;
    const bytes = try buildStream(gpa, &h, &audio, 0);
    defer gpa.free(bytes);
    const got = try readFrames(gpa, bytes, 1);
    defer gpa.free(got);
    try testing.expectEqual(raw.len, got.len);
    const factor = h.gainFactor();
    var seen = false;
    for (raw, got) |r, g| {
        try testing.expectEqual(std.math.clamp(r * factor, -1.0, max_gain), g);
        if (@abs(r) > 1.0 and @abs(r * factor) < 1.0) seen = true;
    }
    try testing.expect(seen);
}

/// Streams made by the packet encoder, one packet for each 20 ms, joined as the packets of an
/// Ogg Opus file with several streams.
const Ambisonic = struct {
    /// The packets of the Ogg file.
    joined: [][]u8,
    /// The decoded samples of each stream, before the output gain and the limit.
    refs: [][]f32,
    coupled: usize,
    streams: usize,

    fn deinit(self: Ambisonic, gpa: std.mem.Allocator) void {
        for (self.joined) |j| gpa.free(j);
        gpa.free(self.joined);
        for (self.refs) |r| gpa.free(r);
        gpa.free(self.refs);
    }

    /// The width of the stream `s` in channels.
    fn width(self: Ambisonic, s: usize) usize {
        return if (s < self.coupled) 2 else 1;
    }

    /// The sample of column `col` of the stream channels at the frame `i`.
    fn column(self: Ambisonic, col: usize, i: usize) f32 {
        var left = col;
        for (0..self.streams) |s| {
            const w = self.width(s);
            if (left < w) return self.refs[s][i * w + left];
            left -= w;
        }
        unreachable;
    }
};

fn makeAmbisonic(gpa: std.mem.Allocator, streams: usize, coupled: usize, count: usize) !Ambisonic {
    const enc = try gpa.create(opus.PacketEncoder);
    defer gpa.destroy(enc);
    const coded = try gpa.alloc([][]u8, streams);
    defer gpa.free(coded);
    var refs = try gpa.alloc([]f32, streams);
    var made_refs: usize = 0;
    errdefer {
        for (refs[0..made_refs]) |r| gpa.free(r);
        gpa.free(refs);
    }
    var made: usize = 0;
    defer for (coded[0..made]) |list| {
        for (list) |p| gpa.free(p);
        gpa.free(list);
    };
    for (0..streams) |s| {
        const width: u32 = if (s < coupled) 2 else 1;
        try enc.initInto(width, .{ .bitrate = 48000 * width });
        const list = try gpa.alloc([]u8, count);
        coded[s] = list;
        made += 1;
        var have: usize = 0;
        errdefer {
            for (list[0..have]) |p| gpa.free(p);
        }
        var pcm: [960 * 2]f32 = undefined;
        for (0..count) |k| {
            for (0..960) |i| {
                for (0..width) |c| {
                    const t: f64 = @floatFromInt(k * 960 + i);
                    const freq = 300.0 + 110.0 * @as(f64, @floatFromInt(2 * s + c));
                    pcm[i * width + c] = 0.3 * @as(f32, @floatCast(@sin(2.0 * std.math.pi * freq * t / 48000.0)));
                }
            }
            var buf: [1276]u8 = undefined;
            const n = try enc.encode(pcm[0 .. 960 * width], &buf);
            list[k] = try gpa.dupe(u8, buf[0..n]);
            have += 1;
        }
        refs[s] = try refDecodeLimit(gpa, width, list, false);
        made_refs += 1;
    }
    const joined = try gpa.alloc([]u8, count);
    var have_joined: usize = 0;
    errdefer {
        for (joined[0..have_joined]) |j| gpa.free(j);
        gpa.free(joined);
    }
    for (0..count) |k| {
        var parts: std.ArrayList(u8) = .empty;
        defer parts.deinit(gpa);
        for (0..streams) |s| {
            if (s + 1 < streams) {
                const d = try selfDelimit(gpa, coded[s][k]);
                defer gpa.free(d);
                try parts.appendSlice(gpa, d);
            } else {
                try parts.appendSlice(gpa, coded[s][k]);
            }
        }
        joined[k] = try parts.toOwnedSlice(gpa);
        have_joined += 1;
    }
    return .{ .joined = joined, .refs = refs, .coupled = coupled, .streams = streams };
}

fn constSlices(gpa: std.mem.Allocator, packets_in: []const []u8) ![][]const u8 {
    const out = try gpa.alloc([]const u8, packets_in.len);
    for (packets_in, out) |p, *o| o.* = p;
    return out;
}

/// The matrix entry in Q15 for a coefficient with an exact binary value.
fn q15(v: f32) i16 {
    return @intFromFloat(v * 32768.0);
}

/// The little endian bytes of a matrix given column by column.
fn matrixBytes(gpa: std.mem.Allocator, values: []const i16) ![]u8 {
    const out = try gpa.alloc(u8, 2 * values.len);
    for (values, 0..) |v, i| std.mem.writeInt(i16, out[2 * i ..][0..2], v, .little);
    return out;
}

fn headFor3(channels: u8, streams: u8, coupled: u8, matrix: []const u8) head_file.Head {
    var h = headFor(channels, 3, streams, coupled, &.{});
    h.matrix = matrix;
    return h;
}

test "family 2 gives the stream channels in the order of the table" {
    const gpa = testing.allocator;
    const data = try makeAmbisonic(gpa, 3, 2, 8);
    defer data.deinit(gpa);
    const audio = try constSlices(gpa, data.joined);
    defer gpa.free(audio);
    const frames: usize = 8 * 960;

    // Four ACN channels and the two non-diegetic channels, with the second ACN channel silent.
    const silent = head_file.silent;
    const table = [_]u8{ 0, silent, 2, 3, 4, 1 };
    const h = headFor(6, 2, 3, 2, &table);
    const bytes = try buildStream(gpa, &h, audio, 0);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(u8, 6), dec.info().channels);
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(dec.info().mask)));
    const got = try helpers.readAll(gpa, &dec, 700);
    defer gpa.free(got);
    try testing.expectEqual(frames * 6, got.len);
    for (0..frames) |i| {
        for (table, 0..) |entry, c| {
            const want: f32 = if (entry == silent) 0 else data.column(entry, i);
            try testing.expectEqual(want, got[i * 6 + c]);
        }
    }
}

test "family 3 multiplies the stream channels by the demixing matrix" {
    const gpa = testing.allocator;
    const data = try makeAmbisonic(gpa, 3, 1, 8);
    defer data.deinit(gpa);
    const audio = try constSlices(gpa, data.joined);
    defer gpa.free(audio);
    const frames: usize = 8 * 960;
    // The first stream has two channels and the two others one each, so there are four columns.
    const columns: usize = 4;

    const Case = struct { channels: usize, rows: []const [4]f32 };
    const cases = [_]Case{
        // Half of each stream channel.
        .{ .channels = 4, .rows = &.{ .{ 0.5, 0, 0, 0 }, .{ 0, 0.5, 0, 0 }, .{ 0, 0, 0.5, 0 }, .{ 0, 0, 0, 0.5 } } },
        // A swap and a negation.
        .{ .channels = 4, .rows = &.{ .{ 0, 0, 0, 0.5 }, .{ 0, -0.5, 0, 0 }, .{ 0.25, 0, 0, 0 }, .{ 0, 0, 0.5, 0 } } },
        // Mixes, a row of zeros and more rows than stream channels.
        .{ .channels = 6, .rows = &.{ .{ 0.5, 0.25, 0, -0.125 }, .{ 0, 0, 0, 0 }, .{ 0.5, 0.5, 0.5, 0.5 }, .{ 0.125, 0, 0.25, 0 }, .{ 0, 0.75, 0, 0 }, .{ -0.5, 0, 0, 0.5 } } },
        // One output channel.
        .{ .channels = 1, .rows = &.{.{ 0.25, 0.25, 0.25, 0.25 }} },
    };
    for (cases) |case| {
        const values = try gpa.alloc(i16, columns * case.channels);
        defer gpa.free(values);
        for (0..case.channels) |row| {
            for (0..columns) |col| values[col * case.channels + row] = q15(case.rows[row][col]);
        }
        const matrix = try matrixBytes(gpa, values);
        defer gpa.free(matrix);
        const h = headFor3(@intCast(case.channels), 3, 1, matrix);
        const bytes = try buildStream(gpa, &h, audio, 0);
        defer gpa.free(bytes);
        var input: io.Input = .init(.{ .bytes = bytes });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        try testing.expectEqual(case.channels, @as(usize, dec.info().channels));
        try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(dec.info().mask)));
        const got = try helpers.readAll(gpa, &dec, 700);
        defer gpa.free(got);
        try testing.expectEqual(frames * case.channels, got.len);
        for (0..frames) |i| {
            for (0..case.channels) |row| {
                var want: f64 = 0;
                var nonzero: usize = 0;
                var only: f32 = 0;
                for (0..columns) |col| {
                    const coef = case.rows[row][col];
                    want += @as(f64, coef) * data.column(col, i);
                    if (coef != 0) {
                        nonzero += 1;
                        only = coef * data.column(col, i);
                    }
                }
                // A row with one coefficient of a power of two is exact.
                try testing.expectApproxEqAbs(@as(f32, @floatCast(want)), got[i * case.channels + row], 2e-7);
                if (nonzero == 1) try testing.expectEqual(only, got[i * case.channels + row]);
            }
        }
    }
}

test "the output gain follows the demixing" {
    const gpa = testing.allocator;
    const data = try makeAmbisonic(gpa, 2, 0, 6);
    defer data.deinit(gpa);
    const audio = try constSlices(gpa, data.joined);
    defer gpa.free(audio);
    const matrix = try matrixBytes(gpa, &.{ 32767, 0, 0, 0, q15(0.5), 0 });
    defer gpa.free(matrix);
    var h = headFor3(3, 2, 0, matrix);
    h.gain = -6 * 256;
    const bytes = try buildStream(gpa, &h, audio, 0);
    defer gpa.free(bytes);
    const got = try readFrames(gpa, bytes, 3);
    defer gpa.free(got);
    const factor = h.gainFactor();
    for (0..6 * 960) |i| {
        const a = (32767.0 / 32768.0) * data.column(0, i) * factor;
        const b = 0.5 * data.column(1, i) * factor;
        try testing.expectApproxEqAbs(a, got[i * 3], 1e-6);
        try testing.expectApproxEqAbs(b, got[i * 3 + 1], 1e-6);
        try testing.expectEqual(@as(f32, 0), got[i * 3 + 2]);
    }
}

test "links of family 3 use their own matrix and the reads do not allocate" {
    const gpa = testing.allocator;
    const data = try makeAmbisonic(gpa, 2, 0, 5);
    defer data.deinit(gpa);
    const audio = try constSlices(gpa, data.joined);
    defer gpa.free(audio);
    // Three output channels from two stream channels, column by column.
    const first = try matrixBytes(gpa, &.{ q15(0.5), 0, q15(0.25), 0, q15(0.5), q15(0.25) });
    defer gpa.free(first);
    const second = try matrixBytes(gpa, &.{ 0, q15(-0.5), 0, q15(0.25), 0, 0 });
    defer gpa.free(second);
    const third = try matrixBytes(gpa, &.{ q15(0.125), 0, q15(0.5), q15(0.125), 0, 0 });
    defer gpa.free(third);
    var parts: [3][]u8 = undefined;
    const matrices = [_][]const u8{ first, second, third };
    for (matrices, &parts, 0..) |m, *p, serial| {
        const h = headFor3(3, 2, 0, m);
        p.* = try buildStreamAs(gpa, &h, audio, 0, @intCast(serial + 1));
    }
    defer for (parts) |p| gpa.free(p);
    const file = try concatBytes(gpa, &parts);
    defer gpa.free(file);

    var failing = testing.FailingAllocator.init(gpa, .{});
    var input: io.Input = .init(.{ .bytes = file });
    var dec: Decoder = try .init(failing.allocator(), &input);
    defer dec.deinit();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    const got = try helpers.readAll(gpa, &dec, 1000);
    defer gpa.free(got);
    const link = 5 * 960;
    try testing.expectEqual(3 * link * 3, got.len);
    for (0..link) |i| {
        const x0 = data.column(0, i);
        const x1 = data.column(1, i);
        try testing.expectEqual(0.5 * x0, got[i * 3]);
        try testing.expectEqual(0.5 * x1, got[i * 3 + 1]);
        try testing.expectEqual(0.25 * x0 + 0.25 * x1, got[i * 3 + 2]);
        try testing.expectEqual(0.25 * x1, got[(link + i) * 3]);
        try testing.expectEqual(-0.5 * x0, got[(link + i) * 3 + 1]);
        try testing.expectEqual(@as(f32, 0), got[(link + i) * 3 + 2]);
        try testing.expectEqual(0.125 * x0 + 0.125 * x1, got[(2 * link + i) * 3]);
        try testing.expectEqual(@as(f32, 0), got[(2 * link + i) * 3 + 1]);
        try testing.expectEqual(0.5 * x0, got[(2 * link + i) * 3 + 2]);
    }
    try dec.seek(link + 100);
    var buf: [3]f32 = undefined;
    try testing.expectEqual(@as(usize, 1), try dec.read(&buf));
    try testing.expectEqual(0.25 * data.column(1, 100), buf[0]);
}

test "family 3 streams that do not decode are concealed and the output stays finite" {
    const gpa = testing.allocator;
    const data = try makeAmbisonic(gpa, 2, 1, 10);
    defer data.deinit(gpa);
    const matrix = try matrixBytes(gpa, &.{ q15(0.5), 0, 0, 0, q15(0.5), 0, 0, 0, q15(0.5) });
    defer gpa.free(matrix);
    const h = headFor3(3, 2, 1, matrix);
    const audio = try constSlices(gpa, data.joined);
    defer gpa.free(audio);
    audio[4] = audio[4][0..2];
    const bytes = try buildStream(gpa, &h, audio, 0);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const got = try helpers.readAll(gpa, &dec, 500);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 10 * 960 * 3), got.len);
    try testing.expectEqual(@as(u32, 1), dec.stats().resyncs);
    try expectUnit(got);
}

test "random packets and damaged headers of the ambisonic families give errors or finite samples" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x8486);
    const random = prng.random();
    const matrix_values = [_]i16{ 32767, -32768, 0, 12345, -4000, 7, 16384, -16384, 1, -1, 30000, -30000 };
    for (0..200) |round| {
        const family: u8 = if (round % 2 == 0) 2 else 3;
        const counts = [_]u8{ 1, 3, 4, 6, 9 };
        const channels: u8 = counts[random.uintLessThan(usize, counts.len)];
        const streams: u8 = 1 + random.uintLessThan(u8, 4);
        const coupled: u8 = random.uintLessThan(u8, streams + 1);
        const columns = @as(usize, streams) + coupled;
        const values = try gpa.alloc(i16, columns * channels);
        defer gpa.free(values);
        for (values) |*v| v.* = matrix_values[random.uintLessThan(usize, matrix_values.len)];
        const matrix = try matrixBytes(gpa, values);
        defer gpa.free(matrix);
        var table: [255]u8 = undefined;
        for (table[0..channels]) |*e| e.* = if (random.uintLessThan(u8, 6) == 0) head_file.silent else random.uintLessThan(u8, @intCast(columns));
        const h = if (family == 3) headFor3(channels, streams, coupled, matrix) else headFor(channels, 2, streams, coupled, table[0..channels]);
        const count = 1 + random.uintLessThan(usize, 4);
        const audio = try gpa.alloc([]u8, count);
        defer gpa.free(audio);
        var owned: usize = 0;
        defer for (audio[0..owned]) |a| gpa.free(a);
        for (audio) |*a| {
            var parts: std.ArrayList(u8) = .empty;
            defer parts.deinit(gpa);
            for (0..streams) |s| {
                const body = try gpa.alloc(u8, 1 + random.uintLessThan(usize, 80));
                defer gpa.free(body);
                random.bytes(body);
                body[0] = if (random.boolean()) 0xf8 | (body[0] & 3) else body[0];
                if (s + 1 < streams) {
                    const d = selfDelimit(gpa, body) catch continue;
                    defer gpa.free(d);
                    try parts.appendSlice(gpa, d);
                } else try parts.appendSlice(gpa, body);
            }
            a.* = try parts.toOwnedSlice(gpa);
            owned += 1;
        }
        var as_const: [4][]const u8 = undefined;
        for (audio, 0..) |a, i| as_const[i] = a;
        const bytes = try buildStream(gpa, &h, as_const[0..count], 0);
        defer gpa.free(bytes);
        var input: io.Input = .init(.{ .bytes = bytes });
        var dec = Decoder.init(gpa, &input) catch |err| {
            try testing.expect(err == error.BadHeader or err == error.Unsupported or err == error.Truncated);
            continue;
        };
        defer dec.deinit();
        const got = helpers.readAll(gpa, &dec, 500) catch continue;
        defer gpa.free(got);
        try expectUnit(got);
    }
}
