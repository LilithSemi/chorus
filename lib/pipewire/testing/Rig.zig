//! A Remote on a FakeServer, for the tests of the proxies.
const std = @import("std");
const pod = @import("../pod.zig");
const Remote = @import("../Remote.zig");
const Registry = @import("../Registry.zig");
const FakeServer = @import("FakeServer.zig");

const Rig = @This();

pub const gpa = std.testing.allocator;

pub const Options = struct {
    app_props: []const [2][]const u8 = &.{},
    /// Reads the handshake and the get_registry request, and drops them. When false the
    /// handshake stays in the socket and there is no registry.
    get_registry: bool = true,
    /// The allocator of the Remote. The server end always uses the testing allocator.
    allocator: std.mem.Allocator = gpa,
};

server: FakeServer,
remote: *Remote,
registry: *Registry,

pub fn init() !Rig {
    return initWith(.{});
}

pub fn initWith(options: Options) !Rig {
    var server = try FakeServer.init(gpa);
    errdefer server.deinit();
    const remote = try Remote.fromFd(options.allocator, server.client_fd, .{
        .app_name = "chorus-test",
        .props = options.app_props,
    });
    errdefer remote.deinit();
    var rig: Rig = .{ .server = server, .remote = remote, .registry = undefined };
    if (!options.get_registry) return rig;
    try rig.skipHandshake();
    rig.registry = try remote.getRegistry();
    try remote.dispatch();
    var m = try rig.server.expect(0, 5);
    m.deinit(gpa);
    return rig;
}

pub fn deinit(self: *Rig) void {
    self.remote.deinit();
    self.server.deinit();
}

/// Reads and drops the hello and the update_properties messages.
pub fn skipHandshake(self: *Rig) !void {
    for (0..2) |_| {
        var m = try self.server.readMessage();
        m.deinit(gpa);
    }
}

/// Binds global `global_id` and reads the bind request.
pub fn bind(self: *Rig, comptime T: type, global_id: u32) !*T {
    const t = try self.registry.bind(global_id, T, null);
    try self.remote.dispatch();
    var m = try self.server.expect(self.registry.proxy.id, 1);
    m.deinit(gpa);
    return t;
}

/// Reads the next message and checks its id and opcode.
pub fn expectMessage(self: *Rig, id: u32, opcode: u8) !FakeServer.OwnedMessage {
    try self.remote.dispatch();
    return self.server.expect(id, opcode);
}
