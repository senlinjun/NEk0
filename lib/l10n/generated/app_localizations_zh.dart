// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get cancel => '取消';

  @override
  String get save => '保存';

  @override
  String get delete => '删除';

  @override
  String get edit => '编辑';

  @override
  String get later => '稍后';

  @override
  String get update => '更新';

  @override
  String get skip => '跳过';

  @override
  String get next => '下一步';

  @override
  String get done => '完成';

  @override
  String get gotIt => '知道了';

  @override
  String get guide => '引导';

  @override
  String get settings => '设置';

  @override
  String get addServer => '添加服务器';

  @override
  String get noServersAdded => '还没有服务器';

  @override
  String get deleteServerTitle => '删除服务器？';

  @override
  String deleteServerBody(String name) {
    return '从书签中移除\"$name\"？';
  }

  @override
  String get guideAddTitle => '添加你的服务器';

  @override
  String get guideAddDesc => '点击 + 添加 TeamSpeak 服务器，然后点击它即可连接并开始语音。';

  @override
  String get channels => '频道';

  @override
  String get chat => '聊天';

  @override
  String get guideMicTitle => '麦克风';

  @override
  String get guideMicDesc => '点击静音麦克风。长按打开语音设置（VAD、PTT、麦克风增益）。';

  @override
  String get guideRecordTitle => '录音';

  @override
  String get guideRecordDesc => '点击打开录音菜单：可随时保存最近的回溯，也可开始录音（可选包含回溯）。每位用户独立音轨。';

  @override
  String get guideSpeakerTitle => '扬声器';

  @override
  String get guideSpeakerDesc => '静音所有人的音频（输出）。';

  @override
  String get guideChatTitle => '聊天';

  @override
  String get guideChatDesc => '点击聊天栏向当前频道发送消息。';

  @override
  String get guideChannelsTitle => '频道';

  @override
  String get guideChannelsDesc => '点击频道加入；长按打开频道菜单（加入、文件管理）。';

  @override
  String get guideMembersTitle => '成员';

  @override
  String get guideMembersDesc => '成员直接列在所属频道下方，其他频道的成员也能看到。';

  @override
  String get guideMemberActionsTitle => '成员操作';

  @override
  String get guideMemberActionsDesc => '点击他人可调节音量、发送 Poke 或踢出；点击自己的名字打开语音设置。';

  @override
  String get keepAliveTitle => '后台保活';

  @override
  String get keepAliveBody =>
      '为了像音乐播放器一样在后台保持在线，请在系统设置中允许 NEk0 后台运行：\n• 电池 → 忽略电池优化（我们会打开它）\n• 自启动：允许 NEk0 自启动\n• 后台耗电管理：允许后台运行';

  @override
  String get talking => '正在说话';

  @override
  String get volume => '音量';

  @override
  String get settingsTitle => '设置';

  @override
  String get voice => '语音';

  @override
  String get micTest => '麦克风测试';

  @override
  String get startMicTest => '开始测试';

  @override
  String get stopMicTest => '停止测试';

  @override
  String get micInUseWhileConnected => '连接期间麦克风正在使用——测试已禁用。';

  @override
  String get micPermissionDenied => '麦克风权限被拒绝';

  @override
  String get micPrivacyHint =>
      'Windows 拦截了麦克风访问。请打开 设置 → 隐私和安全性 → 麦克风，允许桌面应用访问麦克风（并检查是否有其他应用占用麦克风）。';

  @override
  String get audioDevicesSection => '音频设备';

  @override
  String get audioOutputDevice => '输出设备';

  @override
  String get audioInputDevice => '输入设备';

  @override
  String get audioSystemDefault => '系统默认';

  @override
  String get updateSection => '更新';

  @override
  String get checkForUpdates => '检查更新';

  @override
  String get updateSource => '更新源';

  @override
  String get updateSourceAuto => '自动';

  @override
  String get checkNow => '立即检查';

  @override
  String get checkingForUpdates => '正在检查更新…';

  @override
  String get noUpdateAvailable => '暂无可用更新';

  @override
  String get language => '语言';

  @override
  String get languageSystem => '跟随系统';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageChinese => '中文';

  @override
  String get voiceSettings => '语音设置';

  @override
  String get pttMode => 'PTT 模式';

  @override
  String get voiceActivation => '语音激活';

  @override
  String get level => '电平';

  @override
  String get micGain => '麦克风增益';

  @override
  String get channelSounds => '频道提示音';

  @override
  String get sfxDefault => '默认';

  @override
  String get sfxPackNone => '内置音效';

  @override
  String get sfxPackNoneDesc => '未启用语音包';

  @override
  String get sfxPackActive => '使用中';

  @override
  String get sfxPackImport => '导入语音包（.zip）';

  @override
  String sfxPackImported(String name) {
    return '语音包“$name”已启用。';
  }

  @override
  String get sfxPackActivate => '启用此语音包';

  @override
  String get sfxPackDeactivate => '停用此语音包';

  @override
  String get sfxPackDelete => '删除语音包';

  @override
  String sfxPackDeleteBody(String name) {
    return '删除语音包“$name”吗？';
  }

  @override
  String get sfxPackInvalidZip => '不是有效的语音包：缺少 pack.json 或文件不是 zip 压缩包。';

  @override
  String get sfxPackInvalidManifest =>
      'pack.json 无效：需要 name 字段，以及把事件 ID（1–37）映射到压缩包内 WAV 文件的 sounds 表。';

  @override
  String get sfxPackPartialLoad => '语音包中部分音频被跳过（格式不支持）。';

  @override
  String get poke => 'Poke';

  @override
  String get pokeHint => '输入要发送的提示消息';

  @override
  String get pokeSent => 'Poke 已发送';

  @override
  String get pokeNotificationTitle => '你被戳了一下';

  @override
  String pokeNotificationBody(String name, String message) {
    return '$name 戳了你: $message';
  }

  @override
  String get pokeDialogTitle => '你被戳了一下';

  @override
  String get pokeBack => '回戳';

  @override
  String get notificationsSection => '通知';

  @override
  String get notifyPoke => '被戳';

  @override
  String get notifyPokeDesc => '有人戳你时发送系统通知';

  @override
  String get notifyPmMessages => '私聊消息';

  @override
  String get notifyPmMessagesDesc => '收到私聊消息时发送系统通知（聊天面板打开时不弹）';

  @override
  String get notifyChannelMessages => '频道/服务器消息';

  @override
  String get notifyChannelMessagesDesc => '收到频道或服务器消息时发送系统通知（聊天面板打开时不弹）';

  @override
  String get notifyChannelEvents => '进出频道';

  @override
  String get notifyChannelEventsDesc => '有人进入或离开你所在频道时发送系统通知';

  @override
  String get notifyChannelMoves => '频道切换';

  @override
  String get notifyChannelMovesDesc => '你切换频道或被移动/移出频道时发送系统通知';

  @override
  String userEnteredChannel(String name) {
    return '$name 进入了频道';
  }

  @override
  String userLeftChannel(String name) {
    return '$name 离开了频道';
  }

  @override
  String userKickedFromChannelBy(String name, String invoker) {
    return '$name 被 $invoker 移出了频道';
  }

  @override
  String userKickedFromServerBy(String name, String invoker) {
    return '$name 被 $invoker 踢出了服务器';
  }

  @override
  String userKickedFromServer(String name) {
    return '$name 被踢出了服务器';
  }

  @override
  String userBannedBy(String name, String invoker) {
    return '$name 被 $invoker 封禁了';
  }

  @override
  String userBanned(String name) {
    return '$name 被封禁了';
  }

  @override
  String youMovedToChannel(String channel) {
    return '你切换到了频道 $channel';
  }

  @override
  String youWereMovedBy(String invoker, String channel) {
    return '$invoker 将你移动到了频道 $channel';
  }

  @override
  String youWereKickedFromChannelBy(String invoker) {
    return '你被 $invoker 移出了频道';
  }

  @override
  String get send => '发送';

  @override
  String get awayEnable => '标记离开';

  @override
  String get awayDisable => '恢复在线';

  @override
  String get disconnected => '未连接';

  @override
  String get disconnect => '断开连接';

  @override
  String get noMessagesYet => '暂无消息';

  @override
  String get sendMessageHint => '发送消息...';

  @override
  String get chatChannel => '频道';

  @override
  String get chatServer => '服务器';

  @override
  String get sendMessageAction => '发送消息';

  @override
  String messageSendFailed(String error) {
    return '消息发送失败：$error';
  }

  @override
  String get addServerTitle => '添加服务器';

  @override
  String get editServerTitle => '编辑服务器';

  @override
  String get serverName => '服务器名称';

  @override
  String get addressHint => '地址（例如 ts.example.com）';

  @override
  String get nickname => '昵称';

  @override
  String get channelOptional => '频道（可选）';

  @override
  String get passwordOptional => '密码（可选）';

  @override
  String get tokenOptional => '管理员 Token（可选）';

  @override
  String get privilegeKeyTitle => '使用管理员 Token';

  @override
  String get privilegeKeyBody => '该服务器要求提供管理员 Token（权限密钥）。输入后你将被加入对应的服务器组。';

  @override
  String get privilegeKeyHint => 'Token';

  @override
  String get privilegeKeyGranted => 'Token 兑换成功，服务器组已更新。';

  @override
  String get privilegeKeyNoEffect => 'Token 已提交，但未检测到服务器组变化，可能无效或已被使用。';

  @override
  String get teamSpeakUserDefault => 'TeamSpeakUser';

  @override
  String get ports => '端口';

  @override
  String get portsHint =>
      '留空使用默认值（语音 9987、ServerQuery 10011、文件传输 30033、SSH 10022）。';

  @override
  String get voicePort => '语音端口';

  @override
  String get serverQueryPort => 'ServerQuery 端口';

  @override
  String get fileTransferPort => '文件传输端口';

  @override
  String get serverQuerySshPort => 'ServerQuery SSH 端口';

  @override
  String get invalidPort => '端口必须是 1 到 65535 之间的数字。';

  @override
  String get updateAvailable => '发现新版本';

  @override
  String updateAvailableBody(String version) {
    return 'NEk0 $version 已发布。\n\n立即下载并安装？';
  }

  @override
  String get updatingNek0 => '正在更新 NEk0';

  @override
  String downloading(String percent) {
    return '正在下载… $percent%';
  }

  @override
  String get installing => '正在安装…';

  @override
  String updateFailed(String detail) {
    return '更新失败：$detail';
  }

  @override
  String get notifMute => '静音';

  @override
  String get notifUnmute => '取消静音';

  @override
  String get notifDisconnect => '断开连接';

  @override
  String get notifConnected => '已连接';

  @override
  String get noChannels => '暂无频道';

  @override
  String get ok => '确定';

  @override
  String get channelPasswordTitle => '输入频道密码';

  @override
  String get channelPasswordHint => '密码';

  @override
  String get channelPasswordWrong => '频道密码错误';

  @override
  String get menuEnterChannel => '进入频道';

  @override
  String get menuFileManager => '文件管理';

  @override
  String get menuServerTitle => '服务器';

  @override
  String get menuEditServer => '编辑服务器';

  @override
  String get serverSettingsTitle => '服务器设置';

  @override
  String get serverMaxClientsLabel => '最大用户数';

  @override
  String get serverPasswordLabel => '服务器密码';

  @override
  String get serverPasswordHelper => '留空保持当前密码不变';

  @override
  String get serverPasswordRemove => '移除服务器密码';

  @override
  String get serverSaved => '服务器已更新';

  @override
  String get serverReadOnlyHint => '你没有修改服务器设置的权限';

  @override
  String get menuCreateChannel => '新建频道';

  @override
  String get menuEditChannel => '编辑频道';

  @override
  String get menuDeleteChannel => '删除频道';

  @override
  String get channelCreateTitle => '新建频道';

  @override
  String get channelEditTitle => '编辑频道';

  @override
  String get channelNameLabel => '频道名称';

  @override
  String get channelTopicLabel => '主题（可选）';

  @override
  String get channelPasswordHelper => '留空清除现有密码';

  @override
  String get channelMaxClientsLabel => '最大用户数';

  @override
  String get channelMaxClientsHelper => '留空为无限';

  @override
  String get channelTypeLabel => '类型';

  @override
  String get channelTypeTemporary => '临时';

  @override
  String get channelTypeSemiPermanent => '半永久';

  @override
  String get channelTypePermanent => '永久';

  @override
  String get deleteChannelTitle => '删除频道？';

  @override
  String deleteChannelBody(String name) {
    return '删除“$name”？';
  }

  @override
  String deleteChannelOccupied(int count) {
    return '频道内有 $count 名用户，将被移至默认频道。';
  }

  @override
  String get channelCreated => '频道已创建';

  @override
  String get channelSaved => '频道已更新';

  @override
  String get channelDeleted => '频道已删除';

  @override
  String get channelMoved => '频道已移动';

  @override
  String get menuMoveUp => '上移';

  @override
  String get menuMoveDown => '下移';

  @override
  String get channelDescriptionLabel => '频道描述';

  @override
  String get channelNeededTalkPowerLabel => '说话所需权限';

  @override
  String get channelTalkPowerHelper => '0 = 不限制说话';

  @override
  String get channelDeleteDelayLabel => '删除延迟（秒）';

  @override
  String get channelDeleteDelayHelper => '频道空置多少秒后删除';

  @override
  String get channelMaxFamilyLabel => '频道组人数上限';

  @override
  String get channelMaxFamilyInherit => '继承父频道';

  @override
  String get channelMaxFamilyUnlimited => '不限制';

  @override
  String get channelMaxFamilyLimited => '自定义限制';

  @override
  String get channelIsDefaultLabel => '设为默认频道';

  @override
  String get audio => '音频';

  @override
  String get fmUp => '上一级';

  @override
  String get fmRootShort => '/';

  @override
  String get fmSearch => '搜索文件';

  @override
  String get fmSearchHint => '在此目录树中搜索…';

  @override
  String get fmNoResults => '没有匹配的结果';

  @override
  String get fmUploadFile => '上传文件';

  @override
  String get fmUploadFolder => '上传文件夹';

  @override
  String get fmUploadDone => '上传完成';

  @override
  String get fmNewFolder => '新建文件夹';

  @override
  String get fmNewFolderName => '文件夹名称';

  @override
  String get fmInvalidName => '文件夹名称无效';

  @override
  String get fmFolderCreated => '文件夹已创建';

  @override
  String get fmDownload => '下载';

  @override
  String get fmDelete => '删除';

  @override
  String fmConfirmDeleteFile(String name) {
    return '确定删除文件 \"$name\" 吗？';
  }

  @override
  String fmConfirmDeleteFolder(String name) {
    return '确定删除文件夹 \"$name\" 及其全部内容吗？';
  }

  @override
  String get fmDeleted => '已删除';

  @override
  String get fmSavedToDownloads => '已保存到系统下载';

  @override
  String get fmNotConnected => '连接到服务器后才能管理文件。';

  @override
  String get fmEmpty => '空文件夹';

  @override
  String get fmRefresh => '刷新';

  @override
  String get fmCancelTransfer => '取消传输';

  @override
  String get fmTransfersTitle => '传输任务';

  @override
  String get fmStateDone => '已完成';

  @override
  String get fmStateError => '失败';

  @override
  String get fmStateCanceled => '已取消';

  @override
  String get fmOperationFailed => '操作失败';

  @override
  String get fmClearHistory => '清除已完成';

  @override
  String get fmPermDenied => '服务器未授予文件传输权限';

  @override
  String get fmCanceled => '传输已取消';

  @override
  String fmReasonPrefix(String reason) {
    return '操作失败：$reason';
  }

  @override
  String get channelsNoJoinPermission => '你没有权限加入此频道';

  @override
  String channelTalkPowerNeeded(int power) {
    return '需要发言权限：$power';
  }

  @override
  String get serverQuery => '服务器查询客户端';

  @override
  String get serverQueryAdmin => '拥有管理员权限的服务器查询端';

  @override
  String get channelCommander => '频道指挥官';

  @override
  String get prioritySpeaker => '优先发言者';

  @override
  String get recording => '正在录音';

  @override
  String get talkPowerDenied => '在此频道没有发言权限';

  @override
  String serverGroups(String groups) {
    return '组：$groups';
  }

  @override
  String get menuMoveToChannel => '移动到频道';

  @override
  String get menuKickFromChannel => '移出频道';

  @override
  String get menuKickFromServer => '移出服务器';

  @override
  String get menuBan => '封禁';

  @override
  String get kickReasonHint => '原因（可选）';

  @override
  String get banReasonHint => '原因（可选，留空将取消）';

  @override
  String get banDurationLabel => '封禁时长';

  @override
  String get banDurationPermanent => '永久';

  @override
  String get banDuration1h => '1 小时';

  @override
  String get banDuration1d => '1 天';

  @override
  String get banDuration1w => '1 周';

  @override
  String get startKick => '踢出';

  @override
  String get startBan => '封禁';

  @override
  String get banCanceled => '已取消封禁——未填写原因';

  @override
  String get moveSucceeded => '移动请求已发送';

  @override
  String get kickSent => '踢出请求已发送';

  @override
  String get banSent => '封禁请求已发送';

  @override
  String get menuServerGroups => '给予权限（服务器组）';

  @override
  String get menuChannelGroups => '频道组';

  @override
  String get menuGrantRevokePerms => '给予 / 移除权限';

  @override
  String get grantPermission => '给予权限';

  @override
  String get revokePermission => '移除权限';

  @override
  String permCurrent(String current) {
    return '当前：$current';
  }

  @override
  String get permPresetTalkPower => '发言权限';

  @override
  String get permPresetPrioritySpeaker => '优先发言';

  @override
  String get permPresetChannelCommander => '频道指挥官';

  @override
  String get permChannelSection => '频道权限';

  @override
  String get permServerSection => '服务器级权限';

  @override
  String get permCustomSection => '自定义权限';

  @override
  String get permCustomPermsid => '权限 ID（如 i_client_whisper_power）';

  @override
  String get permCustomValue => '值';

  @override
  String get channelGroupNone => '无频道组';

  @override
  String get groupsNotLoaded => '组列表尚未加载';

  @override
  String get retry => '重试';

  @override
  String get dbIdUnavailable => '暂无法获取该用户的数据库 ID';

  @override
  String get permOpSucceeded => '权限变更已发送';

  @override
  String permOpFailed(String error) {
    return '权限变更失败：$error';
  }

  @override
  String get permNotConnected => '未连接';

  @override
  String get permQueueFailed => '请求入队失败';

  @override
  String get permTimeout => '服务器未在规定时间内应答';

  @override
  String get permFailedUnknown => '服务器拒绝了该请求';

  @override
  String get positionTitle => '设置位置';

  @override
  String get positionSelf => '我';

  @override
  String get positionHint =>
      '拖动圆点设置 TA 相对你的位置：上方是你的前方，距离越远音量越小。普通立体声无法区分前后，由距离体现。';

  @override
  String get positionUnset => '未设置位置——居中播放';

  @override
  String get positionReset => '重置位置';

  @override
  String get avatarUpload => '上传头像';

  @override
  String get avatarUploaded => '头像已更新';

  @override
  String avatarUploadFailed(String error) {
    return '头像上传失败：$error';
  }

  @override
  String get avatarInvalidImage => '不支持的图片文件';

  @override
  String get avatarDelete => '删除头像';

  @override
  String get avatarDeleted => '头像已删除';

  @override
  String avatarDeleteFailed(String error) {
    return '头像删除失败：$error';
  }

  @override
  String get about => '关于';

  @override
  String appVersion(String version) {
    return '版本 $version';
  }

  @override
  String get viewOnGitHub => '在 GitHub 上查看';

  @override
  String get openLinkFailed => '无法打开链接';

  @override
  String get backgroundSection => '背景';

  @override
  String get bgPickImage => '选择图片';

  @override
  String get bgDim => '背景变暗';

  @override
  String get bgOpacity => '背景不透明度';

  @override
  String get bgReset => '恢复默认';

  @override
  String get windowSection => '窗口';

  @override
  String get closeActionAsk => '每次询问';

  @override
  String get closeActionHide => '隐藏到托盘';

  @override
  String get closeActionExit => '直接退出';

  @override
  String get closeDialogTitle => '关闭 NEk0';

  @override
  String get closeDialogBody => '要退出 NEk0，还是让它继续在系统托盘中运行？';

  @override
  String get closeDialogConnectedBody =>
      '当前仍连接在服务器上，退出会离开服务器。也可以让 NEk0 继续在托盘中运行。';

  @override
  String get closeDialogQuit => '退出';

  @override
  String get closeDialogHide => '隐藏到托盘';

  @override
  String get closeDialogDontAskAgain => '不再询问';

  @override
  String get trayMenuShow => '显示主窗口';

  @override
  String get trayMenuDisconnect => '断开连接';

  @override
  String get trayMenuQuit => '退出 NEk0';

  @override
  String get recordingTitle => '录音';

  @override
  String get recordingLive => '录音中';

  @override
  String get recordingStopped => '已停止';

  @override
  String get recordingStart => '开始录音';

  @override
  String recordingStartWithBacktrack(int minutes) {
    return '开始录音（含最近 $minutes 分钟）';
  }

  @override
  String get recordingStop => '停止录音';

  @override
  String recordingSaveReplay(int minutes) {
    return '保存最近 $minutes 分钟';
  }

  @override
  String get recordingSave => '保存录音';

  @override
  String get recordingDiscard => '放弃录音';

  @override
  String get recordingSaveTitle => '保存录音';

  @override
  String get recordingSaveMixed => '混合为一个文件（含自己的声音）';

  @override
  String recordingSaveSeparate(int count) {
    return '按用户分别保存（$count 个音轨）';
  }

  @override
  String get recordingSaving => '正在保存录音…';

  @override
  String recordingSavedCount(int count) {
    return '已保存 $count 个文件';
  }

  @override
  String get recordingSaveFailed => '录音保存失败';

  @override
  String get recordingNothing => '没有可保存的录音';

  @override
  String recordingAutoSaved(int count) {
    return '连接已断开，已自动保存 $count 个录音文件';
  }

  @override
  String get recordingBacktrack => '回溯录音';

  @override
  String get recordingSaveDir => '保存位置';

  @override
  String get recordingSaveDirDefault => '默认（下载/NEk0/Recordings）';

  @override
  String get recordingSaveDirPick => '选择…';

  @override
  String get recordingSaveDirReset => '重置';

  @override
  String minutesCount(int n) {
    return '$n 分钟';
  }

  @override
  String get recordingBacktrackHint =>
      '连接期间持续缓冲会话语音：可随时保存最近一段回溯，也可以让录音以这段回溯开头。每位用户保存为独立音轨。';
}
