//! Stereo prediction and mid side unmixing ported from libopus silk/stereo_decode_pred.c and stereo_MS_to_LR.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const range = @import("../range.zig");
const m = @import("macros.zig");
const tables = @import("tables.zig");

const interp_len_ms = 8;

/// The two prediction weights of a frame in Q13. The first is already reduced by the second.
pub const Prediction = [2]i32;

pub fn decodePred(dec: *range.Decoder) Prediction {
    const joint = dec.icdf(&tables.stereo_pred_joint_icdf, 8);
    var ix: [2][3]u32 = undefined;
    ix[0][2] = joint / 5;
    ix[1][2] = joint - 5 * ix[0][2];
    for (&ix) |*row| {
        row[0] = dec.icdf(&tables.uniform3_icdf, 8);
        row[1] = dec.icdf(&tables.uniform5_icdf, 8);
    }
    var pred: Prediction = undefined;
    for (ix, 0..) |row, n| {
        const idx = row[0] + 3 * row[2];
        const low: i32 = tables.stereo_pred_quant_q13[idx];
        const step = m.smulwb(@as(i32, tables.stereo_pred_quant_q13[idx + 1]) - low, 6554);
        pred[n] = m.smlabb(low, step, @intCast(2 * row[1] + 1));
    }
    pred[0] -%= pred[1];
    return pred;
}

pub fn decodeMidOnly(dec: *range.Decoder) bool {
    return dec.icdf(&tables.stereo_only_code_mid_icdf, 8) != 0;
}

/// The filter state that carries over between frames.
pub const State = struct {
    pred_prev_q13: [2]i16 = .{ 0, 0 },
    s_mid: [2]i16 = .{ 0, 0 },
    s_side: [2]i16 = .{ 0, 0 },
};

/// Turns the mid signal `x1` and the side signal `x2` into left and right. Each buffer holds
/// two samples of history and then `frame_length` samples, and the result replaces them.
pub fn msToLr(state: *State, x1: []i16, x2: []i16, pred_q13: Prediction, fs_khz: u32, frame_length: usize) void {
    x1[0..2].* = state.s_mid;
    x2[0..2].* = state.s_side;
    state.s_mid = x1[frame_length..][0..2].*;
    state.s_side = x2[frame_length..][0..2].*;

    var pred0: i32 = state.pred_prev_q13[0];
    var pred1: i32 = state.pred_prev_q13[1];
    const interp: usize = interp_len_ms * fs_khz;
    const denom_q16 = m.div32(1 << 16, @intCast(interp));
    const delta0 = m.rshiftRound(m.smulbb(pred_q13[0] -% state.pred_prev_q13[0], denom_q16), 16);
    const delta1 = m.rshiftRound(m.smulbb(pred_q13[1] -% state.pred_prev_q13[1], denom_q16), 16);
    for (0..@min(interp, frame_length)) |n| {
        pred0 +%= delta0;
        pred1 +%= delta1;
        x2[n + 1] = sideSample(x1, x2, n, pred0, pred1);
    }
    for (@min(interp, frame_length)..frame_length) |n| {
        x2[n + 1] = sideSample(x1, x2, n, pred_q13[0], pred_q13[1]);
    }
    state.pred_prev_q13 = .{ m.trunc16(pred_q13[0]), m.trunc16(pred_q13[1]) };

    for (0..frame_length) |n| {
        const mid: i32 = x1[n + 1];
        const side: i32 = x2[n + 1];
        x1[n + 1] = @intCast(m.sat16(mid + side));
        x2[n + 1] = @intCast(m.sat16(mid - side));
    }
}

fn sideSample(x1: []const i16, x2: []const i16, n: usize, pred0: i32, pred1: i32) i16 {
    const sum: i32 = ((@as(i32, x1[n]) + x1[n + 2]) + (@as(i32, x1[n + 1]) << 1)) << 9;
    var s = m.smlawb(@as(i32, x2[n + 1]) << 8, sum, pred0);
    s = m.smlawb(s, @as(i32, x1[n + 1]) << 11, pred1);
    return @intCast(m.sat16(m.rshiftRound(s, 8)));
}

const testing = std.testing;

test "a zero payload decodes the first prediction pair" {
    const data: [8]u8 = @splat(0);
    var dec = range.Decoder.init(&data);
    const p = decodePred(&dec);
    // The values come from silk_stereo_decode_pred and silk_stereo_decode_mid_only of libopus.
    try testing.expectEqual(Prediction{ 0, -13364 }, p);
    try testing.expect(!decodeMidOnly(&dec));
}

test "a centered signal with no prediction stays on both channels" {
    var st: State = .{};
    var x1: [2 + 64]i16 = undefined;
    var x2: [2 + 64]i16 = @splat(0);
    for (&x1, 0..) |*v, i| v.* = @intCast(@as(i32, @intCast(i)) * 50 - 1000);
    const orig = x1;
    msToLr(&st, x1[0..], x2[0..], .{ 0, 0 }, 8, 64);
    // Side is zero, so left and right equal the mid samples. The first sample is history.
    for (2..65) |i| {
        try testing.expectEqual(x1[i], x2[i]);
        try testing.expectEqual(orig[i], x1[i]);
    }
    try testing.expectEqual(orig[64], st.s_mid[0]);
}
