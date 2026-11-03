//! Helpers that the tests of the Opus decoders share.
const std = @import("std");
const packet = @import("packet.zig");
const ogg = @import("../ogg.zig");
const io = @import("../io.zig");

/// The xorshift generator of the C harnesses that made the expected values in the tests.
pub const Xorshift = struct {
    s: u32 = 12345,

    pub fn next(self: *Xorshift) u32 {
        self.s ^= self.s << 13;
        self.s ^= self.s >> 17;
        self.s ^= self.s << 5;
        return self.s;
    }
};

/// One step of the FNV-1a hash over 32 bit words.
pub fn fnv(h: u32, v: u32) u32 {
    return (h ^ v) *% 16777619;
}

/// The start value of `fnv64`.
pub const fnv64_basis: u64 = 0xcbf29ce484222325;

/// Adds `bytes` to the 64 bit FNV-1a hash `h`.
pub fn fnv64(h_in: u64, bytes: []const u8) u64 {
    var h = h_in;
    for (bytes) |b| h = (h ^ b) *% 0x100000001b3;
    return h;
}

/// The results of one pass over some packets in a loss test. In the tests of the FFmpeg libopus
/// files the pattern says which packets are lost: 0 every fifth, 1 runs of 1, 2 and 3, 2 a run of
/// 60, 3 the first four, 4 every third with random durations, 5 the odd ones, 6 none. With FEC on,
/// a lost packet is made from the next packet when that one arrived. `seq_hash` hashes the sample
/// count and the final range of every call. `exact_hash` hashes the 16 bit samples of the slots
/// that only SILK reaches, 0 means unchecked. `samples` holds every `stride`th 16 bit sample of
/// the output, `energy` is the sum of the squares of all 16 bit samples. Runs with stride 0 check
/// only the hashes.
pub const Run = struct {
    calls: u32,
    seq_hash: u32,
    exact_hash: u32,
    stride: u32,
    energy: u64,
    samples: []const i16,
};

/// Builds Opus packets of random bytes with random TOC bytes, so that a decoder runs through
/// all modes, bandwidths and frame sizes. Every frame has two bytes or more.
pub const ModePackets = struct {
    rng: Xorshift = .{ .s = 0x1F123BB5 },

    pub const max_len = 4096;

    pub fn next(self: *ModePackets) u32 {
        return self.rng.next();
    }

    pub fn packet(self: *ModePackets, buf: *[max_len]u8) []const u8 {
        const r = self.next();
        const config: u8 = @intCast(r % 32);
        const stereo: u8 = @intCast((r >> 5) & 1);
        const samples: u32 = if (config < 12)
            ([_]u32{ 480, 960, 1920, 2880 })[config % 4]
        else if (config < 16)
            ([_]u32{ 480, 960 })[config % 2]
        else
            ([_]u32{ 120, 240, 480, 960 })[config % 4];
        const lens: [4]u32 = if (config < 12)
            .{ 20, 60, 160, 400 }
        else if (config < 16)
            .{ 30, 100, 300, 600 }
        else
            .{ 18, 118, 398, 1000 };
        const base: u32 = if (config < 16) 4 else 2;
        var flen = base + self.next() % lens[self.next() % 4];
        const form = (r >> 6) % 4;
        var frames: u32 = switch (form) {
            0, 1 => 1,
            2 => 2,
            else => 1 + self.next() % 6,
        };
        while (frames > 1 and (frames * samples > 5760 or frames * flen > 3000)) frames -= 1;
        flen = @min(flen, 1275, 3000 / frames);
        var at: usize = 1;
        if (form == 2 and frames == 2) {
            buf[0] = config << 3 | stereo << 2 | 1;
        } else if (form == 3 and frames >= 1) {
            buf[0] = config << 3 | stereo << 2 | 3;
            buf[1] = @intCast(frames);
            at = 2;
        } else {
            buf[0] = config << 3 | stereo << 2;
            frames = 1;
        }
        fillPayload(&self.rng, buf[at..][0 .. frames * flen]);
        return buf[0 .. at + frames * flen];
    }
};

/// Fills `bytes` with random data of a random shape: dense, or mostly zeros, or mostly 0xFF,
/// or with the top and bottom bit set.
pub fn fillPayload(rng: *Xorshift, bytes: []u8) void {
    const mode = rng.next() % 4;
    for (bytes) |*b| {
        const v = rng.next();
        b.* = switch (mode) {
            0 => @truncate(v),
            1 => if (v & 7 == 0) @truncate(v >> 8) else 0,
            2 => if (v & 7 == 0) @truncate(v >> 8) else 0xFF,
            else => @truncate(v | 0x81),
        };
    }
}

/// The mode of the packet in `packets`: 0 for SILK, 1 for hybrid and 2 for CELT. Packets
/// that are out of range count as SILK.
fn modeAt(packets: []const []const u8, i: isize) u8 {
    if (i < 0 or i >= packets.len) return 0;
    const config = packets[@intCast(i)][0] >> 3;
    return if (config < 12) 0 else if (config < 16) 1 else 2;
}

/// A slot is exact when no CELT audio can reach it: the packets around it are all SILK.
fn exactSlot(packets: []const []const u8, i: usize) bool {
    var j: isize = @as(isize, @intCast(i)) - 3;
    while (j <= i + 3) : (j += 1) {
        if (modeAt(packets, j) != 0) return false;
    }
    return true;
}

/// The loss patterns of the tests. Pattern 0 loses every fifth packet. Pattern 1 loses runs of
/// 1, 2 and 3 packets. Pattern 2 loses packets 40 to 99. Pattern 3 loses the first four packets.
/// Pattern 4 loses every third packet and asks for random durations. Pattern 5 loses the
/// odd packets. Other patterns lose none.
pub fn isLost(pattern: u8, i: usize) bool {
    return switch (pattern) {
        0 => i % 5 == 4,
        1 => switch (i % 20) {
            4, 8, 9, 13, 14, 15 => true,
            else => false,
        },
        2 => i >= 40 and i < 100,
        3 => i < 4,
        4 => i % 3 == 2,
        5 => i % 2 == 1,
        else => false,
    };
}

/// The samples that a call asks for when packet `i` is lost. `duration` is the duration of the
/// lost packet.
pub fn lossSize(pattern: u8, i: usize, duration: usize) usize {
    return if (pattern == 4) 120 * (1 + (i * 7) % 48) else duration;
}

fn toInt16(x: f32) i16 {
    return @intFromFloat(std.math.clamp(@round(x * 32768.0), -32768.0, 32767.0));
}

/// Decodes `packets` with a loss pattern like the libopus harness does and compares the sample
/// count and the final range of every call. Slots that only SILK reaches must be exact. When
/// `expected` has samples, every `stride`th sample of the other slots must be within `tolerance`
/// steps of 16 bit and the energy of all samples within 0.01 percent. A lost packet is made by
/// the concealment, or by the FEC data of the next packet when `fec` is set and that packet
/// arrived. `dec` is a PacketDecoder and `expected` a Run of the plc tables.
pub fn playLoss(dec: anytype, packets: []const []const u8, pattern: u8, fec: bool, expected: anytype, tolerance: i32) !void {
    const ch = dec.channels;
    const check_pcm = expected.stride != 0;
    var out: [5760 * 2]f32 = undefined;
    var seq: u32 = 2166136261;
    var exact: u32 = 2166136261;
    var at: usize = 0;
    var energy: u64 = 0;
    var calls: u32 = 0;
    for (packets, 0..) |pkt, i| {
        var n: usize = undefined;
        if (isLost(pattern, i)) {
            const size = lossSize(pattern, i, try packet.samples(pkt, 48000));
            if (fec and i + 1 < packets.len and !isLost(pattern, i + 1)) {
                n = try dec.decode(packets[i + 1], true, out[0 .. size * ch]);
            } else {
                n = try dec.decode(null, false, out[0 .. size * ch]);
            }
        } else {
            n = try dec.decode(pkt, false, &out);
        }
        calls += 1;
        const rng = dec.finalRange();
        seq = fnv(fnv(seq, @intCast(n)), rng);
        const is_exact = exactSlot(packets, i);
        for (out[0 .. n * ch]) |x| {
            const v = toInt16(x);
            if (is_exact) exact = fnv(exact, @as(u16, @bitCast(v)));
            energy += @intCast(@as(i64, v) * v);
            if (check_pcm and at % expected.stride == 0) {
                const want: i32 = expected.samples[at / expected.stride];
                const diff: i32 = @intCast(@abs(@as(i32, v) - want));
                if (diff > (if (is_exact) 0 else tolerance)) {
                    std.debug.print("call {d} sample {d}: {d}, expected {d}\n", .{ i, at, v, want });
                    return error.TestExpectedEqual;
                }
            }
            at += 1;
        }
    }
    try std.testing.expectEqual(expected.calls, calls);
    try std.testing.expectEqual(expected.seq_hash, seq);
    if (expected.exact_hash != 0) try std.testing.expectEqual(expected.exact_hash, exact);
    if (check_pcm) {
        const diff_energy = @max(energy, expected.energy) - @min(energy, expected.energy);
        try std.testing.expect(diff_energy <= expected.energy / 10_000);
    }
}

/// Packets of random modes like `ModePackets` makes them. Every seventh packet is cut to the TOC
/// byte alone or to one byte of payload, which stands for a frame that was not sent. The caller
/// frees the result with `freePackets`.
pub fn mixedPackets(gpa: std.mem.Allocator, seed: u32, count: usize) ![]const []const u8 {
    var gen: ModePackets = .{ .rng = .{ .s = seed } };
    var buf: [ModePackets.max_len]u8 = undefined;
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    for (0..count) |i| {
        var pkt = gen.packet(&buf);
        if (i % 7 == 6) {
            buf[0] &= 0xFC;
            pkt = pkt[0 .. 1 + (i / 7) % 2];
        }
        const copy = try gpa.dupe(u8, pkt);
        errdefer gpa.free(copy);
        try list.append(gpa, copy);
    }
    return list.toOwnedSlice(gpa);
}

/// The audio packets of an Ogg Opus file, without the two header packets. The caller frees the
/// result with `freePackets`.
pub fn oggPackets(gpa: std.mem.Allocator, file: []const u8) ![]const []const u8 {
    var in: io.Input = .init(.{ .bytes = file });
    var reader = try ogg.PacketReader.init(gpa, &in, .any, .{});
    defer reader.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    var index: usize = 0;
    while (try reader.next()) |p| : (index += 1) {
        if (index < 2) continue;
        const copy = try gpa.dupe(u8, p.data);
        errdefer gpa.free(copy);
        try list.append(gpa, copy);
    }
    return list.toOwnedSlice(gpa);
}

pub fn freePackets(gpa: std.mem.Allocator, packets: []const []const u8) void {
    for (packets) |p| gpa.free(p);
    gpa.free(packets);
}

/// A hybrid packet of 20 ms whose redundancy size does not fit in the packet. The decoder
/// drops the redundancy and conceals the CELT part.
pub const bad_redundancy_packet = [_]u8{
    120, 175, 188, 27,  197, 238, 62, 15,  165, 118, 133, 75,  81,  26, 2,
    223, 176, 23,  167, 86,  30,  53, 161, 210, 183, 75,  105, 159, 45, 175,
};

/// The packets of an Ogg Opus file that starts with hybrid packets, with `bad_redundancy_packet`
/// after the fifth. The caller frees the result with `freePackets`.
pub fn withBadRedundancy(gpa: std.mem.Allocator, file: []const u8) ![]const []const u8 {
    const all = try oggPackets(gpa, file);
    defer freePackets(gpa, all);
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    for (all[0..9], 0..) |p, i| {
        if (i == 5) {
            const bad = try gpa.dupe(u8, &bad_redundancy_packet);
            errdefer gpa.free(bad);
            try list.append(gpa, bad);
        }
        const copy = try gpa.dupe(u8, p);
        errdefer gpa.free(copy);
        try list.append(gpa, copy);
    }
    return list.toOwnedSlice(gpa);
}
