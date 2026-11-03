//! The small part of JSON that the metadata values of the session manager use.
const std = @import("std");

pub const Error = error{ BadJson, NoSpace };

/// Writes `{"name":"<name>"}`. Quotes, backslashes and control bytes are escaped.
pub fn nameValue(buf: []u8, name: []const u8) error{NoSpace}![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("{\"name\":\"") catch return error.NoSpace;
    for (name) |c| switch (c) {
        '"' => w.writeAll("\\\"") catch return error.NoSpace,
        '\\' => w.writeAll("\\\\") catch return error.NoSpace,
        0...0x1f => w.print("\\u{x:0>4}", .{c}) catch return error.NoSpace,
        else => w.writeByte(c) catch return error.NoSpace,
    };
    w.writeAll("\"}") catch return error.NoSpace;
    return w.buffered();
}

/// Reads the string member `name` of a flat object into `out`. The result is null when there
/// is no such member. Other members may hold strings, numbers, true, false or null.
pub fn parseName(value: []const u8, out: []u8) Error!?[]const u8 {
    var p: Parser = .{ .src = value };
    var found: ?usize = null;
    p.skipSpace();
    try p.expect('{');
    p.skipSpace();
    if (p.peek() == '}') {
        p.pos += 1;
    } else while (true) {
        p.skipSpace();
        var key_buf: [8]u8 = undefined;
        const start = p.pos;
        const is_name = if (p.string(&key_buf)) |key| std.mem.eql(u8, key, "name") else |err| switch (err) {
            error.NoSpace => blk: {
                p.pos = start;
                _ = try p.string(null);
                break :blk false;
            },
            else => return err,
        };
        p.skipSpace();
        try p.expect(':');
        p.skipSpace();
        if (is_name) {
            if (p.peek() != '"') return error.BadJson;
            found = (try p.string(out)).len;
        } else try p.skipScalar();
        p.skipSpace();
        switch (p.peek() orelse return error.BadJson) {
            ',' => p.pos += 1,
            '}' => {
                p.pos += 1;
                break;
            },
            else => return error.BadJson,
        }
    }
    p.skipSpace();
    if (p.pos != value.len) return error.BadJson;
    return if (found) |n| out[0..n] else null;
}

const Parser = struct {
    src: []const u8,
    pos: usize = 0,

    fn peek(self: *const Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn skipSpace(self: *Parser) void {
        while (self.peek()) |c| : (self.pos += 1) {
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
        }
    }

    fn expect(self: *Parser, c: u8) error{BadJson}!void {
        if (self.peek() != c) return error.BadJson;
        self.pos += 1;
    }

    /// Reads a string at the position. With `out` null it only checks the string.
    fn string(self: *Parser, out: ?[]u8) Error![]const u8 {
        try self.expect('"');
        var n: usize = 0;
        while (true) {
            const c = self.peek() orelse return error.BadJson;
            self.pos += 1;
            var enc: [4]u8 = undefined;
            const bytes: []const u8 = switch (c) {
                '"' => return if (out) |o| o[0..n] else "",
                0...0x1f => return error.BadJson,
                '\\' => blk: {
                    const e = self.peek() orelse return error.BadJson;
                    self.pos += 1;
                    switch (e) {
                        '"' => break :blk "\"",
                        '\\' => break :blk "\\",
                        'u' => {
                            const cp = try self.hex4();
                            const len = std.unicode.utf8Encode(cp, &enc) catch return error.BadJson;
                            break :blk enc[0..len];
                        },
                        else => return error.BadJson,
                    }
                },
                else => blk: {
                    enc[0] = c;
                    break :blk enc[0..1];
                },
            };
            if (out) |o| {
                if (n + bytes.len > o.len) return error.NoSpace;
                @memcpy(o[n..][0..bytes.len], bytes);
            }
            n += bytes.len;
        }
    }

    fn hex4(self: *Parser) error{BadJson}!u21 {
        if (self.pos + 4 > self.src.len) return error.BadJson;
        var v: u16 = 0;
        for (self.src[self.pos..][0..4]) |d| {
            if (!std.ascii.isHex(d)) return error.BadJson;
            v = v * 16 + (std.fmt.charToDigit(d, 16) catch unreachable);
        }
        self.pos += 4;
        if (v >= 0xd800 and v <= 0xdfff) return error.BadJson;
        return v;
    }

    fn skipScalar(self: *Parser) Error!void {
        const c = self.peek() orelse return error.BadJson;
        if (c == '"') {
            _ = try self.string(null);
            return;
        }
        const start = self.pos;
        while (self.peek()) |d| : (self.pos += 1) {
            if (!std.ascii.isAlphanumeric(d) and d != '-' and d != '+' and d != '.') break;
        }
        const word = self.src[start..self.pos];
        if (word.len == 0) return error.BadJson;
        if (std.mem.eql(u8, word, "true") or std.mem.eql(u8, word, "false") or std.mem.eql(u8, word, "null")) return;
        if (!isNumber(word)) return error.BadJson;
    }
};

const testing = std.testing;

test "nameValue writes the name object" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("{\"name\":\"alsa_output.pci\"}", try nameValue(&buf, "alsa_output.pci"));
}

test "nameValue escapes quotes, backslashes and control bytes" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("{\"name\":\"a\\\"b\\\\c\\u0001\"}", try nameValue(&buf, "a\"b\\c\x01"));
}

test "nameValue gives NoSpace when the buffer is short" {
    var buf: [10]u8 = undefined;
    try testing.expectError(error.NoSpace, nameValue(&buf, "abcdefgh"));
    var exact: [11 + 3]u8 = undefined;
    try testing.expectEqualStrings("{\"name\":\"abc\"}", try nameValue(&exact, "abc"));
}

test "parseName round trips escapes" {
    var buf: [64]u8 = undefined;
    var out: [64]u8 = undefined;
    const name = "x\"y\\z\x1f end";
    const value = try nameValue(&buf, name);
    try testing.expectEqualStrings(name, (try parseName(value, &out)).?);
}

test "parseName reads spaced output and other members" {
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings("sink", (try parseName("{ \"name\": \"sink\" }", &out)).?);
    try testing.expectEqualStrings("sink", (try parseName("{\"id\":12,\"on\":true,\"x\":null,\"name\":\"sink\",\"s\":\"t\"}", &out)).?);
}

test "parseName decodes unicode escapes in the basic plane" {
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings("A\u{e9}\u{3042}", (try parseName("{\"name\":\"\\u0041\\u00e9\\u3042\"}", &out)).?);
    try testing.expectEqualStrings("A", (try parseName("{\"n\\u0061me\":\"A\"}", &out)).?);
}

test "parseName gives null when there is no name" {
    var out: [32]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), try parseName("{}", &out));
    try testing.expectEqual(@as(?[]const u8, null), try parseName("{\"other\":\"x\"}", &out));
}

test "parseName rejects bad input" {
    var out: [32]u8 = undefined;
    const bad = [_][]const u8{
        "",
        "{",
        "[]",
        "{\"name\"}",
        "{\"name\":}",
        "{\"name\":5}",
        "{\"name\":\"x\"",
        "{\"name\":\"x\"} extra",
        "{\"name\":\"x\",}",
        "{\"name\":\"a\\nb\"}",
        "{\"name\":\"a\\/b\"}",
        "{\"name\":\"\\u12\"}",
        "{\"name\":\"\\u12zz\"}",
        "{\"name\":\"\\u+041\"}",
        "{\"name\":\"\\u-000\"}",
        "{\"name\":\"\\u0_41\"}",
        "{\"name\":\"\\ud800\"}",
        "{\"name\":\"a\nb\"}",
        "{\"o\":{\"name\":\"x\"}}",
        "{\"o\":[1]}",
        "{\"name\":\"x\" \"y\":1}",
    };
    for (bad) |value| try testing.expectError(error.BadJson, parseName(value, &out));
}

test "parseName gives NoSpace when the name does not fit" {
    var out: [3]u8 = undefined;
    try testing.expectError(error.NoSpace, parseName("{\"name\":\"abcd\"}", &out));
    try testing.expectEqualStrings("abc", (try parseName("{\"name\":\"abc\"}", &out)).?);
}

fn isNumber(word: []const u8) bool {
    var i: usize = 0;
    if (i < word.len and word[i] == '-') i += 1;
    const int_start = i;
    while (i < word.len and std.ascii.isDigit(word[i])) i += 1;
    const int_len = i - int_start;
    if (int_len == 0 or (int_len > 1 and word[int_start] == '0')) return false;
    if (i < word.len and word[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < word.len and std.ascii.isDigit(word[i])) i += 1;
        if (i == frac_start) return false;
    }
    if (i < word.len and (word[i] == 'e' or word[i] == 'E')) {
        i += 1;
        if (i < word.len and (word[i] == '+' or word[i] == '-')) i += 1;
        const exp_start = i;
        while (i < word.len and std.ascii.isDigit(word[i])) i += 1;
        if (i == exp_start) return false;
    }
    return i == word.len;
}

test "parseName skips strict numbers only" {
    var out: [8]u8 = undefined;
    for ([_][]const u8{ "0", "-1", "12", "1.5", "-0.25e+3", "2E9" }) |n| {
        var buf: [64]u8 = undefined;
        const v = try std.fmt.bufPrint(&buf, "{{\"a\":{s},\"name\":\"x\"}}", .{n});
        try testing.expectEqualStrings("x", (try parseName(v, &out)).?);
    }
    for ([_][]const u8{ "inf", "nan", "0x1p3", "-", "01", "1.", ".5", "1e", "+1", "1e+" }) |n| {
        var buf: [64]u8 = undefined;
        const v = try std.fmt.bufPrint(&buf, "{{\"a\":{s},\"name\":\"x\"}}", .{n});
        try testing.expectError(error.BadJson, parseName(v, &out));
    }
}
