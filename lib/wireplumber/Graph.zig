//! The model of cards, endpoints and application streams that the session manager keeps.
//! It listens to the registry of one `Remote` and updates itself inside `Remote.dispatch`.
//! It never blocks. Free it before the `Remote`.
const std = @import("std");
const pipewire = @import("pipewire");
const json = @import("json.zig");
const params = @import("params.zig");

const Remote = pipewire.Remote;
const Registry = pipewire.Registry;
const Proxy = pipewire.Proxy;
const Device = pipewire.Device;
const Node = pipewire.Node;
const Metadata = pipewire.Metadata;

const Graph = @This();

/// A global id of the server.
pub const Id = u32;

/// A port of a card device, from an `EnumRoute` entry. `available` is false only when the
/// server says the port is not available.
pub const Port = struct {
    index: u32,
    name: []const u8,
    description: []const u8,
    available: bool,
};

pub const ProfileInfo = struct {
    index: u32,
    name: []const u8,
    description: []const u8,
    available: bool,
};

pub const Card = struct {
    id: Id,
    /// The object.serial of the server. 0 means absent, as the core global has serial 0.
    serial: u64,
    name: []const u8,
    description: []const u8,
    api: []const u8,
    profiles: []const ProfileInfo = &.{},
    active_profile: ?u32 = null,
};

pub const EndpointKind = enum { sink, source };

/// Where the volume of an endpoint comes from. `none` means the node has no volume that a
/// mixer can use.
pub const VolumeSource = enum { route, props, none };

pub const Endpoint = struct {
    id: Id,
    /// The object.serial of the server. 0 means absent, as the core global has serial 0.
    serial: u64,
    kind: EndpointKind,
    name: []const u8,
    description: []const u8,
    card: ?Id,
    profile_device: ?u32,
    priority: i32,
    channels: u32,
    ports: []const Port = &.{},
    active_port: ?u32 = null,
    volume: params.Volume = .{},
    volume_source: VolumeSource = .none,
};

pub const Direction = enum { playback, capture };

pub const AppStream = struct {
    id: Id,
    /// The object.serial of the server. 0 means absent, as the core global has serial 0.
    serial: u64,
    direction: Direction,
    app_name: []const u8,
    media_name: []const u8,
    /// The node on the other end of a link of the stream.
    target: ?Id,
    volume: params.Volume = .{},
};

/// New variants may be added. Switch with an `else` arm.
pub const Change = union(enum) {
    card_added: Id,
    card_changed: Id,
    card_removed: Id,
    endpoint_added: Id,
    endpoint_changed: Id,
    endpoint_removed: Id,
    stream_added: Id,
    stream_changed: Id,
    stream_removed: Id,
    default_changed: EndpointKind,
    settings_changed,
};

/// The change is reported after the model has it. The listener may read the model and must
/// not call `Remote.dispatch`.
pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, graph: *Graph, change: Change) void,
};

pub const Error = Remote.SendError;

pub const Stats = struct {
    /// Nodes of a class that the graph does not handle yet.
    skipped: u64 = 0,
    /// App streams that carry `node.link-group`. They belong to a loopback or a filter chain.
    link_grouped: u64 = 0,
    /// Objects that were not tracked or updated because of an allocation or send failure.
    failed: u64 = 0,
    /// Core errors for the proxies of the graph. A subscribe for a param id that the object does
    /// not have yet also gives one. That is normal, and later bursts still arrive.
    proxy_errors: u64 = 0,
    /// Param events that did not decode.
    bad_params: u64 = 0,
    /// Param events of an enumeration that the graph did not ask for.
    other_seq_params: u64 = 0,
};

const Kind = enum { card, endpoint, stream, defaults, settings };

const Handle = union(enum) {
    none,
    device: *Device,
    node: *Node,
    metadata: *Metadata,

    fn proxy(self: Handle) ?*Proxy {
        return switch (self) {
            .none => null,
            .device => |d| &d.proxy,
            .node => |n| &n.proxy,
            .metadata => |m| &m.proxy,
        };
    }

    fn detach(self: Handle) void {
        switch (self) {
            .none => {},
            .device => |d| d.listener = null,
            .node => |n| n.listener = null,
            .metadata => |m| m.listener = null,
        }
    }
};

/// A global that the graph has bound. It is the listener context of the bound proxy.
const Tracked = struct {
    graph: *Graph,
    id: Id,
    kind: Kind,
    endpoint_kind: EndpointKind = .sink,
    direction: Direction = .playback,
    /// The props of the registry event.
    props: Proxy.OwnedDict,
    handle: Handle = .none,
    global_gone: bool = false,
    /// The current param lists of a card.
    enum_profiles: params.List(params.Profile),
    profile: params.List(params.Profile),
    enum_routes: params.List(params.Route),
    routes: params.List(params.Route),
    /// The lists that the batch in flight fills. A slot is the position of the param id in
    /// the subscription. `open` tells which slots a batch fills.
    pend_enum_profiles: params.List(params.Profile),
    pend_profile: params.List(params.Profile),
    pend_enum_routes: params.List(params.Route),
    pend_routes: params.List(params.Route),
    open: [4]bool = @splat(false),
    /// The last flags of the param infos, by slot.
    param_flags: [4]?u32 = @splat(null),
    waiter: Remote.SyncWaiter,
    /// The Props of a node that a mixer can use, or else the last Props.
    node_volume: params.Volume = .{},
    pend_volume: params.Volume = .{},
    pend_seen: bool = false,
    /// True once the stream was counted in `Stats.link_grouped`.
    link_counted: bool = false,

    fn deinitParams(self: *Tracked) void {
        self.enum_profiles.deinit();
        self.profile.deinit();
        self.enum_routes.deinit();
        self.routes.deinit();
        self.pend_enum_profiles.deinit();
        self.pend_profile.deinit();
        self.pend_enum_routes.deinit();
        self.pend_routes.deinit();
    }

    fn slotOf(self: *const Tracked, id: pipewire.spa.ParamType) ?usize {
        return switch (self.kind) {
            .card => switch (id) {
                .enum_profile => 0,
                .profile => 1,
                .enum_route => 2,
                .route => 3,
                else => null,
            },
            .endpoint, .stream => if (id == .props) 0 else null,
            .defaults, .settings => null,
        };
    }

    fn clearPending(self: *Tracked, slot: usize) void {
        switch (self.kind) {
            .card => switch (slot) {
                0 => self.pend_enum_profiles.clear(),
                1 => self.pend_profile.clear(),
                2 => self.pend_enum_routes.clear(),
                else => self.pend_routes.clear(),
            },
            else => {
                self.pend_volume = .{};
                self.pend_seen = false;
            },
        }
    }

    /// Makes the pending list the current one, and empties the pending list.
    fn swapPending(self: *Tracked, slot: usize) void {
        switch (self.kind) {
            .card => {
                switch (slot) {
                    0 => std.mem.swap(params.List(params.Profile), &self.enum_profiles, &self.pend_enum_profiles),
                    1 => std.mem.swap(params.List(params.Profile), &self.profile, &self.pend_profile),
                    2 => std.mem.swap(params.List(params.Route), &self.enum_routes, &self.pend_enum_routes),
                    else => std.mem.swap(params.List(params.Route), &self.routes, &self.pend_routes),
                }
            },
            else => self.node_volume = self.pend_volume,
        }
        self.clearPending(slot);
    }
};

const LinkRef = struct { id: Id, output: Id, input: Id };

const PutResult = enum { added, changed, same };

/// Items with one arena each. The arena owns the strings of the item.
fn Table(comptime T: type) type {
    return struct {
        const Self = @This();

        items: std.ArrayList(T) = .empty,
        arenas: std.ArrayList(std.heap.ArenaAllocator) = .empty,

        fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            for (self.arenas.items) |arena| arena.deinit();
            self.arenas.deinit(gpa);
            self.items.deinit(gpa);
        }

        fn find(self: *const Self, id: Id) ?usize {
            for (self.items.items, 0..) |item, i| {
                if (item.id == id) return i;
            }
            return null;
        }

        fn put(self: *Self, gpa: std.mem.Allocator, value: T) error{OutOfMemory}!PutResult {
            const found = self.find(value.id);
            if (found) |i| {
                if (sameValue(self.items.items[i], value)) return .same;
            }
            var arena: std.heap.ArenaAllocator = .init(gpa);
            errdefer arena.deinit();
            const copy = try deepCopy(T, arena.allocator(), value);
            if (found) |i| {
                self.arenas.items[i].deinit();
                self.arenas.items[i] = arena;
                self.items.items[i] = copy;
                return .changed;
            }
            try self.items.ensureUnusedCapacity(gpa, 1);
            try self.arenas.ensureUnusedCapacity(gpa, 1);
            self.items.appendAssumeCapacity(copy);
            self.arenas.appendAssumeCapacity(arena);
            return .added;
        }

        fn remove(self: *Self, id: Id) bool {
            const i = self.find(id) orelse return false;
            self.arenas.items[i].deinit();
            _ = self.arenas.orderedRemove(i);
            _ = self.items.orderedRemove(i);
            return true;
        }
    };
}

fn deepCopy(comptime T: type, arena: std.mem.Allocator, value: T) error{OutOfMemory}!T {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) return value;
            const out = try arena.alloc(p.child, value.len);
            for (value, out) |src, *dst| dst.* = try deepCopy(p.child, arena, src);
            return out;
        },
        .optional => |o| return if (value) |v| try deepCopy(o.child, arena, v) else null,
        .@"struct" => |s| {
            var out = value;
            inline for (s.field_names, s.field_types) |name, field_type| {
                @field(out, name) = try deepCopy(field_type, arena, @field(value, name));
            }
            return out;
        },
        else => return value,
    }
}

fn sameValue(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) return a == b;
            if (@typeInfo(p.child) != .@"struct") return std.mem.eql(p.child, a, b);
            if (a.len != b.len) return false;
            for (a, b) |x, y| {
                if (!sameValue(x, y)) return false;
            }
            return true;
        },
        .array => {
            for (a, b) |x, y| {
                if (!sameValue(x, y)) return false;
            }
            return true;
        },
        .float => return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b)),
        .optional => {
            const x = a orelse return b == null;
            const y = b orelse return false;
            return sameValue(x, y);
        },
        .@"struct" => |s| {
            inline for (s.field_names) |name| {
                if (!sameValue(@field(a, name), @field(b, name))) return false;
            }
            return true;
        },
        else => return a == b,
    }
}

/// The props of an info event, with the props of the registry event as fallback.
const Props = struct {
    info: pipewire.pod.Dict,
    registry: pipewire.pod.Dict,

    fn get(self: Props, key: []const u8) ?[]const u8 {
        return self.info.get(key) orelse self.registry.get(key);
    }

    fn num(self: Props, comptime T: type, key: []const u8) ?T {
        return parseNum(T, self.get(key));
    }
};

fn parseNum(comptime T: type, text: ?[]const u8) ?T {
    return std.fmt.parseInt(T, text orelse return null, 10) catch null;
}

gpa: std.mem.Allocator,
remote: *Remote,
registry: *Registry,
listener: ?Listener,
stats: Stats = .{},
card_table: Table(Card) = .{},
endpoint_table: Table(Endpoint) = .{},
stream_table: Table(AppStream) = .{},
tracked: std.ArrayList(*Tracked) = .empty,
links: std.ArrayList(LinkRef) = .empty,
default_names: [2]?[]u8 = .{ null, null },
default_ids: [2]?Id = .{ null, null },
rate: ?u32 = null,

pub const Options = struct { listener: ?Listener = null };

/// Asks for the registry. The model fills during `Remote.dispatch`.
pub fn init(gpa: std.mem.Allocator, remote: *Remote, options: Options) Error!*Graph {
    const self = try gpa.create(Graph);
    errdefer gpa.destroy(self);
    const registry = try remote.getRegistry();
    self.* = .{ .gpa = gpa, .remote = remote, .registry = registry, .listener = options.listener };
    registry.listener = .{ .ctx = self, .func = onRegistry };
    return self;
}

/// Destroys the proxies of the graph. The `Remote` stays usable.
pub fn deinit(self: *Graph) void {
    const gpa = self.gpa;
    self.registry.listener = null;
    destroyProxy(&self.registry.proxy);
    for (self.tracked.items) |t| {
        t.handle.detach();
        if (t.handle.proxy()) |p| destroyProxy(p);
        t.props.deinit(gpa);
        self.remote.cancelSync(&t.waiter);
        t.deinitParams();
        gpa.destroy(t);
    }
    self.tracked.deinit(gpa);
    self.links.deinit(gpa);
    for (self.default_names) |name| {
        if (name) |n| gpa.free(n);
    }
    self.card_table.deinit(gpa);
    self.endpoint_table.deinit(gpa);
    self.stream_table.deinit(gpa);
    gpa.destroy(self);
}

/// When the send fails, `Remote.deinit` frees the proxy.
fn destroyProxy(p: *Proxy) void {
    p.destroy() catch return;
}

/// The slices and the pointers that `card`, `endpoint` and `stream` return are valid until the
/// next `Remote.dispatch`. Copy what must live longer.
pub fn cards(self: *const Graph) []const Card {
    return self.card_table.items.items;
}

pub fn endpoints(self: *const Graph) []const Endpoint {
    return self.endpoint_table.items.items;
}

pub fn streams(self: *const Graph) []const AppStream {
    return self.stream_table.items.items;
}

pub fn card(self: *const Graph, id: Id) ?*const Card {
    const i = self.card_table.find(id) orelse return null;
    return &self.card_table.items.items[i];
}

pub fn endpoint(self: *const Graph, id: Id) ?*const Endpoint {
    const i = self.endpoint_table.find(id) orelse return null;
    return &self.endpoint_table.items.items[i];
}

pub fn stream(self: *const Graph, id: Id) ?*const AppStream {
    const i = self.stream_table.find(id) orelse return null;
    return &self.stream_table.items.items[i];
}

/// The endpoint that the `default` metadata names, matched on `node.name`. When two endpoints
/// of the kind share the name, the one that arrived first wins.
pub fn defaultEndpoint(self: *const Graph, kind: EndpointKind) ?Id {
    return self.default_ids[@backingInt(kind)];
}

/// The `clock.rate` of the `settings` metadata.
pub fn graphRate(self: *const Graph) ?u32 {
    return self.rate;
}

/// True when this `Remote` exports the node with a `ClientNode`.
pub fn ownsStream(self: *const Graph, id: Id) bool {
    return self.remote.exportsNode(id);
}

/// The bound Device proxy of a card, for the control calls.
pub fn deviceProxy(self: *const Graph, id: Id) ?*Device {
    const t = self.findTracked(id) orelse return null;
    if (t.global_gone) return null;
    return switch (t.handle) {
        .device => |d| d,
        else => null,
    };
}

/// The bound Node proxy of an endpoint or a stream, for the control calls.
pub fn nodeProxy(self: *const Graph, id: Id) ?*Node {
    const t = self.findTracked(id) orelse return null;
    if (t.global_gone) return null;
    return switch (t.handle) {
        .node => |n| n,
        else => null,
    };
}

/// The bound `default` metadata, for the control calls.
pub fn defaultMetadata(self: *const Graph) ?*Metadata {
    for (self.tracked.items) |t| {
        if (t.kind != .defaults or t.global_gone) continue;
        switch (t.handle) {
            .metadata => |m| return m,
            else => {},
        }
    }
    return null;
}

/// The id of the registry proxy.
pub fn registryId(self: *const Graph) u32 {
    return self.registry.proxy.id;
}

/// The id of the proxy that the graph bound for the global.
pub fn proxyId(self: *const Graph, id: Id) ?u32 {
    const t = self.findTracked(id) orelse return null;
    const p = t.handle.proxy() orelse return null;
    return p.id;
}

/// The index of the Route of the card that carries the volume of the endpoint. It is null
/// unless the volume source of the endpoint is `route`.
pub fn volumeRoute(self: *const Graph, id: Id) ?u32 {
    const e = self.endpoint(id) orelse return null;
    if (e.volume_source != .route) return null;
    const dev = self.findTracked(e.card orelse return null) orelse return null;
    const device = e.profile_device orelse return null;
    for (dev.routes.items.items) |r| {
        if (r.device != device) continue;
        const v = r.volume orelse continue;
        if (v.complete()) return r.index;
    }
    return null;
}

fn emit(self: *Graph, change: Change) void {
    if (self.listener) |l| l.func(l.ctx, self, change);
}

fn emitPut(self: *Graph, result: PutResult, added: Change, changed: Change) void {
    switch (result) {
        .added => self.emit(added),
        .changed => self.emit(changed),
        .same => {},
    }
}

fn emitDefaults(self: *Graph, delta: [2]bool) void {
    for (std.enums.values(EndpointKind)) |kind| {
        if (delta[@backingInt(kind)]) self.emit(.{ .default_changed = kind });
    }
}

/// The id of a removed object can belong to a new object before the remove_id of the old proxy
/// arrives. A live entry wins over a removed one.
fn findTracked(self: *const Graph, id: Id) ?*Tracked {
    var gone: ?*Tracked = null;
    for (self.tracked.items) |t| {
        if (t.id != id) continue;
        if (!t.global_gone) return t;
        gone = t;
    }
    return gone;
}

fn findLive(self: *const Graph, id: Id) ?*Tracked {
    const t = self.findTracked(id) orelse return null;
    return if (t.global_gone) null else t;
}

fn onRegistry(ctx: ?*anyopaque, registry: *Registry, event: Registry.Event) void {
    _ = registry;
    const self: *Graph = @ptrCast(@alignCast(ctx.?));
    switch (event) {
        .global => |g| self.onGlobal(g.id, g.type, g.props),
        .global_remove => |id| self.onGlobalRemove(id),
        .@"error" => self.stats.proxy_errors += 1,
        else => {},
    }
}

/// The classes that wpctl lists: `Audio/Sink` and `Audio/Source` with any subclass, such as
/// `Audio/Source/Virtual`, except the ones that end in `/Internal`.
fn endpointKind(class: []const u8) ?EndpointKind {
    if (std.mem.endsWith(u8, class, "/Internal")) return null;
    if (inClass(class, "Audio/Sink")) return .sink;
    if (inClass(class, "Audio/Source")) return .source;
    return null;
}

fn inClass(class: []const u8, base: []const u8) bool {
    if (!std.mem.startsWith(u8, class, base)) return false;
    return class.len == base.len or class[base.len] == '/';
}

fn onGlobal(self: *Graph, id: Id, ty: []const u8, props: pipewire.pod.Dict) void {
    const class = props.get("media.class") orelse "";
    if (std.mem.eql(u8, ty, Proxy.typeName(.link))) {
        self.addLink(id, props);
    } else if (self.findLive(id) != null) {
        return;
    } else if (std.mem.eql(u8, ty, Proxy.typeName(.device))) {
        if (std.mem.eql(u8, class, "Audio/Device")) self.track(id, .card, .sink, .playback, props);
    } else if (std.mem.eql(u8, ty, Proxy.typeName(.node))) {
        if (endpointKind(class)) |kind| {
            self.track(id, .endpoint, kind, .playback, props);
        } else if (std.mem.eql(u8, class, "Stream/Output/Audio") or std.mem.eql(u8, class, "Stream/Input/Audio")) {
            const capture = std.mem.eql(u8, class, "Stream/Input/Audio");
            self.track(id, .stream, .sink, if (capture) .capture else .playback, props);
        } else if (std.mem.eql(u8, class, "Audio/Duplex")) {
            self.stats.skipped += 1;
        }
    } else if (std.mem.eql(u8, ty, Proxy.typeName(.metadata))) {
        const name = props.get("metadata.name") orelse return;
        if (std.mem.eql(u8, name, "default")) {
            self.track(id, .defaults, .sink, .playback, props);
        } else if (std.mem.eql(u8, name, "settings")) {
            self.track(id, .settings, .sink, .playback, props);
        }
    }
}

fn track(self: *Graph, id: Id, kind: Kind, endpoint_kind: EndpointKind, direction: Direction, props: pipewire.pod.Dict) void {
    self.trackAlloc(id, kind, endpoint_kind, direction, props) catch {
        self.stats.failed += 1;
    };
}

fn trackAlloc(self: *Graph, id: Id, kind: Kind, endpoint_kind: EndpointKind, direction: Direction, props: pipewire.pod.Dict) Error!void {
    const gpa = self.gpa;
    const t = try gpa.create(Tracked);
    errdefer gpa.destroy(t);
    t.* = .{
        .graph = self,
        .id = id,
        .kind = kind,
        .endpoint_kind = endpoint_kind,
        .direction = direction,
        .props = try Proxy.OwnedDict.init(gpa, props),
        .enum_profiles = .init(gpa),
        .profile = .init(gpa),
        .enum_routes = .init(gpa),
        .routes = .init(gpa),
        .pend_enum_profiles = .init(gpa),
        .pend_profile = .init(gpa),
        .pend_enum_routes = .init(gpa),
        .pend_routes = .init(gpa),
        .waiter = .{ .ctx = t, .func = onSync },
    };
    errdefer t.props.deinit(gpa);
    errdefer t.deinitParams();
    try self.tracked.append(gpa, t);
    errdefer _ = self.tracked.pop();
    switch (kind) {
        .card => {
            const d = try self.registry.bind(id, Device, null);
            d.listener = .{ .ctx = t, .func = onDevice };
            t.handle = .{ .device = d };
            errdefer {
                t.handle.detach();
                destroyProxy(&d.proxy);
                t.handle = .none;
            }
            try d.subscribeParams(&.{ .enum_profile, .profile, .enum_route, .route });
            t.open = @splat(true);
            try self.remote.syncFor(&t.waiter);
        },
        .endpoint, .stream => {
            const n = try self.registry.bind(id, Node, null);
            n.listener = .{ .ctx = t, .func = onNode };
            t.handle = .{ .node = n };
            errdefer {
                t.handle.detach();
                destroyProxy(&n.proxy);
                t.handle = .none;
            }
            try n.subscribeParams(&.{.props});
            t.open[0] = true;
            try self.remote.syncFor(&t.waiter);
        },
        .defaults, .settings => {
            const m = try self.registry.bind(id, Metadata, null);
            m.listener = .{ .ctx = t, .func = onMetadata };
            t.handle = .{ .metadata = m };
        },
    }
}

fn onDevice(ctx: ?*anyopaque, device: *Device, event: Device.Event) void {
    _ = device;
    const t: *Tracked = @ptrCast(@alignCast(ctx.?));
    switch (event) {
        .info => |i| {
            if (i.change_mask.props) t.graph.applyInfo(t, i.props);
            if (i.change_mask.params) t.graph.onParamsInfo(t, i.params);
        },
        .param => |p| t.graph.onDeviceParam(t, p),
        .removed => t.graph.proxyGone(t),
        .@"error" => t.graph.stats.proxy_errors += 1,
    }
}

fn onNode(ctx: ?*anyopaque, node: *Node, event: Node.Event) void {
    _ = node;
    const t: *Tracked = @ptrCast(@alignCast(ctx.?));
    switch (event) {
        .info => |i| {
            if (i.change_mask.props) t.graph.applyInfo(t, i.props);
            if (i.change_mask.params) t.graph.onParamsInfo(t, i.params);
        },
        .param => |p| t.graph.onNodeParam(t, p),
        .removed => t.graph.proxyGone(t),
        .@"error" => t.graph.stats.proxy_errors += 1,
    }
}

fn onMetadata(ctx: ?*anyopaque, metadata: *Metadata, event: Metadata.Event) void {
    _ = metadata;
    const t: *Tracked = @ptrCast(@alignCast(ctx.?));
    switch (event) {
        .property => |p| t.graph.onProperty(t, p),
        .removed => t.graph.proxyGone(t),
        .@"error" => t.graph.stats.proxy_errors += 1,
    }
}

/// The server removed the object of the proxy. Destroying a removed proxy sends nothing.
fn proxyGone(self: *Graph, t: *Tracked) void {
    const p = t.handle.proxy() orelse return;
    t.handle = .none;
    destroyProxy(p);
    if (!t.global_gone) self.removeModel(t);
    if (t.global_gone) self.release(t);
}

fn release(self: *Graph, t: *Tracked) void {
    for (self.tracked.items, 0..) |other, i| {
        if (other == t) {
            _ = self.tracked.orderedRemove(i);
            break;
        }
    }
    t.props.deinit(self.gpa);
    self.remote.cancelSync(&t.waiter);
    t.deinitParams();
    self.gpa.destroy(t);
}

fn onGlobalRemove(self: *Graph, id: Id) void {
    for (self.links.items, 0..) |l, i| {
        if (l.id != id) continue;
        _ = self.links.orderedRemove(i);
        self.linkChanged(l);
        return;
    }
    const t = self.findTracked(id) orelse return;
    t.global_gone = true;
    self.removeModel(t);
    if (t.handle == .none) self.release(t);
}

/// Takes the object out of the model. It does nothing when the object is out already.
fn removeModel(self: *Graph, t: *Tracked) void {
    const id = t.id;
    switch (t.kind) {
        .card => if (self.card_table.remove(id)) self.emit(.{ .card_removed = id }),
        .endpoint => if (self.endpoint_table.remove(id)) {
            const delta = self.refreshDefaults();
            var moved = self.retargetAll();
            defer moved.deinit(self.gpa);
            self.emit(.{ .endpoint_removed = id });
            self.emitDefaults(delta);
            self.emitStreams(moved.items);
        },
        .stream => if (self.stream_table.remove(id)) self.emit(.{ .stream_removed = id }),
        .defaults => {
            for (&self.default_names) |*name| {
                if (name.*) |n| self.gpa.free(n);
                name.* = null;
            }
            self.emitDefaults(self.refreshDefaults());
        },
        .settings => if (self.rate != null) {
            self.rate = null;
            self.emit(.settings_changed);
        },
    }
}

/// Sets the target of every stream. The result lists the streams that changed. When the list
/// cannot grow, the targets are set and the failure is counted.
fn retargetAll(self: *Graph) std.ArrayList(Id) {
    var moved: std.ArrayList(Id) = .empty;
    for (self.stream_table.items.items) |*item| {
        const target = self.targetOf(item.id, item.direction);
        if (target == item.target) continue;
        item.target = target;
        moved.append(self.gpa, item.id) catch {
            self.stats.failed += 1;
        };
    }
    return moved;
}

fn emitStreams(self: *Graph, ids: []const Id) void {
    for (ids) |id| self.emit(.{ .stream_changed = id });
}

fn applyInfo(self: *Graph, t: *Tracked, info: pipewire.pod.Dict) void {
    if (t.global_gone) return;
    const props: Props = .{ .info = info, .registry = t.props.dict() };
    const serial = props.num(u64, "object.serial") orelse 0;
    switch (t.kind) {
        .card => {
            const name = props.get("device.name") orelse "";
            self.refreshCard(t, .{
                .id = t.id,
                .serial = serial,
                .name = name,
                .description = props.get("device.description") orelse props.get("device.nick") orelse name,
                .api = props.get("device.api") orelse "",
            });
        },
        .endpoint => {
            const name = props.get("node.name") orelse "";
            self.refreshEndpoint(.{
                .id = t.id,
                .serial = serial,
                .kind = t.endpoint_kind,
                .name = name,
                .description = props.get("node.description") orelse props.get("node.nick") orelse name,
                .card = props.num(u32, "device.id"),
                .profile_device = props.num(u32, "card.profile.device"),
                .priority = props.num(i32, "priority.session") orelse props.num(i32, "priority.driver") orelse 0,
                .channels = self.channelCount(props),
            });
        },
        .stream => {
            // The link group is not in the registry props. It arrives with the node info.
            if (props.get("node.link-group") != null) {
                if (!t.link_counted) {
                    t.link_counted = true;
                    self.stats.link_grouped += 1;
                }
                if (self.stream_table.remove(t.id)) self.emit(.{ .stream_removed = t.id });
                return;
            }
            self.putStream(.{
                .id = t.id,
                .serial = serial,
                .direction = t.direction,
                .app_name = props.get("application.name") orelse props.get("node.name") orelse "",
                .media_name = props.get("media.name") orelse "",
                .target = self.targetOf(t.id, t.direction),
                .volume = t.node_volume,
            });
        },
        .defaults, .settings => {},
    }
}

/// A count above the channel limit is server data that cannot be used. It counts as unknown.
fn channelCount(self: *Graph, props: Props) u32 {
    const n = props.num(u32, "audio.channels") orelse return 0;
    if (n <= params.max_channels) return n;
    self.stats.bad_params += 1;
    return 0;
}

fn putCard(self: *Graph, value: Card) void {
    const result = self.card_table.put(self.gpa, value) catch {
        self.stats.failed += 1;
        return;
    };
    self.emitPut(result, .{ .card_added = value.id }, .{ .card_changed = value.id });
}

fn putEndpoint(self: *Graph, value: Endpoint) void {
    const result = self.endpoint_table.put(self.gpa, value) catch {
        self.stats.failed += 1;
        return;
    };
    const delta = self.refreshDefaults();
    var moved = if (result == .added) self.retargetAll() else std.ArrayList(Id).empty;
    defer moved.deinit(self.gpa);
    self.emitPut(result, .{ .endpoint_added = value.id }, .{ .endpoint_changed = value.id });
    self.emitDefaults(delta);
    self.emitStreams(moved.items);
}

fn putStream(self: *Graph, value: AppStream) void {
    const result = self.stream_table.put(self.gpa, value) catch {
        self.stats.failed += 1;
        return;
    };
    self.emitPut(result, .{ .stream_added = value.id }, .{ .stream_changed = value.id });
}

const ParamEvent = @FieldType(Device.Event, "param");
const ParamList = @FieldType(Device.Info, "params");

/// Starts the sync of the batch if none is waiting.
fn arm(self: *Graph, t: *Tracked) void {
    if (t.waiter.armed) return;
    self.remote.syncFor(&t.waiter) catch {
        self.stats.failed += 1;
    };
}

/// When the flags of a readable param change, the server sends the list again. The list that
/// was waiting for the done is dropped and a new batch starts.
fn onParamsInfo(self: *Graph, t: *Tracked, list: ParamList) void {
    if (t.global_gone) return;
    var changed = false;
    var it = list.iterator();
    while (true) {
        const item = (it.next() catch {
            self.stats.bad_params += 1;
            break;
        }) orelse break;
        const slot = t.slotOf(item.id) orelse continue;
        const bits: u32 = @bitCast(item.flags);
        const before = t.param_flags[slot];
        t.param_flags[slot] = bits;
        if (before != null and before.? != bits and item.flags.read) {
            t.clearPending(slot);
            t.open[slot] = true;
            changed = true;
        }
    }
    if (!changed) return;
    self.arm(t);
}

/// Decodes one entry into the pending list. A bad entry is dropped and the batch goes on.
fn collect(self: *Graph, comptime T: type, list: *params.List(T), p: ParamEvent) void {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const value = T.decode(scratch.allocator(), p.param) catch |err| {
        switch (err) {
            error.OutOfMemory => self.stats.failed += 1,
            else => self.stats.bad_params += 1,
        }
        return;
    };
    list.append(value) catch {
        self.stats.failed += 1;
    };
}

/// Opens the batch of the param id of the event. It returns the slot, or null when the event
/// does not belong to a batch.
fn openBatch(self: *Graph, t: *Tracked, p: ParamEvent) ?usize {
    if (t.global_gone) return null;
    const slot = t.slotOf(p.id) orelse return null;
    if (p.seq != 1) {
        self.stats.other_seq_params += 1;
        return null;
    }
    t.open[slot] = true;
    self.arm(t);
    return slot;
}

fn onDeviceParam(self: *Graph, t: *Tracked, p: ParamEvent) void {
    const slot = self.openBatch(t, p) orelse return;
    switch (slot) {
        0 => self.collect(params.Profile, &t.pend_enum_profiles, p),
        1 => self.collect(params.Profile, &t.pend_profile, p),
        2 => self.collect(params.Route, &t.pend_enum_routes, p),
        else => self.collect(params.Route, &t.pend_routes, p),
    }
}

/// The first Props of a batch that a mixer can use wins. When none can be used, the last one
/// stays.
fn onNodeParam(self: *Graph, t: *Tracked, p: ParamEvent) void {
    _ = self.openBatch(t, p) orelse return;
    const volume = params.Volume.decode(p.param) catch {
        self.stats.bad_params += 1;
        return;
    };
    if (!t.pend_seen or (!t.pend_volume.complete() and volume.complete())) t.pend_volume = volume;
    t.pend_seen = true;
}

fn onSync(ctx: ?*anyopaque, remote: *Remote, seq: i32) void {
    _ = remote;
    _ = seq;
    const t: *Tracked = @ptrCast(@alignCast(ctx.?));
    t.graph.commit(t);
}

/// Makes the lists of the batch current and updates the model once.
fn commit(self: *Graph, t: *Tracked) void {
    for (&t.open, 0..) |*open, slot| {
        if (!open.*) continue;
        t.swapPending(slot);
        open.* = false;
    }
    if (t.global_gone) return;
    switch (t.kind) {
        .card => {
            if (self.card_table.find(t.id)) |i| self.refreshCard(t, self.card_table.items.items[i]);
            var i: usize = 0;
            while (i < self.endpoint_table.items.items.len) : (i += 1) {
                const e = self.endpoint_table.items.items[i];
                if (e.card == t.id) self.refreshEndpoint(e);
            }
        },
        .endpoint => if (self.endpoint_table.find(t.id)) |i| self.refreshEndpoint(self.endpoint_table.items.items[i]),
        .stream => if (self.stream_table.find(t.id)) |i| {
            var value = self.stream_table.items.items[i];
            value.volume = t.node_volume;
            self.putStream(value);
        },
        .defaults, .settings => {},
    }
}

fn refreshCard(self: *Graph, t: *Tracked, base: Card) void {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const value = composeCard(scratch.allocator(), t, base) catch {
        self.stats.failed += 1;
        return;
    };
    self.putCard(value);
}

fn composeCard(scratch: std.mem.Allocator, t: *const Tracked, base: Card) error{OutOfMemory}!Card {
    var out = base;
    const items = t.enum_profiles.items.items;
    const infos = try scratch.alloc(ProfileInfo, items.len);
    for (items, infos) |p, *info| info.* = .{
        .index = p.index,
        .name = p.name,
        .description = p.description,
        .available = p.available != .no,
    };
    out.profiles = infos;
    const current = t.profile.items.items;
    out.active_profile = if (current.len > 0) current[0].index else null;
    return out;
}

fn refreshEndpoint(self: *Graph, base: Endpoint) void {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const value = self.composeEndpoint(scratch.allocator(), base) catch {
        self.stats.failed += 1;
        return;
    };
    self.putEndpoint(value);
}

/// Fills the ports and the volume of the endpoint from the params of its card and its node.
/// The volume is the one of the current Route of the card device when that Route has `mute`
/// and `channelVolumes`, and else the one of the node Props.
fn composeEndpoint(self: *Graph, scratch: std.mem.Allocator, base: Endpoint) error{OutOfMemory}!Endpoint {
    var out = base;
    out.ports = &.{};
    out.active_port = null;
    out.volume = .{};
    out.volume_source = .none;
    if (self.findTracked(base.id)) |own| {
        if (own.node_volume.complete()) {
            out.volume = own.node_volume;
            out.volume_source = .props;
        }
    }
    const card_id = base.card orelse return out;
    const device = base.profile_device orelse return out;
    const dev = self.findTracked(card_id) orelse return out;
    if (dev.kind != .card or dev.global_gone) return out;

    for (dev.routes.items.items) |r| {
        if (r.device != device) continue;
        if (out.active_port == null) out.active_port = r.index;
        const v = r.volume orelse continue;
        if (v.complete()) {
            out.volume = v;
            out.volume_source = .route;
            break;
        }
    }

    const current = dev.profile.items.items;
    if (current.len == 0) return out;
    const direction: params.Direction = switch (base.kind) {
        .sink => .output,
        .source => .input,
    };
    var ports: std.ArrayList(Port) = .empty;
    for (dev.enum_routes.items.items) |r| {
        if (r.direction != direction) continue;
        if (std.mem.indexOfScalar(u32, r.devices, device) == null) continue;
        if (r.profiles) |ps| {
            if (std.mem.indexOfScalar(u32, ps, current[0].index) == null) continue;
        }
        try ports.append(scratch, .{
            .index = r.index,
            .name = r.name,
            .description = r.description,
            .available = r.available != .no,
        });
    }
    out.ports = ports.items;
    return out;
}

fn addLink(self: *Graph, id: Id, props: pipewire.pod.Dict) void {
    const output = parseNum(Id, props.get("link.output.node")) orelse return;
    const input = parseNum(Id, props.get("link.input.node")) orelse return;
    const l: LinkRef = .{ .id = id, .output = output, .input = input };
    for (self.links.items) |*existing| {
        if (existing.id != id) continue;
        const old = existing.*;
        existing.* = l;
        self.linkChanged(old);
        self.linkChanged(l);
        return;
    }
    self.links.append(self.gpa, l) catch {
        self.stats.failed += 1;
        return;
    };
    self.linkChanged(l);
}

/// The far node of the first link that ends at an endpoint of the right kind.
fn targetOf(self: *const Graph, id: Id, direction: Direction) ?Id {
    const kind: EndpointKind = switch (direction) {
        .playback => .sink,
        .capture => .source,
    };
    for (self.links.items) |l| {
        const far = switch (direction) {
            .playback => if (l.output == id) l.input else continue,
            .capture => if (l.input == id) l.output else continue,
        };
        const i = self.endpoint_table.find(far) orelse continue;
        if (self.endpoint_table.items.items[i].kind == kind) return far;
    }
    return null;
}

/// Sets the target of the stream and tells whether it changed.
fn retarget(self: *Graph, id: Id) bool {
    const i = self.stream_table.find(id) orelse return false;
    const item = &self.stream_table.items.items[i];
    const target = self.targetOf(id, item.direction);
    if (target == item.target) return false;
    item.target = target;
    return true;
}

fn linkChanged(self: *Graph, l: LinkRef) void {
    const output_changed = self.retarget(l.output);
    const input_changed = l.input != l.output and self.retarget(l.input);
    if (output_changed) self.emit(.{ .stream_changed = l.output });
    if (input_changed) self.emit(.{ .stream_changed = l.input });
}

fn resolveDefault(self: *const Graph, kind: EndpointKind) ?Id {
    const name = self.default_names[@backingInt(kind)] orelse return null;
    for (self.endpoint_table.items.items) |e| {
        if (e.kind == kind and std.mem.eql(u8, e.name, name)) return e.id;
    }
    return null;
}

/// Resolves the default endpoints again and tells which of them changed.
fn refreshDefaults(self: *Graph) [2]bool {
    var delta: [2]bool = .{ false, false };
    for (std.enums.values(EndpointKind)) |kind| {
        const i = @backingInt(kind);
        const now = self.resolveDefault(kind);
        delta[i] = now != self.default_ids[i];
        self.default_ids[i] = now;
    }
    return delta;
}

fn onProperty(self: *Graph, t: *Tracked, p: Metadata.Property) void {
    if (t.global_gone or p.subject != 0) return;
    switch (t.kind) {
        .defaults => self.onDefaultProperty(p),
        .settings => self.onSettingsProperty(p),
        else => {},
    }
}

fn onDefaultProperty(self: *Graph, p: Metadata.Property) void {
    if (p.key) |key| {
        const kind: EndpointKind = if (std.mem.eql(u8, key, "default.audio.sink"))
            .sink
        else if (std.mem.eql(u8, key, "default.audio.source"))
            .source
        else
            return;
        self.setDefaultName(kind, p.value);
    } else for (std.enums.values(EndpointKind)) |kind| {
        self.setDefaultName(kind, null);
    }
    self.emitDefaults(self.refreshDefaults());
}

/// A value that is not a name object clears the default. When the name cannot be copied, the
/// old default stays and the failure is counted.
fn setDefaultName(self: *Graph, kind: EndpointKind, value: ?[]const u8) void {
    var copy: ?[]u8 = null;
    if (value) |v| {
        const buf = self.gpa.alloc(u8, v.len) catch {
            self.stats.failed += 1;
            return;
        };
        defer self.gpa.free(buf);
        if (json.parseName(v, buf) catch null) |name| {
            copy = self.gpa.dupe(u8, name) catch {
                self.stats.failed += 1;
                return;
            };
        }
    }
    const slot = &self.default_names[@backingInt(kind)];
    if (slot.*) |old| self.gpa.free(old);
    slot.* = copy;
}

fn onSettingsProperty(self: *Graph, p: Metadata.Property) void {
    if (p.key) |key| {
        if (!std.mem.eql(u8, key, "clock.rate")) return;
    }
    var rate: ?u32 = null;
    if (p.key != null) {
        if (p.value) |v| {
            rate = parseNum(u32, std.mem.trim(u8, v, "\" "));
            if (rate == 0) rate = null;
        }
    }
    if (rate == self.rate) return;
    self.rate = rate;
    self.emit(.settings_changed);
}

const testing = std.testing;
const tgpa = testing.allocator;
const util = pipewire.testing.util;
const support = @import("testing.zig");
const Fixture = support.Fixture;
const Rec = support.Rec;
const Bind = support.Bind;
const PropsSpec = support.PropsSpec;
const RouteSpec = support.RouteSpec;
const ProfileSpec = support.ProfileSpec;
const device_type = support.device_type;
const node_type = support.node_type;
const link_type = support.link_type;
const metadata_type = support.metadata_type;
const fillCard = support.fillCard;
const addCardSink = support.addCardSink;
const countOf = support.countOf;
const Prop = support.Prop;

test "the registry and the infos fill the model in order of arrival" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();

    try testing.expectEqualSlices(Change, &.{
        .{ .card_added = 40 },
        .{ .endpoint_added = 41 },
        .{ .endpoint_added = 42 },
        .{ .stream_added = 43 },
    }, f.rec.slice());
    try testing.expectEqual(@as(u32, 0), f.rec.model_miss);

    try testing.expectEqual(@as(usize, 1), f.graph.cards().len);
    try testing.expectEqual(@as(usize, 2), f.graph.endpoints().len);
    try testing.expectEqual(@as(usize, 1), f.graph.streams().len);

    const c = f.graph.card(40).?;
    try testing.expectEqual(@as(u64, 140), c.serial);
    try testing.expectEqualStrings("alsa_card.test", c.name);
    try testing.expectEqualStrings("Test Card", c.description);
    try testing.expectEqualStrings("alsa:acp", c.api);

    const sink = f.graph.endpoint(41).?;
    try testing.expectEqual(EndpointKind.sink, sink.kind);
    try testing.expectEqual(@as(u64, 141), sink.serial);
    try testing.expectEqualStrings("alsa_output.test", sink.name);
    try testing.expectEqualStrings("Test Out", sink.description);
    try testing.expectEqual(@as(?Id, 40), sink.card);
    try testing.expectEqual(@as(?u32, 3), sink.profile_device);
    try testing.expectEqual(@as(i32, 1000), sink.priority);
    try testing.expectEqual(@as(u32, 2), sink.channels);

    const source = f.graph.endpoint(42).?;
    try testing.expectEqual(EndpointKind.source, source.kind);
    try testing.expectEqualStrings("Test In", source.description);
    try testing.expectEqual(@as(?Id, 40), source.card);
    try testing.expectEqual(@as(?u32, null), source.profile_device);
    try testing.expectEqual(@as(i32, 0), source.priority);
    try testing.expectEqual(@as(u32, 1), source.channels);

    const s = f.graph.stream(43).?;
    try testing.expectEqual(Direction.playback, s.direction);
    try testing.expectEqual(@as(u64, 143), s.serial);
    try testing.expectEqualStrings("player", s.app_name);
    try testing.expectEqualStrings("Song", s.media_name);
    try testing.expectEqual(@as(?Id, 41), s.target);

    try testing.expect(f.graph.card(41) == null);
    try testing.expect(f.graph.endpoint(40) == null);
    try testing.expect(f.graph.stream(41) == null);
}

test "a capture stream targets the output node of its link" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();

    try f.global(60, node_type, &.{
        .{ "media.class", "Stream/Input/Audio" },
        .{ "node.name", "rec-in" },
    });
    try f.global(61, link_type, &.{
        .{ "link.output.node", "42" },
        .{ "link.input.node", "60" },
    });
    const bind = try f.readBind();
    try f.nodeInfo(bind, 0b11111, &.{.{ "node.name", "rec-in" }});

    const s = f.graph.stream(60).?;
    try testing.expectEqual(Direction.capture, s.direction);
    try testing.expectEqualStrings("rec-in", s.app_name);
    try testing.expectEqualStrings("", s.media_name);
    try testing.expectEqual(@as(?Id, 42), s.target);
}

test "a link that arrives after the stream sets the target" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    try f.globalRemove(44);
    f.rec.clear();

    try f.global(70, link_type, &.{
        .{ "link.output.node", "43" },
        .{ "link.input.node", "41" },
    });
    try testing.expectEqualSlices(Change, &.{.{ .stream_changed = 43 }}, f.rec.slice());
    try testing.expectEqual(@as(?Id, 41), f.graph.stream(43).?.target);
}

test "the default metadata names the default endpoint" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    const meta = try f.bindMetadata(45, "default");
    f.rec.clear();

    try testing.expectEqual(@as(?Id, null), f.graph.defaultEndpoint(.sink));
    try f.defaultName(meta, "default.audio.sink", "alsa_output.test");
    try testing.expectEqual(@as(?Id, 41), f.graph.defaultEndpoint(.sink));
    try testing.expectEqual(@as(?Id, null), f.graph.defaultEndpoint(.source));
    try testing.expectEqualSlices(Change, &.{.{ .default_changed = .sink }}, f.rec.slice());

    f.rec.clear();
    try f.defaultName(meta, "default.audio.sink", "alsa_output.test");
    try f.defaultName(meta, "default.configured.audio.sink", "alsa_input.test");
    try testing.expectEqual(@as(usize, 0), f.rec.n);

    try f.defaultName(meta, "default.audio.source", "alsa_input.test");
    try testing.expectEqual(@as(?Id, 42), f.graph.defaultEndpoint(.source));
    try testing.expectEqualSlices(Change, &.{.{ .default_changed = .source }}, f.rec.slice());

    f.rec.clear();
    try f.defaultName(meta, "default.audio.sink", "gone");
    try testing.expectEqual(@as(?Id, null), f.graph.defaultEndpoint(.sink));
    try testing.expectEqualSlices(Change, &.{.{ .default_changed = .sink }}, f.rec.slice());

    f.rec.clear();
    try f.property(meta, 0, "default.audio.source", null);
    try testing.expectEqual(@as(?Id, null), f.graph.defaultEndpoint(.source));
    try testing.expectEqualSlices(Change, &.{.{ .default_changed = .source }}, f.rec.slice());

    f.rec.clear();
    try f.property(meta, 0, "default.audio.sink", "not json");
    try f.defaultName(meta, "default.audio.sink", "alsa_output.test");
    try f.property(meta, 0, null, null);
    try testing.expectEqual(@as(?Id, null), f.graph.defaultEndpoint(.sink));
    try testing.expectEqualSlices(Change, &.{ .{ .default_changed = .sink }, .{ .default_changed = .sink } }, f.rec.slice());
}

test "a default that names a later endpoint resolves when it appears" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const meta = try f.bindMetadata(45, "default");
    try f.defaultName(meta, "default.audio.sink", "late.sink");
    try testing.expectEqual(@as(usize, 0), f.rec.n);

    try f.global(80, node_type, &.{
        .{ "media.class", "Audio/Sink" },
        .{ "node.name", "late.sink" },
    });
    const bind = try f.readBind();
    try f.nodeInfo(bind, 0b11111, &.{.{ "node.name", "late.sink" }});
    try testing.expectEqualSlices(Change, &.{ .{ .endpoint_added = 80 }, .{ .default_changed = .sink } }, f.rec.slice());
    try testing.expectEqual(@as(?Id, 80), f.graph.defaultEndpoint(.sink));
}

test "the settings metadata gives the graph rate" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const meta = try f.bindMetadata(46, "settings");
    try testing.expectEqual(@as(?u32, null), f.graph.graphRate());

    try f.property(meta, 0, "clock.rate", "44100");
    try testing.expectEqual(@as(?u32, 44100), f.graph.graphRate());
    try testing.expectEqualSlices(Change, &.{.settings_changed}, f.rec.slice());

    f.rec.clear();
    try f.property(meta, 0, "clock.rate", "44100");
    try f.property(meta, 0, "clock.quantum", "1024");
    try f.property(meta, 5, "clock.rate", "96000");
    try testing.expectEqual(@as(usize, 0), f.rec.n);

    try f.property(meta, 0, "clock.rate", "\"48000\"");
    try testing.expectEqual(@as(?u32, 48000), f.graph.graphRate());
    try f.property(meta, 0, "clock.rate", "fast");
    try testing.expectEqual(@as(?u32, null), f.graph.graphRate());
    try testing.expectEqual(@as(usize, 2), f.rec.n);

    try f.property(meta, 0, "clock.rate", "96000");
    try f.property(meta, 0, "clock.rate", null);
    try testing.expectEqual(@as(?u32, null), f.graph.graphRate());
    try testing.expectEqual(@as(usize, 4), f.rec.n);
}

test "other metadata is not bound" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.global(47, metadata_type, &.{.{ "metadata.name", "sm-settings" }});
    try f.global(48, metadata_type, &.{});
    try util.expectQuiet(&f.rig.server, 50);
    try testing.expectEqual(@as(usize, 0), f.graph.tracked.items.len);
}

test "removing the link clears the target and removing the sink removes it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    const meta = try f.bindMetadata(45, "default");
    try f.defaultName(meta, "default.audio.sink", "alsa_output.test");
    f.rec.clear();

    try f.globalRemove(44);
    try testing.expectEqualSlices(Change, &.{.{ .stream_changed = 43 }}, f.rec.slice());
    try testing.expectEqual(@as(?Id, null), f.graph.stream(43).?.target);

    f.rec.clear();
    try f.globalRemove(41);
    try testing.expectEqualSlices(Change, &.{ .{ .endpoint_removed = 41 }, .{ .default_changed = .sink } }, f.rec.slice());
    try testing.expect(f.graph.endpoint(41) == null);
    try testing.expectEqual(@as(usize, 1), f.graph.endpoints().len);
    try testing.expectEqual(@as(?Id, null), f.graph.defaultEndpoint(.sink));

    f.rec.clear();
    try f.globalRemove(43);
    try f.globalRemove(40);
    try testing.expectEqualSlices(Change, &.{ .{ .stream_removed = 43 }, .{ .card_removed = 40 } }, f.rec.slice());
    try testing.expectEqual(@as(u32, 0), f.rec.model_miss);

    // An id that nothing tracks is ignored.
    try f.globalRemove(999);
    try testing.expectEqual(@as(usize, 2), f.rec.n);
}

test "a bound object is freed after both the global_remove and the remove_id" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    // Card, sink, source and stream.
    try testing.expectEqual(@as(usize, 4), f.graph.tracked.items.len);
    const sink_proxy = f.graph.tracked.items[1].handle.node.proxy.id;
    const source_proxy = f.graph.tracked.items[2].handle.node.proxy.id;

    try f.globalRemove(41);
    try testing.expectEqual(@as(usize, 4), f.graph.tracked.items.len);
    try f.removeId(sink_proxy);
    try testing.expectEqual(@as(usize, 3), f.graph.tracked.items.len);

    try f.removeId(source_proxy);
    try testing.expectEqual(@as(usize, 3), f.graph.tracked.items.len);
    try testing.expect(f.graph.endpoint(42) == null);
    try f.globalRemove(42);
    try testing.expectEqual(@as(usize, 2), f.graph.tracked.items.len);
    try testing.expect(f.graph.endpoint(42) == null);
}

test "a node that goes away before its info never shows" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.global(80, node_type, &.{ .{ "media.class", "Audio/Sink" }, .{ "node.name", "x" } });
    const bind = try f.readBind();
    try f.globalRemove(80);
    try f.removeId(bind.new_id);
    try testing.expectEqual(@as(usize, 0), f.rec.n);
    try testing.expectEqual(@as(usize, 0), f.graph.tracked.items.len);
    try testing.expectEqual(@as(usize, 0), f.graph.endpoints().len);
}

test "a new object with the id of a removed one shows before the remove_id of the old proxy" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.global(80, node_type, &.{ .{ "media.class", "Audio/Sink" }, .{ "node.name", "old" } });
    const old = try f.readBind();
    try f.globalRemove(80);
    try f.addNode(80, "Audio/Sink", "new");
    try testing.expectEqualStrings("new", f.graph.endpoint(80).?.name);

    try f.removeId(old.new_id);
    try testing.expectEqualStrings("new", f.graph.endpoint(80).?.name);
    try testing.expectEqual(@as(usize, 1), f.graph.tracked.items.len);
}

test "other classes are ignored and a duplex node is counted" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.global(80, node_type, &.{ .{ "media.class", "Video/Source" }, .{ "node.name", "cam" } });
    try f.global(81, node_type, &.{ .{ "media.class", "Audio/Duplex" }, .{ "node.name", "duplex" } });
    try f.global(82, node_type, &.{.{ "node.name", "no class" }});
    try f.global(83, device_type, &.{.{ "media.class", "Video/Device" }});
    try util.expectQuiet(&f.rig.server, 50);
    try testing.expectEqual(@as(u64, 1), f.graph.stats.skipped);
    try testing.expectEqual(@as(usize, 0), f.graph.tracked.items.len);
    try testing.expectEqual(@as(usize, 0), f.rec.n);
}

test "endpoint classes follow wpctl" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.addNode(80, "Audio/Source/Virtual", "virtual_in");
    try f.addNode(81, "Audio/Sink/Virtual", "virtual_out");
    try testing.expectEqual(EndpointKind.source, f.graph.endpoint(80).?.kind);
    try testing.expectEqual(EndpointKind.sink, f.graph.endpoint(81).?.kind);

    try f.global(82, node_type, &.{ .{ "media.class", "Audio/Sink/Internal" }, .{ "node.name", "a" } });
    try f.global(83, node_type, &.{ .{ "media.class", "Audio/Source/Internal" }, .{ "node.name", "b" } });
    try f.global(84, node_type, &.{ .{ "media.class", "Audio/Sinkhole" }, .{ "node.name", "c" } });
    try f.global(85, node_type, &.{ .{ "media.class", "Audio/Duplex" }, .{ "node.name", "d" } });
    try util.expectQuiet(&f.rig.server, 50);
    try testing.expectEqual(@as(usize, 2), f.graph.endpoints().len);
    try testing.expectEqual(@as(u64, 1), f.graph.stats.skipped);
}

test "a stream with a link group in its info is skipped and counted once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.global(80, node_type, &.{ .{ "media.class", "Stream/Output/Audio" }, .{ "node.name", "loop-out" } });
    var bind = try f.readBind();
    try f.nodeInfo(bind, 0b11111, &.{ .{ "node.name", "loop-out" }, .{ "node.link-group", "loopback-1" } });
    try testing.expectEqual(@as(usize, 0), f.graph.streams().len);
    try testing.expectEqual(@as(u64, 1), f.graph.stats.link_grouped);
    try f.nodeInfo(bind, 0b11111, &.{ .{ "node.name", "loop-out" }, .{ "node.link-group", "loopback-1" } });
    try testing.expectEqual(@as(u64, 1), f.graph.stats.link_grouped);

    try f.global(81, node_type, &.{ .{ "media.class", "Stream/Output/Audio" }, .{ "node.name", "player" } });
    bind = try f.readBind();
    try f.nodeInfo(bind, 0b11111, &.{.{ "node.name", "player" }});
    try testing.expectEqual(@as(usize, 1), f.graph.streams().len);
}

test "a stream that gets a link group is removed from the model" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.global(80, node_type, &.{ .{ "media.class", "Stream/Output/Audio" }, .{ "node.name", "late" } });
    const bind = try f.readBind();
    try f.nodeInfo(bind, 0b11111, &.{.{ "node.name", "late" }});
    try testing.expectEqual(@as(usize, 1), f.graph.streams().len);
    f.rec.clear();
    try f.nodeInfo(bind, 0b11111, &.{ .{ "node.name", "late" }, .{ "node.link-group", "chain" } });
    try testing.expectEqual(@as(usize, 0), f.graph.streams().len);
    try testing.expectEqualSlices(Change, &.{.{ .stream_removed = 80 }}, f.rec.slice());
    try testing.expectEqual(@as(u64, 1), f.graph.stats.link_grouped);
}

test "a new info changes the item and the same info changes nothing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    f.rec.clear();
    const card_bind: Bind = .{ .global = 40, .new_id = f.graph.tracked.items[0].handle.device.proxy.id };

    const same: []const Prop = &.{
        .{ "device.name", "alsa_card.test" },
        .{ "device.description", "Test Card" },
        .{ "device.api", "alsa:acp" },
    };
    try f.deviceInfo(card_bind, 0b11, same);
    try testing.expectEqual(@as(usize, 0), f.rec.n);

    try f.deviceInfo(card_bind, 0b11, &.{
        .{ "device.name", "alsa_card.test" },
        .{ "device.description", "Renamed" },
        .{ "device.api", "alsa:acp" },
    });
    try testing.expectEqualSlices(Change, &.{.{ .card_changed = 40 }}, f.rec.slice());
    try testing.expectEqualStrings("Renamed", f.graph.card(40).?.description);

    // The mask has no props bit, so the empty dict does not wipe the model.
    f.rec.clear();
    try f.deviceInfo(card_bind, 0b10, &.{});
    try testing.expectEqual(@as(usize, 0), f.rec.n);
    try testing.expectEqualStrings("Renamed", f.graph.card(40).?.description);
}

test "ownsStream finds the nodes this remote exports" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();

    const exported = try f.rig.remote.createObjectAs(pipewire.ClientNode, .client_node, "client-node", &.{});
    var created = try f.rig.expectMessage(0, 6);
    created.deinit(tgpa);
    try testing.expect(!f.graph.ownsStream(43));

    var buf: [64]u8 = undefined;
    var b = pipewire.pod.Builder.init(&buf);
    const s = try b.beginStruct();
    try b.int(@bitCast(exported.proxy.id));
    try b.int(43);
    try b.dict(&.{});
    b.end(s);
    try f.rig.server.send(0, 8, b.bytesWritten(), &.{});
    try f.rig.remote.dispatch();
    try testing.expect(f.graph.ownsStream(43));
    try testing.expect(!f.graph.ownsStream(41));
    // The exported node has no listener, so the remote can free it with the graph gone.
}

test "the removed event and the global_remove each remove the object once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    const sink_proxy = f.graph.tracked.items[1].handle.node.proxy.id;
    const source_proxy = f.graph.tracked.items[2].handle.node.proxy.id;
    f.rec.clear();

    try f.removeId(sink_proxy);
    try testing.expectEqualSlices(Change, &.{ .{ .endpoint_removed = 41 }, .{ .stream_changed = 43 } }, f.rec.slice());
    try testing.expect(f.graph.endpoint(41) == null);
    try testing.expectEqual(@as(usize, 4), f.graph.tracked.items.len);
    try f.globalRemove(41);
    try testing.expectEqual(@as(usize, 2), f.rec.n);
    try testing.expectEqual(@as(usize, 3), f.graph.tracked.items.len);

    // The object shows again after both notices.
    try f.addNode(41, "Audio/Sink", "alsa_output.test");
    try testing.expectEqualSlices(Change, &.{
        .{ .endpoint_removed = 41 },
        .{ .stream_changed = 43 },
        .{ .endpoint_added = 41 },
        .{ .stream_changed = 43 },
    }, f.rec.slice());
    try testing.expectEqual(@as(?Id, 41), f.graph.stream(43).?.target);
    try testing.expectEqual(@as(usize, 4), f.graph.tracked.items.len);

    f.rec.clear();
    try f.globalRemove(42);
    try testing.expectEqualSlices(Change, &.{.{ .endpoint_removed = 42 }}, f.rec.slice());
    try f.removeId(source_proxy);
    try testing.expectEqual(@as(usize, 1), f.rec.n);
    try testing.expectEqual(@as(usize, 3), f.graph.tracked.items.len);
    try testing.expectEqual(@as(u32, 0), f.rec.model_miss);
}

test "the target is the far node of the first link to an endpoint of the right kind" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.addNode(41, "Audio/Sink", "sink.a");
    try f.addNode(49, "Audio/Sink", "sink.b");
    try f.addNode(42, "Audio/Source", "source.a");
    try f.addNode(90, "Stream/Input/Audio", "other");
    try f.addNode(43, "Stream/Output/Audio", "player");
    f.rec.clear();

    try f.link(50, "43", "90");
    try f.link(51, "43", "42");
    try testing.expectEqual(@as(?Id, null), f.graph.stream(43).?.target);
    try testing.expectEqual(@as(usize, 0), f.rec.n);

    try f.link(52, "43", "41");
    try f.link(53, "43", "41");
    try f.link(54, "43", "49");
    try testing.expectEqual(@as(?Id, 41), f.graph.stream(43).?.target);
    try testing.expectEqualSlices(Change, &.{.{ .stream_changed = 43 }}, f.rec.slice());

    try f.globalRemove(52);
    try testing.expectEqual(@as(?Id, 41), f.graph.stream(43).?.target);
    try testing.expectEqual(@as(usize, 1), f.rec.n);
    try f.globalRemove(53);
    try testing.expectEqual(@as(?Id, 49), f.graph.stream(43).?.target);
    try testing.expectEqual(@as(usize, 2), f.rec.n);

    // A link to a node that is not an endpoint yet counts once the endpoint shows.
    try f.link(55, "43", "77");
    try f.globalRemove(54);
    try testing.expectEqual(@as(?Id, null), f.graph.stream(43).?.target);
    try f.addNode(77, "Audio/Sink", "sink.c");
    try testing.expectEqual(@as(?Id, 77), f.graph.stream(43).?.target);
    try testing.expectEqual(Change{ .stream_changed = 43 }, f.rec.events[f.rec.n - 1]);
    try testing.expectEqual(@as(u32, 0), f.rec.model_miss);

    // A capture stream ignores sinks.
    try f.addNode(60, "Stream/Input/Audio", "rec");
    try f.link(61, "41", "60");
    try testing.expectEqual(@as(?Id, null), f.graph.stream(60).?.target);
    try f.link(62, "42", "60");
    try testing.expectEqual(@as(?Id, 42), f.graph.stream(60).?.target);
}

test "a default name longer than a small buffer still resolves" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var long: [300]u8 = undefined;
    @memset(&long, 'n');
    try f.addNode(80, "Audio/Sink", &long);
    const meta = try f.bindMetadata(45, "default");
    try f.defaultName(meta, "default.audio.sink", &long);
    try testing.expectEqual(@as(?Id, 80), f.graph.defaultEndpoint(.sink));
    try testing.expectEqual(@as(u64, 0), f.graph.stats.failed);
}

test "the first endpoint with a duplicate node.name is the default" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.addNode(80, "Audio/Sink", "dup");
    try f.addNode(81, "Audio/Sink", "dup");
    const meta = try f.bindMetadata(45, "default");
    try f.defaultName(meta, "default.audio.sink", "dup");
    try testing.expectEqual(@as(?Id, 80), f.graph.defaultEndpoint(.sink));
    try f.globalRemove(80);
    try testing.expectEqual(@as(?Id, 81), f.graph.defaultEndpoint(.sink));
}

test "the params of a card give profiles, ports and the route volume in one change" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    f.rec.clear();
    try fillCard(&f, f.bindOf(40));

    const c = f.graph.card(40).?;
    try testing.expectEqual(@as(usize, 2), c.profiles.len);
    try testing.expectEqual(@as(u32, 0), c.profiles[0].index);
    try testing.expectEqualStrings("off", c.profiles[0].name);
    try testing.expectEqualStrings("Hi Fi", c.profiles[1].description);
    try testing.expect(c.profiles[0].available);
    try testing.expect(c.profiles[1].available);
    try testing.expectEqual(@as(?u32, 1), c.active_profile);

    const sink = f.graph.endpoint(41).?;
    try testing.expectEqual(@as(usize, 2), sink.ports.len);
    try testing.expectEqual(@as(u32, 5), sink.ports[0].index);
    try testing.expectEqualStrings("speaker", sink.ports[0].name);
    try testing.expect(sink.ports[0].available);
    try testing.expectEqual(@as(u32, 6), sink.ports[1].index);
    try testing.expect(!sink.ports[1].available);
    try testing.expectEqual(@as(?u32, 5), sink.active_port);
    try testing.expectEqual(VolumeSource.route, sink.volume_source);
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.5 }, sink.volume.channels());
    try testing.expect(!sink.volume.mute);

    const source = f.graph.endpoint(42).?;
    try testing.expectEqual(@as(usize, 0), source.ports.len);
    try testing.expectEqual(@as(?u32, null), source.active_port);
    try testing.expectEqual(VolumeSource.none, source.volume_source);

    try testing.expectEqualSlices(Change, &.{ .{ .card_changed = 40 }, .{ .endpoint_changed = 41 } }, f.rec.slice());
    try testing.expectEqual(@as(u32, 0), f.rec.model_miss);
    try testing.expectEqual(@as(u64, 0), f.graph.stats.bad_params);
}

test "nothing shows before the done of the batch" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    f.rec.clear();
    const dev = f.bindOf(40);
    try f.param(dev, 8, 0, ProfileSpec{ .index = 0 });
    try f.param(dev, 9, 0, ProfileSpec{ .index = 0 });
    try testing.expectEqual(@as(usize, 0), f.rec.n);
    try testing.expectEqual(@as(usize, 0), f.graph.card(40).?.profiles.len);
    try f.commit();
    try testing.expectEqual(@as(usize, 1), f.graph.card(40).?.profiles.len);
    try testing.expectEqual(@as(?u32, 0), f.graph.card(40).?.active_profile);

    // A param of another enumeration is counted and ignored.
    f.rec.clear();
    var buf: [256]u8 = undefined;
    var b = pipewire.pod.Builder.init(&buf);
    const s = try b.beginStruct();
    try b.int(7);
    try b.id(8);
    try b.int(0);
    try b.int(1);
    try (ProfileSpec{ .index = 3 }).write(&b);
    b.end(s);
    try f.rig.server.send(dev.new_id, 1, b.bytesWritten(), &.{});
    try f.rig.remote.dispatch();
    try testing.expectEqual(@as(u64, 1), f.graph.stats.other_seq_params);
    try util.expectQuiet(&f.rig.server, 50);
    try testing.expectEqual(@as(usize, 0), f.rec.n);
}

test "a burst for two devices gives one change per endpoint" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    try addCardSink(&f, 60, "0");
    try addCardSink(&f, 61, "2");
    const dev = f.bindOf(40);
    try f.param(dev, 9, 0, ProfileSpec{ .index = 1 });
    try f.param(dev, 12, 0, RouteSpec{ .index = 10, .profiles = &.{1}, .devices = &.{0} });
    try f.param(dev, 12, 1, RouteSpec{ .index = 11, .profiles = &.{1}, .devices = &.{2} });
    try f.commit();
    f.rec.clear();

    try f.param(dev, 13, 0, RouteSpec{ .index = 10, .device = 0, .props = .{ .volumes = &.{0.1}, .mute = false } });
    try f.param(dev, 13, 2, RouteSpec{ .index = 11, .device = 2, .props = .{ .volumes = &.{0.9}, .mute = true } });
    try testing.expectEqual(@as(usize, 0), f.rec.n);
    try f.commit();
    try testing.expectEqual(@as(usize, 1), countOf(&f.rec, .{ .endpoint_changed = 60 }));
    try testing.expectEqual(@as(usize, 1), countOf(&f.rec, .{ .endpoint_changed = 61 }));
    try testing.expectEqual(@as(usize, 2), f.rec.n);
    try testing.expectEqual(@as(?u32, 10), f.graph.endpoint(60).?.active_port);
    try testing.expectEqual(@as(?u32, 11), f.graph.endpoint(61).?.active_port);
    try testing.expectEqualSlices(f32, &.{0.9}, f.graph.endpoint(61).?.volume.channels());
    try testing.expect(f.graph.endpoint(61).?.volume.mute);
}

test "a profile change leaves no stale route" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    try addCardSink(&f, 60, "0");
    try addCardSink(&f, 61, "2");
    const dev = f.bindOf(40);
    try f.param(dev, 9, 0, ProfileSpec{ .index = 1 });
    try f.param(dev, 12, 0, RouteSpec{ .index = 10, .devices = &.{0} });
    try f.param(dev, 12, 1, RouteSpec{ .index = 11, .devices = &.{2} });
    try f.param(dev, 13, 0, RouteSpec{ .index = 10, .device = 0, .props = .{ .volumes = &.{0.1}, .mute = false } });
    try f.commit();
    try testing.expectEqual(@as(?u32, 10), f.graph.endpoint(60).?.active_port);
    try testing.expectEqual(@as(?u32, null), f.graph.endpoint(61).?.active_port);
    f.rec.clear();

    // The new profile has only device 2, and its wire index is 2.
    try f.param(dev, 13, 2, RouteSpec{ .index = 11, .device = 2, .props = .{ .volumes = &.{0.4}, .mute = false } });
    try f.commit();
    const old = f.graph.endpoint(60).?;
    try testing.expectEqual(@as(?u32, null), old.active_port);
    try testing.expectEqual(VolumeSource.none, old.volume_source);
    try testing.expectEqual(@as(?u32, 11), f.graph.endpoint(61).?.active_port);
    try testing.expectEqual(VolumeSource.route, f.graph.endpoint(61).?.volume_source);
    try testing.expectEqual(@as(usize, 2), f.rec.n);
}

test "a list that becomes empty clears the ports, the port and the route volume" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    const dev = f.bindOf(40);
    const flags = [_][2]u32{ .{ 8, 2 }, .{ 9, 6 }, .{ 12, 2 }, .{ 13, 6 } };
    try f.deviceInfoParams(dev, 0b10, &.{}, &flags);
    try fillCard(&f, dev);
    try testing.expectEqual(@as(usize, 2), f.graph.endpoint(41).?.ports.len);
    f.rec.clear();

    // The server flips the serial flag of EnumRoute and Route and sends no entries.
    const serial = [_][2]u32{ .{ 8, 2 }, .{ 9, 6 }, .{ 12, 3 }, .{ 13, 7 } };
    try f.deviceInfoParams(dev, 0b10, &.{}, &serial);
    try testing.expectEqual(@as(usize, 0), f.rec.n);
    try f.commit();
    const sink = f.graph.endpoint(41).?;
    try testing.expectEqual(@as(usize, 0), sink.ports.len);
    try testing.expectEqual(@as(?u32, null), sink.active_port);
    try testing.expectEqual(VolumeSource.none, sink.volume_source);
    try testing.expectEqual(@as(usize, 0), sink.volume.channels().len);
    try testing.expectEqualSlices(Change, &.{.{ .endpoint_changed = 41 }}, f.rec.slice());
    // The profiles did not change flags, so they stay.
    try testing.expectEqual(@as(usize, 2), f.graph.card(40).?.profiles.len);

    // The same flags again start nothing.
    try f.deviceInfoParams(dev, 0b10, &.{}, &serial);
    try util.expectQuiet(&f.rig.server, 50);
}

test "a bad first entry does not merge the old and the new list" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    try addCardSink(&f, 60, "0");
    try addCardSink(&f, 61, "2");
    const dev = f.bindOf(40);
    try f.param(dev, 13, 0, RouteSpec{ .index = 10, .device = 0, .props = .{ .volumes = &.{0.1}, .mute = false } });
    try f.commit();
    try testing.expectEqual(@as(?u32, 10), f.graph.endpoint(60).?.active_port);
    f.rec.clear();

    try f.param(dev, 13, 0, RouteSpec{ .index = 10, .device = 0, .props = .{ .cut = true } });
    try f.param(dev, 13, 2, RouteSpec{ .index = 11, .device = 2, .props = .{ .volumes = &.{0.4}, .mute = false } });
    try f.commit();
    try testing.expectEqual(@as(u64, 1), f.graph.stats.bad_params);
    try testing.expectEqual(@as(?u32, null), f.graph.endpoint(60).?.active_port);
    try testing.expectEqual(@as(?u32, 11), f.graph.endpoint(61).?.active_port);
    try testing.expectEqual(@as(u32, 0), f.rec.model_miss);
}

test "a sink without a card takes its volume from the node props" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    try f.addNode(50, "Audio/Sink", "plain");
    f.rec.clear();

    try f.param(f.bindOf(50), 2, 0, PropsSpec{ .volumes = &.{ 0.2, 0.4 }, .mute = true });
    try testing.expectEqual(@as(usize, 0), f.rec.n);
    try f.commit();
    try testing.expectEqualSlices(Change, &.{.{ .endpoint_changed = 50 }}, f.rec.slice());
    const e = f.graph.endpoint(50).?;
    try testing.expectEqual(VolumeSource.props, e.volume_source);
    try testing.expectEqualSlices(f32, &.{ 0.2, 0.4 }, e.volume.channels());
    try testing.expect(e.volume.mute);
    try testing.expectEqual(@as(usize, 0), e.ports.len);

    // The same props change nothing.
    f.rec.clear();
    try f.param(f.bindOf(50), 2, 0, PropsSpec{ .volumes = &.{ 0.2, 0.4 }, .mute = true });
    try f.commit();
    try testing.expectEqual(@as(usize, 0), f.rec.n);

    // Props without mute are not a volume the mixer can use.
    try f.addNode(51, "Audio/Sink", "partial");
    try f.param(f.bindOf(51), 2, 0, PropsSpec{ .volumes = &.{0.2} });
    try f.commit();
    try testing.expectEqual(VolumeSource.none, f.graph.endpoint(51).?.volume_source);

    // A bad Props is counted and the batch commits without it.
    try f.param(f.bindOf(50), 2, 0, PropsSpec{ .cut = true });
    try f.commit();
    try testing.expectEqual(@as(u64, 1), f.graph.stats.bad_params);
    try testing.expectEqual(VolumeSource.none, f.graph.endpoint(50).?.volume_source);
}

test "a Route change updates the endpoint and the props are the fallback" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    const dev = f.bindOf(40);
    try fillCard(&f, dev);
    f.rec.clear();

    try f.param(dev, 13, 3, RouteSpec{
        .index = 6,
        .device = 3,
        .profile = 1,
        .props = .{ .volumes = &.{ 0.8, 0.9 }, .mute = true },
    });
    try f.commit();
    try testing.expectEqualSlices(Change, &.{.{ .endpoint_changed = 41 }}, f.rec.slice());
    var sink = f.graph.endpoint(41).?;
    try testing.expectEqual(@as(?u32, 6), sink.active_port);
    try testing.expectEqual(VolumeSource.route, sink.volume_source);
    try testing.expectEqualSlices(f32, &.{ 0.8, 0.9 }, sink.volume.channels());
    try testing.expect(sink.volume.mute);

    // A Route of another device is not the route of the sink.
    try f.param(dev, 13, 4, RouteSpec{ .index = 7, .device = 4, .props = .{ .volumes = &.{1.0}, .mute = false } });
    try f.commit();
    sink = f.graph.endpoint(41).?;
    try testing.expectEqual(@as(?u32, null), sink.active_port);
    try testing.expectEqual(VolumeSource.none, sink.volume_source);

    // A Route without mute does not carry the volume, so the node props do.
    try f.param(dev, 13, 3, RouteSpec{ .index = 5, .device = 3, .props = .{ .volumes = &.{0.1} } });
    try f.commit();
    try f.param(f.bindOf(41), 2, 0, PropsSpec{ .volumes = &.{ 0.3, 0.3 }, .mute = false });
    try f.commit();
    sink = f.graph.endpoint(41).?;
    try testing.expectEqual(@as(?u32, 5), sink.active_port);
    try testing.expectEqual(VolumeSource.props, sink.volume_source);
    try testing.expectEqualSlices(f32, &.{ 0.3, 0.3 }, sink.volume.channels());

    // A new list of routes replaces the old one.
    try f.param(dev, 12, 0, RouteSpec{ .index = 5, .name = "speaker", .profiles = &.{1}, .devices = &.{3} });
    try f.commit();
    try testing.expectEqual(@as(usize, 1), f.graph.endpoint(41).?.ports.len);

    // A route without a profiles key fits every profile and an empty list fits none.
    try f.param(dev, 12, 0, RouteSpec{ .index = 5, .devices = &.{3} });
    try f.param(dev, 12, 1, RouteSpec{ .index = 6, .profiles = &.{}, .devices = &.{3} });
    try f.commit();
    try testing.expectEqual(@as(usize, 1), f.graph.endpoint(41).?.ports.len);
    try testing.expectEqual(@as(u32, 5), f.graph.endpoint(41).?.ports[0].index);
    try testing.expectEqual(@as(u32, 0), f.rec.model_miss);

    // A new active profile hides the ports of the old one.
    try f.param(dev, 12, 0, RouteSpec{ .index = 5, .profiles = &.{1}, .devices = &.{3} });
    try f.param(dev, 9, 0, ProfileSpec{ .index = 2 });
    try f.commit();
    try testing.expectEqual(@as(usize, 0), f.graph.endpoint(41).?.ports.len);
    try testing.expectEqual(@as(?u32, 2), f.graph.card(40).?.active_profile);
}

test "the props of a stream give its volume" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    f.rec.clear();

    try f.param(f.bindOf(43), 2, 0, PropsSpec{ .volumes = &.{ 0.6, 0.7 }, .mute = false });
    try f.commit();
    try testing.expectEqualSlices(Change, &.{.{ .stream_changed = 43 }}, f.rec.slice());
    const s = f.graph.stream(43).?;
    try testing.expectEqualSlices(f32, &.{ 0.6, 0.7 }, s.volume.channels());
    try testing.expect(!s.volume.mute);
    try testing.expectEqual(@as(?Id, 41), s.target);

    // A later info of the stream keeps the volume.
    const bind = f.bindOf(43);
    try f.nodeInfo(bind, 0b11111, &.{ .{ "node.name", "player-out" }, .{ "media.name", "Other" } });
    try testing.expectEqualStrings("Other", f.graph.stream(43).?.media_name);
    try testing.expectEqualSlices(f32, &.{ 0.6, 0.7 }, f.graph.stream(43).?.volume.channels());
}

test "ports show for an endpoint that arrives after the params of its card" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.global(40, device_type, &.{.{ "media.class", "Audio/Device" }});
    const dev = try f.readBind();
    try fillCard(&f, dev);
    try testing.expectEqual(@as(usize, 0), f.graph.endpoints().len);

    try f.global(41, node_type, &.{ .{ "media.class", "Audio/Sink" }, .{ "node.name", "late" } });
    const bind = try f.readBind();
    try f.nodeInfo(bind, 0b11111, &.{
        .{ "node.name", "late" },
        .{ "device.id", "40" },
        .{ "card.profile.device", "3" },
    });
    const sink = f.graph.endpoint(41).?;
    try testing.expectEqual(@as(usize, 2), sink.ports.len);
    try testing.expectEqual(VolumeSource.route, sink.volume_source);

    // The card shows with its profiles once its info arrives.
    try f.deviceInfo(dev, 0b11, &.{.{ "device.name", "alsa_card.late" }});
    try testing.expectEqual(@as(usize, 2), f.graph.card(40).?.profiles.len);
}

test "removing a node or the graph while a batch waits cancels the sync" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.populate();
    try f.param(f.bindOf(43), 2, 0, PropsSpec{ .volumes = &.{0.6}, .mute = false });
    try f.param(f.bindOf(40), 8, 0, ProfileSpec{ .index = 0 });
    try testing.expect(f.graph.findTracked(43).?.waiter.armed);
    try f.globalRemove(43);
    try f.removeId(f.bindOf(43).new_id);
    try testing.expect(f.graph.findTracked(43) == null);
    try testing.expect(f.graph.findTracked(40).?.waiter.armed);
    // The waiter of the removed node is not linked any more.
    var cur = f.rig.remote.waiters;
    var linked: usize = 0;
    while (cur) |w| : (cur = w.next) linked += 1;
    try testing.expectEqual(@as(usize, 1), linked);
    // The graph is freed with the card waiting.
}

test "a change info while the bind batch waits is committed by one done" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.global(40, device_type, &.{.{ "media.class", "Audio/Device" }});
    const dev = try f.readBindWith(false);
    const flags = [_][2]u32{ .{ 8, 2 }, .{ 9, 6 }, .{ 12, 2 }, .{ 13, 6 } };
    try f.deviceInfoParams(dev, 0b11, &.{.{ "device.name", "alsa_card.x" }}, &flags);
    try f.param(dev, 8, 0, ProfileSpec{ .index = 0, .name = "old" });

    // EnumProfile changes: the pending list is dropped and the server sends it again.
    const serial = [_][2]u32{ .{ 8, 3 }, .{ 9, 6 }, .{ 12, 2 }, .{ 13, 6 } };
    try f.deviceInfoParams(dev, 0b10, &.{}, &serial);
    try f.param(dev, 8, 0, ProfileSpec{ .index = 1, .name = "new" });
    try f.param(dev, 8, 1, ProfileSpec{ .index = 2, .name = "newer" });
    try testing.expectEqual(@as(usize, 0), f.graph.card(40).?.profiles.len);
    try f.commit();
    try util.expectQuiet(&f.rig.server, 50);
    const c = f.graph.card(40).?;
    try testing.expectEqual(@as(usize, 2), c.profiles.len);
    try testing.expectEqualStrings("new", c.profiles[0].name);
    try testing.expectEqualStrings("newer", c.profiles[1].name);
}
