//! Finds the path of the PipeWire socket.
const std = @import("std");

pub const Error = error{PathTooLong};

/// Reads variables of the process environment from a map the caller owns.
pub const ProcessEnv = struct {
    map: *const std.process.Environ.Map,

    pub fn get(self: ProcessEnv, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }
};

/// `env` has `fn get(self, key: []const u8) ?[]const u8`. `name` is the remote name
/// from the client properties. With no runtime dir the result is the `fallback` path. A remote name that is a JSON list is not supported.
pub fn resolve(buf: *[108]u8, env: anytype, name: ?[]const u8) Error![:0]const u8 {
    const remote = nonEmpty(env.get("PIPEWIRE_REMOTE")) orelse nonEmpty(name) orelse "pipewire-0";
    if (remote[0] == '/' or remote[0] == '@') return join(buf, &.{remote});
    const dir = env.get("PIPEWIRE_RUNTIME_DIR") orelse
        env.get("XDG_RUNTIME_DIR") orelse
        env.get("USERPROFILE") orelse
        return fallback(buf, remote);
    return join(buf, &.{ dir, "/", remote });
}

/// The path in the system wide directory. Use it when the socket in the runtime dir does not connect.
pub fn fallback(buf: *[108]u8, name: ?[]const u8) Error![:0]const u8 {
    const remote = nonEmpty(name) orelse "pipewire-0";
    if (remote[0] == '/' or remote[0] == '@') return join(buf, &.{remote});
    return join(buf, &.{ "/run/pipewire/", remote });
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

fn join(buf: *[108]u8, parts: []const []const u8) Error![:0]const u8 {
    var len: usize = 0;
    for (parts) |p| {
        if (p.len > buf.len - 1 - len) return error.PathTooLong;
        @memcpy(buf[len..][0..p.len], p);
        len += p.len;
    }
    buf[len] = 0;
    return buf[0..len :0];
}

fn rep(comptime n: usize) [n]u8 {
    return @splat('a');
}

const TestEnv = struct {
    pairs: []const [2][]const u8,

    pub fn get(self: TestEnv, key: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], key)) return p[1];
        return null;
    }
};

test "default name in XDG_RUNTIME_DIR" {
    var buf: [108]u8 = undefined;
    const env: TestEnv = .{ .pairs = &.{.{ "XDG_RUNTIME_DIR", "/run/user/1000" }} };
    try std.testing.expectEqualStrings("/run/user/1000/pipewire-0", try resolve(&buf, env, null));
}

test "PIPEWIRE_RUNTIME_DIR wins over XDG_RUNTIME_DIR and USERPROFILE" {
    var buf: [108]u8 = undefined;
    const env: TestEnv = .{ .pairs = &.{
        .{ "USERPROFILE", "/c" },
        .{ "XDG_RUNTIME_DIR", "/x" },
        .{ "PIPEWIRE_RUNTIME_DIR", "/p" },
    } };
    try std.testing.expectEqualStrings("/p/pipewire-0", try resolve(&buf, env, null));
    const env2: TestEnv = .{ .pairs = &.{ .{ "USERPROFILE", "/c" }, .{ "XDG_RUNTIME_DIR", "/x" } } };
    try std.testing.expectEqualStrings("/x/pipewire-0", try resolve(&buf, env2, null));
    const env3: TestEnv = .{ .pairs = &.{.{ "USERPROFILE", "/c" }} };
    try std.testing.expectEqualStrings("/c/pipewire-0", try resolve(&buf, env3, null));
}

test "an empty runtime dir counts as set" {
    var buf: [108]u8 = undefined;
    const env: TestEnv = .{ .pairs = &.{ .{ "PIPEWIRE_RUNTIME_DIR", "" }, .{ "XDG_RUNTIME_DIR", "/x" } } };
    try std.testing.expectEqualStrings("/pipewire-0", try resolve(&buf, env, null));
}

test "name order: PIPEWIRE_REMOTE, then the name argument, then the default" {
    var buf: [108]u8 = undefined;
    const base: [2][]const u8 = .{ "XDG_RUNTIME_DIR", "/r" };
    const with_remote: TestEnv = .{ .pairs = &.{ base, .{ "PIPEWIRE_REMOTE", "env-sock" } } };
    try std.testing.expectEqualStrings("/r/env-sock", try resolve(&buf, with_remote, "arg-sock"));
    const empty_remote: TestEnv = .{ .pairs = &.{ base, .{ "PIPEWIRE_REMOTE", "" } } };
    try std.testing.expectEqualStrings("/r/arg-sock", try resolve(&buf, empty_remote, "arg-sock"));
    try std.testing.expectEqualStrings("/r/pipewire-0", try resolve(&buf, empty_remote, ""));
}

test "absolute names are used as is" {
    var buf: [108]u8 = undefined;
    const env: TestEnv = .{ .pairs = &.{ .{ "PIPEWIRE_REMOTE", "/tmp/pw" }, .{ "XDG_RUNTIME_DIR", "/r" } } };
    try std.testing.expectEqualStrings("/tmp/pw", try resolve(&buf, env, null));
    const abstract: TestEnv = .{ .pairs = &.{.{ "PIPEWIRE_REMOTE", "@pw" }} };
    try std.testing.expectEqualStrings("@pw", try resolve(&buf, abstract, null));
}

test "relative name without a runtime dir" {
    var buf: [108]u8 = undefined;
    const env: TestEnv = .{ .pairs = &.{.{ "PIPEWIRE_REMOTE", "rel" }} };
    try std.testing.expectEqualStrings("/run/pipewire/rel", try resolve(&buf, env, null));
}

test "path of 108 bytes does not fit but 107 does" {
    var buf: [108]u8 = undefined;
    const long = rep(200);
    const env: TestEnv = .{ .pairs = &.{ .{ "XDG_RUNTIME_DIR", "/r" }, .{ "PIPEWIRE_REMOTE", &long } } };
    try std.testing.expectError(error.PathTooLong, resolve(&buf, env, null));
    const abs: TestEnv = .{ .pairs = &.{.{ "PIPEWIRE_REMOTE", "/" ++ &rep(199) }} };
    try std.testing.expectError(error.PathTooLong, resolve(&buf, abs, null));
    const fits: TestEnv = .{ .pairs = &.{.{ "PIPEWIRE_REMOTE", "/" ++ &rep(106) }} };
    const p = try resolve(&buf, fits, null);
    try std.testing.expectEqual(@as(usize, 107), p.len);
    try std.testing.expectEqual(@as(u8, 0), p[107]);
    const over: TestEnv = .{ .pairs = &.{.{ "PIPEWIRE_REMOTE", "/" ++ &rep(107) }} };
    try std.testing.expectError(error.PathTooLong, resolve(&buf, over, null));
}

test "fallback path" {
    var buf: [108]u8 = undefined;
    try std.testing.expectEqualStrings("/run/pipewire/pipewire-0", try fallback(&buf, null));
    try std.testing.expectEqualStrings("/run/pipewire/x", try fallback(&buf, "x"));
    try std.testing.expectEqualStrings("/abs", try fallback(&buf, "/abs"));
}
