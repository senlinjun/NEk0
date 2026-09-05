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

# 3. App
flutter run / flutter build apk          # Android
flutter build linux --release            # Linux (needs alsa-lib, gtk3, ninja, pkg-config)
flutter build windows --release          # Windows (needs VS C++ workload)
```

A missing native library does NOT fail the Gradle/CMake build — it crashes at runtime in
`lib/services/ts_ffi.dart`, which loads `libtsclient.so` (Android), `<exe-dir>/lib/libtsclient.so`
(Linux bundle), or `tsclient.dll` (Windows, exe dir). CI (`.github/workflows/ci.yml`) has two
jobs: `android-linux` (ubuntu: `cargo check` → android+linux prebuild → `flutter gen-l10n` +
`dart format` + `flutter analyze` → `flutter build linux` → tag: APKs + Linux tar.gz release)
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
- Kotlin sources live under `kotlin/com/example/teamspeak_apk/` but declare
  `package com.senlinjun.nek0` (the applicationId). Keep the package, not the directory.

## Conventions

- No Dart/Rust tests exist in this repo; verification is `dart format` + `flutter analyze`
  (+ `cargo check` for Rust changes; check host + both android targets when touching audio
  or FFI code).
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
