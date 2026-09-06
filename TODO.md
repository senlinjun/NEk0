# TODO

## 频道设置（未实现，按需取用）

- [ ] **语音编码 + 质量**（`codec` / `codec_quality`：Opus 语音 vs Opus 音乐，质量 1–10）— 音乐频道常用；协议字段在 `OutChannelEditPart`/`OutChannelCreatePart` 里现成可用，UI 加下拉 + 数字即可。
- [ ] **加密开关**（`channel_codec_is_unencrypted`）— 仅服务器允许客户端选择加密时有意义。
- [ ] **语音名称**（`channel_name_phonetic`）— TTS 朗读发音文本，极冷门。
- [ ] **服务器设置的更多字段** — 已实现：名称/最大用户数/密码（serveredit，`ServerEditArgs` + `ServerEditScreen`）。待加：欢迎消息、Host banner（图片/跳转 URL/显示模式）、防灌水、日志开关、默认分组等（`OutServerEditPart` 字段齐全，往 args/表单里扩即可）。
- [ ] **频道描述的完整展示** — book 只在收到 `notifychanneledited` 广播后才有描述（channellist 不携带、vendored 库不处理 `channelinfo` 响应），所以历史频道的描述显示为空。要补全需：发 `channelinfo cid` 并给 vendored `MessagesToBook.toml` 加 `ChannelInfoResponse → OptionalChannelData` 规则（注意该响应不回传 cid，需自己关联）。
- [x] ~~编码延迟因子~~（Speex 遗留字段，Opus 下无意义，永远跳过）

## 已实现（2026-09）

名称 / 主题 / 密码 / 类型 / 最大用户数 / 描述 / 说话所需权限 / 排序（菜单上移下移）/ 默认频道标记 / 删除延迟 / 子频道用户上限 / 新建 / 删除 / **移动父频道（长按拖动）** / **移动用户至频道（长按用户拖到频道行，权限门与面板一致；拖自己 = 加入该频道，走点击加入流程）** / **服务器设置（serveredit：名称/最大用户数/密码；服务器根节点点击/长按打开，无权限只读）**。

### 拖动已知边界（频道拖动与用户拖动同）

- 长按拖动期间列表不滚动（长按已赢得手势仲裁）；长列表需先滚到位再拖。
- 频道拖动：拖到某频道行中间 = 变为其子频道（追加末尾）；行上下边缘 = 插到该位置；同层微调也可用菜单里的上移/下移。
- 用户拖动：拖到目标频道行任意位置 = 移动该用户进去（无插入线，整行高亮）；拖到服务器根节点无效；拖自己的行 = 加入该频道（无加入权限的频道不高亮，与点击一致）；长按不动 = 打开该用户操作面板。
