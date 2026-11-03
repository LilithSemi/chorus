//! Numeric tables of the SPA headers used by the PipeWire native protocol.
//! Every enum is non-exhaustive, so any value from the wire decodes safely.

pub const id_invalid: u32 = 0xffffffff;
pub const max_channels = 64;

pub const Fraction = struct {
    num: u32,
    denom: u32,
};

pub const Rectangle = struct {
    width: u32,
    height: u32,
};

pub const Direction = enum(u32) {
    input = 0,
    output = 1,
    _,
};

pub const ChoiceType = enum(u32) {
    none = 0,
    range = 1,
    step = 2,
    @"enum" = 3,
    flags = 4,
    _,
};

pub const Type = enum(u32) {
    none = 0x1,
    bool = 0x2,
    id = 0x3,
    int = 0x4,
    long = 0x5,
    float = 0x6,
    double = 0x7,
    string = 0x8,
    bytes = 0x9,
    rectangle = 0xa,
    fraction = 0xb,
    bitmap = 0xc,
    array = 0xd,
    @"struct" = 0xe,
    object = 0xf,
    sequence = 0x10,
    pointer = 0x11,
    fd = 0x12,
    choice = 0x13,
    pod = 0x14,
    pointer_buffer = 0x10001,
    pointer_meta = 0x10002,
    pointer_dict = 0x10003,
    _,
};

pub const ObjectType = enum(u32) {
    event_device = 0x20001,
    event_node = 0x20002,
    command_device = 0x30001,
    command_node = 0x30002,
    prop_info = 0x40001,
    props = 0x40002,
    format = 0x40003,
    param_buffers = 0x40004,
    param_meta = 0x40005,
    param_io = 0x40006,
    param_profile = 0x40007,
    param_port_config = 0x40008,
    param_route = 0x40009,
    profiler = 0x4000a,
    param_latency = 0x4000b,
    param_process_latency = 0x4000c,
    param_tag = 0x4000d,
    peer_param = 0x4000e,
    param_dict = 0x4000f,
    _,
};

pub const ParamType = enum(u32) {
    invalid = 0x0,
    prop_info = 0x1,
    props = 0x2,
    enum_format = 0x3,
    format = 0x4,
    buffers = 0x5,
    meta = 0x6,
    io = 0x7,
    enum_profile = 0x8,
    profile = 0x9,
    enum_port_config = 0xa,
    port_config = 0xb,
    enum_route = 0xc,
    route = 0xd,
    control = 0xe,
    latency = 0xf,
    process_latency = 0x10,
    tag = 0x11,
    peer_enum_format = 0x12,
    capability = 0x13,
    peer_capability = 0x14,
    _,
};

pub const PropInfoKey = enum(u32) {
    id = 0x1,
    name = 0x2,
    type = 0x3,
    labels = 0x4,
    container = 0x5,
    params = 0x6,
    description = 0x7,
    _,
};

pub const PropKey = enum(u32) {
    unknown = 0x1,
    device = 0x101,
    device_name = 0x102,
    device_fd = 0x103,
    card = 0x104,
    card_name = 0x105,
    min_latency = 0x106,
    max_latency = 0x107,
    periods = 0x108,
    period_size = 0x109,
    period_event = 0x10a,
    live = 0x10b,
    rate = 0x10c,
    quality = 0x10d,
    bluetooth_audio_codec = 0x10e,
    bluetooth_offload_active = 0x10f,
    clock_id = 0x110,
    clock_device = 0x111,
    clock_interface = 0x112,
    wave_type = 0x10001,
    frequency = 0x10002,
    volume = 0x10003,
    mute = 0x10004,
    pattern_type = 0x10005,
    dither_type = 0x10006,
    truncate = 0x10007,
    channel_volumes = 0x10008,
    volume_base = 0x10009,
    volume_step = 0x1000a,
    channel_map = 0x1000b,
    monitor_mute = 0x1000c,
    monitor_volumes = 0x1000d,
    latency_offset_nsec = 0x1000e,
    soft_mute = 0x1000f,
    soft_volumes = 0x10010,
    iec958_codecs = 0x10011,
    volume_ramp_samples = 0x10012,
    volume_ramp_step_samples = 0x10013,
    volume_ramp_time = 0x10014,
    volume_ramp_step_time = 0x10015,
    volume_ramp_scale = 0x10016,
    params = 0x80001,
    _,
};

pub const FormatKey = enum(u32) {
    media_type = 0x1,
    media_subtype = 0x2,
    audio_format = 0x10001,
    audio_flags = 0x10002,
    audio_rate = 0x10003,
    audio_channels = 0x10004,
    audio_position = 0x10005,
    audio_iec958_codec = 0x10006,
    audio_bitorder = 0x10007,
    audio_interleave = 0x10008,
    audio_bitrate = 0x10009,
    audio_block_align = 0x1000a,
    audio_aac_stream_format = 0x1000b,
    audio_wma_profile = 0x1000c,
    audio_amr_band_mode = 0x1000d,
    audio_mp3_channel_mode = 0x1000e,
    audio_dts_ext_type = 0x1000f,
    control_types = 0x60001,
    _,
};

pub const MediaType = enum(u32) {
    unknown = 0x0,
    audio = 0x1,
    video = 0x2,
    image = 0x3,
    binary = 0x4,
    stream = 0x5,
    application = 0x6,
    _,
};

pub const MediaSubtype = enum(u32) {
    unknown = 0x0,
    raw = 0x1,
    dsp = 0x2,
    iec958 = 0x3,
    dsd = 0x4,
    mp3 = 0x10001,
    aac = 0x10002,
    vorbis = 0x10003,
    wma = 0x10004,
    ra = 0x10005,
    sbc = 0x10006,
    adpcm = 0x10007,
    g723 = 0x10008,
    g726 = 0x10009,
    g729 = 0x1000a,
    amr = 0x1000b,
    gsm = 0x1000c,
    alac = 0x1000d,
    flac = 0x1000e,
    ape = 0x1000f,
    opus = 0x10010,
    ac3 = 0x10011,
    eac3 = 0x10012,
    truehd = 0x10013,
    dts = 0x10014,
    mpegh = 0x10015,
    _,
};

pub const AudioFormat = enum(u32) {
    unknown = 0x0,
    encoded = 0x1,
    s8 = 0x101,
    u8 = 0x102,
    s16_le = 0x103,
    s16_be = 0x104,
    u16_le = 0x105,
    u16_be = 0x106,
    s24_32_le = 0x107,
    s24_32_be = 0x108,
    u24_32_le = 0x109,
    u24_32_be = 0x10a,
    s32_le = 0x10b,
    s32_be = 0x10c,
    u32_le = 0x10d,
    u32_be = 0x10e,
    s24_le = 0x10f,
    s24_be = 0x110,
    u24_le = 0x111,
    u24_be = 0x112,
    s20_le = 0x113,
    s20_be = 0x114,
    u20_le = 0x115,
    u20_be = 0x116,
    s18_le = 0x117,
    s18_be = 0x118,
    u18_le = 0x119,
    u18_be = 0x11a,
    f32_le = 0x11b,
    f32_be = 0x11c,
    f64_le = 0x11d,
    f64_be = 0x11e,
    ulaw = 0x11f,
    alaw = 0x120,
    u8p = 0x201,
    s16p = 0x202,
    s24_32p = 0x203,
    s32p = 0x204,
    s24p = 0x205,
    f32p = 0x206,
    f64p = 0x207,
    s8p = 0x208,
    _,

    pub const dsp_s32: AudioFormat = .s24_32p;
    pub const dsp_f32: AudioFormat = .f32p;
    pub const dsp_f64: AudioFormat = .f64p;
};

pub const AudioChannel = enum(u32) {
    unknown = 0x0,
    na = 0x1,
    mono = 0x2,
    fl = 0x3,
    fr = 0x4,
    fc = 0x5,
    lfe = 0x6,
    sl = 0x7,
    sr = 0x8,
    flc = 0x9,
    frc = 0xa,
    rc = 0xb,
    rl = 0xc,
    rr = 0xd,
    tc = 0xe,
    tfl = 0xf,
    tfc = 0x10,
    tfr = 0x11,
    trl = 0x12,
    trc = 0x13,
    trr = 0x14,
    rlc = 0x15,
    rrc = 0x16,
    flw = 0x17,
    frw = 0x18,
    lfe2 = 0x19,
    flh = 0x1a,
    fch = 0x1b,
    frh = 0x1c,
    tflc = 0x1d,
    tfrc = 0x1e,
    tsl = 0x1f,
    tsr = 0x20,
    llfe = 0x21,
    rlfe = 0x22,
    bc = 0x23,
    blc = 0x24,
    brc = 0x25,
    _,

    pub const aux_first: u32 = 0x1000;
    pub const aux_last: u32 = 0x1fff;
    pub const custom_first: u32 = 0x10000;

    pub fn aux(n: u32) AudioChannel {
        return @fromBackingInt(@intCast(aux_first + n));
    }
};

pub const ParamBuffersKey = enum(u32) {
    buffers = 0x1,
    blocks = 0x2,
    size = 0x3,
    stride = 0x4,
    @"align" = 0x5,
    data_type = 0x6,
    meta_type = 0x7,
    _,
};

pub const ParamMetaKey = enum(u32) {
    type = 0x1,
    size = 0x2,
    features = 0x3,
    _,
};

pub const MetaType = enum(u32) {
    invalid = 0x0,
    header = 0x1,
    video_crop = 0x2,
    video_damage = 0x3,
    bitmap = 0x4,
    cursor = 0x5,
    control = 0x6,
    busy = 0x7,
    video_transform = 0x8,
    sync_timeline = 0x9,
    _,
};

pub const ParamIoKey = enum(u32) {
    id = 0x1,
    size = 0x2,
    _,
};

pub const IoType = enum(u32) {
    invalid = 0x0,
    buffers = 0x1,
    range = 0x2,
    clock = 0x3,
    latency = 0x4,
    control = 0x5,
    notify = 0x6,
    position = 0x7,
    rate_match = 0x8,
    memory = 0x9,
    async_buffers = 0xa,
    _,
};

pub const DataType = enum(u32) {
    invalid = 0x0,
    mem_ptr = 0x1,
    mem_fd = 0x2,
    dma_buf = 0x3,
    mem_id = 0x4,
    sync_obj = 0x5,
    _,
};

pub const ParamRouteKey = enum(u32) {
    index = 0x1,
    direction = 0x2,
    device = 0x3,
    name = 0x4,
    description = 0x5,
    priority = 0x6,
    available = 0x7,
    info = 0x8,
    profiles = 0x9,
    props = 0xa,
    devices = 0xb,
    profile = 0xc,
    save = 0xd,
    _,
};

pub const ParamProfileKey = enum(u32) {
    index = 0x1,
    name = 0x2,
    description = 0x3,
    priority = 0x4,
    available = 0x5,
    info = 0x6,
    classes = 0x7,
    save = 0x8,
    _,
};

pub const ParamPortConfigKey = enum(u32) {
    direction = 0x1,
    mode = 0x2,
    monitor = 0x3,
    control = 0x4,
    format = 0x5,
    _,
};

pub const PortConfigMode = enum(u32) {
    none = 0x0,
    passthrough = 0x1,
    convert = 0x2,
    dsp = 0x3,
    _,
};

pub const ParamLatencyKey = enum(u32) {
    direction = 1,
    min_quantum = 2,
    max_quantum = 3,
    min_rate = 4,
    max_rate = 5,
    min_ns = 6,
    max_ns = 7,
    _,
};

pub const ParamProcessLatencyKey = enum(u32) {
    quantum = 1,
    rate = 2,
    ns = 3,
    _,
};

/// Ids of the commands in `ObjectType.command_node`.
pub const NodeCommand = enum(u32) {
    @"suspend" = 0,
    pause = 1,
    start = 2,
    enable = 3,
    disable = 4,
    flush = 5,
    drain = 6,
    marker = 7,
    param_begin = 8,
    param_end = 9,
    request_process = 10,
    user = 11,
    _,
};

/// Ids of the events in `ObjectType.event_node`.
pub const NodeEvent = enum(u32) {
    @"error" = 0,
    buffering = 1,
    request_refresh = 2,
    request_process = 3,
    user = 4,
    _,
};

pub const PropFlags = packed struct(u32) {
    readonly: bool = false,
    hardware: bool = false,
    hint_dict: bool = false,
    mandatory: bool = false,
    dont_fixate: bool = false,
    drop: bool = false,
    _padding: u26 = 0,
};

pub const DataFlags = packed struct(u32) {
    readable: bool = false,
    writable: bool = false,
    dynamic: bool = false,
    mappable: bool = false,
    _padding: u28 = 0,
};

pub const ChunkFlags = packed struct(u32) {
    corrupted: bool = false,
    empty: bool = false,
    _padding: u30 = 0,
};

pub const ParamInfoFlags = packed struct(u32) {
    serial: bool = false,
    read: bool = false,
    write: bool = false,
    _padding: u29 = 0,
};

pub const NodeFlags = packed struct(u32) {
    rt: bool = false,
    in_dynamic_ports: bool = false,
    out_dynamic_ports: bool = false,
    in_port_config: bool = false,
    out_port_config: bool = false,
    need_configure: bool = false,
    async: bool = false,
    _padding: u25 = 0,
};

pub const PortFlags = packed struct(u32) {
    removable: bool = false,
    optional: bool = false,
    can_alloc_buffers: bool = false,
    in_place: bool = false,
    no_ref: bool = false,
    live: bool = false,
    physical: bool = false,
    terminal: bool = false,
    dynamic_data: bool = false,
    _padding: u23 = 0,
};

/// Flag of `ClientNode` port buffers: the receiver allocates the buffer memory.
pub const node_buffers_flag_alloc: u32 = 1;

test "table values" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0x40003), @backingInt(ObjectType.format));
    try std.testing.expectEqual(@as(u32, 0x30002), @backingInt(ObjectType.command_node));
    try std.testing.expectEqual(@as(u32, 0x10003), @backingInt(FormatKey.audio_rate));
    try std.testing.expectEqual(@as(u32, 0x10008), @backingInt(PropKey.channel_volumes));
    try std.testing.expectEqual(@as(u32, 0x206), @backingInt(AudioFormat.dsp_f32));
    try std.testing.expectEqual(@as(u32, 0x11b), @backingInt(AudioFormat.f32_le));
    try std.testing.expectEqual(@as(u32, 5), @backingInt(ParamBuffersKey.@"align"));
    try std.testing.expectEqual(@as(u32, 0xa), @backingInt(IoType.async_buffers));
    try std.testing.expectEqual(@as(u32, 0x1005), @backingInt(AudioChannel.aux(5)));
    try std.testing.expectEqual(@as(u32, 1 << 5), @as(u32, @bitCast(PropFlags{ .drop = true })));
    try std.testing.expectEqual(@as(u32, 1 << 8), @as(u32, @bitCast(PortFlags{ .dynamic_data = true })));
    try std.testing.expectEqual(@as(u32, 6), @as(u32, @bitCast(ParamInfoFlags{ .read = true, .write = true })));
    try std.testing.expectEqual(@as(u32, 1 << 6), @as(u32, @bitCast(NodeFlags{ .async = true })));
}
