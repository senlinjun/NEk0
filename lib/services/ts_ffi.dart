import 'dart:ffi';
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';

// Load the native Rust library
final DynamicLibrary _lib = _loadLib();

DynamicLibrary _loadLib() {
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libtsclient.so');
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

// ts_move_to_channel(channel_id) -> bool
typedef _MoveToChannelNative = Uint8 Function(Uint32);
typedef _MoveToChannelDart = int Function(int);

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

// ts_get_audio(buf: *mut f32, buf_len: u32) -> u32
typedef _GetAudioNative = Uint32 Function(Pointer<Float>, Uint32);
typedef _GetAudioDart = int Function(Pointer<Float>, int);

// ts_send_audio(data: *const f32, data_len: u32) -> bool
typedef _SendAudioNative = Uint8 Function(Pointer<Float>, Uint32);
typedef _SendAudioDart = int Function(Pointer<Float>, int);

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
    .lookupFunction<_IsConnectedNative, _IsConnectedDart>(
      'ts_is_voice_active',
    );
final _startAudio = _lib.lookupFunction<_StartAudioNative, _StartAudioDart>(
  'ts_start_audio',
);
final _stopAudio = _lib.lookupFunction<_StopAudioNative, _StopAudioDart>(
  'ts_stop_audio',
);
final _getAudio = _lib.lookupFunction<_GetAudioNative, _GetAudioDart>(
  'ts_get_audio',
);
final _sendAudio = _lib.lookupFunction<_SendAudioNative, _SendAudioDart>(
  'ts_send_audio',
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

  static bool moveToChannel(int channelId) {
    debugLog('moveToChannel($channelId)');
    final result = _moveToChannel(channelId) != 0;
    debugLog('moveToChannel -> $result');
    return result;
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

  static int getAudio(Pointer<Float> buf, int bufLen) {
    return _getAudio(buf, bufLen);
  }

  static bool sendAudio(Pointer<Float> data, int dataLen) {
    return _sendAudio(data, dataLen) != 0;
  }
}

void debugLog(String msg) {
  // ignore: avoid_print
  print('[TS FFI] $msg');
}
