import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which event kinds may surface as SYSTEM notifications (Android
/// notification bar / desktop toasts). This only gates the OS-level
/// notification — chat-log messages and the poke in-app dialog always
/// happen. Values are loaded lazily like the other settings providers:
/// until the first disk read completes the defaults are in effect.
class NotificationSettingsState {
  /// Incoming pokes. Defaults to true — that was the behavior before the
  /// setting existed.
  final bool poke;

  /// Someone entering/leaving our current channel.
  final bool channelEvents;

  /// Our own channel switches, being moved, being kicked from a channel.
  final bool channelMoves;

  /// Incoming private messages. Defaults to true — a PM is direct address,
  /// so the toast is worth the interruption.
  final bool pmMessages;

  /// Incoming channel and server chat messages. Defaults to false — those
  /// can be noisy.
  final bool channelMessages;

  const NotificationSettingsState({
    this.poke = true,
    this.channelEvents = false,
    this.channelMoves = false,
    this.pmMessages = true,
    this.channelMessages = false,
  });
}

class NotificationSettingsNotifier extends Notifier<NotificationSettingsState> {
  static const prefKeyPoke = 'notify_poke';
  static const prefKeyChannelEvents = 'notify_channel_events';
  static const prefKeyChannelMoves = 'notify_channel_moves';
  static const prefKeyPmMessages = 'notify_pm_messages';
  static const prefKeyChannelMessages = 'notify_channel_messages';

  bool _loaded = false;

  @override
  NotificationSettingsState build() {
    _load();
    return const NotificationSettingsState();
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    state = fromPrefs(prefs);
  }

  /// Reads the persisted settings directly — lets tests and early callers
  /// bypass the async lazy load.
  static NotificationSettingsState fromPrefs(SharedPreferences prefs) =>
      NotificationSettingsState(
        poke: prefs.getBool(prefKeyPoke) ?? true,
        channelEvents: prefs.getBool(prefKeyChannelEvents) ?? false,
        channelMoves: prefs.getBool(prefKeyChannelMoves) ?? false,
        pmMessages: prefs.getBool(prefKeyPmMessages) ?? true,
        channelMessages: prefs.getBool(prefKeyChannelMessages) ?? false,
      );

  Future<void> setPoke(bool value) => _set(prefKeyPoke, value);
  Future<void> setChannelEvents(bool value) =>
      _set(prefKeyChannelEvents, value);
  Future<void> setChannelMoves(bool value) => _set(prefKeyChannelMoves, value);
  Future<void> setPmMessages(bool value) => _set(prefKeyPmMessages, value);
  Future<void> setChannelMessages(bool value) =>
      _set(prefKeyChannelMessages, value);

  Future<void> _set(String key, bool value) async {
    state = NotificationSettingsState(
      poke: key == prefKeyPoke ? value : state.poke,
      channelEvents: key == prefKeyChannelEvents ? value : state.channelEvents,
      channelMoves: key == prefKeyChannelMoves ? value : state.channelMoves,
      pmMessages: key == prefKeyPmMessages ? value : state.pmMessages,
      channelMessages: key == prefKeyChannelMessages
          ? value
          : state.channelMessages,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }
}

final notificationSettingsProvider =
    NotifierProvider<NotificationSettingsNotifier, NotificationSettingsState>(
      NotificationSettingsNotifier.new,
    );
