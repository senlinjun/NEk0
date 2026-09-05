import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show File, Platform;

import 'package:ffi/ffi.dart';

// Load the native Rust library
final DynamicLibrary _lib = _loadLib();

DynamicLibrary _loadLib() {
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libtsclient.so');
  }
  if (Platform.isWindows) {
    // Bundled next to the exe (standard DLL search order finds it there).
    return DynamicLibrary.open('tsclient.dll');
  }
  if (Platform.isLinux) {
    // The Flutter Linux bundle lays out: <bundle>/nek0 + <bundle>/lib/.
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return DynamicLibrary.open('$exeDir/lib/libtsclient.so');
  }
  throw UnsupportedError('Platform not supported');
}

// ─── C function typedefs ────────────────────────────────────────────

// ts_connect(address, nickname, channel, password) -> *char (JSON)
typedef _ConnectNative =
    Pointer<Utf8> Function(
      Pointer<Utf8> address,
      Pointer<Utf8> nickname,
      Pointer<Utf8> channel,
      Pointer<Utf8> password,
    );
typedef _ConnectDart =
    Pointer<Utf8> Function(
      Pointer<Utf8> address,
      Pointer<Utf8> nickname,
      Pointer<Utf8> channel,
      Pointer<Utf8> password,
    );

// ts_disconnect() -> *char (JSON)
typedef _DisconnectNative = Pointer<Utf8> Function();
typedef _DisconnectDart = Pointer<Utf8> Function();

// ts_poll_events() -> *char (JSON array)
typedef _PollEventsNative = Pointer<Utf8> Function();
typedef _PollEventsDart = Pointer<Utf8> Function();

// ts_get_channels() -> *char (JSON array)
typedef _GetChannelsNative = Pointer<Utf8> Function();
typedef _GetChannelsDart = Pointer<Utf8> Function();

// ts_get_clients() -> *char (JSON array)
typedef _GetClientsNative = Pointer<Utf8> Function();
typedef _GetClientsDart = Pointer<Utf8> Function();

// ts_send_channel_message(channel_id, message) -> bool
typedef _SendChannelMsgNative = Uint8 Function(Uint32, Pointer<Utf8>);
typedef _SendChannelMsgDart = int Function(int, Pointer<Utf8>);

// ts_move_to_channel(channel_id, password) -> bool
// password: null/empty for unlocked channels; plaintext, hashed in Rust.
typedef _MoveToChannelNative = Uint8 Function(Uint32, Pointer<Utf8>);
typedef _MoveToChannelDart = int Function(int, Pointer<Utf8>);

// ts_set_muted(input_muted, output_muted) -> bool
typedef _SetMutedNative = Uint8 Function(Uint8, Uint8);
typedef _SetMutedDart = int Function(int, int);

// ts_is_connected() -> bool
typedef _IsConnectedNative = Uint8 Function();
typedef _IsConnectedDart = int Function();

// ts_set_vad_threshold(threshold: f32)
typedef _SetVadThresholdNative = Void Function(Float);
typedef _SetVadThresholdDart = void Function(double);

// ts_set_vad_enabled(enabled: bool) -> bool
typedef _SetVadEnabledNative = Uint8 Function(Uint8);
typedef _SetVadEnabledDart = int Function(int);

// ts_start_audio() -> bool
typedef _StartAudioNative = Uint8 Function();
typedef _StartAudioDart = int Function();

// ts_stop_audio()
typedef _StopAudioNative = Void Function();
typedef _StopAudioDart = void Function();

// ts_send_audio(data: *const f32, data_len: u32) -> bool
typedef _SendAudioNative = Uint8 Function(Pointer<Float>, Uint32);
typedef _SendAudioDart = int Function(Pointer<Float>, int);

// ts_set_mic_capture(enable: u8) -> u8 (desktop/iOS cpal capture toggle)
typedef _SetMicCaptureNative = Uint8 Function(Uint8);
typedef _SetMicCaptureDart = int Function(int);

// ts_get_mic_rms() -> f32 (RMS of the last native-capture mic block)
typedef _GetMicRmsNative = Float Function();
typedef _GetMicRmsDart = double Function();

// ts_get_audio_devices() -> *char (JSON {outputs:[{name,is_default}], inputs:[...]})
typedef _GetAudioDevicesNative = Pointer<Utf8> Function();
typedef _GetAudioDevicesDart = Pointer<Utf8> Function();

// ts_set_audio_output_device(name) / ts_set_audio_input_device(name) -> bool
typedef _SetAudioDeviceNative = Uint8 Function(Pointer<Utf8>);
typedef _SetAudioDeviceDart = int Function(Pointer<Utf8>);

// ts_set_identity(json: *const c_char)
typedef _SetIdentityNative = Void Function(Pointer<Utf8>);
typedef _SetIdentityDart = void Function(Pointer<Utf8>);

// ts_get_identity() -> *mut c_char (null if none set)
typedef _GetIdentityNative = Pointer<Utf8> Function();
typedef _GetIdentityDart = Pointer<Utf8> Function();

// ts_set_mic_gain(gain: f32)
typedef _SetMicGainNative = Void Function(Float);
typedef _SetMicGainDart = void Function(double);

// ts_set_client_volume(client_id: u16, volume_db: f32)
typedef _SetClientVolumeNative = Void Function(Uint16, Float);
typedef _SetClientVolumeDart = void Function(int, double);

// ts_set_sfx_sample(kind: u8, data: *const u8, len: usize) -> i32
// Returns: 0 ok, 1 invalid kind, 2 unsupported format, 3 empty/too long.
typedef _SetSfxSampleNative = Int32 Function(Uint8, Pointer<Uint8>, IntPtr);
typedef _SetSfxSampleDart = int Function(int, Pointer<Uint8>, int);

// ts_clear_sfx_sample(kind: u8) -> i32
typedef _ClearSfxSampleNative = Int32 Function(Uint8);
typedef _ClearSfxSampleDart = int Function(int);

// ts_play_sfx(kind: u8) -> i32
typedef _PlaySfxNative = Int32 Function(Uint8);
typedef _PlaySfxDart = int Function(int);

// ts_set_away(away: bool) -> bool
typedef _SetAwayNative = Uint8 Function(Uint8);
typedef _SetAwayDart = int Function(int);

// ts_send_poke(client_id: u16, message: *const c_char) -> bool
typedef _SendPokeNative = Uint8 Function(Uint16, Pointer<Utf8>);
typedef _SendPokeDart = int Function(int, Pointer<Utf8>);

// ts_kick_client(client_id: u16, from_server: u8, reason, token) -> bool
typedef _KickClientNative =
    Uint8 Function(Uint16, Uint8, Pointer<Utf8>, Pointer<Utf8>);
typedef _KickClientDart = int Function(int, int, Pointer<Utf8>, Pointer<Utf8>);

// ts_ban_client(client_id: u16, time_seconds: u32, reason, token) -> bool
typedef _BanClientNative =
    Uint8 Function(Uint16, Uint32, Pointer<Utf8>, Pointer<Utf8>);
typedef _BanClientDart = int Function(int, int, Pointer<Utf8>, Pointer<Utf8>);

// ts_move_client(client_id: u16, channel_id: u32, password, token) -> bool
typedef _MoveClientNative =
    Uint8 Function(Uint16, Uint32, Pointer<Utf8>, Pointer<Utf8>);
typedef _MoveClientDart = int Function(int, int, Pointer<Utf8>, Pointer<Utf8>);

// ─── Channel management ─────────────────────────────────────────────

// ts_channel_create(args_json, token) -> bool
typedef _ChannelCreateNative = Uint8 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _ChannelCreateDart = int Function(Pointer<Utf8>, Pointer<Utf8>);

// ts_channel_edit(channel_id: u32, args_json, token) -> bool
typedef _ChannelEditNative =
    Uint8 Function(Uint32, Pointer<Utf8>, Pointer<Utf8>);
typedef _ChannelEditDart = int Function(int, Pointer<Utf8>, Pointer<Utf8>);

// ts_channel_delete(channel_id: u32, force: u8, token) -> bool
typedef _ChannelDeleteNative = Uint8 Function(Uint32, Uint8, Pointer<Utf8>);
typedef _ChannelDeleteDart = int Function(int, int, Pointer<Utf8>);

// ts_channel_move(channel_id: u32, parent_id: u32, order: i64, token) -> bool
typedef _ChannelMoveNative =
    Uint8 Function(Uint32, Uint32, Int64, Pointer<Utf8>);
typedef _ChannelMoveDart = int Function(int, int, int, Pointer<Utf8>);

// ─── File transfer (channel file management) ────────────────────────

// ts_ft_list(channel_id, path, password, token) -> bool
typedef _FtListNative =
    Uint8 Function(Uint32, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FtListDart =
    int Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

// ts_ft_mkdir(channel_id, dirname, password, token) -> bool
typedef _FtMkDirNative =
    Uint8 Function(Uint32, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FtMkDirDart =
    int Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

// ts_ft_delete(channel_id, names_json, password, token) -> bool
typedef _FtDeleteNative =
    Uint8 Function(Uint32, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FtDeleteDart =
    int Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

// ts_ft_download(channel_id, remote_path, dest_local_path, password) -> task_id
typedef _FtDownloadNative =
    Uint32 Function(Uint32, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FtDownloadDart =
    int Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

// ts_ft_upload(channel_id, remote_path, src_local_path, password) -> task_id
typedef _FtUploadNative =
    Uint32 Function(Uint32, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FtUploadDart =
    int Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

// ts_ft_cancel(task_id) -> bool
typedef _FtCancelNative = Uint8 Function(Uint32);
typedef _FtCancelDart = int Function(int);

// ts_download_avatar(uid, dest_local_path) -> task_id
typedef _DownloadAvatarNative = Uint32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _DownloadAvatarDart = int Function(Pointer<Utf8>, Pointer<Utf8>);

// ─── Permission management ──────────────────────────────────────────

// ts_get_server_groups() / ts_get_channel_groups() -> *char (JSON array)
typedef _GetGroupsNative = Pointer<Utf8> Function();
typedef _GetGroupsDart = Pointer<Utf8> Function();

// ts_refresh_groups() -> bool
typedef _RefreshGroupsNative = Uint8 Function();
typedef _RefreshGroupsDart = int Function();

// ts_server_group_add_client(dbid: u64, sgid: u64, token) -> bool
typedef _SgAddClientNative = Uint8 Function(Uint64, Uint64, Pointer<Utf8>);
typedef _SgAddClientDart = int Function(int, int, Pointer<Utf8>);

// ts_server_group_del_client(dbid: u64, sgid: u64, token) -> bool
typedef _SgDelClientNative = Uint8 Function(Uint64, Uint64, Pointer<Utf8>);
typedef _SgDelClientDart = int Function(int, int, Pointer<Utf8>);

// ts_channel_group_set(dbid: u64, cid: u32, cgid: u64, token) -> bool
typedef _CgSetNative = Uint8 Function(Uint64, Uint32, Uint64, Pointer<Utf8>);
typedef _CgSetDart = int Function(int, int, int, Pointer<Utf8>);

// ts_channel_group_clear(dbid: u64, cid: u32, token) -> bool
typedef _CgClearNative = Uint8 Function(Uint64, Uint32, Pointer<Utf8>);
typedef _CgClearDart = int Function(int, int, Pointer<Utf8>);

// ts_channel_perm_grant(dbid: u64, cid: u32, permsid, value: i32, token) -> bool
typedef _PermGrantNative =
    Uint8 Function(Uint64, Uint32, Pointer<Utf8>, Int32, Pointer<Utf8>);
typedef _PermGrantDart =
    int Function(int, int, Pointer<Utf8>, int, Pointer<Utf8>);

// ts_channel_perm_revoke(dbid: u64, cid: u32, permsid, token) -> bool
typedef _PermRevokeNative =
    Uint8 Function(Uint64, Uint32, Pointer<Utf8>, Pointer<Utf8>);
typedef _PermRevokeDart = int Function(int, int, Pointer<Utf8>, Pointer<Utf8>);

// ts_server_perm_grant(dbid: u64, permsid, value: i32, token) -> bool
typedef _ServerPermGrantNative =
    Uint8 Function(Uint64, Pointer<Utf8>, Int32, Pointer<Utf8>);
typedef _ServerPermGrantDart =
    int Function(int, Pointer<Utf8>, int, Pointer<Utf8>);

// ts_server_perm_revoke(dbid: u64, permsid, token) -> bool
typedef _ServerPermRevokeNative =
    Uint8 Function(Uint64, Pointer<Utf8>, Pointer<Utf8>);
typedef _ServerPermRevokeDart = int Function(int, Pointer<Utf8>, Pointer<Utf8>);

// ts_get_own_perms() -> *char (JSON array of TsPerm)
typedef _GetOwnPermsNative = Pointer<Utf8> Function();
typedef _GetOwnPermsDart = Pointer<Utf8> Function();

// ─── Bindings ───────────────────────────────────────────────────────

final _connect = _lib.lookupFunction<_ConnectNative, _ConnectDart>(
  'ts_connect',
);
final _disconnect = _lib.lookupFunction<_DisconnectNative, _DisconnectDart>(
  'ts_disconnect',
);
final _pollEvents = _lib.lookupFunction<_PollEventsNative, _PollEventsDart>(
  'ts_poll_events',
);
final _getChannels = _lib.lookupFunction<_GetChannelsNative, _GetChannelsDart>(
  'ts_get_channels',
);
final _getClients = _lib.lookupFunction<_GetClientsNative, _GetClientsDart>(
  'ts_get_clients',
);
final _sendChannelMsg = _lib
    .lookupFunction<_SendChannelMsgNative, _SendChannelMsgDart>(
      'ts_send_channel_message',
    );
final _moveToChannel = _lib
    .lookupFunction<_MoveToChannelNative, _MoveToChannelDart>(
      'ts_move_to_channel',
    );
final _setMuted = _lib.lookupFunction<_SetMutedNative, _SetMutedDart>(
  'ts_set_muted',
);
final _isConnected = _lib.lookupFunction<_IsConnectedNative, _IsConnectedDart>(
  'ts_is_connected',
);
final _setVadThreshold = _lib
    .lookupFunction<_SetVadThresholdNative, _SetVadThresholdDart>(
      'ts_set_vad_threshold',
    );
final _setVadEnabled = _lib
    .lookupFunction<_SetVadEnabledNative, _SetVadEnabledDart>(
      'ts_set_vad_enabled',
    );
final _isVoiceActive = _lib
    .lookupFunction<_IsConnectedNative, _IsConnectedDart>('ts_is_voice_active');
final _startAudio = _lib.lookupFunction<_StartAudioNative, _StartAudioDart>(
  'ts_start_audio',
);
final _stopAudio = _lib.lookupFunction<_StopAudioNative, _StopAudioDart>(
  'ts_stop_audio',
);
final _sendAudio = _lib.lookupFunction<_SendAudioNative, _SendAudioDart>(
  'ts_send_audio',
);
final _setMicCapture = _lib
    .lookupFunction<_SetMicCaptureNative, _SetMicCaptureDart>(
      'ts_set_mic_capture',
    );
final _getMicRms = _lib.lookupFunction<_GetMicRmsNative, _GetMicRmsDart>(
  'ts_get_mic_rms',
);
final _getAudioDevices = _lib
    .lookupFunction<_GetAudioDevicesNative, _GetAudioDevicesDart>(
      'ts_get_audio_devices',
    );
final _setAudioOutputDevice = _lib
    .lookupFunction<_SetAudioDeviceNative, _SetAudioDeviceDart>(
      'ts_set_audio_output_device',
    );
final _setAudioInputDevice = _lib
    .lookupFunction<_SetAudioDeviceNative, _SetAudioDeviceDart>(
      'ts_set_audio_input_device',
    );
final _setIdentity = _lib.lookupFunction<_SetIdentityNative, _SetIdentityDart>(
  'ts_set_identity',
);
final _getIdentity = _lib.lookupFunction<_GetIdentityNative, _GetIdentityDart>(
  'ts_get_identity',
);
final _setMicGain = _lib.lookupFunction<_SetMicGainNative, _SetMicGainDart>(
  'ts_set_mic_gain',
);
final _setClientVolume = _lib
    .lookupFunction<_SetClientVolumeNative, _SetClientVolumeDart>(
      'ts_set_client_volume',
    );
final _setSfxSample = _lib
    .lookupFunction<_SetSfxSampleNative, _SetSfxSampleDart>(
      'ts_set_sfx_sample',
    );
final _clearSfxSample = _lib
    .lookupFunction<_ClearSfxSampleNative, _ClearSfxSampleDart>(
      'ts_clear_sfx_sample',
    );
final _playSfx = _lib.lookupFunction<_PlaySfxNative, _PlaySfxDart>(
  'ts_play_sfx',
);
final _setAway = _lib.lookupFunction<_SetAwayNative, _SetAwayDart>(
  'ts_set_away',
);
final _sendPoke = _lib.lookupFunction<_SendPokeNative, _SendPokeDart>(
  'ts_send_poke',
);
final _kickClient = _lib.lookupFunction<_KickClientNative, _KickClientDart>(
  'ts_kick_client',
);
final _banClient = _lib.lookupFunction<_BanClientNative, _BanClientDart>(
  'ts_ban_client',
);
final _moveClient = _lib.lookupFunction<_MoveClientNative, _MoveClientDart>(
  'ts_move_client',
);
final _channelCreate = _lib
    .lookupFunction<_ChannelCreateNative, _ChannelCreateDart>(
      'ts_channel_create',
    );
final _channelEdit = _lib.lookupFunction<_ChannelEditNative, _ChannelEditDart>(
  'ts_channel_edit',
);
final _channelDelete = _lib
    .lookupFunction<_ChannelDeleteNative, _ChannelDeleteDart>(
      'ts_channel_delete',
    );
final _channelMove = _lib.lookupFunction<_ChannelMoveNative, _ChannelMoveDart>(
  'ts_channel_move',
);
final _ftList = _lib.lookupFunction<_FtListNative, _FtListDart>('ts_ft_list');
final _ftMkDir = _lib.lookupFunction<_FtMkDirNative, _FtMkDirDart>(
  'ts_ft_mkdir',
);
final _ftDelete = _lib.lookupFunction<_FtDeleteNative, _FtDeleteDart>(
  'ts_ft_delete',
);
final _ftDownload = _lib.lookupFunction<_FtDownloadNative, _FtDownloadDart>(
  'ts_ft_download',
);
final _ftUpload = _lib.lookupFunction<_FtUploadNative, _FtUploadDart>(
  'ts_ft_upload',
);
final _ftCancel = _lib.lookupFunction<_FtCancelNative, _FtCancelDart>(
  'ts_ft_cancel',
);
final _downloadAvatar = _lib
    .lookupFunction<_DownloadAvatarNative, _DownloadAvatarDart>(
      'ts_download_avatar',
    );
final _getServerGroups = _lib.lookupFunction<_GetGroupsNative, _GetGroupsDart>(
  'ts_get_server_groups',
);
final _getChannelGroups = _lib.lookupFunction<_GetGroupsNative, _GetGroupsDart>(
  'ts_get_channel_groups',
);
final _refreshGroups = _lib
    .lookupFunction<_RefreshGroupsNative, _RefreshGroupsDart>(
      'ts_refresh_groups',
    );
final _getOwnPerms = _lib.lookupFunction<_GetOwnPermsNative, _GetOwnPermsDart>(
  'ts_get_own_perms',
);
final _sgAddClient = _lib.lookupFunction<_SgAddClientNative, _SgAddClientDart>(
  'ts_server_group_add_client',
);
final _sgDelClient = _lib.lookupFunction<_SgDelClientNative, _SgDelClientDart>(
  'ts_server_group_del_client',
);
final _cgSet = _lib.lookupFunction<_CgSetNative, _CgSetDart>(
  'ts_channel_group_set',
);
final _cgClear = _lib.lookupFunction<_CgClearNative, _CgClearDart>(
  'ts_channel_group_clear',
);
final _permGrant = _lib.lookupFunction<_PermGrantNative, _PermGrantDart>(
  'ts_channel_perm_grant',
);
final _permRevoke = _lib.lookupFunction<_PermRevokeNative, _PermRevokeDart>(
  'ts_channel_perm_revoke',
);
final _serverPermGrant = _lib
    .lookupFunction<_ServerPermGrantNative, _ServerPermGrantDart>(
      'ts_server_perm_grant',
    );
final _serverPermRevoke = _lib
    .lookupFunction<_ServerPermRevokeNative, _ServerPermRevokeDart>(
      'ts_server_perm_revoke',
    );

// ─── Helper ─────────────────────────────────────────────────────────

String _ptrToString(Pointer<Utf8> ptr) {
  try {
    return ptr.toDartString();
  } finally {
    // Use Rust's ts_free_string to free CString memory properly
    _freeString(ptr.cast());
  }
}

// ts_free_string frees memory allocated by Rust's CString::into_raw()
typedef _FreeStringNative = Void Function(Pointer<Void>);
typedef _FreeStringDart = void Function(Pointer<Void>);
final _freeString = _lib.lookupFunction<_FreeStringNative, _FreeStringDart>(
  'ts_free_string',
);

Pointer<Utf8> _strToPtr(String? s) {
  if (s == null) return Pointer<Utf8>.fromAddress(0);
  return s.toNativeUtf8();
}

// ─── Public API ─────────────────────────────────────────────────────

class TsNative {
  static String connect(
    String address,
    String nickname, {
    String? channel,
    String? password,
  }) {
    debugLog('connect($address, $nickname, ch=$channel)');
    final result = _connect(
      _strToPtr(address),
      _strToPtr(nickname),
      _strToPtr(channel),
      _strToPtr(password),
    );
    final str = _ptrToString(result);
    debugLog('connect -> $str');
    return str;
  }

  static String disconnect() {
    debugLog('disconnect()');
    final result = _ptrToString(_disconnect());
    debugLog('disconnect -> $result');
    return result;
  }

  static String pollEvents() {
    final result = _ptrToString(_pollEvents());
    // debugLog('pollEvents -> ${result.length > 200 ? result.substring(0, 200) + '...' : result}');
    return result;
  }

  static String getChannels() {
    return _ptrToString(_getChannels());
  }

  static String getClients() {
    return _ptrToString(_getClients());
  }

  static bool sendChannelMessage(int channelId, String message) {
    debugLog('sendChannelMessage(cid=$channelId, len=${message.length})');
    final result = _sendChannelMsg(channelId, _strToPtr(message));
    debugLog('sendChannelMessage -> $result');
    return result != 0;
  }

  static bool moveToChannel(int channelId, {String? password}) {
    debugLog(
      'moveToChannel($channelId, pw=${password == null ? 'no' : 'yes'})',
    );
    final ptr = _strToPtr(password ?? '');
    try {
      return _moveToChannel(channelId, ptr) != 0;
    } finally {
      malloc.free(ptr);
    }
  }

  static bool setMuted({required bool input, required bool output}) {
    debugLog('setMuted(inp=$input, out=$output)');
    final result = _setMuted(input ? 1 : 0, output ? 1 : 0) != 0;
    debugLog('setMuted -> $result');
    return result;
  }

  static bool isConnected() {
    return _isConnected() != 0;
  }

  static void setIdentity(String json) {
    final ptr = _strToPtr(json);
    _setIdentity(ptr);
    malloc.free(ptr);
  }

  static String? getIdentity() {
    final ptr = _getIdentity();
    if (ptr == nullptr) return null;
    try {
      return ptr.toDartString();
    } finally {
      _freeString(ptr.cast());
    }
  }

  static void setVadThreshold(double threshold) {
    _setVadThreshold(threshold);
  }

  static bool setVadEnabled(bool enabled) {
    return _setVadEnabled(enabled ? 1 : 0) != 0;
  }

  static bool isVoiceActive() {
    return _isVoiceActive() != 0;
  }

  static bool startAudio() {
    debugLog('startAudio');
    return _startAudio() != 0;
  }

  static void stopAudio() {
    debugLog('stopAudio');
    _stopAudio();
  }

  static bool sendAudio(Pointer<Float> data, int dataLen) {
    return _sendAudio(data, dataLen) != 0;
  }

  /// Toggles the native (cpal) microphone capture stream — desktop / iOS
  /// only; Android captures through its Kotlin EventChannel instead.
  /// Returns true when the stream is in the requested state.
  static bool setMicCapture(bool enable) {
    return _setMicCapture(enable ? 1 : 0) != 0;
  }

  /// RMS (0..1) of the most recent native-capture mic block. Android
  /// reports levels from its own EventChannel data instead.
  static double getMicRms() {
    return _getMicRms();
  }

  /// Host audio devices for the picker UI (desktop). Shape:
  /// `{"outputs":[{"name","is_default"}],"inputs":[...]}` — empty arrays
  /// where enumeration is unsupported (Android).
  static Map<String, dynamic> getAudioDevices() {
    final str = _ptrToString(_getAudioDevices());
    return jsonDecode(str) as Map<String, dynamic>;
  }

  /// Selects the output device by name ('' = system default). Applied to
  /// the running stream within 500ms while connected.
  static bool setAudioOutputDevice(String name) {
    final ptr = _strToPtr(name);
    try {
      return _setAudioOutputDevice(ptr) != 0;
    } finally {
      malloc.free(ptr);
    }
  }

  /// Selects the input (mic) device by name ('' = system default). A
  /// running capture stream restarts immediately.
  static bool setAudioInputDevice(String name) {
    final ptr = _strToPtr(name);
    try {
      return _setAudioInputDevice(ptr) != 0;
    } finally {
      malloc.free(ptr);
    }
  }

  static void setMicGain(double gain) {
    debugLog('setMicGain($gain)');
    _setMicGain(gain);
  }

  static void setClientVolume(int clientId, double volumeDb) {
    _setClientVolume(clientId, volumeDb);
  }

  /// Install a custom WAV sample for an SFX kind (1..=25, see SfxKind).
  /// Returns 0 on success; see the typedef above for error codes.
  static int setSfxSample(int kind, Pointer<Uint8> data, int len) {
    return _setSfxSample(kind, data, len);
  }

  /// Restore the built-in sample for an SFX kind. Returns 0 on success, 1
  /// for an invalid kind.
  static int clearSfxSample(int kind) {
    return _clearSfxSample(kind);
  }

  /// Play the active sample for an SFX kind immediately (preview).
  /// Returns 0 on success, 1 for an invalid kind.
  static int playSfx(int kind) {
    return _playSfx(kind);
  }

  /// Set our own away state (server echo drives the away sounds).
  static bool setAway(bool away) {
    debugLog('setAway($away)');
    return _setAway(away ? 1 : 0) != 0;
  }

  /// Poke another client. Returns true when the request was queued.
  static bool sendPoke(int clientId, String message) {
    debugLog('sendPoke(client=$clientId, len=${message.length})');
    final ptr = _strToPtr(message);
    try {
      return _sendPoke(clientId, ptr) != 0;
    } finally {
      malloc.free(ptr);
    }
  }

  /// Kick a client from the current channel ([fromServer] == false) or from
  /// the whole server ([fromServer] == true). An empty [reason] cancels the
  /// kick (the Rust side treats it as a no-op). [token] is optional: when
  /// non-empty the server's answer resolves as a `perm_op` event carrying it.
  static bool kickClient(
    int clientId, {
    required bool fromServer,
    String reason = '',
    String token = '',
  }) {
    debugLog('kickClient(client=$clientId, fromServer=$fromServer)');
    final ptr = _strToPtr(reason);
    final t = _strToPtr(token);
    try {
      return _kickClient(clientId, fromServer ? 1 : 0, ptr, t) != 0;
    } finally {
      malloc.free(ptr);
      malloc.free(t);
    }
  }

  /// Ban a client. [timeSeconds] == 0 means an indefinite (permanent) ban.
  /// [token] is optional (see [kickClient]).
  static bool banClient(
    int clientId, {
    required int timeSeconds,
    String reason = '',
    String token = '',
  }) {
    debugLog('banClient(client=$clientId, time=$timeSeconds)');
    final ptr = _strToPtr(reason);
    final t = _strToPtr(token);
    try {
      return _banClient(clientId, timeSeconds, ptr, t) != 0;
    } finally {
      malloc.free(ptr);
      malloc.free(t);
    }
  }

  /// Move a client (or ourselves) to another channel. [password] is used for
  /// locked target channels. [token] is optional (see [kickClient]).
  static bool moveClient(
    int clientId,
    int channelId, {
    String? password,
    String token = '',
  }) {
    debugLog('moveClient(client=$clientId, channel=$channelId)');
    final ptr = _strToPtr(password);
    final t = _strToPtr(token);
    try {
      return _moveClient(clientId, channelId, ptr, t) != 0;
    } finally {
      malloc.free(ptr);
      malloc.free(t);
    }
  }

  /// Creates a channel. [args] is a `ChannelArgs` map (see native/src/lib.rs):
  /// parent_id, name (required), topic, password, description, max_clients,
  /// max_family_clients (-1 inherited / 0 unlimited / >0 limit), is_permanent,
  /// is_semi_permanent, is_default, delete_delay (seconds). [token] is
  /// required: the server's answer resolves as a `perm_op` event carrying it.
  /// Returns true when the request was queued.
  static bool createChannel(
    Map<String, Object?> args, {
    required String token,
  }) {
    debugLog('createChannel(${args['name']})');
    final ptr = _strToPtr(jsonEncode(args));
    final tok = _strToPtr(token);
    try {
      return _channelCreate(ptr, tok) != 0;
    } finally {
      malloc.free(ptr);
      malloc.free(tok);
    }
  }

  /// Edits channel properties. [args] is a `ChannelArgs` map (see
  /// native/src/lib.rs); absent keys are left untouched, empty strings clear
  /// topic/description/password, 'order' (sibling id, 0 = first) repositions
  /// the channel. [token] is required (see [createChannel]). Returns true
  /// when the request was queued.
  static bool editChannel(
    int channelId,
    Map<String, Object?> args, {
    required String token,
  }) {
    debugLog('editChannel(channel=$channelId, keys=${args.keys.toList()})');
    final ptr = _strToPtr(jsonEncode(args));
    final tok = _strToPtr(token);
    try {
      return _channelEdit(channelId, ptr, tok) != 0;
    } finally {
      malloc.free(ptr);
      malloc.free(tok);
    }
  }

  /// Deletes a channel. [force] also removes a channel that still has
  /// clients in it (requires the force-delete permission). [token] is
  /// required (see [createChannel]). Returns true when the request was queued.
  static bool deleteChannel(
    int channelId, {
    required bool force,
    required String token,
  }) {
    debugLog('deleteChannel(channel=$channelId, force=$force)');
    final tok = _strToPtr(token);
    try {
      return _channelDelete(channelId, force ? 1 : 0, tok) != 0;
    } finally {
      malloc.free(tok);
    }
  }

  /// Moves a channel to another parent (also re-orders within the same
  /// parent). [order] is the sibling id the channel comes after (0 = first,
  /// null = server default / append at the end). [token] is required
  /// (see [createChannel]). Returns true when the request was queued.
  static bool moveChannelTo(
    int channelId, {
    required int parentId,
    int? order,
    required String token,
  }) {
    debugLog(
      'moveChannelTo(channel=$channelId, parent=$parentId, order=$order)',
    );
    final tok = _strToPtr(token);
    try {
      return _channelMove(channelId, parentId, order ?? -1, tok) != 0;
    } finally {
      malloc.free(tok);
    }
  }

  // ─── File transfers ────────────────────────────────────────────────

  /// Requests a directory listing for a channel's file area. The answer
  /// arrives asynchronously as an `ft_listing` event carrying [token].
  static bool ftListToken(
    int channelId,
    String path,
    String token, {
    String? password,
  }) {
    final p = _strToPtr(path);
    final pw = _strToPtr(password);
    final t = _strToPtr(token);
    try {
      return _ftList(channelId, p, pw, t) != 0;
    } finally {
      malloc.free(p);
      malloc.free(pw);
      malloc.free(t);
    }
  }

  /// Creates a directory in a channel's file area. Returns true when the
  /// request was queued; the real outcome arrives as an `ft_op` event
  /// carrying [token].
  static bool ftMkDir(
    int channelId,
    String dirname,
    String token, {
    String? password,
  }) {
    debugLog('ftMkDir(cid=$channelId, dir=$dirname)');
    final pd = _strToPtr(dirname);
    final pw = _strToPtr(password);
    final pt = _strToPtr(token);
    try {
      return _ftMkDir(channelId, pd, pw, pt) != 0;
    } finally {
      malloc.free(pd);
      malloc.free(pw);
      malloc.free(pt);
    }
  }

  /// Deletes entries (files and/or folders — folders are removed
  /// recursively by the server). Paths must be COMPLETE remote addresses.
  /// Returns true when queued; the outcome arrives as `ft_op` with [token].
  static bool ftDelete(
    int channelId,
    List<String> fullPaths,
    String token, {
    String? password,
  }) {
    debugLog('ftDelete(cid=$channelId, names=${fullPaths.length})');
    final json = jsonEncode(fullPaths);
    final pj = _strToPtr(json);
    final pw = _strToPtr(password);
    final pt = _strToPtr(token);
    try {
      return _ftDelete(channelId, pj, pw, pt) != 0;
    } finally {
      malloc.free(pj);
      malloc.free(pw);
      malloc.free(pt);
    }
  }

  /// Starts downloading a remote file to a local absolute path. Returns a
  /// task id for progress/cancel tracking, or 0 when the request could not
  /// be queued at all.
  static int ftDownload(
    int channelId,
    String remotePath,
    String destLocalPath, {
    String? password,
  }) {
    debugLog('ftDownload(cid=$channelId, $remotePath)');
    final p = _strToPtr(remotePath);
    final d = _strToPtr(destLocalPath);
    final pw = _strToPtr(password);
    try {
      return _ftDownload(channelId, p, d, pw);
    } finally {
      malloc.free(p);
      malloc.free(d);
      malloc.free(pw);
    }
  }

  /// Starts uploading a local file to a remote path. Returns a task id or 0.
  static int ftUpload(
    int channelId,
    String remotePath,
    String srcLocalPath, {
    String? password,
  }) {
    debugLog('ftUpload(cid=$channelId, $remotePath)');
    final p = _strToPtr(remotePath);
    final s = _strToPtr(srcLocalPath);
    final pw = _strToPtr(password);
    try {
      return _ftUpload(channelId, p, s, pw);
    } finally {
      malloc.free(p);
      malloc.free(s);
      malloc.free(pw);
    }
  }

  /// Cancels an active transfer task (cooperative — some bytes may already
  /// be on disk / on the wire).
  static bool ftCancel(int taskId) => _ftCancel(taskId) != 0;

  /// Starts downloading a client's avatar to a local absolute path. Returns
  /// a task id for completion tracking, or 0 when the request could not
  /// start (not connected / malformed uid).
  static int downloadAvatar(String uid, String destLocalPath) {
    debugLog('downloadAvatar($uid)');
    final u = _strToPtr(uid);
    final d = _strToPtr(destLocalPath);
    try {
      return _downloadAvatar(u, d);
    } finally {
      malloc.free(u);
      malloc.free(d);
    }
  }

  // ─── Permission management ────────────────────────────────────────

  /// All server groups known locally (JSON array; empty until the group
  /// lists were answered by the server).
  static List<Map<String, dynamic>> getServerGroups() {
    final str = _ptrToString(_getServerGroups());
    return (jsonDecode(str) as List).cast<Map<String, dynamic>>();
  }

  /// All channel groups known locally (JSON array).
  static List<Map<String, dynamic>> getChannelGroups() {
    final str = _ptrToString(_getChannelGroups());
    return (jsonDecode(str) as List).cast<Map<String, dynamic>>();
  }

  /// Re-request the server/channel group lists. Returns true when queued.
  static bool refreshGroups() => _refreshGroups() != 0;

  /// OUR OWN directly-assigned permissions from `clientpermlist`. See
  /// [perm.dart] `TsPerm` — only directly-assigned values are returned.
  static List<Map<String, dynamic>> getOwnPerms() {
    final str = _ptrToString(_getOwnPerms());
    return (jsonDecode(str) as List).cast<Map<String, dynamic>>();
  }

  /// Add a client (by database id) to a server group. The outcome arrives
  /// as a `perm_op` event carrying [token].
  static bool serverGroupAddClient(int dbid, int sgid, String token) {
    final t = _strToPtr(token);
    try {
      return _sgAddClient(dbid, sgid, t) != 0;
    } finally {
      malloc.free(t);
    }
  }

  /// Remove a client from a server group.
  static bool serverGroupDelClient(int dbid, int sgid, String token) {
    final t = _strToPtr(token);
    try {
      return _sgDelClient(dbid, sgid, t) != 0;
    } finally {
      malloc.free(t);
    }
  }

  /// Set a client's channel group in a channel.
  static bool channelGroupSet(int dbid, int cid, int cgid, String token) {
    final t = _strToPtr(token);
    try {
      return _cgSet(dbid, cid, cgid, t) != 0;
    } finally {
      malloc.free(t);
    }
  }

  /// Clear a client's channel group in a channel.
  static bool channelGroupClear(int dbid, int cid, String token) {
    final t = _strToPtr(token);
    try {
      return _cgClear(dbid, cid, t) != 0;
    } finally {
      malloc.free(t);
    }
  }

  /// Grant a channel-scoped permission (`permsid`, e.g.
  /// `i_client_talk_power`) to a client with the given value.
  static bool channelPermGrant(
    int dbid,
    int cid,
    String permsid,
    int value,
    String token,
  ) {
    final p = _strToPtr(permsid);
    final t = _strToPtr(token);
    try {
      return _permGrant(dbid, cid, p, value, t) != 0;
    } finally {
      malloc.free(p);
      malloc.free(t);
    }
  }

  /// Revoke a channel-scoped permission from a client.
  static bool channelPermRevoke(
    int dbid,
    int cid,
    String permsid,
    String token,
  ) {
    final p = _strToPtr(permsid);
    final t = _strToPtr(token);
    try {
      return _permRevoke(dbid, cid, p, t) != 0;
    } finally {
      malloc.free(p);
      malloc.free(t);
    }
  }

  /// Grant a server-wide permission (`permsid`, e.g. `i_client_talk_power`)
  /// to a client with the given value — applies everywhere, not just one
  /// channel. The outcome arrives as a `perm_op` event carrying [token].
  static bool serverPermGrant(
    int dbid,
    String permsid,
    int value,
    String token,
  ) {
    final p = _strToPtr(permsid);
    final t = _strToPtr(token);
    try {
      return _serverPermGrant(dbid, p, value, t) != 0;
    } finally {
      malloc.free(p);
      malloc.free(t);
    }
  }

  /// Revoke a server-wide permission from a client.
  static bool serverPermRevoke(int dbid, String permsid, String token) {
    final p = _strToPtr(permsid);
    final t = _strToPtr(token);
    try {
      return _serverPermRevoke(dbid, p, t) != 0;
    } finally {
      malloc.free(p);
      malloc.free(t);
    }
  }
}

void debugLog(String msg) {
  // ignore: avoid_print
  print('[TS FFI] $msg');
}
