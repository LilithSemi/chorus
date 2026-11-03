//! SPA POD decoding. Builder is in pod/Builder.zig.
const std = @import("std");
const spa = @import("spa.zig");

pub const Builder = @import("pod/Builder.zig");

// The wire format uses native byte order, and every PipeWire target is little endian.
comptime {
    std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
}

pub const Error = error{ Truncated, BadPod, WrongType };

/// A POD with a body of this size or more is invalid.
pub const max_body_size = 1 << 20;
pub const max_dict_items = 1024;

pub const Prop = struct {
    key: u32,
    flags: spa.PropFlags,
    value: Pod,
};

pub const Pod = struct {
    type: spa.Type,
    /// The body without the 8 byte header and without the padding.
    body: []const u8,

    pub const Parsed = struct { pod: Pod, rest: []const u8 };

    /// Reads the first POD of `data`. `rest` starts after the padding of that POD.
    pub fn parse(data: []const u8) Error!Parsed {
        if (data.len < 8) return error.Truncated;
        const size = readU32(data[0..4]);
        const avail = data.len - 8;
        if (size > avail) return error.Truncated;
        if (size >= max_body_size) return error.BadPod;
        const padded = std.mem.alignForward(usize, size, 8);
        return .{
            .pod = .{ .type = @fromBackingInt(@intCast(readU32(data[4..8]))), .body = data[8..][0..size] },
            .rest = data[8 + @min(padded, avail) ..],
        };
    }

    pub fn int(self: Pod) Error!i32 {
        const body = try self.checked(.int, 4);
        return std.mem.readInt(i32, body[0..4], .little);
    }

    pub fn long(self: Pod) Error!i64 {
        const body = try self.checked(.long, 8);
        return std.mem.readInt(i64, body[0..8], .little);
    }

    pub fn float(self: Pod) Error!f32 {
        const body = try self.checked(.float, 4);
        return @bitCast(readU32(body[0..4]));
    }

    pub fn double(self: Pod) Error!f64 {
        const body = try self.checked(.double, 8);
        return @bitCast(std.mem.readInt(u64, body[0..8], .little));
    }

    pub fn boolean(self: Pod) Error!bool {
        const body = try self.checked(.bool, 4);
        return readU32(body[0..4]) != 0;
    }

    pub fn id(self: Pod) Error!u32 {
        const body = try self.checked(.id, 4);
        return readU32(body[0..4]);
    }

    /// A None pod gives null.
    pub fn string(self: Pod) Error!?[]const u8 {
        if (self.type == .none) return null;
        const body = try self.checked(.string, 1);
        const text = body[0 .. body.len - 1];
        if (body[body.len - 1] != 0 or std.mem.indexOfScalar(u8, text, 0) != null) return error.BadPod;
        return text;
    }

    pub fn bytes(self: Pod) Error![]const u8 {
        return self.checked(.bytes, 0);
    }

    /// The value is an index into the file descriptors of the message.
    pub fn fd(self: Pod) Error!i64 {
        const body = try self.checked(.fd, 8);
        return std.mem.readInt(i64, body[0..8], .little);
    }

    pub fn fraction(self: Pod) Error!spa.Fraction {
        const body = try self.checked(.fraction, 8);
        return .{ .num = readU32(body[0..4]), .denom = readU32(body[4..8]) };
    }

    pub fn rectangle(self: Pod) Error!spa.Rectangle {
        const body = try self.checked(.rectangle, 8);
        return .{ .width = readU32(body[0..4]), .height = readU32(body[4..8]) };
    }

    pub fn structIter(self: Pod) Error!StructIter {
        return .{ .rest = try self.checked(.@"struct", 0) };
    }

    pub fn object(self: Pod) Error!Object {
        const body = try self.checked(.object, 8);
        return .{
            .object_type = readU32(body[0..4]),
            .object_id = readU32(body[4..8]),
            .body = body[8..],
        };
    }

    pub fn choice(self: Pod) Error!Choice {
        const body = try self.checked(.choice, 16);
        const child_type: spa.Type = @fromBackingInt(@intCast(readU32(body[12..16])));
        const child_size = readU32(body[8..12]);
        try checkPacked(child_type, child_size, body[16..]);
        return .{
            .kind = @fromBackingInt(@intCast(readU32(body[0..4]))),
            .flags = readU32(body[4..8]),
            .child_type = child_type,
            .child_size = child_size,
            .data = body[16..],
        };
    }

    pub fn array(self: Pod) Error!Array {
        const body = try self.checked(.array, 8);
        const child_type: spa.Type = @fromBackingInt(@intCast(readU32(body[4..8])));
        const child_size = readU32(body[0..4]);
        try checkPacked(child_type, child_size, body[8..]);
        return .{
            .child_type = child_type,
            .child_size = child_size,
            .data = body[8..],
        };
    }

    /// A Choice of any kind gives its first value. Any other pod gives itself.
    pub fn unwrap(self: Pod) Error!Pod {
        if (self.type != .choice) return self;
        var values = (try self.choice()).values();
        return values.next() orelse error.BadPod;
    }

    fn checked(self: Pod, ty: spa.Type, min_size: usize) Error![]const u8 {
        if (self.type != ty) return error.WrongType;
        if (self.body.len < min_size) return error.BadPod;
        return self.body;
    }
};

pub const StructIter = struct {
    rest: []const u8,

    pub fn next(self: *StructIter) Error!?Pod {
        if (self.rest.len == 0) return null;
        const r = try Pod.parse(self.rest);
        self.rest = r.rest;
        return r.pod;
    }
};

pub const Object = struct {
    object_type: u32,
    object_id: u32,
    body: []const u8,

    pub fn props(self: Object) PropIter {
        return .{ .rest = self.body };
    }
};

pub const PropIter = struct {
    rest: []const u8,

    pub fn next(self: *PropIter) Error!?Prop {
        if (self.rest.len == 0) return null;
        if (self.rest.len < 16) return error.Truncated;
        const r = try Pod.parse(self.rest[8..]);
        const prop: Prop = .{
            .key = readU32(self.rest[0..4]),
            .flags = @bitCast(readU32(self.rest[4..8])),
            .value = r.pod,
        };
        self.rest = r.rest;
        return prop;
    }
};

pub const Choice = struct {
    kind: spa.ChoiceType,
    flags: u32,
    child_type: spa.Type,
    child_size: u32,
    data: []const u8,

    pub fn count(self: Choice) usize {
        return packedCount(self.child_size, self.data);
    }

    pub fn values(self: Choice) ChildIter {
        return .{ .child_type = self.child_type, .child_size = self.child_size, .data = self.data };
    }
};

pub const Array = struct {
    child_type: spa.Type,
    child_size: u32,
    data: []const u8,

    pub fn count(self: Array) usize {
        return packedCount(self.child_size, self.data);
    }

    pub fn items(self: Array) ChildIter {
        return .{ .child_type = self.child_type, .child_size = self.child_size, .data = self.data };
    }
};

/// Iterates the packed values of a Choice or an Array.
pub const ChildIter = struct {
    child_type: spa.Type,
    child_size: u32,
    data: []const u8,

    pub fn next(self: *ChildIter) ?Pod {
        if (self.data.len == 0 or self.data.len < self.child_size) return null;
        const pod: Pod = .{ .type = self.child_type, .body = self.data[0..self.child_size] };
        self.data = self.data[self.child_size..];
        return pod;
    }
};

pub const DictEntry = struct { key: []const u8, value: ?[]const u8 };

/// A Struct of an Int n and n pairs of String.
pub const Dict = struct {
    n: u32,
    items: []const u8,

    pub fn parse(pod: Pod) Error!Dict {
        var it = try pod.structIter();
        const first = (try it.next()) orelse return error.BadPod;
        const n = try first.int();
        if (n < 0 or n > max_dict_items) return error.BadPod;
        const dict: Dict = .{ .n = @intCast(n), .items = it.rest };
        var check = dict.iterator();
        while (try check.next() != null) {}
        return dict;
    }

    pub fn get(self: Dict, key: []const u8) ?[]const u8 {
        var it = self.iterator();
        while (it.next() catch return null) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    pub fn iterator(self: Dict) DictIter {
        return .{ .rest = self.items, .remaining = self.n };
    }

    pub fn len(self: Dict) u32 {
        return self.n;
    }
};

pub const DictIter = struct {
    rest: []const u8,
    remaining: u32,

    pub fn next(self: *DictIter) Error!?DictEntry {
        if (self.remaining == 0) return null;
        if (self.rest.len == 0) return error.BadPod;
        const k = try Pod.parse(self.rest);
        if (k.rest.len == 0) return error.BadPod;
        const v = try Pod.parse(k.rest);
        const key = (try k.pod.string()) orelse return error.BadPod;
        const value = try v.pod.string();
        self.rest = v.rest;
        self.remaining -= 1;
        return .{ .key = key, .value = value };
    }
};

fn readU32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .little);
}

fn packedCount(child_size: u32, data: []const u8) usize {
    if (child_size == 0) return 0;
    return data.len / child_size;
}

fn scalarSize(ty: spa.Type) ?u32 {
    return switch (ty) {
        .bool, .id, .int, .float => 4,
        .long, .double, .rectangle, .fraction, .fd => 8,
        else => null,
    };
}

fn checkPacked(child_type: spa.Type, child_size: u32, data: []const u8) Error!void {
    if (data.len == 0) return;
    if (scalarSize(child_type)) |want| {
        if (child_size != want) return error.BadPod;
    }
    if (child_size == 0 or data.len % child_size != 0) return error.BadPod;
}

fn le(comptime words: anytype) [words.len * 4]u8 {
    var out: [words.len * 4]u8 = undefined;
    for (words, 0..) |w, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], w, .little);
    return out;
}

test "example A: struct with an int and a string" {
    const want = comptime le(.{ 0x20, 0xe, 4, 4, 1, 0, 3, 8, 0x6968, 0 });
    var buf: [64]u8 = undefined;
    var b = Builder.init(&buf);
    const s = try b.beginStruct();
    try b.int(1);
    try b.string("hi");
    b.end(s);
    try std.testing.expectEqualSlices(u8, &want, b.bytesWritten());

    const r = try Pod.parse(&want);
    try std.testing.expectEqual(@as(usize, 0), r.rest.len);
    try std.testing.expectEqual(spa.Type.@"struct", r.pod.type);
    var it = try r.pod.structIter();
    try std.testing.expectEqual(@as(i32, 1), try (try it.next()).?.int());
    try std.testing.expectEqualStrings("hi", (try (try it.next()).?.string()).?);
    try std.testing.expectEqual(@as(?Pod, null), try it.next());
}

test "example B: format object with a range choice" {
    const want = comptime le(.{
        0x50,   0xf,  0x40003, 3,
        1,      0,    4,       3,
        1,      0,    0x10003, 0,
        0x1c,   0x13, 1,       0,
        4,      4,    48000,   8000,
        192000, 0,
    });
    var buf: [128]u8 = undefined;
    var b = Builder.init(&buf);
    const o = try b.beginObject(@backingInt(spa.ObjectType.format), @backingInt(spa.ParamType.enum_format));
    try b.prop(@backingInt(spa.FormatKey.media_type), .{});
    try b.id(@backingInt(spa.MediaType.audio));
    try b.prop(@backingInt(spa.FormatKey.audio_rate), .{});
    const c = try b.beginChoice(.range, 0);
    try b.int(48000);
    try b.int(8000);
    try b.int(192000);
    b.end(c);
    b.end(o);
    try std.testing.expectEqualSlices(u8, &want, b.bytesWritten());

    const pod = (try Pod.parse(&want)).pod;
    const obj = try pod.object();
    try std.testing.expectEqual(@as(u32, 0x40003), obj.object_type);
    try std.testing.expectEqual(@as(u32, 3), obj.object_id);
    var props = obj.props();
    const p1 = (try props.next()).?;
    try std.testing.expectEqual(@as(u32, 1), p1.key);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(p1.flags)));
    try std.testing.expectEqual(@as(u32, 1), try p1.value.id());
    const p2 = (try props.next()).?;
    try std.testing.expectEqual(@as(u32, 0x10003), p2.key);
    const ch = try p2.value.choice();
    try std.testing.expectEqual(spa.ChoiceType.range, ch.kind);
    try std.testing.expectEqual(@as(u32, 0), ch.flags);
    try std.testing.expectEqual(spa.Type.int, ch.child_type);
    var vals = ch.values();
    try std.testing.expectEqual(@as(i32, 48000), try vals.next().?.int());
    try std.testing.expectEqual(@as(i32, 8000), try vals.next().?.int());
    try std.testing.expectEqual(@as(i32, 192000), try vals.next().?.int());
    try std.testing.expectEqual(@as(?Pod, null), vals.next());
    try std.testing.expectEqual(@as(?Prop, null), try props.next());
    try std.testing.expectEqual(@as(i32, 48000), try (try p2.value.unwrap()).int());
}

test "example C: enum choice of ids" {
    const want = comptime le(.{
        0x38,    0xf,   0x40003, 3,
        0x10001, 0,     0x1c,    0x13,
        3,       0,     4,       3,
        0x11b,   0x11b, 0x103,   0,
    });
    var buf: [128]u8 = undefined;
    var b = Builder.init(&buf);
    const o = try b.beginObject(0x40003, 3);
    try b.prop(0x10001, .{});
    const c = try b.beginChoice(.@"enum", 0);
    try b.id(0x11b);
    try b.id(0x11b);
    try b.id(0x103);
    b.end(c);
    b.end(o);
    try std.testing.expectEqualSlices(u8, &want, b.bytesWritten());

    const obj = try (try Pod.parse(&want)).pod.object();
    var props = obj.props();
    const ch = try (try props.next()).?.value.choice();
    try std.testing.expectEqual(spa.ChoiceType.@"enum", ch.kind);
    try std.testing.expectEqual(@as(usize, 3), ch.count());
    var vals = ch.values();
    try std.testing.expectEqual(@as(u32, 0x11b), try vals.next().?.id());
    try std.testing.expectEqual(@as(u32, 0x11b), try vals.next().?.id());
    try std.testing.expectEqual(@as(u32, 0x103), try vals.next().?.id());
    try std.testing.expectEqual(@as(?Pod, null), vals.next());
}

test "example D: every other scalar in one struct" {
    const want = comptime le(.{
        0x90,       0xe,
        0x10,       0xd,
        4,          3,
        3,          4,
        4,          2,
        1,          0,
        8,          5,
        0xfffffffe, 0xffffffff,
        8,          0x12,
        3,          0,
        4,          6,
        0x3f800000, 0,
        3,          9,
        0x636261,   0,
        8,          0xa,
        2,          3,
        8,          0xb,
        1,          48000,
        0,          1,
    });
    var buf: [256]u8 = undefined;
    var b = Builder.init(&buf);
    const s = try b.beginStruct();
    const a = try b.beginArray();
    try b.id(@backingInt(spa.AudioChannel.fl));
    try b.id(@backingInt(spa.AudioChannel.fr));
    b.end(a);
    try b.boolean(true);
    try b.long(-2);
    try b.fd(3);
    try b.float(1.0);
    try b.bytes("abc");
    try b.rectangle(.{ .width = 2, .height = 3 });
    try b.fraction(.{ .num = 1, .denom = 48000 });
    try b.none();
    b.end(s);
    try std.testing.expectEqualSlices(u8, &want, b.bytesWritten());

    var it = try (try Pod.parse(&want)).pod.structIter();
    const arr = try (try it.next()).?.array();
    try std.testing.expectEqual(spa.Type.id, arr.child_type);
    try std.testing.expectEqual(@as(u32, 4), arr.child_size);
    try std.testing.expectEqual(@as(usize, 2), arr.count());
    var items = arr.items();
    try std.testing.expectEqual(@as(u32, 3), try items.next().?.id());
    try std.testing.expectEqual(@as(u32, 4), try items.next().?.id());
    try std.testing.expectEqual(@as(?Pod, null), items.next());
    try std.testing.expectEqual(true, try (try it.next()).?.boolean());
    try std.testing.expectEqual(@as(i64, -2), try (try it.next()).?.long());
    try std.testing.expectEqual(@as(i64, 3), try (try it.next()).?.fd());
    try std.testing.expectEqual(@as(f32, 1.0), try (try it.next()).?.float());
    try std.testing.expectEqualStrings("abc", try (try it.next()).?.bytes());
    const rect = try (try it.next()).?.rectangle();
    try std.testing.expectEqual(@as(u32, 2), rect.width);
    try std.testing.expectEqual(@as(u32, 3), rect.height);
    const frac = try (try it.next()).?.fraction();
    try std.testing.expectEqual(@as(u32, 1), frac.num);
    try std.testing.expectEqual(@as(u32, 48000), frac.denom);
    const nothing = (try it.next()).?;
    try std.testing.expectEqual(spa.Type.none, nothing.type);
    try std.testing.expectEqual(@as(?[]const u8, null), try nothing.string());
    try std.testing.expectEqual(@as(?Pod, null), try it.next());
}

test "example E: dict with an empty value" {
    const want = comptime le(.{
        0x50,       0xe,  4,    4, 2,      0,
        2,          8,    0x6b, 0, 6,      8,
        0x756c6176, 0x65, 3,    8, 0x326b, 0,
        1,          8,    0,    0,
    });
    var buf: [128]u8 = undefined;
    var b = Builder.init(&buf);
    try b.dict(&.{ .{ "k", "value" }, .{ "k2", "" } });
    try std.testing.expectEqualSlices(u8, &want, b.bytesWritten());

    const d = try Dict.parse((try Pod.parse(&want)).pod);
    try std.testing.expectEqual(@as(u32, 2), d.len());
    try std.testing.expectEqualStrings("value", d.get("k").?);
    try std.testing.expectEqualStrings("", d.get("k2").?);
    try std.testing.expectEqual(@as(?[]const u8, null), d.get("k3"));
}

test "example F: empty array and empty choice" {
    const array = comptime le(.{ 8, 0xd, 0, 1 });
    const choice = comptime le(.{ 0x10, 0x13, 3, 0, 0, 1 });
    const arr = try (try Pod.parse(&array)).pod.array();
    try std.testing.expectEqual(@as(usize, 0), arr.count());
    var items = arr.items();
    try std.testing.expectEqual(@as(?Pod, null), items.next());
    const ch = try (try Pod.parse(&choice)).pod.choice();
    try std.testing.expectEqual(@as(usize, 0), ch.count());
    try std.testing.expectError(error.BadPod, (try Pod.parse(&choice)).pod.unwrap());
}

test "round trip of every basic type with padding" {
    var buf: [512]u8 = undefined;
    var b = Builder.init(&buf);
    try b.none();
    try b.boolean(false);
    try b.id(7);
    try b.int(-5);
    try b.long(1 << 40);
    try b.float(-2.5);
    try b.double(1e100);
    try b.string("a");
    try b.string("1234567");
    try b.string("12345678");
    try b.string("");
    try b.string(null);
    try b.bytes("123456789");
    try b.bytes("");
    try b.rectangle(.{ .width = 1920, .height = 1080 });
    try b.fraction(.{ .num = 30000, .denom = 1001 });
    try b.fd(-1);

    var rest: []const u8 = b.bytesWritten();
    try std.testing.expectEqual(@as(usize, 0), rest.len % 8);
    const pods = try std.testing.allocator.alloc(Pod, 17);
    defer std.testing.allocator.free(pods);
    for (pods) |*p| {
        const r = try Pod.parse(rest);
        p.* = r.pod;
        rest = r.rest;
    }
    try std.testing.expectEqual(@as(usize, 0), rest.len);
    try std.testing.expectEqual(spa.Type.none, pods[0].type);
    try std.testing.expectEqual(false, try pods[1].boolean());
    try std.testing.expectEqual(@as(u32, 7), try pods[2].id());
    try std.testing.expectEqual(@as(i32, -5), try pods[3].int());
    try std.testing.expectEqual(@as(i64, 1 << 40), try pods[4].long());
    try std.testing.expectEqual(@as(f32, -2.5), try pods[5].float());
    try std.testing.expectEqual(@as(f64, 1e100), try pods[6].double());
    try std.testing.expectEqualStrings("a", (try pods[7].string()).?);
    try std.testing.expectEqualStrings("1234567", (try pods[8].string()).?);
    try std.testing.expectEqualStrings("12345678", (try pods[9].string()).?);
    try std.testing.expectEqualStrings("", (try pods[10].string()).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try pods[11].string());
    try std.testing.expectEqualStrings("123456789", try pods[12].bytes());
    try std.testing.expectEqualStrings("", try pods[13].bytes());
    const rect = try pods[14].rectangle();
    try std.testing.expectEqual(@as(u32, 1920), rect.width);
    try std.testing.expectEqual(@as(u32, 1080), rect.height);
    const frac = try pods[15].fraction();
    try std.testing.expectEqual(@as(u32, 30000), frac.num);
    try std.testing.expectEqual(@as(u32, 1001), frac.denom);
    try std.testing.expectEqual(@as(i64, -1), try pods[16].fd());
}

test "nested structs and an object with a range choice and an id array" {
    var buf: [512]u8 = undefined;
    var b = Builder.init(&buf);
    const outer = try b.beginStruct();
    const inner = try b.beginStruct();
    try b.int(1);
    try b.string("x");
    b.end(inner);
    const o = try b.beginObject(0x40003, 4);
    try b.prop(0x1, .{ .readonly = true });
    try b.id(1);
    try b.prop(0x10003, .{ .mandatory = true });
    const c = try b.beginChoice(.range, 0);
    try b.int(48000);
    try b.int(8000);
    try b.int(192000);
    b.end(c);
    try b.prop(0x10005, .{});
    const a = try b.beginArray();
    try b.id(3);
    try b.id(4);
    b.end(a);
    b.end(o);
    b.end(outer);

    const r = try Pod.parse(b.bytesWritten());
    try std.testing.expectEqual(@as(usize, 0), r.rest.len);
    var it = try r.pod.structIter();
    var in = try (try it.next()).?.structIter();
    try std.testing.expectEqual(@as(i32, 1), try (try in.next()).?.int());
    try std.testing.expectEqualStrings("x", (try (try in.next()).?.string()).?);
    try std.testing.expectEqual(@as(?Pod, null), try in.next());

    const obj = try (try it.next()).?.object();
    try std.testing.expectEqual(@as(u32, 4), obj.object_id);
    var props = obj.props();
    const p1 = (try props.next()).?;
    try std.testing.expect(p1.flags.readonly);
    try std.testing.expect(!p1.flags.mandatory);
    const p2 = (try props.next()).?;
    try std.testing.expect(p2.flags.mandatory);
    var vals = (try p2.value.choice()).values();
    try std.testing.expectEqual(@as(i32, 48000), try vals.next().?.int());
    try std.testing.expectEqual(@as(i32, 8000), try vals.next().?.int());
    try std.testing.expectEqual(@as(i32, 192000), try vals.next().?.int());
    const p3 = (try props.next()).?;
    var items = (try p3.value.array()).items();
    try std.testing.expectEqual(@as(u32, 3), try items.next().?.id());
    try std.testing.expectEqual(@as(u32, 4), try items.next().?.id());
    try std.testing.expectEqual(@as(?Prop, null), try props.next());
    try std.testing.expectEqual(@as(?Pod, null), try it.next());
}

test "unwrap" {
    var buf: [64]u8 = undefined;
    var b = Builder.init(&buf);
    const c = try b.beginChoice(.none, 0);
    try b.int(44100);
    b.end(c);
    try b.int(9);
    const first = try Pod.parse(b.bytesWritten());
    const plain = try Pod.parse(first.rest);
    try std.testing.expectEqual(@as(i32, 44100), try (try first.pod.unwrap()).int());
    try std.testing.expectEqual(@as(i32, 9), try (try plain.pod.unwrap()).int());
    try std.testing.expectEqual(spa.Type.int, (try plain.pod.unwrap()).type);
}

test "dict with a none value" {
    var buf: [128]u8 = undefined;
    var b = Builder.init(&buf);
    const s = try b.beginStruct();
    try b.int(2);
    try b.string("a");
    try b.string("b");
    try b.string("c");
    try b.string(null);
    b.end(s);
    const d = try Dict.parse((try Pod.parse(b.bytesWritten())).pod);
    try std.testing.expectEqual(@as(u32, 2), d.len());
    try std.testing.expectEqualStrings("b", d.get("a").?);
    try std.testing.expectEqual(@as(?[]const u8, null), d.get("c"));
    var it = d.iterator();
    const e1 = (try it.next()).?;
    try std.testing.expectEqualStrings("a", e1.key);
    try std.testing.expectEqualStrings("b", e1.value.?);
    const e2 = (try it.next()).?;
    try std.testing.expectEqualStrings("c", e2.key);
    try std.testing.expectEqual(@as(?[]const u8, null), e2.value);
    try std.testing.expect((try it.next()) == null);
}

test "dict errors" {
    var buf: [128]u8 = undefined;
    var b = Builder.init(&buf);
    try b.int(0);
    try std.testing.expectError(error.WrongType, Dict.parse((try Pod.parse(b.bytesWritten())).pod));
    b = Builder.init(&buf);
    const s = try b.beginStruct();
    try b.int(2);
    try b.string("a");
    try b.string("b");
    b.end(s);
    try std.testing.expectError(error.BadPod, Dict.parse((try Pod.parse(b.bytesWritten())).pod));
}

test "a size larger than the remaining bytes is truncated" {
    const bytes = comptime le(.{ 16, 4, 1, 0 });
    try std.testing.expectError(error.Truncated, Pod.parse(&bytes));
    try std.testing.expectError(error.Truncated, Pod.parse(bytes[0..7]));
}

test "int on a string is the wrong type" {
    var buf: [32]u8 = undefined;
    var b = Builder.init(&buf);
    try b.string("a");
    const pod = (try Pod.parse(b.bytesWritten())).pod;
    try std.testing.expectError(error.WrongType, pod.int());
    try std.testing.expectError(error.WrongType, pod.structIter());
}

test "an int with a body of 2 bytes is bad" {
    const bytes = comptime le(.{ 2, 4, 1, 0 });
    const pod = (try Pod.parse(&bytes)).pod;
    try std.testing.expectError(error.BadPod, pod.int());
}

test "a choice with child size 4 for a long is bad" {
    const bytes = comptime le(.{ 0x1c, 0x13, 1, 0, 4, 5, 1, 2, 3, 0 });
    const pod = (try Pod.parse(&bytes)).pod;
    try std.testing.expectError(error.BadPod, pod.choice());
}

test "a string without a terminator is bad" {
    const bytes = comptime le(.{ 2, 8, 0x6161, 0 });
    const pod = (try Pod.parse(&bytes)).pod;
    try std.testing.expectError(error.BadPod, pod.string());
}

test "an array with a body that is not a multiple of the child size is bad" {
    const bytes = comptime le(.{ 0x0e, 0xd, 4, 3, 1, 2, 3, 0 });
    const pod = (try Pod.parse(&bytes)).pod;
    try std.testing.expectError(error.BadPod, pod.array());
}

test "a prop that does not fit in the object is truncated" {
    const bytes = comptime le(.{ 0x10, 0xf, 0x40003, 3, 1, 0, 0, 0 });
    const obj = try (try Pod.parse(&bytes)).pod.object();
    var props = obj.props();
    try std.testing.expectError(error.Truncated, props.next());
}

test "every prefix of a nested pod decodes without a crash" {
    var buf: [256]u8 = undefined;
    var b = Builder.init(&buf);
    const s = try b.beginStruct();
    const o = try b.beginObject(0x40003, 3);
    try b.prop(0x10003, .{});
    const c = try b.beginChoice(.range, 0);
    try b.int(48000);
    try b.int(8000);
    try b.int(192000);
    b.end(c);
    b.end(o);
    try b.dict(&.{.{ "a", "b" }});
    b.end(s);
    const full = b.bytesWritten();
    var rejected: usize = 0;
    for (0..full.len) |n| {
        const r = Pod.parse(full[0..n]) catch {
            rejected += 1;
            continue;
        };
        var it = r.pod.structIter() catch continue;
        while (it.next() catch break) |child| {
            _ = Dict.parse(child) catch {
                rejected += 1;
            };
            const obj = child.object() catch continue;
            var props = obj.props();
            while (props.next() catch break) |p| {
                const ch = p.value.choice() catch continue;
                var vals = ch.values();
                while (vals.next()) |v| _ = v.int() catch {
                    rejected += 1;
                };
            }
        }
    }
    try std.testing.expect(rejected > 0);
}
