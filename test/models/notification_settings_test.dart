import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:NEk0/models/notification_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('notification settings', () {
    test('defaults: pokes on, channel events and moves off', () {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(notificationSettingsProvider);
      expect(state.poke, isTrue);
      expect(state.channelEvents, isFalse);
      expect(state.channelMoves, isFalse);
      expect(state.pmMessages, isTrue);
      expect(state.channelMessages, isFalse);
    });

    test('persisted values are picked up on load', () async {
      SharedPreferences.setMockInitialValues({
        NotificationSettingsNotifier.prefKeyPoke: false,
        NotificationSettingsNotifier.prefKeyChannelEvents: true,
        NotificationSettingsNotifier.prefKeyChannelMoves: true,
        NotificationSettingsNotifier.prefKeyPmMessages: false,
        NotificationSettingsNotifier.prefKeyChannelMessages: true,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // First touch instantiates the provider and starts its lazy load; let
      // the async load settle before asserting.
      container.read(notificationSettingsProvider);
      await pumpEventQueue();
      final state = container.read(notificationSettingsProvider);
      expect(state.poke, isFalse);
      expect(state.channelEvents, isTrue);
      expect(state.channelMoves, isTrue);
      expect(state.pmMessages, isFalse);
      expect(state.channelMessages, isTrue);
    });

    test('setters update the state and persist', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(notificationSettingsProvider.notifier);
      await notifier.setChannelEvents(true);
      await notifier.setPoke(false);
      await notifier.setChannelMessages(true);
      await notifier.setPmMessages(false);
      final state = container.read(notificationSettingsProvider);
      expect(state.channelEvents, isTrue);
      expect(state.poke, isFalse);
      expect(state.channelMoves, isFalse);
      expect(state.channelMessages, isTrue);
      expect(state.pmMessages, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(NotificationSettingsNotifier.prefKeyChannelEvents),
        isTrue,
      );
      expect(prefs.getBool(NotificationSettingsNotifier.prefKeyPoke), isFalse);
      expect(
        prefs.getBool(NotificationSettingsNotifier.prefKeyChannelMessages),
        isTrue,
      );
      expect(
        prefs.getBool(NotificationSettingsNotifier.prefKeyPmMessages),
        isFalse,
      );
    });
  });
}
