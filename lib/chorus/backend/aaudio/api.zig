//! The AAudio constants and the function table of libaaudio.
const std = @import("std");
const builtin = @import("builtin");

pub const StreamBuilder = opaque {};
pub const AStream = opaque {};

pub const Result = i32;

pub const DataCallback = *const fn (?*AStream, ?*anyopaque, ?*anyopaque, i32) callconv(.c) i32;
pub const ErrorCallback = *const fn (?*AStream, ?*anyopaque, i32) callconv(.c) void;

pub const unspecified: i32 = 0;

pub const ResultCode = struct {
    /// The result codes are this value plus a small offset.
    pub const base: Result = -900;
    pub const ok: Result = 0;
    pub const disconnected: Result = -899;
    pub const illegal_argument: Result = -898;
    pub const internal: Result = -896;
    pub const invalid_state: Result = -895;
    pub const invalid_handle: Result = -892;
    pub const unimplemented: Result = -890;
    pub const unavailable: Result = -889;
    pub const no_free_handles: Result = -888;
    pub const no_memory: Result = -887;
    pub const null_pointer: Result = -886;
    pub const timeout: Result = -885;
    pub const would_block: Result = -884;
    pub const invalid_format: Result = -883;
    pub const out_of_range: Result = -882;
    pub const no_service: Result = -881;
    pub const invalid_rate: Result = -880;
};

pub const Direction = struct {
    pub const output: i32 = 0;
    pub const input: i32 = 1;
};

pub const Format = struct {
    pub const invalid: i32 = -1;
    pub const unspecified: i32 = 0;
    pub const pcm_i16: i32 = 1;
    pub const pcm_float: i32 = 2;
    pub const pcm_i24_packed: i32 = 3;
    pub const pcm_i32: i32 = 4;
    pub const iec61937: i32 = 5;
};

pub const State = struct {
    pub const uninitialized: i32 = 0;
    pub const unknown: i32 = 1;
    pub const open: i32 = 2;
    pub const starting: i32 = 3;
    pub const started: i32 = 4;
    pub const pausing: i32 = 5;
    pub const paused: i32 = 6;
    pub const flushing: i32 = 7;
    pub const flushed: i32 = 8;
    pub const stopping: i32 = 9;
    pub const stopped: i32 = 10;
    pub const closing: i32 = 11;
    pub const closed: i32 = 12;
    pub const disconnected: i32 = 13;
};

pub const SharingMode = struct {
    pub const exclusive: i32 = 0;
    pub const shared: i32 = 1;
};

pub const PerformanceMode = struct {
    pub const none: i32 = 10;
    pub const power_saving: i32 = 11;
    pub const low_latency: i32 = 12;
};

pub const CallbackResult = struct {
    pub const @"continue": i32 = 0;
    pub const stop: i32 = 1;
};

pub const Usage = struct {
    pub const media: i32 = 1;
    pub const voice_communication: i32 = 2;
    pub const voice_communication_signalling: i32 = 3;
    pub const alarm: i32 = 4;
    pub const notification: i32 = 5;
    pub const notification_ringtone: i32 = 6;
    pub const notification_event: i32 = 10;
    pub const assistance_accessibility: i32 = 11;
    pub const assistance_navigation_guidance: i32 = 12;
    pub const assistance_sonification: i32 = 13;
    pub const game: i32 = 14;
    pub const assistant: i32 = 16;
    pub const system_emergency: i32 = 1000;
    pub const system_safety: i32 = 1001;
    pub const system_vehicle_status: i32 = 1002;
    pub const system_announcement: i32 = 1003;
};

pub const ContentType = struct {
    pub const speech: i32 = 1;
    pub const music: i32 = 2;
    pub const movie: i32 = 3;
    pub const sonification: i32 = 4;
};

pub const InputPreset = struct {
    pub const generic: i32 = 1;
    pub const camcorder: i32 = 5;
    pub const voice_recognition: i32 = 6;
    pub const voice_communication: i32 = 7;
    pub const unprocessed: i32 = 9;
    pub const voice_performance: i32 = 10;
    pub const system_echo_reference: i32 = 1997;
    pub const system_hotword: i32 = 1999;
};

pub const SessionId = struct {
    pub const none: i32 = -1;
    pub const allocate: i32 = 0;
};

pub const AllowedCapturePolicy = struct {
    pub const all: i32 = 1;
    pub const system: i32 = 2;
    pub const none: i32 = 3;
};

pub const SpatializationBehavior = struct {
    pub const auto: i32 = 1;
    pub const never: i32 = 2;
};

/// The values of AudioDeviceInfo.getType. AAudio.h does not list them. The Java device scan returns them.
pub const DeviceType = struct {
    pub const unknown: i32 = 0;
    pub const builtin_earpiece: i32 = 1;
    pub const builtin_speaker: i32 = 2;
    pub const wired_headset: i32 = 3;
    pub const wired_headphones: i32 = 4;
    pub const line_analog: i32 = 5;
    pub const line_digital: i32 = 6;
    pub const bluetooth_sco: i32 = 7;
    pub const bluetooth_a2dp: i32 = 8;
    pub const hdmi: i32 = 9;
    pub const hdmi_arc: i32 = 10;
    pub const usb_device: i32 = 11;
    pub const usb_accessory: i32 = 12;
    pub const dock: i32 = 13;
    pub const fm: i32 = 14;
    pub const builtin_mic: i32 = 15;
    pub const fm_tuner: i32 = 16;
    pub const tv_tuner: i32 = 17;
    pub const telephony: i32 = 18;
    pub const aux_line: i32 = 19;
    pub const ip: i32 = 20;
    pub const bus: i32 = 21;
    pub const usb_headset: i32 = 22;
    pub const hearing_aid: i32 = 23;
    pub const builtin_speaker_safe: i32 = 24;
    pub const remote_submix: i32 = 25;
    pub const ble_headset: i32 = 26;
    pub const ble_speaker: i32 = 27;
    pub const hdmi_earc: i32 = 29;
    pub const ble_broadcast: i32 = 30;
    pub const dock_analog: i32 = 31;
    pub const multichannel_group: i32 = 32;
    pub const ble_hearing_aid: i32 = 33;
    pub const ble_central: i32 = 34;
    pub const ble_central_broadcast: i32 = 35;
};

pub const ChannelMask = struct {
    pub const front_left: u32 = 1 << 0;
    pub const front_right: u32 = 1 << 1;
    pub const front_center: u32 = 1 << 2;
    pub const low_frequency: u32 = 1 << 3;
    pub const back_left: u32 = 1 << 4;
    pub const back_right: u32 = 1 << 5;
    pub const front_left_of_center: u32 = 1 << 6;
    pub const front_right_of_center: u32 = 1 << 7;
    pub const back_center: u32 = 1 << 8;
    pub const side_left: u32 = 1 << 9;
    pub const side_right: u32 = 1 << 10;
    pub const top_center: u32 = 1 << 11;
    pub const top_front_left: u32 = 1 << 12;
    pub const top_front_center: u32 = 1 << 13;
    pub const top_front_right: u32 = 1 << 14;
    pub const top_back_left: u32 = 1 << 15;
    pub const top_back_center: u32 = 1 << 16;
    pub const top_back_right: u32 = 1 << 17;
    pub const top_side_left: u32 = 1 << 18;
    pub const top_side_right: u32 = 1 << 19;
    pub const bottom_front_left: u32 = 1 << 20;
    pub const bottom_front_center: u32 = 1 << 21;
    pub const bottom_front_right: u32 = 1 << 22;
    pub const low_frequency_2: u32 = 1 << 23;
    pub const front_wide_left: u32 = 1 << 24;
    pub const front_wide_right: u32 = 1 << 25;

    pub const invalid: u32 = 0xffffffff;
    pub const mono: u32 = front_left;
    pub const stereo: u32 = front_left | front_right;
    pub const stereo_2_1: u32 = stereo | low_frequency;
    pub const tri: u32 = stereo | front_center;
    pub const tri_back: u32 = stereo | back_center;
    pub const tri_3_1: u32 = tri | low_frequency;
    pub const quad: u32 = stereo | back_left | back_right;
    pub const quad_side: u32 = stereo | side_left | side_right;
    pub const surround: u32 = tri | back_center;
    pub const penta: u32 = quad | front_center;
    pub const surround_5_1: u32 = tri | low_frequency | back_left | back_right;
    pub const surround_5_1_side: u32 = tri | low_frequency | side_left | side_right;
    pub const surround_6_1: u32 = surround_5_1 | back_center;
    pub const surround_7_1: u32 = surround_5_1 | side_left | side_right;
};

/// The functions of libaaudio that the backend calls. A null optional field is a function that the
/// running system does not have. A test can fill the table with fake functions.
pub const Api = struct {
    createStreamBuilder: *const fn (*?*StreamBuilder) callconv(.c) Result,
    deleteBuilder: *const fn (*StreamBuilder) callconv(.c) Result,
    setDeviceId: *const fn (*StreamBuilder, i32) callconv(.c) void,
    setDirection: *const fn (*StreamBuilder, i32) callconv(.c) void,
    setSampleRate: *const fn (*StreamBuilder, i32) callconv(.c) void,
    setChannelCount: *const fn (*StreamBuilder, i32) callconv(.c) void,
    setFormat: *const fn (*StreamBuilder, i32) callconv(.c) void,
    setSharingMode: *const fn (*StreamBuilder, i32) callconv(.c) void,
    setPerformanceMode: *const fn (*StreamBuilder, i32) callconv(.c) void,
    setDataCallback: *const fn (*StreamBuilder, ?DataCallback, ?*anyopaque) callconv(.c) void,
    setErrorCallback: *const fn (*StreamBuilder, ?ErrorCallback, ?*anyopaque) callconv(.c) void,
    openStream: *const fn (*StreamBuilder, *?*AStream) callconv(.c) Result,
    requestStart: *const fn (*AStream) callconv(.c) Result,
    requestStop: *const fn (*AStream) callconv(.c) Result,
    close: *const fn (*AStream) callconv(.c) Result,
    getState: *const fn (*AStream) callconv(.c) i32,
    waitForStateChange: *const fn (*AStream, i32, ?*i32, i64) callconv(.c) Result,
    getSampleRate: *const fn (*AStream) callconv(.c) i32,
    getChannelCount: *const fn (*AStream) callconv(.c) i32,
    getFormat: *const fn (*AStream) callconv(.c) i32,
    getFramesPerBurst: *const fn (*AStream) callconv(.c) i32,
    getBufferCapacityInFrames: *const fn (*AStream) callconv(.c) i32,
    setBufferSizeInFrames: *const fn (*AStream, i32) callconv(.c) Result,
    getXRunCount: *const fn (*AStream) callconv(.c) i32,
    /// API 28.
    setUsage: ?*const fn (*StreamBuilder, i32) callconv(.c) void = null,
    /// API 28.
    setContentType: ?*const fn (*StreamBuilder, i32) callconv(.c) void = null,
    /// API 28.
    setInputPreset: ?*const fn (*StreamBuilder, i32) callconv(.c) void = null,
    /// API 32.
    setChannelMask: ?*const fn (*StreamBuilder, u32) callconv(.c) void = null,
};

const android_api: u32 = if (builtin.abi.isAndroid()) builtin.os.version_range.linux.android else 0;

/// Strong when the target API has the function, weak otherwise.
fn sinceApi(comptime level: u32, comptime T: type, comptime name: []const u8) ?*const T {
    if (android_api >= level) {
        return @extern(*const T, .{ .name = name, .library_name = "aaudio" });
    }
    return @extern(?*const T, .{ .name = name, .library_name = "aaudio", .linkage = .weak });
}

fn makeNative() Api {
    const c = struct {
        extern "aaudio" fn AAudio_createStreamBuilder(*?*StreamBuilder) callconv(.c) Result;
        extern "aaudio" fn AAudioStreamBuilder_delete(*StreamBuilder) callconv(.c) Result;
        extern "aaudio" fn AAudioStreamBuilder_setDeviceId(*StreamBuilder, i32) callconv(.c) void;
        extern "aaudio" fn AAudioStreamBuilder_setDirection(*StreamBuilder, i32) callconv(.c) void;
        extern "aaudio" fn AAudioStreamBuilder_setSampleRate(*StreamBuilder, i32) callconv(.c) void;
        extern "aaudio" fn AAudioStreamBuilder_setChannelCount(*StreamBuilder, i32) callconv(.c) void;
        extern "aaudio" fn AAudioStreamBuilder_setFormat(*StreamBuilder, i32) callconv(.c) void;
        extern "aaudio" fn AAudioStreamBuilder_setSharingMode(*StreamBuilder, i32) callconv(.c) void;
        extern "aaudio" fn AAudioStreamBuilder_setPerformanceMode(*StreamBuilder, i32) callconv(.c) void;
        extern "aaudio" fn AAudioStreamBuilder_setDataCallback(*StreamBuilder, ?DataCallback, ?*anyopaque) callconv(.c) void;
        extern "aaudio" fn AAudioStreamBuilder_setErrorCallback(*StreamBuilder, ?ErrorCallback, ?*anyopaque) callconv(.c) void;
        extern "aaudio" fn AAudioStreamBuilder_openStream(*StreamBuilder, *?*AStream) callconv(.c) Result;
        extern "aaudio" fn AAudioStream_requestStart(*AStream) callconv(.c) Result;
        extern "aaudio" fn AAudioStream_requestStop(*AStream) callconv(.c) Result;
        extern "aaudio" fn AAudioStream_close(*AStream) callconv(.c) Result;
        extern "aaudio" fn AAudioStream_getState(*AStream) callconv(.c) i32;
        extern "aaudio" fn AAudioStream_waitForStateChange(*AStream, i32, ?*i32, i64) callconv(.c) Result;
        extern "aaudio" fn AAudioStream_getSampleRate(*AStream) callconv(.c) i32;
        extern "aaudio" fn AAudioStream_getChannelCount(*AStream) callconv(.c) i32;
        extern "aaudio" fn AAudioStream_getFormat(*AStream) callconv(.c) i32;
        extern "aaudio" fn AAudioStream_getFramesPerBurst(*AStream) callconv(.c) i32;
        extern "aaudio" fn AAudioStream_getBufferCapacityInFrames(*AStream) callconv(.c) i32;
        extern "aaudio" fn AAudioStream_setBufferSizeInFrames(*AStream, i32) callconv(.c) Result;
        extern "aaudio" fn AAudioStream_getXRunCount(*AStream) callconv(.c) i32;
    };
    return .{
        .createStreamBuilder = &c.AAudio_createStreamBuilder,
        .deleteBuilder = &c.AAudioStreamBuilder_delete,
        .setDeviceId = &c.AAudioStreamBuilder_setDeviceId,
        .setDirection = &c.AAudioStreamBuilder_setDirection,
        .setSampleRate = &c.AAudioStreamBuilder_setSampleRate,
        .setChannelCount = &c.AAudioStreamBuilder_setChannelCount,
        .setFormat = &c.AAudioStreamBuilder_setFormat,
        .setSharingMode = &c.AAudioStreamBuilder_setSharingMode,
        .setPerformanceMode = &c.AAudioStreamBuilder_setPerformanceMode,
        .setDataCallback = &c.AAudioStreamBuilder_setDataCallback,
        .setErrorCallback = &c.AAudioStreamBuilder_setErrorCallback,
        .openStream = &c.AAudioStreamBuilder_openStream,
        .requestStart = &c.AAudioStream_requestStart,
        .requestStop = &c.AAudioStream_requestStop,
        .close = &c.AAudioStream_close,
        .getState = &c.AAudioStream_getState,
        .waitForStateChange = &c.AAudioStream_waitForStateChange,
        .getSampleRate = &c.AAudioStream_getSampleRate,
        .getChannelCount = &c.AAudioStream_getChannelCount,
        .getFormat = &c.AAudioStream_getFormat,
        .getFramesPerBurst = &c.AAudioStream_getFramesPerBurst,
        .getBufferCapacityInFrames = &c.AAudioStream_getBufferCapacityInFrames,
        .setBufferSizeInFrames = &c.AAudioStream_setBufferSizeInFrames,
        .getXRunCount = &c.AAudioStream_getXRunCount,
        .setUsage = sinceApi(28, fn (*StreamBuilder, i32) callconv(.c) void, "AAudioStreamBuilder_setUsage"),
        .setContentType = sinceApi(28, fn (*StreamBuilder, i32) callconv(.c) void, "AAudioStreamBuilder_setContentType"),
        .setInputPreset = sinceApi(28, fn (*StreamBuilder, i32) callconv(.c) void, "AAudioStreamBuilder_setInputPreset"),
        .setChannelMask = sinceApi(32, fn (*StreamBuilder, u32) callconv(.c) void, "AAudioStreamBuilder_setChannelMask"),
    };
}

const native_table: Api = if (builtin.abi.isAndroid()) makeNative() else @compileError("the native AAudio table exists only on Android");

/// The table of the system libaaudio. The compiler treats a weak symbol in a constant as present,
/// so the copy goes through an optimization barrier and its null checks stay. Keep the result in
/// heap state and call through a pointer to it.
pub fn loadNative() Api {
    if (@inComptime()) @compileError("loadNative runs at run time");
    var table = native_table;
    std.mem.doNotOptimizeAway(&table);
    return table;
}

test "constants match the NDK header" {
    const t = std.testing;
    try t.expectEqual(@as(Result, -899), ResultCode.disconnected);
    try t.expectEqual(@as(Result, -880), ResultCode.invalid_rate);
    try t.expectEqual(@as(Result, -881), ResultCode.no_service);
    try t.expectEqual(@as(i32, 1), Format.pcm_i16);
    try t.expectEqual(@as(i32, 2), Format.pcm_float);
    try t.expectEqual(@as(i32, 3), Format.pcm_i24_packed);
    try t.expectEqual(@as(i32, 4), Format.pcm_i32);
    try t.expectEqual(@as(i32, 13), State.disconnected);
    try t.expectEqual(@as(i32, 12), PerformanceMode.low_latency);
    try t.expectEqual(@as(i32, 14), Usage.game);
    try t.expectEqual(@as(i32, 13), Usage.assistance_sonification);
    try t.expectEqual(@as(i32, 7), InputPreset.voice_communication);
    try t.expectEqual(@as(u32, 1 << 25), ChannelMask.front_wide_right);
    try t.expectEqual(@as(u32, 0x3f), ChannelMask.surround_5_1);
    try t.expectEqual(@as(u32, 0x63f), ChannelMask.surround_7_1);
}

test "the native table has every required function" {
    if (!builtin.abi.isAndroid()) return error.SkipZigTest;
    const table = loadNative();
    const info = @typeInfo(Api).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        if (@typeInfo(T) != .optional) {
            try std.testing.expect(@intFromPtr(@field(table, name)) != 0);
        }
    }
    if (android_api >= 28) {
        try std.testing.expect(table.setUsage != null);
        try std.testing.expect(table.setContentType != null);
        try std.testing.expect(table.setInputPreset != null);
    }
}

test "more constants match the NDK header" {
    const t = std.testing;
    try t.expectEqual(@as(Result, -900), ResultCode.base);
    try t.expectEqual(@as(i32, 5), Format.iec61937);
    try t.expectEqual(@as(i32, 1003), Usage.system_announcement);
    try t.expectEqual(@as(i32, 1999), InputPreset.system_hotword);
    try t.expectEqual(@as(i32, -1), SessionId.none);
    try t.expectEqual(@as(i32, 3), AllowedCapturePolicy.none);
    try t.expectEqual(@as(i32, 2), SpatializationBehavior.never);
    try t.expectEqual(@as(i32, 35), DeviceType.ble_central_broadcast);
    try t.expectEqual(@as(u32, 0xb), ChannelMask.stereo_2_1);
    try t.expectEqual(@as(u32, 0x103), ChannelMask.tri_back);
    try t.expectEqual(@as(u32, 0xf), ChannelMask.tri_3_1);
    try t.expectEqual(@as(u32, 0x603), ChannelMask.quad_side);
    try t.expectEqual(@as(u32, 0x107), ChannelMask.surround);
    try t.expectEqual(@as(u32, 0x60f), ChannelMask.surround_5_1_side);
}
