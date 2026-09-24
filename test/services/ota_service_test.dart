import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:NEk0/services/ota_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('OtaSettings', () {
    test('defaults: enabled, auto source, no auto-probe winner', () async {
      final s = OtaSettings();
      await s.load();
      expect(s.enabled, isTrue);
      expect(s.source, OtaSource.auto);
      expect(s.lastAutoSource, isNull);
    });

    test(
      'enabled, source and lastAutoSource persist through a reload',
      () async {
        final s = OtaSettings();
        await s.load();
        await s.setEnabled(false);
        await s.setSource(OtaSource.gitee);
        await s.setLastAutoSource(OtaSource.github);

        final reloaded = OtaSettings();
        await reloaded.load();
        expect(reloaded.enabled, isFalse);
        expect(reloaded.source, OtaSource.gitee);
        expect(reloaded.lastAutoSource, OtaSource.github);
      },
    );

    test('an unknown stored source falls back to auto', () async {
      SharedPreferences.setMockInitialValues({'ota_source': 'mirror9'});
      final s = OtaSettings();
      await s.load();
      expect(s.source, OtaSource.auto);
      expect(s.lastAutoSource, isNull);
    });
  });

  test('release sources carry their API endpoints, auto does not', () {
    expect(OtaSource.auto.apiUrl, isNull);
    expect(OtaSource.github.apiUrl, contains('api.github.com'));
    expect(OtaSource.gitee.apiUrl, contains('gitee.com'));
  });
}
