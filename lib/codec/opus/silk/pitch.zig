//! Pitch lag and LTP codebook lookups ported from libopus silk/decode_pitch.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const tables = @import("tables.zig");

pub const ltp_order = 5;

/// The tables that code the pitch lag of one frame size and rate.
pub const LagTables = struct {
    contour_icdf: []const u8,
    /// Row `subframe`, `cbk_size` entries per row.
    lags: []const i8,
    cbk_size: usize,
};

pub fn lagTables(fs_khz: u32, nb_subfr: u32) LagTables {
    if (fs_khz == 8) {
        if (nb_subfr == 4) return .{
            .contour_icdf = &tables.pitch_contour_nb_icdf,
            .lags = &tables.cb_lags_stage2,
            .cbk_size = 11,
        };
        return .{
            .contour_icdf = &tables.pitch_contour_10_ms_nb_icdf,
            .lags = &tables.cb_lags_stage2_10_ms,
            .cbk_size = 3,
        };
    }
    if (nb_subfr == 4) return .{
        .contour_icdf = &tables.pitch_contour_icdf,
        .lags = &tables.cb_lags_stage3,
        .cbk_size = 34,
    };
    return .{
        .contour_icdf = &tables.pitch_contour_10_ms_icdf,
        .lags = &tables.cb_lags_stage3_10_ms,
        .cbk_size = 12,
    };
}

/// The icdf of the low bits of an absolute lag index.
pub fn lagLowBitsIcdf(fs_khz: u32) []const u8 {
    return switch (fs_khz) {
        8 => &tables.uniform4_icdf,
        12 => &tables.uniform6_icdf,
        else => &tables.uniform8_icdf,
    };
}

/// The lag of each subframe in samples.
pub fn decodePitch(lag_index: i32, contour_index: u32, pitch_l: []i32, fs_khz: u32) void {
    const lt = lagTables(fs_khz, @intCast(pitch_l.len));
    const fs: i32 = @intCast(fs_khz);
    const min_lag = 2 * fs;
    const max_lag = 18 * fs;
    const lag = min_lag +% lag_index;
    const contour = @min(contour_index, lt.cbk_size - 1);
    for (pitch_l, 0..) |*l, k| {
        l.* = std.math.clamp(lag +% lt.lags[k * lt.cbk_size + contour], min_lag, max_lag);
    }
}

pub const ltp_gain_icdfs = [3][]const u8{ &tables.ltp_gain_icdf_0, &tables.ltp_gain_icdf_1, &tables.ltp_gain_icdf_2 };
pub const ltp_vq = [3][]const i8{ &tables.ltp_gain_vq_0, &tables.ltp_gain_vq_1, &tables.ltp_gain_vq_2 };

const testing = std.testing;

test "lags follow the contour and stay inside the legal range" {
    var l: [4]i32 = undefined;
    decodePitch(100, 0, &l, 16);
    try testing.expectEqualSlices(i32, &.{ 132, 132, 132, 132 }, &l);
    // Contour 33 of the 16 kHz table is {-9, -3, 3, 9}.
    decodePitch(100, 33, &l, 16);
    try testing.expectEqualSlices(i32, &.{ 123, 129, 135, 141 }, &l);
    decodePitch(-500, 0, &l, 8);
    try testing.expectEqualSlices(i32, &.{ 16, 16, 16, 16 }, &l);
    decodePitch(5000, 0, &l, 8);
    try testing.expectEqualSlices(i32, &.{ 144, 144, 144, 144 }, &l);
    var l2: [2]i32 = undefined;
    decodePitch(10, 1, &l2, 12);
    try testing.expectEqualSlices(i32, &.{ 34, 35 }, &l2);
}

test "codebook sizes match the contour tables" {
    for ([_]u32{ 8, 12, 16 }) |fs| {
        for ([_]u32{ 2, 4 }) |n| {
            const lt = lagTables(fs, n);
            try testing.expectEqual(lt.cbk_size, lt.contour_icdf.len);
            try testing.expectEqual(n * lt.cbk_size, lt.lags.len);
        }
    }
}
