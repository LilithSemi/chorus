//! Ogg Opus encoder (RFC 7845): the headers, the front end for any sample rate and channel count,
//! and the pages.
const std = @import("std");
const codec = @import("../../codec.zig");
const io = @import("../io.zig");
const packets = @import("../ogg.zig");
const resample = @import("../resample.zig");
const head = @import("head.zig");
const multistream = @import("multistream.zig");
const opus = @import("../opus.zig");
const packet = @import("packet.zig");
const vorbis = @import("../vorbis.zig");
const helpers = @import("../testing.zig");
const testing = std.testing;

const vendor = "Chorus";
const chunk_frames = 1024;
const resample_frames = 2048;
const pad_frames = 256;

/// Writes interleaved f32 frames in WAVE channel order as Ogg Opus.
///
/// Any sample rate works: a rate other than 48000 is resampled to 48000 and the header names the
/// original rate. The headers go out with the first `write` or with `finish`. `init` allocates all
/// the memory. `finish` codes enough frames to hold the delay of the encoder, and the granule of
/// the last page trims the output to the length of the input.
pub const Encoder = struct {
    arena: std.heap.ArenaAllocator,
    out: *std.Io.Writer,
    ogg: packets.PacketWriter,
    ms: multistream.Encoder,
    resampler: ?resample.Resampler,
    channels: usize,
    rate: u32,
    pre_skip: u32,
    head_packet: [21 + 255]u8,
    head_len: usize,
    /// The input channel (WAVE order) that each coded channel reads.
    input_map: [255]u8,
    /// Input frames in coded channel order, before the resampler.
    chunk: []f32,
    /// The output of the resampler.
    resampled: []f32,
    /// The samples of the packet that is being filled.
    staging: []f32,
    staged: usize = 0,
    packet_buf: []u8,

    /// The frames that came in, and the frames at 48 kHz that came out of the front end.
    total_in: u64 = 0,
    pushed: u64 = 0,
    /// The most real frames at 48 kHz that `finish` lets through.
    limit: ?u64 = null,
    /// The samples at 48 kHz in the packets written so far.
    coded: u64 = 0,
    /// The granule of the last packet.
    final_granule: u64 = std.math.maxInt(u64),
    page_samples: u64 = 0,
    headers_written: bool = false,
    finished: bool = false,

    pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, options: opus.EncodeOptions, info: codec.Info) codec.EncoderInitError!Encoder {
        if (info.rate == 0 or info.channels == 0 or options.packet_loss > 100) return error.Unsupported;
        const channels: usize = info.channels;
        const layout = try multistream.Layout.init(info.channels);

        var o = options;
        if (o.bitrate == 0) {
            o.bitrate = defaultBitrate(layout, info.rate);
        } else if (o.bitrate < 500 or o.bitrate > 1_024_000 * @as(u32, info.channels)) {
            return error.Unsupported;
        }
        o.bitrate = @min(o.bitrate, 256_000 * @as(u32, info.channels));

        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        var ms = multistream.Encoder.init(gpa, layout, o) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidChannels, error.InvalidFrameSize, error.InvalidRate, error.InvalidComplexity => return error.Unsupported,
        };
        errdefer ms.deinit();
        if (inputBandwidth(info.rate)) |bw| ms.setInputBandwidth(bw);

        var input_map: [255]u8 = @splat(0);
        try channelMap(input_map[0..channels], info.mask);

        var resampler: ?resample.Resampler = null;
        if (info.rate != 48000) {
            resampler = try resample.Resampler.init(gpa, .{
                .channels = info.channels,
                .in_rate = info.rate,
                .out_rate = 48000,
                .quality = .best,
                .block_frames = chunk_frames,
            });
        }
        errdefer if (resampler) |*r| r.deinit(gpa);

        const pre_skip = ms.lookahead();
        var h: head.Head = .{
            .version = 1,
            .channels = info.channels,
            .pre_skip = @intCast(pre_skip),
            .input_rate = info.rate,
            .gain = 0,
            .family = layout.family,
            .streams = layout.streams,
            .coupled = layout.coupled,
            .mapping = layout.mapping,
        };
        var head_packet: [21 + 255]u8 = undefined;
        const head_len = head.writeHead(&head_packet, &h).len;

        const chunk = try a.alloc(f32, chunk_frames * channels);
        const resampled = try a.alloc(f32, resample_frames * channels);
        const staging = try a.alloc(f32, ms.frameSamples() * channels);
        const packet_buf = try a.alloc(u8, 1276 * 6 * @as(usize, layout.streams));
        const ogg = try packets.PacketWriter.init(gpa, writer, o.serial, .{});

        return .{
            .arena = arena,
            .out = writer,
            .ogg = ogg,
            .ms = ms,
            .resampler = resampler,
            .channels = channels,
            .rate = info.rate,
            .pre_skip = pre_skip,
            .head_packet = head_packet,
            .head_len = head_len,
            .input_map = input_map,
            .chunk = chunk,
            .resampled = resampled,
            .staging = staging,
            .packet_buf = packet_buf,
        };
    }

    /// Writes to a file. The stream has no size in a header, so the file is written in one pass.
    pub fn initFile(gpa: std.mem.Allocator, file: *std.Io.File.Writer, options: opus.EncodeOptions, info: codec.Info) codec.EncoderInitError!Encoder {
        return init(gpa, &file.interface, options, info);
    }

    pub fn deinit(self: *Encoder) void {
        const gpa = self.arena.child_allocator;
        self.ogg.deinit();
        if (self.resampler) |*r| r.deinit(gpa);
        self.ms.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// `frames` holds whole interleaved frames. A sample that is not finite counts as 0, and a
    /// sample past 4 in size is cut to 4. A partial frame or a call after `finish` gives
    /// error.Unsupported.
    pub fn write(self: *Encoder, frames: []const f32) codec.WriteError!void {
        const ch = self.channels;
        if (self.finished or frames.len % ch != 0) return error.Unsupported;
        try self.writeHeaders();
        const total = frames.len / ch;
        var at: usize = 0;
        while (at < total) {
            const take = @min(total - at, chunk_frames);
            for (0..take) |i| {
                for (0..ch) |c| {
                    const v = frames[(at + i) * ch + self.input_map[c]];
                    self.chunk[i * ch + c] = if (std.math.isFinite(v)) std.math.clamp(v, -max_input, max_input) else 0;
                }
            }
            self.total_in += take;
            try self.feed(self.chunk[0 .. take * ch]);
            at += take;
        }
    }

    /// Codes the frames that the delay of the encoder and the end of the input need, and writes
    /// the last page. The stream is complete after this.
    pub fn finish(self: *Encoder) codec.WriteError!void {
        if (self.finished) return;
        self.finished = true;
        try self.writeHeaders();
        const ch = self.channels;
        const length = outputFrames(self.total_in, self.rate);
        self.limit = length;
        if (self.resampler != null) {
            // Zeros push the last real frames out of the filter.
            @memset(self.chunk[0 .. pad_frames * ch], 0);
            while (self.pushed < length) try self.feed(self.chunk[0 .. pad_frames * ch]);
        }
        const frame: u64 = self.ms.frameSamples();
        const end = length + self.pre_skip;
        self.final_granule = end;
        const packets_needed = (end + frame - 1) / frame;
        var missing = packets_needed * frame - (self.coded + self.staged);
        @memset(self.chunk[0 .. chunk_frames * ch], 0);
        while (missing > 0) {
            const n: usize = @intCast(@min(missing, chunk_frames));
            try self.stage(self.chunk[0 .. n * ch]);
            missing -= n;
        }
        try self.ogg.finish();
        self.out.flush() catch return error.WriteFailed;
    }

    fn writeHeaders(self: *Encoder) codec.WriteError!void {
        if (self.headers_written) return;
        self.headers_written = true;
        try self.ogg.writePacket(self.head_packet[0..self.head_len], 0);
        try self.ogg.flush();
        var tags: [8 + 4 + vendor.len + 4]u8 = undefined;
        @memcpy(tags[0..8], head.tags_magic);
        std.mem.writeInt(u32, tags[8..12], vendor.len, .little);
        @memcpy(tags[12..][0..vendor.len], vendor);
        std.mem.writeInt(u32, tags[12 + vendor.len ..][0..4], 0, .little);
        try self.ogg.writePacket(&tags, 0);
        try self.ogg.flush();
    }

    /// Takes input frames in coded channel order and passes frames at 48 kHz on.
    fn feed(self: *Encoder, input: []const f32) codec.WriteError!void {
        const ch = self.channels;
        const r = if (self.resampler) |*r| r else return self.push(input);
        var pos: usize = 0;
        while (true) {
            const res = r.process(input[pos * ch ..], self.resampled);
            pos += res.in_frames;
            try self.push(self.resampled[0 .. res.out_frames * ch]);
            if (res.in_frames == 0 and res.out_frames == 0) break;
            if (pos * ch >= input.len and res.out_frames * ch < self.resampled.len) break;
        }
    }

    /// Counts real frames at 48 kHz and drops those past the limit.
    fn push(self: *Encoder, samples: []const f32) codec.WriteError!void {
        var n = samples.len / self.channels;
        if (self.limit) |l| n = @intCast(@min(n, l -| self.pushed));
        self.pushed += n;
        try self.stage(samples[0 .. n * self.channels]);
    }

    /// Fills the packet buffer and codes each packet that is full.
    fn stage(self: *Encoder, samples: []const f32) codec.WriteError!void {
        const ch = self.channels;
        const frame = self.ms.frameSamples();
        var left = samples.len / ch;
        var from: usize = 0;
        while (left > 0) {
            const take = @min(frame - self.staged, left);
            @memcpy(self.staging[self.staged * ch ..][0 .. take * ch], samples[from * ch ..][0 .. take * ch]);
            self.staged += take;
            from += take;
            left -= take;
            if (self.staged == frame) {
                try self.writeAudioPacket();
                self.staged = 0;
            }
        }
    }

    fn writeAudioPacket(self: *Encoder) codec.WriteError!void {
        // The sizes rule out every error of the encoder, so none has a better name than Unsupported.
        const len = self.ms.encode(self.staging, self.packet_buf) catch |err| switch (err) {
            error.BufferTooSmall, error.InvalidFrameSize, error.EncoderFailed => return error.Unsupported,
        };
        const frame: u64 = self.ms.frameSamples();
        self.coded += frame;
        const granule = std.math.cast(i64, @min(self.coded, self.final_granule)) orelse return error.Unsupported;
        try self.ogg.writePacket(self.packet_buf[0..len], granule);
        self.page_samples += frame;
        // A page holds at most one second.
        if (self.page_samples + frame > 48000) {
            try self.ogg.flush();
            self.page_samples = 0;
        }
    }
};

/// A sample past this size is cut.
const max_input: f32 = 4;

/// The frames at 48 kHz that an input of `n` frames at `rate` gives.
fn outputFrames(n: u64, rate: u32) u64 {
    if (rate == 48000) return n;
    const wide = @as(u128, n) * 48000 + rate - 1;
    return @intCast(@min(wide / rate, std.math.maxInt(u64) / 2));
}

/// The rate that opusenc picks: 64 kbit/s for a mono stream and 32 kbit/s more for a coupled
/// one at 44.1 kHz and above, less for lower sample rates.
fn defaultBitrate(layout: multistream.Layout, rate: u32) u32 {
    const base: u64 = 64000 * @as(u64, layout.streams) + 32000 * @as(u64, layout.coupled);
    const khz = std.math.clamp(((if (rate < 44100) rate else 48000) + 1000) / 1000, 8, 48);
    return @intCast(((base * (khz + 16) + 32) >> 6));
}

/// The widest bandwidth that a signal of this sample rate can hold, with the limits that libopus
/// puts on the bandwidth for an input rate. A rate above 24 kHz has no limit.
fn inputBandwidth(rate: u32) ?packet.Bandwidth {
    if (rate <= 8000) return .narrow;
    if (rate <= 12000) return .medium;
    if (rate <= 16000) return .wide;
    if (rate <= 24000) return .super_wide;
    return null;
}

/// Sets `out[c]` to the input channel that the coded channel `c` reads. The coded order of 3 to 8
/// channels is the Vorbis order, the input is in WAVE order.
fn channelMap(out: []u8, mask: codec.ChannelMask) codec.EncoderInitError!void {
    vorbis.encode.channelMap(out, mask) catch return error.Unsupported;
}

fn testInfo(rate: u32, channels: u8) codec.Info {
    return .{ .rate = rate, .channels = channels };
}

fn encodeAll(gpa: std.mem.Allocator, info: codec.Info, options: opus.EncodeOptions, input: []const f32, chunk: usize) ![]u8 {
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
    total_frames: ?u64,

    fn deinit(self: Decoded, gpa: std.mem.Allocator) void {
        gpa.free(self.samples);
    }
};

fn decodeAll(gpa: std.mem.Allocator, bytes: []const u8) !Decoded {
    var input: io.Input = .init(.{ .bytes = bytes });
    var dec: opus.Decoder = try .init(gpa, &input);
    defer dec.deinit();
    const info = dec.info();
    return .{ .samples = try helpers.readAll(gpa, &dec, 4096), .rate = info.rate, .channels = info.channels, .total_frames = info.total_frames };
}

/// The frequency of the sine of channel `c`, in Hz. The low frequency channel of a 5.1 or 7.1
/// layout (the fourth in WAVE order) only carries the lowest bands, so it gets a bass tone.
fn toneFreq(rate: u32, channels: u8, c: usize) f64 {
    if (channels >= 6 and channels <= 8 and c == 3) return 80;
    return @as(f64, @floatFromInt(rate)) * 0.02 * @as(f64, @floatFromInt(c + 1));
}

/// A different sine on each channel, in WAVE order. The tones follow `tone_rate` and the samples
/// are taken at `rate`.
fn sinesAt(gpa: std.mem.Allocator, tone_rate: u32, rate: u32, channels: u8, frames: usize, amp: f32) ![]f32 {
    const out = try gpa.alloc(f32, frames * channels);
    for (0..frames) |i| {
        for (0..channels) |c| {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(rate));
            out[i * channels + c] = amp * @as(f32, @floatCast(@sin(2.0 * std.math.pi * toneFreq(tone_rate, channels, c) * t)));
        }
    }
    return out;
}

fn sines(gpa: std.mem.Allocator, rate: u32, channels: u8, frames: usize, amp: f32) ![]f32 {
    return sinesAt(gpa, rate, rate, channels, frames, amp);
}

/// The signal to noise ratio of one channel, in dB.
fn channelSnr(want: []const f32, got: []const f32, channels: usize, c: usize, frames: usize) f64 {
    var signal: f64 = 0;
    var noise: f64 = 0;
    for (0..frames) |i| {
        const w: f64 = want[i * channels + c];
        const g: f64 = got[i * channels + c];
        signal += w * w;
        noise += (w - g) * (w - g);
    }
    if (noise == 0) return 200;
    return 10 * std.math.log10(signal / noise);
}

/// The power of `x` at the frequency `freq`, from a projection on a sine and a cosine.
fn power(x: []const f32, channels: usize, c: usize, frames: usize, rate: u32, freq: f64) f64 {
    var re: f64 = 0;
    var im: f64 = 0;
    for (0..frames) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(rate));
        const v: f64 = x[i * channels + c];
        re += v * @cos(2.0 * std.math.pi * freq * t);
        im += v * @sin(2.0 * std.math.pi * freq * t);
    }
    return (re * re + im * im) / @as(f64, @floatFromInt(frames));
}

const PageInfo = struct {
    page: packets.Page,
    /// The sizes of the packets that end on the page.
    sizes: [255]usize,
    count: usize,
};

/// Reads the pages of `bytes` and calls `check` on each.
fn pageAt(bytes: []const u8, at: *usize) !PageInfo {
    const page = try packets.parsePage(bytes[at.*..]);
    at.* += page.size();
    var info: PageInfo = .{ .page = page, .sizes = undefined, .count = 0 };
    var run: usize = 0;
    for (page.lacing) |v| {
        run += v;
        if (v < 255) {
            info.sizes[info.count] = run;
            info.count += 1;
            run = 0;
        }
    }
    return info;
}

test "the headers and the granules are as RFC 7845 asks" {
    const gpa = testing.allocator;
    const cases = [_]struct { rate: u32, channels: u8, frames: usize }{
        .{ .rate = 48000, .channels = 1, .frames = 10000 },
        .{ .rate = 44100, .channels = 2, .frames = 9000 },
        .{ .rate = 16000, .channels = 1, .frames = 5000 },
        .{ .rate = 48000, .channels = 2, .frames = 0 },
    };
    for (cases) |case| {
        const input = try sines(gpa, case.rate, case.channels, case.frames, 0.3);
        defer gpa.free(input);
        const bytes = try encodeAll(gpa, testInfo(case.rate, case.channels), .{ .serial = 77 }, input, 777);
        defer gpa.free(bytes);
        var at: usize = 0;
        const first = try pageAt(bytes, &at);
        try testing.expect(first.page.flags.bos);
        try testing.expectEqual(@as(usize, 1), first.count);
        try testing.expectEqual(@as(i64, 0), first.page.granule);
        try testing.expectEqual(@as(u32, 77), first.page.serial);
        const h = try head.parseHead(first.page.body);
        try testing.expectEqual(@as(u8, 1), h.version);
        try testing.expectEqual(case.channels, h.channels);
        try testing.expectEqual(@as(u16, 312), h.pre_skip);
        try testing.expectEqual(case.rate, h.input_rate);
        try testing.expectEqual(@as(i16, 0), h.gain);
        try testing.expectEqual(@as(u8, 0), h.family);

        const tags = try pageAt(bytes, &at);
        try testing.expectEqual(@as(usize, 1), tags.count);
        try testing.expectEqual(@as(i64, 0), tags.page.granule);
        try testing.expect(!tags.page.flags.bos);
        try head.checkTags(tags.page.body);
        try testing.expectEqualStrings("OpusTags\x06\x00\x00\x00Chorus\x00\x00\x00\x00", tags.page.body);

        var last_granule: i64 = 0;
        var last_eos = false;
        var pages: usize = 0;
        var packets_seen: usize = 0;
        while (at < bytes.len) {
            const p = try pageAt(bytes, &at);
            pages += 1;
            packets_seen += p.count;
            try testing.expect(p.page.granule > last_granule or (p.page.granule == last_granule and pages == 1));
            // A page holds at most one second of audio.
            try testing.expect(p.page.granule - last_granule <= 48000);
            last_granule = p.page.granule;
            last_eos = p.page.flags.eos;
        }
        try testing.expect(last_eos);
        const want: i64 = @intCast(312 + outputFrames(case.frames, case.rate));
        try testing.expectEqual(want, last_granule);
        // The last packet adds enough frames to hold the pre-skip and the whole signal.
        try testing.expectEqual(@divFloor(want + 959, 960), @as(i64, @intCast(packets_seen)));
    }
}

test "the output has the length of the input at every rate" {
    const gpa = testing.allocator;
    const rates = [_]u32{ 8000, 11025, 16000, 22050, 44100, 48000, 96000 };
    const lengths = [_]usize{ 0, 1, 100, 959, 961, 2401 };
    for (rates) |rate| {
        for ([_]u8{ 1, 2 }) |channels| {
            for (lengths) |frames| {
                const input = try sines(gpa, rate, channels, frames, 0.3);
                defer gpa.free(input);
                const bytes = try encodeAll(gpa, testInfo(rate, channels), .{}, input, 500);
                defer gpa.free(bytes);
                const out = try decodeAll(gpa, bytes);
                defer out.deinit(gpa);
                const want = outputFrames(frames, rate);
                try testing.expectEqual(@as(u32, 48000), out.rate);
                try testing.expectEqual(channels, out.channels);
                try testing.expectEqual(want * channels, out.samples.len);
                try testing.expectEqual(@as(?u64, want), out.total_frames);
            }
        }
    }
}

test "every channel count keeps each sine on its channel" {
    const gpa = testing.allocator;
    const cases = [_]struct { rate: u32, channels: u8 }{
        .{ .rate = 48000, .channels = 3 },
        .{ .rate = 48000, .channels = 4 },
        .{ .rate = 44100, .channels = 5 },
        .{ .rate = 48000, .channels = 6 },
        .{ .rate = 48000, .channels = 7 },
        .{ .rate = 44100, .channels = 8 },
        .{ .rate = 48000, .channels = 11 },
    };
    for (cases) |case| {
        const frames: usize = 12000;
        const input = try sines(gpa, case.rate, case.channels, frames, 0.25);
        defer gpa.free(input);
        const bytes = try encodeAll(gpa, testInfo(case.rate, case.channels), .{}, input, 1000);
        defer gpa.free(bytes);
        const out = try decodeAll(gpa, bytes);
        defer out.deinit(gpa);
        const n = out.samples.len / case.channels;
        try testing.expectEqual(outputFrames(frames, case.rate), n);
        for (0..case.channels) |c| {
            // The decoded channel holds the tone of channel c and little of the others.
            const own = power(out.samples[0 .. n * case.channels], case.channels, c, n, 48000, toneFreq(case.rate, case.channels, c));
            try testing.expect(own > 0.01);
            for (0..case.channels) |k| {
                if (k == c) continue;
                const other = power(out.samples[0 .. n * case.channels], case.channels, c, n, 48000, toneFreq(case.rate, case.channels, k));
                try testing.expect(other < own / 30);
            }
        }
    }
}

test "the signal to noise ratio of sines stays above the floor" {
    const gpa = testing.allocator;
    // The floors are 4 to 8 dB under the values that the encoder reached: 43, 27, 24, 39 and 24 dB.
    const cases = [_]struct { rate: u32, channels: u8, floor: f64 }{
        .{ .rate = 48000, .channels = 1, .floor = 35 },
        .{ .rate = 48000, .channels = 2, .floor = 20 },
        .{ .rate = 44100, .channels = 2, .floor = 18 },
        .{ .rate = 16000, .channels = 1, .floor = 32 },
        .{ .rate = 48000, .channels = 6, .floor = 16 },
    };
    for (cases) |case| {
        const frames: usize = 24000;
        const input = try sines(gpa, case.rate, case.channels, frames, 0.3);
        defer gpa.free(input);
        const bytes = try encodeAll(gpa, testInfo(case.rate, case.channels), .{}, input, 4096);
        defer gpa.free(bytes);
        const out = try decodeAll(gpa, bytes);
        defer out.deinit(gpa);
        const n = out.samples.len / case.channels;
        const want = try sinesAt(gpa, case.rate, 48000, case.channels, n, 0.3);
        defer gpa.free(want);
        for (0..case.channels) |c| {
            const snr = channelSnr(want, out.samples, case.channels, c, n);
            try testing.expect(snr > case.floor);
        }
    }
}

test "the options that make no sense give Unsupported" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{}, testInfo(0, 2)));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{}, testInfo(48000, 0)));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .frame_ms = 7 }, testInfo(48000, 2)));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .frame_ms = std.math.nan(f32) }, testInfo(48000, 2)));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .bitrate = 100 }, testInfo(48000, 2)));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .bitrate = 3_000_000 }, testInfo(48000, 2)));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .packet_loss = 101 }, testInfo(48000, 2)));
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{ .complexity = 11 }, testInfo(48000, 2)));
}

test "the default bitrate follows opusenc" {
    const mono = try multistream.Layout.init(1);
    const stereo = try multistream.Layout.init(2);
    const surround = try multistream.Layout.init(6);
    try testing.expectEqual(@as(u32, 64000), defaultBitrate(mono, 48000));
    try testing.expectEqual(@as(u32, 96000), defaultBitrate(stereo, 48000));
    try testing.expectEqual(@as(u32, 96000), defaultBitrate(stereo, 44100));
    try testing.expectEqual(@as(u32, 49500), defaultBitrate(stereo, 16000));
    try testing.expectEqual(@as(u32, 320000), defaultBitrate(surround, 48000));
    try testing.expectEqual(@as(u32, 25000), defaultBitrate(mono, 8000));
}

test "constant bitrate packets have the size of the rate and pages stay under a second" {
    const gpa = testing.allocator;
    const frames: usize = 3 * 48000;
    const input = try sines(gpa, 48000, 1, frames, 0.3);
    defer gpa.free(input);
    const bytes = try encodeAll(gpa, testInfo(48000, 1), .{ .vbr = false, .bitrate = 40000 }, input, 4800);
    defer gpa.free(bytes);
    var at: usize = 0;
    _ = try pageAt(bytes, &at);
    _ = try pageAt(bytes, &at);
    var last: i64 = 0;
    var pages: usize = 0;
    while (at < bytes.len) {
        const p = try pageAt(bytes, &at);
        pages += 1;
        try testing.expect(p.page.granule - last <= 48000);
        last = p.page.granule;
        // 40 kbit/s and 20 ms frames make 100 bytes.
        for (p.sizes[0..p.count]) |size| try testing.expectEqual(@as(usize, 100), size);
    }
    try testing.expect(pages >= 3);
}

test "the write size does not change the stream" {
    const gpa = testing.allocator;
    for ([_]u32{ 44100, 48000 }) |rate| {
        const input = try sines(gpa, rate, 2, 3001, 0.3);
        defer gpa.free(input);
        const whole = try encodeAll(gpa, testInfo(rate, 2), .{}, input, 3001);
        defer gpa.free(whole);
        for ([_]usize{ 1, 7, 960, 1025 }) |chunk| {
            const part = try encodeAll(gpa, testInfo(rate, 2), .{}, input, chunk);
            defer gpa.free(part);
            try testing.expectEqualSlices(u8, whole, part);
        }
    }
}

test "every application and frame size gives the exact length" {
    const gpa = testing.allocator;
    const apps = [_]opus.Application{ .audio, .voip, .low_delay };
    const frame_sizes = [_]f32{ 2.5, 10, 20, 60, 120 };
    for (apps) |app| {
        for (frame_sizes) |ms| {
            for ([_]u8{ 1, 2 }) |channels| {
                const input = try sines(gpa, 44100, channels, 5000, 0.3);
                defer gpa.free(input);
                const bytes = try encodeAll(gpa, testInfo(44100, channels), .{ .application = app, .frame_ms = ms }, input, 1500);
                defer gpa.free(bytes);
                var at: usize = 0;
                const first = try pageAt(bytes, &at);
                const h = try head.parseHead(first.page.body);
                try testing.expectEqual(@as(u16, if (app == .low_delay) 120 else 312), h.pre_skip);
                const out = try decodeAll(gpa, bytes);
                defer out.deinit(gpa);
                try testing.expectEqual(outputFrames(5000, 44100) * channels, out.samples.len);
            }
        }
    }
}

test "a coded signal that fills a frame without a rest still ends on the granule" {
    const gpa = testing.allocator;
    // 648 frames and the pre-skip of 312 make exactly one packet of 960.
    const input = try sines(gpa, 48000, 1, 648, 0.3);
    defer gpa.free(input);
    const bytes = try encodeAll(gpa, testInfo(48000, 1), .{}, input, 648);
    defer gpa.free(bytes);
    var at: usize = 0;
    _ = try pageAt(bytes, &at);
    _ = try pageAt(bytes, &at);
    const audio = try pageAt(bytes, &at);
    try testing.expectEqual(@as(usize, 1), audio.count);
    try testing.expectEqual(@as(i64, 960), audio.page.granule);
    try testing.expect(audio.page.flags.eos);
    try testing.expectEqual(bytes.len, at);
}

test "a mask that the layout cannot use gives Unsupported" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const mask: codec.ChannelMask = .{ .front_left = true, .front_center = true, .back_center = true, .side_left = true };
    try testing.expectError(error.Unsupported, Encoder.init(gpa, &aw.writer, .{}, .{ .rate = 48000, .channels = 4, .mask = mask }));
}

test "a mask with side speakers keeps the layout" {
    const gpa = testing.allocator;
    // Four channels with side speakers use the same coded order as back speakers.
    const mask: codec.ChannelMask = .{ .front_left = true, .front_right = true, .side_left = true, .side_right = true };
    const input = try sines(gpa, 48000, 4, 6000, 0.3);
    defer gpa.free(input);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc: Encoder = try .init(gpa, &aw.writer, .{}, .{ .rate = 48000, .channels = 4, .mask = mask });
    defer enc.deinit();
    try enc.write(input);
    try enc.finish();
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, enc.input_map[0..4]);
    const out = try decodeAll(gpa, aw.written());
    defer out.deinit(gpa);
    try testing.expectEqual(@as(usize, 6000 * 4), out.samples.len);
}

test "samples that are not finite or too large are cleaned" {
    const gpa = testing.allocator;
    const input = try sines(gpa, 44100, 2, 4000, 0.3);
    defer gpa.free(input);
    input[10] = std.math.nan(f32);
    input[11] = std.math.inf(f32);
    input[500] = -std.math.inf(f32);
    input[501] = 1e30;
    const bytes = try encodeAll(gpa, testInfo(44100, 2), .{}, input, 999);
    defer gpa.free(bytes);
    const out = try decodeAll(gpa, bytes);
    defer out.deinit(gpa);
    try testing.expectEqual(outputFrames(4000, 44100) * 2, out.samples.len);
    for (out.samples) |v| try testing.expect(std.math.isFinite(v) and v >= -1 and v < 1);
}

test "a partial frame and a write after finish are refused" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc: Encoder = try .init(gpa, &aw.writer, .{}, testInfo(48000, 2));
    defer enc.deinit();
    try testing.expectError(error.Unsupported, enc.write(&.{ 0.1, 0.2, 0.3 }));
    try enc.write(&.{ 0.1, 0.2, 0.3, 0.4 });
    try enc.finish();
    const size = aw.written().len;
    try testing.expectError(error.Unsupported, enc.write(&.{ 0.1, 0.2 }));
    try enc.finish();
    try testing.expectEqual(size, aw.written().len);
}

test "the largest channel count codes one stream per channel" {
    const gpa = testing.allocator;
    const input = try sines(gpa, 48000, 255, 1500, 0.1);
    defer gpa.free(input);
    const bytes = try encodeAll(gpa, testInfo(48000, 255), .{ .bitrate = 255 * 8000 }, input, 1500);
    defer gpa.free(bytes);
    var at: usize = 0;
    const first = try pageAt(bytes, &at);
    const h = try head.parseHead(first.page.body);
    try testing.expectEqual(@as(u8, 255), h.family);
    try testing.expectEqual(@as(u8, 255), h.streams);
    try testing.expectEqual(@as(u8, 0), h.coupled);
    try testing.expectEqual(@as(u8, 254), h.mapping[254]);
    const out = try decodeAll(gpa, bytes);
    defer out.deinit(gpa);
    try testing.expectEqual(@as(usize, 1500 * 255), out.samples.len);
}

test "random options, rates, channels and samples encode and decode" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x0badc0de);
    const rnd = prng.random();
    const rates = [_]u32{ 8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 192000, 7, 100000 };
    const frame_sizes = [_]f32{ 2.5, 5, 10, 20, 40, 60, 80, 100, 120 };
    var skipped: usize = 0;
    for (0..40) |_| {
        const rate = rates[rnd.uintLessThan(usize, rates.len)];
        const channels: u8 = if (rnd.uintLessThan(u8, 8) == 0) rnd.intRangeAtMost(u8, 9, 20) else rnd.intRangeAtMost(u8, 1, 8);
        const frames = rnd.uintLessThan(usize, if (rate < 100) 20 else 4000);
        const options: opus.EncodeOptions = .{
            .bitrate = if (rnd.boolean()) 0 else rnd.intRangeAtMost(u32, 500, 256_000 * @as(u32, channels)),
            .application = rnd.enumValue(opus.Application),
            .vbr = rnd.boolean(),
            .frame_ms = frame_sizes[rnd.uintLessThan(usize, frame_sizes.len)],
            .serial = rnd.int(u32),
            .packet_loss = if (rnd.boolean()) 0 else rnd.intRangeAtMost(u8, 1, 100),
            .complexity = rnd.uintAtMost(u4, 10),
        };
        const input = try gpa.alloc(f32, frames * channels);
        defer gpa.free(input);
        for (input) |*v| {
            v.* = switch (rnd.uintLessThan(u8, 40)) {
                0 => std.math.nan(f32),
                1 => std.math.inf(f32),
                2 => -std.math.inf(f32),
                3 => rnd.floatNorm(f32) * 100,
                else => rnd.floatNorm(f32) * 0.2,
            };
        }
        const bytes = encodeAll(gpa, testInfo(rate, channels), options, input, rnd.intRangeAtMost(usize, 1, 3000)) catch |err| switch (err) {
            error.Unsupported => {
                skipped += 1;
                continue;
            },
            else => return err,
        };
        defer gpa.free(bytes);
        const out = try decodeAll(gpa, bytes);
        defer out.deinit(gpa);
        try testing.expectEqual(outputFrames(frames, rate) * channels, out.samples.len);
        for (out.samples) |v| try testing.expect(std.math.isFinite(v) and v >= -1 and v < 1);
    }
    try testing.expectEqual(@as(usize, 0), skipped);
}

test "a low sample rate limits the bandwidth like libopus" {
    try testing.expectEqual(@as(?packet.Bandwidth, .narrow), inputBandwidth(8000));
    try testing.expectEqual(@as(?packet.Bandwidth, .medium), inputBandwidth(11025));
    try testing.expectEqual(@as(?packet.Bandwidth, .medium), inputBandwidth(12000));
    try testing.expectEqual(@as(?packet.Bandwidth, .wide), inputBandwidth(16000));
    try testing.expectEqual(@as(?packet.Bandwidth, .super_wide), inputBandwidth(22050));
    try testing.expectEqual(@as(?packet.Bandwidth, .super_wide), inputBandwidth(24000));
    try testing.expectEqual(@as(?packet.Bandwidth, null), inputBandwidth(32000));
    try testing.expectEqual(@as(?packet.Bandwidth, null), inputBandwidth(48000));
}
