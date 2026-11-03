//! Channel layout conversion.
const std = @import("std");
const Format = @import("../Format.zig");

const Gain = struct { position: Format.Position, gain: f32 };

const minus_3_db: f32 = 0.70710678;

fn fallbacks(position: Format.Position) []const []const Gain {
    return switch (position) {
        .mono => &.{
            &.{ .{ .position = .front_left, .gain = 1 }, .{ .position = .front_right, .gain = 1 } },
            &.{.{ .position = .front_center, .gain = 1 }},
        },
        .front_left => &.{
            &.{.{ .position = .mono, .gain = 0.5 }},
            &.{.{ .position = .front_center, .gain = 1 }},
        },
        .front_right => &.{
            &.{.{ .position = .mono, .gain = 0.5 }},
            &.{.{ .position = .front_center, .gain = 1 }},
        },
        .front_center => &.{
            &.{ .{ .position = .front_left, .gain = minus_3_db }, .{ .position = .front_right, .gain = minus_3_db } },
            &.{.{ .position = .mono, .gain = 1 }},
        },
        .lfe => &.{},
        .rear_left => &.{
            &.{.{ .position = .side_left, .gain = 1 }},
            &.{.{ .position = .front_left, .gain = minus_3_db }},
            &.{.{ .position = .mono, .gain = 0.5 }},
        },
        .rear_right => &.{
            &.{.{ .position = .side_right, .gain = 1 }},
            &.{.{ .position = .front_right, .gain = minus_3_db }},
            &.{.{ .position = .mono, .gain = 0.5 }},
        },
        .side_left => &.{
            &.{.{ .position = .rear_left, .gain = 1 }},
            &.{.{ .position = .front_left, .gain = minus_3_db }},
            &.{.{ .position = .mono, .gain = 0.5 }},
        },
        .side_right => &.{
            &.{.{ .position = .rear_right, .gain = 1 }},
            &.{.{ .position = .front_right, .gain = minus_3_db }},
            &.{.{ .position = .mono, .gain = 0.5 }},
        },
        _ => &.{},
    };
}

pub const Remap = struct {
    src_count: u8,
    dst_count: u8,
    /// Indexed as matrix[dst][src].
    matrix: [Format.max_channels][Format.max_channels]f32,
    identity: bool,

    pub fn init(src: Format.Channels, dst: Format.Channels) Remap {
        var r: Remap = .{
            .src_count = src.count,
            .dst_count = dst.count,
            .matrix = @splat(@splat(0)),
            .identity = src.eql(dst),
        };
        for (src.slice(), 0..) |position, i| {
            if (dst.indexOf(position)) |d| {
                r.matrix[d][i] = 1;
                continue;
            }
            fit: for (fallbacks(position)) |option| {
                for (option) |g| {
                    if (dst.indexOf(g.position) == null) continue :fit;
                }
                for (option) |g| r.matrix[dst.indexOf(g.position).?][i] += g.gain;
                break;
            }
        }
        return r;
    }

    /// Interleaved frames. dst.len / dst_count must equal src.len / src_count.
    pub fn process(self: *const Remap, src: []const f32, dst: []f32) void {
        const frames = src.len / self.src_count;
        std.debug.assert(dst.len / self.dst_count == frames);
        if (self.identity) {
            std.debug.assert(dst.len == src.len);
            @memcpy(dst, src);
            return;
        }
        for (0..frames) |f| {
            const in = src[f * self.src_count ..][0..self.src_count];
            const out = dst[f * self.dst_count ..][0..self.dst_count];
            for (out, 0..) |*o, d| {
                var sum: f32 = 0;
                for (in, 0..) |s, i| sum += self.matrix[d][i] * s;
                o.* = sum;
            }
        }
    }
};

fn run(src: Format.Channels, dst: Format.Channels, in: []const f32, out: []f32) void {
    const r: Remap = .init(src, dst);
    r.process(in, out);
}

test "the same layout copies the input" {
    const r: Remap = .init(.stereo, .stereo);
    try std.testing.expect(r.identity);
    var out: [4]f32 = undefined;
    r.process(&.{ 0.1, 0.2, 0.3, 0.4 }, &out);
    try std.testing.expectEqualSlices(f32, &.{ 0.1, 0.2, 0.3, 0.4 }, &out);
}

test "mono to stereo puts the sample in both channels" {
    var out: [4]f32 = undefined;
    run(.mono, .stereo, &.{ 0.5, -0.25 }, &out);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.5, -0.25, -0.25 }, &out);
}

test "stereo to mono takes the average" {
    var out: [1]f32 = undefined;
    run(.stereo, .mono, &.{ 0.2, 0.6 }, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), out[0], 1e-6);
}

test "5.1 to stereo folds the center at -3 dB and drops the LFE" {
    var out: [2]f32 = undefined;
    run(.surround_5_1, .stereo, &.{ 0, 0, 1, 1, 0, 0 }, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.70710678), out[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.70710678), out[1], 1e-6);
}

test "a swapped layout swaps the channels" {
    var out: [2]f32 = undefined;
    run(Format.Channels.init(&.{ .front_right, .front_left }), .stereo, &.{ 0.9, 0.1 }, &out);
    try std.testing.expectEqualSlices(f32, &.{ 0.1, 0.9 }, &out);
}

test "7.1 to 5.1 sends the sides to the rears" {
    var out: [6]f32 = undefined;
    run(.surround_7_1, .surround_5_1, &.{ 0, 0, 0, 0, 0, 0, 1, 0 }, &out);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0, 1, 0 }, &out);
}

test "aux channels map only to the same aux channel" {
    const aux = Format.Position.aux;
    var out: [1]f32 = undefined;
    run(.init(&.{ aux(0), aux(1) }), .init(&.{aux(1)}), &.{ 0.25, 0.75 }, &out);
    try std.testing.expectEqualSlices(f32, &.{0.75}, &out);
}
