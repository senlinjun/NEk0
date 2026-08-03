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
- **一键全静音** — 耳机按钮（或媒体卡片播放/暂停）一键静音输入+输出并停止麦克风
- **后台保活** — 像音乐播放器一样在后台保持在线，依托前台服务 + 媒体会话，
  通知栏提供静音/断开按钮
- **独立音量控制** — 本地调节每位用户的音量，基于身份跨会话记忆
- **频道聊天** — 在频道内收发文字消息
- **服务器书签** — 本地保存和管理服务器地址
- **初次使用引导** — 在真实界面上聚光高亮讲解主要功能（可通过帮助图标随时重看）
- **语音设置** — 设置页或长按麦克风按钮可调 VAD / PTT / 麦克风增益 / 阈值，
  带实时麦克风电平与麦克风测试
- **OTA 更新** — 启动时自动检查 GitHub/Gitee 的 release（版本号格式 `vx.y.z`），
  按设备 ABI 下载对应 APK 并安装；可在设置中关闭检查或切换更新源

## 架构

| 层 | 技术栈 |
|---|---|
| UI | Flutter (Dart) + Riverpod |
| 协议与编解码 | Rust ([tsclientlib](https://github.com/ReSpeak/tsclientlib), `opus-rs`) |
| 播放 | Rust（`cpal` — 持续输出流，空闲时输出静音） |
| 麦克风采集 | Kotlin（`AudioRecord`）→ EventChannel → Dart → FFI → Rust |
| 后台保活 | `KeepAliveService`（前台服务 + `MediaSession`） |

```
Flutter (Dart)                  Rust (Native .so)
─────────────                  ─────────────────
lib/services/ts_ffi.dart  ←FFI→  native/src/api.rs
lib/services/audio_service.dart  native/src/lib.rs
lib/models/ts_state.dart         (tsclientlib + opus-rs + tokio)

Kotlin (Android)
────────────────
MainActivity.kt         ←EventChannel→  audio_service.dart   (AudioRecord 采集麦克风)
KeepAliveService.kt     ←MethodChannel→ foreground_service.dart (前台服务
                         + MediaSession + 通知栏按钮)
```

## 环境要求

| 工具 | 版本 |
|------|------|
| Flutter | 3.x (Dart >=3.11) |
| Rust | 1.70+ |
| Android SDK | 最新版 |
| Android NDK | 26+ |

## 构建与运行

一键方式 — 同时构建两种 ABI 并复制 `.so` 文件：

```bash
# 1. 安装 Rust Android 编译目标
rustup target add aarch64-linux-android x86_64-linux-android

# 2. 构建原生库（需将 ANDROID_NDK_HOME 指向已安装的 NDK）
python3 pre_build.py

# 3. 运行
flutter run
```

手动方式（同样的结果，分步执行）：

```bash
cd native
cargo build --release --target aarch64-linux-android
cargo build --release --target x86_64-linux-android
cp target/aarch64-linux-android/release/libtsclient.so ../android/app/src/main/jniLibs/arm64-v8a/
cp target/x86_64-linux-android/release/libtsclient.so ../android/app/src/main/jniLibs/x86_64/
```

`libtsclient.so` 已被 gitignore —— 必须先构建并复制后应用才能运行。

## 调试

```bash
adb logcat | grep flutter          # Flutter 日志
adb logcat | grep RustStdouterr    # Rust 日志
adb logcat | grep -E "cpal|opus"   # 音频日志
adb shell dumpsys media_session    # 媒体会话状态（后台保活）
adb shell dumpsys activity services com.senlinjun.nek0  # 前台服务状态
```

## 权限

| 权限 | 用途 |
|------|------|
| `INTERNET` | 连接 TeamSpeak 服务器 |
| `RECORD_AUDIO` | 麦克风采集（运行时申请） |
| `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MEDIA_PLAYBACK` / `FOREGROUND_SERVICE_MICROPHONE` | 后台保活服务 |
| `POST_NOTIFICATIONS` | 服务通知（Android 13+） |
| `WAKE_LOCK` | 连接期间保持 CPU 唤醒以处理音频 |
| `REQUEST_INSTALL_PACKAGES` | OTA 更新安装 APK |
| `WRITE_EXTERNAL_STORAGE` | OTA 下载（API <= 28） |

## 项目结构

```
Nek0/
├── android/app/src/main/
│   ├── jniLibs/                    # 预编译 .so（gitignore，由 pre_build.py 构建）
│   ├── kotlin/.../MainActivity.kt  # 麦克风采集 (AudioRecord)、平台通道
│   ├── kotlin/.../KeepAliveService.kt      # 前台服务 + MediaSession
│   ├── kotlin/.../NotificationActionReceiver.kt  # 通知栏按钮动作
│   ├── res/xml/filepaths.xml       # OTA 更新的 FileProvider 路径
│   └── AndroidManifest.xml
├── lib/                            # Flutter
│   ├── models/                     # 数据模型 + Riverpod 状态
│   ├── screens/                    # 首页 / 服务器 / 设置页
│   ├── services/                   # FFI 绑定、音频、前台服务、OTA
│   └── widgets/                    # UI 组件（聚光引导、语音面板等）
├── native/                         # Rust
│   ├── Cargo.toml                  # 将 tsclientlib/tsproto patch 到 local_tsclientlib/
│   ├── local_tsclientlib/          # 内置的 tsclientlib/tsproto 源码
│   └── src/
│       ├── lib.rs                  # 状态、类型、命令队列
│       └── api.rs                  # FFI 函数、事件循环、音频编解码
├── resource/
│   └── logo.png
├── AGENTS.md                       # 面向 AI 代理的架构与构建指南
├── README.md
├── README_ZH.md
├── CONTRIBUTING.md
└── pubspec.yaml
```

## 参与贡献

参见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

仅供学习交流使用。[tsclientlib](https://github.com/ReSpeak/tsclientlib) 有其独立许可证。
