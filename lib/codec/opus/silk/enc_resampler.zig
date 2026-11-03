//! Down sampling of the SILK encoder input, ported from libopus silk/resampler.c,
//! resampler_private_down_FIR.c, resampler_private_AR2.c, resampler_down2.c and
//! resampler_down2_3.c. libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");
const m = @import("macros.zig");
const enc_tables = @import("enc_tables.zig");

const fir_order = 36;
const max_batch_in = 480;
const api_khz = 48;

/// A second order AR filter with the output in Q8.
fn ar2(s: *[2]i32, out_q8: []i32, in: []const i16, a_q14: []const i16) void {
    for (in, out_q8) |sample, *o| {
        var out32 = s[0] +% (@as(i32, sample) << 8);
        o.* = out32;
        out32 = out32 << 2;
        s[0] = m.smlawb(s[1], out32, a_q14[0]);
        s[1] = m.smulwb(out32, a_q14[1]);
    }
}

const coefs_3_4 = [29]i16{
    -20694, -13867,
    -49,    64,
    17,     -157,
    353,    -496,
    163,    11047,
    22205,  -39,
    6,      91,
    -170,   186,
    23,     -896,
    6336,   19928,
    -19,    -36,
    102,    -89,
    -24,    328,
    -951,   2568,
    15909,
};
const coefs_2_3 = [20]i16{
    -14457, -14019,
    64,     128,
    -122,   36,
    310,    -768,
    584,    9267,
    17733,  12,
    128,    18,
    -142,   288,
    -117,   -865,
    4123,   14459,
};
const coefs_1_2 = [14]i16{ 616, -14323, -10, 39, 58, -46, -84, 120, 184, -315, -541, 1284, 5380, 9024 };

/// The delay in input samples that equalises the total delay of the modes, by input rate (8, 12,
/// 16, 24, 48 kHz) and output rate (8, 12, 16 kHz).
const delay_matrix = [5][3]usize{
    .{ 6, 0, 3 },
    .{ 0, 7, 3 },
    .{ 0, 1, 10 },
    .{ 0, 2, 6 },
    .{ 18, 10, 12 },
};

fn rateIndex(khz: i32) usize {
    return switch (khz) {
        8 => 0,
        12 => 1,
        16 => 2,
        24 => 3,
        else => 4,
    };
}

/// The rates of the SILK input resampler: from the sampling rate of the caller (8, 12, 16, 24 or
/// 48 kHz) down to the internal rate (8, 12 or 16 kHz). The same rate is a copy.
pub fn validRates(in_khz: i32, out_khz: i32) bool {
    const in_ok = in_khz == 8 or in_khz == 12 or in_khz == 16 or in_khz == 24 or in_khz == 48;
    const out_ok = out_khz == 8 or out_khz == 12 or out_khz == 16;
    return in_ok and out_ok and out_khz <= in_khz;
}

/// Converts the input to the internal rate with an AR2 filter followed by a FIR filter.
pub const DownResampler = struct {
    s_iir: [2]i32 = @splat(0),
    s_fir: [fir_order]i32 = @splat(0),
    delay_buf: [api_khz]i16 = @splat(0),
    in_khz: usize = 48,
    fs_out_khz: i32 = 16,
    input_delay: usize = 12,
    inv_ratio_q16: i32 = 196608,
    copy: bool = false,
    fracs: i32 = 1,
    order: usize = 36,
    coefs: []const i16 = &enc_tables.resampler_1_3_coefs,

    /// A cleared resampler from `in_khz` to `fs_out_khz`. Both come from `validRates`.
    pub fn init(in_khz: i32, fs_out_khz: i32) DownResampler {
        std.debug.assert(validRates(in_khz, fs_out_khz));
        var self: DownResampler = .{ .in_khz = @intCast(in_khz), .fs_out_khz = fs_out_khz };
        self.input_delay = delay_matrix[rateIndex(in_khz)][rateIndex(fs_out_khz)];
        const fs_in = in_khz * 1000;
        const fs_out = fs_out_khz * 1000;
        if (fs_in == fs_out) {
            self.copy = true;
        } else if (fs_out * 4 == fs_in * 3) {
            self.fracs = 3;
            self.order = 18;
            self.coefs = &coefs_3_4;
        } else if (fs_out * 3 == fs_in * 2) {
            self.fracs = 2;
            self.order = 18;
            self.coefs = &coefs_2_3;
        } else if (fs_out * 2 == fs_in) {
            self.order = 24;
            self.coefs = &coefs_1_2;
        } else if (fs_out * 3 == fs_in) {
            self.coefs = &enc_tables.resampler_1_3_coefs;
        } else if (fs_out * 4 == fs_in) {
            self.coefs = &enc_tables.resampler_1_4_coefs;
        } else {
            self.coefs = &enc_tables.resampler_1_6_coefs;
        }
        self.inv_ratio_q16 = m.div32(fs_in << 14, fs_out) << 2;
        while (m.smulww(self.inv_ratio_q16, fs_out) < fs_in) self.inv_ratio_q16 += 1;
        return self;
    }

    /// Resamples `in`, which holds at least one millisecond, to `out`.
    pub fn process(self: *DownResampler, out: []i16, in: []const i16) void {
        const khz = self.in_khz;
        std.debug.assert(in.len >= khz);
        const n = khz - self.input_delay;
        @memcpy(self.delay_buf[self.input_delay..khz], in[0..n]);
        const first = self.delay_buf;
        const out_khz: usize = @intCast(self.fs_out_khz);
        if (self.copy) {
            @memcpy(out[0..khz], first[0..khz]);
            @memcpy(out[out_khz..][0 .. in.len - khz], in[n..][0 .. in.len - khz]);
        } else {
            self.run(out[0..out_khz], first[0..khz]);
            self.run(out[out_khz..], in[n..][0 .. in.len - khz]);
        }
        @memcpy(self.delay_buf[0..self.input_delay], in[in.len - self.input_delay ..]);
    }

    fn run(self: *DownResampler, out_all: []i16, in_all: []const i16) void {
        var buf: [max_batch_in + fir_order]i32 = undefined;
        const order = self.order;
        @memcpy(buf[0..order], self.s_fir[0..order]);
        var in = in_all;
        var out = out_all;
        var n_in: usize = 0;
        const fir = self.coefs[2..];
        const batch = self.in_khz * 10;
        while (true) {
            n_in = @min(in.len, batch);
            ar2(&self.s_iir, buf[order..][0..n_in], in[0..n_in], self.coefs[0..2]);
            const max_index: i32 = @intCast(n_in << 16);
            var index: i32 = 0;
            var o: usize = 0;
            while (index < max_index) : (index +%= self.inv_ratio_q16) {
                const b = buf[@intCast(index >> 16)..];
                var res: i32 = undefined;
                switch (order) {
                    18 => {
                        const ind: usize = @intCast(m.smulwb(index & 0xFFFF, self.fracs));
                        const p = fir[9 * ind ..][0..9];
                        res = m.smulwb(b[0], p[0]);
                        inline for (1..9) |j| res = m.smlawb(res, b[j], p[j]);
                        const q = fir[9 * (@as(usize, @intCast(self.fracs)) - 1 - ind) ..][0..9];
                        inline for (0..9) |j| res = m.smlawb(res, b[17 - j], q[j]);
                    },
                    24 => {
                        res = m.smulwb(b[0] +% b[23], fir[0]);
                        inline for (1..12) |j| res = m.smlawb(res, b[j] +% b[23 - j], fir[j]);
                    },
                    else => {
                        res = m.smulwb(b[0] +% b[35], fir[0]);
                        inline for (1..18) |j| res = m.smlawb(res, b[j] +% b[35 - j], fir[j]);
                    },
                }
                out[o] = @intCast(m.sat16(m.rshiftRound(res, 6)));
                o += 1;
            }
            out = out[o..];
            in = in[n_in..];
            if (in.len > 1) {
                std.mem.copyForwards(i32, buf[0..order], buf[n_in..][0..order]);
            } else break;
        }
        @memcpy(self.s_fir[0..order], buf[n_in..][0..order]);
    }
};

/// Halves the sampling rate with two all-pass sections.
pub fn down2(s: *[2]i32, out: []i16, in: []const i16) void {
    const down2_0: i32 = 9872;
    const down2_1: i32 = 39809 - 65536;
    const len2 = in.len >> 1;
    for (0..len2) |k| {
        var in32 = @as(i32, in[2 * k]) << 10;
        var y = in32 -% s[0];
        var x = m.smlawb(y, y, down2_1);
        var out32 = s[0] +% x;
        s[0] = in32 +% x;
        in32 = @as(i32, in[2 * k + 1]) << 10;
        y = in32 -% s[1];
        x = m.smulwb(y, down2_0);
        out32 = out32 +% s[1];
        out32 = out32 +% x;
        s[1] = in32 +% x;
        out[k] = @intCast(m.sat16(m.rshiftRound(out32, 11)));
    }
}

/// Reduces the sampling rate by 2/3 with low quality.
pub fn down2_3(s: *[6]i32, out_all: []i16, in_all: []const i16) void {
    const c = &enc_tables.resampler_2_3_coefs_lq;
    var buf: [max_batch_in + 4]i32 = undefined;
    @memcpy(buf[0..4], s[0..4]);
    var in = in_all;
    var out = out_all;
    var n_in: usize = 0;
    while (true) {
        n_in = @min(in.len, max_batch_in);
        ar2(s[4..6], buf[4..][0..n_in], in[0..n_in], c[0..2]);
        var p: usize = 0;
        var counter: i32 = @intCast(n_in);
        while (counter > 2) {
            var res = m.smulwb(buf[p], c[2]);
            res = m.smlawb(res, buf[p + 1], c[3]);
            res = m.smlawb(res, buf[p + 2], c[5]);
            res = m.smlawb(res, buf[p + 3], c[4]);
            out[0] = @intCast(m.sat16(m.rshiftRound(res, 6)));
            res = m.smulwb(buf[p + 1], c[4]);
            res = m.smlawb(res, buf[p + 2], c[5]);
            res = m.smlawb(res, buf[p + 3], c[3]);
            res = m.smlawb(res, buf[p + 4], c[2]);
            out[1] = @intCast(m.sat16(m.rshiftRound(res, 6)));
            out = out[2..];
            p += 3;
            counter -= 3;
        }
        in = in[n_in..];
        if (in.len > 0) {
            std.mem.copyForwards(i32, buf[0..4], buf[n_in..][0..4]);
        } else break;
    }
    @memcpy(s[0..4], buf[n_in..][0..4]);
}

const testing = std.testing;

test "the down sampler gives one output sample per ratio input samples" {
    for ([_]i32{ 8, 12, 16 }) |khz| {
        var r = DownResampler.init(48, khz);
        var in: [960]i16 = undefined;
        for (&in, 0..) |*v, i| v.* = @intCast(@as(i32, @intCast(i % 64)) * 200 - 6400);
        const n: usize = @intCast(20 * khz);
        var out: [321]i16 = @splat(0x4242);
        r.process(out[0..n], &in);
        try testing.expectEqual(@as(i16, 0x4242), out[n]);
    }
}

test "the down sampler keeps a constant signal constant" {
    var r = DownResampler.init(48, 16);
    var in: [960]i16 = @splat(1000);
    var out: [320]i16 = undefined;
    r.process(&out, &in);
    r.process(&out, &in);
    for (out[40..]) |v| try testing.expect(@abs(@as(i32, v) - 1000) < 30);
}

test "down2 and down2_3 keep a constant signal constant" {
    var s2: [2]i32 = @splat(0);
    var in: [320]i16 = @splat(2000);
    var out: [160]i16 = undefined;
    down2(&s2, &out, &in);
    for (out[20..]) |v| try testing.expect(@abs(@as(i32, v) - 2000) < 60);
    var s3: [6]i32 = @splat(0);
    var in3: [240]i16 = @splat(2000);
    var out3: [160]i16 = undefined;
    down2_3(&s3, &out3, &in3);
    for (out3[20..]) |v| try testing.expect(@abs(@as(i32, v) - 2000) < 120);
}
