import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What happens when the user closes the main window on desktop. Only
/// meaningful on Windows/Linux — Android has no window close button.
enum WindowCloseAction {
  /// Ask every time (dialog with quit / hide-to-tray + a "don't ask again"
  /// checkbox).
  ask,

  /// Hide the window to the system tray and keep running.
  hide,

  /// Disconnect from the server (if connected) and quit the app.
  exit,
}

/// Desktop close-button behavior. Persists via SharedPreferences and loads
/// lazily like the other settings notifiers: until the first disk read
/// completes, [WindowCloseAction.ask] is in effect.
class WindowSettingsState {
  final WindowCloseAction closeAction;

  const WindowSettingsState({this.closeAction = WindowCloseAction.ask});
}

class WindowSettingsNotifier extends Notifier<WindowSettingsState> {
  static const _kCloseAction = 'window_close_action';

  bool _loaded = false;

  @override
  WindowSettingsState build() {
    _load();
    return const WindowSettingsState();
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    state = WindowSettingsState(
      closeAction: _decode(prefs.getString(_kCloseAction)),
    );
  }

  /// Persists [action] as the new close behavior. Called both from the
  /// settings screen and from the close dialog's "don't ask again" checkbox.
  Future<void> setCloseAction(WindowCloseAction action) async {
    state = WindowSettingsState(closeAction: action);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCloseAction, action.name);
  }

  static WindowCloseAction _decode(String? raw) {
    for (final action in WindowCloseAction.values) {
      if (action.name == raw) return action;
    }
    return WindowCloseAction.ask;
  }
}

final windowSettingsProvider =
    NotifierProvider<WindowSettingsNotifier, WindowSettingsState>(
      WindowSettingsNotifier.new,
    );
