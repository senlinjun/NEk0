<p align="center">
  <img src="resource/logo.png" alt="NEk0 logo" width="128" height="128">
</p>

<h1 align="center">NEk0</h1>
<p align="center">基于 Flutter &amp; Rust 构建的 TeamSpeak 3 客户端（Android / Windows / Linux）</p>

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
- **语音设置** — 设置页、长按麦克风按钮或点击用户列表中自己的名字可调
  VAD / PTT / 麦克风增益 / 阈值，带实时麦克风电平与麦克风测试
- **语音包** — 导入 zip 语音包一键替换全部频道提示音（格式见
  [语音包](#语音包)）
- **桌面端支持** — 同一套 Rust 核心可跑在 Windows 与 Linux 上；麦克风在原生库内用
  cpal 输入流采集，播放端自动协商设备格式并按回退链兜底
- **OTA 更新（Android）** — 启动时自动检查 GitHub/Gitee 的 release（版本号格式 `vx.y.z`），
  按设备 ABI 下载对应 APK 并安装；可在设置中关闭检查或切换更新源

## 架构

| 层 | 技术栈 |
|---|---|
| UI | Flutter (Dart) + Riverpod |
| 协议与编解码 | Rust ([tsclientlib](https://github.com/ReSpeak/tsclientlib), `opus-rs`) |
| 播放 | Rust（`cpal` — 持续输出流，空闲时输出静音） |
| 麦克风采集 | Android：Kotlin（`AudioRecord`）→ EventChannel → Dart → FFI → Rust<br>Windows/Linux：Rust（`cpal` 输入流）→ 编码发送管线 |
| 后台保活 | `KeepAliveService`（前台服务 + `MediaSession`，仅 Android） |

```
Flutter (Dart)                  Rust (Native .so)
─────────────                  ─────────────────
lib/services/ts_ffi.dart  ←FFI→  native/src/api.rs
lib/services/audio_service.dart  native/src/lib.rs
lib/models/ts_state.dart         (tsclientlib + opus-rs + tokio)

Kotlin（仅 Android）
───────────────────
MainActivity.kt         ←EventChannel→  audio_service.dart   (AudioRecord 采集麦克风)
KeepAliveService.kt     ←MethodChannel→ foreground_service.dart (前台服务、
                         MediaSession、通知栏按钮、MediaStore 保存)
```

## 环境要求

| 工具 | 版本 |
|------|------|
| Flutter | 3.x (Dart >=3.11) |
| Rust | 1.70+ |
| Android SDK | 最新版 |
| Android NDK | 26+ |
| Linux: alsa-lib / gtk3 / ninja / pkg-config | 最新版（桌面构建） |
| Windows: Visual Studio（C++ 桌面开发负载） | 最新版（桌面构建） |

## 构建与运行

### Android

一键方式 — 同时构建两种 ABI 并复制 `.so` 文件：

```bash
# 1. 安装 Rust Android 编译目标
rustup target add aarch64-linux-android x86_64-linux-android

# 2. 构建原生库（需将 ANDROID_NDK_HOME 指向已安装的 NDK）
python3 pre_build.py android

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

### Linux

```bash
sudo apt install libasound2-dev libgtk-3-dev ninja-build   # 构建依赖
python3 pre_build.py linux     # 在宿主机构建 Rust 核心，产物进 native/prebuilt/linux/
flutter build linux --release  # 产物：build/linux/x64/release/bundle/
./build/linux/x64/release/bundle/nek0
```

Linux 的 CMake 打包步骤会把 `native/prebuilt/linux/libtsclient.so` 安装到
`<bundle>/lib/`，运行时 `ts_ffi.dart` 从该路径加载。

### Windows

```powershell
python3 pre_build.py windows   # 构建 tsclient.dll 到 native/prebuilt/windows/（仅 Windows 宿主机）
flutter build windows --release
build\windows\x64\runner\Release\nek0.exe
```

CMake 构建会把 `tsclient.dll` 拷到 `nek0.exe` 旁，运行时 `ts_ffi.dart` 从该路径加载。

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

## 语音包

频道提示音支持通过导入语音包整体替换。语音包是一个 `.zip` 压缩包，内含
`pack.json` 清单和它引用的 WAV 音频文件：

```
my-pack.zip
├── pack.json
├── connected.wav
├── disconnected.wav
└── ...
```

`pack.json`：

```json
{
  "name": "我的语音包",
  "description": "显示在设置页里的简短介绍",
  "sounds": {
    "11": "connected.wav",
    "12": "disconnected.wav"
  }
}
```

- `sounds` 语音表把**事件 ID**（对照表见下）映射到压缩包内的 WAV 文件名。
  未覆盖的事件保留内置音效，所以语音包可以只做部分事件。
- WAV 要求：16 位 PCM 或 float32，单声道或双声道，单个文件最长 **2 秒**
  （其他采样率会自动重采样到 48 kHz）。
- 在 **设置 → 音频 → 频道提示音** 中导入语音包。重新导入同一个包（清单
  内容相同）会原地更新，不会产生重复条目。

### 事件 ID 对照表

| ID | 事件 |
|----|------|
| 1 | 自己切换频道 |
| 2 | 有人切换进入你的频道 |
| 3 | 有人切换离开你的频道 |
| 4 | 你被移动 |
| 5 | 你被踢出频道 |
| 6 | 你被踢出服务器 |
| 7 | 你被封禁 |
| 8 | 你被 Poke |
| 9 | 收到聊天消息 |
| 10 | 发送聊天消息 |
| 11 | 连接成功 |
| 12 | 已断开 |
| 13 | 连接丢失 |
| 14 | 错误 |
| 15 | 麦克风启用 |
| 16 | 麦克风静音 |
| 17 | 扬声器静音 |
| 18 | 扬声器恢复 |
| 19 | 离开状态开启 |
| 20 | 离开状态关闭 |
| 21 | 频道创建 |
| 22 | 频道删除 |
| 23 | 频道编辑 |
| 24 | 频道移动 |
| 25 | 频道组变更 |
| 26 | 有人连接到你的频道 |
| 27 | 有人断开连接 |
| 28 | 有人连接超时 |
| 29 | 有人被移入你的频道 |
| 30 | 有人被移出你的频道 |
| 31 | 有人被踢入你的频道 |
| 32 | 有人被踢出你的频道 |
| 33 | 有人被踢出服务器 |
| 34 | 有人被封禁 |
| 35 | 有人开始录音 |
| 36 | 有人停止录音 |
| 37 | 频道内有人正在录音 |

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
├── linux/                          # Flutter Linux runner（打包 native/prebuilt/linux/）
├── windows/                        # Flutter Windows runner（打包 native/prebuilt/windows/）
├── native/                         # Rust
│   ├── Cargo.toml                  # 将 tsclientlib/tsproto patch 到 local_tsclientlib/
│   ├── local_tsclientlib/          # 内置的 tsclientlib/tsproto 源码
│   ├── prebuilt/                   # 桌面端产物（gitignore，由 pre_build.py 构建）
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
