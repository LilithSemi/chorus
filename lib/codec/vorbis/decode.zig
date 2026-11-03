//! Ogg Vorbis decoding. The packets of one link go through the floors, the residues, the
//! channel coupling, the inverse MDCT and the overlap add. `ogg_chain.Chain` plays the links
//! of a chained file as one stream.
//!
//! The output channels are in WAVE order for 1 to 8 channels, and `Info.mask` tells the
//! speaker positions. A stream with more channels keeps the order of the stream and has an
//! empty mask.
//!
//! The page granules set the length. The last page cuts the samples that the last block adds
//! past its granule. A first audio page with a granule below its sample count cuts the start.
//! A first audio page with a granule above its sample count means that the stream starts at
//! that time, and the first returned sample is still frame 0.
const std = @import("std");
const codec = @import("../../codec.zig");
const io = @import("../io.zig");
const packets = @import("../ogg.zig");
const ogg_chain = @import("../ogg_chain.zig");
const pcm = @import("../pcm.zig");
const helpers = @import("../testing.zig");
const vt = @import("testing.zig");
const header = @import("header.zig");
const floor = @import("floor.zig");
const residue = @import("residue.zig");
const mdct = @import("mdct.zig");
const window = @import("window.zig");
const testing = std.testing;

pub const Options = struct {
    /// A packet that fails to decode is skipped and counted in `Stats.resyncs`, or it gives
    /// error.BadData.
    on_bad_packet: enum { resync, fail } = .resync,
    /// The most bytes that parsing one setup header may ask the allocator for. It applies to
    /// each of the two setup slots, so the setup headers can hold twice this much. The other
    /// memory of a decoder depends on the identification header. The worst case is about 25 MB
    /// of work buffers (255 channels, 8192 sample blocks) and 8 MB of packet buffer.
    max_setup_bytes: usize = 16 << 20,
};

pub const Stats = struct {
    /// Packets that failed to decode and were skipped by `read`. A seek does not count the
    /// packets it skips. The overlap with the packet before is lost for each of them.
    resyncs: u32 = 0,
};

/// The limit for the header packets, which can hold pictures.
const header_packet_limit = 1 << 22;
/// The block sizes 64 to 8192 are the powers of two from 6 to 13.
const max_exponents = 8;
const max_floors = 64;

pub fn isIdentification(context: ?*anyopaque, packet: []const u8) bool {
    _ = context;
    return packet.len >= 7 and packet[0] == 1 and std.mem.eql(u8, packet[1..7], "vorbis");
}

/// The WAVE position of the channel `c` of a stream with `channels` channels.
pub fn waveChannel(channels: usize, c: usize) usize {
    const table: []const u8 = switch (channels) {
        3 => &.{ 0, 2, 1 },
        5 => &.{ 0, 2, 1, 3, 4 },
        6 => &.{ 0, 2, 1, 4, 5, 3 },
        7 => &.{ 0, 2, 1, 5, 6, 4, 3 },
        8 => &.{ 0, 2, 1, 6, 7, 4, 5, 3 },
        else => return c,
    };
    return table[c];
}

/// The WAVE speaker mask of a channel count, or 0 for the counts that have no layout.
pub fn channelMask(channels: u8) u32 {
    return switch (channels) {
        1 => 0x4,
        2 => 0x3,
        3 => 0x7,
        4 => 0x33,
        5 => 0x37,
        6 => 0x3f,
        7 => 0x70f,
        8 => 0x63f,
        else => 0,
    };
}

/// Undoes one coupling step on two spectrum vectors.
fn uncouple(mag: []f32, ang: []f32) void {
    std.debug.assert(mag.len == ang.len);
    for (mag, ang) |*m, *a| {
        const mv = m.*;
        const av = a.*;
        if (mv > 0) {
            if (av > 0) {
                a.* = mv - av;
            } else {
                a.* = mv;
                m.* = mv + av;
            }
        } else {
            if (av > 0) {
                a.* = mv + av;
            } else {
                a.* = mv;
                m.* = mv - av;
            }
        }
    }
}

/// A coupled channel needs its residue when its partner has a floor.
fn propagate(coupling: []const header.Coupling, no_residue: []bool) void {
    for (coupling) |step| {
        if (!no_residue[step.magnitude] or !no_residue[step.angle]) {
            no_residue[step.magnitude] = false;
            no_residue[step.angle] = false;
        }
    }
}

/// Hands out aligned parts of one buffer. With the base address 16 it only counts, and the
/// pointers it makes are never used.
const Carve = struct {
    base: usize,
    offset: usize = 0,

    fn take(self: *Carve, comptime T: type, n: usize) []T {
        const start = std.mem.alignForward(usize, self.offset, @alignOf(T));
        self.offset = start + n * @sizeOf(T);
        if (n == 0) return &.{};
        const ptr: [*]T = @ptrFromInt(self.base + start);
        return ptr[0..n];
    }
};

/// The buffers of a link. A channel has `long` samples in a block buffer, `half` lines in
/// `spec`, `points` entries in the floor 1 arrays and `order` entries in `coeffs`.
const Run = struct {
    long: usize = 0,
    points: usize = 0,
    order: usize = 0,
    /// The inverse transform of the current and of the previous block.
    blocks: [2][]f32 = .{ &.{}, &.{} },
    spec: []f32 = &.{},
    vecs: [][]f32 = &.{},
    curve: []f32 = &.{},
    ola: []f32 = &.{},
    win: []f32 = &.{},
    out: []f32 = &.{},
    final_y: []i32 = &.{},
    step2: []bool = &.{},
    coeffs: []f64 = &.{},
    amplitude: []u32 = &.{},
    floor_used: []bool = &.{},
    no_residue: []bool = &.{},
    bundle: []u8 = &.{},
    scratch_vec: []f32 = &.{},
    classes: []u8 = &.{},
    bark_short: []i32 = &.{},
    bark_long: []i32 = &.{},
};

fn layout(c: *Carve, ident: header.Identification, setup: *const header.Setup) Run {
    const channels: usize = ident.channels;
    const long: usize = ident.blocksize_1;
    const half = long / 2;
    const fs = floor.scratch(setup);
    const rs = residue.scratch(setup, half);
    var zero_floors: usize = 0;
    for (setup.floors) |f| zero_floors += @intFromBool(f == .zero);
    return .{
        .long = long,
        .points = fs.points,
        .order = fs.coeffs,
        .blocks = .{ c.take(f32, channels * long), c.take(f32, channels * long) },
        .spec = c.take(f32, channels * half),
        .vecs = c.take([]f32, channels),
        .curve = c.take(f32, half),
        .ola = c.take(f32, half),
        .win = c.take(f32, long),
        .out = c.take(f32, channels * half),
        .final_y = c.take(i32, channels * fs.points),
        .step2 = c.take(bool, channels * fs.points),
        .coeffs = c.take(f64, channels * fs.coeffs),
        .amplitude = c.take(u32, channels),
        .floor_used = c.take(bool, channels),
        .no_residue = c.take(bool, channels),
        .bundle = c.take(u8, channels),
        .scratch_vec = c.take(f32, @max(fs.vec, rs.vec)),
        .classes = c.take(u8, rs.classes),
        .bark_short = c.take(i32, zero_floors * (ident.blocksize_0 / 2 + 1)),
        .bark_long = c.take(i32, zero_floors * (half + 1)),
    };
}

/// The most bytes that an audio packet can have in a link. A bigger packet gives error.BadData.
fn audioBound(ident: header.Identification) usize {
    const lines = @as(usize, ident.blocksize_1) / 2 * ident.channels;
    return @min(16 << 20, lines * 8 + 4096);
}

const LinkHeaders = struct {
    ident: header.Identification,
    setup: header.Setup,
    /// The slot of the codec that holds the memory of `setup`.
    slot: u1,
    /// The bytes of the slot that `setup` uses.
    slot_bytes: usize,
    /// The first audio packet, or the first packet of the next link when the link has none.
    held: ?packets.Packet,
    /// The size of the biggest packet that the read took.
    biggest: usize,
};

const PacketError = error{BadPacket};

/// The part of an audio packet before the floors.
const Head = struct { mode: header.Mode, bits: io.LsbReader };

/// The number of block sizes of the frames that a stream returns, and how the page granules
/// cut or fill them. The decoder and the measure of the start time use the same code, so they
/// agree on the frame count.
const Account = struct {
    have_prev: bool = false,
    prev_n: usize = 0,
    sample_count: i64 = 0,
    granulepos: ?i64 = null,
    /// The frames returned so far.
    emitted: i64 = 0,
    /// A packet or a page was lost since the last granule.
    lost: bool = false,

    const Step = struct { produced: usize, cut_start: usize = 0, cut_end: usize = 0, gap: usize = 0 };

    /// A packet was lost. The next block only primes the overlap, and the next granule can
    /// fill the frames that are missing.
    fn skip(self: *Account) void {
        self.have_prev = false;
        self.lost = true;
    }

    /// Notes the first packet after lost pages, which the reader marks.
    fn page(self: *Account, after_gap: bool) void {
        if (after_gap) self.skip();
    }
    fn cut(extra: i64, produced: usize) usize {
        return @min(std.math.cast(usize, extra) orelse std.math.maxInt(usize), produced);
    }

    /// Counts a block of size `n`. A gap is the silence that fills a granule which is ahead of
    /// the counted position by at most `max_gap` frames after a loss. Without a loss the
    /// granule is believed and nothing is added.
    fn block(self: *Account, n: usize, granule: i64, eos: bool, max_gap: usize) Step {
        const produced: usize = if (self.have_prev) self.prev_n / 4 + n / 4 else 0;
        self.have_prev = true;
        self.prev_n = n;
        var step: Step = .{ .produced = produced };
        const made: i64 = @intCast(produced);
        self.sample_count +|= made;
        if (self.granulepos) |*position| {
            position.* +|= made;
            if (granule != -1 and position.* != granule) {
                if (position.* > granule) {
                    if (eos) step.cut_end = cut(position.* -| granule, produced);
                } else if (self.lost and granule -| position.* <= max_gap) {
                    step.gap = @intCast(granule -| position.*);
                }
                position.* = granule;
            }
        } else if (granule != -1) {
            self.granulepos = granule;
            if (self.sample_count > granule) {
                const extra = cut(self.sample_count -| granule, produced);
                if (eos) step.cut_end = extra else step.cut_start = extra;
            }
        }
        if (granule != -1) self.lost = false;
        self.emitted +|= @intCast(step.gap + produced - step.cut_start - step.cut_end);
        return step;
    }
};

/// The size of the block of an audio packet, or null when the packet does not decode.
fn blockSizeOf(setup: *const header.Setup, ident: header.Identification, data: []const u8) ?usize {
    const head = readHeadOf(setup, data) catch return null;
    return if (head.mode.long) ident.blocksize_1 else ident.blocksize_0;
}

fn readHeadOf(setup: *const header.Setup, data: []const u8) PacketError!Head {
    var bits: io.LsbReader = .init(data);
    if (bits.readBit() catch return error.BadPacket) return error.BadPacket;
    const index = bits.readBits(setup.modeBits()) catch return error.BadPacket;
    if (index >= setup.modes.len) return error.BadPacket;
    const mode = setup.modes[index];
    if (mode.long) _ = bits.readBits(2) catch return error.BadPacket;
    return .{ .mode = mode, .bits = bits };
}

/// The Vorbis part of a chained Ogg decoder. `ogg_chain.Chain` calls it for each link.
const VorbisCodec = struct {
    gpa: std.mem.Allocator,
    options: Options,
    /// The memory of two parsed setup headers: the current link and the one that is read.
    slots: [2][]align(16) u8 = .{ &.{}, &.{} },
    cur_slot: ?u1 = null,
    /// The biggest `LinkHeaders.slot_bytes` seen. Both slots have this size once a link is entered.
    slot_target: usize = 0,
    mdcts: [max_exponents]?mdct.Mdct = @splat(null),
    slopes: [max_exponents]?[]f32 = @splat(null),
    work: []align(16) u8 = &.{},
    run: Run = .{},

    ident: header.Identification = undefined,
    setup: header.Setup = undefined,
    windows: window.Windows = undefined,
    bark_ord: [max_floors]u8 = @splat(0),

    /// The frame count and the granule position of the stream.
    acct: Account = .{},
    prev_long: bool = false,
    /// The block buffer of the current block. The other one holds the previous block.
    which: u1 = 0,
    /// The silent frames that `read` gives before the frames of the last block, and the
    /// frames of the last block that it has not taken.
    gap: usize = 0,
    pend_pos: usize = 0,
    pend_end: usize = 0,
    /// The time of the first returned frame in granule units, once it is known.
    start: ?i64 = null,
    failed: ?ogg_chain.FrameError = null,
    at_end: bool = false,
    resyncs: u32 = 0,
    /// Seeks that found granules that disagree with the frames and decoded from the start.
    rescans: u32 = 0,
    /// A seek is running, and its skipped packets are not counted.
    seeking: bool = false,
    /// The reader dropped packets since the last packet that decoded.
    bad_run: bool = false,

    pub const Headers = LinkHeaders;
    pub const max_header_packet = header_packet_limit;
    pub const isFirst = isIdentification;

    fn nextHeader(reader: *packets.PacketReader) codec.InitError!packets.Packet {
        const p = (reader.next() catch |err| return ogg_chain.initError(err)) orelse return error.Truncated;
        if (p.bos) return error.Truncated;
        return p;
    }

    /// Parses `packet` into `slot`, and makes the slot bigger when it is too small.
    fn parseSetup(self: *VorbisCodec, slot: u1, packet: []const u8, channels: u8) codec.InitError!struct { setup: header.Setup, bytes: usize } {
        var grown = false;
        while (true) {
            var fba: std.heap.FixedBufferAllocator = .init(self.slots[slot]);
            if (header.Setup.parse(fba.allocator(), packet, channels, self.options.max_setup_bytes)) |setup| {
                return .{ .setup = setup, .bytes = fba.end_index };
            } else |err| switch (err) {
                error.BadHeader => return error.BadHeader,
                error.OutOfMemory => if (grown) return error.OutOfMemory,
            }
            const need = try header.Setup.measure(self.gpa, packet, channels, self.options.max_setup_bytes);
            self.gpa.free(self.slots[slot]);
            self.slots[slot] = &.{};
            self.slots[slot] = try self.gpa.alignedAlloc(u8, .@"16", need);
            grown = true;
        }
    }

    pub fn readHeaders(self: *VorbisCodec, reader: *packets.PacketReader, first: []const u8) codec.InitError!LinkHeaders {
        const ident = header.parseIdentification(first) catch return error.BadHeader;
        var biggest = first.len;

        const comment = try nextHeader(reader);
        biggest = @max(biggest, comment.data.len);
        _ = header.parseComment(comment.data) catch return error.BadHeader;

        const setup_packet = try nextHeader(reader);
        biggest = @max(biggest, setup_packet.data.len);
        const slot: u1 = if (self.cur_slot) |s| 1 - s else 0;
        const parsed = try self.parseSetup(slot, setup_packet.data, ident.channels);

        var held: ?packets.Packet = null;
        if (reader.next() catch |err| return ogg_chain.initError(err)) |p| {
            biggest = @max(biggest, p.data.len);
            held = p;
            if (!p.bos) reader.markAudio(p);
        }
        return .{
            .ident = ident,
            .setup = parsed.setup,
            .slot = slot,
            .slot_bytes = parsed.bytes,
            .held = held,
            .biggest = biggest,
        };
    }

    /// The slots belong to the codec, so there is nothing to give back.
    pub fn releaseHeaders(self: *VorbisCodec, h: *LinkHeaders) void {
        _ = self;
        _ = h;
    }

    pub fn deinit(self: *VorbisCodec) void {
        for (&self.slots) |*s| self.gpa.free(s.*);
        self.gpa.free(self.work);
        for (&self.mdcts) |*m| if (m.*) |*table| table.deinit(self.gpa);
        for (self.slopes) |s| if (s) |slope| self.gpa.free(slope);
        self.* = undefined;
    }

    fn exponent(n: usize) usize {
        return @as(usize, std.math.log2_int(usize, n)) - 6;
    }

    fn reserveTables(self: *VorbisCodec, ident: header.Identification) error{OutOfMemory}!void {
        for ([_]usize{ ident.blocksize_0, ident.blocksize_1 }) |n| {
            const e = exponent(n);
            if (self.mdcts[e] == null) {
                self.mdcts[e] = mdct.Mdct.init(self.gpa, n) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // The identification header limits the block sizes to the supported ones.
                    error.BadSize => unreachable,
                };
            }
            if (self.slopes[e] == null) {
                const slope = try self.gpa.alloc(f32, n / 2);
                window.slope(slope);
                self.slopes[e] = slope;
            }
        }
    }

    fn reserveWork(self: *VorbisCodec, ident: header.Identification, setup: *const header.Setup) error{OutOfMemory}!void {
        var count: Carve = .{ .base = 16 };
        _ = layout(&count, ident, setup);
        if (self.work.len >= count.offset) return;
        self.run = .{};
        self.pend_pos = 0;
        self.pend_end = 0;
        self.acct.have_prev = false;
        self.gap = 0;
        self.gpa.free(self.work);
        self.work = &.{};
        self.work = try self.gpa.alignedAlloc(u8, .@"16", count.offset);
    }

    pub fn reserve(self: *VorbisCodec, h: *const LinkHeaders) codec.InitError!usize {
        self.slot_target = @max(self.slot_target, h.slot_bytes);
        try self.reserveTables(h.ident);
        try self.reserveWork(h.ident, &h.setup);
        return audioBound(h.ident);
    }

    pub fn enter(self: *VorbisCodec, h: *LinkHeaders) codec.InitError!usize {
        try self.reserveTables(h.ident);
        try self.reserveWork(h.ident, &h.setup);
        self.slot_target = @max(self.slot_target, h.slot_bytes);
        self.ident = h.ident;
        self.setup = h.setup;
        self.cur_slot = h.slot;
        std.debug.assert(self.setup.floors.len <= max_floors);

        var carve: Carve = .{ .base = @intFromPtr(self.work.ptr) };
        const run = layout(&carve, self.ident, &self.setup);
        self.run = run;
        for (run.vecs) |*v| v.* = &.{};
        const short_lines = self.ident.blocksize_0 / 2 + 1;
        const long_lines = self.ident.blocksize_1 / 2 + 1;
        var ord: usize = 0;
        for (self.setup.floors, 0..) |f, i| switch (f) {
            .zero => |z| {
                self.bark_ord[i] = @intCast(ord);
                floor.barkMap(z, run.bark_short[ord * short_lines ..][0..short_lines]);
                floor.barkMap(z, run.bark_long[ord * long_lines ..][0..long_lines]);
                ord += 1;
            },
            .one => {},
        };
        self.windows = .{
            .bs0 = self.ident.blocksize_0,
            .bs1 = self.ident.blocksize_1,
            .short = self.slopes[exponent(self.ident.blocksize_0)].?,
            .long = self.slopes[exponent(self.ident.blocksize_1)].?,
        };
        self.resetStream();
        self.start = null;
        self.at_end = false;

        const other = 1 - h.slot;
        if (self.slots[other].len < self.slot_target) {
            self.gpa.free(self.slots[other]);
            self.slots[other] = &.{};
            self.slots[other] = try self.gpa.alignedAlloc(u8, .@"16", self.slot_target);
        }
        return audioBound(self.ident);
    }

    pub fn settle(self: *VorbisCodec, first: ?packets.Packet) bool {
        _ = self;
        return if (first) |p| !p.bos else false;
    }

    pub fn sameShape(self: *const VorbisCodec, h: *const LinkHeaders) bool {
        return h.ident.rate == self.ident.rate and h.ident.channels == self.ident.channels;
    }

    pub fn info(self: *const VorbisCodec) codec.Info {
        return .{
            .rate = self.ident.rate,
            .channels = self.ident.channels,
            .mask = @bitCast(channelMask(self.ident.channels)),
        };
    }

    pub fn canLoad(self: *const VorbisCodec) ogg_chain.FrameError!bool {
        if (self.failed) |err| return err;
        return !self.at_end;
    }

    pub fn fail(self: *VorbisCodec, err: ogg_chain.FrameError) void {
        self.failed = err;
    }

    /// Forgets the previous block and the position, so that the next packet only primes the
    /// overlap.
    fn resetStream(self: *VorbisCodec) void {
        self.acct = .{};
        self.gap = 0;
        self.pend_pos = 0;
        self.pend_end = 0;
    }

    /// Drops a lost packet. The position stays, so that the next granule can fill the gap.
    fn lostPacket(self: *VorbisCodec) void {
        self.acct.skip();
        self.gap = 0;
        self.pend_pos = 0;
        self.pend_end = 0;
    }

    fn readHead(self: *const VorbisCodec, data: []const u8) PacketError!Head {
        return readHeadOf(&self.setup, data);
    }

    fn barkFor(self: *const VorbisCodec, floor_index: usize, long: bool) []const i32 {
        const ord: usize = self.bark_ord[floor_index];
        const lines = (if (long) self.ident.blocksize_1 else self.ident.blocksize_0) / 2 + 1;
        const all = if (long) self.run.bark_long else self.run.bark_short;
        return all[ord * lines ..][0..lines];
    }

    /// Decodes one audio packet. The frames it gives are in `run.out[pend_pos .. pend_end]`.
    fn decodeInto(self: *VorbisCodec, data: []const u8, granule: i64, eos: bool) PacketError!void {
        const setup = &self.setup;
        const run = &self.run;
        const channels: usize = setup.channels;
        const head = try self.readHead(data);
        var bits = head.bits;
        const mode = head.mode;
        const n: usize = if (mode.long) self.ident.blocksize_1 else self.ident.blocksize_0;
        const half = n / 2;
        const long = run.long;
        const mapping = setup.mappings[mode.mapping];

        for (0..channels) |c| {
            const sub = mapping.submaps[mapping.mux[c]];
            const used = switch (setup.floors[sub.floor]) {
                .one => |f| floor.decodeFloor1(
                    f,
                    setup.books,
                    &bits,
                    run.final_y[c * run.points ..][0..run.points],
                    run.step2[c * run.points ..][0..run.points],
                ),
                .zero => |f| blk: {
                    const amplitude = floor.decodeFloor0(
                        f,
                        setup.books,
                        &bits,
                        run.coeffs[c * run.order ..][0..run.order],
                        run.scratch_vec,
                    ) orelse break :blk false;
                    run.amplitude[c] = amplitude;
                    break :blk true;
                },
            };
            run.floor_used[c] = used;
            run.no_residue[c] = !used;
        }
        propagate(mapping.coupling, run.no_residue);

        for (0..channels) |c| {
            const vec = run.spec[c * (long / 2) ..][0..half];
            @memset(vec, 0);
            run.vecs[c] = vec;
        }
        for (mapping.submaps, 0..) |sub, s| {
            var count: usize = 0;
            for (0..channels) |c| {
                if (mapping.mux[c] != s) continue;
                run.bundle[count] = @intCast(c);
                count += 1;
            }
            residue.decode(
                setup.residues[sub.residue],
                setup.books,
                &bits,
                half,
                run.vecs,
                run.bundle[0..count],
                run.no_residue,
                run.classes,
                run.scratch_vec,
            );
        }
        var step = mapping.coupling.len;
        while (step > 0) {
            step -= 1;
            const pair = mapping.coupling[step];
            uncouple(run.vecs[pair.magnitude], run.vecs[pair.angle]);
        }

        const table = &self.mdcts[exponent(n)].?;
        const cur = run.blocks[self.which];
        const curve = run.curve[0..half];
        for (0..channels) |c| {
            const block = cur[c * long ..][0..n];
            if (!run.floor_used[c]) {
                @memset(block, 0);
                continue;
            }
            const sub = mapping.submaps[mapping.mux[c]];
            switch (setup.floors[sub.floor]) {
                .one => |f| floor.floor1Curve(
                    f,
                    run.final_y[c * run.points ..][0..run.points],
                    run.step2[c * run.points ..][0..run.points],
                    curve,
                ),
                .zero => |f| floor.floor0Curve(
                    f,
                    self.barkFor(sub.floor, mode.long),
                    run.amplitude[c],
                    run.coeffs[c * run.order ..][0..run.order],
                    curve,
                ),
            }
            for (run.vecs[c], curve) |*line, level| line.* *= level;
            table.inverse(run.vecs[c], block);
        }

        var produced: usize = 0;
        if (self.acct.have_prev) {
            const prev = run.blocks[1 - self.which];
            const prev_n = self.acct.prev_n;
            self.windows.fill(run.win[0..prev_n], self.prev_long, true, mode.long);
            for (0..channels) |c| {
                const tail = prev[c * long ..][prev_n / 2 .. prev_n];
                for (tail, run.win[prev_n / 2 .. prev_n]) |*v, w| v.* *= w;
            }
            self.windows.fill(run.win[0..n], mode.long, self.prev_long, true);
            for (0..channels) |c| {
                const front = cur[c * long ..][0..half];
                for (front, run.win[0..half]) |*v, w| v.* *= w;
            }
            for (0..channels) |c| {
                produced = window.overlapAdd(prev[c * long ..][0..prev_n], cur[c * long ..][0..n], run.ola);
                const dst = waveChannel(channels, c);
                for (run.ola[0..produced], 0..) |v, i| run.out[i * channels + dst] = pcm.clampUnit(v);
            }
        }
        const counted = self.acct.block(n, granule, eos, 2 * @as(usize, self.ident.blocksize_1));
        std.debug.assert(counted.produced == produced);
        self.prev_long = mode.long;
        self.which = 1 - self.which;
        self.gap = counted.gap;
        self.pend_pos = counted.cut_start;
        self.pend_end = produced - counted.cut_end;
    }

    pub fn decode(self: *VorbisCodec, packet: packets.Packet) ogg_chain.FrameError!bool {
        self.bad_run = false;
        self.acct.page(packet.after_gap);
        self.decodeInto(packet.data, packet.granule, packet.eos) catch |err| switch (err) {
            error.BadPacket => switch (self.options.on_bad_packet) {
                .resync => {
                    self.resyncs +|= 1;
                    self.lostPacket();
                    return false;
                },
                .fail => {
                    self.failed = error.BadData;
                    return error.BadData;
                },
            },
        };
        return true;
    }

    /// The reader dropped a packet that is bigger than the limit. It counts like a packet that
    /// does not decode.
    pub fn skipBad(self: *VorbisCodec) bool {
        if (self.options.on_bad_packet != .resync) return false;
        if (!self.seeking and !self.bad_run) self.resyncs +|= 1;
        self.bad_run = true;
        self.lostPacket();
        return true;
    }

    pub fn endOfData(self: *VorbisCodec) ogg_chain.FrameError!bool {
        self.at_end = true;
        return false;
    }

    /// Stops the reads until the next link is entered.
    pub fn endLink(self: *VorbisCodec) ogg_chain.FrameError!void {
        self.at_end = true;
    }

    pub fn read(self: *VorbisCodec, comptime T: type, out: []T, loader: anytype) ogg_chain.FrameError!usize {
        comptime std.debug.assert(T == f32);
        const channels: usize = self.ident.channels;
        std.debug.assert(out.len >= channels);
        const want = out.len / channels;
        var done: usize = 0;
        while (done < want) {
            if (self.gap > 0) {
                const take = @min(want - done, self.gap);
                @memset(out[done * channels ..][0 .. take * channels], 0);
                done += take;
                self.gap -= take;
                continue;
            }
            if (self.pend_pos == self.pend_end) {
                const more = loader.loadBlock() catch |err| {
                    if (done > 0) return done;
                    return err;
                };
                if (!more) break;
                continue;
            }
            const take = @min(want - done, self.pend_end - self.pend_pos);
            @memcpy(out[done * channels ..][0 .. take * channels], self.run.out[self.pend_pos * channels ..][0 .. take * channels]);
            done += take;
            self.pend_pos += take;
        }
        return done;
    }

    pub fn beginSeek(self: *VorbisCodec) void {
        self.resetStream();
        self.failed = null;
        self.at_end = false;
    }

    pub fn clearPosition(self: *VorbisCodec) void {
        self.resetStream();
    }

    pub fn linkTotal(self: *const VorbisCodec) ?u64 {
        _ = self;
        return null;
    }

    pub fn seekEnd(self: *VorbisCodec, frames: u64) void {
        _ = frames;
        self.resetStream();
        self.at_end = true;
    }

    pub fn failSeek(self: *VorbisCodec, err: ogg_chain.FrameError) void {
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

    /// The time of the first returned frame: the granule of the first audio page less the
    /// frames that `read` returns up to its packet. It is below 0 when a start cut is longer
    /// than its packet. `first` is the first audio packet, and the reader follows it. Null when
    /// the packets cannot be read.
    fn measureStart(self: *const VorbisCodec, setup: *const header.Setup, ident: header.Identification, first: ?packets.Packet, reader: *packets.PacketReader) ?i64 {
        var acct: Account = .{};
        var next = first;
        while (next) |p| {
            if (p.bos) break;
            acct.page(p.after_gap);
            if (blockSizeOf(setup, ident, p.data)) |n| {
                _ = acct.block(n, p.granule, p.eos, 2 * @as(usize, ident.blocksize_1));
                if (p.granule != -1) return p.granule -| acct.emitted;
            } else acct.skip();
            next = while (true) {
                break reader.next() catch |err| {
                    if (err == error.BadData and self.options.on_bad_packet == .resync) {
                        acct.skip();
                        continue;
                    }
                    return null;
                };
            };
        }
        return 0;
    }

    /// The last granule less the start time. It is a hint because a damaged stream can have
    /// granules that do not match its frames.
    pub fn linkLength(self: *VorbisCodec, h: *const LinkHeaders, link: *const packets.Link, reader: *packets.PacketReader) ?ogg_chain.Length {
        const last = link.last_granule orelse return null;
        const start = self.measureStart(&h.setup, h.ident, h.held, reader) orelse return null;
        return .{ .frames = if (last > start) @intCast(last - start) else 0, .trusted = false, .start = start };
    }

    /// The start time of the current link, from the table of the chain or from its first page.
    fn startOffset(self: *VorbisCodec, chain: anytype) codec.SeekError!i64 {
        if (self.start) |s| return s;
        if (chain.linkStart()) |s| {
            self.start = s;
            return s;
        }
        try restart(chain);
        const first = switch (try chain.nextData()) {
            .frame => |p| p,
            .link, .end => return 0,
        };
        const s = self.measureStart(&self.setup, self.ident, first, &chain.reader) orelse return error.BadData;
        self.start = s;
        return s;
    }

    /// A packet that does not decode during a seek. It is lost like in a read.
    fn lostInSeek(self: *VorbisCodec) codec.SeekError!void {
        if (self.options.on_bad_packet != .resync) return error.BadData;
        self.lostPacket();
    }

    fn pageSearchFailed(self: *VorbisCodec) ?u64 {
        self.rescans +|= 1;
        return null;
    }

    /// Moves to the page before the one with the last granule at or before `target` and reads
    /// up to the packet that holds that granule. That packet primes the overlap, and the next
    /// packet gives the frame at the granule. Returns that frame, or null when the reader has
    /// to start at the first audio packet.
    fn positionAt(self: *VorbisCodec, chain: anytype, target: i64, offset: i64) codec.SeekError!?u64 {
        chain.held = null;
        // Granules that run backward make the page search fail. The seek then decodes from
        // the start, like for a granule that disagrees with the frames.
        const found = seekPage(chain, target) catch |err| switch (err) {
            error.BadData => return self.pageSearchFailed(),
            else => |e| return e,
        };
        const granule = found orelse return null;
        const frame = std.math.sub(i64, granule, offset) catch return null;
        if (granule < 0 or frame < 0) return null;
        _ = seekPage(chain, granule - 1) catch |err| switch (err) {
            error.BadData => return self.pageSearchFailed(),
            else => |e| return e,
        };
        while (true) {
            const p = switch (try chain.nextData()) {
                .frame => |p| p,
                .link => |p| {
                    chain.held = p;
                    return null;
                },
                .end => return null,
            };
            if (p.granule != granule) continue;
            self.acct.page(p.after_gap);
            self.decodeInto(p.data, p.granule, p.eos) catch {
                try self.lostInSeek();
                return null;
            };
            return @intCast(frame);
        }
    }

    const Walk = error{Mismatch};

    /// Decodes forward from the frame `from` to the frame `local`. With `check`, a page granule
    /// that disagrees with the frame count gives error.Mismatch.
    fn walk(self: *VorbisCodec, chain: anytype, local: u64, from: u64, offset: i64, check: bool) (codec.SeekError || Walk)!void {
        var pos = from;
        while (true) {
            const p = switch (try chain.nextData()) {
                .frame => |p| p,
                .link => |p| {
                    chain.held = p;
                    return self.walkEnd(pos, local);
                },
                .end => return self.walkEnd(pos, local),
            };
            self.acct.page(p.after_gap);
            self.decodeInto(p.data, p.granule, p.eos) catch {
                try self.lostInSeek();
                continue;
            };
            const frames: u64 = self.gap + (self.pend_end - self.pend_pos);
            if (check and p.granule != -1) {
                const want = std.math.sub(i64, p.granule, offset) catch return error.Mismatch;
                if (want < 0 or @as(u64, @intCast(want)) != pos + frames) return error.Mismatch;
            }
            if (local < pos) return error.Mismatch;
            if (local - pos < frames) {
                var skip: usize = @intCast(local - pos);
                const silent = @min(skip, self.gap);
                self.gap -= silent;
                skip -= silent;
                self.pend_pos += skip;
                return;
            }
            pos += frames;
            self.gap = 0;
            self.pend_pos = self.pend_end;
        }
    }

    fn walkEnd(self: *VorbisCodec, pos: u64, local: u64) codec.SeekError!void {
        if (pos != local) return error.Truncated;
        self.gap = 0;
        self.pend_pos = 0;
        self.pend_end = 0;
    }

    pub fn seekIn(self: *VorbisCodec, chain: anytype, local: u64) codec.SeekError!void {
        self.seeking = true;
        defer self.seeking = false;
        const offset = try self.startOffset(chain);
        const wide = std.math.add(i64, std.math.cast(i64, local) orelse return error.Truncated, offset) catch return error.Truncated;
        self.resetStream();
        if (try self.positionAt(chain, wide, offset)) |from| {
            if (self.walk(chain, local, from, offset, true)) |_| return else |err| switch (err) {
                error.Mismatch => self.rescans +|= 1,
                else => |e| return e,
            }
        }
        // The granules and the frames disagree, or the target is before the first granule.
        try restart(chain);
        self.resetStream();
        self.walk(chain, local, 0, offset, false) catch |err| switch (err) {
            error.Mismatch => return error.BadData,
            else => |e| return e,
        };
    }
};

const VorbisChain = ogg_chain.Chain(VorbisCodec);

/// Reads Ogg Vorbis. All the links of a chained file play as one stream. The frame positions
/// of `seek` count from the start of the first link. A link with the same rate and channel
/// count as the one before it continues without a signal. When the format changes, `read`
/// gives error.StreamChanged after the frames of the old link, and the next `read` continues
/// with the first frame of the new link.
pub const Decoder = struct {
    chain: VorbisChain,

    pub fn init(gpa: std.mem.Allocator, input: *io.Input) codec.InitError!Decoder {
        return initOptions(gpa, input, .{});
    }

    pub fn initOptions(gpa: std.mem.Allocator, input: *io.Input, options: Options) codec.InitError!Decoder {
        var reader = try packets.PacketReader.init(
            gpa,
            input,
            .{ .accept = .{ .func = isIdentification } },
            .{ .max_packet_size = header_packet_limit },
        );
        const first = blk: {
            errdefer reader.deinit();
            break :blk (reader.next() catch |err| return ogg_chain.initError(err)) orelse return error.Unsupported;
        };
        return initReader(gpa, input, reader, first.data, options);
    }

    /// Makes a decoder from a reader that has returned `first`, the identification packet. The
    /// decoder takes the reader, also when this fails.
    ///
    /// On a seekable input this reads every page header of the file once, to find the links.
    pub fn initReader(
        gpa: std.mem.Allocator,
        input: *io.Input,
        reader_in: packets.PacketReader,
        first: []const u8,
        options: Options,
    ) codec.InitError!Decoder {
        var reader = reader_in;
        var handed = false;
        errdefer if (!handed) reader.deinit();
        reader.select = .{ .accept = .{ .func = isIdentification } };
        reader.begin_group_only = false;
        reader.max_packet = header_packet_limit;
        var inner: VorbisCodec = .{ .gpa = gpa, .options = options };
        errdefer if (!handed) inner.deinit();
        var h = try inner.readHeaders(&reader, first);
        var held = h.held;
        const bound = try inner.enter(&h);
        try ogg_chain.setBound(&reader, &held, bound);
        handed = true;
        return .{ .chain = try VorbisChain.init(gpa, input, reader, inner, held) };
    }

    pub fn deinit(self: *Decoder) void {
        self.chain.deinit();
        self.* = undefined;
    }

    /// The rate, channels and mask are the ones of the current link. `total_frames` is the
    /// sum over the links when the input is seekable and every link has a page granule. It is
    /// the last granule less the start time of the link, which the first audio page gives. It
    /// is a hint for a damaged stream. A reader that cannot seek gives null.
    pub fn info(self: *const Decoder) codec.Info {
        return self.chain.info();
    }

    pub fn stats(self: *const Decoder) Stats {
        return .{ .resyncs = self.chain.codec.resyncs };
    }

    /// Writes whole frames of f32 into `out` and returns the frame count. 0 means the end.
    /// `out` must hold at least one frame (`info().channels` samples).
    ///
    /// When the next link of a chained file has another rate or channel count, the call
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
    /// error.Unsupported. A seek allocates nothing unless it enters a link that `init` did
    /// not see. A packet that does not decode on the way is skipped under `.resync` and gives
    /// error.BadData under `.fail`.
    ///
    /// A stream with a granule that moves back for good after the first page, or granules that
    /// are ahead of the frames from some page on with no lost packet or page, is malformed. A
    /// seek then lands off by that amount and it is not repaired. A seek that crosses the page
    /// of a single bad granule decodes from the start instead.
    pub fn seek(self: *Decoder, frame: u64) codec.SeekError!void {
        return self.chain.seek(frame);
    }
};

const Vector = struct {
    name: []const u8,
    file: []const u8,
    ref: []const u8,
    rate: u32,
    channels: u8,
    frames: usize,
    mask: u32,
};

fn vector(comptime name: []const u8, rate: u32, channels: u8, frames: usize, mask: u32) Vector {
    return .{
        .name = name,
        .file = vt.embed(name),
        .ref = @embedFile("../testdata/vorbis/" ++ name ++ ".f32"),
        .rate = rate,
        .channels = channels,
        .frames = frames,
        .mask = mask,
    };
}

const vectors = [_]Vector{
    vector("mono8k", 8000, 1, 8000, 0x4),
    vector("stereo44", 44100, 2, 44100, 0x3),
    vector("noise48", 48000, 2, 24000, 0x3),
    vector("surround48", 48000, 6, 24000, 0x3f),
    vector("impulse22", 22050, 1, 22050, 0x4),
    vector("silence44", 44100, 2, 22050, 0x3),
    vector("square32", 32000, 2, 16000, 0x3),
};

const chain_file = vt.embed("chain");
const link_a_ref = @embedFile("../testdata/vorbis/linka.f32");
const link_b_ref = @embedFile("../testdata/vorbis/linkb.f32");

/// The WAVE position of each Vorbis channel of the 6 channel vectors.
const wave_6 = [6]usize{ 0, 2, 1, 4, 5, 3 };

fn refSample(ref: []const u8, index: usize) f32 {
    return @bitCast(std.mem.readInt(u32, ref[index * 4 ..][0..4], .little));
}

/// The biggest difference between the samples of `got` and the reference, which holds every
/// 32nd frame in Vorbis channel order. The reference is clamped like the decoder output,
/// because the libvorbis decode of the full scale square wave goes up to 1.19.
fn maxError(ref: []const u8, channels: usize, got: []const f32) !f32 {
    const ref_frames = ref.len / 4 / channels;
    try testing.expect(got.len / channels >= (ref_frames - 1) * 32 + 1);
    var worst: f32 = 0;
    for (0..ref_frames) |i| {
        for (0..channels) |c| {
            const wave = if (channels == 6) wave_6[c] else c;
            const diff = @abs(pcm.clampUnit(refSample(ref, i * channels + c)) - got[i * 32 * channels + wave]);
            worst = @max(worst, diff);
        }
    }
    return worst;
}

fn openBytes(gpa: std.mem.Allocator, input: *io.Input, bytes: []const u8) !Decoder {
    input.* = .init(.{ .bytes = bytes });
    return Decoder.init(gpa, input);
}

test "each vendored file decodes to its libvorbis reference" {
    const gpa = testing.allocator;
    for (vectors) |v| {
        var input: io.Input = undefined;
        var dec = try openBytes(gpa, &input, v.file);
        defer dec.deinit();
        const info = dec.info();
        try testing.expectEqual(v.rate, info.rate);
        try testing.expectEqual(v.channels, info.channels);
        try testing.expectEqual(v.mask, @as(u32, @bitCast(info.mask)));
        try testing.expectEqual(@as(u8, 0), info.bits_per_sample);
        try testing.expectEqual(@as(?u64, v.frames), info.total_frames);
        const got = try helpers.readAll(gpa, &dec, 1000);
        defer gpa.free(got);
        try testing.expectEqual(v.frames * v.channels, got.len);
        try testing.expect(try maxError(v.ref, v.channels, got) <= 2e-5);
        for (got) |s| try testing.expect(s >= -1 and s < 1);
        try testing.expectEqual(@as(u32, 0), dec.stats().resyncs);
    }
}

test "the output does not depend on the read size" {
    const gpa = testing.allocator;
    var input: io.Input = undefined;
    var whole = try openBytes(gpa, &input, vectors[3].file);
    defer whole.deinit();
    const want = try helpers.readAll(gpa, &whole, 5000);
    defer gpa.free(want);
    for ([_]usize{ 1, 7, 333 }) |chunk| {
        var input2: io.Input = undefined;
        var dec = try openBytes(gpa, &input2, vectors[3].file);
        defer dec.deinit();
        const got = try helpers.readAll(gpa, &dec, chunk);
        defer gpa.free(got);
        try testing.expectEqualSlices(f32, want, got);
    }
}

test "a stream shorter than one block gives the frames of its granule" {
    const gpa = testing.allocator;
    var input: io.Input = undefined;
    var dec = try openBytes(gpa, &input, vt.embed("short44"));
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 100), dec.info().total_frames);
    const got = try helpers.readAll(gpa, &dec, 64);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 200), got.len);
    var signal: f64 = 0;
    var noise: f64 = 0;
    for (0..100) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / 44100.0;
        const want = [2]f64{
            0.5 * @sin(2 * std.math.pi * 440 * t),
            0.5 * @sin(2 * std.math.pi * 550 * t),
        };
        for (want, 0..) |w, c| {
            const d = w - got[i * 2 + c];
            signal += w * w;
            noise += d * d;
        }
    }
    try testing.expect(10 * std.math.log10(signal / noise) > 20);
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

test "a chain with another format gives StreamChanged and then link two" {
    const gpa = testing.allocator;
    var input: io.Input = undefined;
    var dec = try openBytes(gpa, &input, chain_file);
    defer dec.deinit();
    try testing.expectEqual(@as(u32, 44100), dec.info().rate);
    try testing.expectEqual(@as(?u64, 22050 + 11025), dec.info().total_frames);
    const parts = try readTwoLinks(gpa, &dec);
    defer gpa.free(parts.first);
    defer gpa.free(parts.second);
    try testing.expectEqual(@as(usize, 22050 * 2), parts.first.len);
    try testing.expectEqual(@as(usize, 11025), parts.second.len);
    try testing.expect(try maxError(link_a_ref, 2, parts.first) <= 2e-5);
    try testing.expect(try maxError(link_b_ref, 1, parts.second) <= 2e-5);
    try testing.expectEqual(@as(u32, 22050), dec.info().rate);
    try testing.expectEqual(@as(u8, 1), dec.info().channels);
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
    try testing.expectEqual(@as(usize, 22050 * 2), parts.first.len);
    try testing.expectEqual(@as(usize, 11025), parts.second.len);
    try testing.expect(try maxError(link_b_ref, 1, parts.second) <= 2e-5);
}

test "seeks land on the samples of a full decode" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x766f72);
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

test "reads after init do not allocate, also across a format change" {
    const gpa = testing.allocator;
    const Case = struct { file: []const u8, frames: usize };
    for ([_]Case{
        .{ .file = chain_file, .frames = 22050 + 11025 },
        .{ .file = vectors[1].file, .frames = 44100 },
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
    }
}

test "channel positions follow the WAVE order" {
    const expected = [_][]const u8{
        &.{},
        &.{0},
        &.{ 0, 1 },
        &.{ 0, 2, 1 },
        &.{ 0, 1, 2, 3 },
        &.{ 0, 2, 1, 3, 4 },
        &.{ 0, 2, 1, 4, 5, 3 },
        &.{ 0, 2, 1, 5, 6, 4, 3 },
        &.{ 0, 2, 1, 6, 7, 4, 5, 3 },
    };
    const masks = [_]u32{ 0, 0x4, 0x3, 0x7, 0x33, 0x37, 0x3f, 0x70f, 0x63f };
    for (expected, masks, 0..) |table, mask, channels| {
        for (table, 0..) |want, c| try testing.expectEqual(@as(usize, want), waveChannel(channels, c));
        try testing.expectEqual(mask, channelMask(@intCast(channels)));
        // Each position is used once and sits at a set bit of the mask.
        var seen: u32 = 0;
        for (table) |p| seen |= @as(u32, 1) << @intCast(p);
        try testing.expectEqual((@as(u32, 1) << @intCast(channels)) - 1, seen);
    }
    for ([_]usize{ 9, 17, 255 }) |channels| {
        for ([_]usize{ 0, 3, 8 }) |c| try testing.expectEqual(c, waveChannel(channels, c));
        try testing.expectEqual(@as(u32, 0), channelMask(@intCast(channels)));
    }
}

test "inverse coupling follows the four sign cases" {
    // magnitude, angle, then the new magnitude and angle
    const cases = [_][4]f32{
        .{ 3, 2, 3, 1 },
        .{ 3, -2, 1, 3 },
        .{ 3, 0, 3, 3 },
        .{ -3, 2, -3, -1 },
        .{ -3, -2, -1, -3 },
        .{ -3, 0, -3, -3 },
        .{ 0, 2, 0, 2 },
        .{ 0, -2, 2, 0 },
        .{ 0, 0, 0, 0 },
    };
    for (cases) |c| {
        var m = [1]f32{c[0]};
        var a = [1]f32{c[1]};
        uncouple(&m, &a);
        try testing.expectEqual(c[2], m[0]);
        try testing.expectEqual(c[3], a[0]);
    }
}

test "a coupled channel gets its residue when its partner has a floor" {
    const steps = [_]header.Coupling{ .{ .magnitude = 0, .angle = 1 }, .{ .magnitude = 1, .angle = 3 } };
    var none = [_]bool{ true, true, true, true };
    propagate(&steps, &none);
    try testing.expectEqualSlices(bool, &.{ true, true, true, true }, &none);
    var first = [_]bool{ false, true, true, true };
    propagate(&steps, &first);
    try testing.expectEqualSlices(bool, &.{ false, false, true, false }, &first);
    var last = [_]bool{ true, true, true, false };
    propagate(&steps, &last);
    try testing.expectEqualSlices(bool, &.{ true, false, true, false }, &last);
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

const first_audio = 3;

fn decodeAll(gpa: std.mem.Allocator, bytes: []const u8, options: Options) ![]f32 {
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .initOptions(gpa, &input, options);
    defer dec.deinit();
    return helpers.readAll(gpa, &dec, 1000);
}

test "remuxing the packets of a file keeps its samples" {
    const gpa = testing.allocator;
    for (vectors) |v| {
        const pks = try demux(gpa, v.file);
        defer freePks(gpa, pks);
        const again = try muxPks(gpa, pks, 99);
        defer gpa.free(again);
        const want = try decodeAll(gpa, v.file, .{});
        defer gpa.free(want);
        const got = try decodeAll(gpa, again, .{});
        defer gpa.free(got);
        try testing.expectEqualSlices(f32, want, got);
    }
}

test "the end page granule cuts the end" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[0].file);
    defer freePks(gpa, pks);
    const want = try decodeAll(gpa, vectors[0].file, .{});
    defer gpa.free(want);
    // The packets give 8192 frames. The last granule is 8000, and 7950 cuts 50 more.
    try testing.expectEqual(@as(i64, 8000), pks[pks.len - 1].granule);
    pks[pks.len - 1].granule = 7950;
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 7950), dec.info().total_frames);
    const got = try helpers.readAll(gpa, &dec, 999);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, want[0..7950], got);
    try testing.expectEqual(@as(usize, 7950), got.len);
}

test "a granule past the decoded frames does not add frames" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[0].file);
    defer freePks(gpa, pks);
    const want = try decodeAll(gpa, vectors[0].file, .{});
    defer gpa.free(want);
    pks[pks.len - 1].granule = 9000;
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    const got = try decodeAll(gpa, bytes, .{});
    defer gpa.free(got);
    // The granule is 808 ahead, and nothing was lost, so the stream ends at the decoded frames.
    try testing.expectEqual(@as(usize, 8192), got.len);
    try testing.expectEqualSlices(f32, want[0..8000], got[0..8000]);
}

/// Moves the granules of the audio packets of a mono8k stream by `delta`. With `clear_first` the
/// first audio packet gets no granule, so that the page of the second packet holds both.
fn shiftGranules(pks: []Pk, delta: i64, clear_first: bool) void {
    for (pks[first_audio..]) |*p| {
        if (p.granule != -1) p.granule += delta;
    }
    if (clear_first) pks[first_audio].granule = -1;
}

test "a first page granule below the sample count cuts the start" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[0].file);
    defer freePks(gpa, pks);
    const want = try decodeAll(gpa, vectors[0].file, .{});
    defer gpa.free(want);
    // The first two packets give 256 frames, and the granule says 156.
    shiftGranules(pks, -100, true);
    try testing.expectEqual(@as(i64, 156), pks[first_audio + 1].granule);
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 7900), dec.info().total_frames);
    const got = try helpers.readAll(gpa, &dec, 1000);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, want[100..], got);
    try testing.expectEqual(@as(usize, 7900), got.len);

    var prng: std.Random.DefaultPrng = .init(5);
    for (0..20) |_| {
        const t = prng.random().uintLessThan(u64, 7900);
        try dec.seek(t);
        const tail = try helpers.readAll(gpa, &dec, 300);
        defer gpa.free(tail);
        try testing.expectEqualSlices(f32, want[100 + @as(usize, @intCast(t)) ..], tail);
    }
    try testing.expectEqual(@as(u32, 0), dec.chain.codec.rescans);
}

test "a cut start longer than the packet drops the whole packet" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[0].file);
    defer freePks(gpa, pks);
    const want = try decodeAll(gpa, vectors[0].file, .{});
    defer gpa.free(want);
    shiftGranules(pks, -300, true);
    pks[first_audio + 1].granule = 0;
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    const got = try decodeAll(gpa, bytes, .{});
    defer gpa.free(got);
    // The first granule is 0, so all 256 frames of the second packet are cut.
    try testing.expectEqualSlices(f32, want[256 .. 7700 + 256], got[0..7700]);
}

test "a first page granule above the sample count starts the stream at that time" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[0].file);
    defer freePks(gpa, pks);
    const want = try decodeAll(gpa, vectors[0].file, .{});
    defer gpa.free(want);
    shiftGranules(pks, 50, false);
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    // The 50 frames before the start are not counted.
    try testing.expectEqual(@as(?u64, 8000), dec.info().total_frames);
    const got = try helpers.readAll(gpa, &dec, 1000);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, want, got);

    var prng: std.Random.DefaultPrng = .init(6);
    for (0..20) |_| {
        const t = prng.random().uintLessThan(u64, 8000);
        try dec.seek(t);
        const tail = try helpers.readAll(gpa, &dec, 300);
        defer gpa.free(tail);
        try testing.expectEqualSlices(f32, want[@intCast(t)..], tail);
    }
    try dec.seek(8000);
    try testing.expectEqual(@as(usize, 0), try dec.read(got[0..1]));
    try testing.expectError(error.Truncated, dec.seek(8001));
    try testing.expectEqual(@as(u32, 0), dec.chain.codec.rescans);
}

test "a damaged packet is skipped, counted and the stream goes on" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    const want = try decodeAll(gpa, vectors[1].file, .{});
    defer gpa.free(want);
    // The type bit of a header packet makes the packet not audio.
    pks[first_audio + 20].data[0] = 0xff;
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);

    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const got = try helpers.readAll(gpa, &dec, 1000);
    defer gpa.free(got);
    try testing.expectEqual(@as(u32, 1), dec.stats().resyncs);
    // The lost frames are filled with silence at the next granule, so the length stays.
    try testing.expectEqual(want.len, got.len);
    try testing.expectEqual(@as(?u64, 44100), dec.info().total_frames);
    try testing.expectEqualSlices(f32, want[0 .. 1000 * 2], got[0 .. 1000 * 2]);
    // The packets after the damaged one and the next one that primes the overlap are intact.
    const tail = 20000 * 2;
    try testing.expectEqualSlices(f32, want[want.len - tail ..], got[got.len - tail ..]);

    var strict_input: io.Input = .init(.{ .bytes = bytes });
    var strict: Decoder = try .initOptions(gpa, &strict_input, .{ .on_bad_packet = .fail });
    defer strict.deinit();
    var buf: [2000]f32 = undefined;
    const result = while (true) {
        const n = strict.read(&buf) catch |err| break err;
        if (n == 0) break error.TestUnexpectedResult;
    };
    try testing.expectEqual(error.BadData, result);
    try testing.expectError(error.BadData, strict.read(&buf));
    try testing.expectEqual(@as(u32, 0), strict.stats().resyncs);
}

test "empty audio packets are skipped" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[0].file);
    defer freePks(gpa, pks);
    // Two empty packets.
    gpa.free(pks[first_audio + 5].data);
    pks[first_audio + 5].data = try gpa.alloc(u8, 0);
    pks[first_audio + 9].data = try gpa.realloc(pks[first_audio + 9].data, 0);
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const got = try helpers.readAll(gpa, &dec, 1000);
    defer gpa.free(got);
    try testing.expectEqual(@as(u32, 2), dec.stats().resyncs);
    try testing.expect(got.len > 5000);
}

fn expectFinite(samples: []const f32) !void {
    for (samples) |s| try testing.expect(s >= -1 and s < 1);
}

/// Reads up to `limit` frames and checks the samples. Errors end the read.
fn drain(dec: *Decoder, limit: usize) !void {
    var buf: [1024]f32 = undefined;
    var frames: usize = 0;
    while (frames < limit) {
        const channels: usize = dec.info().channels;
        const n = dec.read(buf[0 .. 1024 / channels * channels]) catch |err| switch (err) {
            error.StreamChanged => continue,
            else => return,
        };
        if (n == 0) return;
        try expectFinite(buf[0 .. n * channels]);
        frames += n;
    }
}

test "hostile headers give errors" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    const Case = struct { index: usize, byte: usize, value: u8, err: anyerror };
    // The identification header: the version, the channel count, the rate, the block sizes
    // and the framing bit.
    const cases = [_]Case{
        .{ .index = 0, .byte = 7, .value = 1, .err = error.BadHeader },
        .{ .index = 0, .byte = 11, .value = 0, .err = error.BadHeader },
        .{ .index = 0, .byte = 28, .value = 0x55, .err = error.BadHeader },
        .{ .index = 0, .byte = 28, .value = 0x8b, .err = error.BadHeader },
        .{ .index = 0, .byte = 29, .value = 0, .err = error.BadHeader },
        .{ .index = 1, .byte = 0, .value = 5, .err = error.BadHeader },
        .{ .index = 1, .byte = 3, .value = 'x', .err = error.BadHeader },
        .{ .index = 2, .byte = 0, .value = 3, .err = error.BadHeader },
    };
    for (cases) |c| {
        const copy = try clonePks(gpa, pks);
        defer freePks(gpa, copy);
        copy[c.index].data[c.byte] = c.value;
        const bytes = try muxPks(gpa, copy, 1);
        defer gpa.free(bytes);
        var input: io.Input = .init(.{ .bytes = bytes });
        try testing.expectError(c.err, Decoder.init(gpa, &input));
    }
    // A setup that stops early, and a setup without its framing bit.
    for ([_]usize{ 40, pks[2].data.len - 1 }) |keep| {
        const copy = try clonePks(gpa, pks);
        defer freePks(gpa, copy);
        copy[2].data = try gpa.realloc(copy[2].data, keep);
        if (keep == pks[2].data.len - 1) copy[2].data[keep - 1] = 0;
        const bytes = try muxPks(gpa, copy, 1);
        defer gpa.free(bytes);
        var input: io.Input = .init(.{ .bytes = bytes });
        try testing.expectError(error.BadHeader, Decoder.init(gpa, &input));
    }
    // A stream that ends inside the headers.
    for ([_]usize{ 1, 2 }) |keep| {
        const bytes = try muxPks(gpa, pks[0..keep], 1);
        defer gpa.free(bytes);
        var input: io.Input = .init(.{ .bytes = bytes });
        try testing.expectError(error.Truncated, Decoder.init(gpa, &input));
    }
    var empty: io.Input = .init(.{ .bytes = "" });
    try testing.expectError(error.Unsupported, Decoder.init(gpa, &empty));
}

test "a setup bigger than the limit gives BadHeader" {
    const gpa = testing.allocator;
    var input: io.Input = .init(.{ .bytes = vectors[1].file });
    try testing.expectError(error.BadHeader, Decoder.initOptions(gpa, &input, .{ .max_setup_bytes = 100000 }));
    var ok: io.Input = .init(.{ .bytes = vectors[1].file });
    var dec: Decoder = try .initOptions(gpa, &ok, .{ .max_setup_bytes = 1 << 20 });
    dec.deinit();
}

test "a stream with headers and no audio has no frames" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    const bytes = try muxPks(gpa, pks[0..3], 1);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 0), dec.info().total_frames);
    var buf: [8]f32 = undefined;
    try testing.expectEqual(@as(usize, 0), try dec.read(&buf));
    try dec.seek(0);
    try testing.expectError(error.Truncated, dec.seek(1));
}

test "bit flips in the headers give errors or finite samples" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x4844);
    const rng = prng.random();
    for ([_]usize{ 0, 1, 3 }) |which| {
        const pks = try demux(gpa, vectors[which].file);
        defer freePks(gpa, pks);
        for (0..60) |_| {
            const copy = try clonePks(gpa, pks);
            defer freePks(gpa, copy);
            const target = rng.uintLessThan(usize, 3);
            const data = copy[target].data;
            for (0..1 + rng.uintLessThan(usize, 3)) |_| {
                data[rng.uintLessThan(usize, data.len)] ^= @as(u8, 1) << rng.int(u3);
            }
            const bytes = try muxPks(gpa, copy, 1);
            defer gpa.free(bytes);
            var input: io.Input = .init(.{ .bytes = bytes });
            var dec = Decoder.init(gpa, &input) catch continue;
            defer dec.deinit();
            try drain(&dec, 3000);
            dec.seek(1000) catch |err| {
                try testing.expectEqual(error.Truncated, err);
                continue;
            };
            try drain(&dec, 1000);
        }
    }
}

test "random and damaged audio packets give finite samples" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x7061636b);
    const rng = prng.random();
    for (vectors) |v| {
        const pks = try demux(gpa, v.file);
        defer freePks(gpa, pks);
        for (0..6) |round| {
            const copy = try clonePks(gpa, pks);
            defer freePks(gpa, copy);
            for (copy[first_audio..]) |*p| {
                if (rng.uintLessThan(u8, 8) != 0) continue;
                switch (rng.uintLessThan(u8, 4)) {
                    0 => p.data[rng.uintLessThan(usize, p.data.len)] ^= @as(u8, 1) << rng.int(u3),
                    1 => p.data = try gpa.realloc(p.data, rng.uintLessThan(usize, p.data.len + 1)),
                    2 => rng.bytes(p.data),
                    else => @memset(p.data, 0xff),
                }
            }
            const bytes = try muxPks(gpa, copy, 1);
            defer gpa.free(bytes);
            for ([_]bool{ true, false }) |resync| {
                const options: Options = .{ .on_bad_packet = if (resync) .resync else .fail };
                var input: io.Input = .init(.{ .bytes = bytes });
                var dec = Decoder.initOptions(gpa, &input, options) catch continue;
                defer dec.deinit();
                try drain(&dec, v.frames + 5000);
                if (round % 2 == 0) {
                    dec.seek(v.frames / 3) catch |err| {
                        try testing.expect(err == error.Truncated or (!resync and err == error.BadData));
                        continue;
                    };
                    try drain(&dec, 2000);
                }
            }
        }
    }
}

/// A stream of `count` audio packets in which every floor is unused.
fn silentStream(gpa: std.mem.Allocator, channels: u8, count: usize) ![]u8 {
    const ident = vt.buildIdentification(channels, 8000, 8, 11);
    const comment = "\x03vorbis\x00\x00\x00\x00\x00\x00\x00\x00\x01";
    const setup = try vt.buildSetup(gpa, .{});
    defer gpa.free(setup);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var w: packets.PacketWriter = try .init(gpa, &aw.writer, 3, .{});
    defer w.deinit();
    try w.writePacket(&ident, 0);
    try w.flush();
    try w.writePacket(comment, -1);
    try w.writePacket(setup, 0);
    try w.flush();
    // The type bit, the mode (short) and one absent flag per channel.
    const audio = try gpa.alloc(u8, (2 + @as(usize, channels) + 7) / 8);
    defer gpa.free(audio);
    @memset(audio, 0);
    for (0..count) |i| try w.writePacket(audio, if (i + 1 == count) @as(i64, @intCast((count - 1) * 128)) else -1);
    try w.finish();
    return aw.toOwnedSlice();
}

test "streams with many channels keep the stream order and have no mask" {
    const gpa = testing.allocator;
    for ([_]u8{ 9, 32, 255 }) |channels| {
        const bytes = try silentStream(gpa, channels, 10);
        defer gpa.free(bytes);
        var input: io.Input = .init(.{ .bytes = bytes });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        const info = dec.info();
        try testing.expectEqual(channels, info.channels);
        try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(info.mask)));
        try testing.expectEqual(@as(?u64, 9 * 128), info.total_frames);
        const got = try helpers.readAll(gpa, &dec, 300);
        defer gpa.free(got);
        try testing.expectEqual(@as(usize, 9 * 128) * channels, got.len);
        for (got) |s| try testing.expectEqual(@as(f32, 0), s);
    }
}

/// The files joined into one chained stream, each link with its own serial number.
fn chainOf(gpa: std.mem.Allocator, files: []const []const u8) ![]u8 {
    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(gpa);
    for (files, 0..) |file, i| {
        const pks = try demux(gpa, file);
        defer freePks(gpa, pks);
        const part = try muxPks(gpa, pks, @intCast(i + 1));
        defer gpa.free(part);
        try all.appendSlice(gpa, part);
    }
    return all.toOwnedSlice(gpa);
}

test "links with the same format continue without a signal" {
    const gpa = testing.allocator;
    const bytes = try chainOf(gpa, &.{ vectors[1].file, vectors[1].file, vectors[3].file });
    defer gpa.free(bytes);
    const single = try decodeAll(gpa, vectors[1].file, .{});
    defer gpa.free(single);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 2 * 44100 + 24000), dec.info().total_frames);
    var got: std.ArrayList(f32) = .empty;
    defer got.deinit(gpa);
    var buf: [1000]f32 = undefined;
    var changed: usize = 0;
    while (true) {
        const channels: usize = dec.info().channels;
        const n = dec.read(buf[0 .. 1000 / channels * channels]) catch |err| switch (err) {
            error.StreamChanged => {
                changed += 1;
                continue;
            },
            else => return err,
        };
        if (n == 0) break;
        if (channels == 2) try got.appendSlice(gpa, buf[0 .. n * 2]);
    }
    try testing.expectEqual(@as(usize, 1), changed);
    try testing.expectEqualSlices(f32, single, got.items[0..single.len]);
    try testing.expectEqualSlices(f32, single, got.items[single.len..]);

    // A seek across the seam of the two equal links.
    var again: io.Input = .init(.{ .bytes = bytes });
    var dec2: Decoder = try .init(gpa, &again);
    defer dec2.deinit();
    try dec2.seek(44100 - 10);
    const n = try dec2.read(buf[0..40]);
    try testing.expectEqual(@as(usize, 20), n);
    try testing.expectEqualSlices(f32, single[single.len - 20 ..], buf[0..20]);
    try testing.expectEqualSlices(f32, single[0..20], buf[20..40]);
}

/// Reads until the end or until a format change, and returns the samples.
fn readLink(gpa: std.mem.Allocator, dec: *Decoder) ![]f32 {
    var all: std.ArrayList(f32) = .empty;
    errdefer all.deinit(gpa);
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
    return all.toOwnedSlice(gpa);
}

test "seeks cross the links of a chained file" {
    const gpa = testing.allocator;
    var input: io.Input = .init(.{ .bytes = chain_file });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const parts = try readTwoLinks(gpa, &dec);
    defer gpa.free(parts.first);
    defer gpa.free(parts.second);
    var prng: std.Random.DefaultPrng = .init(11);
    for (0..24) |_| {
        const t = prng.random().uintLessThan(u64, 22050 + 11025);
        try dec.seek(t);
        try testing.expectEqual(@as(u8, if (t < 22050) 2 else 1), dec.info().channels);
        const tail = try readLink(gpa, &dec);
        defer gpa.free(tail);
        const want = if (t < 22050) parts.first[@as(usize, @intCast(t)) * 2 ..] else parts.second[@as(usize, @intCast(t - 22050))..];
        try testing.expectEqualSlices(f32, want, tail);
    }
    try dec.seek(22050);
    try testing.expectEqual(@as(u8, 1), dec.info().channels);
    var one: [1]f32 = undefined;
    try testing.expectEqual(@as(usize, 1), try dec.read(&one));
    try testing.expectEqual(parts.second[0], one[0]);
    try testing.expectEqual(@as(u32, 0), dec.chain.codec.rescans);
}

/// Seeks every `step` frames. Every seek must work. A seek that does not start in the window
/// [skip_from, skip_to) must give the samples of `want`.
fn probeSeeks(dec: *Decoder, want: []const f32, channels: usize, step: usize, skip_from: usize, skip_to: usize) !void {
    const total = want.len / channels;
    var buf: [64]f32 = undefined;
    var t: usize = 0;
    while (t < total) : (t += step) {
        try dec.seek(t);
        const n = try dec.read(buf[0 .. 32 * channels]);
        try testing.expect(n != 0);
        if (t >= skip_from and t < skip_to) continue;
        const frames = @min(n, total - t);
        try testing.expectEqualSlices(f32, want[t * channels ..][0 .. frames * channels], buf[0 .. frames * channels]);
    }
}

test "one granule ahead of the frames with no loss is believed" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[0].file);
    defer freePks(gpa, pks);
    const want = try decodeAll(gpa, vectors[0].file, .{});
    defer gpa.free(want);
    // The packet with the granule 2560 says 2597. The next granule is behind it again.
    try testing.expectEqual(@as(i64, 2560), pks[first_audio + 10].granule);
    pks[first_audio + 10].granule = 2597;
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const whole = try helpers.readAll(gpa, &dec, 1000);
    defer gpa.free(whole);
    try testing.expectEqualSlices(f32, want, whole);
    try probeSeeks(&dec, want, 1, 97, 2304, 2800);
}

test "a granule behind the frames makes the seek decode from the start" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[0].file);
    defer freePks(gpa, pks);
    const want = try decodeAll(gpa, vectors[0].file, .{});
    defer gpa.free(want);
    // The granule 2560 says 2550. The stream is believed and nothing is added.
    pks[first_audio + 10].granule = 2550;
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const whole = try helpers.readAll(gpa, &dec, 1000);
    defer gpa.free(whole);
    try testing.expectEqualSlices(f32, want, whole);

    // The walk reads the bad granule, and the seek decodes from the start.
    try dec.seek(2540);
    try testing.expectEqual(@as(u32, 1), dec.chain.codec.rescans);
    const tail = try helpers.readAll(gpa, &dec, 100);
    defer gpa.free(tail);
    try testing.expectEqualSlices(f32, want[2540..], tail);
}

test "a granule that jumps back by 300 reads the decoded frames and every seek works" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[0].file);
    defer freePks(gpa, pks);
    const want = try decodeAll(gpa, vectors[0].file, .{});
    defer gpa.free(want);
    // The page with the granule 3840 says 3540, which is below the granule of the page before.
    var k: usize = first_audio;
    while (pks[k].granule != 3840) k += 1;
    pks[k].granule -= 300;
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const whole = try helpers.readAll(gpa, &dec, 1000);
    defer gpa.free(whole);
    try testing.expectEqualSlices(f32, want, whole);
    try testing.expectEqual(@as(?u64, 8000), dec.info().total_frames);
    try expectSeeksMatch(&dec, want, 1, 97);
    try testing.expect(dec.chain.codec.rescans > 0);
}

test "granules ahead of the frames from one page on, with no loss, do not add frames" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[0].file);
    defer freePks(gpa, pks);
    const want = try decodeAll(gpa, vectors[0].file, .{});
    defer gpa.free(want);
    for (pks[first_audio + 15 ..]) |*p| {
        if (p.granule != -1) p.granule += 300;
    }
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const whole = try helpers.readAll(gpa, &dec, 1000);
    defer gpa.free(whole);
    try testing.expectEqualSlices(f32, want, whole);
    // The seeks after that page land 300 frames off, which a seek cannot see.
    try dec.seek(1000);
    const early = try helpers.readAll(gpa, &dec, 100);
    defer gpa.free(early);
    try testing.expectEqualSlices(f32, want[1000..], early);
}

test "a lost audio page is filled with silence" {
    const gpa = testing.allocator;
    const file = vectors[1].file;
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(gpa);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, file, i, "OggS")) |at| : (i = at + 4) try starts.append(gpa, at);
    const k = starts.items.len / 2;
    const bytes = try std.mem.concat(gpa, u8, &.{ file[0..starts.items[k]], file[starts.items[k + 1]..] });
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const got = try helpers.readAll(gpa, &dec, 1000);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 44100 * 2), got.len);
    try testing.expectEqual(@as(?u64, 44100), dec.info().total_frames);
    try expectSeeksMatch(&dec, got, 2, 211);
}

test "links with other block sizes continue and read without allocating" {
    const gpa = testing.allocator;
    // The mono links have the block sizes 512 and 512, then 512 and 1024. The rate of the
    // second one is set to 8000, so both have the same format.
    const second = try demux(gpa, vectors[4].file);
    defer freePks(gpa, second);
    std.mem.writeInt(u32, second[0].data[12..16], 8000, .little);
    const second_bytes = try muxPks(gpa, second, 2);
    defer gpa.free(second_bytes);
    const bytes = try std.mem.concat(gpa, u8, &.{ vectors[0].file, second_bytes, vectors[0].file });
    defer gpa.free(bytes);

    const first = try decodeAll(gpa, vectors[0].file, .{});
    defer gpa.free(first);
    const middle = try decodeAll(gpa, second_bytes, .{});
    defer gpa.free(middle);
    const want = try std.mem.concat(gpa, f32, &.{ first, middle, first });
    defer gpa.free(want);
    try testing.expectEqual(@as(usize, 8000 + 22050 + 8000), want.len);

    var failing = testing.FailingAllocator.init(gpa, .{});
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(failing.allocator(), &input);
    defer dec.deinit();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try testing.expectEqual(@as(?u64, want.len), dec.info().total_frames);
    const got = try helpers.readAll(gpa, &dec, 777);
    defer gpa.free(got);
    try testing.expectEqualSlices(f32, want, got);

    var prng: std.Random.DefaultPrng = .init(21);
    for (0..16) |_| {
        const t = prng.random().uintLessThan(u64, want.len);
        try dec.seek(t);
        const tail = try helpers.readAll(gpa, &dec, 500);
        defer gpa.free(tail);
        try testing.expectEqualSlices(f32, want[@intCast(t)..], tail);
    }
    try testing.expectEqual(@as(u32, 0), dec.chain.codec.rescans);

    // A forward-only reader enters the links by allocating.
    var reader: std.Io.Reader = .fixed(bytes);
    var forward: io.Input = .init(.{ .reader = &reader });
    var streamed: Decoder = try .init(gpa, &forward);
    defer streamed.deinit();
    const again = try helpers.readAll(gpa, &streamed, 1000);
    defer gpa.free(again);
    try testing.expectEqualSlices(f32, want, again);
}

/// A two channel stream of short blocks that all use floor 0, with an amplitude for each channel.
fn floor0Stream(gpa: std.mem.Allocator, amplitudes: [2]u32, count: usize) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const class_book = try vt.parseBook(arena.allocator(), vt.book_scalar_4);
    const lattice = try vt.parseBook(arena.allocator(), vt.book_lattice);
    const coeffs = try vt.parseBook(arena.allocator(), vt.book_explicit);

    const ident = vt.buildIdentification(2, 44100, 8, 11);
    const comment = "\x03vorbis\x00\x00\x00\x00\x00\x00\x00\x00\x01";
    const setup = try vt.buildSetup(gpa, .{ .floor_type = 0 });
    defer gpa.free(setup);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var w: packets.PacketWriter = try .init(gpa, &aw.writer, 3, .{});
    defer w.deinit();
    try w.writePacket(&ident, 0);
    try w.flush();
    try w.writePacket(comment, -1);
    try w.writePacket(setup, 0);
    try w.flush();

    var prng: std.Random.DefaultPrng = .init(0x666c6f);
    const rng = prng.random();
    for (0..count) |i| {
        var bits: io.LsbWriter = .init(gpa);
        defer bits.deinit();
        // The type bit and the short mode.
        try bits.writeBits(0, 2);
        for (amplitudes) |amplitude| {
            try bits.writeBits(amplitude, 8);
            if (amplitude == 0) continue;
            // One book, so the book number has one bit. Then eight coefficients.
            try bits.writeBits(0, 1);
            for (0..4) |_| try vt.putCode(&bits, coeffs, rng.uintLessThan(usize, 4));
        }
        for (0..8) |_| {
            try vt.putCode(&bits, class_book, 1);
            for (0..4) |_| try vt.putCode(&bits, lattice, rng.uintLessThan(usize, 9));
        }
        const granule: i64 = if (i + 1 == count) @intCast((count - 1) * 128) else -1;
        try w.writePacket(bits.bytes(), granule);
    }
    try w.finish();
    return aw.toOwnedSlice();
}

/// The energy of one channel of interleaved stereo samples.
fn channelEnergy(samples: []const f32, channel: usize) f64 {
    var sum: f64 = 0;
    var i = channel;
    while (i < samples.len) : (i += 2) sum += @as(f64, samples[i]) * samples[i];
    return sum;
}

test "floor 0 packets decode and a channel without a floor is silent" {
    const gpa = testing.allocator;
    const cases = [_][2]u32{ .{ 100, 100 }, .{ 100, 0 }, .{ 0, 100 }, .{ 0, 0 } };
    for (cases) |amplitudes| {
        const bytes = try floor0Stream(gpa, amplitudes, 12);
        defer gpa.free(bytes);
        const got = try decodeAll(gpa, bytes, .{});
        defer gpa.free(got);
        try testing.expectEqual(@as(usize, 11 * 128 * 2), got.len);
        try expectFinite(got);
        for (amplitudes, 0..) |amplitude, channel| {
            const e = channelEnergy(got, channel);
            if (amplitude == 0) try testing.expectEqual(@as(f64, 0), e) else try testing.expect(e > 1);
        }
    }
}

/// The seeks of a decoder to every `step` frames must give the samples of `want`.
fn expectSeeksMatch(dec: *Decoder, want: []const f32, channels: usize, step: usize) !void {
    const total = want.len / channels;
    var buf: [128]f32 = undefined;
    var t: usize = 0;
    while (t < total) : (t += step) {
        try dec.seek(t);
        const n = try dec.read(buf[0 .. 64 * channels]);
        const frames = @min(n, total - t);
        try testing.expect(n != 0);
        try testing.expectEqualSlices(f32, want[t * channels ..][0 .. frames * channels], buf[0 .. frames * channels]);
    }
}

test "a chain with a start offset in the first link has exact lengths and seeks" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[0].file);
    defer freePks(gpa, pks);
    shiftGranules(pks, 50, false);
    const shifted = try muxPks(gpa, pks, 1);
    defer gpa.free(shifted);
    const plain_pks = try demux(gpa, vectors[0].file);
    defer freePks(gpa, plain_pks);
    const plain = try muxPks(gpa, plain_pks, 2);
    defer gpa.free(plain);
    const bytes = try std.mem.concat(gpa, u8, &.{ shifted, plain });
    defer gpa.free(bytes);
    const want = try decodeAll(gpa, bytes, .{});
    defer gpa.free(want);
    try testing.expectEqual(@as(usize, 16000), want.len);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 16000), dec.info().total_frames);
    try expectSeeksMatch(&dec, want, 1, 997);
    try dec.seek(8000);
    try testing.expectEqual(want[8000], (try readOne(&dec)));
    try testing.expectEqual(@as(u32, 0), dec.chain.codec.rescans);
}

fn readOne(dec: *Decoder) !f32 {
    var one: [1]f32 = undefined;
    try testing.expectEqual(@as(usize, 1), try dec.read(&one));
    return one[0];
}

test "seeks across a damaged packet match a linear read" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    pks[first_audio + 20].data[0] = 0xff;
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    const want = try decodeAll(gpa, bytes, .{});
    defer gpa.free(want);
    try testing.expectEqual(@as(usize, 44100 * 2), want.len);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try expectSeeksMatch(&dec, want, 2, 64);
    try testing.expectEqual(@as(u32, 0), dec.chain.codec.rescans);
    // Each seek over the damaged packet counts it again, so the count is not exact.
    // The skips during a seek are not counted.
    try testing.expectEqual(@as(u32, 0), dec.stats().resyncs);
    var strict_input: io.Input = .init(.{ .bytes = bytes });
    var strict: Decoder = try .initOptions(gpa, &strict_input, .{ .on_bad_packet = .fail });
    defer strict.deinit();
    var failures: usize = 0;
    var t: u64 = 0;
    while (t < 44100) : (t += 500) {
        strict.seek(t) catch |err| {
            try testing.expectEqual(error.BadData, err);
            failures += 1;
        };
    }
    try testing.expect(failures > 0);
}

test "the frame count of a damaged stream agrees with its granules" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    // Several damaged packets, one of them the last of its page.
    for ([_]usize{ 5, 20, 21, 40 }) |i| pks[first_audio + i].data[0] = 0xff;
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const got = try helpers.readAll(gpa, &dec, 1000);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 4), dec.stats().resyncs);
    try testing.expectEqual(@as(?u64, 44100), dec.info().total_frames);
    try testing.expectEqual(@as(usize, 44100 * 2), got.len);
    try expectFinite(got);
}

test "seeks after a cut start longer than the packet match a linear read" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[0].file);
    defer freePks(gpa, pks);
    shiftGranules(pks, -300, true);
    // The first granule is 44 below 0 and its packet gives 256 frames, so all of them are cut.
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    const want = try decodeAll(gpa, bytes, .{});
    defer gpa.free(want);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, want.len), dec.info().total_frames);
    try expectSeeksMatch(&dec, want, 1, 251);
    try testing.expectEqual(@as(u32, 0), dec.chain.codec.rescans);
}

test "a bad packet in the first page counts like the read" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[0].file);
    defer freePks(gpa, pks);
    // The second audio packet is lost after the first one, so the third one primes the overlap
    // again. The page has no frames before its granule 512.
    pks[first_audio].granule = -1;
    pks[first_audio + 1].data[0] = 0xff;
    pks[first_audio + 1].granule = -1;
    const bytes = try muxPks(gpa, pks, 1);
    defer gpa.free(bytes);
    const want = try decodeAll(gpa, bytes, .{});
    defer gpa.free(want);
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, want.len), dec.info().total_frames);
    try expectSeeksMatch(&dec, want, 1, 333);
}

test "a packet over the limit is skipped and counted" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    const want = try decodeAll(gpa, vectors[1].file, .{});
    defer gpa.free(want);
    const at = first_audio + 30;
    const big = try gpa.alloc(Pk, pks.len + 1);
    defer gpa.free(big);
    @memcpy(big[0..at], pks[0..at]);
    const junk = try gpa.alloc(u8, 150000);
    defer gpa.free(junk);
    @memset(junk, 0);
    big[at] = .{ .data = junk, .granule = -1, .eos = false };
    @memcpy(big[at + 1 ..], pks[at..]);
    const bytes = try muxPks(gpa, big, 1);
    defer gpa.free(bytes);

    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const got = try helpers.readAll(gpa, &dec, 1000);
    defer gpa.free(got);
    try testing.expectEqual(@as(u32, 1), dec.stats().resyncs);
    try testing.expectEqual(want.len, got.len);
    try testing.expectEqualSlices(f32, want[want.len - 20000 ..], got[got.len - 20000 ..]);
    // The seeks pass the dropped packet and do not count it again.
    try expectSeeksMatch(&dec, got, 2, 997);
    try testing.expectEqual(@as(u32, 1), dec.stats().resyncs);

    var strict_input: io.Input = .init(.{ .bytes = bytes });
    var strict: Decoder = try .initOptions(gpa, &strict_input, .{ .on_bad_packet = .fail });
    defer strict.deinit();
    var buf: [2000]f32 = undefined;
    const result = while (true) {
        const n = strict.read(&buf) catch |err| break err;
        if (n == 0) break error.TestUnexpectedResult;
    };
    try testing.expectEqual(error.BadData, result);
}

test "differential random seeks and partial reads" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0xabc);
    const r = prng.random();
    for (vectors) |v| {
        const want = try decodeAll(gpa, v.file, .{});
        defer gpa.free(want);
        var input: io.Input = .init(.{ .bytes = v.file });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        const ch: usize = v.channels;
        const total = want.len / ch;
        for (0..200) |_| {
            const t = r.uintAtMost(usize, total);
            try dec.seek(t);
            var pos = t;
            for (0..1 + r.uintLessThan(usize, 4)) |_| {
                var buf: [4096]f32 = undefined;
                const frames = 1 + r.uintLessThan(usize, 4096 / ch);
                const n = try dec.read(buf[0 .. frames * ch]);
                try testing.expectEqualSlices(f32, want[pos * ch ..][0 .. n * ch], buf[0 .. n * ch]);
                if (n == 0) try testing.expectEqual(total, pos);
                pos += n;
            }
        }
    }
    var input: io.Input = .init(.{ .bytes = chain_file });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const parts = try readTwoLinks(gpa, &dec);
    defer gpa.free(parts.first);
    defer gpa.free(parts.second);
    for (0..200) |_| {
        const t = r.uintLessThan(usize, 22050 + 11025);
        try dec.seek(t);
        var buf: [600]f32 = undefined;
        const ch: usize = dec.info().channels;
        const n = dec.read(buf[0 .. 600 / ch * ch]) catch |e| switch (e) {
            error.StreamChanged => 0,
            else => return e,
        };
        const want = if (t < 22050) parts.first[t * 2 ..] else parts.second[t - 22050 ..];
        try testing.expectEqualSlices(f32, want[0 .. n * ch], buf[0 .. n * ch]);
    }
}

test "a link with bad headers does not turn off the length and the seeks of the others" {
    const gpa = testing.allocator;
    const bad_pks = try demux(gpa, vectors[0].file);
    defer freePks(gpa, bad_pks);
    bad_pks[2].data = try gpa.realloc(bad_pks[2].data, 30);
    const bad = try muxPks(gpa, bad_pks, 2);
    defer gpa.free(bad);
    const bytes = try std.mem.concat(gpa, u8, &.{ vectors[0].file, bad, vectors[0].file });
    defer gpa.free(bytes);
    const single = try decodeAll(gpa, vectors[0].file, .{});
    defer gpa.free(single);

    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: Decoder = try .init(gpa, &input);
    defer dec.deinit();
    // The bad link counts its last granule.
    try testing.expectEqual(@as(?u64, 24000), dec.info().total_frames);
    try dec.seek(16000 + 123);
    var buf: [200]f32 = undefined;
    try testing.expectEqual(@as(usize, 200), try dec.read(&buf));
    try testing.expectEqualSlices(f32, single[123..][0..200], &buf);
    try dec.seek(77);
    try testing.expectEqual(@as(usize, 200), try dec.read(&buf));
    try testing.expectEqualSlices(f32, single[77..][0..200], &buf);
}

/// Writes the packets on pages of at most 8 segments, so that a big packet spans many pages.
fn smallPages(gpa: std.mem.Allocator, pks: []const Pk) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lacing: std.ArrayList(u8) = .empty;
    defer lacing.deinit(gpa);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var page: [packets.max_page_size]u8 = undefined;
    var sequence: u32 = 0;
    var granule: i64 = -1;
    var continued = false;
    for (pks, 0..) |p, index| {
        var rest = p.data;
        while (true) {
            const take = @min(rest.len, 255);
            try lacing.append(gpa, @intCast(take));
            try body.appendSlice(gpa, rest[0..take]);
            rest = rest[take..];
            const done = take < 255;
            if (done and p.granule != -1) granule = p.granule;
            const last = done and index + 1 == pks.len;
            // The first packet and a packet with a granule end their page.
            if (lacing.items.len == 8 or last or (done and (index == 0 or p.granule != -1))) {
                const head: packets.Header = .{
                    .flags = .{ .continued = continued, .bos = sequence == 0, .eos = last },
                    .granule = granule,
                    .serial = 7,
                    .sequence = sequence,
                };
                const n = try packets.buildPage(&page, head, lacing.items, body.items);
                try out.appendSlice(gpa, page[0..n]);
                sequence += 1;
                granule = -1;
                continued = !done;
                lacing.clearRetainingCapacity();
                body.clearRetainingCapacity();
            }
            if (done) break;
        }
    }
    return out.toOwnedSlice(gpa);
}

test "a packet over many pages is not a lost page" {
    const gpa = testing.allocator;
    const pks = try demux(gpa, vectors[1].file);
    defer freePks(gpa, pks);
    const plain_bytes = try smallPages(gpa, pks);
    defer gpa.free(plain_bytes);
    const plain = try decodeAll(gpa, plain_bytes, .{});
    defer gpa.free(plain);
    try testing.expectEqual(@as(usize, 44100 * 2), plain.len);

    // One packet gets 12000 zero bytes at its end, which the decoder does not read. It spans
    // more than three pages of 8 segments.
    const at = first_audio + 20;
    const old = pks[at].data.len;
    pks[at].data = try gpa.realloc(pks[at].data, old + 12000);
    @memset(pks[at].data[old..], 0);
    const small = try smallPages(gpa, pks);
    defer gpa.free(small);

    for ([_][]const u8{small}) |bytes| {
        var input: io.Input = .init(.{ .bytes = bytes });
        var dec: Decoder = try .init(gpa, &input);
        defer dec.deinit();
        const got = try helpers.readAll(gpa, &dec, 1000);
        defer gpa.free(got);
        try testing.expectEqualSlices(f32, plain, got);
        try testing.expectEqual(@as(u32, 0), dec.stats().resyncs);
        try testing.expectEqual(@as(?u64, 44100), dec.info().total_frames);
        try expectSeeksMatch(&dec, plain, 2, 211);
        try testing.expectEqual(@as(u32, 0), dec.chain.codec.rescans);
    }
}
