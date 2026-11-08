import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'sfx_service.dart';

/// Outcome of a pick: [code] is 0 when the sound was stored, one of the
/// [SfxError] codes for a rejected WAV, or [cancelled] when the user
/// aborted the picker (no UI error wanted). [name] is the display name of
/// the picked file, only set when [code] == 0.
class EntrySoundPickResult {
  final int code;
  final String? name;

  const EntrySoundPickResult(this.code, this.name);
}

/// Picks, stores and previews the user-configurable ENTRY SOUND — played
/// automatically when a connection to a server is established. One global
/// sound; the trigger lives in TsConnectionNotifier's `connected` handler.
///
/// Mirrors [BackgroundService]: the picked file is copied into the app's
/// private documents directory (`<docs>/entry_sounds/default.wav`) so it
/// survives restarts without any storage permission (the picker uses SAF).
/// The display name is persisted by EntrySoundSettingsNotifier; the file
/// itself is the source of truth for "configured".
class EntrySoundService {
  EntrySoundService._();

  static const _soundDir = 'entry_sounds';
  static const _soundFile = 'default.wav';
  static const cancelled = -1;

  static Future<Directory> _directory() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_soundDir');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Absolute path of the stored entry sound, or null when none exists.
  static Future<String?> soundPath() async {
    final file = File('${(await _directory()).path}/$_soundFile');
    return await file.exists() ? file.path : null;
  }

  /// Opens the WAV picker and copies the chosen file into the private
  /// documents directory. The file is validated by installing it as the
  /// SFX kind-38 sample (which also preloads the local preview) — an
  /// invalid WAV is rejected without touching the stored file.
  static Future<EntrySoundPickResult> pickAndStore() async {
    PlatformFile? file;
    try {
      file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['wav'],
      );
    } catch (_) {
      return const EntrySoundPickResult(cancelled, null); // picker failed
    }
    if (file == null) {
      return const EntrySoundPickResult(cancelled, null); // user cancelled
    }
    Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      return const EntrySoundPickResult(cancelled, null);
    }
    final rc = SfxService.setSample(SfxKind.entrySound, bytes);
    if (rc != 0) {
      return EntrySoundPickResult(rc, null);
    }
    final target = File('${(await _directory()).path}/$_soundFile');
    await target.writeAsBytes(bytes, flush: true);
    return EntrySoundPickResult(0, file.name);
  }

  /// Deletes the stored sound and drops the preloaded preview sample. The
  /// persisted display name is cleared by the caller (settings provider).
  static Future<void> clear() async {
    final file = File('${(await _directory()).path}/$_soundFile');
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {
        // A file that cannot be deleted must not block clearing the
        // setting — a dangling name just means no sound plays.
      }
    }
    SfxService.clearSample(SfxKind.entrySound);
  }

  /// Plays the stored sound through the local output (settings preview).
  /// Returns 0 on success, one of the [SfxError] codes otherwise (the
  /// sample is re-read from disk, so a vanished file surfaces as a decode
  /// failure). The sound plays even with no connection — ts_play_sfx
  /// starts the output stream on demand.
  static Future<int> preview() async {
    final path = await soundPath();
    if (path == null) {
      return SfxError.emptyOrTooLong;
    }
    final bytes = await File(path).readAsBytes();
    final rc = SfxService.setSample(SfxKind.entrySound, bytes);
    if (rc != 0) {
      return rc;
    }
    return SfxService.preview(SfxKind.entrySound);
  }
}
