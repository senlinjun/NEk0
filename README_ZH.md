<p align="center">
  <img src="resource/logo.png" alt="NEk0 logo" width="128" height="128">
</p>

<h1 align="center">NEk0</h1>
<p align="center">基于 Flutter &amp; Rust 构建的 TeamSpeak 3 Android 客户端</p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="https://github.com/ReSpeak/tsclientlib">tsclientlib</a>
</p>

---

## 功能

- **语音通话** — 实时 OpusVoice（48kHz 单声道），支持 VAD 和 PTT
- **独立音量控制** — 本地调节每位用户的音量，基于身份跨会话记忆
- **频道聊天** — 在频道内收发文字消息
- **服务器书签** — 本地保存和管理服务器地址

## 架构

| 层 | 技术栈 |
|---|---|
| UI | Flutter (Dart) + Riverpod |
| 音频 I/O | Rust (`opus-rs`) + Kotlin (`AudioRecord`) |
| 协议 | Rust ([tsclientlib](https://github.com/ReSpeak/tsclientlib)) |
| 播放 | `flutter_pcm_sound` → Android `AudioTrack` |

```
Flutter (Dart)                  Rust (Native .so)
─────────────                  ─────────────────
lib/services/ts_ffi.dart  ←FFI→  native/src/api.rs
lib/services/audio_service.dart  native/src/lib.rs
lib/models/ts_state.dart         (tsclientlib + opus-rs + tokio)

Kotlin (Android)
────────────────
MainActivity.kt  ←EventChannel→  audio_service.dart  (AudioRecord 采集麦克风)
```

## 环境要求

| 工具 | 版本 |
|------|------|
| Flutter | 3.x (Dart >=3.11) |
| Rust | 1.70+ |
| Android SDK | 最新版 |
| Android NDK | 26+ |

## 构建与运行

```bash
# 1. 安装 Rust Android 编译目标
rustup target add aarch64-linux-android x86_64-linux-android

# 2. 配置 NDK 链接器（编辑 native/.cargo/config.toml，见下方）

# 3. 构建原生库
cd native
cargo build --release --target aarch64-linux-android
cargo build --release --target x86_64-linux-android

# 4. 复制 .so 文件
cp target/aarch64-linux-android/release/libtsclient.so ../android/app/src/main/jniLibs/arm64-v8a/
cp target/x86_64-linux-android/release/libtsclient.so ../android/app/src/main/jniLibs/x86_64/

# 5. 运行
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

## 调试

```bash
adb logcat | grep flutter          # Flutter 日志
adb logcat | grep RustStdouterr    # Rust 日志
adb logcat | grep -E "opus|audio"  # 音频日志
```

## 权限

| 权限 | 用途 |
|------|------|
| `INTERNET` | 连接 TeamSpeak 服务器 |
| `RECORD_AUDIO` | 麦克风采集（运行时申请） |

## 项目结构

```
teamspeak_apk/
├── android/app/src/main/
│   ├── jniLibs/                    # 预编译 .so 文件
│   ├── kotlin/.../MainActivity.kt  # 麦克风采集 (AudioRecord)
│   └── AndroidManifest.xml
├── lib/                            # Flutter
│   ├── models/                     # 数据模型
│   ├── screens/                    # 页面
│   ├── services/                   # FFI 绑定 + 音频服务
│   └── widgets/                    # UI 组件
├── native/                         # Rust
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs                  # 状态、类型、命令队列
│       └── api.rs                  # FFI 函数、事件循环、音频编解码
├── resource/
│   └── logo.png
├── README.md
├── README_ZH.md
└── pubspec.yaml
```

## 许可证

仅供学习交流使用。[tsclientlib](https://github.com/ReSpeak/tsclientlib) 有其独立许可证。
