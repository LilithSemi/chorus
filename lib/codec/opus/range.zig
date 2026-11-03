//! Range coder ported from libopus celt/entenc.c, entdec.c, entcode.c and laplace.c.
//! libopus is BSD 3 clause, see LICENSE-libopus.
const std = @import("std");

const sym_bits = 8;
const sym_max = 255;
const code_top: u32 = 0x8000_0000;
const code_bot: u32 = code_top >> sym_bits;
const code_shift = 23;
const uint_bits = 8;
const window_size = 32;
const max_raw_bits = 25;

/// The bits that a value needs. 0 for 0.
pub fn ilog(x: u32) i32 {
    return 32 - @as(i32, @clz(x));
}

fn tellOf(nbits_total: i32, rng: u32) i32 {
    return nbits_total - ilog(rng);
}

/// The bits used, in eighths.
fn tellFracOf(nbits_total: i32, rng: u32) u32 {
    const correction = [8]u32{ 35733, 38967, 42495, 46340, 50535, 55109, 60097, 65535 };
    const nbits = nbits_total << 3;
    const l = ilog(rng);
    const r = rng >> @intCast(l - 16);
    var b = (r >> 12) - 8;
    b += @intFromBool(r > correction[b]);
    return @intCast(nbits - (l * 8 + @as(i32, @intCast(b))));
}

pub const Decoder = struct {
    buf: []const u8,
    /// The bytes that the decoder reads. Use `shrink` to lower it.
    storage: u32,
    end_offs: u32,
    end_window: u32,
    nend_bits: i32,
    nbits_total: i32,
    offs: u32,
    rng: u32,
    val: u32,
    ext: u32,
    rem: u32,
    /// Set when a uniform integer decoded above its range.
    err: bool,

    pub fn init(buf: []const u8) Decoder {
        var self: Decoder = .{
            .buf = buf,
            .storage = @intCast(@min(buf.len, std.math.maxInt(u32))),
            .end_offs = 0,
            .end_window = 0,
            .nend_bits = 0,
            .nbits_total = 9,
            .offs = 0,
            .rng = 128,
            .val = 0,
            .ext = 0,
            .rem = 0,
            .err = false,
        };
        self.rem = self.readByte();
        self.val = self.rng - 1 - (self.rem >> 1);
        self.normalize();
        return self;
    }

    fn readByte(self: *Decoder) u32 {
        if (self.offs >= self.storage) return 0;
        defer self.offs += 1;
        return self.buf[self.offs];
    }

    fn readByteFromEnd(self: *Decoder) u32 {
        if (self.end_offs >= self.storage) return 0;
        self.end_offs += 1;
        return self.buf[self.storage - self.end_offs];
    }

    fn normalize(self: *Decoder) void {
        while (self.rng <= code_bot) {
            self.nbits_total += sym_bits;
            self.rng <<= sym_bits;
            var sym = self.rem;
            self.rem = self.readByte();
            sym = ((sym << sym_bits) | self.rem) >> 1;
            self.val = ((self.val << sym_bits) +% (sym_max & ~sym)) & (code_top - 1);
        }
    }

    /// Cuts off trailing data. `size` is at most the buffer length.
    pub fn shrink(self: *Decoder, size: u32) void {
        std.debug.assert(size <= self.buf.len);
        self.storage = size;
    }

    /// The symbol position in `[0, ft)`. Call `update` right after.
    pub fn decode(self: *Decoder, ft: u32) u32 {
        std.debug.assert(ft != 0 and ft <= 1 << 23);
        self.ext = self.rng / ft;
        const s = self.val / self.ext;
        return ft - @min(s + 1, ft);
    }

    /// `decode` for a total of `1 << nbits`.
    pub fn decodeBin(self: *Decoder, nbits: u5) u32 {
        std.debug.assert(nbits <= 23);
        self.ext = self.rng >> nbits;
        const s = self.val / self.ext;
        const ft = @as(u32, 1) << nbits;
        return ft - @min(s + 1, ft);
    }

    pub fn update(self: *Decoder, fl: u32, fh: u32, ft: u32) void {
        std.debug.assert(fl < fh and fh <= ft);
        const s = self.ext *% (ft - fh);
        self.val -%= s;
        self.rng = if (fl > 0) self.ext *% (fh - fl) else self.rng -% s;
        self.normalize();
    }

    /// A bit with probability `1 / 2^logp` of being set.
    pub fn bitLogp(self: *Decoder, logp: u5) bool {
        std.debug.assert(logp >= 1);
        const s = self.rng >> logp;
        const set = self.val < s;
        if (!set) self.val -%= s;
        self.rng = if (set) s else self.rng -% s;
        self.normalize();
        return set;
    }

    /// A symbol from an inverse cumulative table with `ftb` bits of precision.
    /// The table decreases and ends with 0.
    pub fn icdf(self: *Decoder, table: []const u8, ftb: u5) u32 {
        var s = self.rng;
        const d = self.val;
        const r = s >> ftb;
        var t = s;
        var k: u32 = 0;
        while (true) : (k += 1) {
            t = s;
            s = r *% table[k];
            if (d >= s) break;
        }
        self.val = d -% s;
        self.rng = t -% s;
        self.normalize();
        return k;
    }

    /// An integer in `[0, ft)` for `ft > 1`. The high 8 bits are range coded and the
    /// rest are raw bits. A value out of range sets `err` and gives `ft - 1`.
    pub fn uint(self: *Decoder, ft_in: u32) u32 {
        std.debug.assert(ft_in > 1);
        const ft = ft_in - 1;
        const ftb = ilog(ft);
        if (ftb > uint_bits) {
            const shift: u5 = @intCast(ftb - uint_bits);
            const ft1 = (ft >> shift) + 1;
            const s = self.decode(ft1);
            self.update(s, s + 1, ft1);
            const t = (s << shift) | self.bits(shift);
            if (t <= ft) return t;
            self.err = true;
            return ft;
        }
        const s = self.decode(ft + 1);
        self.update(s, s + 1, ft + 1);
        return s;
    }

    /// Raw bits from the end of the buffer. `n` is 1 to 25.
    pub fn bits(self: *Decoder, n: u5) u32 {
        std.debug.assert(n >= 1 and n <= max_raw_bits);
        var window = self.end_window;
        var available = self.nend_bits;
        if (available < n) {
            while (true) {
                window |= self.readByteFromEnd() << @intCast(available);
                available += 8;
                if (available > window_size - 8) break;
            }
        }
        const ret = window & ((@as(u32, 1) << n) - 1);
        window >>= n;
        available -= n;
        self.end_window = window;
        self.nend_bits = available;
        self.nbits_total += n;
        return ret;
    }

    /// The whole bits used.
    pub fn tell(self: *const Decoder) i32 {
        return tellOf(self.nbits_total, self.rng);
    }

    /// The bits used, in eighths.
    pub fn tellFrac(self: *const Decoder) u32 {
        return tellFracOf(self.nbits_total, self.rng);
    }

    pub fn finalRange(self: *const Decoder) u32 {
        return self.rng;
    }
};

pub const Encoder = struct {
    buf: []u8,
    storage: u32,
    end_offs: u32,
    end_window: u32,
    nend_bits: i32,
    nbits_total: i32,
    offs: u32,
    rng: u32,
    val: u32,
    /// Buffered 0xff bytes that wait for a carry.
    ext: u32,
    /// The byte that waits for a carry, or -1.
    rem: i32,
    /// Set when the range bytes and the raw bytes met.
    err: bool,

    pub fn init(buf: []u8) Encoder {
        return .{
            .buf = buf,
            .storage = @intCast(@min(buf.len, std.math.maxInt(u32))),
            .end_offs = 0,
            .end_window = 0,
            .nend_bits = 0,
            .nbits_total = 33,
            .offs = 0,
            .rng = code_top,
            .val = 0,
            .ext = 0,
            .rem = -1,
            .err = false,
        };
    }

    /// Returns true when the buffer is full.
    fn writeByte(self: *Encoder, value: u32) bool {
        if (self.offs + self.end_offs >= self.storage) return true;
        self.buf[self.offs] = @truncate(value);
        self.offs += 1;
        return false;
    }

    fn writeByteAtEnd(self: *Encoder, value: u32) bool {
        if (self.offs + self.end_offs >= self.storage) return true;
        self.end_offs += 1;
        self.buf[self.storage - self.end_offs] = @truncate(value);
        return false;
    }

    fn carryOut(self: *Encoder, c: u32) void {
        if (c != sym_max) {
            const carry = c >> sym_bits;
            if (self.rem >= 0) {
                if (self.writeByte(@as(u32, @intCast(self.rem)) + carry)) self.err = true;
            }
            if (self.ext > 0) {
                const sym = (sym_max + carry) & sym_max;
                while (self.ext > 0) : (self.ext -= 1) {
                    if (self.writeByte(sym)) self.err = true;
                }
            }
            self.rem = @intCast(c & sym_max);
        } else {
            self.ext += 1;
        }
    }

    fn normalize(self: *Encoder) void {
        while (self.rng <= code_bot) {
            self.carryOut(self.val >> code_shift);
            self.val = (self.val << sym_bits) & (code_top - 1);
            self.rng <<= sym_bits;
            self.nbits_total += sym_bits;
        }
    }

    /// Codes the symbol with the cumulative frequencies `fl` and `fh` of `ft`.
    pub fn encode(self: *Encoder, fl: u32, fh: u32, ft: u32) void {
        std.debug.assert(fl < fh and fh <= ft);
        const r = self.rng / ft;
        if (fl > 0) {
            self.val += self.rng - r * (ft - fl);
            self.rng = r * (fh - fl);
        } else {
            self.rng -= r * (ft - fh);
        }
        self.normalize();
    }

    /// `encode` for a total of `1 << nbits`.
    pub fn encodeBin(self: *Encoder, fl: u32, fh: u32, nbits: u5) void {
        const ft = @as(u32, 1) << nbits;
        std.debug.assert(fl < fh and fh <= ft);
        const r = self.rng >> nbits;
        if (fl > 0) {
            self.val += self.rng - r * (ft - fl);
            self.rng = r * (fh - fl);
        } else {
            self.rng -= r * (ft - fh);
        }
        self.normalize();
    }

    pub fn encodeBitLogp(self: *Encoder, set: bool, logp: u5) void {
        const s = self.rng >> logp;
        const r = self.rng - s;
        if (set) self.val += r;
        self.rng = if (set) s else r;
        self.normalize();
    }

    pub fn encodeIcdf(self: *Encoder, k: u32, table: []const u8, ftb: u5) void {
        const r = self.rng >> ftb;
        if (k > 0) {
            self.val += self.rng - r * table[k - 1];
            self.rng = r * (table[k - 1] - table[k]);
        } else {
            self.rng -= r * table[k];
        }
        self.normalize();
    }

    pub fn encodeUint(self: *Encoder, fl: u32, ft_in: u32) void {
        std.debug.assert(ft_in > 1 and fl < ft_in);
        const ft = ft_in - 1;
        const ftb = ilog(ft);
        if (ftb > uint_bits) {
            const shift: u5 = @intCast(ftb - uint_bits);
            const hi = fl >> shift;
            self.encode(hi, hi + 1, (ft >> shift) + 1);
            self.encodeBits(fl & ((@as(u32, 1) << shift) - 1), shift);
        } else {
            self.encode(fl, fl + 1, ft + 1);
        }
    }

    /// Raw bits for the end of the buffer. `n` is 1 to 25 and `fl` fits in `n` bits.
    pub fn encodeBits(self: *Encoder, fl: u32, n: u5) void {
        std.debug.assert(n >= 1 and n <= max_raw_bits and fl >> n == 0);
        var window = self.end_window;
        var used = self.nend_bits;
        if (used + n > window_size) {
            while (true) {
                if (self.writeByteAtEnd(window & sym_max)) self.err = true;
                window >>= sym_bits;
                used -= sym_bits;
                if (used < sym_bits) break;
            }
        }
        window |= fl << @intCast(used);
        used += n;
        self.end_window = window;
        self.nend_bits = used;
        self.nbits_total += n;
    }

    /// Overwrites the first `n` bits of the stream, `n` at most 8. Sets `err` when too
    /// little is encoded to hold them.
    pub fn patchInitialBits(self: *Encoder, value: u32, n: u4) void {
        std.debug.assert(n >= 1 and n <= sym_bits and value >> n == 0);
        const shift: u3 = @intCast(sym_bits - @as(u32, n));
        const mask: u32 = ((@as(u32, 1) << n) - 1) << shift;
        if (self.offs > 0) {
            self.buf[0] = @truncate((@as(u32, self.buf[0]) & ~mask) | value << shift);
        } else if (self.rem >= 0) {
            const rem: u32 = @intCast(self.rem);
            self.rem = @intCast((rem & ~mask) | value << shift);
        } else if (self.rng <= code_top >> n) {
            self.val = (self.val & ~(mask << code_shift)) | value << (code_shift + @as(u5, shift));
        } else {
            self.err = true;
        }
    }

    /// Cuts the buffer to `size` bytes and moves the raw bytes to the new end.
    pub fn shrink(self: *Encoder, size: u32) void {
        std.debug.assert(self.offs + self.end_offs <= size and size <= self.storage);
        const dst = self.buf[size - self.end_offs ..][0..self.end_offs];
        const src = self.buf[self.storage - self.end_offs ..][0..self.end_offs];
        std.mem.copyForwards(u8, dst, src);
        self.storage = size;
    }

    /// Flushes the coder. The bytes of the packet are `buf[0..storage]`.
    pub fn done(self: *Encoder) void {
        var l: i32 = 32 - ilog(self.rng);
        var msk: u32 = (code_top - 1) >> @intCast(l);
        var end = (self.val +% msk) & ~msk;
        if ((end | msk) >= self.val +% self.rng) {
            l += 1;
            msk >>= 1;
            end = (self.val +% msk) & ~msk;
        }
        while (l > 0) {
            self.carryOut(end >> code_shift);
            end = (end << sym_bits) & (code_top - 1);
            l -= sym_bits;
        }
        if (self.rem >= 0 or self.ext > 0) self.carryOut(0);
        var window = self.end_window;
        var used = self.nend_bits;
        while (used >= sym_bits) {
            if (self.writeByteAtEnd(window & sym_max)) self.err = true;
            window >>= sym_bits;
            used -= sym_bits;
        }
        if (self.err) return;
        @memset(self.buf[self.offs .. self.storage - self.end_offs], 0);
        if (used > 0) {
            if (self.end_offs >= self.storage) {
                self.err = true;
            } else {
                l = -l;
                if (self.offs + self.end_offs >= self.storage and l < used) {
                    window &= (@as(u32, 1) << @intCast(l)) - 1;
                    self.err = true;
                }
                self.buf[self.storage - self.end_offs - 1] |= @truncate(window);
            }
        }
    }

    /// The whole bits used.
    pub fn tell(self: *const Encoder) i32 {
        return tellOf(self.nbits_total, self.rng);
    }

    /// The bits used, in eighths.
    pub fn tellFrac(self: *const Encoder) u32 {
        return tellFracOf(self.nbits_total, self.rng);
    }

    pub fn finalRange(self: *const Encoder) u32 {
        return self.rng;
    }
};

const laplace_min_p = 1;
const laplace_n_min = 16;

fn laplaceFreq1(fs0: u32, decay: i32) u32 {
    const ft = 32768 - laplace_min_p * (2 * laplace_n_min) - fs0;
    return (ft * @as(u32, @intCast(16384 - decay))) >> 15;
}

/// Codes a coarse energy residual. `fs` is the probability of 0 in Q15 and `decay` is in Q14
/// and at most 11456. A value that does not fit is cut, and `value` holds the coded value.
pub fn laplaceEncode(enc: *Encoder, value: *i32, fs_in: u32, decay: i32) void {
    var fs = fs_in;
    var val = value.*;
    var fl: u32 = 0;
    if (val != 0) {
        const s: i32 = -@as(i32, @intFromBool(val < 0));
        val = (val + s) ^ s;
        fl = fs;
        fs = laplaceFreq1(fs, decay);
        var i: i32 = 1;
        while (fs > 0 and i < val) : (i += 1) {
            fs *= 2;
            fl += fs + 2 * laplace_min_p;
            fs = (fs * @as(u32, @intCast(decay))) >> 15;
        }
        if (fs == 0) {
            var ndi_max: i32 = @intCast((32768 - fl + laplace_min_p - 1) >> 0);
            ndi_max = (ndi_max - s) >> 1;
            const di = @min(val - i, ndi_max - 1);
            fl += @as(u32, @bitCast((2 * di + 1 + s) * laplace_min_p));
            fs = @min(laplace_min_p, 32768 - fl);
            value.* = (i + di + s) ^ s;
        } else {
            fs += laplace_min_p;
            fl += fs & ~@as(u32, @bitCast(s));
        }
        std.debug.assert(fl + fs <= 32768 and fs > 0);
    }
    enc.encodeBin(fl, fl + fs, 15);
}

pub fn laplaceDecode(dec: *Decoder, fs_in: u32, decay: i32) i32 {
    var fs = fs_in;
    var val: i32 = 0;
    var fl: u32 = 0;
    const fm = dec.decodeBin(15);
    if (fm >= fs) {
        val += 1;
        fl = fs;
        fs = laplaceFreq1(fs, decay) + laplace_min_p;
        while (fs > laplace_min_p and fm >= fl + 2 * fs) {
            fs *= 2;
            fl += fs;
            fs = ((fs - 2 * laplace_min_p) * @as(u32, @intCast(decay))) >> 15;
            fs += laplace_min_p;
            val += 1;
        }
        if (fs <= laplace_min_p) {
            const di: u32 = (fm - fl) >> 1;
            val += @intCast(di);
            fl += 2 * di * laplace_min_p;
        }
        if (fm < fl + fs) {
            val = -val;
        } else {
            fl += fs;
        }
    }
    dec.update(fl, @min(fl + fs, 32768), 32768);
    return val;
}

const testing = std.testing;
const Xorshift = @import("test_util.zig").Xorshift;

const Op = struct { kind: u8, a: u32 = 0, b: u32 = 0, c: u32 = 0, d: u32 = 0, v: i32 = 0 };
const script_icdf = [_]u8{ 200, 150, 100, 50, 20, 0 };

fn genScript(ops: []Op, seed: u32) void {
    var x: Xorshift = .{ .s = seed };
    for (ops) |*o| {
        o.* = .{ .kind = @intCast(x.next() % 7) };
        switch (o.kind) {
            0 => {
                o.c = 2 + x.next() % 1000;
                o.a = x.next() % o.c;
                o.b = o.a + 1 + x.next() % (o.c - o.a);
            },
            1 => {
                o.d = 1 + x.next() % 15;
                o.c = @as(u32, 1) << @intCast(o.d);
                o.a = x.next() % o.c;
                o.b = o.a + 1 + x.next() % (o.c - o.a);
            },
            2 => {
                o.d = 1 + x.next() % 15;
                o.v = @intFromBool(x.next() % 3 == 0);
            },
            3 => o.v = @intCast(x.next() % 6),
            4 => {
                o.c = 2 + x.next() % 100000;
                o.a = x.next() % o.c;
            },
            5 => {
                o.d = 1 + x.next() % 16;
                o.a = x.next() & ((@as(u32, 1) << @intCast(o.d)) - 1);
            },
            6 => {
                o.a = (1 + x.next() % 100) << 7;
                o.d = 1000 + x.next() % 10000;
                o.v = @as(i32, @intCast(x.next() % 21)) - 10;
            },
            else => unreachable,
        }
    }
}

fn encodeOp(enc: *Encoder, o: *Op) void {
    switch (o.kind) {
        0 => enc.encode(o.a, o.b, o.c),
        1 => enc.encodeBin(o.a, o.b, @intCast(o.d)),
        2 => enc.encodeBitLogp(o.v != 0, @intCast(o.d)),
        3 => enc.encodeIcdf(@intCast(o.v), &script_icdf, 8),
        4 => enc.encodeUint(o.a, o.c),
        5 => enc.encodeBits(o.a, @intCast(o.d)),
        6 => laplaceEncode(enc, &o.v, o.a, @intCast(o.d)),
        else => unreachable,
    }
}

/// Decodes one operation and reports whether it gave the encoded symbol.
fn decodeOp(dec: *Decoder, o: *const Op) bool {
    switch (o.kind) {
        0 => {
            const fm = dec.decode(o.c);
            dec.update(o.a, o.b, o.c);
            return fm >= o.a and fm < o.b;
        },
        1 => {
            const fm = dec.decodeBin(@intCast(o.d));
            dec.update(o.a, o.b, o.c);
            return fm >= o.a and fm < o.b;
        },
        2 => return dec.bitLogp(@intCast(o.d)) == (o.v != 0),
        3 => return dec.icdf(&script_icdf, 8) == o.v,
        4 => return dec.uint(o.c) == o.a,
        5 => return dec.bits(@intCast(o.d)) == o.a,
        6 => return laplaceDecode(dec, o.a, @intCast(o.d)) == o.v,
        else => unreachable,
    }
}

const Fixed = struct {
    seed: u32,
    n: usize,
    shrink: bool,
    size: usize,
    rng: u32,
    tell: i32,
    tell_frac: u32,
    head: []const u8,
    tail: []const u8,
};

// Produced by a C program over libopus 1.6.1 entenc.c, entdec.c and laplace.c.
const fixed = [_]Fixed{
    .{
        .seed = 1,
        .n = 40,
        .shrink = false,
        .size = 200,
        .rng = 14080950,
        .tell = 212,
        .tell_frac = 1691,
        .head = &.{ 0x62, 0x93, 0xf7, 0x0a, 0xc1, 0xd0, 0xec, 0x98, 0x38, 0x8b, 0x44, 0xac, 0x16, 0x8d, 0xa0, 0xc8, 0xe5, 0x3e, 0xbf },
        .tail = &.{ 0x04, 0x76, 0x79, 0x8b, 0x4c, 0x0e, 0xae, 0xbb },
    },
    .{
        .seed = 7,
        .n = 60,
        .shrink = false,
        .size = 200,
        .rng = 14427936,
        .tell = 392,
        .tell_frac = 3130,
        .head = &.{ 0x36, 0x79, 0xe7, 0x89, 0xf4, 0xf1, 0x60, 0xa3, 0x59, 0x0f, 0x50, 0x30, 0xba, 0x39, 0xd9, 0x33, 0x76, 0x23, 0x0e, 0x71, 0x99, 0xaf, 0xe8, 0x9f, 0x41, 0xe5, 0x10, 0x2d, 0xe9, 0x52, 0x80 },
        .tail = &.{ 0x1c, 0x5a, 0x0e, 0x68, 0xe2, 0x4f, 0x2f, 0xb5, 0x88, 0x90, 0x83, 0x9b, 0x1d, 0x27, 0xff, 0x38, 0xbf, 0xf5, 0x25 },
    },
    .{
        .seed = 99,
        .n = 50,
        .shrink = true,
        .size = 150,
        .rng = 41887744,
        .tell = 319,
        .tell_frac = 2550,
        .head = &.{ 0xa0, 0x5b, 0xa5, 0x4c, 0xc2, 0x18, 0xea, 0xce, 0x26, 0x15, 0xbe, 0x4e, 0x18, 0x21, 0x7b, 0x9a, 0xfa, 0x76, 0x43, 0x2d, 0xe4, 0xe3, 0x79, 0xec },
        .tail = &.{ 0x00, 0x22, 0x1c, 0x8f, 0xb7, 0x5a, 0x04, 0x8b, 0x78, 0x64, 0xcb, 0xd2, 0x38, 0x41, 0xe0, 0x4f, 0x5c },
    },
};

test "encoder output equals libopus byte for byte" {
    var ops: [64]Op = undefined;
    for (fixed) |f| {
        genScript(ops[0..f.n], f.seed);
        var buf: [200]u8 = @splat(0xaa);
        var enc: Encoder = .init(&buf);
        for (ops[0..f.n], 0..) |*o, i| {
            encodeOp(&enc, o);
            if (f.shrink and i == f.n / 2) enc.shrink(150);
        }
        if (f.shrink) enc.patchInitialBits(5, 3);
        try testing.expectEqual(f.rng, enc.finalRange());
        try testing.expectEqual(f.tell, enc.tell());
        try testing.expectEqual(f.tell_frac, enc.tellFrac());
        enc.done();
        try testing.expect(!enc.err);
        try testing.expectEqual(f.head.len, enc.offs);
        try testing.expectEqual(f.tail.len - 1, enc.end_offs);
        try testing.expectEqualSlices(u8, f.head, buf[0..f.head.len]);
        try testing.expectEqualSlices(u8, f.tail, buf[f.size - f.tail.len .. f.size]);
        for (buf[f.head.len .. f.size - f.tail.len]) |byte| try testing.expectEqual(@as(u8, 0), byte);
        if (!f.shrink) {
            var dec: Decoder = .init(buf[0..f.size]);
            for (ops[0..f.n]) |*o| try testing.expect(decodeOp(&dec, o));
            try testing.expectEqual(f.rng, dec.finalRange());
            try testing.expectEqual(f.tell, dec.tell());
            try testing.expectEqual(f.tell_frac, dec.tellFrac());
        }
    }
}

test "fresh coders report one bit and eight eighth bits" {
    var buf: [4]u8 = @splat(0);
    const enc: Encoder = .init(&buf);
    try testing.expectEqual(@as(i32, 1), enc.tell());
    try testing.expectEqual(@as(u32, 8), enc.tellFrac());
    try testing.expectEqual(@as(u32, 1) << 31, enc.finalRange());
    const dec: Decoder = .init(&buf);
    try testing.expectEqual(@as(i32, 1), dec.tell());
    try testing.expectEqual(@as(u32, 8), dec.tellFrac());
    try testing.expectEqual(@as(u32, 1) << 31, dec.finalRange());
}

test "random symbol streams decode to the same symbols and final range" {
    var ops: [200]Op = undefined;
    var prng: std.Random.DefaultPrng = .init(0x6563);
    const rand = prng.random();
    for (0..400) |_| {
        const n = rand.intRangeAtMost(usize, 1, ops.len);
        genScript(ops[0..n], rand.int(u32) | 1);
        var buf: [1200]u8 = undefined;
        var enc: Encoder = .init(&buf);
        for (ops[0..n]) |*o| encodeOp(&enc, o);
        const rng = enc.finalRange();
        const tell = enc.tell();
        const frac = enc.tellFrac();
        enc.done();
        try testing.expect(!enc.err);
        var dec: Decoder = .init(&buf);
        for (ops[0..n]) |*o| try testing.expect(decodeOp(&dec, o));
        try testing.expect(!dec.err);
        try testing.expectEqual(rng, dec.finalRange());
        try testing.expectEqual(tell, dec.tell());
        try testing.expectEqual(frac, dec.tellFrac());
    }
}

test "uniform integers at the range edges" {
    const fts = [_]u32{ 2, 3, 255, 256, 257, 258, 1000, 65536, 65537, 1 << 24, (1 << 24) + 1, 0x7fffffff, 0xffffffff };
    var buf: [200]u8 = undefined;
    var enc: Encoder = .init(&buf);
    for (fts) |ft| {
        enc.encodeUint(0, ft);
        enc.encodeUint(ft - 1, ft);
        enc.encodeUint(ft / 2, ft);
    }
    enc.done();
    try testing.expect(!enc.err);
    var dec: Decoder = .init(&buf);
    for (fts) |ft| {
        try testing.expectEqual(@as(u32, 0), dec.uint(ft));
        try testing.expectEqual(ft - 1, dec.uint(ft));
        try testing.expectEqual(ft / 2, dec.uint(ft));
    }
    try testing.expect(!dec.err);
}

test "uniform integer above its range sets the error flag and clamps" {
    // The high part 128 of ft = 0x10001 with a raw part above zero gives 0x10001 + 0x1ff.
    var buf: [8]u8 = @splat(0);
    var enc: Encoder = .init(&buf);
    enc.encode(128, 129, 129);
    enc.encodeBits(1, 9);
    enc.done();
    var dec: Decoder = .init(&buf);
    try testing.expectEqual(@as(u32, 0x10000), dec.uint(0x10001));
    try testing.expect(dec.err);
}

test "raw bits come from the end, low bit first" {
    var buf: [8]u8 = @splat(0);
    var enc: Encoder = .init(&buf);
    enc.encodeBits(0b101, 3);
    enc.encodeBits(0x1ff, 9);
    enc.encodeBits(0, 1);
    enc.done();
    try testing.expect(!enc.err);
    // 13 bits: the last byte holds bits 0 to 7, the byte before it holds bits 8 to 12.
    try testing.expectEqual(@as(u8, 0b1111_1101), buf[7]);
    try testing.expectEqual(@as(u8, 0b0000_1111), buf[6] & 0x0f);
    var dec: Decoder = .init(&buf);
    try testing.expectEqual(@as(u32, 0b101), dec.bits(3));
    try testing.expectEqual(@as(u32, 0x1ff), dec.bits(9));
    try testing.expectEqual(@as(u32, 0), dec.bits(1));
}

test "reads past the end give zeros" {
    var dec: Decoder = .init(&.{});
    try testing.expectEqual(@as(u32, 0), dec.bits(25));
    try testing.expectEqual(@as(u32, 0), dec.decodeBin(8));
    dec.update(0, 1, 256);
    _ = dec.bitLogp(3);
    try testing.expect(!dec.err);
}

test "a full buffer sets the error flag" {
    var buf: [3]u8 = undefined;
    var enc: Encoder = .init(&buf);
    var x: Xorshift = .{ .s = 5 };
    for (0..40) |_| enc.encodeUint(x.next() % 5000, 5000);
    enc.done();
    try testing.expect(enc.err);
    var buf2: [2]u8 = undefined;
    var enc2: Encoder = .init(&buf2);
    enc2.encodeBits(0xffff, 16);
    enc2.encodeBits(0xffff, 16);
    enc2.done();
    try testing.expect(enc2.err);
}

fn laplaceCase(fs: u32, decay: i32, value: i32) !void {
    var buf: [64]u8 = undefined;
    var enc: Encoder = .init(&buf);
    var v = value;
    laplaceEncode(&enc, &v, fs, decay);
    enc.done();
    try testing.expect(!enc.err);
    var dec: Decoder = .init(&buf);
    try testing.expectEqual(v, laplaceDecode(&dec, fs, decay));
    // The coder only shrinks the magnitude, and keeps the sign.
    try testing.expect(@abs(v) <= @abs(value));
    if (v != 0) try testing.expectEqual(value < 0, v < 0);
}

test "laplace values round trip" {
    const params = [_][2]u32{ .{ 72 << 7, 6000 }, .{ 16 << 7, 11456 }, .{ 100 << 7, 1000 }, .{ 1 << 7, 11456 }, .{ 30000, 11456 }, .{ 17, 5000 } };
    for (params) |p| {
        var value: i32 = -60;
        while (value <= 60) : (value += 1) try laplaceCase(p[0], @intCast(p[1]), value);
    }
}

test "laplace values that do not fit lose magnitude" {
    // With a steep decay the tail holds only a few steps, so large values come back smaller.
    var buf: [64]u8 = undefined;
    var enc: Encoder = .init(&buf);
    var v: i32 = 400;
    laplaceEncode(&enc, &v, 72 << 7, 11456);
    try testing.expect(v < 400);
    try testing.expect(v > 0);
}

fn patched(prefix: u32, rem_expected: ?i32) !void {
    var buf: [32]u8 = undefined;
    var enc: Encoder = .init(&buf);
    for (0..prefix) |_| enc.encodeBitLogp(false, 1);
    enc.patchInitialBits(5, 3);
    try testing.expect(!enc.err);
    if (rem_expected) |r| try testing.expectEqual(r, enc.rem);
    enc.done();
    try testing.expect(!enc.err);
    try testing.expectEqual(@as(u8, 0b101), buf[0] >> 5);
}

test "patching the first bits works before, during and after the first byte" {
    // After 40 bits the first bytes are written, after 8 one byte waits for a carry,
    // and after 3 the coder has not shifted anything out yet.
    try patched(40, null);
    try patched(8, 0b1010_0000);
    try patched(3, null);
}

test "patching before enough is encoded sets the error flag" {
    var buf: [8]u8 = undefined;
    var enc: Encoder = .init(&buf);
    enc.encodeBitLogp(false, 1);
    enc.patchInitialBits(1, 8);
    try testing.expect(enc.err);
}

test "a decoder on random bytes never panics" {
    var prng: std.Random.DefaultPrng = .init(0x6563_6465);
    const rand = prng.random();
    var ops: [64]Op = undefined;
    for (0..2000) |_| {
        var buf: [48]u8 = undefined;
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        rand.bytes(buf[0..len]);
        var dec: Decoder = .init(buf[0..len]);
        genScript(&ops, rand.int(u32) | 1);
        for (&ops) |*o| {
            switch (o.kind) {
                0 => {
                    const fm = dec.decode(o.c);
                    dec.update(fm, fm + 1, o.c);
                },
                1 => {
                    const fm = dec.decodeBin(@intCast(o.d));
                    dec.update(fm, fm + 1, o.c);
                },
                2 => _ = dec.bitLogp(@intCast(o.d)),
                3 => _ = dec.icdf(&script_icdf, 8),
                4 => _ = dec.uint(o.c + (o.a << 8)),
                5 => _ = dec.bits(@intCast(o.d)),
                6 => _ = laplaceDecode(&dec, o.a, @intCast(o.d)),
                else => unreachable,
            }
        }
        try testing.expect(dec.tell() >= 1);
        _ = dec.tellFrac();
    }
}

const Tight = struct { seed: u32, size: usize, err: bool, bytes: []const u8 };

// From the same C program, with 12 operations in a buffer that is full or nearly full.
const tight = [_]Tight{
    .{ .seed = 3, .size = 4, .err = true, .bytes = &.{ 0xff, 0xef, 0xed, 0x5a } },
    .{ .seed = 3, .size = 12, .err = false, .bytes = &.{ 0xff, 0xef, 0xed, 0x5a, 0x0b, 0x7f, 0x5d, 0x0c, 0xf0, 0x00, 0x51, 0xa1 } },
    .{ .seed = 5, .size = 6, .err = true, .bytes = &.{ 0xff, 0x41, 0x68, 0x37, 0x68, 0x81 } },
    .{ .seed = 5, .size = 9, .err = false, .bytes = &.{ 0xff, 0x41, 0x68, 0x37, 0x68, 0x00, 0x0e, 0x8b, 0x81 } },
    .{ .seed = 21, .size = 9, .err = true, .bytes = &.{ 0xc0, 0x73, 0xd7, 0xfd, 0xee, 0xbe, 0x89, 0x79, 0x15 } },
    .{ .seed = 34, .size = 9, .err = true, .bytes = &.{ 0xe6, 0xa3, 0x2a, 0x2c, 0x1d, 0x9a, 0x55, 0xa8, 0x16 } },
    .{ .seed = 55, .size = 9, .err = false, .bytes = &.{ 0x31, 0xc8, 0x8e, 0xd4, 0x38, 0x96, 0xf3, 0xd4, 0xfb } },
    .{ .seed = 55, .size = 12, .err = false, .bytes = &.{ 0x31, 0xc8, 0x80, 0x00, 0x00, 0x0e, 0xd4, 0x38, 0x96, 0xf3, 0xd4, 0xfb } },
    // These end in the clipped last byte: the range bytes and the raw bytes fill the buffer.
    .{ .seed = 2, .size = 8, .err = true, .bytes = &.{ 0x1e, 0x68, 0xe3, 0x18, 0xa0, 0x16, 0x86, 0x64 } },
    .{ .seed = 3, .size = 10, .err = true, .bytes = &.{ 0xff, 0xef, 0xed, 0x5a, 0x0b, 0x7f, 0x5d, 0x0c, 0xf1, 0xa1 } },
    .{ .seed = 29, .size = 6, .err = true, .bytes = &.{ 0x32, 0x0f, 0x39, 0x53, 0x03, 0xdc } },
};

test "a nearly full buffer ends like libopus" {
    var ops: [12]Op = undefined;
    for (tight) |t| {
        genScript(&ops, t.seed);
        var buf: [16]u8 = @splat(0xaa);
        var enc: Encoder = .init(buf[0..t.size]);
        for (&ops) |*o| encodeOp(&enc, o);
        enc.done();
        try testing.expectEqual(t.err, enc.err);
        try testing.expectEqualSlices(u8, t.bytes, buf[0..t.size]);
        try testing.expectEqual(@as(u8, 0xaa), buf[t.size]);
    }
}

test "eighth bit counts match the iterative form of the specification" {
    var prng: std.Random.DefaultPrng = .init(0x7e11);
    const rand = prng.random();
    const correction = [8]u32{ 35733, 38967, 42495, 46340, 50535, 55109, 60097, 65535 };
    var rngs: std.ArrayList(u32) = .empty;
    defer rngs.deinit(testing.allocator);
    for (correction) |c| {
        for (0..16) |shift| {
            // A range with a given 16 bit mantissa, at each size from 2^24 up.
            const base = c << @intCast(shift);
            if (base <= 1 << 23) continue;
            for ([_]u32{ base -| 1, base, base + 1 }) |v| try rngs.append(testing.allocator, v);
        }
    }
    for (0..2000) |_| try rngs.append(testing.allocator, rand.intRangeAtMost(u32, (1 << 23) + 1, 1 << 31));
    for (rngs.items) |rng| {
        if (rng <= 1 << 23) continue;
        const total: i32 = rand.intRangeAtMost(i32, 40, 4000);
        var lg = ilog(rng);
        var r = rng >> @intCast(lg - 16);
        for (0..3) |_| {
            r = (r * r) >> 15;
            const last_bit: u32 = r >> 16;
            lg = 2 * lg + @as(i32, @intCast(last_bit));
            r >>= @intCast(last_bit);
        }
        try testing.expectEqual(@as(u32, @intCast(total * 8 - lg)), tellFracOf(total, rng));
    }
}
