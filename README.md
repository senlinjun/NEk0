<p align="center">
  <img src="resource/logo.png" alt="NEk0 logo" width="128" height="128">
</p>

<h1 align="center">NEk0</h1>
<p align="center">A TeamSpeak 3 client for Android, Windows &amp; Linux built with Flutter &amp; Rust</p>

<p align="center">
  <a href="README_ZH.md">中文</a> ·
  <a href="https://github.com/ReSpeak/tsclientlib">tsclientlib</a>
</p>

---

## Features

- **Voice chat** — real-time OpusVoice (48kHz mono) with VAD and PTT
- **Full mute** — one-tap headset button (or the media card play/pause) silences
  input + output and stops the mic
- **Background keep-alive** — stays connected in the background like a music player,
  backed by a foreground service + media session with mute/disconnect notification controls
- **Per-client volume** — adjust each user's volume locally, remembered by identity across sessions
- **Channel chat** — send and receive text messages in channels
- **Server bookmarks** — save and manage server addresses locally
- **First-use guide** — interactive spotlight coach marks on the real UI
  (re-viewable from the help icons)
- **Voice settings** — VAD / PTT / mic gain / threshold tuning from the settings
  screen, by long-pressing the mic button, or by tapping your own name in the
  user list, with a live mic level + mic test
- **Voice packs** — replace all channel sounds at once by importing a zip pack
  (see [Voice Packs](#voice-packs) for the format)
- **Desktop support** — the same Rust core runs on Windows and Linux; mic capture
  uses a cpal input stream inside the native library, playback negotiates the
  device format with an automatic fallback chain
- **OTA updates (Android)** — checks GitHub/Gitee releases (tag format `vx.y.z`) on launch,
  downloads the ABI-matched APK and installs it; check can be disabled and the
  source chosen in settings

## Architecture

| Layer | Stack |
|---|---|
| UI | Flutter (Dart) + Riverpod |
| Protocol & codec | Rust ([tsclientlib](https://github.com/ReSpeak/tsclientlib), `opus-rs`) |
| Playback | Rust (`cpal` — continuous output stream, silence when idle) |
| Mic capture | Android: Kotlin (`AudioRecord`) → EventChannel → Dart → FFI → Rust<br>Windows/Linux: Rust (`cpal` input stream) → encode/send pipeline |
| Background persistence | `KeepAliveService` (foreground service + `MediaSession`, Android) |

```
Flutter (Dart)                  Rust (Native .so)
─────────────                  ─────────────────
lib/services/ts_ffi.dart  ←FFI→  native/src/api.rs
lib/services/audio_service.dart  native/src/lib.rs
lib/models/ts_state.dart         (tsclientlib + opus-rs + tokio)

Kotlin (Android only)
─────────────────────
MainActivity.kt         ←EventChannel→  audio_service.dart   (mic via AudioRecord)
KeepAliveService.kt     ←MethodChannel→ foreground_service.dart (foreground service,
                         MediaSession, notification controls, MediaStore saves)
```

## Prerequisites

| Tool | Version |
|------|---------|
| Flutter | 3.x (Dart >=3.11) |
| Rust | 1.70+ |
| Android SDK | Latest |
| Android NDK | 26+ |
| Linux: alsa-lib, gtk3, ninja, pkg-config | Latest (desktop build) |
| Windows: Visual Studio (C++ desktop workload) | Latest (desktop build) |

## Build & Run

### Android

Quick way — builds both ABIs and copies the `.so` files in one step:

```bash
# 1. Install Rust Android targets
rustup target add aarch64-linux-android x86_64-linux-android

# 2. Build the native library (requires ANDROID_NDK_HOME pointing at an installed NDK)
python3 pre_build.py android

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

### Linux

```bash
sudo apt install libasound2-dev libgtk-3-dev ninja-build   # build deps
python3 pre_build.py linux     # host-builds the Rust core into native/prebuilt/linux/
flutter build linux --release  # bundle: build/linux/x64/release/bundle/
./build/linux/x64/release/bundle/nek0
```

The bundle's CMake step picks up `native/prebuilt/linux/libtsclient.so` and installs it
into `<bundle>/lib/`, where `ts_ffi.dart` loads it from at runtime.

### Windows

```powershell
python3 pre_build.py windows   # builds tsclient.dll into native/prebuilt/windows/ (Windows host only)
flutter build windows --release
build\windows\x64\runner\Release\nek0.exe
```

The CMake build copies `tsclient.dll` next to `nek0.exe`, which is where `ts_ffi.dart`
loads it from at runtime.

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
| `REQUEST_INSTALL_PACKAGES` | OTA update APK installation |
| `WRITE_EXTERNAL_STORAGE` | OTA download (API <= 28) |

## Voice Packs

Channel sounds can be replaced as a whole by importing a voice pack — a
`.zip` archive containing a `pack.json` manifest and the WAV files it
references:

```
my-pack.zip
├── pack.json
├── connected.wav
├── disconnected.wav
└── ...
```

`pack.json`:

```json
{
  "name": "My pack",
  "description": "A short description shown in the settings screen",
  "sounds": {
    "11": "connected.wav",
    "12": "disconnected.wav"
  }
}
```

- `sounds` maps **event IDs** (table below) to WAV file names inside the zip.
  Events without an entry keep the built-in sound, so packs may cover only a
  few events.
- WAV requirements: PCM 16-bit or float32, mono or stereo, at most **2 seconds**
  per file (other sample rates are resampled to 48 kHz automatically).
- Import packs in **Settings → Audio → Channel sounds**. Importing a new
  version of the same pack (same manifest) updates it in place.

### Event IDs

| ID | Event |
|----|-------|
| 1 | You switched channels |
| 2 | Someone switched into your channel |
| 3 | Someone switched away from your channel |
| 4 | You were moved |
| 5 | You were kicked from a channel |
| 6 | You were kicked from the server |
| 7 | You were banned |
| 8 | You were poked |
| 9 | Incoming message |
| 10 | Message sent |
| 11 | Connected |
| 12 | Disconnected |
| 13 | Connection lost |
| 14 | Error |
| 15 | Mic activated |
| 16 | Mic muted |
| 17 | Sound muted |
| 18 | Sound resumed |
| 19 | Away activated |
| 20 | Away deactivated |
| 21 | Channel created |
| 22 | Channel deleted |
| 23 | Channel edited |
| 24 | Channel moved |
| 25 | Channel group changed |
| 26 | User connected to your channel |
| 27 | User disconnected from the server |
| 28 | User connection lost (timeout) |
| 29 | User moved into your channel |
| 30 | User moved out of your channel |
| 31 | User kicked into your channel |
| 32 | User kicked out of your channel |
| 33 | User kicked from the server |
| 34 | User banned from the server |
| 35 | User started recording |
| 36 | User stopped recording |
| 37 | Recording active in channel |

## Project Structure

```
Nek0/
├── android/app/src/main/
│   ├── jniLibs/                    # Pre-built .so files (gitignored, built by pre_build.py)
│   ├── kotlin/.../MainActivity.kt  # Mic capture (AudioRecord), platform channels
│   ├── kotlin/.../KeepAliveService.kt      # Foreground service + MediaSession
│   ├── kotlin/.../NotificationActionReceiver.kt  # Notification button actions
│   ├── res/xml/filepaths.xml       # OTA update file provider paths
│   └── AndroidManifest.xml
├── lib/                            # Flutter
│   ├── models/                     # Data models + Riverpod state
│   ├── screens/                    # Home / server / settings screens
│   ├── services/                   # FFI bindings, audio, foreground service, OTA
│   └── widgets/                    # UI components (spotlight tour, voice panel, ...)
├── linux/                          # Flutter Linux runner (bundles native/prebuilt/linux/)
├── windows/                        # Flutter Windows runner (bundles native/prebuilt/windows/)
├── native/                         # Rust
│   ├── Cargo.toml                  # Patches tsclientlib/tsproto → local_tsclientlib/
│   ├── local_tsclientlib/          # Vendored tsclientlib/tsproto sources
│   ├── prebuilt/                   # Desktop artifacts (gitignored, built by pre_build.py)
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
