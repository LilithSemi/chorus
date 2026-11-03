//! Gain ramps for audio buffers.
const std = @import("std");

pub const Ramp = struct {
    current: f32,
    target: f32,
    step: f32,
    remaining: u32,

    pub fn init(value: f32) Ramp {
        return .{ .current = value, .target = value, .step = 0, .remaining = 0 };
    }

    /// Moves to `target` over `frames` frames. 0 frames jumps at once.
    pub fn set(self: *Ramp, target: f32, frames: u32) void {
        self.target = target;
        if (frames == 0) {
            self.current = target;
            self.step = 0;
            self.remaining = 0;
            return;
        }
        self.step = (target - self.current) / @as(f32, @floatFromInt(frames));
        self.remaining = frames;
    }

    /// Interleaved. One gain value per frame, the same for every channel.
    pub fn apply(self: *Ramp, buf: []f32, channels: u8) void {
        std.debug.assert(channels > 0);
        std.debug.assert(buf.len % channels == 0);
        var i: usize = 0;
        while (i + channels <= buf.len) : (i += channels) {
            self.advance();
            for (buf[i..][0..channels]) |*s| s.* *= self.current;
        }
    }

    pub fn done(self: Ramp) bool {
        return self.remaining == 0;
    }

    fn advance(self: *Ramp) void {
        if (self.remaining == 0) return;
        self.remaining -= 1;
        self.current = if (self.remaining == 0) self.target else self.current + self.step;
    }
};

test "a ramp reaches its target on the last frame" {
    var ramp: Ramp = .init(0);
    ramp.set(1, 4);
    var buf: [5]f32 = @splat(1);
    ramp.apply(&buf, 1);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.5, 0.75, 1.0, 1.0 }, &buf);
    try std.testing.expect(ramp.done());
}

test "a ramp gives both channels of a frame the same gain" {
    var ramp: Ramp = .init(1);
    ramp.set(0, 2);
    var buf: [4]f32 = @splat(1);
    ramp.apply(&buf, 2);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.5, 0, 0 }, &buf);
}

test "zero frames jumps to the target" {
    var ramp: Ramp = .init(1);
    ramp.set(0.25, 0);
    var buf: [2]f32 = @splat(1);
    ramp.apply(&buf, 1);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.25 }, &buf);
}
