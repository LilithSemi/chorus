//! Excitation pulses ported from libopus silk/decode_pulses.c, shell_coder.c and code_signs.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const range = @import("../range.zig");
const tables = @import("tables.zig");

pub const shell_len = 16;
/// The pulse buffer holds whole shell blocks.
pub const max_pulses = (320 + shell_len - 1) / shell_len * shell_len;
const max_blocks = max_pulses / shell_len;
const pulse_escape = 17;

const shell_tables = [4][]const u8{
    &tables.shell_code_table0,
    &tables.shell_code_table1,
    &tables.shell_code_table2,
    &tables.shell_code_table3,
};

fn split(dec: *range.Decoder, c1: *i16, c2: *i16, p: i16, table: []const u8) void {
    if (p > 0) {
        const off = tables.shell_code_table_offsets[@intCast(p)];
        c1.* = @intCast(dec.icdf(table[off..], 8));
        c2.* = p - c1.*;
    } else {
        c1.* = 0;
        c2.* = 0;
    }
}

/// Decodes the 16 pulse amplitudes of one block that sum to `total`.
fn shellDecode(out: *[shell_len]i16, dec: *range.Decoder, total: i16) void {
    var p1: [8]i16 = undefined;
    var p2: [4]i16 = undefined;
    var p3: [2]i16 = undefined;
    split(dec, &p3[0], &p3[1], total, shell_tables[3]);
    split(dec, &p2[0], &p2[1], p3[0], shell_tables[2]);
    split(dec, &p1[0], &p1[1], p2[0], shell_tables[1]);
    split(dec, &out[0], &out[1], p1[0], shell_tables[0]);
    split(dec, &out[2], &out[3], p1[1], shell_tables[0]);
    split(dec, &p1[2], &p1[3], p2[1], shell_tables[1]);
    split(dec, &out[4], &out[5], p1[2], shell_tables[0]);
    split(dec, &out[6], &out[7], p1[3], shell_tables[0]);
    split(dec, &p2[2], &p2[3], p3[1], shell_tables[2]);
    split(dec, &p1[4], &p1[5], p2[2], shell_tables[1]);
    split(dec, &out[8], &out[9], p1[4], shell_tables[0]);
    split(dec, &out[10], &out[11], p1[5], shell_tables[0]);
    split(dec, &p1[6], &p1[7], p2[3], shell_tables[1]);
    split(dec, &out[12], &out[13], p1[6], shell_tables[0]);
    split(dec, &out[14], &out[15], p1[7], shell_tables[0]);
}

/// Decodes the signed pulses of one frame into `pulses`. A frame of 120 samples (10 ms at 12 kHz)
/// still decodes 128 pulses.
pub fn decodePulses(
    dec: *range.Decoder,
    pulses: *[max_pulses]i16,
    signal_type: u32,
    quant_offset_type: u32,
    frame_length: u32,
) void {
    const rate_level = dec.icdf(tables.rate_levels_icdf[(signal_type >> 1) * 9 ..][0..9], 8);
    var iter = frame_length >> 4;
    if (iter * shell_len < frame_length) iter += 1;
    const cdf = tables.pulses_per_block_icdf[rate_level * 18 ..][0..18];
    const escape = tables.pulses_per_block_icdf[9 * 18 ..];

    var sum_pulses: [max_blocks]u32 = undefined;
    var shifts: [max_blocks]u32 = undefined;
    for (0..iter) |i| {
        shifts[i] = 0;
        sum_pulses[i] = dec.icdf(cdf, 8);
        while (sum_pulses[i] == pulse_escape) {
            shifts[i] += 1;
            const table = escape[@intFromBool(shifts[i] == 10)..];
            sum_pulses[i] = dec.icdf(table, 8);
        }
    }
    for (0..iter) |i| {
        const block: *[shell_len]i16 = pulses[i * shell_len ..][0..shell_len];
        if (sum_pulses[i] > 0) {
            shellDecode(block, dec, @intCast(sum_pulses[i]));
        } else {
            block.* = @splat(0);
        }
    }
    for (0..iter) |i| {
        if (shifts[i] > 0) {
            const block = pulses[i * shell_len ..][0..shell_len];
            for (block) |*q| {
                var abs_q: i32 = q.*;
                for (0..shifts[i]) |_| {
                    abs_q = (abs_q << 1) + @as(i32, @intCast(dec.icdf(&tables.lsb_icdf, 8)));
                }
                q.* = @truncate(abs_q);
            }
            sum_pulses[i] |= shifts[i] << 5;
        }
    }
    decodeSigns(dec, pulses, frame_length, signal_type, quant_offset_type, sum_pulses[0..iter]);
}

fn decodeSigns(
    dec: *range.Decoder,
    pulses: *[max_pulses]i16,
    frame_length: u32,
    signal_type: u32,
    quant_offset_type: u32,
    sum_pulses: []const u32,
) void {
    const base = 7 * (quant_offset_type + (signal_type << 1));
    const blocks = (frame_length + shell_len / 2) >> 4;
    var icdf: [2]u8 = .{ 0, 0 };
    for (0..blocks) |i| {
        const p = sum_pulses[i];
        if (p == 0) continue;
        icdf[0] = tables.sign_icdf[base + @min(p & 0x1F, 6)];
        for (pulses[i * shell_len ..][0..shell_len]) |*q| {
            if (q.* > 0) {
                const s: i16 = @intCast(dec.icdf(&icdf, 8));
                q.* *%= s * 2 - 1;
            }
        }
    }
}

const testing = std.testing;
const test_util = @import("../test_util.zig");

test "an all zero payload decodes to a quiet frame" {
    const data: [40]u8 = @splat(0);
    var dec = range.Decoder.init(&data);
    var pulses: [max_pulses]i16 = @splat(99);
    decodePulses(&dec, &pulses, 0, 0, 160);
    // libopus decodes no pulse for this payload.
    for (pulses[0..160]) |q| try testing.expectEqual(@as(i16, 0), q);
}

test "random payloads never trap and keep the 12 kHz 10 ms block count" {
    var rng: test_util.Xorshift = .{ .s = 7 };
    var data: [64]u8 = undefined;
    for (0..2000) |t| {
        for (&data) |*b| b.* = @truncate(rng.next() >> 3);
        var dec = range.Decoder.init(&data);
        var pulses: [max_pulses]i16 = @splat(0x5555);
        const len: u32 = switch (t % 4) {
            0 => 80,
            1 => 120,
            2 => 160,
            else => 320,
        };
        decodePulses(&dec, &pulses, @intCast(t % 3), @intCast(t % 2), len);
        // Every block of the frame is written, the blocks after it are not.
        const written = (len + 15) / 16 * 16;
        for (pulses[0..written]) |q| try testing.expect(q != 0x5555);
        if (written < max_pulses) try testing.expectEqual(@as(i16, 0x5555), pulses[written]);
    }
}
