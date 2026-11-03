//! The Vorbis encoder. It writes a short and a long block size, one floor 1 per channel,
//! residue 2 over all channels and lossless coupling of channel pairs, with the codebooks of
//! `setup.build`. A sudden attack in the input gets short blocks.
const std = @import("std");
const codec = @import("../../codec.zig");
const io = @import("../io.zig");
const packets = @import("../ogg.zig");
const codebook = @import("codebook.zig");
const decode = @import("decode.zig");
const floor = @import("floor.zig");
const header = @import("header.zig");
const mdct = @import("mdct.zig");
const psy = @import("psy.zig");
const setup_mod = @import("setup.zig");
const window = @import("window.zig");
const helpers = @import("../testing.zig");
const vt = @import("testing.zig");
const testing = std.testing;

const vendor = "Chorus";
/// The floor does not go under this level, and a channel that stays under it has no floor.
const absolute_floor_db: f64 = -90.0;
/// The dB step of one floor table index.
const db_per_index = 140.0 / 256.0;
/// Input samples are clamped to this size, so that all the arithmetic stays finite.
const max_input: f32 = 4;
/// The floor does not fall more than the margin plus this many dB under the loudest line.
const dynamic_range_db: f64 = 30.0;
/// A spectrum under this peak has no floor. It is 0.4 of the absolute floor.
const gate: f32 = 0.4 * std.math.pow(f32, 10, @as(f32, absolute_floor_db) / 20);

pub const EncodeOptions = struct {
    /// The oggenc scale, -1 to 10. A value outside it is clamped.
    quality: f32 = 4,
    serial: u32 = 0,
};

pub const Stats = struct {
    short_blocks: u64 = 0,
    long_blocks: u64 = 0,
    /// Spectrum lines whose level was cut to the largest level of the quality.
    clipped_lines: u64 = 0,
};

/// The coded value of a floor 1 post that moves from `predicted` to `final`, both in
/// 0 to `range - 1` and different. The decoder rule is in the specification (7.2.4).
pub fn wrapDeviation(final: i32, predicted: i32, range: i32) i32 {
    const headroom = @min(range - predicted, predicted);
    const d = final - predicted;
    if (d < 0) {
        return if (d < -headroom) headroom - d - 1 else -1 - 2 * d;
    }
    return if (d >= headroom) d + headroom else 2 * d;
}

/// Lossless coupling of two integers. The magnitude slot of the decoder gets the first
/// value of the result, the angle slot the second.
pub fn couple(l: i32, r: i32) [2]i32 {
    var m: i32 = undefined;
    var a: i32 = undefined;
    if (@abs(l) > @abs(r)) {
        a = if (l > 0) l - r else r - l;
        m = l;
    } else {
        a = if (r > 0) l - r else r - l;
        m = r;
    }
    if (a >= 2 * @as(i32, @intCast(@abs(m)))) {
        a = -a;
        m = -m;
    }
    return .{ m, a };
}

/// The first class whose limit holds `peak`. The last limit must hold it.
pub fn classFor(limits: []const u16, peak: u32) usize {
    for (limits, 0..) |limit, class| {
        if (peak <= limit) return class;
    }
    unreachable;
}

/// The residue level of a spectrum value `x` under a floor value `g`, cut to `limit`.
pub fn quantize(x: f32, g: f32, limit: f32) struct { level: i32, clipped: bool } {
    const scaled = @round(x / g);
    return .{ .level = @intFromFloat(std.math.clamp(scaled, -limit, limit)), .clipped = @abs(scaled) > limit };
}

/// Sets `out[c]` to the input channel that the Vorbis channel `c` reads. The input is in
/// WAVE order, the order of the bits of `mask`. A mask of 0 means the default mask of the
/// channel count. The Vorbis layout of 3 to 8 channels needs the speakers it names, and a
/// back pair can be a side pair for 4 to 6 channels. A stream of more than 8 channels ignores
/// the mask. A mask for 1 or 2 channels needs that many bits and keeps the order of the input.
/// Any other mask gives error.Unsupported.
pub fn channelMap(out: []u8, mask: codec.ChannelMask) error{Unsupported}!void {
    const channels = out.len;
    const bits: u32 = @bitCast(mask);
    if (bits == 0 or channels > 8) {
        for (out, 0..) |*o, c| o.* = @intCast(decode.waveChannel(channels, c));
        return;
    }
    if (bits >> 18 != 0 or @popCount(bits) != channels) return error.Unsupported;
    const fl = 0;
    const fr = 1;
    const fc = 2;
    const lfe = 3;
    const bl = 4;
    const br = 5;
    const bc = 8;
    const sl = 9;
    const sr = 10;
    // The speakers of each Vorbis channel, the first one that the mask has wins.
    const roles: []const [2]u5 = switch (channels) {
        1, 2 => &.{},
        3 => &.{ .{ fl, fl }, .{ fc, fc }, .{ fr, fr } },
        4 => &.{ .{ fl, fl }, .{ fr, fr }, .{ bl, sl }, .{ br, sr } },
        5 => &.{ .{ fl, fl }, .{ fc, fc }, .{ fr, fr }, .{ bl, sl }, .{ br, sr } },
        6 => &.{ .{ fl, fl }, .{ fc, fc }, .{ fr, fr }, .{ bl, sl }, .{ br, sr }, .{ lfe, lfe } },
        7 => &.{ .{ fl, fl }, .{ fc, fc }, .{ fr, fr }, .{ sl, sl }, .{ sr, sr }, .{ bc, bc }, .{ lfe, lfe } },
        else => &.{ .{ fl, fl }, .{ fc, fc }, .{ fr, fr }, .{ sl, sl }, .{ sr, sr }, .{ bl, bl }, .{ br, br }, .{ lfe, lfe } },
    };
    if (roles.len == 0) {
        for (out, 0..) |*o, c| o.* = @intCast(c);
        return;
    }
    var used: u32 = 0;
    for (out, roles) |*o, role| {
        const bit: u5 = if (bits >> role[0] & 1 == 1) role[0] else if (bits >> role[1] & 1 == 1) role[1] else return error.Unsupported;
        if (used >> bit & 1 == 1) return error.Unsupported;
        used |= @as(u32, 1) << bit;
        o.* = @intCast(@popCount(bits & ((@as(u32, 1) << bit) - 1)));
    }
}

/// The bits of one packet, in a buffer that was sized for the largest packet.
const Bits = struct {
    buf: []u8,
    len: usize = 0,
    acc: u64 = 0,
    count: u6 = 0,

    fn reset(self: *Bits) void {
        self.len = 0;
        self.acc = 0;
        self.count = 0;
    }

    fn put(self: *Bits, value: u32, bits: u6) void {
        self.acc |= @as(u64, value) << self.count;
        self.count += bits;
        while (self.count >= 8) {
            self.buf[self.len] = @truncate(self.acc);
            self.len += 1;
            self.acc >>= 8;
            self.count -= 8;
        }
    }

    /// Writes the codeword of `entry`. The first bit of the code goes first.
    fn code(self: *Bits, book: *const codebook.Codebook, entry: u32) void {
        const length = book.lengths[entry];
        std.debug.assert(length != 0);
        self.put(@bitReverse(book.codes[entry]) >> @intCast(32 - @as(u32, length)), @intCast(length));
    }

    fn bytes(self: *Bits) []const u8 {
        if (self.count > 0) {
            self.buf[self.len] = @truncate(self.acc);
            self.len += 1;
            self.acc = 0;
            self.count = 0;
        }
        return self.buf[0..self.len];
    }
};

/// The result of fitting a floor to one channel.
const FloorCoded = struct {
    used: bool = false,
    /// Y[0], Y[1], then the wrapped value of each other post.
    values: [header.max_floor1_points]u16 = undefined,
    final_y: [header.max_floor1_points]i32 = undefined,
    step2: [header.max_floor1_points]bool = undefined,
};

/// What one block size needs. The mode number of the size is its index in `Encoder.sizes`.
const Size = struct {
    n: usize,
    lines: usize,
    transform: mdct.Mdct,
    model: psy.Model,
    /// The largest level that each residue class holds.
    class_limits: []const u16,
    /// The first line above the lowpass.
    end_lines: usize,
};

/// Spare samples at the end of the input buffer.
const slack = 16;

/// Writes interleaved f32 frames in WAVE channel order as Ogg Vorbis.
///
/// Blocks are long, from 512 to 2048 samples by the rate, and short after an attack. The
/// headers go out with the first `write` or with `finish`. `init` allocates all the memory,
/// so `write` and `finish` allocate only inside the writer. `finish` writes the last page,
/// which holds the last packet alone, and its granule is the number of frames that were written.
pub const Encoder = struct {
    arena: std.heap.ArenaAllocator,
    out: *std.Io.Writer,
    ogg: packets.PacketWriter,
    id_packet: [30]u8,
    comment_packet: []const u8,
    setup_packet: []const u8,
    headers_written: bool = false,
    finished: bool = false,
    /// False makes every block long. Tests use it. It can change between writes, and the stream
    /// stays valid.
    switching: bool = true,

    setup: header.Setup,
    tun: setup_mod.Tuning,
    channels: usize,
    /// The input channel (WAVE order) that each Vorbis channel reads.
    input_map: []const u8,
    /// The short size, then the long size.
    sizes: [2]Size,
    /// The window of a long block, by the long flags of the previous and the next block.
    long_windows: [4][]const f32,
    short_window: []const f32,
    /// The largest level that one channel codes.
    level_limit: f32,

    /// The input of each channel as a time line of `cap` samples from the time `base`. Time 0 is
    /// the first input frame. The times before 0 and after the input hold a mirror of it.
    buf: []f32,
    cap: usize,
    base: i64,
    total_in: u64 = 0,
    /// The centre of the block to write, as a time. The block 0 is at 0.
    centre: i64 = 0,
    cur_long: bool = true,
    prev_long: bool = true,
    packets_out: u64 = 0,
    stat: Stats = .{},

    work: []f32,
    spectrum: []f32,
    curve: []f32,
    levels: []i32,
    interleaved: []i32,
    classes: []u8,
    coded: []FloorCoded,
    bits: Bits,

    pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, options: EncodeOptions, info: codec.Info) codec.EncoderInitError!Encoder {
        if (info.channels == 0 or info.rate == 0 or std.math.isNan(options.quality)) return error.Unsupported;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const built = setup_mod.build(a, .{ .channels = info.channels, .rate = info.rate, .quality = options.quality }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadSetup => return error.Unsupported,
        };
        const channels: usize = info.channels;
        const long: usize = built.id.blocksize_1;
        const short: usize = built.id.blocksize_0;
        const tun = built.tuning;

        const setup_packet = setup_mod.writeSetup(a, &built.setup) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadSetup => return error.Unsupported,
        };
        const comment_packet = try setup_mod.writeComment(a, vendor);

        const input_map = try a.alloc(u8, channels);
        try channelMap(input_map, info.mask);

        var sizes: [2]Size = undefined;
        var max_bits: usize = 0;
        for (&sizes, [2]usize{ short, long }, 0..) |*sz, n, mode| {
            const res = built.setup.residues[mode];
            const limits = try a.alloc(u16, res.classifications);
            for (limits, res.books) |*limit, row| {
                limit.* = if (row[0] < 0) 0 else @intCast((built.setup.books[@intCast(row[0])].lookup_values - 1) / 2);
            }
            sz.* = .{
                .n = n,
                .lines = n / 2,
                .transform = mdct.Mdct.init(a, n) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadSize => return error.Unsupported,
                },
                .model = try .init(a, built.setup.floors[mode].one, info.rate, @intCast(n / 2), tun.listen_spl),
                .class_limits = limits,
                .end_lines = tun.endLines(info.rate, @intCast(n / 2)),
            };
            const parts = res.end / res.partition_size;
            max_bits = @max(max_bits, @as(usize, res.end) * 32 + (parts + 1) * 32 + channels * (header.max_floor1_points * 64 + 64));
        }

        const slopes = try window.Windows.init(a, short, long);
        var long_windows: [4][]const f32 = undefined;
        for (&long_windows, 0..) |*w, flags| {
            const out = try a.alloc(f32, long);
            slopes.fill(out, true, flags & 2 != 0, flags & 1 != 0);
            w.* = out;
        }
        const short_window = try a.alloc(f32, short);
        slopes.fill(short_window, false, true, true);

        const cap = 5 * long + slack;
        const buf = try a.alloc(f32, channels * cap);
        @memset(buf, 0);
        const lines = long / 2;
        const parts_max = @max(built.setup.residues[0].end / built.setup.residues[0].partition_size, built.setup.residues[1].end / built.setup.residues[1].partition_size);
        const work = try a.alloc(f32, long);
        const spectrum = try a.alloc(f32, lines);
        const curve = try a.alloc(f32, lines);
        const levels = try a.alloc(i32, channels * lines);
        const interleaved = try a.alloc(i32, channels * lines);
        const classes = try a.alloc(u8, parts_max);
        const coded = try a.alloc(FloorCoded, channels);
        const bits_buf = try a.alloc(u8, (max_bits + 7) / 8 + 16);
        const ogg = try packets.PacketWriter.init(gpa, writer, options.serial, .{});

        return .{
            .arena = arena,
            .out = writer,
            .ogg = ogg,
            .id_packet = setup_mod.writeIdentification(built.id),
            .comment_packet = comment_packet,
            .setup_packet = setup_packet,
            .setup = built.setup,
            .tun = tun,
            .channels = channels,
            .input_map = input_map,
            .sizes = sizes,
            .long_windows = long_windows,
            .short_window = short_window,
            .level_limit = tun.levelLimit(),
            .buf = buf,
            .cap = cap,
            .base = -2 * @as(i64, @intCast(long)),
            .work = work,
            .spectrum = spectrum,
            .curve = curve,
            .levels = levels,
            .interleaved = interleaved,
            .classes = classes,
            .coded = coded,
            .bits = .{ .buf = bits_buf },
        };
    }

    /// Writes to a file. The stream has no size in a header, so the file is written in one pass.
    pub fn initFile(gpa: std.mem.Allocator, file: *std.Io.File.Writer, options: EncodeOptions, info: codec.Info) codec.EncoderInitError!Encoder {
        return init(gpa, &file.interface, options, info);
    }

    pub fn deinit(self: *Encoder) void {
        self.ogg.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn stats(self: *const Encoder) Stats {
        return self.stat;
    }

    /// `frames` holds whole interleaved frames. A sample that is not finite counts as 0, and a
    /// sample past 4 in size is cut to 4. A partial frame or a call after `finish` gives
    /// error.Unsupported.
    pub fn write(self: *Encoder, frames: []const f32) codec.WriteError!void {
        if (self.finished or frames.len % self.channels != 0) return error.Unsupported;
        try self.writeHeaders();
        const total = frames.len / self.channels;
        var at: usize = 0;
        while (at < total) {
            self.slide(@intCast(self.sizes[1].n));
            const room = self.cap - self.index(self.end());
            const take = @min(total - at, room);
            const start = self.index(self.end());
            for (0..self.channels) |c| {
                const dst = self.line(c)[start..][0..take];
                const src = self.input_map[c];
                for (dst, 0..) |*d, i| {
                    const v = frames[(at + i) * self.channels + src];
                    d.* = if (std.math.isFinite(v)) std.math.clamp(v, -max_input, max_input) else 0;
                }
            }
            at += take;
            self.total_in += take;
            try self.drain();
        }
    }

    /// Writes the blocks that the end of the input needs and the last page. The stream is
    /// complete after this.
    pub fn finish(self: *Encoder) codec.WriteError!void {
        if (self.finished) return;
        self.finished = true;
        try self.writeHeaders();
        self.slide(1);
        self.fillTail();
        while (true) {
            const last = self.centre >= self.end();
            try self.step(true);
            if (last) break;
        }
        try self.ogg.finish();
        self.out.flush() catch return error.WriteFailed;
        self.finished = true;
    }

    /// The time after the last input frame.
    fn end(self: *const Encoder) i64 {
        return @intCast(self.total_in);
    }

    fn index(self: *const Encoder, time: i64) usize {
        return @intCast(time - self.base);
    }

    fn line(self: *Encoder, c: usize) []f32 {
        return self.buf[c * self.cap ..][0..self.cap];
    }

    /// Drops the old input when the oldest time that is still needed is `min_drop` or more
    /// ahead of `base`. A block needs the input from two long blocks before its centre.
    fn slide(self: *Encoder, min_drop: i64) void {
        const want = self.centre - 2 * @as(i64, @intCast(self.sizes[1].n));
        const drop = want - self.base;
        if (drop < min_drop or drop <= 0) return;
        const have = self.index(self.end());
        const shift: usize = @intCast(drop);
        for (0..self.channels) |c| {
            const b = self.line(c);
            std.mem.copyForwards(f32, b[0 .. have - shift], b[shift..have]);
        }
        self.base = want;
    }

    /// The offset of the sample that a mirror at the edge puts `k` places past the edge, from the
    /// edge, for `m` samples of input.
    fn bounce(k: usize, m: usize) usize {
        const r = k % (2 * m);
        return if (r < m) r else 2 * m - 1 - r;
    }

    /// Fills the times before 0 with a mirror of the start of the input.
    fn fillHead(self: *Encoder) void {
        const m: usize = @intCast(self.total_in);
        const long: i64 = @intCast(self.sizes[1].n);
        var t: i64 = -long;
        while (t < 0) : (t += 1) {
            const k: usize = @intCast(-1 - t);
            for (0..self.channels) |c| {
                const b = self.line(c);
                b[self.index(t)] = if (m == 0) 0 else b[self.index(@intCast(bounce(k, m)))];
            }
        }
    }

    /// Fills two long blocks after the input with a mirror of its end.
    fn fillTail(self: *Encoder) void {
        const m: usize = @intCast(self.total_in);
        const count = 2 * self.sizes[1].n;
        const start = self.index(self.end());
        std.debug.assert(start + count <= self.cap);
        for (0..self.channels) |c| {
            const b = self.line(c);
            for (0..count) |k| {
                b[start + k] = if (m == 0) 0 else b[self.index(self.end() - 1 - @as(i64, @intCast(bounce(k, m))))];
            }
        }
    }

    /// Writes the blocks that the input holds enough data for.
    fn drain(self: *Encoder) codec.WriteError!void {
        while (self.centre + @as(i64, @intCast(self.sizes[1].n)) <= self.end()) try self.step(false);
    }

    /// Writes the block at `centre`. The block after it is long unless an attack is near.
    fn step(self: *Encoder, finishing: bool) codec.WriteError!void {
        if (self.packets_out == 0) self.fillHead();
        const next_long = self.nextIsLong();
        const last = finishing and self.centre >= self.end();
        if (last and self.packets_out > 0) try self.ogg.flush();
        const granule: u64 = if (last) self.total_in else @intCast(self.centre);
        const data = self.encodeBlock(self.cur_long, self.prev_long, next_long);
        try self.ogg.writePacket(data, @intCast(granule));
        self.packets_out += 1;
        if (self.cur_long) self.stat.long_blocks += 1 else self.stat.short_blocks += 1;
        const here = self.sizes[@intFromBool(self.cur_long)].n;
        const there = self.sizes[@intFromBool(next_long)].n;
        self.centre += @intCast(here / 4 + there / 4);
        self.prev_long = self.cur_long;
        self.cur_long = next_long;
    }

    /// True when the block after the one at `centre` can be long. A long block there would
    /// cover the next long block size of input, and an attack in it needs short blocks.
    fn nextIsLong(self: *Encoder) bool {
        if (!self.switching) return true;
        const seg: i64 = @intCast(self.sizes[0].n);
        const stop = @min(self.centre + @as(i64, @intCast(self.sizes[1].n)), self.end());
        if (stop <= self.centre) return true;
        const from = self.index(self.centre - 2 * seg);
        const to = self.index(stop);
        for (0..self.channels) |c| {
            if (psy.hasAttack(self.line(c)[from..to], @intCast(2 * seg), @intCast(seg))) return false;
        }
        return true;
    }

    fn writeHeaders(self: *Encoder) codec.WriteError!void {
        if (self.headers_written) return;
        self.headers_written = true;
        try self.ogg.writePacket(&self.id_packet, 0);
        try self.ogg.flush();
        try self.ogg.writePacket(self.comment_packet, 0);
        try self.ogg.writePacket(self.setup_packet, 0);
        try self.ogg.flush();
    }

    fn encodeBlock(self: *Encoder, long: bool, prev_long: bool, next_long: bool) []const u8 {
        const mode: usize = @intFromBool(long);
        const sz = &self.sizes[mode];
        const f = self.setup.floors[mode].one;
        const res = self.setup.residues[mode];
        const mapping = self.setup.mappings[mode];
        const lines = sz.lines;
        const win = if (long) self.long_windows[@as(usize, @intFromBool(prev_long)) << 1 | @intFromBool(next_long)] else self.short_window;
        const start = self.index(self.centre - @as(i64, @intCast(sz.n / 2)));

        var any_used = false;
        for (0..self.channels) |c| {
            const block = self.line(c)[start..][0..sz.n];
            const work = self.work[0..sz.n];
            for (work, block, win) |*o, s, w| o.* = s * w;
            sz.transform.forward(work, self.spectrum[0..lines]);
            const levels = self.levels[c * lines ..][0..lines];
            self.fitFloor(sz, f, &self.coded[c]);
            if (self.coded[c].used) {
                any_used = true;
                for (levels, self.spectrum[0..lines], self.curve[0..lines], 0..) |*q, x, g, k| {
                    if (k >= sz.end_lines) {
                        q.* = 0;
                        continue;
                    }
                    const r = quantize(x, g, self.level_limit);
                    q.* = r.level;
                    self.stat.clipped_lines += @intFromBool(r.clipped);
                }
            } else {
                @memset(levels, 0);
            }
        }

        self.bits.reset();
        self.bits.put(0, 1);
        self.bits.put(@intFromBool(long), 1);
        if (long) {
            self.bits.put(@intFromBool(prev_long), 1);
            self.bits.put(@intFromBool(next_long), 1);
        }
        for (self.coded[0..self.channels]) |*coded| self.writeFloor(f, coded);
        if (any_used) {
            for (mapping.coupling) |pair_def| {
                const m = self.levels[@as(usize, pair_def.magnitude) * lines ..][0..lines];
                const a = self.levels[@as(usize, pair_def.angle) * lines ..][0..lines];
                for (m, a) |*lv, *rv| {
                    const pair = couple(lv.*, rv.*);
                    lv.* = pair[0];
                    rv.* = pair[1];
                }
            }
            for (0..self.channels) |c| {
                for (self.levels[c * lines ..][0..lines], 0..) |q, k| self.interleaved[k * self.channels + c] = q;
            }
            self.writeResidue(res, sz);
        }
        return self.bits.bytes();
    }

    /// Sets the posts of `out` for the spectrum, and the curve of the decoder for it.
    fn fitFloor(self: *Encoder, sz: *const Size, f: header.Floor1, out: *FloorCoded) void {
        const lines = sz.lines;
        const spectrum = self.spectrum[0..lines];
        var peak: f32 = 0;
        for (spectrum) |x| peak = @max(peak, @abs(x));
        out.used = peak >= gate;
        if (!out.used) return;

        const range: i32 = f.range();
        const mult: f64 = @floatFromInt(f.multiplier);
        const peak_db: f64 = 20 * std.math.log10(@as(f64, peak));
        const margin: f64 = self.tun.margin_db;
        const points = f.x.len;
        var levels: [header.max_floor1_points]f64 = undefined;
        var masks: [header.max_floor1_points]f64 = undefined;
        for (sz.model.bands, levels[0..points]) |band, *level| {
            var sum: f64 = 0;
            for (spectrum[band.start..band.stop]) |v| {
                const sq = @as(f64, v) * v;
                sum += sq * sq;
            }
            const mean = sum / @as(f64, @floatFromInt(band.stop - band.start));
            level.* = if (mean > 0) 5 * std.math.log10(mean) else -300;
        }
        sz.model.thresholds(levels[0..points], margin, masks[0..points]);
        var targets: [header.max_floor1_points]i32 = undefined;
        for (masks[0..points], targets[0..points]) |mask, *t| {
            const target_db = @max(@max(mask, peak_db - margin - dynamic_range_db), absolute_floor_db);
            const level_index = 255 + target_db / db_per_index;
            t.* = std.math.clamp(@as(i32, @intFromFloat(@round(level_index / mult))), 0, range - 1);
        }

        const tolerance: i32 = self.tun.tolerance;
        out.step2[0] = true;
        out.step2[1] = true;
        out.final_y[0] = targets[0];
        out.final_y[1] = targets[1];
        out.values[0] = @intCast(targets[0]);
        out.values[1] = @intCast(targets[1]);
        for (2..points) |i| {
            const lo = f.low[i];
            const hi = f.high[i];
            const predicted = floor.renderPoint(f.x[lo], out.final_y[lo], f.x[hi], out.final_y[hi], f.x[i]);
            const deviation = targets[i] - predicted;
            if (@abs(deviation) <= tolerance) {
                out.values[i] = 0;
                out.final_y[i] = predicted;
                out.step2[i] = false;
            } else {
                out.values[i] = @intCast(wrapDeviation(targets[i], predicted, range));
                out.final_y[i] = targets[i];
                out.step2[i] = true;
                out.step2[lo] = true;
                out.step2[hi] = true;
            }
        }
        floor.floor1Curve(f, out.final_y[0..points], out.step2[0..points], self.curve[0..lines]);
    }

    fn writeFloor(self: *Encoder, f: header.Floor1, coded: *const FloorCoded) void {
        if (!coded.used) return self.bits.put(0, 1);
        self.bits.put(1, 1);
        const width: u6 = codebook.ilog(@as(u32, f.range()) - 1);
        self.bits.put(coded.values[0], width);
        self.bits.put(coded.values[1], width);
        var at: usize = 2;
        for (f.partition_classes) |class_index| {
            const class = f.classes[class_index];
            const values = coded.values[at..][0..class.dimensions];
            at += class.dimensions;
            var picked: [8]u8 = @splat(0);
            if (class.subclasses > 0) {
                var cval: u32 = 0;
                for (values, 0..) |v, k| {
                    for (0..@as(usize, 1) << @intCast(class.subclasses)) |sub| {
                        const book = class.subclass_books[sub];
                        const entries: u32 = if (book < 0) 1 else self.setup.books[@intCast(book)].entries;
                        if (v < entries) {
                            picked[k] = @intCast(sub);
                            break;
                        }
                    }
                    cval |= @as(u32, picked[k]) << @intCast(k * class.subclasses);
                }
                self.bits.code(&self.setup.books[class.masterbook], cval);
            }
            for (values, 0..) |v, k| {
                const book = class.subclass_books[picked[k]];
                if (book >= 0) self.bits.code(&self.setup.books[@intCast(book)], v);
            }
        }
    }

    fn writeResidue(self: *Encoder, res: header.Residue, sz: *const Size) void {
        const size = res.partition_size;
        const parts = res.end / size;
        const per_word = self.setup.books[res.classbook].dimensions;
        const classes = self.classes;
        for (0..parts) |p| {
            var peak: u32 = 0;
            for (self.interleaved[p * size ..][0..size]) |q| peak = @max(peak, @abs(q));
            std.debug.assert(peak <= sz.class_limits[sz.class_limits.len - 1]);
            classes[p] = @intCast(classFor(sz.class_limits, peak));
        }
        var part: usize = 0;
        while (part < parts) : (part += per_word) {
            var word: u32 = 0;
            for (0..per_word) |i| {
                word = word * res.classifications + if (part + i < parts) classes[part + i] else 0;
            }
            self.bits.code(&self.setup.books[res.classbook], word);
            for (part..@min(parts, part + per_word)) |p| {
                const book_index = res.books[classes[p]][0];
                if (book_index < 0) continue;
                const book = &self.setup.books[@intCast(book_index)];
                const base: i32 = @intCast(book.lookup_values);
                const k = @divExact(base - 1, 2);
                var at = p * size;
                const stop = at + size;
                while (at < stop) : (at += book.dimensions) {
                    var entry: u32 = 0;
                    var scale: u32 = 1;
                    for (self.interleaved[at..][0..book.dimensions]) |q| {
                        entry += @as(u32, @intCast(q + k)) * scale;
                        scale *= @intCast(base);
                    }
                    self.bits.code(book, entry);
                }
            }
        }
    }
};

fn testInfo(rate: u32, channels: u8) codec.Info {
    return .{ .rate = rate, .channels = channels };
}

fn encodeAll(gpa: std.mem.Allocator, info: codec.Info, options: EncodeOptions, input: []const f32, chunk: usize) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var enc: Encoder = try .init(gpa, &aw.writer, options, info);
    defer enc.deinit();
    const step = chunk * info.channels;
    var at: usize = 0;
    while (at < input.len) : (at += step) try enc.write(input[at..@min(input.len, at + step)]);
    try enc.finish();
    return aw.toOwnedSlice();
}

const Decoded = struct {
    samples: []f32,
    rate: u32,
    channels: u8,

    fn deinit(self: Decoded, gpa: std.mem.Allocator) void {
        gpa.free(self.samples);
    }
};

fn decodeAll(gpa: std.mem.Allocator, bytes: []const u8) !Decoded {
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: decode.Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const info = dec.info();
    return .{ .samples = try helpers.readAll(gpa, &dec, 4096), .rate = info.rate, .channels = info.channels };
}

fn snrDb(want: []const f32, got: []const f32) f64 {
    std.debug.assert(want.len == got.len);
    var signal: f64 = 0;
    var noise: f64 = 0;
    for (want, got) |w, g| {
        signal += @as(f64, w) * w;
        const d = @as(f64, w) - g;
        noise += d * d;
    }
    if (noise == 0) return 200;
    return 10 * std.math.log10(signal / noise);
}

/// `colored` is white noise through an average of 8 samples, so the high bands are weaker.
const Signal = enum { sines, colored, white, silence };

fn makeSignal(gpa: std.mem.Allocator, kind: Signal, channels: u8, frames: usize) ![]f32 {
    const out = try gpa.alloc(f32, frames * channels);
    errdefer gpa.free(out);
    var prng: std.Random.DefaultPrng = .init(12345);
    const random = prng.random();
    for (0..channels) |c| {
        const cf: f64 = @floatFromInt(c);
        var history: [8]f64 = @splat(0);
        for (0..frames) |i| {
            const t: f64 = @floatFromInt(i);
            const white = (random.float(f64) - 0.5) * 0.5;
            history[i % 8] = white;
            var sum: f64 = 0;
            for (history) |h| sum += h;
            out[i * channels + c] = @floatCast(switch (kind) {
                .sines => blk: {
                    var v: f64 = 0;
                    inline for (.{ 0.0113, 0.0371, 0.1049 }, .{ 0.25, 0.15, 0.08 }) |f, a| {
                        v += a * @sin(2.0 * std.math.pi * f * (1.0 + 0.37 * cf) * t);
                    }
                    break :blk v;
                },
                .colored => sum * 0.4,
                .white => white,
                .silence => 0,
            });
        }
    }
    return out;
}

test "the wrapped floor value decodes to the posted value for every prediction" {
    for ([_]i32{ 256, 128, 86, 64 }) |range| {
        var predicted: i32 = 0;
        while (predicted < range) : (predicted += 1) {
            var seen: [256]bool = @splat(false);
            var final: i32 = 0;
            while (final < range) : (final += 1) {
                if (final == predicted) continue;
                const coded = wrapDeviation(final, predicted, range);
                try testing.expect(coded >= 1 and coded < range);
                try testing.expect(!seen[@intCast(coded)]);
                seen[@intCast(coded)] = true;
                // The decoder rule of the specification.
                const high_room = range - predicted;
                const low_room = predicted;
                const room = 2 * @min(high_room, low_room);
                const decoded: i32 = if (coded >= room)
                    (if (high_room > low_room) coded - low_room + predicted else predicted - coded + high_room - 1)
                else if (coded & 1 == 1)
                    predicted - @divTrunc(coded + 1, 2)
                else
                    predicted + @divTrunc(coded, 2);
                try testing.expectEqual(final, decoded);
            }
        }
    }
}

test "lossless coupling is undone by the decoder for every pair" {
    var l: i32 = -40;
    while (l <= 40) : (l += 1) {
        var r: i32 = -40;
        while (r <= 40) : (r += 1) {
            const pair = couple(l, r);
            const m = pair[0];
            const a = pair[1];
            try testing.expect(@abs(a) <= 2 * @max(@abs(l), @abs(r)));
            // The decoder rule of the specification: the magnitude slot gets the left value.
            var new_m: i32 = undefined;
            var new_a: i32 = undefined;
            if (m > 0) {
                if (a > 0) {
                    new_m = m;
                    new_a = m - a;
                } else {
                    new_a = m;
                    new_m = m + a;
                }
            } else {
                if (a > 0) {
                    new_m = m;
                    new_a = m + a;
                } else {
                    new_a = m;
                    new_m = m - a;
                }
            }
            try testing.expectEqual(l, new_m);
            try testing.expectEqual(r, new_a);
        }
    }
}

test "a partition takes the smallest class that holds its peak" {
    const limits = [_]u16{ 0, 1, 2, 4, 8, 16, 40, 128, 511 };
    const cases = [_][2]u32{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 }, .{ 4, 3 }, .{ 5, 4 }, .{ 8, 4 }, .{ 9, 5 }, .{ 16, 5 }, .{ 17, 6 }, .{ 40, 6 }, .{ 41, 7 }, .{ 128, 7 }, .{ 129, 8 }, .{ 510, 8 }, .{ 511, 8 } };
    for (cases) |c| try testing.expectEqual(@as(usize, c[1]), classFor(&limits, c[0]));
}

const Case = struct { rate: u32, channels: u8, quality: f32, kind: Signal, snr_floor: f64 };

const round_trip_cases = [_]Case{
    .{ .rate = 8000, .channels = 1, .quality = 4, .kind = .sines, .snr_floor = 23.7 },
    .{ .rate = 22050, .channels = 2, .quality = 4, .kind = .sines, .snr_floor = 26.4 },
    .{ .rate = 44100, .channels = 1, .quality = 4, .kind = .sines, .snr_floor = 25.7 },
    .{ .rate = 44100, .channels = 2, .quality = 4, .kind = .sines, .snr_floor = 25.3 },
    .{ .rate = 48000, .channels = 6, .quality = 4, .kind = .sines, .snr_floor = 25.1 },
    .{ .rate = 8000, .channels = 6, .quality = 4, .kind = .sines, .snr_floor = 23.6 },
    .{ .rate = 22050, .channels = 6, .quality = 4, .kind = .sines, .snr_floor = 25.7 },
    .{ .rate = 8000, .channels = 1, .quality = 4, .kind = .colored, .snr_floor = 23.7 },
    .{ .rate = 22050, .channels = 2, .quality = 4, .kind = .colored, .snr_floor = 23.9 },
    .{ .rate = 44100, .channels = 1, .quality = 4, .kind = .colored, .snr_floor = 16.3 },
    .{ .rate = 44100, .channels = 2, .quality = 4, .kind = .colored, .snr_floor = 16.1 },
    .{ .rate = 48000, .channels = 6, .quality = 4, .kind = .colored, .snr_floor = 15.6 },
    .{ .rate = 8000, .channels = 1, .quality = 4, .kind = .white, .snr_floor = 23.5 },
    .{ .rate = 22050, .channels = 2, .quality = 4, .kind = .white, .snr_floor = 23.4 },
    .{ .rate = 44100, .channels = 2, .quality = 10, .kind = .white, .snr_floor = 37 },
    .{ .rate = 48000, .channels = 6, .quality = 10, .kind = .white, .snr_floor = 37 },
    .{ .rate = 44100, .channels = 2, .quality = -1, .kind = .sines, .snr_floor = 15.1 },
    .{ .rate = 22050, .channels = 2, .quality = -1, .kind = .colored, .snr_floor = 12.2 },
    .{ .rate = 22050, .channels = 2, .quality = -1, .kind = .white, .snr_floor = 12.3 },
    .{ .rate = 44100, .channels = 2, .quality = 2, .kind = .sines, .snr_floor = 21.1 },
    .{ .rate = 22050, .channels = 2, .quality = 2, .kind = .colored, .snr_floor = 19.5 },
    .{ .rate = 22050, .channels = 2, .quality = 2, .kind = .white, .snr_floor = 19 },
    .{ .rate = 44100, .channels = 2, .quality = 6, .kind = .sines, .snr_floor = 30 },
    .{ .rate = 22050, .channels = 2, .quality = 6, .kind = .colored, .snr_floor = 28.3 },
    .{ .rate = 22050, .channels = 2, .quality = 6, .kind = .white, .snr_floor = 28.1 },
    .{ .rate = 44100, .channels = 2, .quality = 8, .kind = .sines, .snr_floor = 32.8 },
    .{ .rate = 22050, .channels = 2, .quality = 8, .kind = .colored, .snr_floor = 32.9 },
    .{ .rate = 22050, .channels = 2, .quality = 8, .kind = .white, .snr_floor = 32.4 },
    .{ .rate = 44100, .channels = 2, .quality = 10, .kind = .sines, .snr_floor = 36.8 },
    .{ .rate = 22050, .channels = 2, .quality = 10, .kind = .colored, .snr_floor = 37.5 },
    .{ .rate = 22050, .channels = 2, .quality = 10, .kind = .white, .snr_floor = 37 },
};

test "encoded sines and noise decode to the input length with the SNR floor" {
    const gpa = testing.allocator;
    for (round_trip_cases) |c| {
        const frames = c.rate / 4 + 123;
        const input = try makeSignal(gpa, c.kind, c.channels, frames);
        defer gpa.free(input);
        const bytes = try encodeAll(gpa, testInfo(c.rate, c.channels), .{ .quality = c.quality }, input, 1000);
        defer gpa.free(bytes);
        const out = try decodeAll(gpa, bytes);
        defer out.deinit(gpa);
        try testing.expectEqual(c.rate, out.rate);
        try testing.expectEqual(c.channels, out.channels);
        try testing.expectEqual(input.len, out.samples.len);
        const snr = snrDb(input, out.samples);
        try testing.expect(snr >= c.snr_floor);
    }
}

test "silence decodes to silence and every floor is unused" {
    const gpa = testing.allocator;
    for ([_]u32{ 8000, 22050, 44100 }) |rate| for ([_]u8{ 1, 2, 6, 8 }) |channels| {
        const input = try makeSignal(gpa, .silence, channels, 10000);
        defer gpa.free(input);
        const bytes = try encodeAll(gpa, testInfo(rate, channels), .{}, input, 4096);
        defer gpa.free(bytes);
        const out = try decodeAll(gpa, bytes);
        defer out.deinit(gpa);
        try testing.expectEqual(input.len, out.samples.len);
        for (out.samples) |s| try testing.expectEqual(@as(f32, 0), s);

        var in: io.Input = .init(.{ .bytes = bytes });
        var reader: packets.PacketReader = try .init(gpa, &in, .any, .{});
        defer reader.deinit();
        for (0..3) |_| _ = (try reader.next()).?;
        var count: usize = 0;
        while (try reader.next()) |p| : (count += 1) {
            // The type bit, the mode and the two window flags, then one bit per channel.
            try testing.expectEqual((@as(usize, channels) + 4 + 7) / 8, p.data.len);
            try testing.expectEqual(@as(u8, 0x0e), p.data[0]);
            for (p.data[1..]) |b| try testing.expectEqual(@as(u8, 0), b);
        }
        try testing.expectEqual(@as(usize, 10000 / (setup_mod.blocksizeFor(rate) / 2) + 1 + 1), count);
    };
}

test "the output has exactly the input length for lengths near the block edges" {
    const gpa = testing.allocator;
    const half = 1024;
    for ([_]usize{ 0, 1, 2, half - 1, half, half + 1, 2 * half - 1, 2 * half, 2 * half + 1, 5 * half, 5 * half + 7 }) |frames| {
        const input = try makeSignal(gpa, .sines, 2, frames);
        defer gpa.free(input);
        const bytes = try encodeAll(gpa, testInfo(44100, 2), .{}, input, 333);
        defer gpa.free(bytes);
        const out = try decodeAll(gpa, bytes);
        defer out.deinit(gpa);
        try testing.expectEqual(input.len, out.samples.len);
        if (frames >= 2 * half) try testing.expect(snrDb(input, out.samples) > 15);
    }
}

test "two runs and any chunking give the same bytes" {
    const gpa = testing.allocator;
    const input = try makeSignal(gpa, .colored, 2, 9000);
    defer gpa.free(input);
    const a = try encodeAll(gpa, testInfo(44100, 2), .{ .quality = 3 }, input, 9000);
    defer gpa.free(a);
    const b = try encodeAll(gpa, testInfo(44100, 2), .{ .quality = 3 }, input, 9000);
    defer gpa.free(b);
    const c = try encodeAll(gpa, testInfo(44100, 2), .{ .quality = 3 }, input, 1);
    defer gpa.free(c);
    const d = try encodeAll(gpa, testInfo(44100, 2), .{ .quality = 3 }, input, 1023);
    defer gpa.free(d);
    try testing.expectEqualSlices(u8, a, b);
    try testing.expectEqualSlices(u8, a, c);
    try testing.expectEqualSlices(u8, a, d);
}

test "the pages carry the granules of the stream mapping" {
    const gpa = testing.allocator;
    for ([_]usize{ 0, 700, 1024, 30000, 100000 }) |frames| {
        const input = try makeSignal(gpa, .colored, 2, frames);
        defer gpa.free(input);
        const bytes = try encodeAll(gpa, testInfo(44100, 2), .{ .serial = 0x1234 }, input, 5000);
        defer gpa.free(bytes);

        var at: usize = 0;
        var index: u32 = 0;
        var completed: i64 = 0;
        while (at < bytes.len) : (index += 1) {
            const page = try packets.parsePage(bytes[at..]);
            at += page.size();
            const last = at == bytes.len;
            try testing.expectEqual(@as(u32, 0x1234), page.serial);
            try testing.expectEqual(index, page.sequence);
            try testing.expectEqual(index == 0, page.flags.bos);
            try testing.expectEqual(last, page.flags.eos);
            var ends: i64 = 0;
            for (page.lacing) |v| ends += @intFromBool(v < 255);
            switch (index) {
                0 => {
                    try testing.expectEqual(@as(usize, 58), page.size());
                    try testing.expectEqual(@as(i64, 1), ends);
                    try testing.expectEqual(@as(i64, 0), page.granule);
                },
                1 => {
                    try testing.expectEqual(@as(i64, 2), ends);
                    try testing.expectEqual(@as(i64, 0), page.granule);
                },
                else => {
                    completed += ends;
                    const want: i64 = if (last) @intCast(frames) else (completed - 1) * 1024;
                    try testing.expectEqual(want, page.granule);
                    // The last packet has a page of its own, so a reader that finds the length from the
                    // page before it, as FFmpeg does, can cut the end.
                    if (last and index > 2) try testing.expectEqual(@as(i64, 1), ends);
                },
            }
        }
        try testing.expect(index >= 3);
        try testing.expectEqual(@as(i64, @intCast(frames / 1024 + 1 + @intFromBool(frames % 1024 != 0))), completed);
    }
}

test "the headers read back" {
    const gpa = testing.allocator;
    const input = try makeSignal(gpa, .sines, 3, 5000);
    defer gpa.free(input);
    const bytes = try encodeAll(gpa, testInfo(32000, 3), .{}, input, 5000);
    defer gpa.free(bytes);
    const headers = try vt.firstHeaders(gpa, bytes);
    defer headers.deinit(gpa);
    const id = try header.parseIdentification(headers.identification);
    try testing.expectEqual(@as(u8, 3), id.channels);
    try testing.expectEqual(@as(u32, 32000), id.rate);
    try testing.expectEqual(@as(u16, 256), id.blocksize_0);
    try testing.expectEqual(@as(u16, 2048), id.blocksize_1);
    const comments = try header.parseComment(headers.comment);
    try testing.expectEqualStrings("Chorus", comments.vendor);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const parsed = try header.Setup.parse(arena.allocator(), headers.setup, 3, 16 << 20);
    try testing.expectEqual(headers.setup.len, parsed.size);
}

test "the bitrate grows with the quality" {
    const gpa = testing.allocator;
    const input = try makeSignal(gpa, .colored, 2, 44100);
    defer gpa.free(input);
    var last: usize = 0;
    for ([_]f32{ -1, 2, 5, 8, 10 }) |quality| {
        const bytes = try encodeAll(gpa, testInfo(44100, 2), .{ .quality = quality }, input, 4410);
        defer gpa.free(bytes);
        try testing.expect(bytes.len > last);
        last = bytes.len;
    }
}

test "write and finish allocate nothing after init" {
    const gpa = testing.allocator;
    const input = try makeSignal(gpa, .colored, 6, 8000);
    defer gpa.free(input);
    const out = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(out);
    var writer: std.Io.Writer = .fixed(out);
    var failing = std.testing.FailingAllocator.init(gpa, .{});
    var enc: Encoder = try .init(failing.allocator(), &writer, .{}, testInfo(44100, 6));
    defer enc.deinit();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try enc.write(input[0 .. 3000 * 6]);
    try enc.write(input[3000 * 6 ..]);
    try enc.finish();
    try testing.expect(writer.end > 0);
}

test "an unsupported setup is rejected at init" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const gpa = testing.allocator;
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &writer, .{}, testInfo(44100, 0)));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &writer, .{}, testInfo(0, 2)));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &writer, .{ .quality = std.math.nan(f32) }, testInfo(44100, 2)));
}

test "a partial frame and a write after finish give Unsupported" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc: Encoder = try .init(gpa, &aw.writer, .{}, testInfo(44100, 2));
    defer enc.deinit();
    try testing.expectError(error.Unsupported, enc.write(&.{ 0.1, 0.2, 0.3 }));
    try enc.write(&.{ 0.1, 0.2, 0.3, 0.4 });
    try enc.finish();
    const size = aw.written().len;
    try testing.expectError(error.Unsupported, enc.write(&.{ 0.1, 0.2 }));
    try enc.finish();
    try testing.expectEqual(size, aw.written().len);
}

test "an impulse comes back at its place" {
    const gpa = testing.allocator;
    const input = try gpa.alloc(f32, 6000);
    defer gpa.free(input);
    @memset(input, 0);
    input[0] = 0.5;
    input[3001] = -0.5;
    const bytes = try encodeAll(gpa, testInfo(44100, 1), .{ .quality = 8 }, input, 6000);
    defer gpa.free(bytes);
    const out = try decodeAll(gpa, bytes);
    defer out.deinit(gpa);
    try testing.expectEqual(input.len, out.samples.len);
    var low: usize = 0;
    var high: usize = 0;
    for (out.samples, 0..) |s, i| {
        if (s > out.samples[high]) high = i;
        if (s < out.samples[low]) low = i;
    }
    try testing.expectEqual(@as(usize, 0), high);
    try testing.expectEqual(@as(usize, 3001), low);
}

test "eight channels keep their order" {
    const gpa = testing.allocator;
    const input = try makeSignal(gpa, .sines, 8, 20000);
    defer gpa.free(input);
    const bytes = try encodeAll(gpa, testInfo(44100, 8), .{ .quality = 6 }, input, 20000);
    defer gpa.free(bytes);
    const out = try decodeAll(gpa, bytes);
    defer out.deinit(gpa);
    try testing.expectEqual(input.len, out.samples.len);
    for (0..8) |c| {
        var signal: f64 = 0;
        var noise: f64 = 0;
        for (0..20000) |i| {
            const w = input[i * 8 + c];
            const d = @as(f64, w) - out.samples[i * 8 + c];
            signal += @as(f64, w) * w;
            noise += d * d;
        }
        try testing.expect(10 * std.math.log10(signal / noise) > 15);
    }
}

test "a silent channel next to loud ones decodes to zeros" {
    const gpa = testing.allocator;
    for ([_]u8{ 2, 3, 6 }) |channels| {
        for (0..channels) |silent| {
            const input = try makeSignal(gpa, .sines, channels, 12000);
            defer gpa.free(input);
            for (0..12000) |i| input[i * channels + silent] = 0;
            const bytes = try encodeAll(gpa, testInfo(44100, channels), .{}, input, 12000);
            defer gpa.free(bytes);
            const out = try decodeAll(gpa, bytes);
            defer out.deinit(gpa);
            try testing.expectEqual(input.len, out.samples.len);
            for (0..12000) |i| {
                for (0..channels) |c| {
                    if (c == silent) try testing.expectEqual(@as(f32, 0), out.samples[i * channels + c]);
                }
            }
            try testing.expect(snrDb(input, out.samples) > 20);
        }
    }
}

test "samples that are not finite or too large do not break the stream" {
    const gpa = testing.allocator;
    const input = try makeSignal(gpa, .sines, 2, 9000);
    defer gpa.free(input);
    input[10] = std.math.nan(f32);
    input[2000] = std.math.inf(f32);
    input[2001] = -std.math.inf(f32);
    input[5000] = 3.0e38;
    const bytes = try encodeAll(gpa, testInfo(44100, 2), .{ .quality = 10 }, input, 9000);
    defer gpa.free(bytes);
    const out = try decodeAll(gpa, bytes);
    defer out.deinit(gpa);
    try testing.expectEqual(input.len, out.samples.len);
    for (out.samples) |s| try testing.expect(std.math.isFinite(s) and s >= -1 and s < 1);
}

test "a full scale square wave encodes and decodes" {
    const gpa = testing.allocator;
    const input = try gpa.alloc(f32, 30000);
    defer gpa.free(input);
    for (input, 0..) |*s, i| s.* = if ((i / 50) % 2 == 0) 0.999 else -0.999;
    const bytes = try encodeAll(gpa, testInfo(44100, 1), .{ .quality = 6 }, input, 30000);
    defer gpa.free(bytes);
    const out = try decodeAll(gpa, bytes);
    defer out.deinit(gpa);
    try testing.expectEqual(input.len, out.samples.len);
    try testing.expect(snrDb(input, out.samples) > 10);
}

test "255 channels encode and decode in stream order" {
    const gpa = testing.allocator;
    const input = try makeSignal(gpa, .sines, 255, 2000);
    defer gpa.free(input);
    const bytes = try encodeAll(gpa, testInfo(8000, 255), .{ .quality = 6 }, input, 2000);
    defer gpa.free(bytes);
    const out = try decodeAll(gpa, bytes);
    defer out.deinit(gpa);
    try testing.expectEqual(@as(u8, 255), out.channels);
    try testing.expectEqual(input.len, out.samples.len);
    try testing.expect(snrDb(input, out.samples) > 15);
}

test "a quality outside the scale is clamped" {
    const gpa = testing.allocator;
    const input = try makeSignal(gpa, .colored, 1, 6000);
    defer gpa.free(input);
    const low = try encodeAll(gpa, testInfo(22050, 1), .{ .quality = -1 }, input, 6000);
    defer gpa.free(low);
    const below = try encodeAll(gpa, testInfo(22050, 1), .{ .quality = -7 }, input, 6000);
    defer gpa.free(below);
    const high = try encodeAll(gpa, testInfo(22050, 1), .{ .quality = 10 }, input, 6000);
    defer gpa.free(high);
    const above = try encodeAll(gpa, testInfo(22050, 1), .{ .quality = 99 }, input, 6000);
    defer gpa.free(above);
    try testing.expectEqualSlices(u8, low, below);
    try testing.expectEqualSlices(u8, high, above);
    try testing.expect(!std.mem.eql(u8, low, high));
}

fn encodeWith(gpa: std.mem.Allocator, info: codec.Info, options: EncodeOptions, input: []const f32, switching: bool) !struct { bytes: []u8, stats: Stats } {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var enc: Encoder = try .init(gpa, &aw.writer, options, info);
    defer enc.deinit();
    enc.switching = switching;
    try enc.write(input);
    try enc.finish();
    return .{ .bytes = try aw.toOwnedSlice(), .stats = enc.stats() };
}

/// A mono signal of quiet noise with a loud click every `period` frames from `first`.
fn clickTrain(gpa: std.mem.Allocator, frames: usize, first: usize, period: usize) ![]f32 {
    const out = try gpa.alloc(f32, frames);
    var prng: std.Random.DefaultPrng = .init(99);
    const random = prng.random();
    for (out) |*s| s.* = (random.float(f32) - 0.5) * 0.0002;
    var at = first;
    while (at < frames) : (at += period) out[at] = if ((at / period) % 2 == 0) 0.8 else -0.8;
    return out;
}

fn energy(samples: []const f32) f64 {
    var sum: f64 = 0;
    for (samples) |s| sum += @as(f64, s) * s;
    return sum;
}

test "a click train uses short blocks and has less pre-echo than long blocks only" {
    const gpa = testing.allocator;
    const period = 7000;
    const first = 9000;
    const input = try clickTrain(gpa, 44100, first, period);
    defer gpa.free(input);
    const info = testInfo(44100, 1);
    const switched = try encodeWith(gpa, info, .{ .quality = 6 }, input, true);
    defer gpa.free(switched.bytes);
    const plain = try encodeWith(gpa, info, .{ .quality = 6 }, input, false);
    defer gpa.free(plain.bytes);
    try testing.expect(switched.stats.short_blocks >= 5);
    try testing.expectEqual(@as(u64, 0), plain.stats.short_blocks);

    const a = try decodeAll(gpa, switched.bytes);
    defer a.deinit(gpa);
    const b = try decodeAll(gpa, plain.bytes);
    defer b.deinit(gpa);
    try testing.expectEqual(input.len, a.samples.len);
    try testing.expectEqual(input.len, b.samples.len);

    // The energy in the 700 samples that end 300 samples before each click.
    var pre_short: f64 = 0;
    var pre_long: f64 = 0;
    var at: usize = first;
    while (at < input.len) : (at += period) {
        pre_short += energy(a.samples[at - 1000 .. at - 300]);
        pre_long += energy(b.samples[at - 1000 .. at - 300]);
    }
    try testing.expect(pre_long > 0);
    try testing.expect(pre_short * 8 < pre_long);
    try testing.expect(snrDb(input, a.samples) > 9);
}

test "the window flags of every long block name the blocks next to it" {
    const gpa = testing.allocator;
    const input = try clickTrain(gpa, 30000, 4000, 5200);
    defer gpa.free(input);
    const bytes = try encodeAll(gpa, testInfo(44100, 1), .{ .quality = 4 }, input, 3000);
    defer gpa.free(bytes);

    var in: io.Input = .init(.{ .bytes = bytes });
    var reader: packets.PacketReader = try .init(gpa, &in, .any, .{});
    defer reader.deinit();
    for (0..3) |_| _ = (try reader.next()).?;
    var kinds: std.ArrayList(bool) = .empty;
    defer kinds.deinit(gpa);
    var prev: std.ArrayList(bool) = .empty;
    defer prev.deinit(gpa);
    var next: std.ArrayList(bool) = .empty;
    defer next.deinit(gpa);
    while (try reader.next()) |p| {
        try testing.expectEqual(@as(u8, 0), p.data[0] & 1);
        const long = p.data[0] & 2 != 0;
        try kinds.append(gpa, long);
        try prev.append(gpa, long and p.data[0] & 4 != 0);
        try next.append(gpa, long and p.data[0] & 8 != 0);
    }
    var shorts: usize = 0;
    for (kinds.items, 0..) |long, i| {
        shorts += @intFromBool(!long);
        if (!long) continue;
        if (i > 0) try testing.expectEqual(kinds.items[i - 1], prev.items[i]);
        if (i + 1 < kinds.items.len) try testing.expectEqual(kinds.items[i + 1], next.items[i]);
    }
    try testing.expect(shorts > 0 and shorts < kinds.items.len);
    try testing.expect(kinds.items[0]);
}

test "block switching keeps the length and the chunking and gives a clean click train" {
    const gpa = testing.allocator;
    const info = testInfo(44100, 2);
    for ([_]usize{ 0, 1, 700, 2047, 2048, 2049, 9001, 30000 }) |frames| {
        const mono = try clickTrain(gpa, frames, 0, 1500);
        defer gpa.free(mono);
        const input = try gpa.alloc(f32, frames * 2);
        defer gpa.free(input);
        for (mono, 0..) |s, i| {
            input[2 * i] = s;
            input[2 * i + 1] = if (i % 3000 == 1700) -0.6 else s * 0.5;
        }
        const whole = try encodeAll(gpa, info, .{ .quality = 8 }, input, @max(1, frames));
        defer gpa.free(whole);
        const bits = try encodeAll(gpa, info, .{ .quality = 8 }, input, 1023);
        defer gpa.free(bits);
        try testing.expectEqualSlices(u8, whole, bits);
        const out = try decodeAll(gpa, whole);
        defer out.deinit(gpa);
        try testing.expectEqual(input.len, out.samples.len);
        if (frames >= 9001) try testing.expect(snrDb(input, out.samples) > 25);
    }
}

test "levels are cut to the limit and counted" {
    const over = quantize(100, 1, 20);
    try testing.expectEqual(@as(i32, 20), over.level);
    try testing.expect(over.clipped);
    const under = quantize(-100, 2, 20);
    try testing.expectEqual(@as(i32, -20), under.level);
    try testing.expect(under.clipped);
    const edge = quantize(20.4, 1, 20);
    try testing.expectEqual(@as(i32, 20), edge.level);
    try testing.expect(!edge.clipped);
    const inside = quantize(-19.4, 1, 20);
    try testing.expectEqual(@as(i32, -19), inside.level);
    try testing.expect(!inside.clipped);
    const just = quantize(20.6, 1, 20);
    try testing.expectEqual(@as(i32, 20), just.level);
    try testing.expect(just.clipped);
}

test "the stats count the blocks and the cut lines" {
    const gpa = testing.allocator;
    const input = try makeSignal(gpa, .sines, 1, 44100);
    defer gpa.free(input);
    const low = try encodeWith(gpa, testInfo(44100, 1), .{ .quality = -1 }, input, true);
    defer gpa.free(low.bytes);
    const high = try encodeWith(gpa, testInfo(44100, 1), .{ .quality = 10 }, input, true);
    defer gpa.free(high.bytes);
    try testing.expectEqual(@as(u64, 0), low.stats.short_blocks);
    try testing.expectEqual(@as(u64, 44100 / 1024 + 1 + 1), low.stats.long_blocks);
    try testing.expectEqual(@as(u64, 0), high.stats.clipped_lines);
    try testing.expectEqual(@as(u64, 0), low.stats.clipped_lines);
}

test "a strong tone at a low quality is cut and counted" {
    const gpa = testing.allocator;
    const input = try gpa.alloc(f32, 8192);
    defer gpa.free(input);
    var prng: std.Random.DefaultPrng = .init(5);
    for (input, 0..) |*s, i| {
        const t: f64 = @floatFromInt(i);
        s.* = @floatCast(0.8 * @sin(2 * std.math.pi * 0.3181 * t) + (prng.random().float(f64) - 0.5) * 1e-4);
    }
    const cut = try encodeWith(gpa, testInfo(8000, 1), .{ .quality = 1 }, input, true);
    defer gpa.free(cut.bytes);
    try testing.expectEqual(@as(u64, 30), cut.stats.clipped_lines);
    const fine = try encodeWith(gpa, testInfo(8000, 1), .{ .quality = 10 }, input, true);
    defer gpa.free(fine.bytes);
    try testing.expect(fine.stats.clipped_lines < cut.stats.clipped_lines);
    const out = try decodeAll(gpa, cut.bytes);
    defer out.deinit(gpa);
    try testing.expectEqual(input.len, out.samples.len);
    try testing.expect(snrDb(input, out.samples) > 10);
}

fn maskOf(bits: u32) codec.ChannelMask {
    return @bitCast(bits);
}

test "the channel map follows the speaker mask" {
    const defaults = [_]u32{ 0x4, 0x3, 0x7, 0x33, 0x37, 0x3f, 0x70f, 0x63f };
    for (defaults, 1..) |bits, channels| {
        var given: [8]u8 = undefined;
        var zero: [8]u8 = undefined;
        try channelMap(given[0..channels], maskOf(bits));
        try channelMap(zero[0..channels], .{});
        try testing.expectEqualSlices(u8, zero[0..channels], given[0..channels]);
        for (given[0..channels], 0..) |g, c| try testing.expectEqual(@as(u8, @intCast(decode.waveChannel(channels, c))), g);
    }
    var out: [8]u8 = undefined;
    // Side speakers in place of the back pair.
    try channelMap(out[0..4], maskOf(0x603));
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, out[0..4]);
    try channelMap(out[0..5], maskOf(0x607));
    try testing.expectEqualSlices(u8, &.{ 0, 2, 1, 3, 4 }, out[0..5]);
    try channelMap(out[0..6], maskOf(0x60f));
    try testing.expectEqualSlices(u8, &.{ 0, 2, 1, 4, 5, 3 }, out[0..6]);
    // Two speakers that are not the front pair are read in mask order.
    try channelMap(out[0..2], maskOf(0x30));
    try testing.expectEqualSlices(u8, &.{ 0, 1 }, out[0..2]);
    // More than 8 channels read in order whatever the mask.
    try channelMap(out[0..8], maskOf(0));
    var wide: [9]u8 = undefined;
    try channelMap(&wide, maskOf(0x1ff));
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 }, &wide);
}

test "a mask that does not fit the channel count is rejected" {
    var out: [8]u8 = undefined;
    try testing.expectError(error.Unsupported, channelMap(out[0..6], maskOf(0x37)));
    try testing.expectError(error.Unsupported, channelMap(out[0..3], maskOf(0x13)));
    try testing.expectError(error.Unsupported, channelMap(out[0..7], maskOf(0x63f | 0x100 << 0)));
    try testing.expectError(error.Unsupported, channelMap(out[0..2], maskOf(0x7)));
    try testing.expectError(error.Unsupported, channelMap(out[0..1], maskOf(0x80000000)));
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const info: codec.Info = .{ .rate = 44100, .channels = 6, .mask = maskOf(0x37) };
    try testing.expectError(error.Unsupported, Encoder.init(testing.allocator, &writer, .{}, info));
}

test "a mask with side speakers encodes like the default mask" {
    const gpa = testing.allocator;
    const input = try makeSignal(gpa, .sines, 6, 6000);
    defer gpa.free(input);
    const plain = try encodeAll(gpa, testInfo(44100, 6), .{}, input, 6000);
    defer gpa.free(plain);
    const sides = try encodeAll(gpa, .{ .rate = 44100, .channels = 6, .mask = maskOf(0x60f) }, .{}, input, 6000);
    defer gpa.free(sides);
    try testing.expectEqualSlices(u8, plain, sides);
}
