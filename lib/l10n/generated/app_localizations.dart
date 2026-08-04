import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @later.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get later;

  /// No description provided for @update.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get update;

  /// No description provided for @skip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// No description provided for @next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @gotIt.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get gotIt;

  /// No description provided for @guide.
  ///
  /// In en, this message translates to:
  /// **'Guide'**
  String get guide;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @addServer.
  ///
  /// In en, this message translates to:
  /// **'Add Server'**
  String get addServer;

  /// No description provided for @noServersAdded.
  ///
  /// In en, this message translates to:
  /// **'No servers added'**
  String get noServersAdded;

  /// No description provided for @deleteServerTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Server?'**
  String get deleteServerTitle;

  /// No description provided for @deleteServerBody.
  ///
  /// In en, this message translates to:
  /// **'Remove \"{name}\" from bookmarks?'**
  String deleteServerBody(String name);

  /// No description provided for @guideAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add your server'**
  String get guideAddTitle;

  /// No description provided for @guideAddDesc.
  ///
  /// In en, this message translates to:
  /// **'Tap + to add a TeamSpeak server, then tap it to connect and start talking.'**
  String get guideAddDesc;

  /// No description provided for @channels.
  ///
  /// In en, this message translates to:
  /// **'Channels'**
  String get channels;

  /// No description provided for @users.
  ///
  /// In en, this message translates to:
  /// **'Users'**
  String get users;

  /// No description provided for @chat.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get chat;

  /// No description provided for @guideMicTitle.
  ///
  /// In en, this message translates to:
  /// **'Mic'**
  String get guideMicTitle;

  /// No description provided for @guideMicDesc.
  ///
  /// In en, this message translates to:
  /// **'Tap to mute your mic. Long-press for voice settings (VAD, PTT, mic gain).'**
  String get guideMicDesc;

  /// No description provided for @guideHeadsetTitle.
  ///
  /// In en, this message translates to:
  /// **'Headset'**
  String get guideHeadsetTitle;

  /// No description provided for @guideHeadsetDesc.
  ///
  /// In en, this message translates to:
  /// **'Full mute: silences your mic and the audio of everyone else. The media card play/pause does the same.'**
  String get guideHeadsetDesc;

  /// No description provided for @guideSpeakerTitle.
  ///
  /// In en, this message translates to:
  /// **'Speaker'**
  String get guideSpeakerTitle;

  /// No description provided for @guideSpeakerDesc.
  ///
  /// In en, this message translates to:
  /// **'Mute everyone\'s audio (output).'**
  String get guideSpeakerDesc;

  /// No description provided for @guideChatTitle.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get guideChatTitle;

  /// No description provided for @guideChatDesc.
  ///
  /// In en, this message translates to:
  /// **'Tap the chat bar to send messages in your channel.'**
  String get guideChatDesc;

  /// No description provided for @keepAliveTitle.
  ///
  /// In en, this message translates to:
  /// **'Background Keep-Alive'**
  String get keepAliveTitle;

  /// No description provided for @keepAliveBody.
  ///
  /// In en, this message translates to:
  /// **'To stay online in the background like a music player, allow NEk0 to run in the background in system settings:\n• Battery → ignore battery optimizations (we will open it)\n• Auto-start: allow NEk0 to auto-start\n• Background power management: allow background running'**
  String get keepAliveBody;

  /// No description provided for @talking.
  ///
  /// In en, this message translates to:
  /// **'Talking'**
  String get talking;

  /// No description provided for @volume.
  ///
  /// In en, this message translates to:
  /// **'Volume'**
  String get volume;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @voice.
  ///
  /// In en, this message translates to:
  /// **'Voice'**
  String get voice;

  /// No description provided for @micTest.
  ///
  /// In en, this message translates to:
  /// **'Mic Test'**
  String get micTest;

  /// No description provided for @startMicTest.
  ///
  /// In en, this message translates to:
  /// **'Start mic test'**
  String get startMicTest;

  /// No description provided for @stopMicTest.
  ///
  /// In en, this message translates to:
  /// **'Stop test'**
  String get stopMicTest;

  /// No description provided for @micInUseWhileConnected.
  ///
  /// In en, this message translates to:
  /// **'Mic is in use while connected — test is disabled.'**
  String get micInUseWhileConnected;

  /// No description provided for @micPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Microphone permission denied'**
  String get micPermissionDenied;

  /// No description provided for @updateSection.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get updateSection;

  /// No description provided for @checkForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get checkForUpdates;

  /// No description provided for @updateSource.
  ///
  /// In en, this message translates to:
  /// **'Update source'**
  String get updateSource;

  /// No description provided for @checkNow.
  ///
  /// In en, this message translates to:
  /// **'Check now'**
  String get checkNow;

  /// No description provided for @checkingForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Checking for updates…'**
  String get checkingForUpdates;

  /// No description provided for @noUpdateAvailable.
  ///
  /// In en, this message translates to:
  /// **'No update available'**
  String get noUpdateAvailable;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get languageSystem;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageChinese.
  ///
  /// In en, this message translates to:
  /// **'中文'**
  String get languageChinese;

  /// No description provided for @voiceSettings.
  ///
  /// In en, this message translates to:
  /// **'Voice Settings'**
  String get voiceSettings;

  /// No description provided for @pttMode.
  ///
  /// In en, this message translates to:
  /// **'PTT Mode'**
  String get pttMode;

  /// No description provided for @voiceActivation.
  ///
  /// In en, this message translates to:
  /// **'Voice Activation'**
  String get voiceActivation;

  /// No description provided for @level.
  ///
  /// In en, this message translates to:
  /// **'Level'**
  String get level;

  /// No description provided for @micGain.
  ///
  /// In en, this message translates to:
  /// **'Mic Gain'**
  String get micGain;

  /// No description provided for @disconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get disconnected;

  /// No description provided for @disconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// No description provided for @noUsersInChannel.
  ///
  /// In en, this message translates to:
  /// **'No users in this channel'**
  String get noUsersInChannel;

  /// No description provided for @noMessagesYet.
  ///
  /// In en, this message translates to:
  /// **'No messages yet'**
  String get noMessagesYet;

  /// No description provided for @sendMessageHint.
  ///
  /// In en, this message translates to:
  /// **'Send a message...'**
  String get sendMessageHint;

  /// No description provided for @addServerTitle.
  ///
  /// In en, this message translates to:
  /// **'Add Server'**
  String get addServerTitle;

  /// No description provided for @editServerTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Server'**
  String get editServerTitle;

  /// No description provided for @serverName.
  ///
  /// In en, this message translates to:
  /// **'Server Name'**
  String get serverName;

  /// No description provided for @addressHint.
  ///
  /// In en, this message translates to:
  /// **'Address (e.g. ts.example.com)'**
  String get addressHint;

  /// No description provided for @nickname.
  ///
  /// In en, this message translates to:
  /// **'Nickname'**
  String get nickname;

  /// No description provided for @channelOptional.
  ///
  /// In en, this message translates to:
  /// **'Channel (optional)'**
  String get channelOptional;

  /// No description provided for @passwordOptional.
  ///
  /// In en, this message translates to:
  /// **'Password (optional)'**
  String get passwordOptional;

  /// No description provided for @teamSpeakUserDefault.
  ///
  /// In en, this message translates to:
  /// **'TeamSpeakUser'**
  String get teamSpeakUserDefault;

  /// No description provided for @updateAvailable.
  ///
  /// In en, this message translates to:
  /// **'Update available'**
  String get updateAvailable;

  /// No description provided for @updateAvailableBody.
  ///
  /// In en, this message translates to:
  /// **'NEk0 {version} is available.\n\nDownload and install it now?'**
  String updateAvailableBody(String version);

  /// No description provided for @updatingNek0.
  ///
  /// In en, this message translates to:
  /// **'Updating NEk0'**
  String get updatingNek0;

  /// No description provided for @downloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading… {percent}%'**
  String downloading(String percent);

  /// No description provided for @installing.
  ///
  /// In en, this message translates to:
  /// **'Installing…'**
  String get installing;

  /// No description provided for @updateFailed.
  ///
  /// In en, this message translates to:
  /// **'Update failed: {detail}'**
  String updateFailed(String detail);

  /// No description provided for @notifMute.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get notifMute;

  /// No description provided for @notifUnmute.
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get notifUnmute;

  /// No description provided for @notifDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get notifDisconnect;

  /// No description provided for @notifConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get notifConnected;

  /// No description provided for @noChannels.
  ///
  /// In en, this message translates to:
  /// **'No channels'**
  String get noChannels;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
