# TeamSpeak Android 客户端

一个基于 **Flutter**（UI）和 **Rust**（通过 [tsclientlib](https://github.com/ReSpeak/tsclientlib) 实现 TS3 协议）构建的 TeamSpeak 3 Android 客户端。

## 功能

- 连接任意 TeamSpeak 3 服务器
- 查看频道树（支持展开/折叠）
- 查看当前频道内的用户
- 收发文字消息（频道聊天）
- 切换频道
- 麦克风/扬声器静音切换
- **实时语音聊天** — 麦克风输入 + 音频播放（OpusVoice，48kHz 单声道）
- 服务器书签管理（本地存储）

## 架构

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
MainActivity.kt  ←EventChannel→  audio_service.dart  (通过 AudioRecord 采集麦克风)
```

- **Flutter** 负责界面、状态管理（Riverpod）、音频播放（`flutter_pcm_sound`）和事件轮询。
- **Rust** 通过 `tsclientlib` 处理 TS3 协议，使用 `opus-rs` 进行 Opus 编解码，对外暴露 C FFI 函数。
- **Kotlin** 通过 Android `AudioRecord`（48kHz，单声道，PCM_FLOAT）采集麦克风数据，并通过 EventChannel 传输。
- 通信方式：Flutter 每 200ms 轮询 Rust 获取事件。命令（发消息、切换频道、静音、断开连接、发送音频）通过通道队列发送，由 Rust 事件循环处理。

## 环境要求

| 工具 | 版本 | 说明 |
|------|------|------|
| Flutter | 3.x (Dart >=3.11) | [安装指南](https://docs.flutter.dev/get-started/install) |
| Rust | 1.70+ | [安装指南](https://rustup.rs/) |
| Android SDK | 最新版 | 通过 Android Studio 或独立安装 |
| Android NDK | 26+ | 通过 Android Studio SDK Manager 安装 |
| Rust Android 编译目标 | - | 见下方 |

## 环境配置

### 1. 安装 Rust Android 编译目标

```bash
rustup target add aarch64-linux-android x86_64-linux-android
```

### 2. 配置 Android NDK 链接器

创建（或编辑）`native/.cargo/config.toml` 文件，填入 NDK 工具链的路径。先确认你的 NDK 路径：

- **Windows**：`%LOCALAPPDATA%/Android/Sdk/ndk/<版本号>/` 或自定义路径
- **Linux**：`~/Android/Sdk/ndk/<版本号>/`
- **macOS**：`~/Library/Android/sdk/ndk/<版本号>/`

然后创建配置文件：

```toml
[target.aarch64-linux-android]
linker = "<ndk路径>/toolchains/llvm/prebuilt/<系统平台>/bin/aarch64-linux-android21-clang"
# Windows 上需加 .cmd 后缀

[target.x86_64-linux-android]
linker = "<ndk路径>/toolchains/llvm/prebuilt/<系统平台>/bin/x86_64-linux-android21-clang"
# Windows 上需加 .cmd 后缀
```

将 `<ndk路径>` 替换为你的实际 NDK 路径，`<系统平台>` 替换为：
- **Windows**：`windows-x86_64`
- **Linux**：`linux-x86_64`
- **macOS (Intel)**：`darwin-x86_64`
- **macOS (Apple Silicon)**：`darwin-aarch64`

示例（Windows）：
```toml
[target.aarch64-linux-android]
linker = "D:/software/android/SDK/ndk/29.0.13599879/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android21-clang.cmd"

[target.x86_64-linux-android]
linker = "D:/software/android/SDK/ndk/29.0.13599879/toolchains/llvm/prebuilt/windows-x86_64/bin/x86_64-linux-android21-clang.cmd"
```

### 3. 获取 Flutter 依赖

```bash
flutter pub get
```

## 构建与运行

### 第一步：构建 Rust 原生库

```bash
cd native

# 构建 ARM64（大多数 Android 设备）
cargo build --release --target aarch64-linux-android

# 构建 x86_64（Android 模拟器）
cargo build --release --target x86_64-linux-android
```

这会生成两个共享库文件：

- `native/target/aarch64-linux-android/release/libtsclient.so`
- `native/target/x86_64-linux-android/release/libtsclient.so`

### 第二步：复制 .so 文件到 jniLibs

```bash
# 在 native 目录下执行
cp target/aarch64-linux-android/release/libtsclient.so ../android/app/src/main/jniLibs/arm64-v8a/
cp target/x86_64-linux-android/release/libtsclient.so ../android/app/src/main/jniLibs/x86_64/
```

### 第三步：运行应用

```bash
flutter run
```

或构建 release APK：

```bash
flutter build apk --release
```

APK 输出路径：`build/app/outputs/flutter-apk/app-release.apk`

## 调试

### 查看日志

```bash
# 所有应用日志
adb logcat | grep flutter

# Rust 日志（eprintln! 输出）
adb logcat | grep RustStdouterr

# 音频相关日志
adb logcat | grep -E "ts_send_audio|opus encode|audio"
```

### 关键诊断日志

| 日志模式 | 含义 |
|----------|------|
| `ts_send_audio: N samp peak=X rms=Y` | 麦克风 PCM 数据到达 Rust 层 |
| `opus encode: N samp -> M bytes` | Opus 编码结果（语音数据包） |
| `audio: decoded N samp peak=X` | 从服务器接收到的语音解码 |
| `event_loop PANICKED: ...` | Rust 事件循环崩溃 |
| `PANIC celt.rs:1746` | Opus 编码器崩溃（麦克风帧大小不足） |
| `event_loop: started (gen=1)` | 事件循环启动成功 |

### 常见问题

| 问题 | 解决方案 |
|------|----------|
| `linker 'cc' not found` | 创建 `native/.cargo/config.toml` 并配置 NDK 链接器路径（见环境配置第 2 步） |
| 应用启动即崩溃 | 确保 `libtsclient.so` 同时存在于 `jniLibs/arm64-v8a/` 和 `jniLibs/x86_64/` |
| `event_loop PANICKED: index out of bounds` | 麦克风发送的采样数不足 960；确保 PCM 缓冲区已启用 |
| 听不到其他人的声音 | 确认 `flutter_pcm_sound` 已正确配置；检查解码器为单声道（1 通道） |
| 发出的声音有杂音 | 检查 Opus 编码器是否为单声道/Voip 模式；确认 PCM 缓冲正常工作 |
| cmake/audiopus 构建错误 | 确保 `Cargo.toml` 中 `tsclientlib` 设置了 `default-features = false` |
| 无法连接服务器 | 如果端口非默认，地址中需包含端口号（如 `ts.example.com:9987`） |
| 麦克风权限被拒绝 | 在 Android 设置中授权麦克风权限，或在首次提示时允许 |

## 权限

应用需要以下 Android 权限（在 `AndroidManifest.xml` 中声明）：

| 权限 | 用途 |
|------|------|
| `INTERNET` | 连接 TeamSpeak 服务器 |
| `RECORD_AUDIO` | 语音聊天的麦克风采集 |

麦克风权限在取消静音时动态申请。未授权时，应用以只听模式运行（可以听到他人，但无法发言）。

## 项目结构

```
teamspeak_apk/
├── android/                    # Android 工程
│   └── app/src/main/
│       ├── jniLibs/            # 预编译 .so 文件
│       │   ├── arm64-v8a/libtsclient.so
│       │   └── x86_64/libtsclient.so
│       ├── kotlin/.../
│       │   └── MainActivity.kt # 麦克风采集（AudioRecord + EventChannel）
│       └── AndroidManifest.xml # 权限与应用配置
├── lib/                        # Flutter (Dart)
│   ├── main.dart               # 应用入口
│   ├── models/
│   │   ├── channel.dart        # 频道模型
│   │   ├── client.dart         # 用户模型
│   │   ├── chat_message.dart   # 聊天消息模型
│   │   ├── server.dart         # 服务器书签模型
│   │   └── ts_state.dart       # Riverpod 状态管理 + 事件轮询
│   ├── screens/
│   │   ├── home_screen.dart    # 服务器列表 / 书签
│   │   └── server_screen.dart  # 已连接服务器视图
│   ├── services/
│   │   ├── audio_service.dart  # 音频播放 + 麦克风采集
│   │   └── ts_ffi.dart         # FFI 绑定（调用 Rust .so）
│   └── widgets/
│       ├── channel_tree.dart   # 频道树（展开/折叠）
│       ├── chat_panel.dart     # 聊天消息列表 + 输入框
│       ├── client_list.dart    # 频道内用户列表
│       ├── connection_bar.dart # 连接状态栏（静音/断开）
│       └── server_form_dialog.dart # 添加/编辑服务器对话框
├── native/                     # Rust 工程目录
│   ├── .cargo/
│   │   └── config.toml         # NDK 链接器配置
│   ├── Cargo.toml              # 依赖（tsclientlib、opus-rs、tokio 等）
│   ├── local_tsclientlib/      # 修补后的 tsclientlib（audio 功能始终可用）
│   └── src/
│       ├── lib.rs              # 类型定义、全局状态、命令队列
│       └── api.rs              # FFI 函数、事件循环、音频编解码
└── pubspec.yaml
```

## 许可证

本项目仅供学习交流使用。底层依赖 [tsclientlib](https://github.com/ReSpeak/tsclientlib) 有其独立许可证。
