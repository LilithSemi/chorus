//! The microphone permission status. It asks AVFoundation through the Objective-C runtime that
//! dlopen loads, so the build links neither AVFoundation nor libobjc.
const std = @import("std");
const api = @import("api.zig");

/// The values of AVAuthorizationStatus, plus `unknown` for a system that cannot answer.
pub const Status = enum(u8) {
    not_determined = 0,
    restricted = 1,
    denied = 2,
    authorized = 3,
    unknown = 255,

    pub fn fromRaw(raw: isize) Status {
        return switch (raw) {
            0 => .not_determined,
            1 => .restricted,
            2 => .denied,
            3 => .authorized,
            else => .unknown,
        };
    }

    /// True when capture gives silence or the system ends the process.
    pub fn blocksCapture(self: Status) bool {
        return self == .restricted or self == .denied;
    }
};

/// The backend asks a Source. A test gives its own.
pub const Source = struct {
    ptr: *anyopaque,
    statusFn: *const fn (ptr: *anyopaque) Status,

    pub fn status(self: Source) Status {
        return self.statusFn(self.ptr);
    }
};

/// The two functions of the dynamic loader that the check needs.
pub const Loader = struct {
    ctx: *anyopaque,
    dlopen: *const fn (self: *anyopaque, path: [*:0]const u8, mode: c_int) ?*anyopaque,
    dlsym: *const fn (self: *anyopaque, handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque,

    pub fn fromBinding(binding: api.Binding) Loader {
        return .{ .ctx = binding.self, .dlopen = binding.table.dlopen, .dlsym = binding.table.dlsym };
    }

    /// A Source that reads the status each time it is asked. The Loader must outlive it.
    pub fn source(self: *Loader) Source {
        return .{ .ptr = self, .statusFn = statusOf };
    }

    fn statusOf(ptr: *anyopaque) Status {
        const self: *Loader = @ptrCast(@alignCast(ptr));
        return self.microphoneStatus();
    }

    /// Reads the status of `AVCaptureDevice` for audio. Any missing library or symbol gives `unknown`.
    pub fn microphoneStatus(self: Loader) Status {
        const mode = api.RTLD.lazy | api.RTLD.local;
        const av = self.dlopen(self.ctx, av_foundation_path, mode) orelse return .unknown;
        const objc = self.dlopen(self.ctx, objc_path, mode) orelse return .unknown;
        const get_class: GetClass = @ptrCast(@alignCast(self.dlsym(self.ctx, objc, "objc_getClass") orelse return .unknown));
        const register: Register = @ptrCast(@alignCast(self.dlsym(self.ctx, objc, "sel_registerName") orelse return .unknown));
        const send: MsgSend = @ptrCast(@alignCast(self.dlsym(self.ctx, objc, "objc_msgSend") orelse return .unknown));
        const media: *const ?*anyopaque = @ptrCast(@alignCast(self.dlsym(self.ctx, av, "AVMediaTypeAudio") orelse return .unknown));
        const class = get_class("AVCaptureDevice") orelse return .unknown;
        const selector = register("authorizationStatusForMediaType:") orelse return .unknown;
        return Status.fromRaw(send(class, selector, media.*));
    }
};

const av_foundation_path = "/System/Library/Frameworks/AVFoundation.framework/AVFoundation";
const objc_path = "/usr/lib/libobjc.A.dylib";

const GetClass = *const fn ([*:0]const u8) callconv(.c) ?*anyopaque;
const Register = *const fn ([*:0]const u8) callconv(.c) ?*anyopaque;
const MsgSend = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) isize;

/// A fake loader. The C functions of the Objective-C runtime carry no context, so they compare
/// against identity tokens. The status plus one travels as the value of the AVMediaTypeAudio symbol.
const Fake = struct {
    const tokens: [4]u8 = .{ 1, 2, 3, 4 };

    fn token(index: usize) *anyopaque {
        return @constCast(&tokens[index]);
    }

    media: ?*anyopaque,
    missing: ?[]const u8 = null,
    loaded: u32 = 0,

    fn init(raw: usize) Fake {
        return .{ .media = @ptrFromInt(raw + 1) };
    }

    fn getClass(name: [*:0]const u8) callconv(.c) ?*anyopaque {
        if (!std.mem.eql(u8, std.mem.span(name), "AVCaptureDevice")) return null;
        return token(0);
    }

    fn register(name: [*:0]const u8) callconv(.c) ?*anyopaque {
        if (!std.mem.eql(u8, std.mem.span(name), "authorizationStatusForMediaType:")) return null;
        return token(1);
    }

    fn send(class: ?*anyopaque, selector: ?*anyopaque, media: ?*anyopaque) callconv(.c) isize {
        if (class != @as(?*anyopaque, token(0)) or selector != @as(?*anyopaque, token(1))) return -1;
        return @as(isize, @intCast(@intFromPtr(media))) - 1;
    }

    fn dlopen(ctx: *anyopaque, path: [*:0]const u8, mode: c_int) ?*anyopaque {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (mode != api.RTLD.lazy | api.RTLD.local) return null;
        const name = std.mem.span(path);
        if (self.missing) |m| if (std.mem.eql(u8, name, m)) return null;
        self.loaded += 1;
        if (std.mem.eql(u8, name, av_foundation_path)) return token(2);
        if (std.mem.eql(u8, name, objc_path)) return token(3);
        return null;
    }

    fn dlsym(ctx: *anyopaque, handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const name = std.mem.span(symbol);
        if (handle == @as(?*anyopaque, token(2))) {
            if (std.mem.eql(u8, name, "AVMediaTypeAudio")) return @ptrCast(&self.media);
            return null;
        }
        if (handle != @as(?*anyopaque, token(3))) return null;
        if (std.mem.eql(u8, name, "objc_getClass")) return @ptrCast(@constCast(&getClass));
        if (std.mem.eql(u8, name, "sel_registerName")) return @ptrCast(@constCast(&register));
        if (std.mem.eql(u8, name, "objc_msgSend")) return @ptrCast(@constCast(&send));
        return null;
    }

    fn loader(self: *Fake) Loader {
        return .{ .ctx = self, .dlopen = dlopen, .dlsym = dlsym };
    }
};

test "the status values follow AVAuthorizationStatus" {
    const t = std.testing;
    try t.expectEqual(Status.not_determined, Status.fromRaw(0));
    try t.expectEqual(Status.restricted, Status.fromRaw(1));
    try t.expectEqual(Status.denied, Status.fromRaw(2));
    try t.expectEqual(Status.authorized, Status.fromRaw(3));
    try t.expectEqual(Status.unknown, Status.fromRaw(4));
    try t.expectEqual(Status.unknown, Status.fromRaw(-1));
    try t.expect(Status.denied.blocksCapture());
    try t.expect(Status.restricted.blocksCapture());
    try t.expect(!Status.not_determined.blocksCapture());
    try t.expect(!Status.authorized.blocksCapture());
    try t.expect(!Status.unknown.blocksCapture());
}

test "the loader reads the status through the objc calls" {
    const t = std.testing;
    const raws = [_]isize{ 0, 1, 2, 3 };
    const want = [_]Status{ .not_determined, .restricted, .denied, .authorized };
    for (raws, want) |raw, expected| {
        var fake: Fake = .init(@intCast(raw));
        var loader = fake.loader();
        try t.expectEqual(expected, loader.source().status());
        try t.expectEqual(@as(u32, 2), fake.loaded);
    }
}

test "a missing library gives unknown" {
    const t = std.testing;
    var no_av: Fake = .init(3);
    no_av.missing = av_foundation_path;
    try t.expectEqual(Status.unknown, no_av.loader().microphoneStatus());
    var no_objc: Fake = .init(3);
    no_objc.missing = objc_path;
    try t.expectEqual(Status.unknown, no_objc.loader().microphoneStatus());
}

test "a source can be a test double" {
    const Double = struct {
        value: Status,
        fn status(ptr: *anyopaque) Status {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.value;
        }
    };
    var double: Double = .{ .value = .denied };
    const source: Source = .{ .ptr = &double, .statusFn = Double.status };
    try std.testing.expectEqual(Status.denied, source.status());
}
