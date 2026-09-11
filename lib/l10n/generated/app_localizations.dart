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

  /// No description provided for @guideChannelsTitle.
  ///
  /// In en, this message translates to:
  /// **'Channels'**
  String get guideChannelsTitle;

  /// No description provided for @guideChannelsDesc.
  ///
  /// In en, this message translates to:
  /// **'Tap a channel to join it; long-press for its menu (join, file manager).'**
  String get guideChannelsDesc;

  /// No description provided for @guideMembersTitle.
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get guideMembersTitle;

  /// No description provided for @guideMembersDesc.
  ///
  /// In en, this message translates to:
  /// **'Every member is listed under their channel — including members of other channels.'**
  String get guideMembersDesc;

  /// No description provided for @guideMemberActionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Member actions'**
  String get guideMemberActionsTitle;

  /// No description provided for @guideMemberActionsDesc.
  ///
  /// In en, this message translates to:
  /// **'Tap someone to adjust volume, poke or kick; tap your own name for voice settings.'**
  String get guideMemberActionsDesc;

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

  /// No description provided for @audioDevicesSection.
  ///
  /// In en, this message translates to:
  /// **'Audio devices'**
  String get audioDevicesSection;

  /// No description provided for @audioOutputDevice.
  ///
  /// In en, this message translates to:
  /// **'Output device'**
  String get audioOutputDevice;

  /// No description provided for @audioInputDevice.
  ///
  /// In en, this message translates to:
  /// **'Input device'**
  String get audioInputDevice;

  /// No description provided for @audioSystemDefault.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get audioSystemDefault;

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

  /// No description provided for @updateSourceAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get updateSourceAuto;

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

  /// No description provided for @channelSounds.
  ///
  /// In en, this message translates to:
  /// **'Channel sounds'**
  String get channelSounds;

  /// No description provided for @sfxDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get sfxDefault;

  /// No description provided for @sfxPackNone.
  ///
  /// In en, this message translates to:
  /// **'Built-in sounds'**
  String get sfxPackNone;

  /// No description provided for @sfxPackNoneDesc.
  ///
  /// In en, this message translates to:
  /// **'No voice pack in use'**
  String get sfxPackNoneDesc;

  /// No description provided for @sfxPackActive.
  ///
  /// In en, this message translates to:
  /// **'In use'**
  String get sfxPackActive;

  /// No description provided for @sfxPackImport.
  ///
  /// In en, this message translates to:
  /// **'Import voice pack (.zip)'**
  String get sfxPackImport;

  /// No description provided for @sfxPackImported.
  ///
  /// In en, this message translates to:
  /// **'Voice pack \"{name}\" enabled.'**
  String sfxPackImported(String name);

  /// No description provided for @sfxPackActivate.
  ///
  /// In en, this message translates to:
  /// **'Enable this pack'**
  String get sfxPackActivate;

  /// No description provided for @sfxPackDeactivate.
  ///
  /// In en, this message translates to:
  /// **'Stop using this pack'**
  String get sfxPackDeactivate;

  /// No description provided for @sfxPackDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete pack'**
  String get sfxPackDelete;

  /// No description provided for @sfxPackDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'Delete voice pack \"{name}\"?'**
  String sfxPackDeleteBody(String name);

  /// No description provided for @sfxPackInvalidZip.
  ///
  /// In en, this message translates to:
  /// **'Not a voice pack: pack.json is missing or the file is not a zip archive.'**
  String get sfxPackInvalidZip;

  /// No description provided for @sfxPackInvalidManifest.
  ///
  /// In en, this message translates to:
  /// **'pack.json is invalid: it needs a name and a sounds table mapping event IDs (1–37) to WAV files from the archive.'**
  String get sfxPackInvalidManifest;

  /// No description provided for @sfxPackPartialLoad.
  ///
  /// In en, this message translates to:
  /// **'Some sounds in this pack were skipped (unsupported format or longer than 2 seconds).'**
  String get sfxPackPartialLoad;

  /// No description provided for @poke.
  ///
  /// In en, this message translates to:
  /// **'Poke'**
  String get poke;

  /// No description provided for @pokeHint.
  ///
  /// In en, this message translates to:
  /// **'Message to send'**
  String get pokeHint;

  /// No description provided for @pokeSent.
  ///
  /// In en, this message translates to:
  /// **'Poke sent'**
  String get pokeSent;

  /// No description provided for @pokeNotificationTitle.
  ///
  /// In en, this message translates to:
  /// **'You were poked'**
  String get pokeNotificationTitle;

  /// No description provided for @pokeNotificationBody.
  ///
  /// In en, this message translates to:
  /// **'{name} poked you: {message}'**
  String pokeNotificationBody(String name, String message);

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @awayEnable.
  ///
  /// In en, this message translates to:
  /// **'Set away'**
  String get awayEnable;

  /// No description provided for @awayDisable.
  ///
  /// In en, this message translates to:
  /// **'Back online'**
  String get awayDisable;

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

  /// No description provided for @chatChannel.
  ///
  /// In en, this message translates to:
  /// **'Channel'**
  String get chatChannel;

  /// No description provided for @chatServer.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get chatServer;

  /// No description provided for @sendMessageAction.
  ///
  /// In en, this message translates to:
  /// **'Send message'**
  String get sendMessageAction;

  /// No description provided for @messageSendFailed.
  ///
  /// In en, this message translates to:
  /// **'Message not sent: {error}'**
  String messageSendFailed(String error);

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

  /// No description provided for @tokenOptional.
  ///
  /// In en, this message translates to:
  /// **'Privilege key (optional)'**
  String get tokenOptional;

  /// No description provided for @privilegeKeyTitle.
  ///
  /// In en, this message translates to:
  /// **'Use privilege key'**
  String get privilegeKeyTitle;

  /// No description provided for @privilegeKeyBody.
  ///
  /// In en, this message translates to:
  /// **'This server is asking for a privilege key (admin token). Enter it to be added to the associated server groups.'**
  String get privilegeKeyBody;

  /// No description provided for @privilegeKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Token'**
  String get privilegeKeyHint;

  /// No description provided for @privilegeKeyGranted.
  ///
  /// In en, this message translates to:
  /// **'Privilege key redeemed — server groups updated.'**
  String get privilegeKeyGranted;

  /// No description provided for @privilegeKeyNoEffect.
  ///
  /// In en, this message translates to:
  /// **'The token was accepted, but no group change was detected. It may be invalid or already used.'**
  String get privilegeKeyNoEffect;

  /// No description provided for @teamSpeakUserDefault.
  ///
  /// In en, this message translates to:
  /// **'TeamSpeakUser'**
  String get teamSpeakUserDefault;

  /// No description provided for @ports.
  ///
  /// In en, this message translates to:
  /// **'Ports'**
  String get ports;

  /// No description provided for @portsHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to use the defaults (voice 9987, ServerQuery 10011, file transfer 30033, SSH 10022).'**
  String get portsHint;

  /// No description provided for @voicePort.
  ///
  /// In en, this message translates to:
  /// **'Voice port'**
  String get voicePort;

  /// No description provided for @serverQueryPort.
  ///
  /// In en, this message translates to:
  /// **'ServerQuery port'**
  String get serverQueryPort;

  /// No description provided for @fileTransferPort.
  ///
  /// In en, this message translates to:
  /// **'File transfer port'**
  String get fileTransferPort;

  /// No description provided for @serverQuerySshPort.
  ///
  /// In en, this message translates to:
  /// **'ServerQuery SSH port'**
  String get serverQuerySshPort;

  /// No description provided for @invalidPort.
  ///
  /// In en, this message translates to:
  /// **'Ports must be numbers between 1 and 65535.'**
  String get invalidPort;

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

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @channelPasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter channel password'**
  String get channelPasswordTitle;

  /// No description provided for @channelPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get channelPasswordHint;

  /// No description provided for @channelPasswordWrong.
  ///
  /// In en, this message translates to:
  /// **'Wrong channel password'**
  String get channelPasswordWrong;

  /// No description provided for @menuEnterChannel.
  ///
  /// In en, this message translates to:
  /// **'Join channel'**
  String get menuEnterChannel;

  /// No description provided for @menuFileManager.
  ///
  /// In en, this message translates to:
  /// **'File management'**
  String get menuFileManager;

  /// No description provided for @menuServerTitle.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get menuServerTitle;

  /// No description provided for @menuEditServer.
  ///
  /// In en, this message translates to:
  /// **'Edit server'**
  String get menuEditServer;

  /// No description provided for @serverSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Server Settings'**
  String get serverSettingsTitle;

  /// No description provided for @serverMaxClientsLabel.
  ///
  /// In en, this message translates to:
  /// **'Max clients'**
  String get serverMaxClientsLabel;

  /// No description provided for @serverPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Server password'**
  String get serverPasswordLabel;

  /// No description provided for @serverPasswordHelper.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to keep the current one'**
  String get serverPasswordHelper;

  /// No description provided for @serverPasswordRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove server password'**
  String get serverPasswordRemove;

  /// No description provided for @serverSaved.
  ///
  /// In en, this message translates to:
  /// **'Server updated'**
  String get serverSaved;

  /// No description provided for @serverReadOnlyHint.
  ///
  /// In en, this message translates to:
  /// **'You do not have permission to change server settings'**
  String get serverReadOnlyHint;

  /// No description provided for @menuCreateChannel.
  ///
  /// In en, this message translates to:
  /// **'Create channel'**
  String get menuCreateChannel;

  /// No description provided for @menuEditChannel.
  ///
  /// In en, this message translates to:
  /// **'Edit channel'**
  String get menuEditChannel;

  /// No description provided for @menuDeleteChannel.
  ///
  /// In en, this message translates to:
  /// **'Delete channel'**
  String get menuDeleteChannel;

  /// No description provided for @channelCreateTitle.
  ///
  /// In en, this message translates to:
  /// **'Create Channel'**
  String get channelCreateTitle;

  /// No description provided for @channelEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Channel'**
  String get channelEditTitle;

  /// No description provided for @channelNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Channel name'**
  String get channelNameLabel;

  /// No description provided for @channelTopicLabel.
  ///
  /// In en, this message translates to:
  /// **'Topic (optional)'**
  String get channelTopicLabel;

  /// No description provided for @channelPasswordHelper.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to clear'**
  String get channelPasswordHelper;

  /// No description provided for @channelMaxClientsLabel.
  ///
  /// In en, this message translates to:
  /// **'Max clients'**
  String get channelMaxClientsLabel;

  /// No description provided for @channelMaxClientsHelper.
  ///
  /// In en, this message translates to:
  /// **'Empty = unlimited'**
  String get channelMaxClientsHelper;

  /// No description provided for @channelTypeLabel.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get channelTypeLabel;

  /// No description provided for @channelTypeTemporary.
  ///
  /// In en, this message translates to:
  /// **'Temporary'**
  String get channelTypeTemporary;

  /// No description provided for @channelTypeSemiPermanent.
  ///
  /// In en, this message translates to:
  /// **'Semi-permanent'**
  String get channelTypeSemiPermanent;

  /// No description provided for @channelTypePermanent.
  ///
  /// In en, this message translates to:
  /// **'Permanent'**
  String get channelTypePermanent;

  /// No description provided for @deleteChannelTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete channel?'**
  String get deleteChannelTitle;

  /// No description provided for @deleteChannelBody.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String deleteChannelBody(String name);

  /// No description provided for @deleteChannelOccupied.
  ///
  /// In en, this message translates to:
  /// **'This channel has {count} clients — they will be moved to the default channel.'**
  String deleteChannelOccupied(int count);

  /// No description provided for @channelCreated.
  ///
  /// In en, this message translates to:
  /// **'Channel created'**
  String get channelCreated;

  /// No description provided for @channelSaved.
  ///
  /// In en, this message translates to:
  /// **'Channel updated'**
  String get channelSaved;

  /// No description provided for @channelDeleted.
  ///
  /// In en, this message translates to:
  /// **'Channel deleted'**
  String get channelDeleted;

  /// No description provided for @channelMoved.
  ///
  /// In en, this message translates to:
  /// **'Channel moved'**
  String get channelMoved;

  /// No description provided for @menuMoveUp.
  ///
  /// In en, this message translates to:
  /// **'Move up'**
  String get menuMoveUp;

  /// No description provided for @menuMoveDown.
  ///
  /// In en, this message translates to:
  /// **'Move down'**
  String get menuMoveDown;

  /// No description provided for @channelDescriptionLabel.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get channelDescriptionLabel;

  /// No description provided for @channelNeededTalkPowerLabel.
  ///
  /// In en, this message translates to:
  /// **'Needed talk power'**
  String get channelNeededTalkPowerLabel;

  /// No description provided for @channelTalkPowerHelper.
  ///
  /// In en, this message translates to:
  /// **'0 = everyone may talk'**
  String get channelTalkPowerHelper;

  /// No description provided for @channelDeleteDelayLabel.
  ///
  /// In en, this message translates to:
  /// **'Delete delay (seconds)'**
  String get channelDeleteDelayLabel;

  /// No description provided for @channelDeleteDelayHelper.
  ///
  /// In en, this message translates to:
  /// **'Seconds before an empty channel is removed'**
  String get channelDeleteDelayHelper;

  /// No description provided for @channelMaxFamilyLabel.
  ///
  /// In en, this message translates to:
  /// **'Group user limit'**
  String get channelMaxFamilyLabel;

  /// No description provided for @channelMaxFamilyInherit.
  ///
  /// In en, this message translates to:
  /// **'Inherit from parent'**
  String get channelMaxFamilyInherit;

  /// No description provided for @channelMaxFamilyUnlimited.
  ///
  /// In en, this message translates to:
  /// **'Unlimited'**
  String get channelMaxFamilyUnlimited;

  /// No description provided for @channelMaxFamilyLimited.
  ///
  /// In en, this message translates to:
  /// **'Custom limit'**
  String get channelMaxFamilyLimited;

  /// No description provided for @channelIsDefaultLabel.
  ///
  /// In en, this message translates to:
  /// **'Default channel'**
  String get channelIsDefaultLabel;

  /// No description provided for @audio.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get audio;

  /// No description provided for @fmUp.
  ///
  /// In en, this message translates to:
  /// **'Up'**
  String get fmUp;

  /// No description provided for @fmRootShort.
  ///
  /// In en, this message translates to:
  /// **'/'**
  String get fmRootShort;

  /// No description provided for @fmSearch.
  ///
  /// In en, this message translates to:
  /// **'Search files'**
  String get fmSearch;

  /// No description provided for @fmSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search in this folder tree…'**
  String get fmSearchHint;

  /// No description provided for @fmNoResults.
  ///
  /// In en, this message translates to:
  /// **'No matches found'**
  String get fmNoResults;

  /// No description provided for @fmUploadFile.
  ///
  /// In en, this message translates to:
  /// **'Upload file'**
  String get fmUploadFile;

  /// No description provided for @fmUploadFolder.
  ///
  /// In en, this message translates to:
  /// **'Upload folder'**
  String get fmUploadFolder;

  /// No description provided for @fmUploadDone.
  ///
  /// In en, this message translates to:
  /// **'Upload finished'**
  String get fmUploadDone;

  /// No description provided for @fmNewFolder.
  ///
  /// In en, this message translates to:
  /// **'New folder'**
  String get fmNewFolder;

  /// No description provided for @fmNewFolderName.
  ///
  /// In en, this message translates to:
  /// **'Folder name'**
  String get fmNewFolderName;

  /// No description provided for @fmInvalidName.
  ///
  /// In en, this message translates to:
  /// **'Invalid folder name'**
  String get fmInvalidName;

  /// No description provided for @fmFolderCreated.
  ///
  /// In en, this message translates to:
  /// **'Folder created'**
  String get fmFolderCreated;

  /// No description provided for @fmDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get fmDownload;

  /// No description provided for @fmDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get fmDelete;

  /// No description provided for @fmConfirmDeleteFile.
  ///
  /// In en, this message translates to:
  /// **'Delete file \"{name}\"?'**
  String fmConfirmDeleteFile(String name);

  /// No description provided for @fmConfirmDeleteFolder.
  ///
  /// In en, this message translates to:
  /// **'Delete folder \"{name}\" and ALL of its contents?'**
  String fmConfirmDeleteFolder(String name);

  /// No description provided for @fmDeleted.
  ///
  /// In en, this message translates to:
  /// **'Deleted'**
  String get fmDeleted;

  /// No description provided for @fmSavedToDownloads.
  ///
  /// In en, this message translates to:
  /// **'Saved to Downloads'**
  String get fmSavedToDownloads;

  /// No description provided for @fmNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Connect to a server to manage its files.'**
  String get fmNotConnected;

  /// No description provided for @fmEmpty.
  ///
  /// In en, this message translates to:
  /// **'Empty folder'**
  String get fmEmpty;

  /// No description provided for @fmRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get fmRefresh;

  /// No description provided for @fmCancelTransfer.
  ///
  /// In en, this message translates to:
  /// **'Cancel transfer'**
  String get fmCancelTransfer;

  /// No description provided for @fmTransfersTitle.
  ///
  /// In en, this message translates to:
  /// **'Transfers'**
  String get fmTransfersTitle;

  /// No description provided for @fmStateDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get fmStateDone;

  /// No description provided for @fmStateError.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get fmStateError;

  /// No description provided for @fmStateCanceled.
  ///
  /// In en, this message translates to:
  /// **'Canceled'**
  String get fmStateCanceled;

  /// No description provided for @fmOperationFailed.
  ///
  /// In en, this message translates to:
  /// **'Operation failed'**
  String get fmOperationFailed;

  /// No description provided for @fmClearHistory.
  ///
  /// In en, this message translates to:
  /// **'Clear finished'**
  String get fmClearHistory;

  /// No description provided for @fmPermDenied.
  ///
  /// In en, this message translates to:
  /// **'The server has not granted file-transfer permissions'**
  String get fmPermDenied;

  /// No description provided for @fmCanceled.
  ///
  /// In en, this message translates to:
  /// **'Transfer canceled'**
  String get fmCanceled;

  /// No description provided for @fmReasonPrefix.
  ///
  /// In en, this message translates to:
  /// **'Operation failed: {reason}'**
  String fmReasonPrefix(String reason);

  /// No description provided for @channelsNoJoinPermission.
  ///
  /// In en, this message translates to:
  /// **'You do not have permission to join this channel'**
  String get channelsNoJoinPermission;

  /// No description provided for @channelTalkPowerNeeded.
  ///
  /// In en, this message translates to:
  /// **'Talk power required: {power}'**
  String channelTalkPowerNeeded(int power);

  /// No description provided for @serverQuery.
  ///
  /// In en, this message translates to:
  /// **'Server query client'**
  String get serverQuery;

  /// No description provided for @serverQueryAdmin.
  ///
  /// In en, this message translates to:
  /// **'Server query with admin rights'**
  String get serverQueryAdmin;

  /// No description provided for @channelCommander.
  ///
  /// In en, this message translates to:
  /// **'Channel commander'**
  String get channelCommander;

  /// No description provided for @prioritySpeaker.
  ///
  /// In en, this message translates to:
  /// **'Priority speaker'**
  String get prioritySpeaker;

  /// No description provided for @recording.
  ///
  /// In en, this message translates to:
  /// **'Recording'**
  String get recording;

  /// No description provided for @talkPowerDenied.
  ///
  /// In en, this message translates to:
  /// **'No talk power in this channel'**
  String get talkPowerDenied;

  /// No description provided for @serverGroups.
  ///
  /// In en, this message translates to:
  /// **'Groups: {groups}'**
  String serverGroups(String groups);

  /// No description provided for @menuMoveToChannel.
  ///
  /// In en, this message translates to:
  /// **'Move to channel'**
  String get menuMoveToChannel;

  /// No description provided for @menuKickFromChannel.
  ///
  /// In en, this message translates to:
  /// **'Kick from channel'**
  String get menuKickFromChannel;

  /// No description provided for @menuKickFromServer.
  ///
  /// In en, this message translates to:
  /// **'Kick from server'**
  String get menuKickFromServer;

  /// No description provided for @menuBan.
  ///
  /// In en, this message translates to:
  /// **'Ban'**
  String get menuBan;

  /// No description provided for @kickReasonHint.
  ///
  /// In en, this message translates to:
  /// **'Reason (optional)'**
  String get kickReasonHint;

  /// No description provided for @banReasonHint.
  ///
  /// In en, this message translates to:
  /// **'Reason (optional — empty cancels)'**
  String get banReasonHint;

  /// No description provided for @banDurationLabel.
  ///
  /// In en, this message translates to:
  /// **'Ban duration'**
  String get banDurationLabel;

  /// No description provided for @banDurationPermanent.
  ///
  /// In en, this message translates to:
  /// **'Permanent'**
  String get banDurationPermanent;

  /// No description provided for @banDuration1h.
  ///
  /// In en, this message translates to:
  /// **'1 hour'**
  String get banDuration1h;

  /// No description provided for @banDuration1d.
  ///
  /// In en, this message translates to:
  /// **'1 day'**
  String get banDuration1d;

  /// No description provided for @banDuration1w.
  ///
  /// In en, this message translates to:
  /// **'1 week'**
  String get banDuration1w;

  /// No description provided for @startKick.
  ///
  /// In en, this message translates to:
  /// **'Kick'**
  String get startKick;

  /// No description provided for @startBan.
  ///
  /// In en, this message translates to:
  /// **'Ban'**
  String get startBan;

  /// No description provided for @banCanceled.
  ///
  /// In en, this message translates to:
  /// **'Ban canceled — no reason given'**
  String get banCanceled;

  /// No description provided for @moveSucceeded.
  ///
  /// In en, this message translates to:
  /// **'Move sent'**
  String get moveSucceeded;

  /// No description provided for @kickSent.
  ///
  /// In en, this message translates to:
  /// **'Kick sent'**
  String get kickSent;

  /// No description provided for @banSent.
  ///
  /// In en, this message translates to:
  /// **'Ban sent'**
  String get banSent;

  /// No description provided for @menuServerGroups.
  ///
  /// In en, this message translates to:
  /// **'Grant permissions (server groups)'**
  String get menuServerGroups;

  /// No description provided for @menuChannelGroups.
  ///
  /// In en, this message translates to:
  /// **'Channel group'**
  String get menuChannelGroups;

  /// No description provided for @menuGrantRevokePerms.
  ///
  /// In en, this message translates to:
  /// **'Grant / revoke permissions'**
  String get menuGrantRevokePerms;

  /// No description provided for @grantPermission.
  ///
  /// In en, this message translates to:
  /// **'Grant permission'**
  String get grantPermission;

  /// No description provided for @revokePermission.
  ///
  /// In en, this message translates to:
  /// **'Revoke permission'**
  String get revokePermission;

  /// No description provided for @permCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current: {current}'**
  String permCurrent(String current);

  /// No description provided for @permPresetTalkPower.
  ///
  /// In en, this message translates to:
  /// **'Talk power'**
  String get permPresetTalkPower;

  /// No description provided for @permPresetPrioritySpeaker.
  ///
  /// In en, this message translates to:
  /// **'Priority speaker'**
  String get permPresetPrioritySpeaker;

  /// No description provided for @permPresetChannelCommander.
  ///
  /// In en, this message translates to:
  /// **'Channel commander'**
  String get permPresetChannelCommander;

  /// No description provided for @permChannelSection.
  ///
  /// In en, this message translates to:
  /// **'Channel permissions'**
  String get permChannelSection;

  /// No description provided for @permServerSection.
  ///
  /// In en, this message translates to:
  /// **'Server-wide permissions'**
  String get permServerSection;

  /// No description provided for @permCustomSection.
  ///
  /// In en, this message translates to:
  /// **'Custom permission'**
  String get permCustomSection;

  /// No description provided for @permCustomPermsid.
  ///
  /// In en, this message translates to:
  /// **'perm id (e.g. i_client_whisper_power)'**
  String get permCustomPermsid;

  /// No description provided for @permCustomValue.
  ///
  /// In en, this message translates to:
  /// **'value'**
  String get permCustomValue;

  /// No description provided for @channelGroupNone.
  ///
  /// In en, this message translates to:
  /// **'No channel group'**
  String get channelGroupNone;

  /// No description provided for @groupsNotLoaded.
  ///
  /// In en, this message translates to:
  /// **'Group list not loaded yet'**
  String get groupsNotLoaded;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @dbIdUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Cannot get this user\'s database ID yet'**
  String get dbIdUnavailable;

  /// No description provided for @permOpSucceeded.
  ///
  /// In en, this message translates to:
  /// **'Permission change sent'**
  String get permOpSucceeded;

  /// No description provided for @permOpFailed.
  ///
  /// In en, this message translates to:
  /// **'Permission change failed: {error}'**
  String permOpFailed(String error);

  /// No description provided for @permNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get permNotConnected;

  /// No description provided for @permQueueFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to queue the request'**
  String get permQueueFailed;

  /// No description provided for @permTimeout.
  ///
  /// In en, this message translates to:
  /// **'The server did not answer in time'**
  String get permTimeout;

  /// No description provided for @permFailedUnknown.
  ///
  /// In en, this message translates to:
  /// **'The server rejected the request'**
  String get permFailedUnknown;

  /// No description provided for @positionTitle.
  ///
  /// In en, this message translates to:
  /// **'Set position'**
  String get positionTitle;

  /// No description provided for @positionSelf.
  ///
  /// In en, this message translates to:
  /// **'Me'**
  String get positionSelf;

  /// No description provided for @positionHint.
  ///
  /// In en, this message translates to:
  /// **'Drag to place them around you: up is in front of you, farther away is quieter. Plain stereo cannot tell front from back — distance carries that.'**
  String get positionHint;

  /// No description provided for @positionUnset.
  ///
  /// In en, this message translates to:
  /// **'No position set — plays centered'**
  String get positionUnset;

  /// No description provided for @positionReset.
  ///
  /// In en, this message translates to:
  /// **'Reset position'**
  String get positionReset;

  /// No description provided for @avatarUpload.
  ///
  /// In en, this message translates to:
  /// **'Upload avatar'**
  String get avatarUpload;

  /// No description provided for @avatarUploaded.
  ///
  /// In en, this message translates to:
  /// **'Avatar updated'**
  String get avatarUploaded;

  /// No description provided for @avatarUploadFailed.
  ///
  /// In en, this message translates to:
  /// **'Avatar upload failed: {error}'**
  String avatarUploadFailed(String error);

  /// No description provided for @avatarInvalidImage.
  ///
  /// In en, this message translates to:
  /// **'Unsupported image file'**
  String get avatarInvalidImage;

  /// No description provided for @avatarDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete avatar'**
  String get avatarDelete;

  /// No description provided for @avatarDeleted.
  ///
  /// In en, this message translates to:
  /// **'Avatar removed'**
  String get avatarDeleted;

  /// No description provided for @avatarDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete avatar: {error}'**
  String avatarDeleteFailed(String error);

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @appVersion.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String appVersion(String version);

  /// No description provided for @viewOnGitHub.
  ///
  /// In en, this message translates to:
  /// **'View on GitHub'**
  String get viewOnGitHub;

  /// No description provided for @openLinkFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open the link'**
  String get openLinkFailed;

  /// No description provided for @backgroundSection.
  ///
  /// In en, this message translates to:
  /// **'Background'**
  String get backgroundSection;

  /// No description provided for @bgPickImage.
  ///
  /// In en, this message translates to:
  /// **'Pick Image'**
  String get bgPickImage;

  /// No description provided for @bgDim.
  ///
  /// In en, this message translates to:
  /// **'Dim'**
  String get bgDim;

  /// No description provided for @bgOpacity.
  ///
  /// In en, this message translates to:
  /// **'Opacity'**
  String get bgOpacity;

  /// No description provided for @bgReset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get bgReset;

  /// No description provided for @windowSection.
  ///
  /// In en, this message translates to:
  /// **'Window'**
  String get windowSection;

  /// No description provided for @closeActionAsk.
  ///
  /// In en, this message translates to:
  /// **'Ask every time'**
  String get closeActionAsk;

  /// No description provided for @closeActionHide.
  ///
  /// In en, this message translates to:
  /// **'Hide to tray'**
  String get closeActionHide;

  /// No description provided for @closeActionExit.
  ///
  /// In en, this message translates to:
  /// **'Quit the app'**
  String get closeActionExit;

  /// No description provided for @closeDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Close NEk0'**
  String get closeDialogTitle;

  /// No description provided for @closeDialogBody.
  ///
  /// In en, this message translates to:
  /// **'Do you want to quit NEk0, or keep it running in the system tray?'**
  String get closeDialogBody;

  /// No description provided for @closeDialogConnectedBody.
  ///
  /// In en, this message translates to:
  /// **'You are still connected — quitting will leave the server. You can also keep NEk0 running in the tray.'**
  String get closeDialogConnectedBody;

  /// No description provided for @closeDialogQuit.
  ///
  /// In en, this message translates to:
  /// **'Quit'**
  String get closeDialogQuit;

  /// No description provided for @closeDialogHide.
  ///
  /// In en, this message translates to:
  /// **'Hide to tray'**
  String get closeDialogHide;

  /// No description provided for @closeDialogDontAskAgain.
  ///
  /// In en, this message translates to:
  /// **'Don\'t ask again'**
  String get closeDialogDontAskAgain;

  /// No description provided for @trayMenuShow.
  ///
  /// In en, this message translates to:
  /// **'Show NEk0'**
  String get trayMenuShow;

  /// No description provided for @trayMenuDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get trayMenuDisconnect;

  /// No description provided for @trayMenuQuit.
  ///
  /// In en, this message translates to:
  /// **'Quit NEk0'**
  String get trayMenuQuit;
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
