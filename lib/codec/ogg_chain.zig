//! The link logic of a chained Ogg stream, shared by the Ogg codecs.
const std = @import("std");
const codec = @import("../codec.zig");
const io = @import("io.zig");
const packets = @import("ogg.zig");
const testing = std.testing;

pub const FrameError = codec.DecodeError;
pub const DataError = codec.DecodeError;

/// The frame count of a link and how far it can be trusted. A trusted length comes from the
/// headers and makes the end shortcut of `seek` and the `Truncated` check exact. A hint
/// comes from the granules.
pub const Length = struct {
    frames: u64,
    trusted: bool,
    /// The time of the first frame of the link in the units of the page granules. It is
    /// negative when the link cuts frames from its start.
    start: i64 = 0,
};

pub fn initError(err: packets.PacketReader.Error) codec.InitError {
    return switch (err) {
        error.BadData => error.BadHeader,
        else => |e| e,
    };
}

/// A read that needs a bigger packet buffer than init made can run out of memory. This
/// happens only when a chained file has a link with big header packets.
fn dataError(err: packets.PacketReader.Error) DataError {
    return switch (err) {
        error.OutOfMemory => error.ReadFailed,
        else => |e| e,
    };
}

fn seekError(err: codec.InitError) codec.SeekError {
    return switch (err) {
        error.BadHeader => error.BadData,
        else => |e| e,
    };
}

fn readHeaderError(err: codec.InitError) DataError {
    return switch (err) {
        error.BadHeader, error.BadData, error.Unsupported => error.BadData,
        error.OutOfMemory, error.ReadFailed => error.ReadFailed,
        error.Truncated => error.Truncated,
    };
}

/// Sets the packet limit of the reader and keeps `held` valid when that moves the buffer.
pub fn setBound(reader: *packets.PacketReader, held: *?packets.Packet, bound: usize) error{OutOfMemory}!void {
    const was_pending = if (held.*) |h| h.data.ptr == reader.pending.items.ptr else false;
    try reader.reserve(bound);
    if (was_pending) held.*.?.data = reader.pending.items;
}

/// Plays the links of a chained Ogg stream as one stream. The chain owns the packet
/// reader, the link table, the timeline and the format change rule. `Codec` decodes the
/// packets of one link. See flac/ogg.zig and the test at the end of this file.
///
/// The frame positions of `seek` count from the start of the first link. A link with the
/// same shape as the one before it continues without a signal. When the shape changes,
/// `read` gives error.StreamChanged after the frames of the old link, and the next `read`
/// continues with the first frame of the new link. The errors of the decode functions of
/// `Codec` are a subset of `FrameError`.
///
/// `Codec` is a struct type with these declarations. `self` is a `*Codec`.
///
/// - `const Headers`: a struct of the header packets of a link. It has the fields
///   `held: ?ogg.Packet`, the first packet after the headers (the first audio packet, or the
///   first packet of the next link) and `biggest: usize`, the size of the biggest packet read.
///   It can own memory. `enter` takes the ownership, `releaseHeaders` gives it back. At most
///   one `Headers` value lives beside the headers of the current link (in the loop that reads
///   the links at init, in `enterLink` after a staged value is released, and in `nextLink`), so
///   a codec sizes its header storage in `reserve` for two.
/// - `const max_header_packet: usize`: the packet limit while the headers are read.
/// - `fn isFirst(context: ?*anyopaque, packet: []const u8) bool`: true for the first packet
///   of a stream of this codec. The reader uses it to select the links.
/// - `fn linkLength(self, h: *const Headers, link: *const ogg.Link, reader: *PacketReader) ?Length`:
///   the length of a link, or null when the codec cannot tell. The chain calls it at init for
///   every link while the headers `h` of the link are in hand (`link` has the granules, and
///   `reader` is at the first audio packet, which the codec can read on). Its position is not
///   used afterwards. `Length.start` is the time of the first frame in granule units, 0 for
///   a link that starts at 0. The chain gives it back to the codec with `linkStart()`.
/// - `fn skipBad(self) bool`: the reader dropped a packet because it is too big. True when the
///   codec counts it and goes on with the next packet, false to end the stream with BadData.
/// - `fn readHeaders(self, reader: *PacketReader, first: []const u8) InitError!Headers`: reads
///   the header packets after `first` and marks the start of the audio in the reader. A failure
///   frees what it made. The codec can take the memory from storage that `reserve` made, so
///   this does not allocate when the link table is complete.
/// - `fn releaseHeaders(self, h: *Headers) void`: frees the memory of headers that were not
///   given to `enter`. The chain calls it for each `Headers` value that it drops.
/// - `fn deinit(self) void`.
/// - `fn reserve(self, h: *const Headers) InitError!usize`: makes the buffers and the header
///   storage of the codec big enough for the link without starting it. Returns the packet
///   limit for the link.
/// - `fn enter(self, h: *Headers) InitError!usize`: starts the link in the codec and returns
///   the packet limit for it. It owns `h` also when it fails.
/// - `fn settle(self, first: ?ogg.Packet) bool`: learns from the first packet of a link
///   where its audio starts. Returns true when the link has audio.
/// - `fn sameShape(self, h: *const Headers) bool`: true when the link of `h` has the same
///   format as the current one.
/// - `fn info(self) codec.Info`: describes the current link.
/// - `fn canLoad(self) FrameError!bool`: the error that ended the stream, or false at the end.
/// - `fn fail(self, err: FrameError) void`: ends the stream with `err`.
/// - `fn decode(self, packet: ogg.Packet) FrameError!bool`: decodes the next packet into the
///   output block. False when it skipped a bad packet. The packet has its granule and flags.
/// - `fn endOfData(self) FrameError!bool`: the packets ended. Returns false.
/// - `fn endLink(self) FrameError!void`: the packets of a link ended and another link follows.
/// - `fn read(self, comptime T: type, out: []T, loader: anytype) FrameError!usize`: copies
///   frames from the output block. When it is empty it calls `loader.loadBlock()`, which
///   returns false at the end.
/// - `fn beginSeek(self) void`: forgets the position and the checks of the stream.
/// - `fn clearPosition(self) void`: forgets the position.
/// - `fn linkTotal(self) ?u64`: the frame count of the current link when it is exact.
/// - `fn seekEnd(self, frames: u64) void`: puts the codec at the end of a link of `frames`.
/// - `fn failSeek(self, err: FrameError) void`: leaves the codec failed after a seek error.
/// - `fn seekIn(self, chain: anytype, local: u64) SeekError!void`: moves to the frame `local`
///   of the current link. It reads packets with `chain.nextData()` and can set `chain.held`
///   and use `chain.reader`.
pub fn Chain(comptime Codec: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        input: *io.Input,
        reader: packets.PacketReader,
        codec: Codec,
        /// A packet already taken from the reader that `nextData` returns first.
        held: ?packets.Packet = null,
        /// The headers of a link with another format, kept until `read` reports the change.
        staged: ?Codec.Headers = null,
        /// The index of the link that the decoder is in.
        cur: usize = 0,
        /// The link has at least one packet of audio.
        has_audio: bool = false,
        /// The input is seekable, so `reader.links` holds the links of the whole file.
        scanned: bool = false,
        /// The frame position where each link starts, then the total. Empty when a length is unknown.
        bases: []u64 = &.{},
        /// Every length comes from the first packets, so the total is exact.
        bases_trusted: bool = false,
        /// The start time of each link in the units of the granules, when `bases` is set.
        starts: []i64 = &.{},

        pub const Next = union(enum) {
            frame: packets.Packet,
            /// The first packet of the next link.
            link: packets.Packet,
            end,
        };

        /// Takes the reader and the codec, also when this fails. The codec owns the headers of
        /// the first link. `held` is the packet that `Codec.readHeaders` returned for it. The
        /// packet limit of the reader must already fit the link (see `setBound`). The caller
        /// has set `select` of the reader to the first packets of the codec and
        /// `begin_group_only` to false.
        ///
        /// On a seekable input this reads every page header of the file once, to find the links.
        pub fn init(
            gpa: std.mem.Allocator,
            input: *io.Input,
            reader_in: packets.PacketReader,
            codec_in: Codec,
            held: ?packets.Packet,
        ) codec.InitError!Self {
            var reader = reader_in;
            var inner = codec_in;
            var built = false;
            errdefer if (!built) {
                inner.deinit();
                reader.deinit();
            };
            if (input.seekable()) {
                reader.scanLinks() catch |err| switch (err) {
                    error.Unseekable => {},
                    else => |e| return e,
                };
            }
            var self: Self = .{
                .gpa = gpa,
                .input = input,
                .reader = reader,
                .codec = inner,
                .held = held,
                .scanned = reader.links.items.len > 0,
            };
            built = true;
            errdefer self.deinit();
            self.settle();
            const lens = try self.reserveLinks();
            defer self.gpa.free(lens);
            try self.timeline(lens);
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.staged) |*h| self.codec.releaseHeaders(h);
            self.gpa.free(self.bases);
            self.gpa.free(self.starts);
            self.codec.deinit();
            self.reader.deinit();
            self.* = undefined;
        }

        /// When the table holds every link, reads the headers of all links, makes the packet
        /// buffer and the buffers of the codec big enough for the biggest one and asks the codec
        /// for the length of each link. A later link then starts without an allocation. The
        /// result has one entry per link, or is empty when the table is not complete. A link with
        /// bad headers has no length and is left for `read` to report. The first link is
        /// entered again at the end.
        fn reserveLinks(self: *Self) codec.InitError![]?Length {
            const reader = &self.reader;
            if (!self.scanned or !reader.links_complete or reader.links.items.len == 0) return &.{};
            const lens = try self.gpa.alloc(?Length, reader.links.items.len);
            errdefer self.gpa.free(lens);
            @memset(lens, null);
            var biggest: usize = reader.pending.capacity;
            for (lens, 0..) |*len, index| {
                reader.max_packet = Codec.max_header_packet;
                self.held = null;
                reader.seekLink(index) catch return error.ReadFailed;
                const p = (reader.next() catch |err| switch (err) {
                    error.OutOfMemory, error.ReadFailed => |e| return e,
                    else => continue,
                }) orelse continue;
                if (!Codec.isFirst(null, p.data)) continue;
                var h = self.codec.readHeaders(reader, p.data) catch |err| switch (err) {
                    error.OutOfMemory, error.ReadFailed => |e| return e,
                    else => continue,
                };
                defer self.codec.releaseHeaders(&h);
                const bound = try self.codec.reserve(&h);
                biggest = @max(biggest, h.biggest, bound);
                if (reader.links.items[index].last_granule == null) {
                    _ = reader.lastGranule() catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => null,
                    };
                }
                len.* = self.codec.linkLength(&h, &reader.links.items[index], reader);
            }
            try reader.reserve(biggest);
            self.enterLink(0) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.BadData => error.BadHeader,
                error.Truncated => error.Truncated,
                else => error.ReadFailed,
            };
            return lens;
        }

        /// Computes where each link starts from the lengths that `reserveLinks` got.
        fn timeline(self: *Self, lens: []const ?Length) error{OutOfMemory}!void {
            if (lens.len == 0) return;
            const bases = try self.gpa.alloc(u64, lens.len + 1);
            errdefer self.gpa.free(bases);
            const starts = try self.gpa.alloc(i64, lens.len);
            errdefer self.gpa.free(starts);
            var sum: u64 = 0;
            var trusted = true;
            for (lens, 0..) |known, i| {
                bases[i] = sum;
                // A link with bad headers or without a length from the codec counts its last
                // granule, as a hint.
                const length = known orelse blk: {
                    const last = self.reader.links.items[i].last_granule orelse {
                        self.gpa.free(bases);
                        self.gpa.free(starts);
                        return;
                    };
                    break :blk Length{ .frames = if (last > 0) @intCast(last) else 0, .trusted = false };
                };
                starts[i] = length.start;
                trusted = trusted and length.trusted;
                sum +|= length.frames;
            }
            bases[lens.len] = sum;
            self.bases = bases;
            self.starts = starts;
            self.bases_trusted = trusted;
        }

        /// The start time of the current link in the units of the granules, when init got it.
        pub fn linkStart(self: *const Self) ?i64 {
            if (self.cur < self.starts.len) return self.starts[self.cur];
            return null;
        }

        /// The description of the current link. `total_frames` is the sum over the links when
        /// the input is seekable and every length is known. A reader that cannot seek only
        /// knows the current link, so it reports the total of that link.
        pub fn info(self: *const Self) codec.Info {
            var i = self.codec.info();
            if (self.scanned) i.total_frames = if (self.bases.len > 0) self.bases[self.bases.len - 1] else null;
            return i;
        }

        /// Copies frames into `out` and returns the count. 0 means the end. When the next
        /// link has another format, the call after the last frame of the old link returns
        /// error.StreamChanged and no frames.
        pub fn read(self: *Self, comptime T: type, out: []T) codec.ReadError!usize {
            const n = try self.codec.read(T, out, Loader{ .chain = self });
            if (n == 0 and self.staged != null) {
                try self.applyStaged();
                return error.StreamChanged;
            }
            return n;
        }

        /// Lets the codec ask for the next block without showing `loadBlock` in the public type.
        const Loader = struct {
            chain: *Self,

            pub fn loadBlock(self: Loader) FrameError!bool {
                return self.chain.loadBlock();
            }
        };

        /// The next packet, from `held` or from the reader. A begin page starts a link.
        pub fn nextData(self: *Self) DataError!Next {
            const p = if (self.held) |h| blk: {
                self.held = null;
                break :blk h;
            } else while (true) {
                break (self.reader.next() catch |err| {
                    if (err == error.BadData and self.codec.skipBad()) continue;
                    return dataError(err);
                }) orelse return .end;
            };
            return if (p.bos) .{ .link = p } else .{ .frame = p };
        }

        fn loadBlock(self: *Self) FrameError!bool {
            const c = &self.codec;
            if (!try c.canLoad()) return false;
            while (true) {
                const next = self.nextData() catch |err| {
                    c.fail(err);
                    return err;
                };
                switch (next) {
                    .end => return c.endOfData(),
                    .link => |first| {
                        if (!try self.nextLink(first)) return false;
                    },
                    .frame => |packet| {
                        if (try c.decode(packet)) return true;
                    },
                }
            }
        }

        /// The old link has no more frames and `first` starts the next one. False when the
        /// new link has another format and waits for `read` to report the change.
        fn nextLink(self: *Self, first: packets.Packet) FrameError!bool {
            try self.codec.endLink();
            self.reader.max_packet = Codec.max_header_packet;
            const h = self.codec.readHeaders(&self.reader, first.data) catch |err| {
                const e = readHeaderError(err);
                self.codec.fail(e);
                return e;
            };
            if (!self.codec.sameShape(&h)) {
                self.staged = h;
                return false;
            }
            try self.enter(h);
            self.cur += 1;
            return true;
        }

        fn applyStaged(self: *Self) FrameError!void {
            const h = self.staged.?;
            self.staged = null;
            try self.enter(h);
            self.cur += 1;
        }

        /// Makes `h` the headers of the stream in a read. A failure ends the stream.
        fn enter(self: *Self, h_in: Codec.Headers) FrameError!void {
            var h = h_in;
            self.start(&h) catch |err| {
                const e = readHeaderError(err);
                self.codec.fail(e);
                return e;
            };
        }

        /// Starts the link described by `h` in the codec, which takes the ownership of `h`.
        fn start(self: *Self, h: *Codec.Headers) codec.InitError!void {
            var held = h.held;
            const bound = try self.codec.enter(h);
            try setBound(&self.reader, &held, bound);
            self.held = held;
            self.settle();
        }

        fn settle(self: *Self) void {
            self.has_audio = self.codec.settle(self.held);
        }

        /// Moves to a frame of the whole stream. `frame` equal to the frame count is the end of
        /// the data. A format change at a link is not reported by a seek: `info()` describes the
        /// link that the frame is in. A chained file whose link lengths are unknown gives
        /// error.Unsupported.
        pub fn seek(self: *Self, frame: u64) codec.SeekError!void {
            if (!self.input.seekable()) return error.Unseekable;
            if (self.scanned and self.bases.len == 0 and self.reader.links.items.len > 1) return error.Unsupported;
            self.seekInner(frame) catch |err| {
                self.codec.failSeek(switch (err) {
                    error.BadData => error.BadData,
                    error.Truncated => error.Truncated,
                    else => error.ReadFailed,
                });
                return err;
            };
        }

        /// The index of the link that holds `frame`.
        fn linkOf(self: *const Self, frame: u64) usize {
            const n = self.bases.len - 1;
            var lo: usize = 0;
            var hi: usize = n;
            while (hi - lo > 1) {
                const mid = lo + (hi - lo) / 2;
                if (self.bases[mid] <= frame) lo = mid else hi = mid;
            }
            // A link of length 0 shares its start with the next link.
            while (lo + 1 < n and self.bases[lo + 1] <= frame) lo += 1;
            return lo;
        }

        /// Moves the reader to the begin page of the link and reads its headers.
        fn enterLink(self: *Self, index: usize) codec.SeekError!void {
            const reader = &self.reader;
            reader.max_packet = Codec.max_header_packet;
            self.held = null;
            try reader.seekLink(index);
            const p = (reader.next() catch |err| return seekError(initError(err))) orelse return error.Truncated;
            if (!Codec.isFirst(null, p.data)) return error.BadData;
            var h = self.codec.readHeaders(reader, p.data) catch |err| return seekError(err);
            self.start(&h) catch |err| return seekError(err);
            self.cur = index;
        }

        fn seekInner(self: *Self, frame: u64) codec.SeekError!void {
            const c = &self.codec;
            c.beginSeek();
            self.held = null;
            // The reader sits in the staged link, so the current link is entered again.
            const stale = self.staged != null;
            if (self.staged) |*h| self.codec.releaseHeaders(h);
            self.staged = null;
            var link = self.cur;
            var local = frame;
            var length: ?u64 = null;
            if (self.bases.len > 0) {
                if (self.bases_trusted and frame > self.bases[self.bases.len - 1]) return error.Truncated;
                link = self.linkOf(frame);
                local = frame - self.bases[link];
                if (self.bases_trusted) length = self.bases[link + 1] - self.bases[link];
            } else if (c.linkTotal()) |t| {
                if (frame > t) return error.Truncated;
                length = t;
            }
            if (link != self.cur or stale) {
                try self.enterLink(link);
                c.clearPosition();
            }
            if (!self.has_audio) {
                // Nothing to find, and the reader has no audio page to go back to.
                if (local != 0) return error.Truncated;
                c.seekEnd(0);
                return;
            }
            if (length) |len| {
                if (local == len) {
                    self.held = null;
                    c.seekEnd(len);
                    return;
                }
            }
            try c.seekIn(self, local);
        }
    };
}

const FakeError = codec.DecodeError;

/// A codec for the tests. The first packet of a link is { 0xf0, format, pre-skip, total }. A
/// total other than 0 is the exact frame count of the link. An audio packet is { 1, frames }
/// and it decodes to that many frames, each holding its frame number in the link. 0 frames is
/// a packet that the decoder skips. The headers own a buffer, which comes from storage that
/// `reserve` makes when it can.
const Fake = struct {
    pub const max_header_packet = 64;
    const extra_len = 32;
    pub const Headers = struct { held: ?packets.Packet, biggest: usize, format: u8, extra: []u8 };

    gpa: std.mem.Allocator,
    format: u8,
    extra: []u8 = &.{},
    store: ?[]u8 = null,
    used: [2]bool = .{ false, false },
    block: [16]u32 = undefined,
    block_len: usize = 0,
    block_pos: usize = 0,
    next: u32 = 0,
    at_end: bool = false,
    failed: ?FakeError = null,
    skipped: u32 = 0,
    last_granule: i64 = -2,

    fn init(gpa: std.mem.Allocator, h: *Headers) Fake {
        const extra = h.extra;
        h.extra = &.{};
        return .{ .gpa = gpa, .format = h.format, .extra = extra };
    }

    fn allocExtra(self: *Fake) error{OutOfMemory}![]u8 {
        if (self.store) |s| {
            for (&self.used, 0..) |*u, i| {
                if (!u.*) {
                    u.* = true;
                    return s[i * extra_len ..][0..extra_len];
                }
            }
        }
        return self.gpa.alloc(u8, extra_len);
    }

    fn freeExtra(self: *Fake, b: []u8) void {
        if (self.store) |s| {
            const at = @intFromPtr(b.ptr);
            const base = @intFromPtr(s.ptr);
            if (at >= base and at < base + s.len) {
                self.used[(at - base) / extra_len] = false;
                return;
            }
        }
        self.gpa.free(b);
    }

    pub fn isFirst(context: ?*anyopaque, packet: []const u8) bool {
        _ = context;
        return packet.len >= 2 and packet[0] == 0xf0;
    }

    pub fn skipBad(self: *Fake) bool {
        _ = self;
        return false;
    }

    pub fn linkLength(self: *Fake, h: *const Headers, link: *const packets.Link, reader: *packets.PacketReader) ?Length {
        _ = self;
        _ = h;
        _ = reader;
        const head = link.firstBytes();
        if (head.len >= 4 and head[3] != 0) return .{ .frames = head[3], .trusted = true };
        const last = link.last_granule orelse return null;
        const skip: i64 = if (head.len >= 3) head[2] else 0;
        return .{ .frames = @intCast(@max(0, last - link.first_granule - skip)), .trusted = false };
    }

    pub fn readHeaders(self: *Fake, reader: *packets.PacketReader, first: []const u8) codec.InitError!Headers {
        if (first.len < 2 or first[0] != 0xf0) return error.BadHeader;
        const format = first[1];
        const extra = try self.allocExtra();
        errdefer self.freeExtra(extra);
        @memset(extra, format);
        const p = reader.next() catch |err| return initError(err);
        if (p) |packet| {
            if (!packet.bos) reader.markAudio(packet);
            return .{ .held = packet, .biggest = 2, .format = format, .extra = extra };
        }
        return .{ .held = null, .biggest = 2, .format = format, .extra = extra };
    }

    pub fn releaseHeaders(self: *Fake, h: *Headers) void {
        if (h.extra.len > 0) self.freeExtra(h.extra);
        h.extra = &.{};
    }

    pub fn deinit(self: *Fake) void {
        if (self.extra.len > 0) self.freeExtra(self.extra);
        if (self.store) |s| self.gpa.free(s);
    }

    pub fn reserve(self: *Fake, h: *const Headers) codec.InitError!usize {
        _ = h;
        if (self.store == null) self.store = try self.gpa.alloc(u8, 2 * extra_len);
        return 64;
    }

    pub fn enter(self: *Fake, h: *Headers) codec.InitError!usize {
        if (self.extra.len > 0) self.freeExtra(self.extra);
        self.extra = h.extra;
        h.extra = &.{};
        self.format = h.format;
        self.next = 0;
        self.block_len = 0;
        self.block_pos = 0;
        self.at_end = false;
        self.failed = null;
        return 64;
    }

    pub fn settle(self: *Fake, first: ?packets.Packet) bool {
        _ = self;
        const p = first orelse return false;
        return !p.bos;
    }

    pub fn sameShape(self: *const Fake, h: *const Headers) bool {
        return self.format == h.format;
    }

    pub fn info(self: *const Fake) codec.Info {
        return .{ .rate = 1000 * @as(u32, self.format), .channels = 1 };
    }

    pub fn canLoad(self: *const Fake) FakeError!bool {
        if (self.failed) |err| return err;
        return !self.at_end;
    }

    pub fn fail(self: *Fake, err: FakeError) void {
        self.failed = err;
    }

    pub fn decode(self: *Fake, packet: packets.Packet) FakeError!bool {
        const data = packet.data;
        if (data.len != 2 or data[0] != 1 or data[1] > self.block.len) {
            self.failed = error.BadData;
            return error.BadData;
        }
        self.last_granule = packet.granule;
        if (data[1] == 0) {
            self.skipped += 1;
            return false;
        }
        for (0..data[1]) |i| self.block[i] = self.next + @as(u32, @intCast(i));
        self.next += data[1];
        self.block_len = data[1];
        self.block_pos = 0;
        return true;
    }

    pub fn endOfData(self: *Fake) FakeError!bool {
        self.at_end = true;
        return false;
    }

    pub fn endLink(self: *Fake) FakeError!void {
        self.at_end = true;
    }

    pub fn read(self: *Fake, comptime T: type, out: []T, loader: anytype) FakeError!usize {
        var done: usize = 0;
        while (done < out.len) {
            if (self.block_pos == self.block_len) {
                const more = loader.loadBlock() catch |err| {
                    if (done > 0) return done;
                    return err;
                };
                if (!more) break;
            }
            out[done] = @intCast(self.block[self.block_pos]);
            self.block_pos += 1;
            done += 1;
        }
        return done;
    }

    pub fn beginSeek(self: *Fake) void {
        self.clearPosition();
    }

    pub fn clearPosition(self: *Fake) void {
        self.failed = null;
        self.at_end = false;
        self.block_len = 0;
        self.block_pos = 0;
    }

    pub fn linkTotal(self: *const Fake) ?u64 {
        _ = self;
        return null;
    }

    pub fn seekEnd(self: *Fake, frames: u64) void {
        self.next = @intCast(frames);
        self.at_end = true;
        self.block_len = 0;
        self.block_pos = 0;
    }

    pub fn failSeek(self: *Fake, err: FakeError) void {
        self.failed = err;
        self.block_len = 0;
        self.block_pos = 0;
    }

    pub fn seekIn(self: *Fake, chain: anytype, local: u64) codec.SeekError!void {
        chain.held = null;
        _ = try chain.reader.seekGranule(-1);
        self.next = 0;
        while (true) {
            const packet = switch (try chain.nextData()) {
                .frame => |p| p,
                .link, .end => {
                    if (self.next != local) return error.Truncated;
                    self.block_len = 0;
                    self.block_pos = 0;
                    return;
                },
            };
            const before = self.next;
            _ = try self.decode(packet);
            if (local < self.next) {
                self.block_pos = @intCast(local - before);
                return;
            }
        }
    }
};

const LinkOptions = struct {
    format: u8,
    /// The frames of each audio packet.
    frames: []const u8,
    /// The granule of the header page, which the granules of the audio add to.
    base: i64 = 0,
    preskip: u8 = 0,
    total: u8 = 0,
};

/// Writes one link: the first packet, then audio packets with their running granule.
fn fakeLink(gpa: std.mem.Allocator, w: *std.Io.Writer, serial: u32, o: LinkOptions) !void {
    var pw: packets.PacketWriter = try .init(gpa, w, serial, .{ .flush_on_granule = true });
    defer pw.deinit();
    try pw.writePacket(&.{ 0xf0, o.format, o.preskip, o.total }, o.base);
    var granule: i64 = o.base;
    for (o.frames) |n| {
        granule += n;
        try pw.writePacket(&.{ 1, n }, granule);
    }
    try pw.finish();
}

fn fakeChain(gpa: std.mem.Allocator, input: *io.Input) !Chain(Fake) {
    var reader: packets.PacketReader = try .init(gpa, input, .{ .accept = .{ .func = Fake.isFirst } }, .{ .max_packet_size = Fake.max_header_packet });
    var handed = false;
    errdefer if (!handed) reader.deinit();
    const first = (try reader.next()) orelse return error.Unsupported;
    var tmp: Fake = .{ .gpa = gpa, .format = 0 };
    var h = try tmp.readHeaders(&reader, first.data);
    errdefer tmp.releaseHeaders(&h);
    var held = h.held;
    try setBound(&reader, &held, 64);
    const fake: Fake = .init(gpa, &h);
    handed = true;
    return Chain(Fake).init(gpa, input, reader, fake, held);
}

fn expectFrames(chain: *Chain(Fake), first: u32, count: u32) !void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var one: [1]u32 = undefined;
        try testing.expectEqual(@as(usize, 1), try chain.read(u32, &one));
        try testing.expectEqual(first + i, one[0]);
    }
}

test "three links play on one timeline and a format change is reported once" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try fakeLink(gpa, &aw.writer, 1, .{ .format = 1, .frames = &.{ 4, 4, 2 } });
    try fakeLink(gpa, &aw.writer, 2, .{ .format = 1, .frames = &.{ 5, 5 } });
    try fakeLink(gpa, &aw.writer, 3, .{ .format = 2, .frames = &.{ 3, 3, 4 } });

    var input: io.Input = .init(.{ .bytes = aw.written() });
    var chain = try fakeChain(gpa, &input);
    defer chain.deinit();
    try testing.expectEqual(@as(?u64, 30), chain.info().total_frames);
    try testing.expectEqual(@as(u32, 1000), chain.info().rate);

    // Links 1 and 2 have one format, so they play without a signal.
    try expectFrames(&chain, 0, 10);
    try expectFrames(&chain, 0, 10);
    var one: [1]u32 = undefined;
    try testing.expectError(error.StreamChanged, chain.read(u32, &one));
    try testing.expectEqual(@as(u32, 2000), chain.info().rate);
    try expectFrames(&chain, 0, 10);
    try testing.expectEqual(@as(usize, 0), try chain.read(u32, &one));
    try testing.expectEqual(@as(usize, 0), try chain.read(u32, &one));

    // A seek into link 3 changes the info at once and gives no signal.
    try chain.seek(25);
    try testing.expectEqual(@as(u32, 2000), chain.info().rate);
    try expectFrames(&chain, 5, 5);
    try testing.expectEqual(@as(usize, 0), try chain.read(u32, &one));

    // Back to link 1.
    try chain.seek(3);
    try testing.expectEqual(@as(u32, 1000), chain.info().rate);
    try expectFrames(&chain, 3, 7);
    try expectFrames(&chain, 0, 10);
    try testing.expectError(error.StreamChanged, chain.read(u32, &one));
    try testing.expectEqual(@as(u32, 2000), chain.info().rate);

    // The end of the timeline.
    try chain.seek(30);
    try testing.expectEqual(@as(usize, 0), try chain.read(u32, &one));
}

test "a seek after a staged format change enters the link again" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try fakeLink(gpa, &aw.writer, 1, .{ .format = 1, .frames = &.{ 4, 4, 2 } });
    try fakeLink(gpa, &aw.writer, 2, .{ .format = 1, .frames = &.{ 5, 5 } });
    try fakeLink(gpa, &aw.writer, 3, .{ .format = 2, .frames = &.{ 3, 3, 4 } });

    var input: io.Input = .init(.{ .bytes = aw.written() });
    var chain = try fakeChain(gpa, &input);
    defer chain.deinit();

    // One big read ends at the format change. The reader already sits in link 3.
    var all: [64]u32 = undefined;
    try testing.expectEqual(@as(usize, 20), try chain.read(u32, &all));
    try testing.expectEqual(@as(u32, 9), all[19]);

    // Frame 15 is in link 2, the link of the decoder, but the headers of link 3 are staged.
    try chain.seek(15);
    try testing.expectEqual(@as(u32, 1000), chain.info().rate);
    try expectFrames(&chain, 5, 5);
    var one: [1]u32 = undefined;
    try testing.expectError(error.StreamChanged, chain.read(u32, &one));
    try expectFrames(&chain, 0, 10);
}

fn threeLinks(aw: *std.Io.Writer.Allocating) !void {
    const gpa = testing.allocator;
    try fakeLink(gpa, &aw.writer, 1, .{ .format = 1, .frames = &.{ 4, 4, 2 } });
    try fakeLink(gpa, &aw.writer, 2, .{ .format = 1, .frames = &.{ 5, 5 } });
    try fakeLink(gpa, &aw.writer, 3, .{ .format = 2, .frames = &.{ 3, 3, 4 } });
}

test "staged headers are released when the chain ends" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try threeLinks(&aw);

    var input: io.Input = .init(.{ .bytes = aw.written() });
    var chain = try fakeChain(gpa, &input);
    defer chain.deinit();
    var all: [64]u32 = undefined;
    try testing.expectEqual(@as(usize, 20), try chain.read(u32, &all));
    try testing.expect(chain.staged != null);
}

test "reads, format changes and seeks do not allocate after init" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try threeLinks(&aw);

    var failing: testing.FailingAllocator = .init(gpa, .{});
    var input: io.Input = .init(.{ .bytes = aw.written() });
    var chain = try fakeChain(failing.allocator(), &input);
    defer chain.deinit();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    var all: [64]u32 = undefined;
    try testing.expectEqual(@as(usize, 20), try chain.read(u32, &all));
    try testing.expectError(error.StreamChanged, chain.read(u32, &all));
    try expectFrames(&chain, 0, 10);
    try chain.seek(3);
    try testing.expectEqual(@as(usize, 17), try chain.read(u32, &all));
    try chain.seek(25);
    try expectFrames(&chain, 5, 5);
    try chain.seek(15);
    try expectFrames(&chain, 5, 5);
    try testing.expectError(error.StreamChanged, chain.read(u32, &all));
}

test "the length of a link comes from the granules and the first bytes" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    // The granules of the first link start at 1000, the second has a pre-skip of 3.
    try fakeLink(gpa, &aw.writer, 1, .{ .format = 1, .frames = &.{ 5, 5 }, .base = 1000 });
    try fakeLink(gpa, &aw.writer, 2, .{ .format = 1, .frames = &.{ 4, 4, 4 }, .base = 500, .preskip = 3 });
    try fakeLink(gpa, &aw.writer, 3, .{ .format = 1, .frames = &.{2} });

    var input: io.Input = .init(.{ .bytes = aw.written() });
    var chain = try fakeChain(gpa, &input);
    defer chain.deinit();
    try testing.expectEqualSlices(u64, &.{ 0, 10, 19, 21 }, chain.bases);
    try testing.expect(!chain.bases_trusted);
    try testing.expectEqual(@as(?u64, 21), chain.info().total_frames);
    try chain.seek(19);
    try expectFrames(&chain, 0, 2);
}

test "a trusted length makes the end exact" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    // The last link states 12 frames but holds 10, so only the shortcut can reach frame 32.
    try fakeLink(gpa, &aw.writer, 1, .{ .format = 1, .frames = &.{ 5, 5 }, .total = 10 });
    try fakeLink(gpa, &aw.writer, 2, .{ .format = 1, .frames = &.{ 5, 5 }, .total = 10 });
    try fakeLink(gpa, &aw.writer, 3, .{ .format = 1, .frames = &.{ 5, 5 }, .total = 12 });

    var input: io.Input = .init(.{ .bytes = aw.written() });
    var chain = try fakeChain(gpa, &input);
    defer chain.deinit();
    try testing.expect(chain.bases_trusted);
    try testing.expectEqual(@as(?u64, 32), chain.info().total_frames);
    try chain.seek(32);
    var one: [1]u32 = undefined;
    try testing.expectEqual(@as(usize, 0), try chain.read(u32, &one));
    try testing.expectError(error.Truncated, chain.seek(33));
    try chain.seek(21);
    try expectFrames(&chain, 1, 3);
}

test "a skipped packet gives no frames and decode sees the granule" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try fakeLink(gpa, &aw.writer, 1, .{ .format = 1, .frames = &.{ 3, 0, 4 } });

    var input: io.Input = .init(.{ .bytes = aw.written() });
    var chain = try fakeChain(gpa, &input);
    defer chain.deinit();
    var out: [3]u32 = undefined;
    try testing.expectEqual(@as(usize, 3), try chain.read(u32, &out));
    try testing.expectEqual(@as(i64, 3), chain.codec.last_granule);
    try expectFrames(&chain, 3, 4);
    try testing.expectEqual(@as(u32, 1), chain.codec.skipped);
    try testing.expectEqual(@as(i64, 7), chain.codec.last_granule);
    try testing.expectEqual(@as(usize, 0), try chain.read(u32, &out));
    try chain.seek(5);
    try expectFrames(&chain, 5, 2);
}
