import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ts_ffi.dart';

/// SFX kinds, mirroring the Rust mapping (see the `SFX_*` consts in
/// api.rs). Pack files reference kinds by these IDs — do not renumber.
class SfxKind {
  SfxKind._();

  static const int channelSwitched = 1;
  static const int neutralToCurrent = 2;
  static const int neutralAwayFromCurrent = 3;
  static const int youWereMoved = 4;
  static const int youKickedChannel = 5;
  static const int youKickedServer = 6;
  static const int youWereBanned = 7;
  static const int youWerePoked = 8;
  static const int chatInbound = 9;
  static const int chatOutbound = 10;
  static const int connected = 11;
  static const int disconnected = 12;
  static const int connectionLost = 13;
  static const int error = 14;
  static const int micActivated = 15;
  static const int micMuted = 16;
  static const int soundMuted = 17;
  static const int soundResumed = 18;
  static const int awayActivated = 19;
  static const int awayDeactivated = 20;
  static const int channelCreated = 21;
  static const int channelDeleted = 22;
  static const int channelEdited = 23;
  static const int channelMoved = 24;
  static const int channelgroupChanged = 25;
  static const int neutralConnConnected = 26;
  static const int neutralConnDisconnected = 27;
  static const int neutralConnConnectionLost = 28;
  static const int neutralMovedToCurrent = 29;
  static const int neutralMovedAwayFromCurrent = 30;
  static const int neutralKickedChannelToCurrent = 31;
  static const int neutralKickedChannelAwayFromCurrent = 32;
  static const int neutralKickedServer = 33;
  static const int neutralBannedServer = 34;
  static const int neutralRecordingStarted = 35;
  static const int neutralRecordingStopped = 36;
  static const int neutralRecordingActive = 37;

  static const List<int> all = [
    channelSwitched,
    neutralToCurrent,
    neutralAwayFromCurrent,
    youWereMoved,
    youKickedChannel,
    youKickedServer,
    youWereBanned,
    youWerePoked,
    chatInbound,
    chatOutbound,
    connected,
    disconnected,
    connectionLost,
    error,
    micActivated,
    micMuted,
    soundMuted,
    soundResumed,
    awayActivated,
    awayDeactivated,
    channelCreated,
    channelDeleted,
    channelEdited,
    channelMoved,
    channelgroupChanged,
    neutralConnConnected,
    neutralConnDisconnected,
    neutralConnConnectionLost,
    neutralMovedToCurrent,
    neutralMovedAwayFromCurrent,
    neutralKickedChannelToCurrent,
    neutralKickedChannelAwayFromCurrent,
    neutralKickedServer,
    neutralBannedServer,
    neutralRecordingStarted,
    neutralRecordingStopped,
    neutralRecordingActive,
  ];
}

/// Error codes returned by `ts_set_sfx_sample`.
class SfxError {
  SfxError._();

  static const int invalidKind = 1;
  static const int unsupportedFormat = 2;
  static const int emptyOrTooLong = 3;
}

/// Low-level channel-event sound handling: pushes WAV samples into the Rust
/// mixer, restores built-in samples, and plays previews.
///
/// The user-facing part of this feature is [SfxPackService], which manages
/// whole packs of sounds imported as zip archives.
class SfxService {
  SfxService._();

  /// Replace the active sample for a channel-event kind with [bytes]
  /// (a WAV file). Returns 0 on success, otherwise an [SfxError] code; on
  /// failure the previously active sample stays in place.
  static int setSample(int kind, Uint8List bytes) {
    final ptr = malloc<Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      return TsNative.setSfxSample(kind, ptr, bytes.length);
    } finally {
      malloc.free(ptr);
    }
  }

  /// Restore the built-in sample for a kind.
  static int clearSample(int kind) {
    return TsNative.clearSfxSample(kind);
  }

  /// Restore the built-in sample for every kind.
  static void clearAllSamples() {
    for (final kind in SfxKind.all) {
      TsNative.clearSfxSample(kind);
    }
  }

  /// Play the active sample for a kind immediately (settings-page preview).
  static int preview(int kind) {
    return TsNative.playSfx(kind);
  }
}
