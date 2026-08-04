// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String get delete => 'Delete';

  @override
  String get edit => 'Edit';

  @override
  String get later => 'Later';

  @override
  String get update => 'Update';

  @override
  String get skip => 'Skip';

  @override
  String get next => 'Next';

  @override
  String get done => 'Done';

  @override
  String get gotIt => 'Got it';

  @override
  String get guide => 'Guide';

  @override
  String get settings => 'Settings';

  @override
  String get addServer => 'Add Server';

  @override
  String get noServersAdded => 'No servers added';

  @override
  String get deleteServerTitle => 'Delete Server?';

  @override
  String deleteServerBody(String name) {
    return 'Remove \"$name\" from bookmarks?';
  }

  @override
  String get guideAddTitle => 'Add your server';

  @override
  String get guideAddDesc =>
      'Tap + to add a TeamSpeak server, then tap it to connect and start talking.';

  @override
  String get channels => 'Channels';

  @override
  String get users => 'Users';

  @override
  String get chat => 'Chat';

  @override
  String get guideMicTitle => 'Mic';

  @override
  String get guideMicDesc =>
      'Tap to mute your mic. Long-press for voice settings (VAD, PTT, mic gain).';

  @override
  String get guideHeadsetTitle => 'Headset';

  @override
  String get guideHeadsetDesc =>
      'Full mute: silences your mic and the audio of everyone else. The media card play/pause does the same.';

  @override
  String get guideSpeakerTitle => 'Speaker';

  @override
  String get guideSpeakerDesc => 'Mute everyone\'s audio (output).';

  @override
  String get guideChatTitle => 'Chat';

  @override
  String get guideChatDesc =>
      'Tap the chat bar to send messages in your channel.';

  @override
  String get keepAliveTitle => 'Background Keep-Alive';

  @override
  String get keepAliveBody =>
      'To stay online in the background like a music player, allow NEk0 to run in the background in system settings:\n• Battery → ignore battery optimizations (we will open it)\n• Auto-start: allow NEk0 to auto-start\n• Background power management: allow background running';

  @override
  String get talking => 'Talking';

  @override
  String get volume => 'Volume';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get voice => 'Voice';

  @override
  String get micTest => 'Mic Test';

  @override
  String get startMicTest => 'Start mic test';

  @override
  String get stopMicTest => 'Stop test';

  @override
  String get micInUseWhileConnected =>
      'Mic is in use while connected — test is disabled.';

  @override
  String get micPermissionDenied => 'Microphone permission denied';

  @override
  String get updateSection => 'Update';

  @override
  String get checkForUpdates => 'Check for updates';

  @override
  String get updateSource => 'Update source';

  @override
  String get checkNow => 'Check now';

  @override
  String get checkingForUpdates => 'Checking for updates…';

  @override
  String get noUpdateAvailable => 'No update available';

  @override
  String get language => 'Language';

  @override
  String get languageSystem => 'System';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageChinese => '中文';

  @override
  String get voiceSettings => 'Voice Settings';

  @override
  String get pttMode => 'PTT Mode';

  @override
  String get voiceActivation => 'Voice Activation';

  @override
  String get level => 'Level';

  @override
  String get micGain => 'Mic Gain';

  @override
  String get disconnected => 'Disconnected';

  @override
  String get disconnect => 'Disconnect';

  @override
  String get noUsersInChannel => 'No users in this channel';

  @override
  String get noMessagesYet => 'No messages yet';

  @override
  String get sendMessageHint => 'Send a message...';

  @override
  String get addServerTitle => 'Add Server';

  @override
  String get editServerTitle => 'Edit Server';

  @override
  String get serverName => 'Server Name';

  @override
  String get addressHint => 'Address (e.g. ts.example.com)';

  @override
  String get nickname => 'Nickname';

  @override
  String get channelOptional => 'Channel (optional)';

  @override
  String get passwordOptional => 'Password (optional)';

  @override
  String get teamSpeakUserDefault => 'TeamSpeakUser';

  @override
  String get updateAvailable => 'Update available';

  @override
  String updateAvailableBody(String version) {
    return 'NEk0 $version is available.\n\nDownload and install it now?';
  }

  @override
  String get updatingNek0 => 'Updating NEk0';

  @override
  String downloading(String percent) {
    return 'Downloading… $percent%';
  }

  @override
  String get installing => 'Installing…';

  @override
  String updateFailed(String detail) {
    return 'Update failed: $detail';
  }

  @override
  String get notifMute => 'Mute';

  @override
  String get notifUnmute => 'Unmute';

  @override
  String get notifDisconnect => 'Disconnect';

  @override
  String get notifConnected => 'Connected';

  @override
  String get noChannels => 'No channels';
}
