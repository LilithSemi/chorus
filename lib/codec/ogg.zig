//! Ogg pages, packet demuxing and muxing, chained and multiplexed streams, granule seek.
const std = @import("std");
const crc = @import("crc.zig");
const io = @import("io.zig");
const Input = io.Input;
const testing = std.testing;

pub const header_size = 27;
pub const max_segments = 255;
pub const max_body = 255 * 255;
pub const max_page_size = header_size + max_segments + max_body;

pub const Flags = packed struct(u8) {
    continued: bool = false,
    bos: bool = false,
    eos: bool = false,
    reserved: u5 = 0,
};

pub const Header = struct {
    flags: Flags = .{},
    granule: i64,
    serial: u32,
    sequence: u32,
};

/// A parsed page. The slices point into the bytes given to `parsePage`.
pub const Page = struct {
    flags: Flags,
    granule: i64,
    serial: u32,
    sequence: u32,
    lacing: []const u8,
    body: []const u8,

    pub fn size(self: Page) usize {
        return header_size + self.lacing.len + self.body.len;
    }
};

/// `NotPage` means the bytes do not start with a valid page header.
/// `Truncated` means more bytes are needed.
pub const ParseError = error{ NotPage, Truncated, BadCrc };

pub const BuildError = error{ NoSpace, BadLacing };

fn pageCrc(head: []const u8, body: []const u8) u32 {
    var c = crc.ogg.init();
    c.update(head[0..22]);
    c.update(&.{ 0, 0, 0, 0 });
    c.update(head[26..]);
    c.update(body);
    return c.final();
}

/// Parses and checks one page at the start of `bytes`.
pub fn parsePage(bytes: []const u8) ParseError!Page {
    const cap = "OggS";
    if (!std.mem.startsWith(u8, bytes, cap[0..@min(bytes.len, cap.len)])) return error.NotPage;
    if (bytes.len < header_size) return error.Truncated;
    if (bytes[4] != 0) return error.NotPage;
    const nseg: usize = bytes[26];
    if (bytes.len < header_size + nseg) return error.Truncated;
    const lacing = bytes[header_size..][0..nseg];
    var body_len: usize = 0;
    for (lacing) |v| body_len += v;
    const total = header_size + nseg + body_len;
    if (bytes.len < total) return error.Truncated;
    const head = bytes[0 .. header_size + nseg];
    const body = bytes[header_size + nseg .. total];
    if (pageCrc(head, body) != std.mem.readInt(u32, bytes[22..26], .little)) return error.BadCrc;
    return .{
        .flags = @bitCast(bytes[5]),
        .granule = std.mem.readInt(i64, bytes[6..14], .little),
        .serial = std.mem.readInt(u32, bytes[14..18], .little),
        .sequence = std.mem.readInt(u32, bytes[18..22], .little),
        .lacing = lacing,
        .body = body,
    };
}

fn writeHeader(buf: *[header_size + max_segments]u8, h: Header, lacing: []const u8, body: []const u8) usize {
    @memcpy(buf[0..4], "OggS");
    buf[4] = 0;
    buf[5] = @bitCast(h.flags);
    std.mem.writeInt(i64, buf[6..14], h.granule, .little);
    std.mem.writeInt(u32, buf[14..18], h.serial, .little);
    std.mem.writeInt(u32, buf[18..22], h.sequence, .little);
    @memset(buf[22..26], 0);
    buf[26] = @intCast(lacing.len);
    @memcpy(buf[header_size..][0..lacing.len], lacing);
    const n = header_size + lacing.len;
    std.mem.writeInt(u32, buf[22..26], pageCrc(buf[0..n], body), .little);
    return n;
}

/// Builds one page into `out` and returns its length. `body.len` must equal the sum of `lacing`.
pub fn buildPage(out: []u8, h: Header, lacing: []const u8, body: []const u8) BuildError!usize {
    if (lacing.len > max_segments) return error.BadLacing;
    var sum: usize = 0;
    for (lacing) |v| sum += v;
    if (sum != body.len) return error.BadLacing;
    const total = header_size + lacing.len + body.len;
    if (out.len < total) return error.NoSpace;
    var head: [header_size + max_segments]u8 = undefined;
    const n = writeHeader(&head, h, lacing, body);
    @memcpy(out[0..n], head[0..n]);
    @memcpy(out[n..][0..body.len], body);
    return total;
}

/// Picks which logical stream a PacketReader follows.
pub const Select = union(enum) {
    /// Follow the stream with this serial. There is no chaining.
    serial: u32,
    /// Follow the first stream whose first packet the function accepts. After its
    /// end page, the next accepted stream in the file is followed. A begin page that
    /// comes after data pages of the followed stream also starts a new link. The first
    /// packet must end on its begin page, else the stream is not accepted. The function
    /// sees the whole first packet, whatever its length.
    accept: Accept,
    /// Follow the first stream.
    any,

    pub const Accept = struct {
        context: ?*anyopaque = null,
        func: *const fn (context: ?*anyopaque, first_packet: []const u8) bool,
    };
};

/// The most bytes of a first packet that a `Link` keeps.
pub const head_size = 64;
/// `scanLinks` puts no more links than this in the table.
pub const max_links = 1 << 14;

/// A logical stream of a chained file.
pub const Link = struct {
    serial: u32,
    /// Offset of the begin page.
    start: u64,
    /// Offset of the first audio page. Set by `markAudio`.
    audio: ?u64 = null,
    /// The granule before the first audio page. Set by `markAudio`.
    first_granule: i64 = 0,
    /// The granule of the last page that has one. Set by `scanLinks` and `lastGranule`.
    last_granule: ?i64 = null,
    head: [head_size]u8 = @splat(0),
    head_len: u8 = 0,

    /// The first bytes of the first packet of the link.
    pub fn firstBytes(self: *const Link) []const u8 {
        return self.head[0..self.head_len];
    }
};

pub const Stats = struct {
    /// Bytes dropped while looking for the next page.
    skipped_bytes: u64 = 0,
    bad_crc: u64 = 0,
    /// Pages of the followed stream missing between two good pages.
    lost_pages: u64 = 0,
    /// Pages that belong to other streams.
    skipped_pages: u64 = 0,
    /// Streams that were not followed.
    skipped_streams: u64 = 0,
    /// Streams followed so far by reading. More than 1 means a chained file.
    links: u64 = 0,
    /// Pages looked at while seeking.
    seek_probes: u64 = 0,
};

pub const Packet = struct {
    /// Valid until the next call of `next`, `seekGranule`, `seekLinkGranule`, `seekLink` or `deinit`.
    data: []const u8,
    /// The page granule when this is the last packet that ends on its page, else -1.
    granule: i64,
    serial: u32,
    sequence: u32,
    /// First packet of a begin page.
    bos: bool,
    /// Last packet of an end page.
    eos: bool,
    /// Offset in the input of the page where the packet starts.
    offset: u64,
    /// Granule of the last page with a granule before that page, or 0.
    granule_before: i64,
    /// The first packet that completed after pages were lost.
    after_gap: bool = false,
};

pub const PacketReader = struct {
    gpa: std.mem.Allocator,
    input: *Input,
    select: Select,
    max_packet: usize,
    win: []u8,
    begin_group_only: bool = false,
    stopped: bool = false,
    start: usize = 0,
    len: usize = 0,
    eof: bool = false,
    pending: std.ArrayList(u8) = .empty,
    pending_active: bool = false,
    pending_returned: bool = false,
    serial: ?u32 = null,
    ended: bool = false,
    link: ?Link = null,
    /// The links of the file in file order. `scanLinks` fills it.
    links: std.ArrayList(Link) = .empty,
    /// True when `scanLinks` reached the end of the file with every link in `links`.
    links_complete: bool = false,
    max_link_start: ?u64 = null,
    seen_granule: i64 = 0,
    before_granule: i64 = 0,
    pending_offset: u64 = 0,
    pending_before: i64 = 0,
    expected_sequence: ?u32 = null,
    /// A page sequence gap was seen, and no packet has completed since.
    gap_pending: bool = false,
    silent_next: bool = false,
    page: ?PageState = null,
    link_data: bool = false,
    stats: Stats = .{},

    pub const Options = struct {
        /// Packets longer than this give `error.BadData`, whatever their page count. The
        /// default is large. A codec should pass the biggest packet its format allows.
        max_packet_size: usize = 1 << 24,
        /// While no stream is followed, stop at the first page that is not a begin page. `next`
        /// then returns null, so a file with no known stream is not read to its end.
        begin_group_only: bool = false,
    };

    pub const Error = error{ OutOfMemory, BadData, Truncated, ReadFailed };
    pub const SeekError = error{ Unseekable, BadData, Truncated, ReadFailed };
    pub const ScanError = error{ OutOfMemory, Unseekable, ReadFailed };

    const PageState = struct {
        offset: u64,
        before: i64,
        size: usize,
        nseg: usize,
        seg: usize,
        body_off: usize,
        flags: Flags,
        granule: i64,
        serial: u32,
        sequence: u32,
        last_complete: ?usize,
        silent: bool,
        bos_pending: bool,
    };

    const PageHead = struct {
        flags: Flags,
        granule: i64,
        serial: u32,
        sequence: u32,
        nseg: usize,
        size: usize,
        offset: u64,
    };

    /// Allocates the page window once. The packet buffer grows on demand and is kept.
    pub fn init(gpa: std.mem.Allocator, input: *Input, select: Select, options: Options) error{OutOfMemory}!PacketReader {
        return .{
            .gpa = gpa,
            .input = input,
            .select = select,
            .max_packet = options.max_packet_size,
            .begin_group_only = options.begin_group_only,
            .win = try gpa.alloc(u8, max_page_size),
        };
    }

    /// Sets the packet size limit and makes room for a packet of that size, so later
    /// calls of `next` do not allocate.
    pub fn reserve(self: *PacketReader, n: usize) error{OutOfMemory}!void {
        try self.pending.ensureTotalCapacity(self.gpa, n);
        self.max_packet = n;
        // Callers that read without error.OutOfMemory depend on this.
        std.debug.assert(self.pending.capacity >= self.max_packet);
    }

    pub fn deinit(self: *PacketReader) void {
        self.gpa.free(self.win);
        self.pending.deinit(self.gpa);
        self.links.deinit(self.gpa);
        self.* = undefined;
    }

    /// Returns the next packet of the followed stream, or null at the end of the input.
    /// A packet cut off by the end of the input gives `error.Truncated` once.
    pub fn next(self: *PacketReader) Error!?Packet {
        if (self.pending_returned) {
            self.pending.clearRetainingCapacity();
            self.pending_returned = false;
        }
        while (true) {
            if (self.stopped) return null;
            if (self.ended and self.select == .serial) return null;
            if (self.page) |*p| {
                if (try self.packetFromPage(p)) |pkt| return pkt;
                self.dropPage();
            }
            const head = try self.nextPage() orelse {
                if (self.pending_active) {
                    self.pending_active = false;
                    self.pending.clearRetainingCapacity();
                    return error.Truncated;
                }
                return null;
            };
            try self.openPage(head);
        }
    }

    /// Moves to the last page of the current link with a granule at or before `target`
    /// and returns that granule. The next packets are the ones that start after it, so a
    /// packet that crosses into the next page is kept whole. Returns null when no page
    /// qualifies. The link then restarts at its first audio page, or at its first page
    /// when `markAudio` was not called.
    /// Call it after `next` has returned a packet. Granules that run backward give
    /// `error.BadData`. After any error the reader position is unspecified until the next
    /// successful seek. Pages read while seeking count in `stats.seek_probes`.
    pub fn seekGranule(self: *PacketReader, target: i64) SeekError!?i64 {
        const link = self.link orelse return error.BadData;
        return self.seekIn(link, target);
    }

    /// Like `seekGranule`, for the link `index` of `links`. The reader follows that link
    /// afterwards. It works on any link of a scanned file.
    pub fn seekLinkGranule(self: *PacketReader, index: usize, target: i64) SeekError!?i64 {
        if (index >= self.links.items.len) return error.BadData;
        return self.seekIn(self.links.items[index], target);
    }

    /// Moves to the begin page of the link `index` of `links`. The next packet is the first
    /// packet of that link, and the reader follows it from there.
    pub fn seekLink(self: *PacketReader, index: usize) SeekError!void {
        if (index >= self.links.items.len) return error.BadData;
        if (!self.input.seekable()) return error.Unseekable;
        try self.resetAt(self.links.items[index].start);
        self.serial = null;
        self.link = null;
        self.link_data = false;
    }

    fn seekIn(self: *PacketReader, link: Link, target: i64) SeekError!?i64 {
        if (!self.input.seekable()) return error.Unseekable;
        const total = self.input.length() orelse return error.Unseekable;
        const first = link.audio orelse link.start;
        const end = self.linkEnd(link.start, total);
        var lo = first;
        var hi = end;
        var best: ?Probe = null;
        while (lo < hi and hi - lo > max_page_size) {
            const mid = lo + (hi - lo) / 2;
            const found = try self.probe(mid, hi, link.serial);
            const f = found orelse {
                hi = mid;
                continue;
            };
            if (f.granule > target) {
                hi = mid;
                continue;
            }
            if (best) |b| if (f.granule < b.granule) return error.BadData;
            best = f;
            lo = f.offset + f.size;
        }
        try self.resetAt(lo);
        while (try self.nextPage()) |h| {
            self.stats.seek_probes += 1;
            if (h.offset >= end) break;
            if (h.serial == link.serial and h.granule >= 0) {
                if (h.granule > target) break;
                if (best) |b| if (h.granule < b.granule) return error.BadData;
                best = .{ .offset = h.offset, .size = h.size, .granule = h.granule };
            }
            self.start += h.size;
        }
        const at = if (best) |b| b.offset else first;
        try self.resetAt(at);
        self.serial = link.serial;
        self.link = link;
        self.link_data = at != link.start;
        const b = best orelse return null;
        self.silent_next = true;
        return b.granule;
    }

    /// The offset where the link that starts at `start` ends: the next link of `links`,
    /// else the end of the input.
    fn linkEnd(self: *const PacketReader, start: u64, total: u64) u64 {
        const items = self.links.items;
        const i = self.linkAfter(start);
        return if (i < items.len) items[i].start else total;
    }

    /// The index of the first link that starts after `start`.
    fn linkAfter(self: *const PacketReader, start: u64) usize {
        const items = self.links.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].start <= start) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn tableIndex(self: *const PacketReader, start: u64) ?usize {
        const i = self.linkAfter(start);
        if (i > 0 and self.links.items[i - 1].start == start) return i - 1;
        return null;
    }

    /// Records that the audio of the current link starts at the page where `first` begins.
    /// Seeks restart there, so the header packets are not read again. `first` is the first
    /// audio packet that `next` returned.
    pub fn markAudio(self: *PacketReader, first: Packet) void {
        const link = &(self.link orelse return);
        link.audio = first.offset;
        link.first_granule = first.granule_before;
        if (self.tableIndex(link.start)) |i| {
            self.links.items[i].audio = link.audio;
            self.links.items[i].first_granule = link.first_granule;
        }
    }

    /// Walks the whole input once and fills `links` with every link that the `Select` rule
    /// follows. It reads the page headers only and jumps over the bodies, except for a begin
    /// page, which it reads whole and checks. The cost is bounded by the size of the input.
    /// The position of the reader does not change. A damaged page makes the walk look for
    /// the next capture pattern. At most `max_links` links are kept, and `links_complete`
    /// tells whether the table holds every link.
    /// The walk reads one page header per page, so on a source where each read is a request the
    /// cost grows with the page count.
    pub fn scanLinks(self: *PacketReader) ScanError!void {
        if (!self.input.seekable()) return error.Unseekable;
        const total = self.input.length() orelse return error.Unseekable;
        const saved = self.input.position();
        self.links.clearRetainingCapacity();
        self.links_complete = false;
        try self.scanPages(total);
        self.input.seekTo(saved) catch return error.ReadFailed;
        if (self.link) |*l| {
            if (self.tableIndex(l.start)) |i| {
                const entry = &self.links.items[i];
                entry.audio = l.audio;
                entry.first_granule = l.first_granule;
                l.last_granule = entry.last_granule;
            }
        }
    }

    fn scanPages(self: *PacketReader, total: u64) ScanError!void {
        var pos: u64 = 0;
        var cur: ?usize = null;
        var ended = false;
        var link_data = false;
        var head: [header_size + max_segments]u8 = undefined;
        while (total - pos >= header_size) {
            if (!try self.readAt(pos, head[0..header_size])) break;
            if (!std.mem.eql(u8, head[0..4], "OggS") or head[4] != 0) {
                pos = try self.findCapture(pos + 1, total) orelse break;
                continue;
            }
            const nseg: usize = head[26];
            if (!try self.readHere(head[header_size..][0..nseg])) break;
            var body_len: u64 = 0;
            for (head[header_size..][0..nseg]) |v| body_len += v;
            const size = header_size + nseg + body_len;
            if (total - pos < size) break;
            const flags: Flags = @bitCast(head[5]);
            const granule = std.mem.readInt(i64, head[6..14], .little);
            const serial = std.mem.readInt(u32, head[14..18], .little);
            const items = self.links.items;
            if (cur != null and !ended and serial == items[cur.?].serial) {
                if (!flags.bos) link_data = true;
                if (granule >= 0) items[cur.?].last_granule = granule;
                if (flags.eos) ended = true;
            } else if (flags.bos and (cur == null or self.select != .serial) and (cur == null or ended or link_data)) {
                if (try self.scanBegin(pos, size)) |link| {
                    if (items.len >= max_links) {
                        self.links_complete = false;
                        return;
                    }
                    try self.links.append(self.gpa, link);
                    cur = self.links.items.len - 1;
                    ended = false;
                    link_data = false;
                }
            }
            pos += size;
        }
        self.links_complete = true;
    }

    /// Reads the begin page at `pos` and returns its link when the `Select` rule accepts it.
    fn scanBegin(self: *PacketReader, pos: u64, size: u64) ScanError!?Link {
        const bytes = try self.gpa.alloc(u8, @intCast(size));
        defer self.gpa.free(bytes);
        if (!try self.readAt(pos, bytes)) return null;
        const page = parsePage(bytes) catch return null;
        const first = firstPacket(page.lacing, page.body, page.flags);
        if (!self.accepts(page.serial, first)) return null;
        var link: Link = .{ .serial = page.serial, .start = pos };
        const head = first orelse page.body;
        link.head_len = @intCast(@min(head.len, head_size));
        @memcpy(link.head[0..link.head_len], head[0..link.head_len]);
        return link;
    }

    /// Seeks to `pos` and fills `buf`. False when the input ends first.
    fn readAt(self: *PacketReader, pos: u64, buf: []u8) error{ReadFailed}!bool {
        self.input.seekTo(pos) catch |err| switch (err) {
            error.Truncated => return false,
            error.Unseekable, error.ReadFailed => return error.ReadFailed,
        };
        return self.readHere(buf);
    }

    fn readHere(self: *PacketReader, buf: []u8) error{ReadFailed}!bool {
        self.input.readExact(buf) catch |err| switch (err) {
            error.Truncated => return false,
            error.ReadFailed => return error.ReadFailed,
        };
        return true;
    }

    /// The offset of the first capture pattern at or after `from`.
    fn findCapture(self: *PacketReader, from: u64, total: u64) error{ReadFailed}!?u64 {
        var buf: [4096]u8 = undefined;
        var pos = from;
        while (total - @min(pos, total) >= 4) {
            const n: usize = @intCast(@min(buf.len, total - pos));
            if (!try self.readAt(pos, buf[0..n])) return null;
            if (std.mem.indexOf(u8, buf[0..n], "OggS")) |i| return pos + i;
            pos += n - 3;
        }
        return null;
    }

    /// The granule of the last page of the current link that has one, or null when there is
    /// none. It reads backward from the end of the link and keeps the answer in the link.
    /// The position of the reader does not change. It allocates a scratch buffer.
    pub fn lastGranule(self: *PacketReader) (SeekError || error{OutOfMemory})!?i64 {
        const link = self.link orelse return error.BadData;
        if (link.last_granule) |g| return g;
        if (!self.input.seekable()) return error.Unseekable;
        const total = self.input.length() orelse return error.Unseekable;
        const saved = self.input.position();
        const found = try self.lastGranuleBefore(link, self.linkEnd(link.start, total));
        self.input.seekTo(saved) catch return error.ReadFailed;
        if (found) |g| {
            self.link.?.last_granule = g;
            if (self.tableIndex(link.start)) |i| self.links.items[i].last_granule = g;
        }
        return found;
    }

    fn lastGranuleBefore(self: *PacketReader, link: Link, link_end: u64) (SeekError || error{OutOfMemory})!?i64 {
        const buf = try self.gpa.alloc(u8, 2 * max_page_size);
        defer self.gpa.free(buf);
        var end = link_end;
        while (end > link.start) {
            const begin = if (end - link.start > buf.len) end - buf.len else link.start;
            const n: usize = @intCast(end - begin);
            if (!try self.readAt(begin, buf[0..n])) return error.Truncated;
            var limit = n;
            while (std.mem.lastIndexOf(u8, buf[0..limit], "OggS")) |i| {
                // A false sync or a cut page is skipped.
                if (parsePage(buf[i..n]) catch null) |page| {
                    if (page.serial == link.serial and page.granule >= 0) return page.granule;
                }
                limit = i + 3;
            }
            if (begin == link.start) break;
            end = begin + max_page_size;
        }
        return null;
    }

    const Probe = struct { offset: u64, size: usize, granule: i64 };

    fn probe(self: *PacketReader, from: u64, limit: u64, serial: u32) SeekError!?Probe {
        try self.resetAt(from);
        while (try self.nextPage()) |h| {
            self.stats.seek_probes += 1;
            if (h.offset >= limit) return null;
            if (h.serial == serial and h.granule >= 0) {
                return .{ .offset = h.offset, .size = h.size, .granule = h.granule };
            }
            self.start += h.size;
        }
        return null;
    }

    fn resetAt(self: *PacketReader, offset: u64) SeekError!void {
        try self.input.seekTo(offset);
        self.start = 0;
        self.len = 0;
        self.eof = false;
        self.page = null;
        self.pending.clearRetainingCapacity();
        self.pending_active = false;
        self.pending_returned = false;
        self.expected_sequence = null;
        self.gap_pending = false;
        self.silent_next = false;
        self.ended = false;
    }

    /// Makes `want` bytes available at `win[start..]`. It reads only the missing bytes, so a live
    /// reader does not wait for a whole window. The window moves only when the bytes do not fit.
    fn fill(self: *PacketReader, want: usize) error{ReadFailed}!void {
        if (self.len - self.start >= want) return;
        if (self.start + want > self.win.len) {
            std.mem.copyForwards(u8, self.win[0 .. self.len - self.start], self.win[self.start..self.len]);
            self.len -= self.start;
            self.start = 0;
        }
        while (self.len - self.start < want and !self.eof) {
            const n = try self.input.readUpTo(self.win[self.len .. self.start + want]);
            if (n == 0) self.eof = true;
            self.len += n;
        }
    }

    fn skip(self: *PacketReader, n: usize) void {
        self.start += n;
        self.stats.skipped_bytes += n;
    }

    /// Leaves a checked page at `win[start..]`. Returns null at the end of the input.
    fn nextPage(self: *PacketReader) error{ReadFailed}!?PageHead {
        while (true) {
            try self.fill(header_size);
            const avail = self.len - self.start;
            if (avail < header_size) {
                self.skip(avail);
                return null;
            }
            const w = self.win[self.start..self.len];
            if (!std.mem.startsWith(u8, w, "OggS")) {
                const at = std.mem.indexOfPos(u8, w, 1, "OggS") orelse avail - 3;
                self.skip(at);
                continue;
            }
            if (w[4] != 0) {
                self.skip(1);
                continue;
            }
            const head_len = header_size + @as(usize, w[26]);
            try self.fill(head_len);
            if (self.len - self.start < head_len) {
                self.skip(1);
                continue;
            }
            var body_len: usize = 0;
            for (self.win[self.start + header_size ..][0 .. head_len - header_size]) |v| body_len += v;
            const total = head_len + body_len;
            try self.fill(total);
            if (self.len - self.start < total) {
                self.skip(1);
                continue;
            }
            const page = parsePage(self.win[self.start..][0..total]) catch |err| {
                if (err == error.BadCrc) self.stats.bad_crc += 1;
                self.skip(1);
                continue;
            };
            return .{
                .flags = page.flags,
                .granule = page.granule,
                .serial = page.serial,
                .sequence = page.sequence,
                .nseg = page.lacing.len,
                .size = total,
                .offset = self.input.position() - (self.len - self.start),
            };
        }
    }

    fn accepts(self: *const PacketReader, serial: u32, first: ?[]const u8) bool {
        return switch (self.select) {
            .serial => |s| serial == s,
            .any => true,
            .accept => |a| if (first) |f| a.func(a.context, f) else false,
        };
    }

    fn pageFirstPacket(self: *const PacketReader, head: PageHead) ?[]const u8 {
        const base = self.win[self.start..][0..head.size];
        const lacing = base[header_size..][0..head.nseg];
        return firstPacket(lacing, base[header_size + head.nseg ..], head.flags);
    }

    /// Makes the table entry for the link that begins on `head`.
    fn beginLink(self: *PacketReader, head: PageHead) void {
        var link: Link = .{ .serial = head.serial, .start = head.offset };
        if (self.tableIndex(head.offset)) |i| {
            link = self.links.items[i];
        } else {
            const base = self.win[self.start..][0..head.size];
            const body = base[header_size + head.nseg ..];
            const first = self.pageFirstPacket(head) orelse body;
            link.head_len = @intCast(@min(first.len, head_size));
            @memcpy(link.head[0..link.head_len], first[0..link.head_len]);
        }
        self.link = link;
        if (self.max_link_start == null or head.offset > self.max_link_start.?) {
            self.max_link_start = head.offset;
            self.stats.links += 1;
        }
    }

    fn dropPage(self: *PacketReader) void {
        const p = self.page orelse return;
        self.start += p.size;
        self.page = null;
        if (p.flags.eos) {
            self.ended = true;
            self.pending_active = false;
            if (!self.pending_returned) self.pending.clearRetainingCapacity();
        }
    }

    fn openPage(self: *PacketReader, head: PageHead) error{OutOfMemory}!void {
        const followed = self.serial != null and !self.ended and head.serial == self.serial.?;
        if (!followed) {
            const new_link = self.select != .serial and self.link_data and head.flags.bos;
            if (self.serial == null or self.ended or new_link) {
                if (head.flags.bos and self.accepts(head.serial, self.pageFirstPacket(head))) {
                    self.serial = head.serial;
                    self.ended = false;
                    self.seen_granule = 0;
                    self.expected_sequence = null;
                    self.pending_active = false;
                    self.pending.clearRetainingCapacity();
                    self.link_data = false;
                    self.beginLink(head);
                    self.beginPage(head);
                    return;
                }
            }
            if (self.begin_group_only and self.serial == null and !head.flags.bos) self.stopped = true;
            if (head.flags.bos) self.stats.skipped_streams += 1;
            self.stats.skipped_pages += 1;
            self.start += head.size;
            return;
        }
        if (!head.flags.bos) self.link_data = true;
        if (self.expected_sequence) |e| {
            if (e != head.sequence) {
                self.stats.lost_pages += head.sequence -% e;
                self.gap_pending = true;
                self.pending_active = false;
                self.pending.clearRetainingCapacity();
            }
        }
        self.beginPage(head);
    }

    fn beginPage(self: *PacketReader, head: PageHead) void {
        self.expected_sequence = head.sequence +% 1;
        self.before_granule = self.seen_granule;
        if (head.granule >= 0) self.seen_granule = head.granule;
        const base = self.win[self.start..][0..head.size];
        const lacing = base[header_size..][0..head.nseg];
        var seg: usize = 0;
        var off: usize = header_size + head.nseg;
        if (head.flags.continued and !self.pending_active) {
            while (seg < head.nseg) {
                const v = lacing[seg];
                off += v;
                seg += 1;
                if (v < 255) break;
            }
        } else if (!head.flags.continued and self.pending_active) {
            self.pending_active = false;
            self.pending.clearRetainingCapacity();
        }
        var last: ?usize = null;
        var i = head.nseg;
        while (i > seg) {
            i -= 1;
            if (lacing[i] < 255) {
                last = i;
                break;
            }
        }
        self.page = .{
            .offset = head.offset,
            .before = self.before_granule,
            .size = head.size,
            .nseg = head.nseg,
            .seg = seg,
            .body_off = off,
            .flags = head.flags,
            .granule = head.granule,
            .serial = head.serial,
            .sequence = head.sequence,
            .last_complete = last,
            .silent = self.silent_next,
            .bos_pending = head.flags.bos,
        };
        self.silent_next = false;
    }

    fn appendPending(self: *PacketReader, data: []const u8) Error!void {
        if (self.pending.items.len + data.len > self.max_packet) {
            self.pending.clearRetainingCapacity();
            self.pending_active = false;
            return error.BadData;
        }
        try self.pending.appendSlice(self.gpa, data);
    }

    fn packetFromPage(self: *PacketReader, p: *PageState) Error!?Packet {
        const base = self.win[self.start..][0..p.size];
        const lacing = base[header_size..][0..p.nseg];
        while (p.seg < p.nseg) {
            var run: usize = 0;
            var i = p.seg;
            var done = false;
            while (i < p.nseg) {
                const v = lacing[i];
                run += v;
                i += 1;
                if (v < 255) {
                    done = true;
                    break;
                }
            }
            const data = base[p.body_off..][0..run];
            const idx = i - 1;
            p.seg = i;
            p.body_off += run;
            if (!done) {
                if (!self.pending_active) {
                    self.pending_offset = p.offset;
                    self.pending_before = p.before;
                }
                try self.appendPending(data);
                self.pending_active = true;
                return null;
            }
            if (!self.pending_active and data.len > self.max_packet) return error.BadData;
            var bytes = data;
            var offset = p.offset;
            var before = p.before;
            if (self.pending_active) {
                offset = self.pending_offset;
                before = self.pending_before;
                try self.appendPending(data);
                self.pending_active = false;
                bytes = self.pending.items;
            }
            if (p.silent) {
                self.pending.clearRetainingCapacity();
                continue;
            }
            if (bytes.ptr == self.pending.items.ptr) self.pending_returned = true;
            const last = p.last_complete != null and p.last_complete.? == idx;
            const bos = p.bos_pending;
            const after_gap = self.gap_pending;
            self.gap_pending = false;
            p.bos_pending = false;
            return .{
                .data = bytes,
                .granule = if (last) p.granule else -1,
                .serial = p.serial,
                .sequence = p.sequence,
                .bos = bos,
                .eos = last and p.flags.eos,
                .offset = offset,
                .granule_before = before,
                .after_gap = after_gap,
            };
        }
        return null;
    }
};

/// Builds pages from packets and writes them to a Writer.
pub const PacketWriter = struct {
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    serial: u32,
    target: usize,
    body: []u8,
    body_len: usize = 0,
    lacing: [max_segments]u8 = undefined,
    nseg: usize = 0,
    sequence: u32 = 0,
    page_granule: i64 = -1,
    last_granule: i64 = 0,
    continued: bool = false,
    open: bool = false,
    flush_on_granule: bool,

    pub const Options = struct {
        /// Close the page after each packet that has a granule other than -1.
        flush_on_granule: bool = false,
        /// A page is closed before the next packet once its body holds this many bytes.
        target_page_size: usize = 4096,
    };

    pub const WriteError = error{WriteFailed};

    pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, serial: u32, options: Options) error{OutOfMemory}!PacketWriter {
        return .{
            .gpa = gpa,
            .writer = writer,
            .serial = serial,
            .target = options.target_page_size,
            .flush_on_granule = options.flush_on_granule,
            .body = try gpa.alloc(u8, max_body),
        };
    }

    pub fn deinit(self: *PacketWriter) void {
        self.gpa.free(self.body);
        self.* = undefined;
    }

    /// Adds a packet. `granule` goes to the page that ends the packet, or -1 for none.
    /// A packet that does not fit in 255 segments continues on the next page.
    pub fn writePacket(self: *PacketWriter, data: []const u8, granule: i64) WriteError!void {
        if (self.body_len >= self.target) try self.emit(false);
        var rest = data;
        while (true) {
            if (self.nseg == max_segments) try self.emit(false);
            const space = max_segments - self.nseg;
            const need = rest.len / 255 + 1;
            if (need <= space) {
                @memcpy(self.body[self.body_len..][0..rest.len], rest);
                self.body_len += rest.len;
                @memset(self.lacing[self.nseg..][0 .. need - 1], 255);
                self.lacing[self.nseg + need - 1] = @intCast(rest.len % 255);
                self.nseg += need;
                if (granule != -1) {
                    self.page_granule = granule;
                    self.last_granule = granule;
                }
                self.open = false;
                if (self.flush_on_granule and granule != -1) try self.emit(false);
                return;
            }
            const take = space * 255;
            @memcpy(self.body[self.body_len..][0..take], rest[0..take]);
            self.body_len += take;
            @memset(self.lacing[self.nseg..][0..space], 255);
            self.nseg = max_segments;
            rest = rest[take..];
            self.open = true;
        }
    }

    /// Closes the current page if it holds any segment.
    pub fn flush(self: *PacketWriter) WriteError!void {
        if (self.nseg > 0) try self.emit(false);
    }

    /// Writes the last page with the end flag. Nothing may be written after it.
    pub fn finish(self: *PacketWriter) WriteError!void {
        if (self.nseg == 0) self.page_granule = self.last_granule;
        try self.emit(true);
    }

    fn emit(self: *PacketWriter, eos: bool) WriteError!void {
        const h: Header = .{
            .flags = .{ .continued = self.continued, .bos = self.sequence == 0, .eos = eos },
            .granule = self.page_granule,
            .serial = self.serial,
            .sequence = self.sequence,
        };
        var head: [header_size + max_segments]u8 = undefined;
        const body = self.body[0..self.body_len];
        const n = writeHeader(&head, h, self.lacing[0..self.nseg], body);
        try self.writer.writeAll(head[0..n]);
        try self.writer.writeAll(body);
        self.sequence +%= 1;
        self.continued = self.open;
        self.nseg = 0;
        self.body_len = 0;
        self.page_granule = -1;
    }
};

fn isFlac(context: ?*anyopaque, packet: []const u8) bool {
    _ = context;
    return packet.len > 0 and packet[0] == 'F';
}

const accept_f: Select = .{ .accept = .{ .func = isFlac } };

/// The first packet of a page, when the page holds all of it.
fn firstPacket(lacing: []const u8, body: []const u8, flags: Flags) ?[]const u8 {
    if (flags.continued) return null;
    var n: usize = 0;
    for (lacing) |v| {
        n += v;
        if (v < 255) return body[0..n];
    }
    return null;
}

const Owned = struct {
    data: []u8,
    granule: i64,
    serial: u32,
    bos: bool,
    eos: bool,
};

fn freeAll(list: *std.ArrayList(Owned)) void {
    for (list.items) |o| testing.allocator.free(o.data);
    list.deinit(testing.allocator);
}

fn drain(reader: *PacketReader, list: *std.ArrayList(Owned)) !void {
    while (try reader.next()) |p| {
        const copy = try testing.allocator.dupe(u8, p.data);
        errdefer testing.allocator.free(copy);
        try list.append(testing.allocator, .{ .data = copy, .granule = p.granule, .serial = p.serial, .bos = p.bos, .eos = p.eos });
    }
}

fn pattern(buf: []u8, seed: usize) void {
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 7 +% seed *% 13);
}

test "build then parse a page" {
    var out: [300]u8 = undefined;
    const lacing = [_]u8{ 3, 255, 0, 2 };
    var body: [260]u8 = undefined;
    for (&body, 0..) |*b, i| b.* = @truncate(i);
    const n = try buildPage(&out, .{
        .flags = .{ .bos = true, .eos = true },
        .granule = -2,
        .serial = 0xdeadbeef,
        .sequence = 9,
    }, &lacing, &body);
    try testing.expectEqual(@as(usize, 27 + 4 + 260), n);
    const page = try parsePage(out[0..n]);
    try testing.expect(page.flags.bos and page.flags.eos and !page.flags.continued);
    try testing.expectEqual(@as(i64, -2), page.granule);
    try testing.expectEqual(@as(u32, 0xdeadbeef), page.serial);
    try testing.expectEqual(@as(u32, 9), page.sequence);
    try testing.expectEqualSlices(u8, &lacing, page.lacing);
    try testing.expectEqualSlices(u8, &body, page.body);
    try testing.expectEqual(n, page.size());
    try testing.expectError(error.Truncated, parsePage(out[0 .. n - 1]));
    try testing.expectError(error.Truncated, parsePage(out[0..10]));
    try testing.expectError(error.NotPage, parsePage("Ogg"[0..2] ++ "x"));
    out[40] ^= 1;
    try testing.expectError(error.BadCrc, parsePage(out[0..n]));
    var small: [10]u8 = undefined;
    try testing.expectError(error.NoSpace, buildPage(&small, .{ .granule = 0, .serial = 0, .sequence = 0 }, &lacing, &body));
    try testing.expectError(error.BadLacing, buildPage(&out, .{ .granule = 0, .serial = 0, .sequence = 0 }, &lacing, body[0..5]));
}

test "packets of many sizes round trip" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = try PacketWriter.init(testing.allocator, &aw.writer, 77, .{});
    defer w.deinit();
    const sizes = [_]usize{ 0, 255, 256, 70000, 510, 1, 254 };
    var big: [70000]u8 = undefined;
    for (sizes, 0..) |n, i| {
        pattern(big[0..n], i);
        try w.writePacket(big[0..n], @intCast(i + 1));
        if (i == 0) try w.flush();
    }
    for (0..300) |i| {
        const b = [_]u8{@truncate(i)};
        try w.writePacket(&b, @intCast(100 + i));
    }
    try w.finish();

    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, .any, .{});
    defer r.deinit();
    var list: std.ArrayList(Owned) = .empty;
    defer freeAll(&list);
    try drain(&r, &list);
    try testing.expectEqual(sizes.len + 300, list.items.len);
    for (sizes, 0..) |n, i| {
        pattern(big[0..n], i);
        try testing.expectEqualSlices(u8, big[0..n], list.items[i].data);
    }
    for (0..300) |i| {
        try testing.expectEqualSlices(u8, &.{@as(u8, @truncate(i))}, list.items[sizes.len + i].data);
    }
    try testing.expect(list.items[0].bos);
    try testing.expect(!list.items[1].bos);
    try testing.expect(list.items[list.items.len - 1].eos);
    try testing.expectEqual(@as(i64, 399), list.items[list.items.len - 1].granule);
    try testing.expectEqual(@as(i64, 1), list.items[0].granule);
    for (list.items[0 .. list.items.len - 1]) |o| try testing.expect(!o.eos);
    for (list.items) |o| try testing.expectEqual(@as(u32, 77), o.serial);
    try testing.expectEqual(Stats{ .links = 1 }, r.stats);
}

test "an empty stream is one end page" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = try PacketWriter.init(testing.allocator, &aw.writer, 1, .{});
    defer w.deinit();
    try w.finish();
    const page = try parsePage(aw.written());
    try testing.expect(page.flags.bos and page.flags.eos);
    try testing.expectEqual(@as(usize, 0), page.lacing.len);
}

test "a flipped byte is skipped and the reader resyncs" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = try PacketWriter.init(testing.allocator, &aw.writer, 5, .{});
    defer w.deinit();
    const texts = [_][]const u8{ "first", "second packet", "third", "fourth" };
    for (texts, 0..) |t, i| {
        try w.writePacket(t, @intCast(i));
        if (i < 3) try w.flush();
    }
    try w.finish();
    const clean = aw.written();
    const second = 27 + 1 + "first".len;
    const bad = try testing.allocator.alloc(u8, clean.len + 6);
    defer testing.allocator.free(bad);
    @memcpy(bad[0..6], "junk!!");
    @memcpy(bad[6..], clean);
    bad[6 + second + 27 + 1 + 3] ^= 0x10;

    var in: Input = .init(.{ .bytes = bad });
    var r = try PacketReader.init(testing.allocator, &in, .any, .{});
    defer r.deinit();
    var list: std.ArrayList(Owned) = .empty;
    defer freeAll(&list);
    try drain(&r, &list);
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqualStrings("first", list.items[0].data);
    try testing.expectEqualStrings("third", list.items[1].data);
    try testing.expectEqualStrings("fourth", list.items[2].data);
    try testing.expectEqual(@as(u64, 1), r.stats.bad_crc);
    try testing.expectEqual(@as(u64, 1), r.stats.lost_pages);
    try testing.expectEqual(@as(u64, 6 + (27 + 1 + "second packet".len)), r.stats.skipped_bytes);
}

test "a stream cut in a packet gives Truncated once" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = try PacketWriter.init(testing.allocator, &aw.writer, 5, .{ .target_page_size = 1 << 20 });
    defer w.deinit();
    var big: [70000]u8 = undefined;
    pattern(&big, 1);
    try w.writePacket("head", 0);
    try w.flush();
    try w.writePacket(&big, 1);
    try w.finish();
    const bytes = aw.written();
    // Page 0 holds "head". Page 1 is full and continues on page 2.
    const cut = bytes[0 .. 27 + 1 + 4 + 27 + 255 + 255 * 255];
    var in: Input = .init(.{ .bytes = cut });
    var r = try PacketReader.init(testing.allocator, &in, .any, .{});
    defer r.deinit();
    try testing.expectEqualStrings("head", (try r.next()).?.data);
    try testing.expectError(error.Truncated, r.next());
    try testing.expectEqual(@as(?Packet, null), try r.next());
}

test "packets over the limit give BadData" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = try PacketWriter.init(testing.allocator, &aw.writer, 5, .{});
    defer w.deinit();
    var big: [70000]u8 = undefined;
    pattern(&big, 1);
    try w.writePacket(&big, 1);
    try w.finish();
    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, .any, .{ .max_packet_size = 1000 });
    defer r.deinit();
    try testing.expectError(error.BadData, r.next());
}

fn muxTwo(aw: *std.Io.Writer.Allocating) !void {
    var a = try PacketWriter.init(testing.allocator, &aw.writer, 1, .{});
    defer a.deinit();
    var b = try PacketWriter.init(testing.allocator, &aw.writer, 2, .{});
    defer b.deinit();
    try a.writePacket("Vhead", 0);
    try a.flush();
    try b.writePacket("Fhead", 0);
    try b.flush();
    try a.writePacket("v1", 10);
    try a.flush();
    try b.writePacket("f1", 20);
    try b.flush();
    try a.writePacket("v2", 30);
    try a.finish();
    try b.writePacket("f2", 40);
    try b.finish();
}

test "multiplexed streams pick one by predicate or serial" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try muxTwo(&aw);

    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, accept_f, .{});
    defer r.deinit();
    var list: std.ArrayList(Owned) = .empty;
    defer freeAll(&list);
    try drain(&r, &list);
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqualStrings("Fhead", list.items[0].data);
    try testing.expectEqualStrings("f1", list.items[1].data);
    try testing.expectEqualStrings("f2", list.items[2].data);
    for (list.items) |o| try testing.expectEqual(@as(u32, 2), o.serial);
    try testing.expectEqual(@as(i64, 40), list.items[2].granule);
    try testing.expectEqual(@as(u64, 1), r.stats.skipped_streams);
    try testing.expectEqual(@as(u64, 3), r.stats.skipped_pages);

    var in2: Input = .init(.{ .bytes = aw.written() });
    var r2 = try PacketReader.init(testing.allocator, &in2, .{ .serial = 1 }, .{});
    defer r2.deinit();
    var list2: std.ArrayList(Owned) = .empty;
    defer freeAll(&list2);
    try drain(&r2, &list2);
    try testing.expectEqual(@as(usize, 3), list2.items.len);
    try testing.expectEqualStrings("Vhead", list2.items[0].data);
    try testing.expectEqualStrings("v2", list2.items[2].data);
    try testing.expectEqual(@as(u64, 1), r2.stats.skipped_streams);

    var in3: Input = .init(.{ .bytes = aw.written() });
    var r3 = try PacketReader.init(testing.allocator, &in3, .{ .serial = 9 }, .{});
    defer r3.deinit();
    try testing.expectEqual(@as(?Packet, null), try r3.next());
    try testing.expectEqual(@as(u64, 2), r3.stats.skipped_streams);
}

test "chained streams follow each link" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    {
        var a = try PacketWriter.init(testing.allocator, &aw.writer, 11, .{});
        defer a.deinit();
        try a.writePacket("Fone", 0);
        try a.flush();
        try a.writePacket("a1", 5);
        try a.finish();
        var b = try PacketWriter.init(testing.allocator, &aw.writer, 12, .{});
        defer b.deinit();
        try b.writePacket("Ftwo", 0);
        try b.flush();
        try b.writePacket("b1", 7);
        try b.writePacket("b2", 9);
        try b.finish();
    }
    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, accept_f, .{});
    defer r.deinit();
    var list: std.ArrayList(Owned) = .empty;
    defer freeAll(&list);
    try drain(&r, &list);
    try testing.expectEqual(@as(usize, 5), list.items.len);
    const want = [_][]const u8{ "Fone", "a1", "Ftwo", "b1", "b2" };
    const serials = [_]u32{ 11, 11, 12, 12, 12 };
    const bos = [_]bool{ true, false, true, false, false };
    const eos = [_]bool{ false, true, false, false, true };
    for (list.items, 0..) |o, i| {
        try testing.expectEqualStrings(want[i], o.data);
        try testing.expectEqual(serials[i], o.serial);
        try testing.expectEqual(bos[i], o.bos);
        try testing.expectEqual(eos[i], o.eos);
    }
    try testing.expectEqual(@as(i64, -1), list.items[3].granule);
    try testing.expectEqual(@as(i64, 9), list.items[4].granule);
    try testing.expectEqual(@as(u64, 2), r.stats.links);

    var in2: Input = .init(.{ .bytes = aw.written() });
    var r2 = try PacketReader.init(testing.allocator, &in2, .{ .serial = 11 }, .{});
    defer r2.deinit();
    var list2: std.ArrayList(Owned) = .empty;
    defer freeAll(&list2);
    try drain(&r2, &list2);
    try testing.expectEqual(@as(usize, 2), list2.items.len);
}

fn thousandPages(aw: *std.Io.Writer.Allocating) !void {
    var w = try PacketWriter.init(testing.allocator, &aw.writer, 3, .{});
    defer w.deinit();
    var buf: [4000]u8 = undefined;
    try w.writePacket("head", 0);
    try w.flush();
    for (0..1000) |i| {
        pattern(&buf, i);
        try w.writePacket(&buf, @intCast((i + 1) * 1000));
        if (i < 999) try w.flush();
    }
    try w.finish();
}

fn expectNextIs(r: *PacketReader, index: usize) !void {
    var buf: [4000]u8 = undefined;
    pattern(&buf, index);
    const p = (try r.next()).?;
    try testing.expectEqualSlices(u8, &buf, p.data);
    try testing.expectEqual(@as(i64, @intCast((index + 1) * 1000)), p.granule);
}

test "seek bisects a thousand pages" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try thousandPages(&aw);
    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, .any, .{});
    defer r.deinit();
    try testing.expectError(error.BadData, r.seekGranule(5));
    try testing.expectEqualStrings("head", (try r.next()).?.data);

    try testing.expectEqual(@as(?i64, 500000), try r.seekGranule(500500));
    try expectNextIs(&r, 500);
    try expectNextIs(&r, 501);
    try testing.expect(r.stats.seek_probes < 60);

    try testing.expectEqual(@as(?i64, 1000), try r.seekGranule(1000));
    try expectNextIs(&r, 1);
    try testing.expectEqual(@as(?i64, 0), try r.seekGranule(999));
    try expectNextIs(&r, 0);
    try testing.expectEqual(@as(?i64, 998000), try r.seekGranule(998999));
    try expectNextIs(&r, 998);
    try expectNextIs(&r, 999);
    try testing.expectEqual(@as(?Packet, null), try r.next());
    try testing.expectEqual(@as(?i64, 1000000), try r.seekGranule(std.math.maxInt(i64)));
    try testing.expectEqual(@as(?Packet, null), try r.next());

    try testing.expectEqual(@as(?i64, null), try r.seekGranule(-5));
    const first = (try r.next()).?;
    try testing.expectEqualStrings("head", first.data);
    try testing.expect(first.bos);
}

test "seek keeps a packet that crosses a page" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = try PacketWriter.init(testing.allocator, &aw.writer, 3, .{ .target_page_size = 1 << 20 });
    defer w.deinit();
    var buf: [40000]u8 = undefined;
    try w.writePacket("head", 0);
    try w.flush();
    for (0..20) |i| {
        pattern(&buf, i);
        try w.writePacket(&buf, @intCast((i + 1) * 100));
    }
    try w.finish();
    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, .any, .{});
    defer r.deinit();
    _ = try r.next();
    for (0..20) |k| {
        const g: i64 = @intCast((k + 1) * 100 + 50);
        const got = (try r.seekGranule(g)).?;
        var want: i64 = 0;
        for (0..20) |i| {
            const ends_page = i == 19 or (157 * i + 156) / 255 != (157 * (i + 1) + 156) / 255;
            const pg: i64 = @intCast((i + 1) * 100);
            if (ends_page and pg <= g) want = pg;
        }
        try testing.expectEqual(want, got);
        const p = (try r.next()) orelse {
            try testing.expectEqual(@as(i64, 2000), got);
            continue;
        };
        pattern(&buf, @intCast(@divExact(got, 100)));
        try testing.expectEqualSlices(u8, &buf, p.data);
    }
}

test "seek on a forward only reader is Unseekable" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try muxTwo(&aw);
    var fr: std.Io.Reader = .fixed(aw.written());
    var in: Input = .init(.{ .reader = &fr });
    var r = try PacketReader.init(testing.allocator, &in, .any, .{});
    defer r.deinit();
    _ = try r.next();
    try testing.expectError(error.Unseekable, r.seekGranule(5));
}

test "seek works on a file" {
    if (!io.has_files) return error.SkipZigTest;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try thousandPages(&aw);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.ogg", .data = aw.written() });
    var file = try tmp.dir.openFile(testing.io, "f.ogg", .{});
    defer file.close(testing.io);
    var fbuf: [512]u8 = undefined;
    var fr = file.reader(testing.io, &fbuf);
    var in: Input = .init(.{ .file = &fr });
    var r = try PacketReader.init(testing.allocator, &in, .any, .{});
    defer r.deinit();
    try testing.expectEqualStrings("head", (try r.next()).?.data);
    try expectNextIs(&r, 0);
    try testing.expectEqual(@as(?i64, 700000), try r.seekGranule(700999));
    try expectNextIs(&r, 700);
    try testing.expectEqual(@as(?i64, 3000), try r.seekGranule(3000));
    try expectNextIs(&r, 3);
}

fn rawPage(aw: *std.Io.Writer.Allocating, h: Header, lacing: []const u8, body: []const u8) !void {
    var buf: [max_page_size]u8 = undefined;
    const n = try buildPage(&buf, h, lacing, body);
    try aw.writer.writeAll(buf[0..n]);
}

test "long packets span several pages" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = try PacketWriter.init(testing.allocator, &aw.writer, 4, .{});
    defer w.deinit();
    const big = try testing.allocator.alloc(u8, 200000);
    defer testing.allocator.free(big);
    pattern(big, 3);
    try w.writePacket(big, 1);
    try w.writePacket(big[0..65025], 2);
    try w.writePacket(big[0..130050], 3);
    try w.finish();

    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, .any, .{});
    defer r.deinit();
    try testing.expectEqualSlices(u8, big, (try r.next()).?.data);
    try testing.expectEqualSlices(u8, big[0..65025], (try r.next()).?.data);
    try testing.expectEqualSlices(u8, big[0..130050], (try r.next()).?.data);
    try testing.expectEqual(@as(?Packet, null), try r.next());
    try testing.expectEqual(Stats{ .links = 1 }, r.stats);
}

test "a packet of 65025 bytes ends with a zero lacing value" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = try PacketWriter.init(testing.allocator, &aw.writer, 4, .{});
    defer w.deinit();
    const big = try testing.allocator.alloc(u8, 65025);
    defer testing.allocator.free(big);
    pattern(big, 1);
    try w.writePacket(big, 9);
    try w.finish();
    const first = try parsePage(aw.written());
    try testing.expectEqual(@as(usize, 255), first.lacing.len);
    for (first.lacing) |v| try testing.expectEqual(@as(u8, 255), v);
    try testing.expectEqual(@as(i64, -1), first.granule);
    try testing.expect(first.flags.bos and !first.flags.continued and !first.flags.eos);
    const second = try parsePage(aw.written()[first.size()..]);
    try testing.expectEqualSlices(u8, &.{0}, second.lacing);
    try testing.expectEqual(@as(usize, 0), second.body.len);
    try testing.expectEqual(@as(i64, 9), second.granule);
    try testing.expect(second.flags.continued and second.flags.eos);
}

test "a continued page with no packet in progress drops its first packet" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try rawPage(&aw, .{ .flags = .{ .bos = true }, .granule = 0, .serial = 1, .sequence = 0 }, &.{3}, "abc");
    try rawPage(&aw, .{ .flags = .{ .continued = true }, .granule = 4, .serial = 1, .sequence = 1 }, &.{ 2, 3 }, "xxdef");
    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, .any, .{});
    defer r.deinit();
    try testing.expectEqualStrings("abc", (try r.next()).?.data);
    const p = (try r.next()).?;
    try testing.expectEqualStrings("def", p.data);
    try testing.expectEqual(@as(i64, 4), p.granule);
    try testing.expectEqual(@as(?Packet, null), try r.next());
    try testing.expectEqual(Stats{ .links = 1 }, r.stats);
}

test "a sequence gap with valid checksums drops the open packet" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var part: [255]u8 = undefined;
    pattern(&part, 2);
    try rawPage(&aw, .{ .flags = .{ .bos = true }, .granule = -1, .serial = 1, .sequence = 0 }, &.{255}, &part);
    try rawPage(&aw, .{ .flags = .{ .continued = true }, .granule = 8, .serial = 1, .sequence = 3 }, &.{ 2, 3 }, "xxdef");
    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, .any, .{});
    defer r.deinit();
    try testing.expectEqualStrings("def", (try r.next()).?.data);
    try testing.expectEqual(@as(?Packet, null), try r.next());
    try testing.expectEqual(@as(u64, 2), r.stats.lost_pages);
    try testing.expectEqual(@as(u64, 0), r.stats.bad_crc);
    try testing.expectEqual(@as(u64, 0), r.stats.skipped_bytes);
}

test "a header that claims more than the input holds is skipped" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var hostile: [27 + 255 + 10]u8 = @splat(0);
    @memcpy(hostile[0..4], "OggS");
    hostile[26] = 255;
    @memset(hostile[27..][0..255], 255);
    try aw.writer.writeAll(&hostile);
    try rawPage(&aw, .{ .flags = .{ .bos = true }, .granule = 0, .serial = 1, .sequence = 0 }, &.{2}, "ok");
    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, .any, .{});
    defer r.deinit();
    try testing.expectEqualStrings("ok", (try r.next()).?.data);
    try testing.expectEqual(@as(?Packet, null), try r.next());
    try testing.expectEqual(@as(u64, hostile.len), r.stats.skipped_bytes);
    try testing.expectEqual(@as(u64, 0), r.stats.bad_crc);
}

test "a flood of capture patterns ends with counted skips" {
    var flood: [20000]u8 = undefined;
    for (0..5000) |i| @memcpy(flood[i * 4 ..][0..4], "OggS");
    var in: Input = .init(.{ .bytes = &flood });
    var r = try PacketReader.init(testing.allocator, &in, .any, .{});
    defer r.deinit();
    try testing.expectEqual(@as(?Packet, null), try r.next());
    try testing.expectEqual(@as(u64, flood.len), r.stats.skipped_bytes);
    try testing.expectEqual(@as(u64, 0), r.stats.links);
}

test "a begin page after data starts a new link without an end page" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    {
        var a = try PacketWriter.init(testing.allocator, &aw.writer, 1, .{});
        defer a.deinit();
        try a.writePacket("Fone", 0);
        try a.flush();
        try a.writePacket("a1", 5);
        try a.flush();
        var b = try PacketWriter.init(testing.allocator, &aw.writer, 2, .{});
        defer b.deinit();
        try b.writePacket("Ftwo", 0);
        try b.flush();
        try b.writePacket("b1", 7);
        try b.finish();
    }
    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, accept_f, .{});
    defer r.deinit();
    var list: std.ArrayList(Owned) = .empty;
    defer freeAll(&list);
    try drain(&r, &list);
    try testing.expectEqual(@as(usize, 4), list.items.len);
    try testing.expectEqualStrings("Ftwo", list.items[2].data);
    try testing.expectEqual(@as(u32, 2), list.items[3].serial);
    try testing.expectEqual(@as(u64, 2), r.stats.links);

    var in2: Input = .init(.{ .bytes = aw.written() });
    var r2 = try PacketReader.init(testing.allocator, &in2, .{ .serial = 1 }, .{});
    defer r2.deinit();
    var list2: std.ArrayList(Owned) = .empty;
    defer freeAll(&list2);
    try drain(&r2, &list2);
    try testing.expectEqual(@as(usize, 2), list2.items.len);
    try testing.expectEqual(@as(u64, 1), r2.stats.links);
}

test "the packet limit applies to single page packets" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = try PacketWriter.init(testing.allocator, &aw.writer, 5, .{});
    defer w.deinit();
    var data: [2000]u8 = undefined;
    pattern(&data, 1);
    try w.writePacket(&data, 1);
    try w.finish();
    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, .any, .{ .max_packet_size = 1000 });
    defer r.deinit();
    try testing.expectError(error.BadData, r.next());
}

test "a granule of -1 keeps the page granule" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = try PacketWriter.init(testing.allocator, &aw.writer, 5, .{});
    defer w.deinit();
    try w.writePacket("a", 5);
    try w.writePacket("b", -1);
    try w.finish();
    const page = try parsePage(aw.written());
    try testing.expectEqual(@as(i64, 5), page.granule);
    try testing.expectEqual(@as(usize, 2), page.lacing.len);
}

test "flush on granule closes a page after each granule" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = try PacketWriter.init(testing.allocator, &aw.writer, 5, .{ .flush_on_granule = true });
    defer w.deinit();
    try w.writePacket("a", 1);
    try w.writePacket("b", -1);
    try w.writePacket("c", 3);
    try w.writePacket("d", -1);
    try w.finish();
    const bytes = aw.written();
    const p0 = try parsePage(bytes);
    const p1 = try parsePage(bytes[p0.size()..]);
    const p2 = try parsePage(bytes[p0.size() + p1.size() ..]);
    try testing.expectEqual(bytes.len, p0.size() + p1.size() + p2.size());
    try testing.expectEqual(@as(i64, 1), p0.granule);
    try testing.expectEqual(@as(usize, 1), p0.lacing.len);
    try testing.expectEqual(@as(i64, 3), p1.granule);
    try testing.expectEqual(@as(usize, 2), p1.lacing.len);
    try testing.expectEqual(@as(i64, -1), p2.granule);
    try testing.expect(p2.flags.eos);
}

fn linkPayload(buf: []u8, link: usize, i: usize) []u8 {
    pattern(buf[0..100], link * 100 + i);
    return buf[0..100];
}

/// Writes one link per entry of `counts`. Each link has a 300 byte first packet, then
/// one packet per page with the granules 10, 20 and so on.
fn writeChain(aw: *std.Io.Writer.Allocating, counts: []const usize) !void {
    for (counts, 0..) |count, k| {
        var w = try PacketWriter.init(testing.allocator, &aw.writer, @intCast(30 + k), .{});
        defer w.deinit();
        var head: [300]u8 = @splat('F');
        head[1] = @intCast('0' + k);
        try w.writePacket(&head, 0);
        try w.flush();
        var buf: [100]u8 = undefined;
        for (0..count) |i| {
            try w.writePacket(linkPayload(&buf, k, i), @intCast((i + 1) * 10));
            try w.flush();
        }
        try w.finish();
    }
}

test "the predicate sees a first packet of any length" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeChain(&aw, &.{2});
    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, accept_f, .{});
    defer r.deinit();
    const first = (try r.next()).?;
    try testing.expectEqual(@as(usize, 300), first.data.len);
    try testing.expect(first.bos);
    try testing.expectEqual(@as(u64, 1), r.stats.links);
    try testing.expectEqual(@as(u64, 0), r.stats.skipped_streams);
}

test "scanLinks fills the link table and keeps the position" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeChain(&aw, &.{ 5, 3, 4 });
    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, accept_f, .{});
    defer r.deinit();
    try testing.expectEqualStrings("F0", (try r.next()).?.data[0..2]);
    try r.scanLinks();
    try testing.expect(r.links_complete);
    try testing.expectEqual(@as(usize, 3), r.links.items.len);
    const counts = [_]i64{ 5, 3, 4 };
    var prev: u64 = 0;
    for (r.links.items, counts, 0..) |l, c, k| {
        try testing.expectEqual(@as(u32, @intCast(30 + k)), l.serial);
        try testing.expectEqual(@as(?i64, c * 10), l.last_granule);
        try testing.expectEqual(@as(usize, head_size), l.firstBytes().len);
        try testing.expectEqual(@as(u8, @intCast('0' + k)), l.firstBytes()[1]);
        try testing.expect(k == 0 or l.start > prev);
        prev = l.start;
    }
    try testing.expectEqual(@as(u64, 0), r.links.items[0].start);
    // The current link knows its last granule from the scan.
    try testing.expectEqual(@as(?i64, 50), r.link.?.last_granule);
    // The reader goes on with the next packet.
    var buf: [100]u8 = undefined;
    try testing.expectEqualSlices(u8, linkPayload(&buf, 0, 0), (try r.next()).?.data);
    try testing.expectEqual(@as(u64, 1), r.stats.links);
}

test "scanLinks follows the serial rule and needs a seekable input" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeChain(&aw, &.{ 2, 2 });
    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, .{ .serial = 31 }, .{});
    defer r.deinit();
    try r.scanLinks();
    try testing.expectEqual(@as(usize, 1), r.links.items.len);
    try testing.expectEqual(@as(u32, 31), r.links.items[0].serial);

    var fr: std.Io.Reader = .fixed(aw.written());
    var in2: Input = .init(.{ .reader = &fr });
    var r2 = try PacketReader.init(testing.allocator, &in2, .any, .{});
    defer r2.deinit();
    try testing.expectError(error.Unseekable, r2.scanLinks());
}

test "scanLinks skips damage and finds the later links" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeChain(&aw, &.{ 2, 2, 2 });
    const clean = aw.written();
    const bad = try testing.allocator.alloc(u8, clean.len + 5);
    defer testing.allocator.free(bad);
    @memcpy(bad[0..clean.len], clean);
    // Flip a byte in the begin page of the second link.
    var in0: Input = .init(.{ .bytes = clean });
    var r0 = try PacketReader.init(testing.allocator, &in0, accept_f, .{});
    defer r0.deinit();
    try r0.scanLinks();
    const second = r0.links.items[1].start;
    bad[@intCast(second + 40)] ^= 1;
    var in: Input = .init(.{ .bytes = bad[0..clean.len] });
    var r = try PacketReader.init(testing.allocator, &in, accept_f, .{});
    defer r.deinit();
    try r.scanLinks();
    try testing.expect(r.links_complete);
    try testing.expectEqual(@as(usize, 2), r.links.items.len);
    try testing.expectEqual(@as(u32, 32), r.links.items[1].serial);
}

test "seeks reach any known link" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeChain(&aw, &.{ 5, 3, 4 });
    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, accept_f, .{});
    defer r.deinit();
    _ = (try r.next()).?;
    try r.scanLinks();
    var buf: [100]u8 = undefined;

    try testing.expectEqual(@as(?i64, 10), try r.seekLinkGranule(1, 15));
    const p = (try r.next()).?;
    try testing.expectEqualSlices(u8, linkPayload(&buf, 1, 1), p.data);
    try testing.expectEqual(@as(i64, 20), p.granule);
    try testing.expectEqual(@as(u32, 31), p.serial);

    try testing.expectEqual(@as(?i64, 40), try r.seekLinkGranule(2, 1000));
    try testing.expectEqual(@as(?i64, 50), try r.seekLinkGranule(0, 1000));
    try testing.expectEqual(@as(?i64, 20), try r.seekGranule(25));
    try testing.expectEqualSlices(u8, linkPayload(&buf, 0, 2), (try r.next()).?.data);
    // Reading goes on into the next links.
    var left: usize = 0;
    while (try r.next()) |_| left += 1;
    try testing.expectEqual(@as(usize, 2 + (1 + 3) + (1 + 4)), left);

    try r.seekLink(2);
    const head = (try r.next()).?;
    try testing.expect(head.bos);
    try testing.expectEqual(@as(u32, 32), head.serial);
    try testing.expectEqual(@as(usize, 300), head.data.len);
    try r.seekLink(0);
    try testing.expectEqual(@as(u32, 30), (try r.next()).?.serial);
    try testing.expectError(error.BadData, r.seekLink(3));
    try testing.expectError(error.BadData, r.seekLinkGranule(3, 0));
}

test "a seek stays inside a link that shares its serial with the next one" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    for (0..2) |k| {
        var w = try PacketWriter.init(testing.allocator, &aw.writer, 7, .{});
        defer w.deinit();
        try w.writePacket("Fhead", 0);
        try w.flush();
        var buf: [100]u8 = undefined;
        for (0..3) |i| {
            try w.writePacket(linkPayload(&buf, k, i), @intCast((i + 1) * 10));
            try w.flush();
        }
        try w.finish();
    }
    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, accept_f, .{});
    defer r.deinit();
    _ = (try r.next()).?;
    try r.scanLinks();
    try testing.expectEqual(@as(usize, 2), r.links.items.len);
    try testing.expectEqual(@as(?i64, 30), try r.seekLinkGranule(0, 1000));
    try testing.expectEqual(@as(?i64, 30), try r.seekLinkGranule(1, 1000));
}

test "lastGranule reads backward from the end of the link" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeChain(&aw, &.{ 5, 3 });
    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, accept_f, .{});
    defer r.deinit();
    _ = (try r.next()).?;
    try testing.expectEqual(@as(?i64, 50), try r.lastGranule());
    try testing.expectEqual(@as(?i64, 50), r.link.?.last_granule);
    var buf: [100]u8 = undefined;
    try testing.expectEqualSlices(u8, linkPayload(&buf, 0, 0), (try r.next()).?.data);
    // The second link has no table entry yet, so the answer comes from its own pages.
    try r.scanLinks();
    r.links.items[1].last_granule = null;
    try r.seekLink(1);
    _ = (try r.next()).?;
    try testing.expectEqual(@as(?i64, 30), try r.lastGranule());
    try testing.expectEqual(@as(?i64, 30), r.links.items[1].last_granule);

    var fr: std.Io.Reader = .fixed(aw.written());
    var in2: Input = .init(.{ .reader = &fr });
    var r2 = try PacketReader.init(testing.allocator, &in2, .any, .{});
    defer r2.deinit();
    _ = (try r2.next()).?;
    try testing.expectError(error.Unseekable, r2.lastGranule());
}

test "lastGranule finds a page that is far from the end" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var w = try PacketWriter.init(testing.allocator, &aw.writer, 3, .{});
    defer w.deinit();
    try w.writePacket("Fhead", 0);
    try w.flush();
    try w.writePacket("last", 77);
    try w.flush();
    // 300000 bytes of one packet on pages without a granule.
    const big = try testing.allocator.alloc(u8, 300000);
    defer testing.allocator.free(big);
    pattern(big, 4);
    try w.writePacket(big, -1);
    try w.finish();
    var in: Input = .init(.{ .bytes = aw.written() });
    var r = try PacketReader.init(testing.allocator, &in, .any, .{});
    defer r.deinit();
    _ = (try r.next()).?;
    try testing.expectEqual(@as(?i64, 77), try r.lastGranule());
}

test "only the first packet after lost pages is marked" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var w = try PacketWriter.init(gpa, &aw.writer, 5, .{});
    defer w.deinit();
    const big = try gpa.alloc(u8, 70000);
    defer gpa.free(big);
    @memset(big, 9);
    try w.writePacket("a", 1);
    try w.flush();
    // The packet of 70000 bytes spans two pages.
    try w.writePacket(big, 2);
    try w.flush();
    try w.writePacket("c", 3);
    try w.flush();
    try w.writePacket("d", 4);
    try w.writePacket("e", 5);
    try w.finish();
    const bytes = aw.written();
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(gpa);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, "OggS")) |at| : (i = at + 4) try starts.append(gpa, at);
    try testing.expectEqual(@as(usize, 5), starts.items.len);

    const whole: [5]bool = .{ false, false, false, false, false };
    const lost: [4]bool = .{ false, false, true, false };
    const Case = struct { data: []const u8, flags: []const bool };
    const dropped = try std.mem.concat(gpa, u8, &.{ bytes[0..starts.items[3]], bytes[starts.items[4]..] });
    defer gpa.free(dropped);
    for ([_]Case{ .{ .data = bytes, .flags = &whole }, .{ .data = dropped, .flags = &lost } }) |case| {
        var in: Input = .init(.{ .bytes = case.data });
        var r = try PacketReader.init(gpa, &in, .any, .{});
        defer r.deinit();
        var n: usize = 0;
        while (try r.next()) |p| : (n += 1) try testing.expectEqual(case.flags[n], p.after_gap);
        try testing.expectEqual(case.flags.len, n);
    }
}

/// A source that hands out `step` bytes per call. With `arrived` set, it fails a request that
/// asks for more bytes than have arrived, as a blocking reader would stall.
const Trickle = struct {
    data: []const u8,
    arrived: usize = std.math.maxInt(usize),
    step: usize = 5,
    pos: usize = 0,
    calls: usize = 0,
    asked: usize = 0,
    largest: usize = 0,
    stalled: bool = false,

    const vtable: @import("../codec.zig").SeekableSource.VTable = .{ .read = read, .seekTo = seekTo, .length = length };

    fn source(self: *Trickle) @import("../codec.zig").SeekableSource {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn read(ctx: ?*anyopaque, buf: []u8) error{ReadFailed}!usize {
        const self: *Trickle = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.asked += buf.len;
        self.largest = @max(self.largest, buf.len);
        if (self.pos + buf.len > self.arrived and self.pos < self.arrived) {
            self.stalled = true;
            return error.ReadFailed;
        }
        const n = @min(@min(buf.len, self.step), self.data.len - self.pos);
        @memcpy(buf[0..n], self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    fn seekTo(ctx: ?*anyopaque, offset: u64) error{ ReadFailed, Unseekable }!void {
        const self: *Trickle = @ptrCast(@alignCast(ctx.?));
        if (offset > self.data.len) return error.ReadFailed;
        self.pos = @intCast(offset);
    }

    fn length(ctx: ?*anyopaque) ?u64 {
        const self: *Trickle = @ptrCast(@alignCast(ctx.?));
        return self.data.len;
    }
};

test "a live source is asked only for the bytes of the next page" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var w = try PacketWriter.init(gpa, &aw.writer, 5, .{});
    defer w.deinit();
    var packet: [100]u8 = undefined;
    for (0..3) |i| {
        pattern(&packet, i);
        try w.writePacket(&packet, @intCast(i + 1));
        try w.flush();
    }
    try w.finish();
    const bytes = aw.written();
    var starts: [4]usize = undefined;
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, at, "OggS")) |s| : (at = s + 4) {
        if (n < starts.len) starts[n] = s;
        n += 1;
    }
    try testing.expect(n >= 3);

    // Only the first two pages have arrived. A request past them would stall.
    var live: Trickle = .{ .data = bytes, .arrived = starts[2] };
    const src = live.source();
    var in: Input = .init(.{ .custom = &src });
    var r = try PacketReader.init(gpa, &in, .any, .{});
    defer r.deinit();
    for (0..2) |i| {
        pattern(&packet, i);
        const p = (try r.next()).?;
        try testing.expectEqualSlices(u8, &packet, p.data);
    }
    try testing.expect(!live.stalled);
    try testing.expect(live.largest <= starts[1] - starts[0]);
    // Every byte came in a call of 5 bytes at most, and all requests together stay under one window.
    try testing.expectEqual(starts[2], live.pos);
    try testing.expect(live.calls >= starts[2] / 5);
    try testing.expect(live.asked < max_page_size);
}

test "scanLinks builds the whole link table over a source with short reads" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeChain(&aw, &.{ 5, 3, 4 });
    var short: Trickle = .{ .data = aw.written(), .step = 1 };
    const src = short.source();
    var in: Input = .init(.{ .custom = &src });
    var r = try PacketReader.init(testing.allocator, &in, accept_f, .{});
    defer r.deinit();
    try testing.expectEqualStrings("F0", (try r.next()).?.data[0..2]);
    try r.scanLinks();
    try testing.expect(r.links_complete);
    try testing.expectEqual(@as(usize, 3), r.links.items.len);
    try testing.expectEqual(@as(?i64, 30), r.links.items[1].last_granule);
    try testing.expectEqual(@as(?i64, 40), r.links.items[2].last_granule);
    try testing.expectEqual(@as(?i64, 50), try r.lastGranule());
}
