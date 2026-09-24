# AGENTS.md

NEk0: a TeamSpeak 3 client for Android, Windows and Linux. Flutter UI + Rust FFI. The
connection, audio codec, and session state live entirely in a Rust dynamic library
inside the app process.

## Build & verify

```bash
# 1. Rust → native library (REQUIRED before the app can run; artifacts are gitignored)
python3 pre_build.py android   # x86_64+aarch64 .so into android/app/src/main/jniLibs/
                               # (requires ANDROID_NDK_HOME set to an installed NDK)
python3 pre_build.py linux     # host .so into native/prebuilt/linux/ (picked up by linux/CMakeLists.txt)
python3 pre_build.py windows   # tsclient.dll into native/prebuilt/windows/ (Windows host only,
                               # picked up by windows/CMakeLists.txt)
python3 pre_build.py           # default: android when ANDROID_NDK_HOME is set, else host

# 2. Dart checks — must pass before committing (CI runs `--set-exit-if-changed`)
dart format . --set-exit-if-changed
flutter analyze
flutter test

# 3. Rust checks — `cargo check` per changed target (the android targets need the
#    NDK toolchain env, see pre_build.py), plus the pure-logic unit tests in
#    lib.rs / api.rs / recording.rs, which need neither an audio device nor a
#    connection
cd native && cargo check && cargo check --target x86_64-linux-android
cargo test --lib

# 4. App
flutter run / flutter build apk          # Android
flutter build linux --release            # Linux (needs alsa-lib, gtk3, ninja, pkg-config)
flutter build windows --release          # Windows (needs VS C++ workload)
```

A missing native library does NOT fail the Gradle/CMake build — it crashes at runtime in
`lib/services/ts_ffi.dart`, which loads `libtsclient.so` (Android), `<exe-dir>/lib/libtsclient.so`
(Linux bundle), or `tsclient.dll` (Windows, exe dir). CI (`.github/workflows/ci.yml`) has two
jobs: `android-linux` (ubuntu: `cargo check` + `cargo test --lib` → android+linux prebuild →
`flutter gen-l10n` + `dart format` + `flutter analyze` + `flutter test` → `flutter build linux`
→ tag: APKs + Linux tar.gz release)
and `windows` (prebuild → `flutter build windows` → tag: zip release).

## Architecture

- `native/` — Rust `cdylib` (`tsclient`). `src/lib.rs`: globals (`STATE` mutex, tokio
  `RUNTIME`, `CONNECTION_STASH`, lock-free per-client jitter buffers, `AUDIO_STREAM` /
  `MIC_STREAM` cpal streams). `src/api.rs`: all `ts_*` FFI exports, the connection event
  loop, audio mixing.
- `native/Cargo.toml` **patches** the tsclientlib/tsproto git deps to the vendored copy in
  `native/local_tsclientlib/` — keep the vendored sources and git branch in sync.
- `lib/services/ts_ffi.dart` — FFI bindings. Rust-returned strings MUST be freed via
  `ts_free_string` (the `_ptrToString` helper does this; use it for any new FFI functions).
- Event flow: Dart polls `TsNative.pollEvents()` on a 200ms `Timer.periodic`; Rust pushes
  `TsEvent`s (`connected`, `disconnected`, `text_message`, ...) that drive Riverpod state,
  audio, and the foreground service.
- Playback is Rust `cpal` — a continuous output stream (silence when idle). The internal
  mixing clock is always 48 kHz mono (`PLAYED_SAMPLES`); the device-facing stream is
  negotiated through a fallback chain (48k/mono/Fixed(960) → 48k/mono/Default → device
  default channels/rate) with in-callback linear resampling (`OutRing` +
  `gen_output_mix_frame` in api.rs). Device changes trigger rebuilds via
  `OUTPUT_RESTART_REQUESTED`.
- **Inbound voice latency is a per-speaker *adaptive* playout lead**, not a fixed constant.
  A speaker's stream is anchored `target_frames` (20 ms frames) ahead of the mixing clock;
  the state lives in `JitterStats` (`lib.rs`), keyed by client id in `JITTER_STATS` and
  deliberately outliving the 10 s `CLIENT_BUFFERS` teardown so a client's network profile
  survives a quiet spell. The lead starts at `TARGET_FRAMES_INIT` (6 = 120 ms) and
  `observe_margin`/`anchor_target` walk it down to `TARGET_FRAMES_FLOOR` (3 = 60 ms) using
  the decaying minimum of the measured arrival margin, or up (≤1 frame per 2 s) when packets
  arrive late. The lead may only *change* at an anchor — the first packet, or a ≥200 ms
  arrival gap where the reader has overtaken the writer — because shortening it mid-stream
  would skip already-buffered frames; a late-arrival growth instead inserts one frame of
  silence and is safe anywhere. Arrival margins come from `CLOCK_REF` (packed
  `(slot << 40) | ms`, published once per generated mix frame) via `play_time_ms`.
  `MIN_SURPLUS_FRAMES` closes the clock-drift loop: while *every* active speaker has frames
  buffered beyond their own target, the resampling loop advances the mix clock up to 1%
  faster (`compression_eps`) until the surplus is gone — this is what stops a fast sender
  clock from turning into ever-growing delay. The 5 s `[cpal-stats]` line reports
  `period_ms` (measured device period, the floor under any playout slack), `depth_ms`,
  `target_ms`, `late` and `gaps`; `[jbuf] rebase …` logs every re-anchor.
- Never take `STATE.lock()` on the audio receive path: `decode_to_client_buffer` runs for
  every voice packet, and Dart's 200 ms polling holds the same lock while serializing the
  roster. The "is talking" heartbeat therefore lives in the `TALKING_CLIENTS` DashMap
  (`talking_clients` is no longer a field of `TsConnection`), swept by the 5 s maintenance
  tick instead of per event-loop iteration; the callback snapshot (`ACTIVE_CLIENT_IDS`) is
  extended immediately when a speaker's buffer is created instead of waiting up to 500 ms
  for the next tick.
- Mic capture has two paths behind `AudioService` (`lib/services/audio_service.dart`):
  - Android: Kotlin `AudioRecord` in `MainActivity.kt` → EventChannel
    `com.senlinjun.nek0/mic` → Dart → `ts_send_audio`.
  - Windows/Linux: `ts_set_mic_capture` builds a cpal input stream inside the Rust core;
    its callback resamples to 48 kHz mono and feeds the same `Command::SendAudio` encode
    path. Dart polls `ts_get_mic_rms` (50ms timer) for the level meter.
  Both paths converge on VAD → mic gain → Opus encode in the event loop.
- Platform gating: `ForegroundService` (foreground service, notification actions, battery
  exemption, poke notifications, MediaStore saves) is Android-only and degrades to no-ops
  elsewhere — except `saveToDownloads`, which on desktop writes into the system Downloads
  directory (`getDownloadsDirectory`). OTA (`OtaService`) is Android-only
  (`OtaService.isSupported`); settings/home screens hide it. On desktop,
  `save_to_downloads` collisions are resolved in Dart (`name (2).ext`).

## Android specifics

- MethodChannel `com.senlinjun.nek0/service` (start/update/stop foreground service,
  `request_battery_optimization_exemption`, `save_to_downloads`, `notify_poke`) is handled
  in `MainActivity.kt`.
- One cached FlutterEngine (`"teamspeak_engine"`) is shared by the Activity and
  `NotificationActionReceiver` so platform channels keep working while backgrounded.
- Keep-alive: `KeepAliveService.kt` runs a foreground service (mediaPlayback[|microphone])
  + a `MediaSession` in PLAYING state while connected — this is what exempts the app from
  Android 14/15 background kill policies (Android 15 caps mediaPlayback FGS at 6h/24h
  without an active media session). Changes here must keep that design intact.
- **Swipe-away disconnect is intentional**: `onTaskRemoved` calls `tsDisconnect()` and
  tears down the service — do not change it. The corresponding JNI exports in
  `native/src/api.rs` are `#[cfg(target_os = "android")]` — keep them gated.
- Kotlin gotcha: `android.app.Notification` has NO `setMediaSession()`/`mediaSession` member
  (verified via javap on the SDK jar). The session token attaches only through
  `Notification.MediaStyle().setMediaSession(token)` on the Builder (`buildNotification`).
- `ndk-context` MUST be initialized before any cpal stream is built on Android: cpal/oboe
  resolve the JVM through it (AudioTrack/AudioRecord buffer-size queries go through JNI)
  and panic with "android context was not initialized" otherwise. A Flutter FFI app has
  no ndk-glue, so `MainActivity.onCreate` calls the `tsInitAndroid` JNI export (see
  `native/src/api.rs`) at the very top. Keep that ordering intact when touching startup.
- Kotlin sources live under `kotlin/com/example/teamspeak_apk/` but declare
  `package com.senlinjun.nek0` (the applicationId). Keep the package, not the directory.

## Conventions

- Dart tests live under `test/` (pure logic only: models, service state machines). They must
  never call anything that reaches `TsNative` — its lazy `DynamicLibrary.open` would crash
  the test isolate — and only public, FFI-free notifier/service methods are driven. Run with
  `flutter test`. Rust has in-file `#[cfg(test)] mod tests` blocks in `lib.rs` (WAV parsing,
  the adaptive playout-lead state machine, the Dart-facing serde JSON contract), `api.rs`
  (sequence unwrap, positional gains, OutRing, compression_eps, the mic resampler) and
  `recording.rs` (filenames, f32_to_i16, WavWriter) — run `cargo test --lib` in `native/`
  (the `cdylib`-only crate type rules out a `tests/` directory). Verification is
  `dart format` + `flutter analyze` + `flutter test` (+ `cargo check` and `cargo test --lib`
  for Rust changes; check host + both android targets when touching audio or FFI code).
- Keep all code and comments in English.
- i18n: all UI strings go through `AppLocalizations` (gen-l10n). After editing
  `lib/l10n/*.arb`, run `flutter gen-l10n` — generated files in `lib/l10n/generated/`
  ARE committed (CI's `dart format`/`analyze` depend on them). Notification-button
  labels are localized in Dart and passed to `KeepAliveService` via the service
  channel (`mute_label`/`unmute_label`/`disconnect_label`).
- Platform scaffolding: `linux/` and `windows/` were generated by
  `flutter create --platforms=... --project-name nek0 --org com.senlinjun` (the pubspec
  name `NEk0` has uppercase letters, hence the explicit `--project-name`). Window/bundle
  display name is NEk0; the executable stays lowercase `nek0`.
