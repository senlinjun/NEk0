import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The user-configurable entry sound played automatically when a connection
/// to a server is established (see EntrySoundService): broadcast into the
/// current channel as voice plus an optional local echo. One global sound —
/// not per server. Values are loaded lazily like the other settings
/// providers: until the first disk read completes the defaults are in
/// effect. [soundName] is display metadata only; the stored file under
/// `<docs>/entry_sounds/` is the source of truth for "configured".
class EntrySoundSettingsState {
  /// Master switch. No sound is configured out of the box, so this being
  /// true by default changes nothing until the user picks a file.
  final bool enabled;

  /// Play the sound through the local output while it is broadcast.
  final bool playLocally;

  /// Display name of the picked file, or null when none is configured.
  final String? soundName;

  const EntrySoundSettingsState({
    this.enabled = true,
    this.playLocally = true,
    this.soundName,
  });

  EntrySoundSettingsState copyWith({
    bool? enabled,
    bool? playLocally,
    String? soundName,
  }) {
    return EntrySoundSettingsState(
      enabled: enabled ?? this.enabled,
      playLocally: playLocally ?? this.playLocally,
      soundName: soundName ?? this.soundName,
    );
  }
}

class EntrySoundSettingsNotifier extends Notifier<EntrySoundSettingsState> {
  static const prefKeyEnabled = 'entry_sound_enabled';
  static const prefKeyLocalEcho = 'entry_sound_local_echo';
  static const prefKeySoundName = 'entry_sound_name';

  bool _loaded = false;

  @override
  EntrySoundSettingsState build() {
    _load();
    return const EntrySoundSettingsState();
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    state = fromPrefs(prefs);
  }

  /// Reads the persisted settings directly — lets tests and early callers
  /// bypass the async lazy load.
  static EntrySoundSettingsState fromPrefs(SharedPreferences prefs) =>
      EntrySoundSettingsState(
        enabled: prefs.getBool(prefKeyEnabled) ?? true,
        playLocally: prefs.getBool(prefKeyLocalEcho) ?? true,
        soundName: prefs.getString(prefKeySoundName),
      );

  Future<void> setEnabled(bool value) => _setBool(prefKeyEnabled, value);
  Future<void> setPlayLocally(bool value) => _setBool(prefKeyLocalEcho, value);

  Future<void> setSoundName(String? value) async {
    // Direct construction, not copyWith — copyWith cannot clear a nullable
    // field (null means "keep").
    state = EntrySoundSettingsState(
      enabled: state.enabled,
      playLocally: state.playLocally,
      soundName: (value != null && value.isEmpty) ? null : value,
    );
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.isEmpty) {
      await prefs.remove(prefKeySoundName);
    } else {
      await prefs.setString(prefKeySoundName, value);
    }
  }

  Future<void> _setBool(String key, bool value) async {
    state = EntrySoundSettingsState(
      enabled: key == prefKeyEnabled ? value : state.enabled,
      playLocally: key == prefKeyLocalEcho ? value : state.playLocally,
      soundName: state.soundName,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }
}

final entrySoundSettingsProvider =
    NotifierProvider<EntrySoundSettingsNotifier, EntrySoundSettingsState>(
      EntrySoundSettingsNotifier.new,
    );
