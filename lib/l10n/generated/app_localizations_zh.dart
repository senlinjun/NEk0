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
  String get users => '用户';

  @override
  String get chat => '聊天';

  @override
  String get guideMicTitle => '麦克风';

  @override
  String get guideMicDesc => '点击静音麦克风。长按打开语音设置（VAD、PTT、麦克风增益）。';

  @override
  String get guideHeadsetTitle => '耳机';

  @override
  String get guideHeadsetDesc => '一键全静音：同时关闭你的麦克风和其他人的音频。媒体卡片上的播放/暂停键也是同样的功能。';

  @override
  String get guideSpeakerTitle => '扬声器';

  @override
  String get guideSpeakerDesc => '静音所有人的音频（输出）。';

  @override
  String get guideChatTitle => '聊天';

  @override
  String get guideChatDesc => '点击聊天栏向当前频道发送消息。';

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
  String get updateSection => '更新';

  @override
  String get checkForUpdates => '检查更新';

  @override
  String get updateSource => '更新源';

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
  String get disconnected => '未连接';

  @override
  String get disconnect => '断开连接';

  @override
  String get noUsersInChannel => '该频道暂无用户';

  @override
  String get noMessagesYet => '暂无消息';

  @override
  String get sendMessageHint => '发送消息...';

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
  String get teamSpeakUserDefault => 'TeamSpeakUser';

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
}
