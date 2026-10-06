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
flutter build linux --release            # Linux (needs alsa-lib, gtk3, libnotify, ninja, pkg-config)
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
- The protocol/session engine is **univox** (`univox-core` + `univox-ts3` +
  `univox-ts3-proto`, git deps pinned by rev in `native/Cargo.toml`). `univox-ts3` MUST
  stay on `default-features = false`: its default `voice` feature pulls `audiopus`, and
  a second static libopus cannot link into the cdylib next to `opus-rs` (and
  `audiopus_sys` wants cmake on Android). Nek0 bypasses univox's PCM voice pipeline and
  uses the raw packet API instead — receive via `UdpConnection::voice_sink_handle()`
  (broadcast of `VoiceData::S2C{,Whisper}` = speaker clid + voice seq + raw Opus, fed
  straight into `decode_to_client_buffer`), send via `conn.send_voice([codec byte] ++
  opus)` from the mic pipeline (`PacketType::Voice`; the univox actor owns the C2S seq).
- Connection lifecycle lives in `native/src/api.rs`: `do_connect` parses the address
  (invite links/TSDNS via `univox_ts3::address`), converts Dart's stored identity JSON
  (`{key, counter, max_counter}` — tsclientlib/tsproto shape, kept for storage
  compatibility) via `Identity::from_tsclientlib_json`, connects with
  `Ts3ConnectOptions { server_password, privilege_key, upgrade_identity_to: 24 }`, then
  writes the possibly-upgraded identity back with `to_tsclientlib_json()`. One tokio
  task per connection generation drains `session.events()` (unified events:
  Member*/Channel*/MessageCreated/Closed ...), the raw voice broadcast, and the
  `COMMAND_TX` command queue via `tokio::select!`. `RecentClients` (2 s windows)
  dedupes the up-to-three events one channel transition produces (clientmoved +
  leftview + enterview). Permission hint bits in the roster JSON are computed
  best-effort from our own `clientpermlist` (univox does not model hints). Group
  lists and own perms are fetched with plain execs at connect and on
  `Command::RefreshGroups`/`OwnPermList`; file transfer runs on univox's streaming
  `FileDownload`/`FileUpload` handles (password-aware `ftgetfilelist`/`ftdeletefile`
  are exec'd by hand — univox's `list_files`/`delete_file` send no `cpw`).
  `session.identity()` is the post-connect identity; persist it after every connect.
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
  Both paths converge on the mic pipeline (`native/src/mic_pipeline.rs`, global
  `MIC_PIPELINE` on its OWN mutex — never take `STATE.lock()` for it): per 20 ms frame
  RNNoise speech probability (via pure-Rust `nnnoiseless`; two 10 ms sub-frames, max;
  first frame after reset is a bypass warm-up; the model is 16-bit-PCM domain on BOTH
  ends — input scaled ×32768 in, denoised output ÷32768 back to ±1, a missing divide
  once made denoise sound like full-scale electrical buzz) → optional RNNoise denoise →
  speech-gated
  AGC (`native/src/agc.rs`, gain frozen in silence, persisted per input device in
  `AGC_MEMORY`) → mic gain + whole-frame peak limiter (0.99, no per-sample clipping) →
  VAD gate (`native/src/vad.rs`) → Opus encode. While NOT connected the frames still
  feed the pipeline's analysis stage (level meter / noise floor / probability for the
  settings mic test and calibration), but are never encoded or sent. The settings
  panel (`VoiceSettingsPanel`) polls `ts_get_vad_status` itself on a 200ms timer while
  no connection exists — the notifier's poll timer only runs between connect and
  disconnect, so without the panel-local poll the mic test meter would stay dead.
- Linux device lists (`ts_get_audio_devices`) come from the stable ALSA name hints
  (`snd_device_name_hint` via a Linux-only `alsa` crate dep), NOT from cpal's
  enumeration: cpal probe-opens every PCM and silently drops the ones the sound
  server holds at that moment, so the list would grow/shrink with PipeWire/WirePlumber
  activity. The Rust side filters converter/junk PCMs (`null`, rate converters,
  `jack`/`oss`, `usbstream:`), hides alias duplicates (`front:`/`surround*:`;
  `sysdefault:CARD=x` when `default:CARD=x` exists; `hdmi:`/`iec958:` input-side) and
  sets `label` from the hint description ("HyperX Cloud III USB") — `name` stays the
  ALSA PCM selection/persistence key, Dart displays `label`. Openability is enforced
  when the device is opened: a chosen-but-busy device falls back to the sound-server
  PCM / default on both the input (error recorded) and output (one retry) paths; with
  no stored choice `pick_device` prefers the sound-server PCMs (`pipewire`, `pulse`)
  because bare ALSA `default` bypasses PipeWire when `pipewire-alsa` is not installed.
- The VAD is TeamSpeak-style: three modes (`auto` = ML probability only, `gate` = dB
  volume only, `hybrid` = both, default), dB activation level (default −46 dBFS ≈ the
  old linear 0.005), two-threshold hysteresis, an onset confirmation run that does NOT
  evict the preroll ring (confirmation costs decision latency only), preroll flush on
  open and a `hold_ms` tail (default 200). Defaults are TS3-aligned
  (`vad_extrabuffersize` = 2, per-frame decision): `preroll_frames` 0–8 default 2,
  `onset_frames` 1–5 default 1 — so a talkspurt onset is shifted by
  (preroll + onset − 1) × 20 ms ≈ 40 ms (steady-state latency is unaffected) and the
  softest onset may lose up to 20 ms when RNNoise ramps slowly, exactly the trade TS3
  makes. Fast adds no onset delay; robust (preroll 5, onset 3, ≈140 ms) covers the
  worst measured RNNoise ramp loss-free (`rnnoise_onset_latency_fits_preset_prerolls`
  test). Silence frames are dropped WITHOUT consuming sequence numbers.
  The recording tap back-fills slots across a preroll burst (`slot − (n−1−i)`), skipped
  when the back-fill would underflow. Dart owns the settings (`lib/models/vad_settings.dart`,
  persisted under `vad_*` SharedPreferences keys) and pushes the full config JSON via
  `ts_set_vad_config`; `ts_get_vad_status` returns the per-frame snapshot (level, noise
  floor, probability, AGC gain) consumed by the poll loop into `state.vadStatus` and
  rendered by `VoiceSettingsPanel` (mode segments, dB meter with noise/gate ticks,
  calibration flow, AGC/denoise toggles, response-speed preset). Legacy scalar FFI
  (`ts_set_vad_enabled`, `ts_set_vad_threshold`, `ts_set_mic_gain`) stays as a
  compatibility shim. The `[vad]` line in the 5 s maintenance log reports mode, level,
  noise, probability and gain; the old `vad_*`/`pcm_in`/encoder fields are gone from
  `STATE` (`voice_active` is the `VOICE_ACTIVE` atomic, read-and-clear via
  `ts_is_voice_active`).
- Platform gating: `ForegroundService` (foreground service, notification actions, battery
  exemption, MediaStore saves) is Android-only and degrades to no-ops elsewhere — except
  `saveToDownloads`, which on desktop writes into the system Downloads directory
  (`getDownloadsDirectory`), and `notify`, which on desktop shows a system toast via
  `local_notifier` (Windows WinRT / Linux libnotify; `main()` runs
  `localNotifier.setup`). System notifications are gated per event kind by
  `notificationSettingsProvider` (pokes and private messages on by default;
  channel/server messages, channel enter/leave and moves off) and chat
  messages never toast while the chat panel is open (`chatOpen`); chat-log
  system messages and the poke in-app dialog always happen. OTA (`OtaService`)
  is Android-only (`OtaService.isSupported`); settings/home screens hide it. On desktop,
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
  (sequence unwrap, positional gains, OutRing, compression_eps, the mic resampler),
  `vad.rs` (three-mode gate semantics, hysteresis/tail, the zero-loss preroll invariant,
  the measured RNNoise onset latency, noise floor, config clamps), `agc.rs` (closed-loop
  convergence, silence freeze, limiter shapes) and `mic_pipeline.rs` (patch contract,
  gated end-to-end, AGC memory) plus `recording.rs` (filenames, f32_to_i16, WavWriter) —
  run `cargo test --lib` in `native/`
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
