//! The seam between the web backend and the browser. The real table calls the Web Audio binding.
//! The fake table in `fake.zig` serves tests. The backend never touches the binding directly.

/// A reference to a browser object. 0 means none. The caller owns every handle that a call
/// returns and gives it back with `release`. A handle that a call takes is borrowed.
pub const Handle = u32;

pub const State = enum { suspended, running, closed, interrupted, unknown };

/// Every function takes `self` first. It is the `ctx` of the `Binding` that holds the table.
pub const Api = struct {
    /// True when the browser has an `AudioContext`.
    available: *const fn (self: *anyopaque) bool,
    /// Makes a context with the given rate, or with the browser rate when null. 0 means failure.
    createContext: *const fn (self: *anyopaque, rate: ?u32) Handle,
    close: *const fn (self: *anyopaque, context: Handle) void,
    release: *const fn (self: *anyopaque, h: Handle) void,
    currentTime: *const fn (self: *anyopaque, context: Handle) f64,
    /// A wall clock in milliseconds that keeps running while the context is suspended. The real
    /// table reads `performance.now()` through a webidl namespace, which needs no handle.
    now: *const fn (self: *anyopaque) f64,
    sampleRate: *const fn (self: *anyopaque, context: Handle) f32,
    state: *const fn (self: *anyopaque, context: Handle) State,
    @"resume": *const fn (self: *anyopaque, context: Handle) void,
    /// True after the user has interacted with the page, or when the browser has no such rule.
    activated: *const fn (self: *anyopaque) bool,
    /// True while the page is inside a user gesture. False when the browser has no such rule.
    transient: *const fn (self: *anyopaque) bool,
    /// True when the page is hidden.
    hidden: *const fn (self: *anyopaque) bool,
    maxChannels: *const fn (self: *anyopaque, context: Handle) u32,
    /// Makes a gain node that is connected to the destination. 0 means failure.
    createGain: *const fn (self: *anyopaque, context: Handle) Handle,
    /// Ramps the gain to `value` over `seconds`, from the current value, without a click.
    rampGain: *const fn (self: *anyopaque, context: Handle, gain: Handle, value: f32, seconds: f64) void,
    disconnect: *const fn (self: *anyopaque, node: Handle) void,
    /// Makes a buffer of `frames` frames at `rate`, copies one planar slice per channel into it,
    /// connects a source to `gain` and starts it at `when` seconds. Gives the source, or 0 on failure.
    play: *const fn (self: *anyopaque, context: Handle, gain: Handle, planar: []const []const f32, frames: u32, rate: f32, when: f64) Handle,
    stopSource: *const fn (self: *anyopaque, src: Handle, when: f64) void,
};

/// A table together with the state that its functions use.
pub const Binding = struct {
    self: *anyopaque,
    table: *const Api,
};
