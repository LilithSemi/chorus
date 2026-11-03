//! Plays sounds that are loaded fully into memory and sounds that are streamed from a source, mixed
//! on one playback stream.
//!
//! A streamed voice is decoded in the pump, which runs in `Context.dispatch` on the app thread.
//! The render path cannot wake the app, so an app that waits on `Context.fd` must also wait for
//! `Context.timeoutMs` and call `dispatch` when `fd` is readable or the time is over. Read the hint
//! again before each wait, because `stream` and `setPaused` change it. A stopped voice gives a
//! short hint until the pump frees it. With a plain `poll` call:
//!
//!     const wait = ctx.timeoutMs();
//!     poll(fd, wait orelse -1);
//!     ctx.dispatch();
//!
//! The Player asks for a call when its emptiest ring has fallen to half of `stream_buffer_ms`.
//! Ended events of loaded sounds have no timer, so they reach the listener at the next dispatch.
const std = @import("std");
const codec = @import("codec");
const Format = @import("Format.zig");
const Context = @import("Context.zig");
const Stream = @import("Stream.zig");
const Mixer = @import("Mixer.zig");
const Null = @import("backend/Null.zig");
const Player = @This();
const builtin = @import("builtin");

const dsp = @import("dsp.zig");
const spsc = @import("spsc.zig");

context: *Context,
gpa: std.mem.Allocator,
options: Options,
playback: *Stream,
commands: spsc.Spsc(Command),
events: spsc.Spsc(Voice),
ramp_frames: u32,
listener: ?Listener = null,
rejected: u32 = 0,
/// Underruns of stream voices that have ended.
underruns_done: u32 = 0,
stream_errors: u32 = 0,
fill_start: usize = 0,
/// Control side. Sounds and the voice slots that mirror the audio side.
sounds: std.ArrayList(SoundSlot) = .empty,
slots: []Slot,
// The next three fields belong to the audio thread.
voices: []AudioVoice,
mix_scratch: []f32,
master: dsp.gain.Ramp = .init(1),

pub const Options = struct {
    voices: u16 = 32,
    /// The sample type must be f32.
    format: Format = .{ .sample = .f32, .rate = 48000, .channels = .stereo },
    device: ?Mixer.Id = null,
    latency_frames: u32 = 512,
    role: Stream.Role = .media,
    /// Commands that can wait for the audio thread. The queue size is a power of two at least this
    /// big.
    command_queue: u32 = 256,
    /// Audio that the pump keeps ready for each streamed voice. The ring size is a power of two
    /// at least this big, but the pump fills only this much.
    stream_buffer_ms: u32 = 500,
};

pub const PlayOptions = struct {
    /// From 0 to 16. Other values are clamped.
    gain: f32 = 1,
    /// A loop of a resampled sound can have a small click at the seam.
    loop: bool = false,
    paused: bool = false,
};

/// A handle with a generation. A handle of an unloaded sound or an ended voice is never valid
/// again.
pub const Sound = struct { index: u16 = 0, generation: u32 = 0 };
pub const Voice = struct { index: u16 = 0, generation: u32 = 0 };

pub const FailReason = enum { bad_data, read_failed, out_of_memory };

/// A streamed voice met an error while it decoded. It plays what was decoded before, then
/// `ended` follows for the same voice.
pub const Failure = struct { voice: Voice, reason: FailReason };

pub const Event = union(enum) { ended: Voice, failed: Failure };

/// Runs on the app thread during `Context.dispatch` with `ended` and `failed` events. It can call
/// the Player, but not `deinit`.
pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, player: *Player, event: Event) void,
};

pub const Stats = struct {
    /// Voices that have not reported their end yet.
    active_voices: u32,
    /// Commands that were refused with `error.Busy`.
    rejected_commands: u32,
    /// Audio blocks (up to 256 frames) in which a streamed voice had too few frames and played
    /// silence. The count wraps at 2^32.
    underruns: u32,
    /// Streamed voices that ended with a decode error.
    stream_errors: u32,
    /// Underruns of the playback stream as the audio system reports them. See `Stream.Stats`.
    xruns: u64,
};

pub const InitError = Stream.OpenError || error{ InvalidOptions, CapacityTooLarge };
pub const LoadError = codec.InitError || codec.ReadError || error{ UnsupportedFormat, EmptySound, TooLarge, TooManySounds };
pub const PlayError = error{ UnknownSound, NoFreeVoice, Busy };
pub const StreamError = codec.InitError || error{ EmptySound, UnsupportedFormat, Unseekable, NoFreeVoice, Busy, CapacityTooLarge };
pub const CommandError = error{Busy};
pub const LoopError = CommandError || error{Unseekable};

const max_gain = 16;
const block_frames: usize = 256;
const ramp_ms = 5;
/// Frames that the pump decodes for all streamed voices together. At 48 kHz this is about 170 ms of
/// audio, which keeps one pump short.
const pump_frames: usize = 8192;
const chunk_frames: usize = 1024;
const flush_frames: usize = 64;
const max_flush_frames: usize = 1 << 16;

const SoundSlot = struct {
    /// Null when the slot is free.
    samples: ?[]f32 = null,
    frames: u32 = 0,
    generation: u32 = 1,
    unloading: bool = false,
    /// Voices that play it and have not reported their end.
    users: u32 = 0,
};

const Slot = struct {
    generation: u32 = 0,
    active: bool = false,
    sound: u16 = 0,
    /// Set for a streamed voice. The pump frees it after the ended event.
    feed: ?*Feed = null,
};

const Command = union(enum) {
    play: struct { voice: Voice, source: Source, gain: f32, loop: bool, paused: bool },
    stop: Voice,
    gain: struct { voice: Voice, gain: f32 },
    loop: struct { voice: Voice, loop: bool },
    paused: struct { voice: Voice, paused: bool },
    master: f32,
    stop_all,
};

/// Where a voice reads from.
const Source = union(enum) {
    memory: struct { samples: []const f32 },
    ring: *Ring,
};

/// The frames of a streamed voice. The pump writes and the audio thread reads.
const Ring = struct {
    frames: spsc.FrameRing,
    /// The pump sets it after its last write.
    eof: std.atomic.Value(bool) = .init(false),
    underruns: std.atomic.Value(u32) = .init(0),
};

const AudioVoice = struct {
    state: enum { idle, playing, ending } = .idle,
    generation: u32 = 0,
    source: union(enum) { memory: struct { samples: []const f32, position: usize }, ring: *Ring } = undefined,
    loop: bool = false,
    paused: bool = false,
    stopping: bool = false,
    gain: dsp.gain.Ramp = .init(1),
    fade: dsp.gain.Ramp = .init(1),
};

pub fn init(ctx: *Context, options: Options) InitError!*Player {
    if (options.voices == 0 or options.command_queue == 0 or options.stream_buffer_ms == 0) return error.InvalidOptions;
    if (options.format.sample != .f32) return error.UnsupportedFormat;
    try options.format.validate();
    const gpa = ctx.gpa;
    const self = try gpa.create(Player);
    errdefer gpa.destroy(self);
    var commands: spsc.Spsc(Command) = try .init(gpa, options.command_queue);
    errdefer commands.deinit(gpa);
    var events: spsc.Spsc(Voice) = try .init(gpa, options.voices);
    errdefer events.deinit(gpa);
    const slots = try gpa.alloc(Slot, options.voices);
    errdefer gpa.free(slots);
    @memset(slots, .{});
    const voices = try gpa.alloc(AudioVoice, options.voices);
    errdefer gpa.free(voices);
    @memset(voices, .{});
    const mix_scratch = try gpa.alloc(f32, block_frames * options.format.channels.count);
    errdefer gpa.free(mix_scratch);
    self.* = .{
        .context = ctx,
        .gpa = gpa,
        .options = options,
        .playback = undefined,
        .commands = commands,
        .events = events,
        .ramp_frames = @max(1, options.format.rate / 1000 * ramp_ms),
        .slots = slots,
        .voices = voices,
        .mix_scratch = mix_scratch,
    };
    self.playback = try ctx.openStream(.{
        .direction = .playback,
        .format = options.format,
        .device = options.device,
        .latency_frames = options.latency_frames,
        .role = options.role,
        .callback = .{ .ctx = self, .func = render },
    });
    errdefer self.playback.close();
    try ctx.addPump(.{ .ctx = self, .func = pump, .timeout = timeoutHint });
    errdefer ctx.removePump(.{ .ctx = self, .func = pump, .timeout = timeoutHint });
    try self.playback.start();
    return self;
}

/// Call it before `Context.deinit`.
pub fn deinit(self: *Player) void {
    self.context.removePump(.{ .ctx = self, .func = pump, .timeout = timeoutHint });
    self.playback.close();
    const gpa = self.gpa;
    for (self.slots) |slot| {
        if (slot.feed) |feed| feed.deinit(gpa);
    }
    for (self.sounds.items) |slot| {
        if (slot.samples) |samples| gpa.free(samples);
    }
    self.sounds.deinit(gpa);
    gpa.free(self.mix_scratch);
    gpa.free(self.voices);
    gpa.free(self.slots);
    self.events.deinit(gpa);
    self.commands.deinit(gpa);
    gpa.destroy(self);
}

/// Decodes the whole source and converts it to the player format. The sound is in memory up to
/// three times during the call, so it suits short sounds. The source is not used after the call.
/// Each link of a chained file is converted by itself, so the sound can change format.
pub fn load(self: *Player, source: codec.Source, options: codec.Decoder.Options) LoadError!Sound {
    const gpa = self.gpa;
    var decoder: codec.Decoder = try .initOptions(gpa, source, .auto, options);
    defer decoder.deinit();
    var info = decoder.info();
    try checkInfo(info);

    var raw: std.ArrayList(f32) = .empty;
    defer raw.deinit(gpa);
    // Links of a chained file with another format are converted one at a time.
    var done: std.ArrayList(f32) = .empty;
    defer done.deinit(gpa);
    const chunk = try gpa.alloc(f32, 4096 * Format.max_channels);
    defer gpa.free(chunk);
    while (true) {
        const channels: usize = info.channels;
        const n = decoder.read(chunk[0 .. 4096 * channels]) catch |err| switch (err) {
            error.Truncated => break,
            error.StreamChanged => {
                if (raw.items.len > 0) {
                    const part = try self.convert(raw.items, info);
                    defer gpa.free(part);
                    try done.appendSlice(gpa, part);
                    raw.clearRetainingCapacity();
                }
                info = decoder.info();
                try checkInfo(info);
                continue;
            },
            else => |e| return e,
        };
        if (n == 0) break;
        try raw.appendSlice(gpa, chunk[0 .. n * channels]);
    }
    if (raw.items.len == 0 and done.items.len == 0) return error.EmptySound;

    const samples = if (done.items.len == 0) try self.convert(raw.items, info) else blk: {
        if (raw.items.len > 0) {
            const part = try self.convert(raw.items, info);
            defer gpa.free(part);
            try done.appendSlice(gpa, part);
        }
        break :blk try done.toOwnedSlice(gpa);
    };
    errdefer gpa.free(samples);
    const dst_channels = self.options.format.channels.count;
    const frames = std.math.cast(u32, samples.len / dst_channels) orelse return error.TooLarge;
    for (samples) |*s| {
        if (!std.math.isFinite(s.*)) s.* = 0;
    }
    return self.addSound(samples, frames);
}

fn addSound(self: *Player, samples: []f32, frames: u32) error{ OutOfMemory, TooManySounds }!Sound {
    var index: usize = self.sounds.items.len;
    for (self.sounds.items, 0..) |slot, i| {
        if (slot.samples == null) {
            index = i;
            break;
        }
    }
    if (index == self.sounds.items.len) {
        if (index > std.math.maxInt(u16)) return error.TooManySounds;
        try self.sounds.append(self.gpa, .{});
    }
    const slot = &self.sounds.items[index];
    slot.samples = samples;
    slot.frames = frames;
    slot.unloading = false;
    slot.users = 0;
    return .{ .index = @intCast(index), .generation = slot.generation };
}

/// Gives interleaved samples in the player format. The result is owned by the caller.
fn convert(self: *Player, raw: []const f32, info: codec.Info) error{OutOfMemory}![]f32 {
    const gpa = self.gpa;
    const dst = self.options.format;
    const src_channels = channelsOf(info);
    const frames = raw.len / info.channels;
    const dst_count: usize = dst.channels.count;

    const mapped = try gpa.alloc(f32, frames * dst_count);
    errdefer gpa.free(mapped);
    const remap: dsp.remap.Remap = .init(src_channels, dst.channels);
    remap.process(raw, mapped);
    if (info.rate == dst.rate) return mapped;
    defer gpa.free(mapped);

    const expected: usize = @intCast((@as(u64, frames) * dst.rate + info.rate - 1) / info.rate);
    const out = try gpa.alloc(f32, expected * dst_count);
    errdefer gpa.free(out);
    @memset(out, 0);
    var resampler: dsp.resample.Resampler = try .init(gpa, .{
        .channels = dst.channels.count,
        .in_rate = info.rate,
        .out_rate = dst.rate,
        .quality = .best,
    });
    defer resampler.deinit(gpa);
    var consumed: usize = 0;
    var produced: usize = 0;
    while (consumed < frames) {
        const r = resampler.process(mapped[consumed * dst_count ..], out[produced * dst_count ..]);
        consumed += r.in_frames;
        produced += r.out_frames;
        if (r.in_frames == 0 and r.out_frames == 0) break;
    }
    // Zeros push the last input frames through the filter.
    const zeros: [64 * Format.max_channels]f32 = @splat(0);
    while (produced < expected) {
        const r = resampler.process(zeros[0 .. 64 * dst_count], out[produced * dst_count ..]);
        produced += r.out_frames;
        if (r.in_frames == 0 and r.out_frames == 0) break;
    }
    return out;
}

fn checkInfo(info: codec.Info) error{UnsupportedFormat}!void {
    if (info.channels == 0 or info.channels > Format.max_channels) return error.UnsupportedFormat;
    if (info.rate < Format.min_rate or info.rate > Format.max_rate) return error.UnsupportedFormat;
}

fn channelsOf(info: codec.Info) Format.Channels {
    const count = info.channels;
    if (count == 1) return .mono;
    const mask: u32 = @bitCast(info.mask);
    if (@popCount(mask) == count) {
        // Format has no center-of-front or back center position. Those fold to front left,
        // front right and mono.
        const table = [_]Format.Position{
            .front_left,  .front_right, .front_center, .lfe,        .rear_left, .rear_right, .front_left,
            .front_right, .mono,        .side_left,    .side_right,
        };
        var positions: [Format.max_channels]Format.Position = undefined;
        var n: usize = 0;
        for (0..32) |bit| {
            if (mask >> @intCast(bit) & 1 == 0) continue;
            positions[n] = if (bit < table.len) table[bit] else .aux(@intCast(bit));
            n += 1;
        }
        return .init(positions[0..n]);
    }
    return switch (count) {
        2 => .stereo,
        6 => .surround_5_1,
        8 => .surround_7_1,
        else => blk: {
            var positions: [Format.max_channels]Format.Position = undefined;
            for (positions[0..count], 0..) |*p, i| p.* = .aux(@intCast(i));
            break :blk .init(positions[0..count]);
        },
    };
}

/// Marks the sound. Its memory is freed when no voice plays it. A stale handle does nothing.
pub fn unload(self: *Player, sound: Sound) void {
    const slot = self.soundSlot(sound) orelse return;
    slot.unloading = true;
    self.freeIfUnused(slot);
}

fn soundSlot(self: *Player, sound: Sound) ?*SoundSlot {
    if (sound.index >= self.sounds.items.len) return null;
    const slot = &self.sounds.items[sound.index];
    if (slot.samples == null or slot.unloading or slot.generation != sound.generation) return null;
    return slot;
}

fn freeIfUnused(self: *Player, slot: *SoundSlot) void {
    if (!slot.unloading or slot.users != 0) return;
    if (slot.samples) |samples| self.gpa.free(samples);
    slot.samples = null;
    slot.unloading = false;
    slot.generation = nextGeneration(slot.generation);
}

fn nextGeneration(generation: u32) u32 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}

/// Converts decoded chunks to the player format. It is the streaming form of `convert`.
const Converter = struct {
    remap: dsp.remap.Remap,
    src_channels: usize,
    dst_channels: usize,
    in_rate: u32,
    out_rate: u32,
    resampler: ?dsp.resample.Resampler,
    raw: []f32,
    /// Remapped frames that wait for the resampler. Empty when the rates are equal.
    mapped: []f32,
    pending: []f32,
    mapped_pos: usize = 0,
    mapped_len: usize = 0,
    pend_pos: usize = 0,
    pend_len: usize = 0,
    in_total: u64 = 0,
    out_total: u64 = 0,
    flushing: bool = false,
    flush_fed: usize = 0,
    end: Step = .eof,

    const Step = enum { data, eof, changed };

    fn init(gpa: std.mem.Allocator, info: codec.Info, dst: Format) error{ OutOfMemory, UnsupportedFormat }!Converter {
        try checkInfo(info);
        const src_channels: usize = info.channels;
        const dst_channels: usize = dst.channels.count;
        const rate_differs = info.rate != dst.rate;
        const raw = try gpa.alloc(f32, chunk_frames * src_channels);
        errdefer gpa.free(raw);
        const mapped = try gpa.alloc(f32, if (rate_differs) chunk_frames * dst_channels else 0);
        errdefer gpa.free(mapped);
        const pending_frames = if (rate_differs) chunk_frames * dst.rate / info.rate + 32 else chunk_frames;
        const pending = try gpa.alloc(f32, pending_frames * dst_channels);
        errdefer gpa.free(pending);
        var resampler: ?dsp.resample.Resampler = null;
        if (rate_differs) resampler = try .init(gpa, .{
            .channels = dst.channels.count,
            .in_rate = info.rate,
            .out_rate = dst.rate,
            .quality = .best,
        });
        return .{
            .remap = .init(channelsOf(info), dst.channels),
            .src_channels = src_channels,
            .dst_channels = dst_channels,
            .in_rate = info.rate,
            .out_rate = dst.rate,
            .resampler = resampler,
            .raw = raw,
            .mapped = mapped,
            .pending = pending,
        };
    }

    fn deinit(self: *Converter, gpa: std.mem.Allocator) void {
        if (self.resampler) |*r| r.deinit(gpa);
        gpa.free(self.raw);
        gpa.free(self.mapped);
        gpa.free(self.pending);
        self.* = undefined;
    }

    fn expected(self: *const Converter) u64 {
        return (self.in_total * self.out_rate + self.in_rate - 1) / self.in_rate;
    }

    /// Fills `pending` with the next converted frames. Gives `.eof` or `.changed` once the end of
    /// the input and the tail of the filter have come out.
    fn produce(self: *Converter, decoder: *codec.Decoder) error{ BadData, ReadFailed }!Step {
        self.pend_pos = 0;
        self.pend_len = 0;
        if (self.mapped_pos < self.mapped_len) {
            self.resample();
            return .data;
        }
        if (!self.flushing) {
            const n = decoder.read(self.raw) catch |err| switch (err) {
                error.Truncated => 0,
                error.StreamChanged => blk: {
                    self.end = .changed;
                    break :blk 0;
                },
                error.BadData => return error.BadData,
                error.ReadFailed => return error.ReadFailed,
            };
            if (n > 0) {
                self.in_total += n;
                const raw = self.raw[0 .. n * self.src_channels];
                if (self.resampler == null) {
                    self.remap.process(raw, self.pending[0 .. n * self.dst_channels]);
                    self.pend_len = n;
                    self.out_total += n;
                } else {
                    self.remap.process(raw, self.mapped[0 .. n * self.dst_channels]);
                    self.mapped_pos = 0;
                    self.mapped_len = n;
                    self.resample();
                }
                return .data;
            }
            self.flushing = true;
        }
        if (self.resampler == null or self.out_total >= self.expected() or self.flush_fed >= max_flush_frames) return self.end;
        self.flush_fed += flush_frames;
        // Zeros push the last input frames through the filter.
        @memset(self.mapped[0 .. flush_frames * self.dst_channels], 0);
        self.mapped_pos = 0;
        self.mapped_len = flush_frames;
        self.resample();
        return .data;
    }

    fn resample(self: *Converter) void {
        const resampler = &self.resampler.?;
        const dst = self.dst_channels;
        const room = self.pending.len / dst;
        while (self.mapped_pos < self.mapped_len and self.pend_len < room) {
            const r = resampler.process(
                self.mapped[self.mapped_pos * dst .. self.mapped_len * dst],
                self.pending[self.pend_len * dst ..],
            );
            self.mapped_pos += r.in_frames;
            self.pend_len += r.out_frames;
            if (r.in_frames == 0 and r.out_frames == 0) self.mapped_pos = self.mapped_len;
        }
        if (self.flushing) {
            const left = self.expected() -| self.out_total;
            if (self.pend_len > left) {
                self.pend_len = @intCast(left);
                self.mapped_pos = self.mapped_len;
            }
        }
        self.out_total += self.pend_len;
    }
};

/// The control side of a streamed voice. The pump owns it.
const Feed = struct {
    ring: *Ring,
    decoder: codec.Decoder,
    conv: Converter,
    loop: bool,
    paused: bool,
    /// The voice was told to stop, so the pump does not decode for it.
    halted: bool = false,
    finished: bool = false,
    reason: ?FailReason = null,
    /// Samples that the pump keeps in the ring.
    target: u32,
    /// Frames converted since the last seek to the start.
    pass_out: u64 = 0,

    fn deinit(self: *Feed, gpa: std.mem.Allocator) void {
        self.conv.deinit(gpa);
        self.decoder.deinit();
        self.ring.frames.deinit(gpa);
        gpa.destroy(self.ring);
        gpa.destroy(self);
    }

    fn finish(self: *Feed) void {
        self.finished = true;
        self.ring.eof.store(true, .release);
    }
};

/// Decodes into the ring of `feed` until the ring holds its target, the source ends, or the
/// budget of frames is used.
fn fillFeed(self: *Player, feed: *Feed, budget: *usize) void {
    const channels = feed.conv.dst_channels;
    const ring = &feed.ring.frames;
    while (budget.* > 0 and !feed.finished) {
        const level = ring.readAvailable();
        if (level >= feed.target) return;
        const room = @min(@min((feed.target - level) / channels, ring.writeAvailable() / channels), budget.*);
        if (room == 0) return;
        const conv = &feed.conv;
        if (conv.pend_pos < conv.pend_len) {
            const n = @min(room, conv.pend_len - conv.pend_pos);
            const written = ring.write(conv.pending[conv.pend_pos * channels ..][0 .. n * channels]);
            std.debug.assert(written == n * channels);
            conv.pend_pos += n;
            budget.* -= n;
            feed.pass_out += n;
            continue;
        }
        const step = conv.produce(&feed.decoder) catch |err| return failFeed(feed, switch (err) {
            error.BadData => .bad_data,
            error.ReadFailed => .read_failed,
        });
        switch (step) {
            .data => {},
            .changed => self.restartConverter(feed),
            .eof => if (feed.loop and feed.pass_out > 0) {
                feed.decoder.seek(0) catch |err| return failFeed(feed, switch (err) {
                    error.OutOfMemory => .out_of_memory,
                    error.Unsupported, error.BadData, error.Truncated => .bad_data,
                    error.Unseekable, error.ReadFailed => .read_failed,
                });
                feed.pass_out = 0;
                self.restartConverter(feed);
            } else feed.finish(),
        }
    }
}

/// Builds the converter again for the format that the decoder reports now.
fn restartConverter(self: *Player, feed: *Feed) void {
    const next = Converter.init(self.gpa, feed.decoder.info(), self.options.format) catch |err| {
        return failFeed(feed, switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.UnsupportedFormat => .bad_data,
        });
    };
    feed.conv.deinit(self.gpa);
    feed.conv = next;
}

fn failFeed(feed: *Feed, reason: FailReason) void {
    feed.reason = reason;
    feed.finish();
}

/// Starts a voice that plays a source while it decodes it. The pump decodes in `Context.dispatch`,
/// and one pump decodes at most 8192 frames for all streamed voices together. The first frames are
/// ready before the call returns. A voice counts against `Options.voices`. The decoder reads the
/// source until the voice has ended. With `loop` the source must seek, else the call gives
/// `error.Unseekable`. The end of the source, and a source that is cut off, end the voice. An error
/// in the middle of the source also ends it, after the frames before the error, with a `failed`
/// event first. A pump that runs late gives silence for the missing frames and counts an
/// underrun. The voice does not skip ahead. A chained file whose format changes plays on.
pub fn stream(self: *Player, source: codec.Source, options: PlayOptions) StreamError!Voice {
    const gpa = self.gpa;
    const index = for (self.slots, 0..) |slot, i| {
        if (!slot.active) break i;
    } else return error.NoFreeVoice;
    const wanted = @max(@as(u64, block_frames), @as(u64, self.options.format.rate) * self.options.stream_buffer_ms / 1000);
    const target_frames = std.math.cast(u32, wanted) orelse return error.CapacityTooLarge;
    const target = std.math.mul(u32, target_frames, self.options.format.channels.count) catch return error.CapacityTooLarge;

    // The fields are set in place, because filling the feed changes them.
    const feed = try gpa.create(Feed);
    errdefer gpa.destroy(feed);
    feed.decoder = try .init(gpa, source, .auto);
    errdefer feed.decoder.deinit();
    if (options.loop and !feed.decoder.input.seekable()) return error.Unseekable;
    feed.conv = try .init(gpa, feed.decoder.info(), self.options.format);
    errdefer feed.conv.deinit(gpa);
    const ring = try gpa.create(Ring);
    errdefer gpa.destroy(ring);
    ring.* = .{ .frames = try .init(gpa, target) };
    errdefer ring.frames.deinit(gpa);
    feed.ring = ring;
    feed.loop = options.loop;
    feed.paused = options.paused;
    feed.halted = false;
    feed.finished = false;
    feed.reason = null;
    feed.target = target;
    feed.pass_out = 0;
    var budget: usize = pump_frames;
    self.fillFeed(feed, &budget);
    if (ring.frames.readAvailable() == 0 and feed.finished) {
        const reason = feed.reason orelse return error.EmptySound;
        return switch (reason) {
            .bad_data => error.BadData,
            .read_failed => error.ReadFailed,
            .out_of_memory => error.OutOfMemory,
        };
    }

    const slot = &self.slots[index];
    const voice: Voice = .{ .index = @intCast(index), .generation = nextGeneration(slot.generation) };
    try self.send(.{ .play = .{
        .voice = voice,
        .source = .{ .ring = ring },
        .gain = cleanGain(options.gain),
        .loop = false,
        .paused = options.paused,
    } });
    slot.* = .{ .generation = voice.generation, .active = true, .feed = feed };
    return voice;
}

/// Starts a voice. The voice starts at its gain with no fade in.
pub fn play(self: *Player, sound: Sound, options: PlayOptions) PlayError!Voice {
    const sound_slot = self.soundSlot(sound) orelse return error.UnknownSound;
    const index = for (self.slots, 0..) |slot, i| {
        if (!slot.active) break i;
    } else return error.NoFreeVoice;
    const slot = &self.slots[index];
    const voice: Voice = .{ .index = @intCast(index), .generation = nextGeneration(slot.generation) };
    try self.send(.{ .play = .{
        .voice = voice,
        .source = .{ .memory = .{ .samples = sound_slot.samples.? } },
        .gain = cleanGain(options.gain),
        .loop = options.loop,
        .paused = options.paused,
    } });
    slot.* = .{ .generation = voice.generation, .active = true, .sound = sound.index };
    sound_slot.users += 1;
    return voice;
}

/// Fades the voice out over about 5 ms, then ends it. When the call gives `error.Busy`, the voice
/// keeps playing.
pub fn stop(self: *Player, voice: Voice) CommandError!void {
    if (!self.isActive(voice)) return;
    try self.send(.{ .stop = voice });
    if (self.slots[voice.index].feed) |feed| feed.halted = true;
}

pub fn setGain(self: *Player, voice: Voice, gain: f32) CommandError!void {
    if (!self.isActive(voice)) return;
    try self.send(.{ .gain = .{ .voice = voice, .gain = cleanGain(gain) } });
}

/// A loop on a streamed voice needs a source that seeks, else the call gives `error.Unseekable`.
/// A change takes effect after the frames that are already in the ring. A loop set after the
/// source has been read to its end has no effect.
pub fn setLoop(self: *Player, voice: Voice, loop: bool) LoopError!void {
    if (!self.isActive(voice)) return;
    if (self.slots[voice.index].feed) |feed| {
        if (loop and !feed.decoder.input.seekable()) return error.Unseekable;
        feed.loop = loop;
        return;
    }
    try self.send(.{ .loop = .{ .voice = voice, .loop = loop } });
}

pub fn setPaused(self: *Player, voice: Voice, paused: bool) CommandError!void {
    if (!self.isActive(voice)) return;
    try self.send(.{ .paused = .{ .voice = voice, .paused = paused } });
    if (self.slots[voice.index].feed) |feed| feed.paused = paused;
}

pub fn setMasterGain(self: *Player, gain: f32) CommandError!void {
    try self.send(.{ .master = cleanGain(gain) });
}

pub fn stopAll(self: *Player) CommandError!void {
    try self.send(.stop_all);
    for (self.slots) |slot| {
        if (slot.feed) |feed| feed.halted = true;
    }
}

/// The listener runs in `Context.dispatch`. It gets one `ended` event for each voice. A streamed
/// voice that met a decode error gets a `failed` event before it.
pub fn listen(self: *Player, listener: ?Listener) void {
    self.listener = listener;
}

/// App thread only.
pub fn stats(self: *const Player) Stats {
    var active: u32 = 0;
    var underruns = self.underruns_done;
    for (self.slots) |slot| {
        if (slot.active) active += 1;
        if (slot.feed) |feed| underruns +%= feed.ring.underruns.load(.monotonic);
    }
    return .{
        .active_voices = active,
        .rejected_commands = self.rejected,
        .underruns = underruns,
        .stream_errors = self.stream_errors,
        .xruns = self.playback.stats().xruns,
    };
}

fn isActive(self: *const Player, voice: Voice) bool {
    if (voice.index >= self.slots.len) return false;
    const slot = self.slots[voice.index];
    return slot.active and slot.generation == voice.generation;
}

fn send(self: *Player, command: Command) CommandError!void {
    if (self.commands.push(command)) return;
    self.rejected +%= 1;
    return error.Busy;
}

fn cleanGain(gain: f32) f32 {
    if (!std.math.isFinite(gain)) return 0;
    return std.math.clamp(gain, 0, max_gain);
}

fn pump(ptr: ?*anyopaque) void {
    const self: *Player = @ptrCast(@alignCast(ptr.?));
    while (self.events.pop()) |voice| {
        if (!self.isActive(voice)) continue;
        const slot = &self.slots[voice.index];
        slot.active = false;
        if (slot.feed) |feed| {
            slot.feed = null;
            self.underruns_done +%= feed.ring.underruns.load(.monotonic);
            const reason = feed.reason;
            feed.deinit(self.gpa);
            if (reason) |r| {
                self.stream_errors +%= 1;
                if (self.listener) |l| l.func(l.ctx, self, .{ .failed = .{ .voice = voice, .reason = r } });
            }
        } else {
            const sound_slot = &self.sounds.items[slot.sound];
            sound_slot.users -= 1;
            self.freeIfUnused(sound_slot);
        }
        if (self.listener) |l| l.func(l.ctx, self, .{ .ended = voice });
    }
    var budget: usize = pump_frames;
    for (0..self.slots.len) |k| {
        const feed = self.slots[(self.fill_start + k) % self.slots.len].feed orelse continue;
        if (!feed.halted and !feed.finished) self.fillFeed(feed, &budget);
    }
    self.fill_start = (self.fill_start + 1) % self.slots.len;
}

fn timeoutHint(ptr: ?*anyopaque) ?u32 {
    const self: *const Player = @ptrCast(@alignCast(ptr.?));
    if (self.playback.state() != .running) return null;
    const rate: u64 = self.options.format.rate;
    var best: ?u32 = null;
    for (self.slots) |slot| {
        const feed = slot.feed orelse continue;
        if (feed.halted) {
            // The stop fade is about 5 ms, then the pump frees the voice.
            best = if (best) |b| @min(b, ramp_ms + 10) else ramp_ms + 10;
            continue;
        }
        if (feed.paused) continue;
        const buffered: u64 = feed.ring.frames.readAvailable() / feed.conv.dst_channels;
        const ms: u64 = if (feed.finished)
            buffered * 1000 / rate + 10
        else blk: {
            const half = feed.target / feed.conv.dst_channels / 2;
            break :blk if (buffered <= half) 0 else (buffered - half) * 1000 / rate;
        };
        const clamped: u32 = @intCast(@min(ms, std.math.maxInt(u32)));
        best = if (best) |b| @min(b, clamped) else clamped;
    }
    return best;
}

fn render(ctx: ?*anyopaque, _: *Stream, buffer: Stream.Buffer) Stream.Status {
    const self: *Player = @ptrCast(@alignCast(ctx.?));
    const channels: usize = buffer.format.channels.count;
    std.debug.assert(buffer.format.channels.count == self.options.format.channels.count);
    const samples: []f32 = @alignCast(std.mem.bytesAsSlice(f32, buffer.bytes));
    const out = samples[0 .. buffer.frames * channels];
    std.debug.assert(out.len % channels == 0);
    self.applyCommands();
    var done: usize = 0;
    while (done < out.len) {
        const end = @min(out.len, done + block_frames * channels);
        self.mixBlock(out[done..end], channels);
        done = end;
    }
    return .@"continue";
}

fn applyCommands(self: *Player) void {
    while (self.commands.pop()) |command| switch (command) {
        .play => |p| self.startVoice(p.voice, p.source, p.gain, p.loop, p.paused),
        .stop => |v| if (self.find(v)) |voice| self.stopVoice(voice),
        .gain => |c| if (self.find(c.voice)) |voice| voice.gain.set(c.gain, self.ramp_frames),
        .loop => |c| if (self.find(c.voice)) |voice| {
            voice.loop = c.loop;
        },
        .paused => |c| if (self.find(c.voice)) |voice| {
            if (!voice.stopping and voice.paused != c.paused) {
                voice.paused = c.paused;
                voice.fade.set(if (c.paused) 0 else 1, self.ramp_frames);
            }
        },
        .master => |g| self.master.set(g, self.ramp_frames),
        .stop_all => for (self.voices) |*voice| {
            if (voice.state == .playing) self.stopVoice(voice);
        },
    };
}

fn find(self: *Player, voice: Voice) ?*AudioVoice {
    const v = &self.voices[voice.index];
    if (v.state != .playing or v.generation != voice.generation) return null;
    return v;
}

fn stopVoice(self: *Player, voice: *AudioVoice) void {
    voice.stopping = true;
    voice.paused = false;
    voice.fade.set(0, self.ramp_frames);
}

fn startVoice(self: *Player, handle: Voice, source: Source, gain: f32, loop: bool, paused: bool) void {
    self.voices[handle.index] = .{
        .state = .playing,
        .generation = handle.generation,
        .source = switch (source) {
            .memory => |m| .{ .memory = .{ .samples = m.samples, .position = 0 } },
            .ring => |r| .{ .ring = r },
        },
        .loop = loop,
        .paused = paused,
        .gain = .init(gain),
        .fade = .init(if (paused) 0 else 1),
    };
}

/// Mixes every voice into `out`, then applies the master gain and the soft clip.
fn mixBlock(self: *Player, out: []f32, channels: usize) void {
    @memset(out, 0);
    const scratch = self.mix_scratch[0..out.len];
    for (self.voices, 0..) |*voice, index| {
        if (voice.state == .idle) continue;
        if (voice.state == .playing) {
            const held = voice.paused and voice.fade.done();
            if (!held) {
                // A voice that fades into a pause reads only the frames of the fade.
                const frames = if (voice.paused) @min(out.len / channels, voice.fade.remaining) else out.len / channels;
                const chunk = scratch[0 .. frames * channels];
                const finished = switch (voice.source) {
                    .memory => |*m| fillMemory(m, voice.loop, chunk),
                    .ring => |r| fillRing(r, chunk, channels),
                };
                voice.gain.apply(chunk, @intCast(channels));
                voice.fade.apply(chunk, @intCast(channels));
                dsp.mix.accumulate(out[0..chunk.len], chunk, 1);
                if (finished or (voice.stopping and voice.fade.done())) voice.state = .ending;
            }
        }
        if (voice.state == .ending and self.events.push(.{ .index = @intCast(index), .generation = voice.generation })) {
            voice.state = .idle;
        }
    }
    self.master.apply(out, @intCast(channels));
    dsp.mix.softClip(out);
}

/// Fills `out` from the ring and pads a short read with silence. Gives true when the source has
/// ended and the ring is empty.
fn fillRing(ring: *Ring, out: []f32, channels: usize) bool {
    const done = ring.eof.load(.acquire);
    const have: usize = ring.frames.readAvailable();
    const n = @min(out.len, have - have % channels);
    const got = ring.frames.read(out[0..n]);
    std.debug.assert(got == n);
    @memset(out[n..], 0);
    if (n < out.len and !done) _ = ring.underruns.fetchAdd(1, .monotonic);
    return done and ring.frames.readAvailable() == 0;
}

/// Fills `out` with whole frames. Gives true when a voice without a loop has played its last frame.
fn fillMemory(m: anytype, loop: bool, out: []f32) bool {
    std.debug.assert(m.samples.len > 0);
    var filled: usize = 0;
    while (filled < out.len) {
        const left = m.samples.len - m.position;
        if (left == 0) {
            if (!loop) break;
            m.position = 0;
            continue;
        }
        const n = @min(left, out.len - filled);
        @memcpy(out[filled..][0..n], m.samples[m.position..][0..n]);
        filled += n;
        m.position += n;
    }
    @memset(out[filled..], 0);
    return !loop and m.position == m.samples.len;
}

const mono_format: Format = .{ .sample = .f32, .rate = 48000, .channels = .mono };

fn wavBytes(gpa: std.mem.Allocator, rate: u32, channels: u8, samples: []const f32) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var enc: codec.Encoder = try .init(gpa, &aw.writer, .{ .wav = .{ .sample = .f32 } }, .{ .rate = rate, .channels = channels });
    defer enc.deinit();
    try enc.write(samples);
    try enc.finish();
    return aw.toOwnedSlice();
}

const Fixture = struct {
    ctx: *Context,
    player: *Player,

    fn init(null_options: Null.Options, options: Options) !Fixture {
        const ctx = try Context.init(std.testing.allocator, std.testing.io, .{ .app_name = "test", .backend = .null, .null_backend = null_options });
        errdefer ctx.deinit();
        return .{ .ctx = ctx, .player = try Player.init(ctx, options) };
    }

    fn deinit(self: *Fixture) void {
        self.player.deinit();
        self.ctx.deinit();
    }

    fn sound(self: *Fixture, rate: u32, channels: u8, samples: []const f32) !Sound {
        const bytes = try wavBytes(std.testing.allocator, rate, channels, samples);
        defer std.testing.allocator.free(bytes);
        return self.player.load(.{ .bytes = bytes }, .{});
    }

    fn constant(self: *Fixture, value: f32, frames: usize) !Sound {
        const samples = try std.testing.allocator.alloc(f32, frames);
        defer std.testing.allocator.free(samples);
        @memset(samples, value);
        return self.sound(48000, 1, samples);
    }

    fn run(self: *Fixture, n: usize) !void {
        for (0..n) |_| _ = try self.ctx.dispatch();
    }

    fn out(self: *Fixture) []const f32 {
        return @alignCast(std.mem.bytesAsSlice(f32, self.ctx.backend.as(Null).?.output(self.player.playback)));
    }

    fn clear(self: *Fixture) void {
        self.ctx.backend.as(Null).?.clearOutput(self.player.playback);
    }
};

const EndedLog = struct {
    voices: [8]Voice = undefined,
    count: usize = 0,

    fn listener(self: *EndedLog) Listener {
        return .{ .ctx = self, .func = onEvent };
    }

    fn onEvent(ctx: ?*anyopaque, player: *Player, event: Event) void {
        _ = player;
        const self: *EndedLog = @ptrCast(@alignCast(ctx.?));
        self.voices[self.count] = event.ended;
        self.count += 1;
    }
};

test "a sound at gain 1 comes out sample for sample" {
    var fx: Fixture = try .init(.{ .period_frames = 64 }, .{});
    defer fx.deinit();
    var samples: [200]f32 = undefined;
    for (&samples, 0..) |*s, i| s.* = @as(f32, @floatFromInt(i)) * 0.004;
    const sound = try fx.sound(48000, 2, &samples);
    _ = try fx.player.play(sound, .{});
    try fx.run(2);
    try std.testing.expectEqual(@as(usize, 256), fx.out().len);
    try std.testing.expectEqualSlices(f32, &samples, fx.out()[0..200]);
    for (fx.out()[200..]) |s| try std.testing.expectEqual(@as(f32, 0), s);
    try std.testing.expectEqual(@as(u32, 1), fx.player.stats().active_voices);
    try fx.run(1);
    try std.testing.expectEqual(@as(u32, 0), fx.player.stats().active_voices);
}

test "two voices are added" {
    var fx: Fixture = try .init(.{ .period_frames = 100 }, .{ .format = mono_format });
    defer fx.deinit();
    const a = try fx.constant(0.2, 100);
    const b = try fx.constant(0.3, 100);
    _ = try fx.player.play(a, .{});
    _ = try fx.player.play(b, .{ .gain = 0.5 });
    try fx.run(1);
    try std.testing.expectEqual(@as(usize, 100), fx.out().len);
    for (fx.out()) |s| try std.testing.expectApproxEqAbs(@as(f32, 0.35), s, 1e-6);
}

test "a gain change ramps over about 5 ms" {
    var fx: Fixture = try .init(.{ .period_frames = 300 }, .{ .format = mono_format });
    defer fx.deinit();
    const sound = try fx.constant(0.8, 2000);
    const voice = try fx.player.play(sound, .{});
    try fx.run(1);
    for (fx.out()) |s| try std.testing.expectEqual(@as(f32, 0.8), s);
    fx.clear();
    try fx.player.setGain(voice, 0.5);
    try fx.run(1);
    for (fx.out()[0..240], 1..) |s, k| {
        try std.testing.expectApproxEqAbs(0.8 - 0.4 * @as(f32, @floatFromInt(k)) / 240, s, 1e-5);
    }
    for (fx.out()[240..]) |s| try std.testing.expectEqual(@as(f32, 0.4), s);
}

test "a loop wraps with no gap, also across the internal block size" {
    var fx: Fixture = try .init(.{ .period_frames = 600 }, .{ .format = mono_format });
    defer fx.deinit();
    const samples = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7 };
    const sound = try fx.sound(48000, 1, &samples);
    _ = try fx.player.play(sound, .{ .loop = true });
    try fx.run(1);
    try std.testing.expectEqual(@as(usize, 600), fx.out().len);
    for (fx.out(), 0..) |s, i| try std.testing.expectEqual(samples[i % 7], s);
    try std.testing.expectEqual(@as(u32, 1), fx.player.stats().active_voices);
}

test "stop fades to zero and the voice ends once" {
    var fx: Fixture = try .init(.{ .period_frames = 300 }, .{ .format = mono_format });
    defer fx.deinit();
    var ended: EndedLog = .{};
    fx.player.listen(ended.listener());
    const sound = try fx.constant(0.8, 100);
    const voice = try fx.player.play(sound, .{ .loop = true });
    try fx.run(1);
    fx.clear();
    try fx.player.stop(voice);
    try fx.run(1);
    for (fx.out()[0..240], 1..) |s, k| {
        try std.testing.expectApproxEqAbs(0.8 * (1 - @as(f32, @floatFromInt(k)) / 240), s, 1e-5);
    }
    for (fx.out()[239..]) |s| try std.testing.expectEqual(@as(f32, 0), s);
    try fx.run(3);
    try std.testing.expectEqual(@as(usize, 1), ended.count);
    try std.testing.expectEqual(voice, ended.voices[0]);
    try std.testing.expectEqual(@as(u32, 0), fx.player.stats().active_voices);
}

test "a stale handle does nothing" {
    var fx: Fixture = try .init(.{ .period_frames = 16 }, .{ .format = mono_format, .voices = 1 });
    defer fx.deinit();
    const short = try fx.constant(0.25, 4);
    const long = try fx.constant(0.5, 100);
    const first = try fx.player.play(short, .{});
    try fx.run(2);
    const second = try fx.player.play(long, .{ .loop = true });
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(first.generation != second.generation);
    try fx.player.stop(first);
    try fx.player.setGain(first, 0);
    try fx.player.setPaused(first, true);
    fx.clear();
    try fx.run(3);
    for (fx.out()) |s| try std.testing.expectEqual(@as(f32, 0.5), s);
    try std.testing.expectEqual(@as(u32, 1), fx.player.stats().active_voices);
    try fx.player.stop(.{});
}

test "no free voice" {
    var fx: Fixture = try .init(.{}, .{ .format = mono_format, .voices = 2 });
    defer fx.deinit();
    const sound = try fx.constant(0.1, 10);
    const a = try fx.player.play(sound, .{ .loop = true });
    _ = try fx.player.play(sound, .{ .loop = true });
    try std.testing.expectError(error.NoFreeVoice, fx.player.play(sound, .{}));
    try fx.player.stop(a);
    try fx.run(3);
    _ = try fx.player.play(sound, .{});
}

test "a full command queue gives Busy and changes nothing" {
    var fx: Fixture = try .init(.{}, .{ .format = mono_format, .voices = 8, .command_queue = 4 });
    defer fx.deinit();
    const sound = try fx.constant(0.1, 10);
    var voices: [4]Voice = undefined;
    for (&voices) |*v| v.* = try fx.player.play(sound, .{ .loop = true });
    try std.testing.expectError(error.Busy, fx.player.play(sound, .{}));
    try std.testing.expectError(error.Busy, fx.player.stop(voices[0]));
    try std.testing.expectError(error.Busy, fx.player.setMasterGain(0.5));
    try std.testing.expectEqual(@as(u32, 4), fx.player.stats().active_voices);
    try std.testing.expectEqual(@as(u32, 3), fx.player.stats().rejected_commands);
    try fx.run(1);
    const again = try fx.player.play(sound, .{});
    try std.testing.expectEqual(@as(u16, 4), again.index);
}

test "unload while a voice plays waits for the voice" {
    var fx: Fixture = try .init(.{ .period_frames = 300 }, .{ .format = mono_format });
    defer fx.deinit();
    const sound = try fx.constant(0.5, 10);
    const voice = try fx.player.play(sound, .{ .loop = true });
    try fx.run(1);
    fx.player.unload(sound);
    fx.player.unload(sound);
    try std.testing.expectError(error.UnknownSound, fx.player.play(sound, .{}));
    try std.testing.expect(fx.player.sounds.items[sound.index].samples != null);
    fx.clear();
    try fx.run(1);
    for (fx.out()) |s| try std.testing.expectEqual(@as(f32, 0.5), s);
    try fx.player.stop(voice);
    try fx.run(1);
    try std.testing.expect(fx.player.sounds.items[sound.index].samples != null);
    try fx.run(1);
    try std.testing.expect(fx.player.sounds.items[sound.index].samples == null);
}

test "unload with no voice frees at once and the slot gets a new generation" {
    var fx: Fixture = try .init(.{}, .{ .format = mono_format });
    defer fx.deinit();
    const old = try fx.constant(0.5, 10);
    fx.player.unload(old);
    try std.testing.expect(fx.player.sounds.items[old.index].samples == null);
    const new = try fx.constant(0.25, 10);
    try std.testing.expectEqual(old.index, new.index);
    try std.testing.expect(old.generation != new.generation);
    try std.testing.expectError(error.UnknownSound, fx.player.play(old, .{}));
    _ = try fx.player.play(new, .{});
}

test "a mono sound at 24 kHz plays as 48 kHz stereo" {
    var fx: Fixture = try .init(.{ .period_frames = 200 }, .{});
    defer fx.deinit();
    const input: [100]f32 = @splat(0.5);
    const sound = try fx.sound(24000, 1, &input);
    try std.testing.expectEqual(@as(u32, 200), fx.player.sounds.items[sound.index].frames);
    _ = try fx.player.play(sound, .{});
    try fx.run(1);
    try std.testing.expectEqual(@as(usize, 400), fx.out().len);
    for (40..160) |i| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), fx.out()[i * 2], 0.01);
        try std.testing.expectEqual(fx.out()[i * 2], fx.out()[i * 2 + 1]);
    }
}

test "the resampled length follows the rate ratio" {
    var fx: Fixture = try .init(.{}, .{ .format = mono_format });
    defer fx.deinit();
    const input: [441]f32 = @splat(0.1);
    const sound = try fx.sound(44100, 1, &input);
    try std.testing.expectEqual(@as(u32, 480), fx.player.sounds.items[sound.index].frames);
}

test "a 5.1 sound folds to stereo" {
    var fx: Fixture = try .init(.{ .period_frames = 8 }, .{});
    defer fx.deinit();
    var input: [48]f32 = @splat(0);
    for (0..8) |f| input[f * 6 + 2] = 1;
    const sound = try fx.sound(48000, 6, &input);
    _ = try fx.player.play(sound, .{});
    try fx.run(1);
    for (fx.out()) |s| try std.testing.expectApproxEqAbs(@as(f32, 0.70710678), s, 1e-6);
}

test "the listener fires once for each ended voice" {
    var fx: Fixture = try .init(.{ .period_frames = 16 }, .{ .format = mono_format, .voices = 4 });
    defer fx.deinit();
    var ended: EndedLog = .{};
    fx.player.listen(ended.listener());
    var voices: [3]Voice = undefined;
    for (&voices, 0..) |*v, i| {
        const sound = try fx.constant(0.1, 4 + i * 10);
        v.* = try fx.player.play(sound, .{});
    }
    try fx.run(6);
    try std.testing.expectEqual(@as(usize, 3), ended.count);
    for (voices) |v| {
        var seen: usize = 0;
        for (ended.voices[0..3]) |e| {
            if (e.index == v.index and e.generation == v.generation) seen += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), seen);
    }
}

test "master gain and the soft clip bound the output" {
    var fx: Fixture = try .init(.{ .period_frames = 300 }, .{ .format = mono_format });
    defer fx.deinit();
    const sound = try fx.constant(0.8, 1000);
    _ = try fx.player.play(sound, .{});
    _ = try fx.player.play(sound, .{});
    try fx.run(1);
    for (fx.out()) |s| try std.testing.expect(s > 0.9 and s <= 1);
    fx.clear();
    try fx.player.setMasterGain(0.25);
    try fx.run(1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), fx.out()[299], 1e-6);
    try std.testing.expect(fx.out()[0] > 0.4);
}

test "pause fades out, holds the position and resume fades in" {
    var fx: Fixture = try .init(.{ .period_frames = 300 }, .{ .format = mono_format });
    defer fx.deinit();
    var input: [2000]f32 = undefined;
    for (&input, 0..) |*s, i| s.* = @as(f32, @floatFromInt(i)) * 0.0001;
    const sound = try fx.sound(48000, 1, &input);
    const voice = try fx.player.play(sound, .{ .paused = true });
    try fx.run(1);
    for (fx.out()) |s| try std.testing.expectEqual(@as(f32, 0), s);
    fx.clear();
    try fx.player.setPaused(voice, false);
    try fx.run(1);
    for (fx.out()[0..240], 0..) |s, i| {
        try std.testing.expectApproxEqAbs(input[i] * @as(f32, @floatFromInt(i + 1)) / 240, s, 1e-5);
    }
    for (fx.out()[240..], 240..) |s, i| try std.testing.expectEqual(input[i], s);
    fx.clear();
    try fx.player.setPaused(voice, true);
    try fx.run(1);
    try std.testing.expectEqual(@as(f32, 0), fx.out()[239]);
    for (fx.out()[240..]) |s| try std.testing.expectEqual(@as(f32, 0), s);
    fx.clear();
    try fx.player.setPaused(voice, false);
    try fx.run(1);
    try std.testing.expectApproxEqAbs(input[540] / 240, fx.out()[0], 1e-5);
    try std.testing.expectEqual(input[540 + 299], fx.out()[299]);
}

test "bad options are rejected" {
    try std.testing.expectError(error.UnsupportedFormat, Fixture.init(.{}, .{ .format = .{ .sample = .s16, .rate = 48000, .channels = .stereo } }));
    try std.testing.expectError(error.InvalidOptions, Fixture.init(.{}, .{ .voices = 0 }));
}

test "bad input and empty sounds do not load" {
    var fx: Fixture = try .init(.{}, .{ .format = mono_format });
    defer fx.deinit();
    try std.testing.expectError(error.Unsupported, fx.player.load(.{ .bytes = "this is not audio data at all" }, .{}));
    const empty = try wavBytes(std.testing.allocator, 48000, 1, &.{});
    defer std.testing.allocator.free(empty);
    try std.testing.expectError(error.EmptySound, fx.player.load(.{ .bytes = empty }, .{}));
}

test "the stream converts to a native format of another sample type" {
    const native: Format = .{ .sample = .s16, .rate = 48000, .channels = .mono };
    var fx: Fixture = try .init(.{ .native = native, .period_frames = 8 }, .{ .format = mono_format });
    defer fx.deinit();
    const sound = try fx.constant(0.5, 8);
    _ = try fx.player.play(sound, .{});
    try fx.run(1);
    const pcm = std.mem.bytesAsSlice(i16, fx.ctx.backend.as(Null).?.output(fx.player.playback));
    try std.testing.expectEqual(@as(usize, 8), pcm.len);
    for (pcm) |s| try std.testing.expect(@abs(@as(i32, s) - 16384) <= 1);
}

test "stop all ends every voice and setLoop ends a loop at its last frame" {
    var fx: Fixture = try .init(.{ .period_frames = 300 }, .{ .format = mono_format });
    defer fx.deinit();
    var ended: EndedLog = .{};
    fx.player.listen(ended.listener());
    const sound = try fx.constant(0.1, 10);
    _ = try fx.player.play(sound, .{ .loop = true });
    _ = try fx.player.play(sound, .{ .loop = true });
    const third = try fx.player.play(sound, .{ .loop = true });
    try fx.run(1);
    try fx.player.setLoop(third, false);
    try fx.player.stopAll();
    try fx.run(2);
    try std.testing.expectEqual(@as(usize, 3), ended.count);
    try std.testing.expectEqual(@as(u32, 0), fx.player.stats().active_voices);
    fx.clear();
    try fx.run(1);
    for (fx.out()) |s| try std.testing.expectEqual(@as(f32, 0), s);
}

test "a second pause does not move the position" {
    var fx: Fixture = try .init(.{ .period_frames = 300 }, .{ .format = mono_format });
    defer fx.deinit();
    var input: [2000]f32 = undefined;
    for (&input, 0..) |*s, i| s.* = @as(f32, @floatFromInt(i)) * 0.0001;
    const sound = try fx.sound(48000, 1, &input);
    const voice = try fx.player.play(sound, .{ .paused = true });
    try fx.player.setPaused(voice, true);
    try fx.run(1);
    try fx.player.setPaused(voice, true);
    try fx.run(1);
    fx.clear();
    try fx.player.setPaused(voice, false);
    try fx.run(1);
    try std.testing.expectApproxEqAbs(input[239], fx.out()[239], 1e-5);
    try std.testing.expectEqual(input[240], fx.out()[240]);
}

/// A reader that gives a few bytes per call and can fail after some bytes.
const SlowReader = struct {
    data: []const u8,
    pos: usize = 0,
    step: usize = 7,
    fail_at: ?usize = null,
    buffer: [64]u8 = undefined,
    reader: std.Io.Reader = undefined,

    fn start(self: *SlowReader) *std.Io.Reader {
        self.reader = .{ .vtable = &.{ .stream = give }, .buffer = &self.buffer, .seek = 0, .end = 0 };
        return &self.reader;
    }

    fn give(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *SlowReader = @fieldParentPtr("reader", r);
        var end = self.data.len;
        if (self.fail_at) |at| {
            if (self.pos >= at) return error.ReadFailed;
            end = @min(end, at);
        }
        if (self.pos >= end) return error.EndOfStream;
        const n = @min(@min(self.step, end - self.pos), @backingInt(limit));
        try w.writeAll(self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
};

const Kind = enum { bytes, reader, slow };

/// Plays `bytes` once as a loaded sound and once as a stream on two players and compares the
/// output.
fn expectStreamMatchesLoad(bytes: []const u8, kind: Kind, tolerance: f32) !void {
    var loaded: Fixture = try .init(.{ .period_frames = 256 }, .{});
    defer loaded.deinit();
    var streamed: Fixture = try .init(.{ .period_frames = 256 }, .{});
    defer streamed.deinit();
    const sound = try loaded.player.load(.{ .bytes = bytes }, .{});
    const frames = loaded.player.sounds.items[sound.index].frames;
    _ = try loaded.player.play(sound, .{});

    var reader: std.Io.Reader = .fixed(bytes);
    var slow: SlowReader = .{ .data = bytes };
    const source: codec.Source = switch (kind) {
        .bytes => .{ .bytes = bytes },
        .reader => .{ .reader = &reader },
        .slow => .{ .reader = slow.start() },
    };
    var ended: EndedLog = .{};
    streamed.player.listen(ended.listener());
    _ = try streamed.player.stream(source, .{});

    const dispatches = frames / 256 + 4;
    try loaded.run(dispatches);
    try streamed.run(dispatches);
    try std.testing.expectEqual(loaded.out().len, streamed.out().len);
    try std.testing.expect(frames > 256);
    for (loaded.out(), streamed.out()) |a, b| try std.testing.expectApproxEqAbs(a, b, tolerance);
    try std.testing.expectEqual(@as(usize, 1), ended.count);
    try std.testing.expectEqual(@as(u32, 0), streamed.player.stats().active_voices);
    try std.testing.expectEqual(@as(u32, 0), streamed.player.stats().underruns);
    try std.testing.expectEqual(@as(u32, 0), streamed.player.stats().stream_errors);
}

const flac_file = @embedFile("../codec/testdata/flac/s01-blocksize-4096.flac");
const vorbis_file = @embedFile("../codec/testdata/vorbis/noise48.ogg");
const vorbis_44k = @embedFile("../codec/testdata/vorbis/stereo44.ogg");
const vorbis_mono_8k = @embedFile("../codec/testdata/vorbis/mono8k.ogg");
const vorbis_chain = @embedFile("../codec/testdata/vorbis/chain.ogg");
const opus_file = @embedFile("../codec/testdata/opus/stereo48.opus");

test "a streamed FLAC file plays the samples of a full decode" {
    try expectStreamMatchesLoad(flac_file, .bytes, 0);
}

test "a streamed Vorbis file plays the samples of a full decode" {
    try expectStreamMatchesLoad(vorbis_file, .bytes, 0);
}

test "a streamed Opus file plays the samples of a full decode" {
    try expectStreamMatchesLoad(opus_file, .bytes, 0);
}

test "a streamed file from a forward only reader plays the samples of a full decode" {
    try expectStreamMatchesLoad(vorbis_file, .reader, 0);
    try expectStreamMatchesLoad(flac_file, .reader, 0);
}

test "a source that returns a few bytes per call streams the same samples" {
    try expectStreamMatchesLoad(vorbis_file, .slow, 0);
    try expectStreamMatchesLoad(opus_file, .slow, 0);
    try expectStreamMatchesLoad(flac_file, .slow, 0);
}

test "a streamed file at another rate and layout is converted like a loaded one" {
    try expectStreamMatchesLoad(vorbis_44k, .bytes, 1e-6);
    try expectStreamMatchesLoad(vorbis_mono_8k, .bytes, 1e-6);
}

test "a chained file that changes format plays on, loaded and streamed" {
    try expectStreamMatchesLoad(vorbis_chain, .bytes, 1e-6);
}

test "a file that is cut off plays what was decoded and ends with no error" {
    try expectStreamMatchesLoad(vorbis_file[0 .. vorbis_file.len * 2 / 3], .bytes, 0);
    try expectStreamMatchesLoad(flac_file[0 .. flac_file.len / 2], .bytes, 0);
}

fn rampWav(gpa: std.mem.Allocator, frames: usize) ![]u8 {
    const samples = try gpa.alloc(f32, frames);
    defer gpa.free(samples);
    for (samples, 0..) |*s, i| s.* = @as(f32, @floatFromInt(i + 1)) * 1e-5;
    return wavBytes(gpa, 48000, 1, samples);
}

fn ramp(i: usize) f32 {
    return @as(f32, @floatFromInt(i + 1)) * 1e-5;
}

test "a loop on a stream seeks to the start" {
    var fx: Fixture = try .init(.{ .period_frames = 300 }, .{ .format = mono_format });
    defer fx.deinit();
    const bytes = try rampWav(std.testing.allocator, 1000);
    defer std.testing.allocator.free(bytes);
    const voice = try fx.player.stream(.{ .bytes = bytes }, .{ .loop = true });
    try fx.run(20);
    try std.testing.expectEqual(@as(usize, 6000), fx.out().len);
    for (fx.out(), 0..) |s, i| try std.testing.expectEqual(ramp(i % 1000), s);
    try std.testing.expectEqual(@as(u32, 0), fx.player.stats().underruns);
    try fx.player.setLoop(voice, false);
    // The ring holds looped frames already, so the end comes after the ring is empty.
    try fx.run(100);
    try std.testing.expectEqual(@as(u32, 0), fx.player.stats().active_voices);
}

test "a loop on a resampled stream repeats the same samples" {
    var fx: Fixture = try .init(.{ .period_frames = 400 }, .{ .format = mono_format });
    defer fx.deinit();
    const input: [100]f32 = @splat(0.5);
    const bytes = try wavBytes(std.testing.allocator, 24000, 1, &input);
    defer std.testing.allocator.free(bytes);
    _ = try fx.player.stream(.{ .bytes = bytes }, .{ .loop = true });
    try fx.run(10);
    try std.testing.expectEqual(@as(usize, 4000), fx.out().len);
    for (fx.out()[0..3800], fx.out()[200..4000]) |a, b| try std.testing.expectEqual(a, b);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), fx.out()[100], 0.01);
}

test "a loop needs a source that seeks" {
    var fx: Fixture = try .init(.{}, .{ .format = mono_format });
    defer fx.deinit();
    const bytes = try rampWav(std.testing.allocator, 1000);
    defer std.testing.allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    try std.testing.expectError(error.Unseekable, fx.player.stream(.{ .reader = &reader }, .{ .loop = true }));
    try std.testing.expectEqual(@as(u32, 0), fx.player.stats().active_voices);
    var again: std.Io.Reader = .fixed(bytes);
    const voice = try fx.player.stream(.{ .reader = &again }, .{});
    try std.testing.expectError(error.Unseekable, fx.player.setLoop(voice, true));
    try fx.player.setLoop(voice, false);
}

test "a pump that runs late gives silence and a count, and the voice keeps its place" {
    var fx: Fixture = try .init(.{ .period_frames = 256 }, .{ .format = mono_format });
    defer fx.deinit();
    const bytes = try rampWav(std.testing.allocator, 40000);
    defer std.testing.allocator.free(bytes);
    _ = try fx.player.stream(.{ .bytes = bytes }, .{});
    const out = try std.testing.allocator.alloc(f32, 10000);
    defer std.testing.allocator.free(out);
    const buffer: Stream.Buffer = .{ .bytes = std.mem.sliceAsBytes(out), .frames = 10000, .format = mono_format };
    try std.testing.expectEqual(Stream.Status.@"continue", render(fx.player, fx.player.playback, buffer));
    for (out[0..pump_frames], 0..) |s, i| try std.testing.expectEqual(ramp(i), s);
    for (out[pump_frames..]) |s| try std.testing.expectEqual(@as(f32, 0), s);
    try std.testing.expectEqual(@as(u32, 8), fx.player.stats().underruns);
    try fx.run(1);
    try std.testing.expectEqual(ramp(pump_frames), fx.out()[0]);
    try std.testing.expectEqual(ramp(pump_frames + 255), fx.out()[255]);
    try std.testing.expectEqual(@as(u32, 8), fx.player.stats().underruns);
}

test "a stream reader that fails in the middle ends the voice with a failure" {
    var fx: Fixture = try .init(.{ .period_frames = 256 }, .{ .format = mono_format });
    defer fx.deinit();
    const Log = struct {
        events: [4]Event = undefined,
        count: usize = 0,
        fn onEvent(ctx: ?*anyopaque, player: *Player, event: Event) void {
            _ = player;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.events[self.count] = event;
            self.count += 1;
        }
    };
    var log: Log = .{};
    fx.player.listen(.{ .ctx = &log, .func = Log.onEvent });
    const bytes = try rampWav(std.testing.allocator, 40000);
    defer std.testing.allocator.free(bytes);
    var slow: SlowReader = .{ .data = bytes, .step = 1000, .fail_at = 60000 };
    const voice = try fx.player.stream(.{ .reader = slow.start() }, .{});
    try fx.run(200);
    try std.testing.expectEqual(@as(usize, 2), log.count);
    try std.testing.expectEqual(Event{ .failed = .{ .voice = voice, .reason = .read_failed } }, log.events[0]);
    try std.testing.expectEqual(Event{ .ended = voice }, log.events[1]);
    try std.testing.expectEqual(@as(u32, 1), fx.player.stats().stream_errors);
    try std.testing.expectEqual(@as(u32, 0), fx.player.stats().active_voices);
    // The frames before the error were played.
    var played: usize = 0;
    for (fx.out()) |s| {
        if (s == 0) continue;
        try std.testing.expectEqual(ramp(played), s);
        played += 1;
    }
    try std.testing.expect(played > 10000 and played < 40000);
    var early: SlowReader = .{ .data = bytes, .fail_at = 20 };
    try std.testing.expectError(error.ReadFailed, fx.player.stream(.{ .reader = early.start() }, .{}));
}

test "a stream counts against the voices and a full queue frees it" {
    var fx: Fixture = try .init(.{}, .{ .format = mono_format, .voices = 1, .command_queue = 1 });
    defer fx.deinit();
    const bytes = try rampWav(std.testing.allocator, 1000);
    defer std.testing.allocator.free(bytes);
    const voice = try fx.player.stream(.{ .bytes = bytes }, .{ .loop = true });
    try std.testing.expectError(error.NoFreeVoice, fx.player.stream(.{ .bytes = bytes }, .{}));
    try fx.run(1);
    try fx.player.stop(voice);
    try fx.run(3);
    try std.testing.expectEqual(@as(u32, 0), fx.player.stats().active_voices);
    var full: Fixture = try .init(.{}, .{ .format = mono_format, .voices = 4, .command_queue = 1 });
    defer full.deinit();
    _ = try full.player.stream(.{ .bytes = bytes }, .{ .loop = true });
    try std.testing.expectError(error.Busy, full.player.stream(.{ .bytes = bytes }, .{}));
    try std.testing.expectEqual(@as(u32, 1), full.player.stats().active_voices);
}

test "stop ends a streamed voice and frees its decoder" {
    var fx: Fixture = try .init(.{ .period_frames = 300 }, .{ .format = mono_format });
    defer fx.deinit();
    var ended: EndedLog = .{};
    fx.player.listen(ended.listener());
    const bytes = try rampWav(std.testing.allocator, 40000);
    defer std.testing.allocator.free(bytes);
    const voice = try fx.player.stream(.{ .bytes = bytes }, .{});
    try fx.run(2);
    try fx.player.stop(voice);
    try fx.run(4);
    try std.testing.expectEqual(@as(usize, 1), ended.count);
    try std.testing.expect(fx.player.slots[voice.index].feed == null);
    try std.testing.expectEqual(@as(?u32, null), timeoutHint(fx.player));
}

test "the timeout hint follows the ring level" {
    var fx: Fixture = try .init(.{ .period_frames = 256 }, .{ .format = mono_format });
    defer fx.deinit();
    try std.testing.expectEqual(@as(?u32, null), timeoutHint(fx.player));
    const bytes = try rampWav(std.testing.allocator, 100000);
    defer std.testing.allocator.free(bytes);
    const voice = try fx.player.stream(.{ .bytes = bytes }, .{});
    // The first fill holds 8192 of 24000 frames, which is below half.
    try std.testing.expectEqual(@as(?u32, 0), timeoutHint(fx.player));
    try fx.run(4);
    const full = timeoutHint(fx.player).?;
    try std.testing.expect(full >= 240 and full <= 250);
    try fx.player.setPaused(voice, true);
    try std.testing.expectEqual(@as(?u32, null), timeoutHint(fx.player));
    try fx.player.stop(voice);
    // A paused voice that stops still needs a call to end.
    // The stopped voice needs one more dispatch to end and to free its memory.
    try std.testing.expectEqual(@as(?u32, ramp_ms + 10), timeoutHint(fx.player));
    try fx.run(3);
    try std.testing.expectEqual(@as(?u32, null), timeoutHint(fx.player));
}

test "no hint while the playback stream is not running" {
    var fx: Fixture = try .init(.{ .period_frames = 256 }, .{ .format = mono_format });
    defer fx.deinit();
    const bytes = try rampWav(std.testing.allocator, 100000);
    defer std.testing.allocator.free(bytes);
    _ = try fx.player.stream(.{ .bytes = bytes }, .{});
    try std.testing.expect(timeoutHint(fx.player) != null);
    fx.player.playback.stop();
    try std.testing.expectEqual(@as(?u32, null), timeoutHint(fx.player));
    try fx.player.playback.start();
    try std.testing.expect(timeoutHint(fx.player) != null);
}

test "a short stream that has ended asks for a call when its ring is drained" {
    var fx: Fixture = try .init(.{ .period_frames = 256 }, .{ .format = mono_format });
    defer fx.deinit();
    const bytes = try rampWav(std.testing.allocator, 4800);
    defer std.testing.allocator.free(bytes);
    _ = try fx.player.stream(.{ .bytes = bytes }, .{});
    const ms = timeoutHint(fx.player).?;
    try std.testing.expectEqual(@as(u32, 4800 * 1000 / 48000 + 10), ms);
}

test "the context hint is the smaller of the pump hint and the null period" {
    var fx: Fixture = try .init(.{ .period_frames = 480 }, .{ .format = mono_format });
    defer fx.deinit();
    const bytes = try rampWav(std.testing.allocator, 100000);
    defer std.testing.allocator.free(bytes);
    _ = try fx.player.stream(.{ .bytes = bytes }, .{});
    try std.testing.expectEqual(@as(?u32, 0), timeoutHint(fx.player));
    try std.testing.expectEqual(@as(?u32, 0), fx.ctx.timeoutMs());
    try fx.run(4);
    const own = timeoutHint(fx.player).?;
    try std.testing.expect(own > 10);
    try std.testing.expectEqual(@as(?u32, 10), fx.ctx.timeoutMs());
}

/// Plays a long stream for `seconds` of audio time. The audio side consumes time at once and the
/// app dispatches only when `hint` says so. Gives the dispatch count.
fn pollDriven(fx: *Fixture, seconds: usize, use_hint: bool, fixed_ms: u32) !usize {
    const rate = 48;
    var dispatches: usize = 0;
    var elapsed: usize = 0;
    const out = try std.testing.allocator.alloc(f32, 600 * rate);
    defer std.testing.allocator.free(out);
    while (elapsed < seconds * 1000) {
        const wait: u32 = if (use_hint) fx.ctx.timeoutMs() orelse 100 else fixed_ms;
        const step: usize = @min(wait, 600);
        const frames = step * rate;
        const buffer: Stream.Buffer = .{ .bytes = std.mem.sliceAsBytes(out[0..frames]), .frames = @intCast(frames), .format = mono_format };
        _ = render(fx.player, fx.player.playback, buffer);
        elapsed += step;
        _ = try fx.ctx.dispatch();
        dispatches += 1;
        try std.testing.expect(dispatches < 2000);
    }
    return dispatches;
}

test "an app that polls with the timeout hint keeps a stream fed" {
    var fx: Fixture = try .init(.{ .period_frames = 4800 }, .{ .format = mono_format });
    defer fx.deinit();
    const bytes = try rampWav(std.testing.allocator, 48000 * 12);
    defer std.testing.allocator.free(bytes);
    _ = try fx.player.stream(.{ .bytes = bytes }, .{});
    const dispatches = try pollDriven(&fx, 4, true, 0);
    try std.testing.expectEqual(@as(u32, 0), fx.player.stats().underruns);
    try std.testing.expect(dispatches < 80);
    try std.testing.expectEqual(@as(u32, 1), fx.player.stats().active_voices);
}

test "an app that dispatches too rarely gets underruns" {
    var fx: Fixture = try .init(.{ .period_frames = 16 }, .{ .format = mono_format });
    defer fx.deinit();
    const bytes = try rampWav(std.testing.allocator, 48000 * 6);
    defer std.testing.allocator.free(bytes);
    _ = try fx.player.stream(.{ .bytes = bytes }, .{});
    _ = try pollDriven(&fx, 4, false, 600);
    try std.testing.expect(fx.player.stats().underruns > 0);
}

test "a second thread renders while the pump fills and a command arrives" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const frames = 60000;
    const block = 100;
    const half_at = 20000;
    var fx: Fixture = try .init(.{}, .{ .format = mono_format });
    defer fx.deinit();
    const bytes = try rampWav(std.testing.allocator, frames);
    defer std.testing.allocator.free(bytes);
    const voice = try fx.player.stream(.{ .bytes = bytes }, .{});
    const seen = try std.testing.allocator.alloc(f32, frames + 4 * block);
    defer std.testing.allocator.free(seen);
    @memset(seen, -1);

    // The audio thread renders a block only when the pump has written the frames for it, so the
    // run has no underrun, and every output sample is checked.
    const Audio = struct {
        player: *Player,
        seen: []f32,
        rendered: std.atomic.Value(u32) = .init(0),
        allowed: std.atomic.Value(u32) = .init(0),
        stop: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            var out: [block]f32 = undefined;
            const buffer: Stream.Buffer = .{ .bytes = std.mem.sliceAsBytes(&out), .frames = block, .format = mono_format };
            while (!self.stop.load(.acquire)) {
                const done = self.rendered.load(.monotonic);
                if (done + block > self.allowed.load(.acquire)) {
                    std.Thread.yield() catch continue;
                    continue;
                }
                _ = render(self.player, self.player.playback, buffer);
                @memcpy(self.seen[done..][0..block], &out);
                self.rendered.store(done + block, .release);
            }
        }
    };
    var audio: Audio = .{ .player = fx.player, .seen = seen };
    const thread = try std.Thread.spawn(.{}, Audio.run, .{&audio});
    var sent = false;
    var rounds: usize = 0;
    while (fx.player.stats().active_voices > 0 and rounds < 4_000_000) : (rounds += 1) {
        pump(fx.player);
        if (fx.player.slots[voice.index].feed) |feed| {
            const written = feed.ring.frames.write_index.load(.acquire);
            // Frames past the end let the voice see the end of the source.
            const limit = if (feed.finished) written + 2 * block else written;
            audio.allowed.store(if (sent) limit else @min(limit, half_at), .release);
        }
        if (!sent and audio.rendered.load(.acquire) == half_at) {
            if (fx.player.setMasterGain(0.5)) sent = true else |err| try std.testing.expectEqual(error.Busy, err);
        }
        std.Thread.yield() catch continue;
    }
    audio.stop.store(true, .release);
    thread.join();
    try std.testing.expect(sent);
    try std.testing.expectEqual(@as(u32, 0), fx.player.stats().active_voices);
    try std.testing.expectEqual(@as(u32, 0), fx.player.stats().underruns);
    for (seen[0..half_at], 0..) |s, i| try std.testing.expectEqual(ramp(i), s);
    // The master gain ramps over 240 frames, once the audio thread has taken the command.
    for (seen[half_at + 3 * block .. frames], half_at + 3 * block..) |s, i| {
        try std.testing.expectApproxEqAbs(ramp(i) * 0.5, s, 1e-6);
    }
}

test "bad stream buffer and bad input" {
    try std.testing.expectError(error.InvalidOptions, Fixture.init(.{}, .{ .stream_buffer_ms = 0 }));
    var fx: Fixture = try .init(.{}, .{ .format = mono_format });
    defer fx.deinit();
    try std.testing.expectError(error.Unsupported, fx.player.stream(.{ .bytes = "this is not audio data at all" }, .{}));
    const empty = try wavBytes(std.testing.allocator, 48000, 1, &.{});
    defer std.testing.allocator.free(empty);
    try std.testing.expectError(error.EmptySound, fx.player.stream(.{ .bytes = empty }, .{}));
    try std.testing.expectEqual(@as(u32, 0), fx.player.stats().active_voices);
}

test "the stats give the xruns of the playback stream" {
    var fx: Fixture = try .init(.{ .period_frames = 64 }, .{ .format = mono_format });
    defer fx.deinit();
    try std.testing.expectEqual(@as(u64, 0), fx.player.stats().xruns);
    fx.player.playback.noteXrun();
    fx.player.playback.noteXrun();
    try std.testing.expectEqual(@as(u64, 2), fx.player.stats().xruns);
    try std.testing.expectEqual(fx.player.playback.stats().xruns, fx.player.stats().xruns);
}
