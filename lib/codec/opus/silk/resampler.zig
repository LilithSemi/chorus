//! Resampler up to 48 kHz ported from libopus silk/resampler.c, resampler_private_IIR_FIR.c and up2_HQ.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const m = @import("macros.zig");
const tables = @import("tables.zig");

const fir_order = 8;
const max_batch = 10 * 16;

const up2_hq_0 = [3]i16{ 1746, 14986, 39083 - 65536 };
const up2_hq_1 = [3]i16{ 6854, 25769, 55542 - 65536 };

/// Samples of delay by input rate (8, 12 or 16 kHz) and output rate (8, 12, 16, 24, 48 kHz).
fn inputDelay(in_khz: u32, out_khz: u32) usize {
    const table = [3][5]usize{
        .{ 4, 0, 2, 0, 0 },
        .{ 0, 9, 4, 7, 4 },
        .{ 0, 3, 12, 7, 7 },
    };
    const row: usize = switch (in_khz) {
        8 => 0,
        12 => 1,
        else => 2,
    };
    const col: usize = switch (out_khz) {
        8 => 0,
        12 => 1,
        16 => 2,
        24 => 3,
        else => 4,
    };
    return table[row][col];
}

/// True when the resampler can go from `in_khz` to `out_khz`.
pub fn validRates(in_khz: u32, out_khz: u32) bool {
    const in_ok = in_khz == 8 or in_khz == 12 or in_khz == 16;
    const out_ok = out_khz == 8 or out_khz == 12 or out_khz == 16 or out_khz == 24 or out_khz == 48;
    return in_ok and out_ok and out_khz >= in_khz;
}

pub const Resampler = struct {
    in_khz: u32,
    out_khz: u32,
    input_delay: usize,
    batch_size: usize,
    inv_ratio_q16: i32,
    s_iir: [6]i32,
    s_fir: [fir_order]i16,
    delay_buf: [16]i16,

    /// A resampler from `in_khz` (8, 12 or 16) to 48 kHz with cleared state.
    pub fn init(in_khz: u32) Resampler {
        return initTo(in_khz, 48);
    }

    /// A resampler from `in_khz` (8, 12 or 16) to `out_khz` (the same or more, up to 48) with
    /// cleared state.
    pub fn initTo(in_khz: u32, out_khz: u32) Resampler {
        std.debug.assert(validRates(in_khz, out_khz));
        const in_hz: i32 = @intCast(in_khz * 1000);
        const out_hz: i32 = @intCast(out_khz * 1000);
        const up2x: u5 = if (out_khz > in_khz and out_khz != 2 * in_khz) 1 else 0;
        var inv_ratio = m.div32(in_hz << (14 + up2x), out_hz) << 2;
        while (m.smulww(inv_ratio, out_hz) < in_hz << up2x) inv_ratio += 1;
        return .{
            .in_khz = in_khz,
            .out_khz = out_khz,
            .input_delay = inputDelay(in_khz, out_khz),
            .batch_size = in_khz * 10,
            .inv_ratio_q16 = inv_ratio,
            .s_iir = @splat(0),
            .s_fir = @splat(0),
            .delay_buf = @splat(0),
        };
    }

    /// Resamples `in` to `out`. `in` holds at least one millisecond and `out` holds
    /// `in.len * out_khz / in_khz` samples.
    pub fn process(self: *Resampler, out: []i16, in: []const i16) void {
        const khz = self.in_khz;
        std.debug.assert(in.len >= khz);
        const n = khz - self.input_delay;
        @memcpy(self.delay_buf[self.input_delay..khz], in[0..n]);
        const first = self.delay_buf;
        const rest = in[n..][0 .. in.len - khz];
        if (self.out_khz == khz) {
            @memcpy(out[0..khz], first[0..khz]);
            @memcpy(out[khz..][0..rest.len], rest);
        } else if (self.out_khz == 2 * khz) {
            self.up2(out[0 .. 2 * khz], first[0..khz]);
            self.up2(out[2 * khz ..][0 .. 2 * rest.len], rest);
        } else {
            self.run(out[0..self.out_khz], first[0..khz]);
            self.run(out[self.out_khz..], rest);
        }
        @memcpy(self.delay_buf[0..self.input_delay], in[in.len - self.input_delay ..]);
    }

    fn up2(self: *Resampler, out: []i16, in: []const i16) void {
        for (in, 0..) |sample, k| {
            const in32 = @as(i32, sample) << 10;
            out[2 * k] = allpass3(self.s_iir[0..3], in32, up2_hq_0);
            out[2 * k + 1] = allpass3(self.s_iir[3..6], in32, up2_hq_1);
        }
    }

    fn run(self: *Resampler, out_in: []i16, in_all: []const i16) void {
        var out = out_in;
        var in = in_all;
        var buf: [2 * max_batch + fir_order]i16 = undefined;
        buf[0..fir_order].* = self.s_fir;
        var n_in: usize = 0;
        while (true) {
            n_in = @min(in.len, self.batch_size);
            self.up2(buf[fir_order..][0 .. 2 * n_in], in[0..n_in]);
            const max_index: i32 = @intCast(n_in << 17);
            var index: i32 = 0;
            var o: usize = 0;
            while (index < max_index) : (index +%= self.inv_ratio_q16) {
                const t: usize = @intCast(m.smulwb(index & 0xFFFF, 12));
                const b = buf[@intCast(index >> 16)..][0..8];
                const f = tables.resampler_frac_fir_12;
                const r = 11 - t;
                var acc = m.smulbb(b[0], f[t * 4]);
                acc = m.smlabb(acc, b[1], f[t * 4 + 1]);
                acc = m.smlabb(acc, b[2], f[t * 4 + 2]);
                acc = m.smlabb(acc, b[3], f[t * 4 + 3]);
                acc = m.smlabb(acc, b[4], f[r * 4 + 3]);
                acc = m.smlabb(acc, b[5], f[r * 4 + 2]);
                acc = m.smlabb(acc, b[6], f[r * 4 + 1]);
                acc = m.smlabb(acc, b[7], f[r * 4]);
                out[o] = @intCast(m.sat16(m.rshiftRound(acc, 15)));
                o += 1;
            }
            out = out[o..];
            in = in[n_in..];
            if (in.len > 0) {
                const tail: [fir_order]i16 = buf[2 * n_in ..][0..fir_order].*;
                buf[0..fir_order].* = tail;
            } else break;
        }
        self.s_fir = buf[2 * n_in ..][0..fir_order].*;
    }
};

fn allpass3(s: *[3]i32, in32: i32, c: [3]i16) i16 {
    var y = in32 -% s[0];
    var x = m.smulwb(y, c[0]);
    const o1 = s[0] +% x;
    s[0] = in32 +% x;
    y = o1 -% s[1];
    x = m.smulwb(y, c[1]);
    const o2 = s[1] +% x;
    s[1] = o1 +% x;
    y = o2 -% s[2];
    x = m.smlawb(y, y, c[2]);
    const o3 = s[2] +% x;
    s[2] = o2 +% x;
    return @intCast(m.sat16(m.rshiftRound(o3, 10)));
}

const testing = std.testing;

test "the init ratios match libopus" {
    try testing.expectEqual(@as(i32, 21846), Resampler.init(8).inv_ratio_q16);
    try testing.expectEqual(@as(i32, 32768), Resampler.init(12).inv_ratio_q16);
    try testing.expectEqual(@as(i32, 43691), Resampler.init(16).inv_ratio_q16);
}

test "every frame length gives exactly 48 samples per input millisecond" {
    for ([_]u32{ 8, 12, 16 }) |khz| {
        for ([_]u32{ 10, 20 }) |ms| {
            var r = Resampler.init(khz);
            var in: [320]i16 = undefined;
            for (&in, 0..) |*v, i| v.* = @intCast(@as(i32, @intCast(i % 50)) * 100 - 2500);
            var out: [960 + 8]i16 = @splat(0x4242);
            r.process(out[0 .. ms * 48], in[0 .. ms * khz]);
            try testing.expectEqual(@as(i16, 0x4242), out[ms * 48]);
        }
    }
}
