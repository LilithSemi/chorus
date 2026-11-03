//! Decoding and sending that the Node, Device and Port proxies share.
const std = @import("std");
const spa = @import("spa.zig");
const pod = @import("pod.zig");
const Proxy = @import("Proxy.zig");
const Remote = @import("Remote.zig");

pub const ParamInfo = struct { id: spa.ParamType, flags: spa.ParamInfoFlags };

/// The `{id, flags}` list of an info event. It borrows the message bytes.
pub const ParamList = struct {
    n: u32,
    items: []const u8,

    pub fn iterator(self: ParamList) ParamIter {
        return .{ .rest = self.items, .remaining = self.n };
    }

    pub fn len(self: ParamList) u32 {
        return self.n;
    }
};

pub const ParamIter = struct {
    rest: []const u8,
    remaining: u32,

    pub fn next(self: *ParamIter) pod.Error!?ParamInfo {
        if (self.remaining == 0) return null;
        if (self.rest.len == 0) return error.BadPod;
        const i = try pod.Pod.parse(self.rest);
        if (i.rest.len == 0) return error.BadPod;
        const f = try pod.Pod.parse(i.rest);
        const info: ParamInfo = .{
            .id = @fromBackingInt(try i.pod.id()),
            .flags = @bitCast(try f.pod.int()),
        };
        self.rest = f.rest;
        self.remaining -= 1;
        return info;
    }
};

/// The payload of a `param` event. `param` borrows the message bytes.
pub const ParamEvent = struct {
    seq: i32,
    id: spa.ParamType,
    index: u32,
    next: u32,
    param: pod.Pod,
};

pub fn readParams(a: *Proxy.Args) pod.Error!ParamList {
    var it = try (try a.next()).structIter();
    const first = (try it.next()) orelse return error.BadPod;
    const n = try first.int();
    if (n < 0 or n > pod.max_dict_items) return error.BadPod;
    const list: ParamList = .{ .n = @intCast(n), .items = it.rest };
    var check = list.iterator();
    while (try check.next() != null) {}
    return list;
}

pub fn readParam(a: *Proxy.Args) pod.Error!ParamEvent {
    return .{
        .seq = try a.int(),
        .id = @fromBackingInt(try a.id()),
        .index = try a.uint(),
        .next = try a.uint(),
        .param = try a.next(),
    };
}

/// Copies one whole pod into the builder. The padding is added.
pub fn appendPod(b: *pod.Builder, bytes: []const u8) pod.Builder.Error!void {
    const padded = std.mem.alignForward(usize, bytes.len, 8);
    if (padded > b.buf.len - b.pos) return error.NoSpace;
    @memcpy(b.buf[b.pos..][0..bytes.len], bytes);
    @memset(b.buf[b.pos + bytes.len ..][0 .. padded - bytes.len], 0);
    b.pos += padded;
}

/// Room for the headers and padding of a body with `extra` bytes of payload.
const slack = 128;

pub fn subscribeParams(proxy: *Proxy, ids: []const spa.ParamType) Remote.SendError!void {
    const gpa = proxy.remote.gpa;
    const buf = try gpa.alloc(u8, ids.len * 8 + slack);
    defer gpa.free(buf);
    var b = pod.Builder.init(buf);
    const f = try b.beginStruct();
    const arr = try b.beginArray();
    for (ids) |i| try b.id(@backingInt(i));
    b.end(arr);
    b.end(f);
    try proxy.remote.sendBody(proxy.id, 1, b.bytesWritten());
}

/// `filter` is a whole pod, or null for none.
pub fn enumParams(proxy: *Proxy, seq: i32, id: spa.ParamType, index: u32, num: u32, filter: ?[]const u8) Remote.SendError!void {
    const gpa = proxy.remote.gpa;
    const fl = if (filter) |x| x.len else 0;
    const buf = try gpa.alloc(u8, fl + slack);
    defer gpa.free(buf);
    var b = pod.Builder.init(buf);
    const f = try b.beginStruct();
    try b.int(seq);
    try b.id(@backingInt(id));
    try b.int(@bitCast(index));
    try b.int(@bitCast(num));
    if (filter) |x| try appendPod(&b, x) else try b.none();
    b.end(f);
    try proxy.remote.sendBody(proxy.id, 2, b.bytesWritten());
}

/// `param` is a whole pod.
pub fn setParam(proxy: *Proxy, id: spa.ParamType, flags: u32, param: []const u8) Remote.SendError!void {
    const gpa = proxy.remote.gpa;
    const buf = try gpa.alloc(u8, param.len + slack);
    defer gpa.free(buf);
    var b = pod.Builder.init(buf);
    const f = try b.beginStruct();
    try b.id(@backingInt(id));
    try b.int(@bitCast(flags));
    try appendPod(&b, param);
    b.end(f);
    try proxy.remote.sendBody(proxy.id, 3, b.bytesWritten());
}

/// A Struct that holds one pod, sent with opcode `opcode`.
pub fn sendPod(proxy: *Proxy, opcode: u8, bytes: []const u8) Remote.SendError!void {
    const gpa = proxy.remote.gpa;
    const buf = try gpa.alloc(u8, bytes.len + slack);
    defer gpa.free(buf);
    var b = pod.Builder.init(buf);
    const f = try b.beginStruct();
    try appendPod(&b, bytes);
    b.end(f);
    try proxy.remote.sendBody(proxy.id, opcode, b.bytesWritten());
}
