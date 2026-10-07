# Contributing to NEk0

Thanks for contributing! NEk0 is an Android TeamSpeak 3 client with a Flutter UI and a
Rust FFI core: the connection, audio codec, and session state live entirely in a Rust
`.so` inside the app process. [AGENTS.md](AGENTS.md) has the condensed architecture and
build guide; this file covers the contribution workflow.

## Setup

1. Install Flutter (3.x), Rust (1.70+), and the Android SDK with an NDK (26+).
2. Add the Rust Android targets:

   ```bash
   rustup target add aarch64-linux-android x86_64-linux-android
   ```

3. Set `ANDROID_NDK_HOME` to an installed NDK — `pre_build.py` requires it.

## Building

```bash
python3 pre_build.py   # builds the Rust lib (x86_64 + aarch64) and copies the .so
                       # into android/app/src/main/jniLibs/
flutter run            # or: flutter build apk
```

Gotchas:

- `libtsclient.so` is gitignored. Without it the Gradle build still succeeds, but the
  app crashes at startup when `lib/services/ts_ffi.dart` calls
  `DynamicLibrary.open('libtsclient.so')`.
- For Rust-only changes, `cd native && cargo check` is enough for a quick sanity check;
  use `cargo build --release --target <abi>` (or `pre_build.py`) before installing.

## Before submitting

```bash
dart format . --set-exit-if-changed
flutter analyze
cd native && cargo check   # if you touched Rust
```

- CI (`.github/workflows/ci.yml`) runs on every push (any branch or tag) and enforces
  exactly these checks, then builds the release APKs.
- Pure-logic tests exist on both sides: `flutter test` (models / service state
  machines) and `cargo test --lib` in `native/`. Keep them green.

## Architecture in five bullets

- All connection state lives in Rust (`native/src/lib.rs` globals, `native/src/api.rs`
  FFI exports). Dart only polls events every 200ms (`ts_ffi.dart` + `ts_state.dart`).
- Rust-returned strings MUST be freed with `ts_free_string` — use the `_ptrToString`
  helper in `ts_ffi.dart` for any new FFI function.
- The protocol/session engine is univox (`univox-core` / `univox-ts3` /
  `univox-ts3-proto` in `native/Cargo.toml`, pinned by rev). `univox-ts3` must
  keep `default-features = false` — its optional audiopus codec would collide
  with Nek0's own opus-rs inside one cdylib.
- Playback is Rust `cpal` (continuous output stream, silence when idle); mic capture is
  Kotlin `AudioRecord` streamed to Dart over EventChannel `com.senlinjun.nek0/mic`.
- Background persistence is a deliberate design: `KeepAliveService` (foreground service
  + `MediaSession` in PLAYING state) keeps the app alive like a music player, while
  swiping the app away from recents disconnects on purpose. Do not change either
  behavior without discussion.

## Conventions

- Keep all code and comments in English.
- Kotlin sources live under `android/app/src/main/kotlin/com/example/teamspeak_apk/` but
  declare `package com.senlinjun.nek0` (the applicationId) — keep the package, not the
  directory.
- Kotlin gotcha: `android.app.Notification` has NO `setMediaSession()`/`mediaSession` member —
  the session token attaches only through `Notification.MediaStyle().setMediaSession(token)`
  on the Builder (see `buildNotification` in `KeepAliveService.kt`).

## Verifying keep-alive changes

```bash
adb shell dumpsys media_session                 # session should be active/playing
adb shell dumpsys activity services com.senlinjun.nek0  # foreground service state
adb logcat | grep -E "flutter|RustStdouterr"    # app + Rust logs
```
