const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const single_threaded = b.option(bool, "single-threaded", "Build with no threads.");
    const compile_only = b.option(bool, "compile-only", "Compile the tests and do not run them.") orelse false;
    const android_ndk = b.option([]const u8, "android-ndk", "Absolute path of an Android NDK. Android tests then link bionic and can run on a device. A package that depends on chorus must pass it, or link libaaudio itself, or its link fails.");
    // The PipeWire backend and its modules exist only where the PipeWire daemon can run.
    const pipewire_enabled = target.result.os.tag == .linux and !target.result.abi.isAndroid();

    const test_step = b.step("test", "Run all tests");

    const codec = b.addModule("codec", .{
        .root_source_file = b.path("lib/codec.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
    });
    addTests(b, test_step, compile_only, codec);

    const chorus = b.addModule("chorus", .{
        .root_source_file = b.path("lib/chorus.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .imports = &.{.{ .name = "codec", .module = codec }},
    });

    if (pipewire_enabled) {
        const pipewire = b.addModule("pipewire", .{
            .root_source_file = b.path("lib/pipewire.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = single_threaded,
        });
        addTests(b, test_step, compile_only, pipewire);

        const wireplumber = b.addModule("wireplumber", .{
            .root_source_file = b.path("lib/wireplumber.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = single_threaded,
            .imports = &.{.{ .name = "pipewire", .module = pipewire }},
        });
        addTests(b, test_step, compile_only, wireplumber);

        chorus.addImport("pipewire", pipewire);
        chorus.addImport("wireplumber", wireplumber);
        if (b.lazyDependency("dbus", .{ .target = target, .optimize = optimize })) |dbus_dep| {
            chorus.addImport("dbus", dbus_dep.module("dbus"));
        }
    }
    const web_enabled = target.result.cpu.arch == .wasm32 and target.result.os.tag == .freestanding;
    var web_check: ?*std.Build.Step = null;
    if (web_enabled) {
        if (b.lazyImport(@This(), "webidl")) |webidl| {
            if (b.lazyDependency("webidl", .{})) |webidl_dep| {
                chorus.addImport("webidl", webidl_dep.module("webidl"));
                chorus.addImport("web_audio", webidl.generateModule(b, webidl_dep, .{
                    .name = "web_audio",
                    .idl = b.path("web/audio.webidl"),
                    .style = .client,
                }));
                web_check = addWebCheck(b, chorus, target, optimize);
            }
        }
    }
    var chorus_libc: ?std.Build.LazyPath = null;
    var chorus_object = false;
    if (target.result.abi.isAndroid()) {
        // The AAudio backend needs bionic, so the module links libc on Android.
        chorus.link_libc = true;
        chorus.pic = true;
        if (android_ndk) |ndk| {
            chorus_libc = linkAndroidNdk(b, chorus, target.result, ndk);
        } else if (!b.isRoot()) {
            // A dependent without an NDK path fails at link time and not at load time.
            chorus.linkSystemLibrary("aaudio", .{});
        } else {
            // Without an NDK nothing can link. The tests compile the backend and stop at the object.
            chorus_object = true;
        }
    }
    if (target.result.os.tag == .macos) {
        for ([_][]const u8{ "CoreAudio", "AudioToolbox", "CoreFoundation" }) |framework| {
            chorus.linkFramework(framework, .{});
        }
        // Zig skips its own SDK search when a nix shell sets NIX_CFLAGS_COMPILE. The SDK setup
        // exports SDKROOT there. CoreFoundation needs libobjc from usr/lib.
        if (b.graph.environ_map.get("SDKROOT")) |sdkroot| {
            chorus.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdkroot, "System/Library/Frameworks" }) });
            chorus.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdkroot, "usr/lib" }) });
        }
    }
    const chorus_tests = addTestsWith(b, test_step, compile_only, chorus, chorus_libc, chorus_object);
    if (chorus_libc != null) {
        // The linked test binary runs on a device, so it gets its own step and install path.
        const install = b.addInstallArtifact(chorus_tests, .{
            .dest_dir = .{ .override = .{ .custom = "test" } },
            .dest_sub_path = "chorus-test",
        });
        const android_step = b.step("test-android", "Install the Android test binary as test/chorus-test under the install prefix");
        android_step.dependOn(&install.step);
    }

    // The vectors are too large to ship, so only a root build fetches them.
    if (b.isRoot()) {
        if (b.lazyDependency("opus_vectors", .{})) |vectors| {
            addVectorTests(b, test_step, compile_only, target, single_threaded, vectors);
        }
    }

    if (!web_enabled and !chorus_object) addPlay(b, chorus, codec, target, optimize, chorus_libc);

    const lib = b.addLibrary(.{ .name = "chorus", .root_module = chorus, .linkage = .static });
    // The web-check exe is the build check for the web target. An app takes the chorus module, not the archive.
    if (!web_enabled) b.installArtifact(lib);
    if (web_check) |step| {
        b.getInstallStep().dependOn(step);
        test_step.dependOn(step);
    }
}

/// The chorus-play program, to check by ear that audio works.
fn addPlay(
    b: *std.Build,
    chorus: *std.Build.Module,
    codec: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    libc_file: ?std.Build.LazyPath,
) void {
    const exe = b.addExecutable(.{
        .name = "chorus-play",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/chorus-play.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "chorus", .module = chorus },
                .{ .name = "codec", .module = codec },
            },
        }),
    });
    if (libc_file) |file| exe.setLibCFile(file);
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    const step = b.step("play", "Run chorus-play, pass the arguments after --");
    step.dependOn(&run.step);
}

/// An exe that makes the compiler analyze the real web table. The Zig test runner cannot build
/// for freestanding targets. The exe has no entry point and exports its functions.
fn addWebCheck(
    b: *std.Build,
    chorus: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step {
    const exe = b.addExecutable(.{
        .name = "web-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/chorus/backend/web/check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "chorus", .module = chorus }},
        }),
    });
    exe.entry = .disabled;
    exe.rdynamic = true;
    const install = b.addInstallArtifact(exe, .{});
    const step = b.step("web-check", "Build the wasm32-freestanding check exe");
    step.dependOn(&install.step);
    return step;
}

fn addTests(b: *std.Build, test_step: *std.Build.Step, compile_only: bool, module: *std.Build.Module) void {
    _ = addTestsWith(b, test_step, compile_only, module, null, false);
}

fn addTestsWith(
    b: *std.Build,
    test_step: *std.Build.Step,
    compile_only: bool,
    module: *std.Build.Module,
    libc_file: ?std.Build.LazyPath,
    emit_object: bool,
) *std.Build.Step.Compile {
    const tests = b.addTest(.{ .root_module = module, .emit_object = emit_object });
    if (libc_file) |file| tests.setLibCFile(file);
    if (compile_only or emit_object) {
        test_step.dependOn(&tests.step);
        return tests;
    }
    const run = b.addRunArtifact(tests);
    // A build for a foreign target still checks every declaration and skips only the run.
    run.skip_foreign_checks = true;
    test_step.dependOn(&run.step);
    return tests;
}

/// The vector tests decode 12 files with a spectral comparison, so they always build for speed.
fn addVectorTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    compile_only: bool,
    target: std.Build.ResolvedTarget,
    single_threaded: ?bool,
    vectors: *std.Build.Dependency,
) void {
    const codec = b.createModule(.{
        .root_source_file = b.path("lib/codec.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .single_threaded = single_threaded,
    });
    const vector_options = b.addOptions();
    // The package root holds the testvectorNN files, as Zig strips the single top directory.
    vector_options.addOptionPathDirectory("vectors_dir", vectors.path(""));
    const module = b.createModule(.{
        .root_source_file = b.path("lib/codec/opus/vectors_test.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .single_threaded = single_threaded,
        .imports = &.{
            .{ .name = "codec", .module = codec },
            .{ .name = "vector_options", .module = vector_options.createModule() },
        },
    });
    addTests(b, test_step, compile_only, module);
}

/// Links libaaudio from the NDK sysroot and returns the libc file for the tests.
fn linkAndroidNdk(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Target,
    ndk: []const u8,
) std.Build.LazyPath {
    const triple = switch (target.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .arm => "arm-linux-androideabi",
        .x86_64 => "x86_64-linux-android",
        .x86 => "i686-linux-android",
        .riscv64 => "riscv64-linux-android",
        else => |arch| std.debug.panic("the Android NDK has no sysroot for {t}", .{arch}),
    };
    // The libc file needs absolute paths.
    const root = b.root.root_dir.path orelse ".";
    const ndk_path = b.pathResolve(&.{ root, b.root.sub_path, ndk });
    const prebuilt = b.pathJoin(&.{ ndk_path, "toolchains/llvm/prebuilt" });
    const sysroot_path = b.pathJoin(&.{ prebuilt, hostDirectory(b, prebuilt), "sysroot" });
    const api = b.fmt("{s}/usr/lib/{s}/{d}", .{ sysroot_path, triple, target.os.version_range.linux.android });
    module.addLibraryPath(.{ .cwd_relative = api });
    module.linkSystemLibrary("aaudio", .{});

    const conf = b.addWriteFiles().add("libc.conf", b.fmt(
        \\include_dir={[sysroot]s}/usr/include
        \\sys_include_dir={[sysroot]s}/usr/include/{[triple]s}
        \\crt_dir={[api]s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\darwin_sdk_dir=
        \\cc_dir={[api]s}
        \\
    , .{ .sysroot = sysroot_path, .triple = triple, .api = api }));
    return conf;
}

/// The NDK names the host directory by OS and CPU, so the one directory in prebuilt is the host.
fn hostDirectory(b: *std.Build, prebuilt: []const u8) []const u8 {
    const io = b.graph.io;
    var dir = std.Io.Dir.cwd().openDir(io, prebuilt, .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open {s}, check -Dandroid-ndk: {t}", .{ prebuilt, err });
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("cannot list {s}: {t}", .{ prebuilt, err })) |entry| {
        if (entry.kind == .directory) return b.dupe(entry.name);
    }
    std.debug.panic("{s} has no host directory, check -Dandroid-ndk", .{prebuilt});
}
