import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/recording_service.dart';

/// Recording preferences: how many minutes of session audio the Rust-side
/// backtrack buffer keeps, and where recordings are exported. The buffer is
/// always live while connected, so any moment up to
/// [RecordingSettingsState.backtrackMinutes] in the past can be saved on
/// demand, and starting a recording can optionally open with that prefix.
/// Values are loaded lazily like the other settings providers: until the
/// first disk read completes the defaults are in effect.
class RecordingSettingsState {
  /// Backtrack window in minutes (1–60).
  final int backtrackMinutes;

  /// Export location for recordings. '' = the default
  /// Downloads/NEk0/Recordings; on Android a SAF tree URI, on desktop an
  /// absolute directory path.
  final String saveDir;

  const RecordingSettingsState({
    this.backtrackMinutes = defaultMinutes,
    this.saveDir = '',
  });

  static const defaultMinutes = 5;
}

class RecordingSettingsNotifier extends Notifier<RecordingSettingsState> {
  static const prefKeyBacktrackMinutes = 'backtrack_minutes';
  static const prefKeySaveDir = RecordingService.prefKeySaveDir;

  bool _loaded = false;

  @override
  RecordingSettingsState build() {
    _load();
    return const RecordingSettingsState();
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    state = fromPrefs(prefs);
  }

  /// Reads the persisted settings directly — used by the connect flow, which
  /// already holds a SharedPreferences instance and cannot await this
  /// provider's lazy load.
  static RecordingSettingsState fromPrefs(SharedPreferences prefs) =>
      RecordingSettingsState(
        backtrackMinutes:
            prefs.getInt(prefKeyBacktrackMinutes) ??
            RecordingSettingsState.defaultMinutes,
        saveDir: prefs.getString(prefKeySaveDir) ?? '',
      );

  Future<void> setBacktrackMinutes(int minutes) async {
    final clamped = minutes.clamp(1, 60);
    state = RecordingSettingsState(
      backtrackMinutes: clamped,
      saveDir: state.saveDir,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(prefKeyBacktrackMinutes, clamped);
    // Apply immediately so a running session uses the new window.
    RecordingService.applyConfig(minutes: clamped);
  }

  /// Stores the user-picked recordings directory ('' restores the default
  /// Downloads/NEk0/Recordings). Takes effect on the next export.
  Future<void> setSaveDir(String dir) async {
    state = RecordingSettingsState(
      backtrackMinutes: state.backtrackMinutes,
      saveDir: dir,
    );
    final prefs = await SharedPreferences.getInstance();
    if (dir.isEmpty) {
      await prefs.remove(prefKeySaveDir);
    } else {
      await prefs.setString(prefKeySaveDir, dir);
    }
  }
}

final recordingSettingsProvider =
    NotifierProvider<RecordingSettingsNotifier, RecordingSettingsState>(
      RecordingSettingsNotifier.new,
    );
