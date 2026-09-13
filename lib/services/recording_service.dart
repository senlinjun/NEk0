import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'foreground_service.dart';
import 'ts_ffi.dart';

/// One WAV file the Rust recorder produced (temp location).
class RecordingFile {
  /// Absolute path of the temp file Rust wrote.
  final String path;

  /// Client id of the track; 0 for the mixed file and for our own mic.
  final int clientId;

  final String? uid;

  /// Track nickname ('' for the mixed file).
  final String name;

  /// true = the single mixed file, false = one per-user track.
  final bool mixed;

  const RecordingFile({
    required this.path,
    required this.clientId,
    required this.uid,
    required this.name,
    required this.mixed,
  });

  factory RecordingFile.fromJson(Map<String, dynamic> j) => RecordingFile(
    path: j['path'] as String? ?? '',
    clientId: (j['client_id'] as int?) ?? 0,
    uid: j['uid'] as String?,
    name: j['name'] as String? ?? '',
    mixed: (j['mixed'] as bool?) ?? false,
  );
}

/// Status snapshot from `ts_get_recording_status`.
class RecordingStatus {
  final bool recording;
  final bool hold;
  final int backtrackSecs;
  final int availableSecs;
  final int recordingSecs;
  final List<RecordingStatusTrack> tracks;

  const RecordingStatus({
    required this.recording,
    required this.hold,
    required this.backtrackSecs,
    required this.availableSecs,
    required this.recordingSecs,
    required this.tracks,
  });

  factory RecordingStatus.fromJson(Map<String, dynamic> j) => RecordingStatus(
    recording: (j['recording'] as bool?) ?? false,
    hold: (j['hold'] as bool?) ?? false,
    backtrackSecs: (j['backtrack_secs'] as int?) ?? 0,
    availableSecs: (j['available_secs'] as int?) ?? 0,
    recordingSecs: (j['recording_secs'] as int?) ?? 0,
    tracks: ((j['tracks'] as List?) ?? const [])
        .map((t) => RecordingStatusTrack.fromJson(t as Map<String, dynamic>))
        .toList(),
  );
}

class RecordingStatusTrack {
  /// 0 = our own microphone track.
  final int clientId;
  final String? uid;
  final String name;

  const RecordingStatusTrack({
    required this.clientId,
    required this.uid,
    required this.name,
  });

  factory RecordingStatusTrack.fromJson(Map<String, dynamic> j) =>
      RecordingStatusTrack(
        clientId: (j['client_id'] as int?) ?? 0,
        uid: j['uid'] as String?,
        name: j['name'] as String? ?? '',
      );
}

/// Result of a completed export: where each file ended up.
class SavedRecording {
  final RecordingFile file;
  final String destination;

  const SavedRecording({required this.file, required this.destination});
}

/// Raised by [RecordingService.saveAndExport] when the Rust save failed or
/// produced no usable files.
class RecordingException implements Exception {
  final String reason;
  RecordingException(this.reason);
  @override
  String toString() => reason;
}

/// Bridges the Rust multi-track recorder to the UI:
/// - tracks the recording on/off flag pushed via `recording_state` events,
/// - resolves save requests against `recording_saved` /
///   `recording_save_failed` events,
/// - moves the resulting temp WAVs into the user-visible Downloads folder.
class RecordingService extends ChangeNotifier {
  RecordingService._();
  static final RecordingService instance = RecordingService._();

  bool _recording = false;
  bool get recording => _recording;

  /// Temp directory the Rust core auto-saves an interrupted recording into.
  static const _autoSaveDirName = 'nek0_recordings';

  /// Persisted save location for exported recordings: '' = the default
  /// Downloads/NEk0/Recordings. Android stores a SAF tree URI, desktop an
  /// absolute directory path. Written by the settings screen.
  static const prefKeySaveDir = 'recording_save_dir';

  Completer<List<RecordingFile>>? _saveWaiter;

  /// (Re)applies the recorder config: backtrack window from [minutes] plus
  /// the auto-save work dir. Called on connect and when the setting changes
  /// (Rust treats an already-armed recorder as "update only", so a live
  /// session keeps its buffered audio).
  static Future<void> applyConfig({required int minutes}) async {
    final tmp = await getTemporaryDirectory();
    TsNative.setRecordingConfig(
      (minutes.clamp(1, 60)) * 60,
      '${tmp.path}/$_autoSaveDirName',
    );
  }

  /// Set when a recording was auto-saved because the connection dropped
  /// (Rust saved separate tracks into its temp dir and reported them with
  /// reason "disconnected"). The server-list screen toasts this once and
  /// clears it — the service itself has no context for localized UI.
  int? pendingAutoExportCount;
  String? pendingAutoExportError;

  /// Called by TsConnectionNotifier's event dispatch loop.
  void handleEvent(Map<String, dynamic> event) {
    switch (event['type'] as String?) {
      case 'recording_state':
        final active = (event['recording'] as bool?) ?? false;
        if (active != _recording) {
          _recording = active;
          notifyListeners();
        }
      case 'recording_saved':
        final reason = event['reason'] as String? ?? 'manual';
        final files = ((event['files'] as List?) ?? const [])
            .map((f) => RecordingFile.fromJson(f as Map<String, dynamic>))
            .toList();
        if (_saveWaiter != null) {
          _saveWaiter!.complete(files);
          _saveWaiter = null;
        } else if (reason == 'disconnected' && files.isNotEmpty) {
          // No dialog was possible (connection already gone): export the
          // separate tracks ourselves and leave a message for the UI.
          _exportAutoSave(files);
        }
      case 'recording_save_failed':
        final reason = event['reason'] as String? ?? 'manual';
        final error = event['error'] as String? ?? 'unknown error';
        if (_saveWaiter != null) {
          _saveWaiter!.completeError(RecordingException(error));
          _saveWaiter = null;
        } else if (reason == 'disconnected') {
          pendingAutoExportError = error;
          notifyListeners();
        }
    }
  }

  Future<void> _exportAutoSave(List<RecordingFile> files) async {
    final folder = saveFolderName();
    try {
      var count = 0;
      for (final f in files) {
        final name = f.name.isEmpty ? 'track_${f.clientId}' : f.name;
        final dest = await _exportOne(f.path, '$name.wav', folder);
        if (dest != null) count++;
      }
      pendingAutoExportCount = count > 0 ? count : null;
      if (count == 0) pendingAutoExportError = 'export failed';
    } catch (e) {
      pendingAutoExportError = e.toString();
    } finally {
      _cleanupTempDirs();
      notifyListeners();
    }
  }

  /// Deletes the temp directories Rust wrote recordings into.
  void _cleanupTempDirs() {
    getTemporaryDirectory()
        .then((tmp) async {
          await for (final e in tmp.list()) {
            final name = e.path.split(Platform.pathSeparator).last;
            if (name.startsWith('nek0_recording_') ||
                name == 'nek0_recordings') {
              try {
                await e.delete(recursive: true);
              } catch (_) {}
            }
          }
        })
        .catchError((_) {});
  }

  /// Clears UI state on disconnect (the Rust side already auto-saved and
  /// discarded its buffers). Files from a disconnect auto-save are exported
  /// by the last save request only; nothing is tracked here.
  void reset() {
    if (_recording) {
      _recording = false;
      notifyListeners();
    }
  }

  /// Snapshot of the recorder state (recording flag, track list).
  RecordingStatus status() {
    try {
      return RecordingStatus.fromJson(
        jsonDecode(TsNative.getRecordingStatus()) as Map<String, dynamic>,
      );
    } catch (e) {
      debugPrint('RecordingService: status parse error: $e');
      return const RecordingStatus(
        recording: false,
        hold: false,
        backtrackSecs: 0,
        availableSecs: 0,
        recordingSecs: 0,
        tracks: [],
      );
    }
  }

  /// Saves a window through Rust, then copies the produced WAVs into the
  /// configured save location and deletes the temp files.
  ///
  /// [windowMs] == 0 saves the whole stopped recording, otherwise the
  /// trailing window. [mixed] picks one combined file vs one per user.
  /// [mixedDisplayName] names the mixed file (localized + timestamped by the
  /// caller); per-user files use their track nickname. Returns one entry per
  /// exported file for the success toast.
  Future<List<SavedRecording>> saveAndExport({
    required int windowMs,
    required bool mixed,
    required String mixedDisplayName,
  }) async {
    final tmpDir = await getTemporaryDirectory();
    final dir =
        '${tmpDir.path}/nek0_recording_${DateTime.now().millisecondsSinceEpoch}';
    // Reject early when Rust cannot even start the job (busy / no data).
    if (!TsNative.saveRecording(windowMs, mixed ? 0 : 1, dir)) {
      throw RecordingException('save not started');
    }
    final waiter = Completer<List<RecordingFile>>();
    _saveWaiter = waiter;
    List<RecordingFile> files;
    try {
      files = await waiter.future.timeout(const Duration(minutes: 5));
    } on TimeoutException {
      _saveWaiter = null;
      throw RecordingException('save timed out');
    } finally {
      if (_saveWaiter == waiter) _saveWaiter = null;
    }

    final exported = <SavedRecording>[];
    final folder = saveFolderName();
    try {
      for (final f in files) {
        final name = f.mixed
            ? mixedDisplayName
            : (f.name.isEmpty ? 'track_${f.clientId}' : f.name);
        final dest = await _exportOne(f.path, '$name.wav', folder);
        if (dest == null) {
          throw RecordingException('cannot write to the save location');
        }
        exported.add(SavedRecording(file: f, destination: dest));
      }
    } finally {
      // The temp copies have served their purpose either way.
      _cleanupTempDirs();
    }
    if (exported.isEmpty) {
      throw RecordingException('no files');
    }
    return exported;
  }

  /// Name of the per-save subfolder created inside the save location, so
  /// every save groups its files under its own date+time stamp
  /// ("20260913_153045" — colon-free so it works on Windows).
  static String saveFolderName() {
    final n = DateTime.now();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${p2(n.month)}${p2(n.day)}_${p2(n.hour)}${p2(n.minute)}${p2(n.second)}';
  }

  /// Exports one file according to the configured save location, into the
  /// per-save [folder], falling back to the default Downloads folder when
  /// the custom one fails (e.g. a revoked SAF permission).
  static Future<String?> _exportOne(
    String srcPath,
    String displayName,
    String folder,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final custom = prefs.getString(prefKeySaveDir) ?? '';
    if (custom.isNotEmpty) {
      final dest = Platform.isAndroid
          ? await ForegroundService.saveToPickedDir(
              srcPath: srcPath,
              displayName: displayName,
              treeUri: custom,
              subDir: folder,
            )
          : await ForegroundService.saveToCustomDir(
              srcPath: srcPath,
              displayName: displayName,
              dir: '$custom/$folder',
            );
      if (dest != null) return dest;
    }
    return ForegroundService.saveToDownloads(
      srcPath: srcPath,
      displayName: displayName,
      relativeDir: 'NEk0/Recordings/$folder',
    );
  }
}
