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
- **Per-client volume** — adjust each user's volume locally, remembered by identity across sessions
- **Channel chat** — send and receive text messages in channels
- **Server bookmarks** — save and manage server addresses locally

## Architecture

| Layer | Stack |
|---|---|
| UI | Flutter (Dart) + Riverpod |
| Audio I/O | Rust (`opus-rs`) + Kotlin (`AudioRecord`) |
| Protocol | Rust ([tsclientlib](https://github.com/ReSpeak/tsclientlib)) |
| Playback | `flutter_pcm_sound` → Android `AudioTrack` |

```
Flutter (Dart)                  Rust (Native .so)
─────────────                  ─────────────────
lib/services/ts_ffi.dart  ←FFI→  native/src/api.rs
lib/services/audio_service.dart  native/src/lib.rs
lib/models/ts_state.dart         (tsclientlib + opus-rs + tokio)

Kotlin (Android)
────────────────
MainActivity.kt  ←EventChannel→  audio_service.dart  (mic via AudioRecord)
```

## Prerequisites

| Tool | Version |
|------|---------|
| Flutter | 3.x (Dart >=3.11) |
| Rust | 1.70+ |
| Android SDK | Latest |
| Android NDK | 26+ |

## Build & Run

```bash
# 1. Install Rust Android targets
rustup target add aarch64-linux-android x86_64-linux-android

# 2. Configure NDK linker (edit native/.cargo/config.toml, see below)

# 3. Build native library
cd native
cargo build --release --target aarch64-linux-android
cargo build --release --target x86_64-linux-android

# 4. Copy .so files
cp target/aarch64-linux-android/release/libtsclient.so ../android/app/src/main/jniLibs/arm64-v8a/
cp target/x86_64-linux-android/release/libtsclient.so ../android/app/src/main/jniLibs/x86_64/

# 5. Run
cd .. && flutter run
```

<details>
<summary>native/.cargo/config.toml</summary>

```toml
[target.aarch64-linux-android]
linker = "<ndk>/toolchains/llvm/prebuilt/<host>/bin/aarch64-linux-android21-clang"

[target.x86_64-linux-android]
linker = "<ndk>/toolchains/llvm/prebuilt/<host>/bin/x86_64-linux-android21-clang"
```

</details>

## Debug

```bash
adb logcat | grep flutter          # Flutter logs
adb logcat | grep RustStdouterr    # Rust logs
adb logcat | grep -E "opus|audio"  # Audio logs
```

## Permissions

| Permission | Purpose |
|------------|---------|
| `INTERNET` | Connect to TeamSpeak servers |
| `RECORD_AUDIO` | Microphone capture (requested at runtime) |

## Project Structure

```
teamspeak_apk/
├── android/app/src/main/
│   ├── jniLibs/                    # Pre-built .so files
│   ├── kotlin/.../MainActivity.kt  # Mic capture (AudioRecord)
│   └── AndroidManifest.xml
├── lib/                            # Flutter
│   ├── models/                     # Data models
│   ├── screens/                    # Screens
│   ├── services/                   # FFI bindings + audio service
│   └── widgets/                    # UI components
├── native/                         # Rust
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs                  # State, types, command queue
│       └── api.rs                  # FFI functions, event loop, audio codec
├── resource/
│   └── logo.png
├── README.md
├── README_ZH.md
└── pubspec.yaml
```

## License

For educational use. [tsclientlib](https://github.com/ReSpeak/tsclientlib) has its own license.
