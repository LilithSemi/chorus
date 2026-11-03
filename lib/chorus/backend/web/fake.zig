//! A fake browser for tests. It holds a clock that a test sets, and it records every call that
//! has an effect. The functions reach the state through the `self` pointer of the `Binding`.
const std = @import("std");
const api = @import("api.zig");
const Handle = api.Handle;

const Fake = @This();

pub const Play = struct {
    context: Handle,
    gain: Handle,
    src: Handle,
    frames: u32,
    rate: f32,
    when: f64,
    /// One copy per channel, `frames` samples each.
    channels: []const []const f32,
};

pub const Ramp = struct { gain: Handle, value: f32, seconds: f64, at: f64 };
pub const Stop = struct { src: Handle, when: f64, at: f64 };

gpa: std.mem.Allocator,
/// Settings that a test changes at any time.
now: f64 = 0,
/// The wall clock in milliseconds. It does not stop while the context is suspended.
wall_ms: f64 = 0,
/// One state for every context. `createContext` sets it to `new_state`.
ctx_state: api.State = .running,
new_state: api.State = .running,
is_activated: bool = true,
/// True while a user gesture runs.
is_transient: bool = false,
is_hidden: bool = false,
max_channels: u32 = 2,
rate: f32 = 48000,
is_available: bool = true,
/// A rate in `createContext` replaces `rate` when this is true.
honor_rate: bool = true,
/// `resume` sets `state` to running when this is true.
resume_runs: bool = false,
/// Makes `play` fail with handle 0.
fail_play: bool = false,
/// Makes `createContext` and `createGain` fail with handle 0.
fail_create: bool = false,
/// Records.
plays: std.ArrayList(Play) = .empty,
ramps: std.ArrayList(Ramp) = .empty,
stops: std.ArrayList(Stop) = .empty,
/// The wall clock value of every `resume` call.
resumes: std.ArrayList(f64) = .empty,
disconnects: std.ArrayList(Handle) = .empty,
contexts_created: u32 = 0,
contexts_closed: u32 = 0,
/// The rate that the last `createContext` asked for.
requested_rate: ?u32 = null,
/// Releases of a handle that is not live, such as a double release.
bad_releases: u32 = 0,
/// Stops and disconnects of a handle that is not live.
bad_uses: u32 = 0,
live: std.ArrayList(Handle) = .empty,
next_handle: Handle = 1,

pub fn init(gpa: std.mem.Allocator) Fake {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Fake) void {
    for (self.plays.items) |entry| {
        for (entry.channels) |channel| self.gpa.free(channel);
        self.gpa.free(entry.channels);
    }
    self.plays.deinit(self.gpa);
    self.ramps.deinit(self.gpa);
    self.stops.deinit(self.gpa);
    self.resumes.deinit(self.gpa);
    self.disconnects.deinit(self.gpa);
    self.live.deinit(self.gpa);
}

pub fn binding(self: *Fake) api.Binding {
    return .{ .self = self, .table = &table };
}

/// The number of handles that the backend has not released.
pub fn liveHandles(self: *const Fake) usize {
    return self.live.items.len;
}

fn from(ptr: *anyopaque) *Fake {
    return @ptrCast(@alignCast(ptr));
}

fn isLive(self: *const Fake, h: Handle) bool {
    return std.mem.indexOfScalar(Handle, self.live.items, h) != null;
}

fn make(self: *Fake) Handle {
    const h = self.next_handle;
    self.next_handle += 1;
    self.live.append(self.gpa, h) catch @panic("fake out of memory");
    return h;
}

const table: api.Api = .{
    .available = available,
    .createContext = createContext,
    .close = close,
    .release = release,
    .currentTime = currentTime,
    .now = wallNow,
    .sampleRate = sampleRate,
    .state = state,
    .@"resume" = @"resume",
    .activated = activated,
    .transient = transient,
    .hidden = hidden,
    .maxChannels = maxChannels,
    .createGain = createGain,
    .rampGain = rampGain,
    .disconnect = disconnect,
    .play = play,
    .stopSource = stopSource,
};

fn available(ptr: *anyopaque) bool {
    return from(ptr).is_available;
}

fn createContext(ptr: *anyopaque, rate: ?u32) Handle {
    const self = from(ptr);
    self.requested_rate = rate;
    if (self.fail_create) return 0;
    if (rate) |r| if (self.honor_rate) {
        self.rate = @floatFromInt(r);
    };
    self.contexts_created += 1;
    self.ctx_state = self.new_state;
    return self.make();
}

fn close(ptr: *anyopaque, context: Handle) void {
    _ = context;
    const self = from(ptr);
    self.contexts_closed += 1;
    self.ctx_state = .closed;
}

fn release(ptr: *anyopaque, h: Handle) void {
    const self = from(ptr);
    const i = std.mem.indexOfScalar(Handle, self.live.items, h) orelse {
        self.bad_releases += 1;
        return;
    };
    _ = self.live.swapRemove(i);
}

fn currentTime(ptr: *anyopaque, context: Handle) f64 {
    _ = context;
    return from(ptr).now;
}

fn wallNow(ptr: *anyopaque) f64 {
    return from(ptr).wall_ms;
}

fn sampleRate(ptr: *anyopaque, context: Handle) f32 {
    _ = context;
    return from(ptr).rate;
}

fn state(ptr: *anyopaque, context: Handle) api.State {
    _ = context;
    return from(ptr).ctx_state;
}

fn @"resume"(ptr: *anyopaque, context: Handle) void {
    _ = context;
    const self = from(ptr);
    self.resumes.append(self.gpa, self.wall_ms) catch @panic("fake out of memory");
    if (self.resume_runs) self.ctx_state = .running;
}

fn activated(ptr: *anyopaque) bool {
    return from(ptr).is_activated;
}

fn transient(ptr: *anyopaque) bool {
    return from(ptr).is_transient;
}

fn hidden(ptr: *anyopaque) bool {
    return from(ptr).is_hidden;
}

fn maxChannels(ptr: *anyopaque, context: Handle) u32 {
    _ = context;
    return from(ptr).max_channels;
}

fn createGain(ptr: *anyopaque, context: Handle) Handle {
    _ = context;
    const self = from(ptr);
    if (self.fail_create) return 0;
    return self.make();
}

fn rampGain(ptr: *anyopaque, context: Handle, gain: Handle, value: f32, seconds: f64) void {
    _ = context;
    const self = from(ptr);
    self.ramps.append(self.gpa, .{ .gain = gain, .value = value, .seconds = seconds, .at = self.now }) catch @panic("fake out of memory");
}

fn disconnect(ptr: *anyopaque, node: Handle) void {
    const self = from(ptr);
    if (!self.isLive(node)) self.bad_uses += 1;
    self.disconnects.append(self.gpa, node) catch @panic("fake out of memory");
}

fn play(ptr: *anyopaque, context: Handle, gain: Handle, planar: []const []const f32, frames: u32, rate: f32, when: f64) Handle {
    const self = from(ptr);
    if (self.fail_play) return 0;
    const channels = self.gpa.alloc([]const f32, planar.len) catch @panic("fake out of memory");
    for (planar, channels) |source, *copy| {
        copy.* = self.gpa.dupe(f32, source[0..frames]) catch @panic("fake out of memory");
    }
    const src = self.make();
    self.plays.append(self.gpa, .{
        .context = context,
        .gain = gain,
        .src = src,
        .frames = frames,
        .rate = rate,
        .when = when,
        .channels = channels,
    }) catch @panic("fake out of memory");
    return src;
}

fn stopSource(ptr: *anyopaque, src: Handle, when: f64) void {
    const self = from(ptr);
    if (!self.isLive(src)) self.bad_uses += 1;
    self.stops.append(self.gpa, .{ .src = src, .when = when, .at = self.now }) catch @panic("fake out of memory");
}

test "the fake records plays and counts live handles" {
    var fake: Fake = .init(std.testing.allocator);
    defer fake.deinit();
    const b = fake.binding();
    const t = b.table;
    try std.testing.expect(t.available(b.self));
    const context = t.createContext(b.self, 44100);
    const gain = t.createGain(b.self, context);
    const left = [_]f32{ 0.5, -0.5, 0.25 };
    const right = [_]f32{ 1, 2, 3 };
    const src = t.play(b.self, context, gain, &.{ &left, &right }, 3, 44100, 0.125);
    try std.testing.expectEqual(@as(usize, 3), fake.liveHandles());
    try std.testing.expectEqual(@as(usize, 1), fake.plays.items.len);
    try std.testing.expectEqualSlices(f32, &right, fake.plays.items[0].channels[1]);
    try std.testing.expectEqual(@as(f64, 0.125), fake.plays.items[0].when);
    try std.testing.expectEqual(@as(f32, 44100), t.sampleRate(b.self, context));
    t.stopSource(b.self, src, 0);
    t.release(b.self, src);
    t.release(b.self, gain);
    t.release(b.self, context);
    try std.testing.expectEqual(@as(usize, 0), fake.liveHandles());
    try std.testing.expectEqual(@as(u32, 0), fake.bad_releases);
}

test "a new context starts in new_state and uses of released handles are counted" {
    var fake: Fake = .init(std.testing.allocator);
    defer fake.deinit();
    const b = fake.binding();
    const t = b.table;
    const first = t.createContext(b.self, null);
    t.close(b.self, first);
    try std.testing.expectEqual(api.State.closed, t.state(b.self, first));
    fake.new_state = .suspended;
    const second = t.createContext(b.self, null);
    try std.testing.expectEqual(api.State.suspended, t.state(b.self, second));
    fake.fail_play = true;
    const gain = t.createGain(b.self, second);
    try std.testing.expectEqual(@as(Handle, 0), t.play(b.self, second, gain, &.{}, 0, 48000, 0));
    t.release(b.self, gain);
    t.disconnect(b.self, gain);
    t.stopSource(b.self, gain, 0);
    try std.testing.expectEqual(@as(u32, 2), fake.bad_uses);
    t.release(b.self, first);
    t.release(b.self, second);
    try std.testing.expectEqual(@as(usize, 0), fake.liveHandles());
}
