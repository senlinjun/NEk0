# AGENTS.md

NEk0: an Android TeamSpeak 3 client. Flutter UI + Rust FFI. The connection, audio codec,
and session state live entirely in a Rust `.so` inside the app process.

## Build & verify

```bash
# 1. Rust → .so (REQUIRED before the app can run; libtsclient.so is gitignored)
#    Requires ANDROID_NDK_HOME set to an installed NDK.
python3 pre_build.py   # builds x86_64+aarch64, copies .so into android/app/src/main/jniLibs/

# 2. Dart checks — must pass before committing (CI runs `--set-exit-if-changed`)
dart format . --set-exit-if-changed
flutter analyze

# 3. App
flutter run / flutter build apk
```

A missing `libtsclient.so` does NOT fail the Gradle build — it crashes at runtime in
`lib/services/ts_ffi.dart` (`DynamicLibrary.open('libtsclient.so')`). CI
(`.github/workflows/ci.yml`) runs only on tag pushes: `cargo check` → `pre_build.py` →
`dart format` + `flutter analyze` → `flutter build apk` (release artifacts).

## Architecture

- `native/` — Rust `cdylib` (`tsclient`). `src/lib.rs`: globals (`STATE` mutex, tokio
  `RUNTIME`, `CONNECTION_STASH`, lock-free per-client jitter buffers, `AUDIO_STREAM` cpal
  stream). `src/api.rs`: all `ts_*` FFI exports, the connection event loop, audio mixing.
- `native/Cargo.toml` **patches** the tsclientlib/tsproto git deps to the vendored copy in
  `native/local_tsclientlib/` — keep the vendored sources and git branch in sync.
- `lib/services/ts_ffi.dart` — FFI bindings. Rust-returned strings MUST be freed via
  `ts_free_string` (the `_ptrToString` helper does this; use it for any new FFI functions).
- Event flow: Dart polls `TsNative.pollEvents()` on a 200ms `Timer.periodic`; Rust pushes
  `TsEvent`s (`connected`, `disconnected`, `text_message`, ...) that drive Riverpod state,
  audio, and the foreground service.
- Playback is Rust `cpal` (continuous output stream, silence when idle); mic capture is
  Kotlin `AudioRecord` in `MainActivity.kt`, streamed to Dart over EventChannel
  `com.senlinjun.nek0/mic`. (README's `flutter_pcm_sound` architecture line is stale — cpal.)

## Android specifics

- MethodChannel `com.senlinjun.nek0/service` (start/update/stop foreground service,
  `request_battery_optimization_exemption`) is handled in `MainActivity.kt`.
- One cached FlutterEngine (`"teamspeak_engine"`) is shared by the Activity and
  `NotificationActionReceiver` so platform channels keep working while backgrounded.
- Keep-alive: `KeepAliveService.kt` runs a foreground service (mediaPlayback[|microphone])
  + a `MediaSession` in PLAYING state while connected — this is what exempts the app from
  Android 14/15 background kill policies (Android 15 caps mediaPlayback FGS at 6h/24h
  without an active media session). Changes here must keep that design intact.
- **Swipe-away disconnect is intentional**: `onTaskRemoved` calls `tsDisconnect()` and
  tears down the service — do not change it.
- Kotlin gotcha: `android.app.Notification` has NO `setMediaSession()`/`mediaSession` member
  (verified via javap on the SDK jar). The session token attaches only through
  `Notification.MediaStyle().setMediaSession(token)` on the Builder (`buildNotification`).
- Kotlin sources live under `kotlin/com/example/teamspeak_apk/` but declare
  `package com.senlinjun.nek0` (the applicationId). Keep the package, not the directory.

## Conventions

- No Dart/Rust tests exist in this repo; verification is `dart format` + `flutter analyze`
  (+ `cargo check` for Rust changes).
- Keep all code and comments in English.
- i18n: all UI strings go through `AppLocalizations` (gen-l10n). After editing
  `lib/l10n/*.arb`, run `flutter gen-l10n` — generated files in `lib/l10n/generated/`
  ARE committed (CI's `dart format`/`analyze` depend on them). Notification-button
  labels are localized in Dart and passed to `KeepAliveService` via the service
  channel (`mute_label`/`unmute_label`/`disconnect_label`).
