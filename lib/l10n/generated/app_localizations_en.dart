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
  String get chat => 'Chat';

  @override
  String get guideMicTitle => 'Mic';

  @override
  String get guideMicDesc =>
      'Tap to mute your mic. Long-press for voice settings (VAD, PTT, mic gain).';

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
  String get guideChannelsTitle => 'Channels';

  @override
  String get guideChannelsDesc =>
      'Tap a channel to join it; long-press for its menu (join, file manager).';

  @override
  String get guideMembersTitle => 'Members';

  @override
  String get guideMembersDesc =>
      'Every member is listed under their channel — including members of other channels.';

  @override
  String get guideMemberActionsTitle => 'Member actions';

  @override
  String get guideMemberActionsDesc =>
      'Tap someone to adjust volume, poke or kick; tap your own name for voice settings.';

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
  String get updateSourceAuto => 'Auto';

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
  String get channelSounds => 'Channel sounds';

  @override
  String get sfxGroupConnection => 'Connection';

  @override
  String get sfxGroupChannel => 'Channel';

  @override
  String get sfxGroupUsers => 'Other users';

  @override
  String get sfxGroupAboutYou => 'About you';

  @override
  String get sfxGroupChat => 'Chat';

  @override
  String get sfxGroupVoice => 'Voice';

  @override
  String get sfxGroupOther => 'Other';

  @override
  String get sfxChannelSwitched => 'You switched channels';

  @override
  String get sfxNeutralToCurrent => 'Someone switched into your channel';

  @override
  String get sfxNeutralAwayFromCurrent =>
      'Someone switched away from your channel';

  @override
  String get sfxNeutralConnConnected => 'User connected to your channel';

  @override
  String get sfxNeutralConnDisconnected => 'User disconnected from the server';

  @override
  String get sfxNeutralConnConnectionLost => 'User connection lost (timeout)';

  @override
  String get sfxNeutralMovedToCurrent => 'User moved into your channel';

  @override
  String get sfxNeutralMovedAwayFromCurrent => 'User moved out of your channel';

  @override
  String get sfxNeutralKickedChannelToCurrent =>
      'User kicked into your channel';

  @override
  String get sfxNeutralKickedChannelAwayFromCurrent =>
      'User kicked out of your channel';

  @override
  String get sfxNeutralKickedServer => 'User kicked from the server';

  @override
  String get sfxNeutralBannedServer => 'User banned from the server';

  @override
  String get sfxNeutralRecordingStarted => 'User started recording';

  @override
  String get sfxNeutralRecordingStopped => 'User stopped recording';

  @override
  String get sfxNeutralRecordingActive => 'Recording active in channel';

  @override
  String get sfxYouWereMoved => 'You were moved';

  @override
  String get sfxYouKickedChannel => 'You were kicked from a channel';

  @override
  String get sfxYouKickedServer => 'You were kicked from the server';

  @override
  String get sfxYouWereBanned => 'You were banned';

  @override
  String get sfxYouWerePoked => 'You were poked';

  @override
  String get sfxChatInbound => 'Incoming message';

  @override
  String get sfxChatOutbound => 'Message sent';

  @override
  String get sfxConnected => 'Connected';

  @override
  String get sfxDisconnected => 'Disconnected';

  @override
  String get sfxConnectionLost => 'Connection lost';

  @override
  String get sfxError => 'Error';

  @override
  String get sfxMicActivated => 'Mic activated';

  @override
  String get sfxMicMuted => 'Mic muted';

  @override
  String get sfxSoundMuted => 'Sound muted';

  @override
  String get sfxSoundResumed => 'Sound resumed';

  @override
  String get sfxAwayActivated => 'Away activated';

  @override
  String get sfxAwayDeactivated => 'Away deactivated';

  @override
  String get sfxChannelCreated => 'Channel created';

  @override
  String get sfxChannelDeleted => 'Channel deleted';

  @override
  String get sfxChannelEdited => 'Channel edited';

  @override
  String get sfxChannelMoved => 'Channel moved';

  @override
  String get sfxChannelgroupChanged => 'Channel group changed';

  @override
  String get sfxDefault => 'Default';

  @override
  String get sfxPreview => 'Preview';

  @override
  String get sfxSelectWav => 'Select WAV';

  @override
  String get sfxReset => 'Restore default';

  @override
  String get sfxImported => 'Custom sound saved.';

  @override
  String get sfxTooLong => 'Audio is too long (maximum 2 seconds).';

  @override
  String get sfxFormatError =>
      'Unsupported audio format. Use a PCM 16-bit or float32 WAV up to 2 seconds.';

  @override
  String get sfxImportFailed => 'Failed to save the custom sound.';

  @override
  String get poke => 'Poke';

  @override
  String get pokeHint => 'Message to send';

  @override
  String get pokeSent => 'Poke sent';

  @override
  String get pokeNotificationTitle => 'You were poked';

  @override
  String pokeNotificationBody(String name, String message) {
    return '$name poked you: $message';
  }

  @override
  String get send => 'Send';

  @override
  String get awayEnable => 'Set away';

  @override
  String get awayDisable => 'Back online';

  @override
  String get disconnected => 'Disconnected';

  @override
  String get disconnect => 'Disconnect';

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
  String get ports => 'Ports';

  @override
  String get portsHint =>
      'Leave empty to use the defaults (voice 9987, ServerQuery 10011, file transfer 30033, SSH 10022).';

  @override
  String get voicePort => 'Voice port';

  @override
  String get serverQueryPort => 'ServerQuery port';

  @override
  String get fileTransferPort => 'File transfer port';

  @override
  String get serverQuerySshPort => 'ServerQuery SSH port';

  @override
  String get invalidPort => 'Ports must be numbers between 1 and 65535.';

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

  @override
  String get ok => 'OK';

  @override
  String get channelPasswordTitle => 'Enter channel password';

  @override
  String get channelPasswordHint => 'Password';

  @override
  String get channelPasswordWrong => 'Wrong channel password';

  @override
  String get menuEnterChannel => 'Join channel';

  @override
  String get menuFileManager => 'File management';

  @override
  String get menuServerTitle => 'Server';

  @override
  String get menuCreateChannel => 'Create channel';

  @override
  String get menuEditChannel => 'Edit channel';

  @override
  String get menuDeleteChannel => 'Delete channel';

  @override
  String get channelCreateTitle => 'Create Channel';

  @override
  String get channelEditTitle => 'Edit Channel';

  @override
  String get channelNameLabel => 'Channel name';

  @override
  String get channelTopicLabel => 'Topic (optional)';

  @override
  String get channelPasswordHelper => 'Leave empty to clear';

  @override
  String get channelMaxClientsLabel => 'Max clients';

  @override
  String get channelMaxClientsHelper => 'Empty = unlimited';

  @override
  String get channelTypeLabel => 'Type';

  @override
  String get channelTypeTemporary => 'Temporary';

  @override
  String get channelTypeSemiPermanent => 'Semi-permanent';

  @override
  String get channelTypePermanent => 'Permanent';

  @override
  String get deleteChannelTitle => 'Delete channel?';

  @override
  String deleteChannelBody(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String deleteChannelOccupied(int count) {
    return 'This channel has $count clients — they will be moved to the default channel.';
  }

  @override
  String get channelCreated => 'Channel created';

  @override
  String get channelSaved => 'Channel updated';

  @override
  String get channelDeleted => 'Channel deleted';

  @override
  String get channelMoved => 'Channel moved';

  @override
  String get menuMoveUp => 'Move up';

  @override
  String get menuMoveDown => 'Move down';

  @override
  String get channelDescriptionLabel => 'Description';

  @override
  String get channelNeededTalkPowerLabel => 'Needed talk power';

  @override
  String get channelTalkPowerHelper => '0 = everyone may talk';

  @override
  String get channelDeleteDelayLabel => 'Delete delay (seconds)';

  @override
  String get channelDeleteDelayHelper =>
      'Seconds before an empty channel is removed';

  @override
  String get channelMaxFamilyLabel => 'Group user limit';

  @override
  String get channelMaxFamilyInherit => 'Inherit from parent';

  @override
  String get channelMaxFamilyUnlimited => 'Unlimited';

  @override
  String get channelMaxFamilyLimited => 'Custom limit';

  @override
  String get channelIsDefaultLabel => 'Default channel';

  @override
  String get audio => 'Audio';

  @override
  String get fmUp => 'Up';

  @override
  String get fmRootShort => '/';

  @override
  String get fmSearch => 'Search files';

  @override
  String get fmSearchHint => 'Search in this folder tree…';

  @override
  String get fmNoResults => 'No matches found';

  @override
  String get fmUploadFile => 'Upload file';

  @override
  String get fmUploadFolder => 'Upload folder';

  @override
  String get fmUploadDone => 'Upload finished';

  @override
  String get fmNewFolder => 'New folder';

  @override
  String get fmNewFolderName => 'Folder name';

  @override
  String get fmInvalidName => 'Invalid folder name';

  @override
  String get fmFolderCreated => 'Folder created';

  @override
  String get fmDownload => 'Download';

  @override
  String get fmDelete => 'Delete';

  @override
  String fmConfirmDeleteFile(String name) {
    return 'Delete file \"$name\"?';
  }

  @override
  String fmConfirmDeleteFolder(String name) {
    return 'Delete folder \"$name\" and ALL of its contents?';
  }

  @override
  String get fmDeleted => 'Deleted';

  @override
  String get fmSavedToDownloads => 'Saved to Downloads';

  @override
  String get fmNotConnected => 'Connect to a server to manage its files.';

  @override
  String get fmEmpty => 'Empty folder';

  @override
  String get fmRefresh => 'Refresh';

  @override
  String get fmCancelTransfer => 'Cancel transfer';

  @override
  String get fmTransfersTitle => 'Transfers';

  @override
  String get fmStateDone => 'Done';

  @override
  String get fmStateError => 'Failed';

  @override
  String get fmStateCanceled => 'Canceled';

  @override
  String get fmOperationFailed => 'Operation failed';

  @override
  String get fmClearHistory => 'Clear finished';

  @override
  String get fmPermDenied =>
      'The server has not granted file-transfer permissions';

  @override
  String get fmCanceled => 'Transfer canceled';

  @override
  String fmReasonPrefix(String reason) {
    return 'Operation failed: $reason';
  }

  @override
  String get channelsNoJoinPermission =>
      'You do not have permission to join this channel';

  @override
  String channelTalkPowerNeeded(int power) {
    return 'Talk power required: $power';
  }

  @override
  String get serverQuery => 'Server query client';

  @override
  String get serverQueryAdmin => 'Server query with admin rights';

  @override
  String get channelCommander => 'Channel commander';

  @override
  String get prioritySpeaker => 'Priority speaker';

  @override
  String get recording => 'Recording';

  @override
  String get talkPowerDenied => 'No talk power in this channel';

  @override
  String serverGroups(String groups) {
    return 'Groups: $groups';
  }

  @override
  String get menuMoveToChannel => 'Move to channel';

  @override
  String get menuKickFromChannel => 'Kick from channel';

  @override
  String get menuKickFromServer => 'Kick from server';

  @override
  String get menuBan => 'Ban';

  @override
  String get kickReasonHint => 'Reason (optional)';

  @override
  String get banReasonHint => 'Reason (optional — empty cancels)';

  @override
  String get banDurationLabel => 'Ban duration';

  @override
  String get banDurationPermanent => 'Permanent';

  @override
  String get banDuration1h => '1 hour';

  @override
  String get banDuration1d => '1 day';

  @override
  String get banDuration1w => '1 week';

  @override
  String get startKick => 'Kick';

  @override
  String get startBan => 'Ban';

  @override
  String get banCanceled => 'Ban canceled — no reason given';

  @override
  String get moveSucceeded => 'Move sent';

  @override
  String get kickSent => 'Kick sent';

  @override
  String get banSent => 'Ban sent';

  @override
  String get menuServerGroups => 'Grant permissions (server groups)';

  @override
  String get menuChannelGroups => 'Channel group';

  @override
  String get menuGrantRevokePerms => 'Grant / revoke permissions';

  @override
  String get grantPermission => 'Grant permission';

  @override
  String get revokePermission => 'Revoke permission';

  @override
  String permCurrent(String current) {
    return 'Current: $current';
  }

  @override
  String get permPresetTalkPower => 'Talk power';

  @override
  String get permPresetPrioritySpeaker => 'Priority speaker';

  @override
  String get permPresetChannelCommander => 'Channel commander';

  @override
  String get permChannelSection => 'Channel permissions';

  @override
  String get permServerSection => 'Server-wide permissions';

  @override
  String get permCustomSection => 'Custom permission';

  @override
  String get permCustomPermsid => 'perm id (e.g. i_client_whisper_power)';

  @override
  String get permCustomValue => 'value';

  @override
  String get channelGroupNone => 'No channel group';

  @override
  String get groupsNotLoaded => 'Group list not loaded yet';

  @override
  String get retry => 'Retry';

  @override
  String get dbIdUnavailable => 'Cannot get this user\'s database ID yet';

  @override
  String get permOpSucceeded => 'Permission change sent';

  @override
  String permOpFailed(String error) {
    return 'Permission change failed: $error';
  }

  @override
  String get permNotConnected => 'Not connected';

  @override
  String get permQueueFailed => 'Failed to queue the request';

  @override
  String get permTimeout => 'The server did not answer in time';

  @override
  String get permFailedUnknown => 'The server rejected the request';

  @override
  String get positionTitle => 'Set position';

  @override
  String get positionSelf => 'Me';

  @override
  String get positionHint =>
      'Drag to place them around you: up is in front of you, farther away is quieter. Plain stereo cannot tell front from back — distance carries that.';

  @override
  String get positionUnset => 'No position set — plays centered';

  @override
  String get positionReset => 'Reset position';
}
