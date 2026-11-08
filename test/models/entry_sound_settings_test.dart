import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:NEk0/models/entry_sound_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('entry sound settings', () {
    test('defaults: enabled + local echo on, no sound set', () {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(entrySoundSettingsProvider);
      expect(state.enabled, isTrue);
      expect(state.playLocally, isTrue);
      expect(state.soundName, isNull);
    });

    test('persisted values are picked up on load', () async {
      SharedPreferences.setMockInitialValues({
        EntrySoundSettingsNotifier.prefKeyEnabled: false,
        EntrySoundSettingsNotifier.prefKeyLocalEcho: false,
        EntrySoundSettingsNotifier.prefKeySoundName: 'boom.wav',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // First touch instantiates the provider and starts its lazy load; let
      // the async load settle before asserting.
      container.read(entrySoundSettingsProvider);
      await pumpEventQueue();
      final state = container.read(entrySoundSettingsProvider);
      expect(state.enabled, isFalse);
      expect(state.playLocally, isFalse);
      expect(state.soundName, 'boom.wav');
    });

    test('setters update the state and persist', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(entrySoundSettingsProvider.notifier);
      await notifier.setEnabled(false);
      await notifier.setPlayLocally(false);
      await notifier.setSoundName('tada.wav');
      final state = container.read(entrySoundSettingsProvider);
      expect(state.enabled, isFalse);
      expect(state.playLocally, isFalse);
      expect(state.soundName, 'tada.wav');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(EntrySoundSettingsNotifier.prefKeyEnabled), isFalse);
      expect(
        prefs.getBool(EntrySoundSettingsNotifier.prefKeyLocalEcho),
        isFalse,
      );
      expect(
        prefs.getString(EntrySoundSettingsNotifier.prefKeySoundName),
        'tada.wav',
      );
    });

    test(
      'setSoundName(null) clears the name (copyWith null-trap avoided)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(entrySoundSettingsProvider.notifier);
        await notifier.setSoundName('tada.wav');
        await notifier.setSoundName(null);
        expect(container.read(entrySoundSettingsProvider).soundName, isNull);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString(EntrySoundSettingsNotifier.prefKeySoundName),
          isNull,
        );
      },
    );

    test('copyWith keeps fields on null', () {
      const state = EntrySoundSettingsState(
        enabled: false,
        playLocally: false,
        soundName: 'a.wav',
      );
      final patched = state.copyWith(enabled: true);
      expect(patched.enabled, isTrue);
      expect(patched.playLocally, isFalse);
      expect(patched.soundName, 'a.wav');
    });
  });
}
