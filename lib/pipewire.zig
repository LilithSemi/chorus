//! Client for the PipeWire native protocol.
const std = @import("std");

pub const spa = @import("pipewire/spa.zig");
pub const pod = @import("pipewire/pod.zig");
pub const path = @import("pipewire/path.zig");
pub const Connection = @import("pipewire/Connection.zig");
pub const Remote = @import("pipewire/Remote.zig");
pub const Proxy = @import("pipewire/Proxy.zig");
pub const Registry = @import("pipewire/Registry.zig");
pub const Node = @import("pipewire/Node.zig");
pub const Device = @import("pipewire/Device.zig");
pub const Port = @import("pipewire/Port.zig");
pub const Link = @import("pipewire/Link.zig");
pub const Metadata = @import("pipewire/Metadata.zig");
pub const MemPool = @import("pipewire/MemPool.zig");
pub const DataLoop = @import("pipewire/DataLoop.zig");
pub const ClientNode = @import("pipewire/ClientNode.zig");
pub const Stream = @import("pipewire/Stream.zig");
pub const shm = @import("pipewire/shm.zig");
pub const testing = struct {
    pub const FakeServer = @import("pipewire/testing/FakeServer.zig");
    pub const Rig = @import("pipewire/testing/Rig.zig");
    pub const util = @import("pipewire/testing/util.zig");
    pub const live = @import("pipewire/testing/live.zig");
    pub const stream_harness = @import("pipewire/stream/harness.zig");
};

test {
    std.testing.refAllDecls(spa);
    std.testing.refAllDecls(pod);
    std.testing.refAllDecls(path);
    _ = pod.Builder;
    _ = Connection;
    _ = Remote;
    _ = Proxy;
    _ = Registry;
    _ = Node;
    _ = Device;
    _ = Port;
    _ = Link;
    _ = Metadata;
    _ = MemPool;
    _ = DataLoop;
    _ = ClientNode;
    _ = Stream;
    std.testing.refAllDecls(shm);
    _ = testing.FakeServer;
    _ = testing.Rig;
    _ = testing.util;
    _ = testing.live;
    _ = @import("pipewire/live_test.zig");
}
