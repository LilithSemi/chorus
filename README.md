# chorus

Portable audio library in pure Zig for Linux, macOS, Android and the web.

## Use

```zig
const chorus = @import("chorus");

const ctx = try chorus.Context.init(gpa, io, .{ .app_name = "demo" });
defer ctx.deinit();

const stream = try ctx.openStream(.{
    .direction = .playback,
    .format = .{ .sample = .f32, .rate = 48000, .channels = .stereo },
    .callback = .{ .ctx = &state, .func = render },
});
try stream.start();

while (running) _ = try ctx.dispatch();
```

`.auto` can fall back to the null backend, which renders and drops the audio. Check `ctx.info().backend` to see if real audio is there.

When `dispatch` gives `.disconnected`, call `ctx.reconnect()`. On the web a closed `AudioContext` gives `.disconnected` once, and `reconnect` makes a new one and starts the streams that ran.

### Play sounds

`Player` mixes sounds on one playback stream. `load` decodes a short sound into memory, and `stream` decodes a long file while it plays.

```zig
const player = try chorus.Player.init(ctx, .{});
defer player.deinit();

const click = try player.load(.{ .bytes = click_wav }, .{});
_ = try player.play(click, .{ .gain = 0.8 });
_ = try player.stream(.{ .reader = &music_reader }, .{ .loop = false });
```

### Record

`Recorder` sends a capture stream through an encoder into a writer. `finish` stops the stream, drains it and flushes the file.

```zig
const recorder = try chorus.Recorder.init(ctx, &writer, .{
    .format = .{ .sample = .f32, .rate = 48000, .channels = .stereo },
    .encode = .{ .wav = .{ .sample = .s16 } },
});
defer recorder.deinit();
try recorder.start();
// Call ctx.dispatch while you record.
try recorder.finish();
```

An app that waits on `ctx.fd()` also waits for `ctx.timeoutMs()`, then calls `ctx.dispatch()`. Player and Recorder do their work in `dispatch`.

### Android

On Android, Chorus plays and records through AAudio. An app must do these things.

- Give your build a libc file for bionic. Chorus links libc itself, because the backend uses it.
- Pass `-Dandroid-ndk=<absolute path>` to the chorus dependency, or add the NDK library directory `<sysroot>/usr/lib/<triple>/<api>` to the library path of your own build. Chorus links `aaudio` itself. A build with neither fails at link time.
- Pass `java_vm` and `android_context` (a global reference) in `aaudio_backend` to get the device list and the volume. Without them the Mixer has one default sink and one default source.
- Add `android.permission.RECORD_AUDIO` to the manifest and ask for it before you open a capture stream. Without the permission the open gives `error.PermissionDenied` when `java_vm` and `android_context` are set, and `error.Disconnected` otherwise.
- Call Chorus on the thread that created the Context. All JNI calls run on that thread.
- `dispatch` can block while the system audio service restarts. Run the Context on a thread other than the UI thread if that matters.

`ctx.backend.as(chorus.backend.AAudio).?.jniSetupError()` reports why a JNI setup failed. The Mixer then keeps the default endpoints.

To run the live tests on a device, build with `zig build test-android -Dtarget=aarch64-linux-android.26 -Dandroid-ndk=<path>`. Push `zig-out/test/chorus-test` to `/data/local/tmp` and run it with `adb shell 'cd /data/local/tmp && ./chorus-test'`. The shell user can write only there.

### macOS

On macOS, Chorus plays and records through CoreAudio. Build it on a Mac, because a Linux to macOS cross build is not supported.

- A build needs the macOS SDK. Use Xcode, the Command Line Tools, or the nix dev shell. In the nix dev shell the build reads `SDKROOT`. After `SDKROOT` changes, remove `.zig-cache` before you build again.
- Chorus links CoreAudio, AudioToolbox and CoreFoundation. It loads AVFoundation at run time to read the microphone permission status.
- Capture needs `NSMicrophoneUsageDescription` in the Info.plist of the app. A hardened runtime app also needs the `com.apple.security.device.audio-input` entitlement. A sandboxed app needs `com.apple.security.device.microphone`. The app owns these. The system keeps the microphone permission (TCC) for the app and asks the user the first time. When the user denies access, the open of a capture stream gives `error.PermissionDenied`.
- A Mac with no input device gives an error when you open a capture stream. The Mixer then has no default source.
- A process in an ssh session with no console login gets no audio callbacks. The start succeeds and nothing plays.
- Chorus never changes the sample rate of a device. `Mixer.setDefault` changes the system default device for every app.

To run the live tests, run `zig build test` on a Mac in a login session with audio, for example Terminal in a Screen Sharing session. A playback test skips when no callback arrives in 2 s. The tests play silence and change no device setting.

### Web

On wasm32-freestanding, Chorus plays through one `AudioContext` and one gain node for each stream. Capture and device choice do not exist on the web, so `openStream` for capture gives `error.UnknownDevice`. The page must provide the webidl host, which is the JS side of webidl.zig. Chorus ships no JS.

- A browser starts an `AudioContext` only after the user touched the page. Audio stays silent until then, and Chorus calls `resume` by itself once the page has been touched. On Safari, also call `ctx.dispatch()` inside the `click`, `pointerdown`, `pointerup`, `touchend` or `keydown` handler, before any `await`. Chorus then calls `resume` inside the gesture. The automatic `resume` is enough only where the browser counts earlier page use, as Chromium does. Chromium logs a warning for each started source until the first gesture.
- Call `ctx.dispatch()` on every animation frame. Also call it from a 20 ms timer while the page is hidden, because the browser stops animation frames in hidden tabs.
- Pin the same webidl.zig as your app. The url and hash are in `build.zig.zon`. Two copies of webidl.zig in one wasm file fail to link.
- `zig build -Dtarget=wasm32-freestanding` fetches webidl.zig and builds a `web-check` exe. The exe imports only `env.__webidl_*` functions. Other targets never fetch webidl.zig.

## Test

```sh
zig build test
zig build -Dtarget=wasm32-freestanding
```

The second command is the web compile check. It builds the `web-check` exe, because the Zig test runner cannot build for freestanding targets.

## Licence

Chorus is Apache 2.0. The Opus codec uses code and tables from libopus, which is BSD 3 clause. Its notice is in `LICENSE-libopus`.
