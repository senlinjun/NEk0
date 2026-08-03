<p align="center">
  <img src="resource/logo.png" alt="NEk0 logo" width="128" height="128">
</p>

<h1 align="center">NEk0</h1>
<p align="center">A TeamSpeak 3 client for Android built with Flutter &amp; Rust</p>

<p align="center">
  <a href="README_ZH.md">中文</a> ·
  <a href="https://github.com/ReSpeak/tsclientlib">tsclientlib</a>
</p>

---

## Features

- **Voice chat** — real-time OpusVoice (48kHz mono) with VAD and PTT
- **Background keep-alive** — stays connected in the background like a music player,
  backed by a foreground service + media session with mute/disconnect notification controls
- **Per-client volume** — adjust each user's volume locally, remembered by identity across sessions
- **Channel chat** — send and receive text messages in channels
- **Server bookmarks** — save and manage server addresses locally

## Architecture

| Layer | Stack |
|---|---|
| UI | Flutter (Dart) + Riverpod |
| Protocol & codec | Rust ([tsclientlib](https://github.com/ReSpeak/tsclientlib), `opus-rs`) |
| Playback | Rust (`cpal` — continuous output stream, silence when idle) |
| Mic capture | Kotlin (`AudioRecord`) → EventChannel → Dart → FFI → Rust |
| Background persistence | `KeepAliveService` (foreground service + `MediaSession`) |

```
Flutter (Dart)                  Rust (Native .so)
─────────────                  ─────────────────
lib/services/ts_ffi.dart  ←FFI→  native/src/api.rs
lib/services/audio_service.dart  native/src/lib.rs
lib/models/ts_state.dart         (tsclientlib + opus-rs + tokio)

Kotlin (Android)
────────────────
MainActivity.kt         ←EventChannel→  audio_service.dart   (mic via AudioRecord)
KeepAliveService.kt     ←MethodChannel→ foreground_service.dart (foreground service
                         + MediaSession + notification controls)
```

## Prerequisites

| Tool | Version |
|------|---------|
| Flutter | 3.x (Dart >=3.11) |
| Rust | 1.70+ |
| Android SDK | Latest |
| Android NDK | 26+ |

## Build & Run

Quick way — builds both ABIs and copies the `.so` files in one step:

```bash
# 1. Install Rust Android targets
rustup target add aarch64-linux-android x86_64-linux-android

# 2. Build the native library (requires ANDROID_NDK_HOME pointing at an installed NDK)
python3 pre_build.py

# 3. Run
flutter run
```

Manual alternative (same result, step by step):

```bash
cd native
cargo build --release --target aarch64-linux-android
cargo build --release --target x86_64-linux-android
cp target/aarch64-linux-android/release/libtsclient.so ../android/app/src/main/jniLibs/arm64-v8a/
cp target/x86_64-linux-android/release/libtsclient.so ../android/app/src/main/jniLibs/x86_64/
```

`libtsclient.so` is gitignored — the app runs only after it has been built and copied.

## Debug

```bash
adb logcat | grep flutter          # Flutter logs
adb logcat | grep RustStdouterr    # Rust logs
adb logcat | grep -E "cpal|opus"   # Audio logs
adb shell dumpsys media_session    # Media session active/playing (keep-alive)
adb shell dumpsys activity services com.senlinjun.nek0  # Foreground service state
```

## Permissions

| Permission | Purpose |
|------------|---------|
| `INTERNET` | Connect to TeamSpeak servers |
| `RECORD_AUDIO` | Microphone capture (requested at runtime) |
| `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MEDIA_PLAYBACK` / `FOREGROUND_SERVICE_MICROPHONE` | Background keep-alive service |
| `POST_NOTIFICATIONS` | Service notification (Android 13+) |
| `WAKE_LOCK` | Keep the CPU awake for audio while connected |

## Project Structure

```
Nek0/
├── android/app/src/main/
│   ├── jniLibs/                    # Pre-built .so files (gitignored, built by pre_build.py)
│   ├── kotlin/.../MainActivity.kt  # Mic capture (AudioRecord), platform channels
│   ├── kotlin/.../KeepAliveService.kt      # Foreground service + MediaSession
│   ├── kotlin/.../NotificationActionReceiver.kt  # Notification button actions
│   └── AndroidManifest.xml
├── lib/                            # Flutter
│   ├── models/                     # Data models + Riverpod state
│   ├── screens/                    # Screens
│   ├── services/                   # FFI bindings + audio + foreground service
│   └── widgets/                    # UI components
├── native/                         # Rust
│   ├── Cargo.toml                  # Patches tsclientlib/tsproto → local_tsclientlib/
│   ├── local_tsclientlib/          # Vendored tsclientlib/tsproto sources
│   └── src/
│       ├── lib.rs                  # State, types, command queue
│       └── api.rs                  # FFI functions, event loop, audio codec
├── resource/
│   └── logo.png
├── AGENTS.md                       # Architecture & build guide for AI agents
├── README.md
├── README_ZH.md
├── CONTRIBUTING.md
└── pubspec.yaml
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

For educational use. [tsclientlib](https://github.com/ReSpeak/tsclientlib) has its own license.
