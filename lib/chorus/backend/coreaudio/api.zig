//! The CoreAudio constants, the C types and the function table of the macOS frameworks.
const std = @import("std");
const builtin = @import("builtin");

pub const OSStatus = i32;
pub const OSType = u32;
pub const Boolean = u8;
pub const CFIndex = isize;
pub const CFTypeRef = *const anyopaque;
pub const CFStringRef = *const opaque {};
pub const CFStringEncoding = u32;

pub const CFRange = extern struct { location: CFIndex, length: CFIndex };

pub const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;

/// 'abcd' in C is the big endian u32 of the four bytes.
pub fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

pub const AudioComponent = *opaque {};
pub const AudioUnit = *opaque {};
pub const AudioUnitPropertyID = u32;
pub const AudioUnitScope = u32;
pub const AudioUnitElement = u32;
pub const AudioUnitRenderActionFlags = u32;

pub const AudioComponentDescription = extern struct {
    componentType: OSType,
    componentSubType: OSType,
    componentManufacturer: OSType,
    componentFlags: u32 = 0,
    componentFlagsMask: u32 = 0,
};

pub const SMPTETime = extern struct {
    mSubframes: i16,
    mSubframeDivisor: i16,
    mCounter: u32,
    mType: u32,
    mFlags: u32,
    mHours: i16,
    mMinutes: i16,
    mSeconds: i16,
    mFrames: i16,
};

pub const AudioTimeStamp = extern struct {
    mSampleTime: f64,
    mHostTime: u64,
    mRateScalar: f64,
    mWordClockTime: u64,
    mSMPTETime: SMPTETime,
    mFlags: u32,
    mReserved: u32,
};

pub const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32 = 0,
};

pub const AudioBuffer = extern struct {
    mNumberChannels: u32,
    mDataByteSize: u32,
    mData: ?*anyopaque,
};

/// The C array has a variable length. One interleaved buffer needs only the first entry.
pub const AudioBufferList = extern struct {
    mNumberBuffers: u32,
    mBuffers: [1]AudioBuffer,
};

pub const AURenderCallback = *const fn (
    in_ref_con: ?*anyopaque,
    io_action_flags: *AudioUnitRenderActionFlags,
    in_time_stamp: *const AudioTimeStamp,
    in_bus_number: u32,
    in_number_frames: u32,
    io_data: ?*AudioBufferList,
) callconv(.c) OSStatus;

pub const AURenderCallbackStruct = extern struct {
    inputProc: ?AURenderCallback,
    inputProcRefCon: ?*anyopaque,
};

pub const AudioUnitPropertyListenerProc = *const fn (
    in_ref_con: ?*anyopaque,
    in_unit: AudioUnit,
    in_id: AudioUnitPropertyID,
    in_scope: AudioUnitScope,
    in_element: AudioUnitElement,
) callconv(.c) void;

pub const AudioObjectID = u32;
pub const AudioObjectPropertySelector = u32;
pub const AudioObjectPropertyScope = u32;
pub const AudioObjectPropertyElement = u32;

pub const AudioObjectPropertyAddress = extern struct {
    mSelector: AudioObjectPropertySelector,
    mScope: AudioObjectPropertyScope,
    mElement: AudioObjectPropertyElement,
};

pub const AudioValueRange = extern struct { mMinimum: f64, mMaximum: f64 };

pub const AudioValueTranslation = extern struct {
    mInputData: *anyopaque,
    mInputDataSize: u32,
    mOutputData: *anyopaque,
    mOutputDataSize: u32,
};

pub const AudioObjectPropertyListenerProc = *const fn (
    in_object_id: AudioObjectID,
    in_number_addresses: u32,
    in_addresses: [*]const AudioObjectPropertyAddress,
    in_client_data: ?*anyopaque,
) callconv(.c) OSStatus;

/// Builds a property address.
pub fn address(selector: u32, scope: u32, element: u32) AudioObjectPropertyAddress {
    return .{ .mSelector = selector, .mScope = scope, .mElement = element };
}

pub const object_unknown: AudioObjectID = 0;
pub const object_system: AudioObjectID = 1;

pub const Scope = struct {
    pub const global: u32 = fourcc("glob");
    pub const input: u32 = fourcc("inpt");
    pub const output: u32 = fourcc("outp");
    pub const play_through: u32 = fourcc("ptru");
};

pub const element_main: u32 = 0;
pub const element_wildcard: u32 = 0xFFFFFFFF;
pub const selector_wildcard: u32 = fourcc("****");

pub const Selector = struct {
    pub const devices: u32 = fourcc("dev#");
    pub const default_input_device: u32 = fourcc("dIn ");
    pub const default_output_device: u32 = fourcc("dOut");
    pub const default_system_output_device: u32 = fourcc("sOut");
    pub const translate_uid_to_device: u32 = fourcc("uidd");
    pub const service_restarted: u32 = fourcc("srst");
    pub const run_loop: u32 = fourcc("rnlp");
    pub const class: u32 = fourcc("clas");
    pub const name: u32 = fourcc("lnam");
    pub const manufacturer: u32 = fourcc("lmak");
    pub const element_name: u32 = fourcc("lchn");
    pub const device_uid: u32 = fourcc("uid ");
    pub const model_uid: u32 = fourcc("muid");
    pub const transport_type: u32 = fourcc("tran");
    pub const is_alive: u32 = fourcc("livn");
    pub const is_running: u32 = fourcc("goin");
    pub const can_be_default: u32 = fourcc("dflt");
    pub const latency: u32 = fourcc("ltnc");
    pub const streams: u32 = fourcc("stm#");
    pub const safety_offset: u32 = fourcc("saft");
    pub const nominal_sample_rate: u32 = fourcc("nsrt");
    pub const available_nominal_sample_rates: u32 = fourcc("nsr#");
    pub const is_hidden: u32 = fourcc("hidn");
    pub const preferred_channels_for_stereo: u32 = fourcc("dch2");
    pub const preferred_channel_layout: u32 = fourcc("srnd");
    pub const device_has_changed: u32 = fourcc("diff");
    pub const is_running_somewhere: u32 = fourcc("gone");
    pub const processor_overload: u32 = fourcc("over");
    pub const io_stopped_abnormally: u32 = fourcc("stpd");
    pub const hog_mode: u32 = fourcc("oink");
    pub const buffer_frame_size: u32 = fourcc("fsiz");
    pub const buffer_frame_size_range: u32 = fourcc("fsz#");
    pub const stream_configuration: u32 = fourcc("slay");
    pub const volume_scalar: u32 = fourcc("volm");
    pub const volume_decibels: u32 = fourcc("vold");
    pub const volume_range_decibels: u32 = fourcc("vdb#");
    pub const mute: u32 = fourcc("mute");
    pub const data_source: u32 = fourcc("ssrc");
    pub const data_sources: u32 = fourcc("ssc#");
    pub const data_source_name: u32 = fourcc("lscn");
    pub const virtual_main_volume: u32 = fourcc("vmvc");
    pub const virtual_main_balance: u32 = fourcc("vmbc");
    // No v2db or db2v entries. They do not match the real taper of the built in speakers.
};

pub const Status = struct {
    pub const ok: OSStatus = 0;
    pub const unimplemented: OSStatus = -4;
    pub const param: OSStatus = -50;
    pub const mem_full: OSStatus = -108;
    pub const not_running: OSStatus = @bitCast(fourcc("stop"));
    pub const unspecified: OSStatus = @bitCast(fourcc("what"));
    pub const unknown_property: OSStatus = @bitCast(fourcc("who?"));
    pub const bad_property_size: OSStatus = @bitCast(fourcc("!siz"));
    pub const illegal_operation: OSStatus = @bitCast(fourcc("nope"));
    pub const bad_object: OSStatus = @bitCast(fourcc("!obj"));
    pub const bad_device: OSStatus = @bitCast(fourcc("!dev"));
    pub const bad_stream: OSStatus = @bitCast(fourcc("!str"));
    pub const unsupported_operation: OSStatus = @bitCast(fourcc("unop"));
    pub const not_ready: OSStatus = @bitCast(fourcc("nrdy"));
    pub const unsupported_format: OSStatus = @bitCast(fourcc("!dat"));
    pub const permissions: OSStatus = @bitCast(fourcc("!hog"));
    pub const unit_invalid_property: OSStatus = -10879;
    pub const unit_invalid_parameter: OSStatus = -10878;
    pub const unit_invalid_element: OSStatus = -10877;
    pub const unit_no_connection: OSStatus = -10876;
    pub const unit_failed_initialization: OSStatus = -10875;
    pub const unit_too_many_frames: OSStatus = -10874;
    pub const unit_format_not_supported: OSStatus = -10868;
    pub const unit_uninitialized: OSStatus = -10867;
    pub const unit_invalid_scope: OSStatus = -10866;
    pub const unit_property_not_writable: OSStatus = -10865;
    pub const unit_cannot_do_in_current_context: OSStatus = -10863;
    pub const unit_invalid_property_value: OSStatus = -10851;
    pub const unit_property_not_in_use: OSStatus = -10850;
    pub const unit_initialized: OSStatus = -10849;
    pub const unit_unauthorized: OSStatus = -10847;
    pub const component_not_permitted: OSStatus = -66748;
    pub const component_too_many_instances: OSStatus = -66750;
    pub const component_instance_invalidated: OSStatus = -66749;
};

pub const unit_type_output: OSType = fourcc("auou");
pub const unit_subtype_hal_output: OSType = fourcc("ahal");
pub const unit_manufacturer_apple: OSType = fourcc("appl");

pub const UnitScope = struct {
    pub const global: AudioUnitScope = 0;
    pub const input: AudioUnitScope = 1;
    pub const output: AudioUnitScope = 2;
};

pub const UnitProperty = struct {
    pub const sample_rate: AudioUnitPropertyID = 2;
    pub const stream_format: AudioUnitPropertyID = 8;
    pub const maximum_frames_per_slice: AudioUnitPropertyID = 14;
    pub const audio_channel_layout: AudioUnitPropertyID = 19;
    pub const last_render_error: AudioUnitPropertyID = 22;
    pub const set_render_callback: AudioUnitPropertyID = 23;
    pub const should_allocate_buffer: AudioUnitPropertyID = 51;
    pub const current_device: AudioUnitPropertyID = 2000;
    pub const is_running: AudioUnitPropertyID = 2001;
    pub const channel_map: AudioUnitPropertyID = 2002;
    pub const enable_io: AudioUnitPropertyID = 2003;
    pub const set_input_callback: AudioUnitPropertyID = 2005;
    pub const has_io: AudioUnitPropertyID = 2006;
};

pub const render_action_output_is_silence: AudioUnitRenderActionFlags = 1 << 4;

pub const format_linear_pcm: u32 = fourcc("lpcm");

pub const FormatFlag = struct {
    pub const is_float: u32 = 1 << 0;
    pub const is_big_endian: u32 = 1 << 1;
    pub const is_signed_integer: u32 = 1 << 2;
    pub const is_packed: u32 = 1 << 3;
    pub const is_non_interleaved: u32 = 1 << 5;
};

/// The dlopen mode bits of macOS.
pub const RTLD = struct {
    pub const lazy: c_int = 1;
    pub const now: c_int = 2;
    pub const local: c_int = 4;
};

/// The functions of the frameworks that the backend calls. Every function takes `self` first.
/// It is the `ctx` of the `Binding` that holds the table. The native table ignores it.
pub const Api = struct {
    componentFindNext: *const fn (self: *anyopaque, desc: *const AudioComponentDescription) ?AudioComponent,
    componentInstanceNew: *const fn (self: *anyopaque, component: AudioComponent, out: *?AudioUnit) OSStatus,
    componentInstanceDispose: *const fn (self: *anyopaque, unit: AudioUnit) OSStatus,
    unitInitialize: *const fn (self: *anyopaque, unit: AudioUnit) OSStatus,
    unitUninitialize: *const fn (self: *anyopaque, unit: AudioUnit) OSStatus,
    unitGetPropertyInfo: *const fn (
        self: *anyopaque,
        unit: AudioUnit,
        id: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        size: ?*u32,
        writable: ?*Boolean,
    ) OSStatus,
    unitGetProperty: *const fn (
        self: *anyopaque,
        unit: AudioUnit,
        id: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: *anyopaque,
        size: *u32,
    ) OSStatus,
    unitSetProperty: *const fn (
        self: *anyopaque,
        unit: AudioUnit,
        id: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: ?*const anyopaque,
        size: u32,
    ) OSStatus,
    unitAddPropertyListener: *const fn (
        self: *anyopaque,
        unit: AudioUnit,
        id: AudioUnitPropertyID,
        proc: AudioUnitPropertyListenerProc,
        user_data: ?*anyopaque,
    ) OSStatus,
    unitRemovePropertyListener: *const fn (
        self: *anyopaque,
        unit: AudioUnit,
        id: AudioUnitPropertyID,
        proc: AudioUnitPropertyListenerProc,
        user_data: ?*anyopaque,
    ) OSStatus,
    unitRender: *const fn (
        self: *anyopaque,
        unit: AudioUnit,
        flags: ?*AudioUnitRenderActionFlags,
        time_stamp: *const AudioTimeStamp,
        bus: u32,
        frames: u32,
        data: *AudioBufferList,
    ) OSStatus,
    outputUnitStart: *const fn (self: *anyopaque, unit: AudioUnit) OSStatus,
    outputUnitStop: *const fn (self: *anyopaque, unit: AudioUnit) OSStatus,
    objectHasProperty: *const fn (self: *anyopaque, object: AudioObjectID, addr: *const AudioObjectPropertyAddress) bool,
    objectIsPropertySettable: *const fn (
        self: *anyopaque,
        object: AudioObjectID,
        addr: *const AudioObjectPropertyAddress,
        settable: *Boolean,
    ) OSStatus,
    objectGetPropertyDataSize: *const fn (
        self: *anyopaque,
        object: AudioObjectID,
        addr: *const AudioObjectPropertyAddress,
        qualifier_size: u32,
        qualifier: ?*const anyopaque,
        size: *u32,
    ) OSStatus,
    objectGetPropertyData: *const fn (
        self: *anyopaque,
        object: AudioObjectID,
        addr: *const AudioObjectPropertyAddress,
        qualifier_size: u32,
        qualifier: ?*const anyopaque,
        size: *u32,
        data: *anyopaque,
    ) OSStatus,
    objectSetPropertyData: *const fn (
        self: *anyopaque,
        object: AudioObjectID,
        addr: *const AudioObjectPropertyAddress,
        qualifier_size: u32,
        qualifier: ?*const anyopaque,
        size: u32,
        data: *const anyopaque,
    ) OSStatus,
    objectAddPropertyListener: *const fn (
        self: *anyopaque,
        object: AudioObjectID,
        addr: *const AudioObjectPropertyAddress,
        proc: AudioObjectPropertyListenerProc,
        client_data: ?*anyopaque,
    ) OSStatus,
    objectRemovePropertyListener: *const fn (
        self: *anyopaque,
        object: AudioObjectID,
        addr: *const AudioObjectPropertyAddress,
        proc: AudioObjectPropertyListenerProc,
        client_data: ?*anyopaque,
    ) OSStatus,
    cfRelease: *const fn (self: *anyopaque, cf: CFTypeRef) void,
    cfStringGetLength: *const fn (self: *anyopaque, string: CFStringRef) CFIndex,
    cfStringGetMaximumSizeForEncoding: *const fn (self: *anyopaque, length: CFIndex, encoding: CFStringEncoding) CFIndex,
    cfStringGetBytes: *const fn (
        self: *anyopaque,
        string: CFStringRef,
        range: CFRange,
        encoding: CFStringEncoding,
        loss_byte: u8,
        is_external: Boolean,
        buffer: ?[*]u8,
        max_len: CFIndex,
        used: ?*CFIndex,
    ) CFIndex,
    dlopen: *const fn (self: *anyopaque, path: [*:0]const u8, mode: c_int) ?*anyopaque,
    dlsym: *const fn (self: *anyopaque, handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque,
    /// `thread_policy_get` for the calling thread. It gives a kern_return_t.
    threadPolicyGet: *const fn (self: *anyopaque, flavor: u32, info: [*]u32, count: *u32, get_default: *u32) i32,
};

/// The flavor of `thread_policy_get` that tells whether a thread has a time constraint.
pub const thread_time_constraint_policy: u32 = 2;
pub const thread_time_constraint_count: u32 = 4;

/// A table together with the state that its functions use.
pub const Binding = struct {
    self: *anyopaque,
    table: *const Api,
};

fn makeNative() Api {
    const c = struct {
        extern "AudioToolbox" fn AudioComponentFindNext(?AudioComponent, *const AudioComponentDescription) callconv(.c) ?AudioComponent;
        extern "AudioToolbox" fn AudioComponentInstanceNew(AudioComponent, *?AudioUnit) callconv(.c) OSStatus;
        extern "AudioToolbox" fn AudioComponentInstanceDispose(AudioUnit) callconv(.c) OSStatus;
        extern "AudioToolbox" fn AudioUnitInitialize(AudioUnit) callconv(.c) OSStatus;
        extern "AudioToolbox" fn AudioUnitUninitialize(AudioUnit) callconv(.c) OSStatus;
        extern "AudioToolbox" fn AudioUnitGetPropertyInfo(
            AudioUnit,
            AudioUnitPropertyID,
            AudioUnitScope,
            AudioUnitElement,
            ?*u32,
            ?*Boolean,
        ) callconv(.c) OSStatus;
        extern "AudioToolbox" fn AudioUnitGetProperty(
            AudioUnit,
            AudioUnitPropertyID,
            AudioUnitScope,
            AudioUnitElement,
            *anyopaque,
            *u32,
        ) callconv(.c) OSStatus;
        extern "AudioToolbox" fn AudioUnitSetProperty(
            AudioUnit,
            AudioUnitPropertyID,
            AudioUnitScope,
            AudioUnitElement,
            ?*const anyopaque,
            u32,
        ) callconv(.c) OSStatus;
        extern "AudioToolbox" fn AudioUnitAddPropertyListener(
            AudioUnit,
            AudioUnitPropertyID,
            AudioUnitPropertyListenerProc,
            ?*anyopaque,
        ) callconv(.c) OSStatus;
        extern "AudioToolbox" fn AudioUnitRemovePropertyListenerWithUserData(
            AudioUnit,
            AudioUnitPropertyID,
            AudioUnitPropertyListenerProc,
            ?*anyopaque,
        ) callconv(.c) OSStatus;
        extern "AudioToolbox" fn AudioUnitRender(
            AudioUnit,
            ?*AudioUnitRenderActionFlags,
            *const AudioTimeStamp,
            u32,
            u32,
            *AudioBufferList,
        ) callconv(.c) OSStatus;
        extern "AudioToolbox" fn AudioOutputUnitStart(AudioUnit) callconv(.c) OSStatus;
        extern "AudioToolbox" fn AudioOutputUnitStop(AudioUnit) callconv(.c) OSStatus;
        extern "CoreAudio" fn AudioObjectHasProperty(AudioObjectID, *const AudioObjectPropertyAddress) callconv(.c) Boolean;
        extern "CoreAudio" fn AudioObjectIsPropertySettable(
            AudioObjectID,
            *const AudioObjectPropertyAddress,
            *Boolean,
        ) callconv(.c) OSStatus;
        extern "CoreAudio" fn AudioObjectGetPropertyDataSize(
            AudioObjectID,
            *const AudioObjectPropertyAddress,
            u32,
            ?*const anyopaque,
            *u32,
        ) callconv(.c) OSStatus;
        extern "CoreAudio" fn AudioObjectGetPropertyData(
            AudioObjectID,
            *const AudioObjectPropertyAddress,
            u32,
            ?*const anyopaque,
            *u32,
            *anyopaque,
        ) callconv(.c) OSStatus;
        extern "CoreAudio" fn AudioObjectSetPropertyData(
            AudioObjectID,
            *const AudioObjectPropertyAddress,
            u32,
            ?*const anyopaque,
            u32,
            *const anyopaque,
        ) callconv(.c) OSStatus;
        extern "CoreAudio" fn AudioObjectAddPropertyListener(
            AudioObjectID,
            *const AudioObjectPropertyAddress,
            AudioObjectPropertyListenerProc,
            ?*anyopaque,
        ) callconv(.c) OSStatus;
        extern "CoreAudio" fn AudioObjectRemovePropertyListener(
            AudioObjectID,
            *const AudioObjectPropertyAddress,
            AudioObjectPropertyListenerProc,
            ?*anyopaque,
        ) callconv(.c) OSStatus;
        extern "CoreFoundation" fn CFRelease(CFTypeRef) callconv(.c) void;
        extern "CoreFoundation" fn CFStringGetLength(CFStringRef) callconv(.c) CFIndex;
        extern "CoreFoundation" fn CFStringGetMaximumSizeForEncoding(CFIndex, CFStringEncoding) callconv(.c) CFIndex;
        extern "CoreFoundation" fn CFStringGetBytes(
            CFStringRef,
            CFRange,
            CFStringEncoding,
            u8,
            Boolean,
            ?[*]u8,
            CFIndex,
            ?*CFIndex,
        ) callconv(.c) CFIndex;
        extern "c" fn dlopen(?[*:0]const u8, c_int) callconv(.c) ?*anyopaque;
        extern "c" fn dlsym(?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque;
        extern "c" fn pthread_self() callconv(.c) *anyopaque;
        extern "c" fn pthread_mach_thread_np(*anyopaque) callconv(.c) u32;
        extern "c" fn thread_policy_get(u32, u32, [*]u32, *u32, *u32) callconv(.c) c_int;

        fn componentFindNext(_: *anyopaque, desc: *const AudioComponentDescription) ?AudioComponent {
            return AudioComponentFindNext(null, desc);
        }
        fn componentInstanceNew(_: *anyopaque, component: AudioComponent, out: *?AudioUnit) OSStatus {
            return AudioComponentInstanceNew(component, out);
        }
        fn componentInstanceDispose(_: *anyopaque, unit: AudioUnit) OSStatus {
            return AudioComponentInstanceDispose(unit);
        }
        fn unitInitialize(_: *anyopaque, unit: AudioUnit) OSStatus {
            return AudioUnitInitialize(unit);
        }
        fn unitUninitialize(_: *anyopaque, unit: AudioUnit) OSStatus {
            return AudioUnitUninitialize(unit);
        }
        fn unitGetPropertyInfo(
            _: *anyopaque,
            unit: AudioUnit,
            id: AudioUnitPropertyID,
            scope: AudioUnitScope,
            element: AudioUnitElement,
            size: ?*u32,
            writable: ?*Boolean,
        ) OSStatus {
            return AudioUnitGetPropertyInfo(unit, id, scope, element, size, writable);
        }
        fn unitGetProperty(
            _: *anyopaque,
            unit: AudioUnit,
            id: AudioUnitPropertyID,
            scope: AudioUnitScope,
            element: AudioUnitElement,
            data: *anyopaque,
            size: *u32,
        ) OSStatus {
            return AudioUnitGetProperty(unit, id, scope, element, data, size);
        }
        fn unitSetProperty(
            _: *anyopaque,
            unit: AudioUnit,
            id: AudioUnitPropertyID,
            scope: AudioUnitScope,
            element: AudioUnitElement,
            data: ?*const anyopaque,
            size: u32,
        ) OSStatus {
            return AudioUnitSetProperty(unit, id, scope, element, data, size);
        }
        fn unitAddPropertyListener(
            _: *anyopaque,
            unit: AudioUnit,
            id: AudioUnitPropertyID,
            proc: AudioUnitPropertyListenerProc,
            user_data: ?*anyopaque,
        ) OSStatus {
            return AudioUnitAddPropertyListener(unit, id, proc, user_data);
        }
        fn unitRemovePropertyListener(
            _: *anyopaque,
            unit: AudioUnit,
            id: AudioUnitPropertyID,
            proc: AudioUnitPropertyListenerProc,
            user_data: ?*anyopaque,
        ) OSStatus {
            return AudioUnitRemovePropertyListenerWithUserData(unit, id, proc, user_data);
        }
        fn unitRender(
            _: *anyopaque,
            unit: AudioUnit,
            flags: ?*AudioUnitRenderActionFlags,
            time_stamp: *const AudioTimeStamp,
            bus: u32,
            frames: u32,
            data: *AudioBufferList,
        ) OSStatus {
            return AudioUnitRender(unit, flags, time_stamp, bus, frames, data);
        }
        fn outputUnitStart(_: *anyopaque, unit: AudioUnit) OSStatus {
            return AudioOutputUnitStart(unit);
        }
        fn outputUnitStop(_: *anyopaque, unit: AudioUnit) OSStatus {
            return AudioOutputUnitStop(unit);
        }
        fn objectHasProperty(_: *anyopaque, object: AudioObjectID, addr: *const AudioObjectPropertyAddress) bool {
            return AudioObjectHasProperty(object, addr) != 0;
        }
        fn objectIsPropertySettable(
            _: *anyopaque,
            object: AudioObjectID,
            addr: *const AudioObjectPropertyAddress,
            settable: *Boolean,
        ) OSStatus {
            return AudioObjectIsPropertySettable(object, addr, settable);
        }
        fn objectGetPropertyDataSize(
            _: *anyopaque,
            object: AudioObjectID,
            addr: *const AudioObjectPropertyAddress,
            qualifier_size: u32,
            qualifier: ?*const anyopaque,
            size: *u32,
        ) OSStatus {
            return AudioObjectGetPropertyDataSize(object, addr, qualifier_size, qualifier, size);
        }
        fn objectGetPropertyData(
            _: *anyopaque,
            object: AudioObjectID,
            addr: *const AudioObjectPropertyAddress,
            qualifier_size: u32,
            qualifier: ?*const anyopaque,
            size: *u32,
            data: *anyopaque,
        ) OSStatus {
            return AudioObjectGetPropertyData(object, addr, qualifier_size, qualifier, size, data);
        }
        fn objectSetPropertyData(
            _: *anyopaque,
            object: AudioObjectID,
            addr: *const AudioObjectPropertyAddress,
            qualifier_size: u32,
            qualifier: ?*const anyopaque,
            size: u32,
            data: *const anyopaque,
        ) OSStatus {
            return AudioObjectSetPropertyData(object, addr, qualifier_size, qualifier, size, data);
        }
        fn objectAddPropertyListener(
            _: *anyopaque,
            object: AudioObjectID,
            addr: *const AudioObjectPropertyAddress,
            proc: AudioObjectPropertyListenerProc,
            client_data: ?*anyopaque,
        ) OSStatus {
            return AudioObjectAddPropertyListener(object, addr, proc, client_data);
        }
        fn objectRemovePropertyListener(
            _: *anyopaque,
            object: AudioObjectID,
            addr: *const AudioObjectPropertyAddress,
            proc: AudioObjectPropertyListenerProc,
            client_data: ?*anyopaque,
        ) OSStatus {
            return AudioObjectRemovePropertyListener(object, addr, proc, client_data);
        }
        fn cfRelease(_: *anyopaque, cf: CFTypeRef) void {
            CFRelease(cf);
        }
        fn cfStringGetLength(_: *anyopaque, string: CFStringRef) CFIndex {
            return CFStringGetLength(string);
        }
        fn cfStringGetMaximumSizeForEncoding(_: *anyopaque, length: CFIndex, encoding: CFStringEncoding) CFIndex {
            return CFStringGetMaximumSizeForEncoding(length, encoding);
        }
        fn cfStringGetBytes(
            _: *anyopaque,
            string: CFStringRef,
            range: CFRange,
            encoding: CFStringEncoding,
            loss_byte: u8,
            is_external: Boolean,
            buffer: ?[*]u8,
            max_len: CFIndex,
            used: ?*CFIndex,
        ) CFIndex {
            return CFStringGetBytes(string, range, encoding, loss_byte, is_external, buffer, max_len, used);
        }
        fn dlopenFn(_: *anyopaque, path: [*:0]const u8, mode: c_int) ?*anyopaque {
            return dlopen(path, mode);
        }
        fn dlsymFn(_: *anyopaque, handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque {
            return dlsym(handle, symbol);
        }
        fn threadPolicyGetFn(_: *anyopaque, flavor: u32, info: [*]u32, count: *u32, get_default: *u32) i32 {
            return thread_policy_get(pthread_mach_thread_np(pthread_self()), flavor, info, count, get_default);
        }
    };
    return .{
        .componentFindNext = &c.componentFindNext,
        .componentInstanceNew = &c.componentInstanceNew,
        .componentInstanceDispose = &c.componentInstanceDispose,
        .unitInitialize = &c.unitInitialize,
        .unitUninitialize = &c.unitUninitialize,
        .unitGetPropertyInfo = &c.unitGetPropertyInfo,
        .unitGetProperty = &c.unitGetProperty,
        .unitSetProperty = &c.unitSetProperty,
        .unitAddPropertyListener = &c.unitAddPropertyListener,
        .unitRemovePropertyListener = &c.unitRemovePropertyListener,
        .unitRender = &c.unitRender,
        .outputUnitStart = &c.outputUnitStart,
        .outputUnitStop = &c.outputUnitStop,
        .objectHasProperty = &c.objectHasProperty,
        .objectIsPropertySettable = &c.objectIsPropertySettable,
        .objectGetPropertyDataSize = &c.objectGetPropertyDataSize,
        .objectGetPropertyData = &c.objectGetPropertyData,
        .objectSetPropertyData = &c.objectSetPropertyData,
        .objectAddPropertyListener = &c.objectAddPropertyListener,
        .objectRemovePropertyListener = &c.objectRemovePropertyListener,
        .cfRelease = &c.cfRelease,
        .cfStringGetLength = &c.cfStringGetLength,
        .cfStringGetMaximumSizeForEncoding = &c.cfStringGetMaximumSizeForEncoding,
        .cfStringGetBytes = &c.cfStringGetBytes,
        .dlopen = &c.dlopenFn,
        .dlsym = &c.dlsymFn,
        .threadPolicyGet = &c.threadPolicyGetFn,
    };
}

/// The table of the system frameworks. It exists only on macOS, where every function is present.
pub const native: Api = if (builtin.os.tag == .macos) makeNative() else @compileError("the native CoreAudio table exists only on macOS");

test "four character codes match the headers" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 0x61756f75), unit_type_output);
    try t.expectEqual(@as(u32, 0x6168616c), unit_subtype_hal_output);
    try t.expectEqual(@as(u32, 0x6170706c), unit_manufacturer_apple);
    try t.expectEqual(@as(u32, 0x676c6f62), Scope.global);
    try t.expectEqual(@as(u32, 0x696e7074), Scope.input);
    try t.expectEqual(@as(u32, 0x6f757470), Scope.output);
    try t.expectEqual(@as(u32, 0x2a2a2a2a), selector_wildcard);
    try t.expectEqual(@as(u32, 0x64657623), Selector.devices);
    try t.expectEqual(@as(u32, 0x64496e20), Selector.default_input_device);
    try t.expectEqual(@as(u32, 0x644f7574), Selector.default_output_device);
    try t.expectEqual(@as(u32, 0x73726e64), Selector.preferred_channel_layout);
    try t.expectEqual(@as(u32, 0x75696420), Selector.device_uid);
    try t.expectEqual(@as(u32, 0x6c69766e), Selector.is_alive);
    try t.expectEqual(@as(u32, 0x6e737274), Selector.nominal_sample_rate);
    try t.expectEqual(@as(u32, 0x6673697a), Selector.buffer_frame_size);
    try t.expectEqual(@as(u32, 0x66737a23), Selector.buffer_frame_size_range);
    try t.expectEqual(@as(u32, 0x736c6179), Selector.stream_configuration);
    try t.expectEqual(@as(u32, 0x766f6c6d), Selector.volume_scalar);
    try t.expectEqual(@as(u32, 0x766f6c64), Selector.volume_decibels);
    try t.expectEqual(@as(u32, 0x76646223), Selector.volume_range_decibels);
    try t.expectEqual(@as(u32, 0x6d757465), Selector.mute);
    try t.expectEqual(@as(u32, 0x73737263), Selector.data_source);
    try t.expectEqual(@as(u32, 0x73736323), Selector.data_sources);
    try t.expectEqual(@as(u32, 0x6c73636e), Selector.data_source_name);
    try t.expectEqual(@as(u32, 0x766d7663), Selector.virtual_main_volume);
    try t.expectEqual(@as(u32, 0x6c70636d), format_linear_pcm);
}

test "status codes match the headers" {
    const t = std.testing;
    try t.expectEqual(@as(OSStatus, 0x73746f70), Status.not_running);
    try t.expectEqual(@as(OSStatus, 0x77686174), Status.unspecified);
    try t.expectEqual(@as(OSStatus, 0x2173697a), Status.bad_property_size);
    try t.expectEqual(@as(OSStatus, 0x21686f67), Status.permissions);
    try t.expectEqual(@as(OSStatus, -10863), Status.unit_cannot_do_in_current_context);
    try t.expectEqual(@as(OSStatus, -66748), Status.component_not_permitted);
}

test "the format flags and unit properties match the headers" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 0x8), FormatFlag.is_packed);
    try t.expectEqual(@as(u32, 0x20), FormatFlag.is_non_interleaved);
    try t.expectEqual(@as(u32, 0x10), render_action_output_is_silence);
    try t.expectEqual(@as(AudioUnitPropertyID, 2000), UnitProperty.current_device);
    try t.expectEqual(@as(AudioUnitPropertyID, 2005), UnitProperty.set_input_callback);
    try t.expectEqual(@as(AudioUnitPropertyID, 14), UnitProperty.maximum_frames_per_slice);
}

test "the native table finds the HAL output component" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var unused: u8 = 0;
    const desc: AudioComponentDescription = .{
        .componentType = unit_type_output,
        .componentSubType = unit_subtype_hal_output,
        .componentManufacturer = unit_manufacturer_apple,
    };
    try std.testing.expect(native.componentFindNext(&unused, &desc) != null);
}

test "type sizes match the headers" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 20), @sizeOf(AudioComponentDescription));
    try t.expectEqual(@as(usize, 24), @sizeOf(SMPTETime));
    try t.expectEqual(@as(usize, 64), @sizeOf(AudioTimeStamp));
    try t.expectEqual(@as(usize, 40), @sizeOf(AudioStreamBasicDescription));
    try t.expectEqual(@as(usize, 12), @sizeOf(AudioObjectPropertyAddress));
    try t.expectEqual(@as(usize, 16), @sizeOf(AudioValueRange));
    const wide = @sizeOf(usize) == 8;
    try t.expectEqual(@as(usize, if (wide) 16 else 12), @sizeOf(AudioBuffer));
    try t.expectEqual(@as(usize, if (wide) 24 else 16), @sizeOf(AudioBufferList));
    try t.expectEqual(@as(usize, if (wide) 8 else 4), @offsetOf(AudioBufferList, "mBuffers"));
    try t.expectEqual(@as(usize, if (wide) 16 else 8), @sizeOf(AURenderCallbackStruct));
    try t.expectEqual(@as(usize, if (wide) 32 else 16), @sizeOf(AudioValueTranslation));
    try t.expectEqual(@as(usize, if (wide) 16 else 8), @sizeOf(CFRange));
}
