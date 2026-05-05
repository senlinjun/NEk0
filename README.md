# TeamSpeak Android Client

A TeamSpeak 3 client for Android built with **Flutter** (UI) and **Rust** (TS3 protocol via [tsclientlib](https://github.com/ReSpeak/tsclientlib)).

## Features

- Connect to any TeamSpeak 3 server
- View channel tree with expand/collapse
- View users in the selected channel
- Send and receive text messages (channel chat)
- Switch channels
- Mute/unmute microphone and speaker
- **Real-time voice chat** — microphone input + audio playback (OpusVoice, 48kHz mono)
- Server bookmark management (saved locally)

## Architecture

```
Flutter (Dart)                  Rust (Native .so)
─────────────                  ─────────────────
lib/services/ts_ffi.dart  ←FFI→  native/src/api.rs
lib/services/audio_service.dart  native/src/lib.rs
lib/models/ts_state.dart         (tsclientlib + opus-rs + tokio)
lib/screens/
lib/widgets/

Kotlin (Android)
────────────────
MainActivity.kt  ←EventChannel→  audio_service.dart  (mic capture via AudioRecord)
```

- **Flutter** handles UI, state management (Riverpod), audio playback (`flutter_pcm_sound`), and event polling.
- **Rust** handles the TS3 protocol through `tsclientlib`, Opus encoding/decoding via `opus-rs`, and exposes C FFI functions.
- **Kotlin** handles microphone capture via Android `AudioRecord` (48kHz, mono, PCM_FLOAT) and streams data through an EventChannel.
- Communication: Flutter polls Rust for events every 200ms. Commands (send message, move channel, mute, disconnect, send audio) are sent through a channel queue that the Rust event loop processes.

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Flutter | 3.x (Dart >=3.11) | [Install](https://docs.flutter.dev/get-started/install) |
| Rust | 1.70+ | [Install](https://rustup.rs/) |
| Android SDK | Latest | Via Android Studio or standalone |
| Android NDK | 26+ | Install via Android Studio SDK Manager |
| Rust Android targets | - | See below |

## Setup

### 1. Install Rust Android targets

```bash
rustup target add aarch64-linux-android x86_64-linux-android
```

### 2. Configure Android NDK linker

Create (or edit) `native/.cargo/config.toml` with the paths to your NDK toolchain. Find your NDK path first:

- **Windows**: `%LOCALAPPDATA%/Android/Sdk/ndk/<version>/` or custom path
- **Linux**: `~/Android/Sdk/ndk/<version>/`
- **macOS**: `~/Library/Android/sdk/ndk/<version>/`

Then create the config:

```toml
[target.aarch64-linux-android]
linker = "<ndk-path>/toolchains/llvm/prebuilt/<host>/bin/aarch64-linux-android21-clang.cmd"
# On Linux/macOS remove the .cmd extension

[target.x86_64-linux-android]
linker = "<ndk-path>/toolchains/llvm/prebuilt/<host>/bin/x86_64-linux-android21-clang.cmd"
# On Linux/macOS remove the .cmd extension
```

Replace `<ndk-path>` with your actual NDK path and `<host>` with your platform:
- **Windows**: `windows-x86_64`
- **Linux**: `linux-x86_64`
- **macOS**: `darwin-x86_64` (Intel) or `darwin-aarch64` (Apple Silicon)

Example (Windows):
```toml
[target.aarch64-linux-android]
linker = "D:/software/android/SDK/ndk/29.0.13599879/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android21-clang.cmd"

[target.x86_64-linux-android]
linker = "D:/software/android/SDK/ndk/29.0.13599879/toolchains/llvm/prebuilt/windows-x86_64/bin/x86_64-linux-android21-clang.cmd"
```

### 3. Get Flutter dependencies

```bash
flutter pub get
```

## Build & Run

### Step 1: Build the Rust native library

```bash
cd native

# Build for ARM64 (most Android devices)
cargo build --release --target aarch64-linux-android

# Build for x86_64 (Android emulator)
cargo build --release --target x86_64-linux-android
```

This produces two shared libraries:
- `native/target/aarch64-linux-android/release/libtsclient.so`
- `native/target/x86_64-linux-android/release/libtsclient.so`

### Step 2: Copy .so files to jniLibs

```bash
# From the native directory
cp target/aarch64-linux-android/release/libtsclient.so ../android/app/src/main/jniLibs/arm64-v8a/
cp target/x86_64-linux-android/release/libtsclient.so ../android/app/src/main/jniLibs/x86_64/
```

### Step 3: Run the app

```bash
flutter run
```

Or build a release APK:

```bash
flutter build apk --release
```

The APK will be at `build/app/outputs/flutter-apk/app-release.apk`.

## Debugging

### View logs

```bash
# All app logs
adb logcat | grep flutter

# Rust logs (eprintln! output from native code)
adb logcat | grep RustStdouterr

# Audio-specific logs
adb logcat | grep -E "ts_send_audio|opus encode|audio"
```

### Key diagnostic log patterns

| Pattern | Meaning |
|---------|---------|
| `ts_send_audio: N samp peak=X rms=Y` | Microphone PCM data arriving at Rust |
| `opus encode: N samp -> M bytes` | Opus encoding result (voice traffic) |
| `audio: decoded N samp peak=X` | Incoming voice decoded from server |
| `event_loop PANICKED: ...` | Crash in the Rust event loop |
| `PANIC celt.rs:1746` | Opus encoder panic (undersized mic frame) |
| `event_loop: started (gen=1)` | Event loop started successfully |

### Common issues

| Problem | Solution |
|---------|----------|
| `linker 'cc' not found` | Create `native/.cargo/config.toml` with NDK linker paths (see Setup step 2) |
| App crashes on launch | Ensure `libtsclient.so` exists in both `jniLibs/arm64-v8a/` and `jniLibs/x86_64/` |
| `event_loop PANICKED: index out of bounds` | Mic is sending fewer than 960 samples per chunk; check PCM buffer is enabled |
| No audio from others | Verify `flutter_pcm_sound` is set up; check decoder is mono (1 channel) |
| Garbled outbound voice | Check opus encoder is mono/Voip mode; verify PCM buffering is working |
| cmake/audiopus build error | Make sure `default-features = false` is set for `tsclientlib` in `Cargo.toml` |
| Cannot connect to server | Check that the server address includes port if non-default (e.g. `ts.example.com:9987`) |
| Mic permission denied | Grant microphone permission in Android settings or on first prompt |

## Permissions

The app requires these Android permissions (declared in `AndroidManifest.xml`):

| Permission | Purpose |
|------------|---------|
| `INTERNET` | Connect to TeamSpeak servers |
| `RECORD_AUDIO` | Microphone capture for voice chat |

Microphone permission is requested at runtime when you unmute the microphone. Without it, the app works in listen-only mode (you can hear others but cannot speak).

## Project Structure

```
teamspeak_apk/
├── android/                    # Android project
│   └── app/src/main/
│       ├── jniLibs/            # Pre-built .so files
│       │   ├── arm64-v8a/libtsclient.so
│       │   └── x86_64/libtsclient.so
│       ├── kotlin/.../
│       │   └── MainActivity.kt # Mic capture (AudioRecord + EventChannel)
│       └── AndroidManifest.xml # Permissions + app config
├── lib/                        # Flutter (Dart)
│   ├── main.dart               # App entry point
│   ├── models/
│   │   ├── channel.dart        # Channel model
│   │   ├── client.dart         # Client model
│   │   ├── chat_message.dart   # Chat message model
│   │   ├── server.dart         # Server bookmark model
│   │   └── ts_state.dart       # Riverpod state + event polling
│   ├── screens/
│   │   ├── home_screen.dart    # Server list / bookmarks
│   │   └── server_screen.dart  # Connected server view
│   ├── services/
│   │   ├── audio_service.dart  # Audio playback + mic capture
│   │   └── ts_ffi.dart         # FFI bindings to Rust .so
│   └── widgets/
│       ├── channel_tree.dart   # Channel tree with expand/collapse
│       ├── chat_panel.dart     # Chat message list + input
│       ├── client_list.dart    # User list in channel
│       ├── connection_bar.dart # Connection status + mute/disconnect
│       └── server_form_dialog.dart # Add/edit server dialog
├── native/                     # Rust crate
│   ├── .cargo/
│   │   └── config.toml         # NDK linker configuration
│   ├── Cargo.toml              # Dependencies (tsclientlib, opus-rs, tokio, etc.)
│   ├── local_tsclientlib/      # Patched tsclientlib (audio feature always available)
│   └── src/
│       ├── lib.rs              # Types, state, command queue, static globals
│       └── api.rs              # FFI functions, event loop, audio encode/decode
└── pubspec.yaml
```

## License

This project is for educational purposes. The underlying [tsclientlib](https://github.com/ReSpeak/tsclientlib) has its own license.
