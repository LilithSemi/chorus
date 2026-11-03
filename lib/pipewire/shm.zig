//! Shared memory layouts of the PipeWire server and client. The offsets are the same on 32 bit
//! and 64 bit builds.
const std = @import("std");
const builtin = @import("builtin");

pub const Fraction = extern struct {
    num: u32,
    denom: u32,
};

pub const Rectangle = extern struct {
    width: u32,
    height: u32,
};

pub const ActivationStatus = enum(u32) {
    not_triggered = 0,
    triggered = 1,
    awake = 2,
    finished = 3,
    inactive = 4,
    _,
};

pub const PositionState = enum(u32) {
    stopped = 0,
    starting = 1,
    running = 2,
    _,
};

pub const ActivationCommand = enum(u32) {
    none = 0,
    start = 1,
    stop = 2,
    _,
};

pub const activation_version_bit = 1 << 0;
pub const pending_sync_bit = 1 << 1;
pub const pending_new_pos_bit = 1 << 2;

/// Bit of `NodeActivation.flags`: the server treats the node as async.
pub const activation_flag_async = 1 << 1;

pub const status_need_data: i32 = 1 << 0;
pub const status_have_data: i32 = 1 << 1;

pub const IoBuffers = extern struct {
    status: i32,
    buffer_id: u32,
};

pub const IoAsyncBuffers = extern struct {
    buffers: [2]IoBuffers,
};

pub const IoClock = extern struct {
    flags: u32,
    id: u32,
    name: [64]u8,
    nsec: u64,
    rate: Fraction,
    position: u64,
    duration: u64,
    delay: i64,
    rate_diff: f64,
    next_nsec: u64,
    target_rate: Fraction,
    target_duration: u64,
    target_seq: u32,
    cycle: u32,
    xrun: u64,
};

pub const IoVideoSize = extern struct {
    flags: u32,
    stride: u32,
    size: Rectangle,
    framerate: Fraction,
    padding: [4]u32,
};

pub const IoSegmentBar = extern struct {
    flags: u32,
    offset: u32,
    signature_num: f32,
    signature_denom: f32,
    bpm: f64,
    beat: f64,
    bar_start_tick: f64,
    ticks_per_beat: f64,
    padding: [4]u32,
};

pub const IoSegmentVideo = extern struct {
    flags: u32,
    offset: u32,
    framerate: Fraction,
    hours: u32,
    minutes: u32,
    seconds: u32,
    frames: u32,
    field_count: u32,
    padding: [11]u32,
};

pub const IoSegment = extern struct {
    version: u32,
    flags: u32,
    start: u64,
    duration: u64,
    rate: f64,
    position: u64,
    bar: IoSegmentBar,
    video: IoSegmentVideo,
};

pub const IoPosition = extern struct {
    clock: IoClock,
    video: IoVideoSize,
    offset: i64,
    state: PositionState,
    n_segments: u32,
    segments: [8]IoSegment,
};

pub const IoRateMatch = extern struct {
    delay: u32,
    size: u32,
    rate: f64,
    flags: u32,
    delay_frac: i32,
    padding: [6]u32,
};

pub const ActivationState = extern struct {
    status: i32,
    required: i32,
    pending: i32,
};

pub const NodeActivation = extern struct {
    status: ActivationStatus,
    bits: u32,
    state: [2]ActivationState,
    signal_time: u64,
    awake_time: u64,
    finish_time: u64,
    prev_signal_time: u64,
    reposition: IoSegment,
    segment: IoSegment,
    segment_owner: [16]u32,
    prev_awake_time: u64,
    prev_finish_time: u64,
    padding: [7]u32,
    client_version: u32,
    server_version: u32,
    active_driver_id: u32,
    driver_id: u32,
    flags: u32,
    position: IoPosition,
    sync_timeout: u64,
    sync_left: u64,
    cpu_load: [3]f32,
    xrun_count: u32,
    xrun_time: u64,
    xrun_delay: u64,
    max_delay: u64,
    command: ActivationCommand,
    reposition_owner: u32,
};

pub const Chunk = extern struct {
    offset: u32,
    size: u32,
    stride: i32,
    flags: i32,
};

pub const MetaHeader = extern struct {
    flags: u32,
    offset: u32,
    seq: u64,
    pts: i64,
    dts_offset: i64,
};

fn expectOffset(comptime T: type, comptime field: []const u8, comptime want: usize) void {
    const got = @offsetOf(T, field);
    if (got != want) {
        @compileError(std.fmt.comptimePrint("{s}.{s} is at offset {d}, want {d}", .{ @typeName(T), field, got, want }));
    }
}

fn expectSize(comptime T: type, comptime want: usize) void {
    const got = @sizeOf(T);
    if (got != want) {
        @compileError(std.fmt.comptimePrint("{s} is {d} bytes, want {d}", .{ @typeName(T), got, want }));
    }
}

comptime {
    expectSize(Fraction, 8);
    expectSize(Rectangle, 8);

    expectSize(IoBuffers, 8);
    expectOffset(IoBuffers, "status", 0);
    expectOffset(IoBuffers, "buffer_id", 4);

    expectSize(IoAsyncBuffers, 16);
    expectOffset(IoAsyncBuffers, "buffers", 0);

    expectSize(IoClock, 160);
    expectOffset(IoClock, "flags", 0);
    expectOffset(IoClock, "id", 4);
    expectOffset(IoClock, "name", 8);
    expectOffset(IoClock, "nsec", 72);
    expectOffset(IoClock, "rate", 80);
    expectOffset(IoClock, "position", 88);
    expectOffset(IoClock, "duration", 96);
    expectOffset(IoClock, "delay", 104);
    expectOffset(IoClock, "rate_diff", 112);
    expectOffset(IoClock, "next_nsec", 120);
    expectOffset(IoClock, "target_rate", 128);
    expectOffset(IoClock, "target_duration", 136);
    expectOffset(IoClock, "target_seq", 144);
    expectOffset(IoClock, "cycle", 148);
    expectOffset(IoClock, "xrun", 152);

    expectSize(IoVideoSize, 40);
    expectOffset(IoVideoSize, "flags", 0);
    expectOffset(IoVideoSize, "stride", 4);
    expectOffset(IoVideoSize, "size", 8);
    expectOffset(IoVideoSize, "framerate", 16);
    expectOffset(IoVideoSize, "padding", 24);

    expectSize(IoSegmentBar, 64);
    expectOffset(IoSegmentBar, "flags", 0);
    expectOffset(IoSegmentBar, "offset", 4);
    expectOffset(IoSegmentBar, "signature_num", 8);
    expectOffset(IoSegmentBar, "signature_denom", 12);
    expectOffset(IoSegmentBar, "bpm", 16);
    expectOffset(IoSegmentBar, "beat", 24);
    expectOffset(IoSegmentBar, "bar_start_tick", 32);
    expectOffset(IoSegmentBar, "ticks_per_beat", 40);
    expectOffset(IoSegmentBar, "padding", 48);

    expectSize(IoSegmentVideo, 80);
    expectOffset(IoSegmentVideo, "flags", 0);
    expectOffset(IoSegmentVideo, "offset", 4);
    expectOffset(IoSegmentVideo, "framerate", 8);
    expectOffset(IoSegmentVideo, "hours", 16);
    expectOffset(IoSegmentVideo, "minutes", 20);
    expectOffset(IoSegmentVideo, "seconds", 24);
    expectOffset(IoSegmentVideo, "frames", 28);
    expectOffset(IoSegmentVideo, "field_count", 32);
    expectOffset(IoSegmentVideo, "padding", 36);

    expectSize(IoSegment, 184);
    expectOffset(IoSegment, "version", 0);
    expectOffset(IoSegment, "flags", 4);
    expectOffset(IoSegment, "start", 8);
    expectOffset(IoSegment, "duration", 16);
    expectOffset(IoSegment, "rate", 24);
    expectOffset(IoSegment, "position", 32);
    expectOffset(IoSegment, "bar", 40);
    expectOffset(IoSegment, "video", 104);

    expectSize(IoPosition, 1688);
    expectOffset(IoPosition, "clock", 0);
    expectOffset(IoPosition, "video", 160);
    expectOffset(IoPosition, "offset", 200);
    expectOffset(IoPosition, "state", 208);
    expectOffset(IoPosition, "n_segments", 212);
    expectOffset(IoPosition, "segments", 216);

    expectSize(IoRateMatch, 48);
    expectOffset(IoRateMatch, "delay", 0);
    expectOffset(IoRateMatch, "size", 4);
    expectOffset(IoRateMatch, "rate", 8);
    expectOffset(IoRateMatch, "flags", 16);
    expectOffset(IoRateMatch, "delay_frac", 20);
    expectOffset(IoRateMatch, "padding", 24);

    expectSize(ActivationState, 12);
    expectOffset(ActivationState, "status", 0);
    expectOffset(ActivationState, "required", 4);
    expectOffset(ActivationState, "pending", 8);

    expectSize(NodeActivation, 2312);
    expectOffset(NodeActivation, "status", 0);
    expectOffset(NodeActivation, "bits", 4);
    expectOffset(NodeActivation, "state", 8);
    expectOffset(NodeActivation, "signal_time", 32);
    expectOffset(NodeActivation, "awake_time", 40);
    expectOffset(NodeActivation, "finish_time", 48);
    expectOffset(NodeActivation, "prev_signal_time", 56);
    expectOffset(NodeActivation, "reposition", 64);
    expectOffset(NodeActivation, "segment", 248);
    expectOffset(NodeActivation, "segment_owner", 432);
    expectOffset(NodeActivation, "prev_awake_time", 496);
    expectOffset(NodeActivation, "prev_finish_time", 504);
    expectOffset(NodeActivation, "padding", 512);
    expectOffset(NodeActivation, "client_version", 540);
    expectOffset(NodeActivation, "server_version", 544);
    expectOffset(NodeActivation, "active_driver_id", 548);
    expectOffset(NodeActivation, "driver_id", 552);
    expectOffset(NodeActivation, "flags", 556);
    expectOffset(NodeActivation, "position", 560);
    expectOffset(NodeActivation, "sync_timeout", 2248);
    expectOffset(NodeActivation, "sync_left", 2256);
    expectOffset(NodeActivation, "cpu_load", 2264);
    expectOffset(NodeActivation, "xrun_count", 2276);
    expectOffset(NodeActivation, "xrun_time", 2280);
    expectOffset(NodeActivation, "xrun_delay", 2288);
    expectOffset(NodeActivation, "max_delay", 2296);
    expectOffset(NodeActivation, "command", 2304);
    expectOffset(NodeActivation, "reposition_owner", 2308);

    expectSize(Chunk, 16);
    expectOffset(Chunk, "offset", 0);
    expectOffset(Chunk, "size", 4);
    expectOffset(Chunk, "stride", 8);
    expectOffset(Chunk, "flags", 12);

    expectSize(MetaHeader, 32);
    expectOffset(MetaHeader, "flags", 0);
    expectOffset(MetaHeader, "offset", 4);
    expectOffset(MetaHeader, "seq", 8);
    expectOffset(MetaHeader, "pts", 16);
    expectOffset(MetaHeader, "dts_offset", 24);
}

const native_u64_atomic = @sizeOf(usize) >= 8;

/// A 64 bit field in shared memory. A target with no 64 bit atomics writes the low half and then
/// the high half. A reader that runs during the write would see a value that is wrong by a multiple
/// of 2^32. No reader does, because the status change or the eventfd publishes these fields.
pub fn store64(ptr: *u64, value: u64) void {
    if (native_u64_atomic) return @atomicStore(u64, ptr, value, .monotonic);
    const halves: *[2]u32 = @ptrCast(ptr);
    const low = @intFromBool(builtin.cpu.arch.endian() == .big);
    @atomicStore(u32, &halves[low], @truncate(value), .monotonic);
    @atomicStore(u32, &halves[1 - low], @truncate(value >> 32), .monotonic);
}

/// Reads the high half twice, so a change of the high half between the two reads repeats the read.
pub fn load64(ptr: *const u64) u64 {
    if (native_u64_atomic) return @atomicLoad(u64, ptr, .monotonic);
    const halves: *const [2]u32 = @ptrCast(ptr);
    const low = @intFromBool(builtin.cpu.arch.endian() == .big);
    while (true) {
        const high = @atomicLoad(u32, &halves[1 - low], .monotonic);
        const lo = @atomicLoad(u32, &halves[low], .monotonic);
        if (@atomicLoad(u32, &halves[1 - low], .monotonic) == high) return @as(u64, high) << 32 | lo;
    }
}

test "shm layouts match the IC offsets" {
    try std.testing.expectEqual(@as(usize, 2312), @sizeOf(NodeActivation));
    try std.testing.expectEqual(@as(usize, 544), @offsetOf(NodeActivation, "server_version"));
    try std.testing.expectEqual(@as(u32, 1 << 2), pending_new_pos_bit);
}

test "store64 and load64 round trip a value with both halves set" {
    var value: u64 = 0;
    store64(&value, 0x0123_4567_89ab_cdef);
    try std.testing.expectEqual(@as(u64, 0x0123_4567_89ab_cdef), load64(&value));
    try std.testing.expectEqual(@as(u64, 0x0123_4567_89ab_cdef), value);
}
