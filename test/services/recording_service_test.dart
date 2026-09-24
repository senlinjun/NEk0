import 'package:flutter_test/flutter_test.dart';

import 'package:NEk0/services/recording_service.dart';

void main() {
  group('RecordingStatus.fromJson', () {
    test('parses the full snapshot', () {
      final s = RecordingStatus.fromJson({
        'recording': true,
        'hold': true,
        'backtrack_secs': 60,
        'available_secs': 45,
        'recording_secs': 120,
        'tracks': [
          {'client_id': 0, 'uid': null, 'name': ''},
          {'client_id': 5, 'uid': 'abc=', 'name': 'Alice'},
        ],
      });
      expect(s.recording, isTrue);
      expect(s.hold, isTrue);
      expect(s.backtrackSecs, 60);
      expect(s.availableSecs, 45);
      expect(s.recordingSecs, 120);
      expect(s.tracks, hasLength(2));
      expect(s.tracks[0].clientId, 0);
      expect(s.tracks[0].uid, isNull);
      expect(s.tracks[1].clientId, 5);
      expect(s.tracks[1].uid, 'abc=');
      expect(s.tracks[1].name, 'Alice');
    });

    test('missing fields fall back to safe defaults', () {
      final s = RecordingStatus.fromJson(const {});
      expect(s.recording, isFalse);
      expect(s.hold, isFalse);
      expect(s.backtrackSecs, 0);
      expect(s.availableSecs, 0);
      expect(s.recordingSecs, 0);
      expect(s.tracks, isEmpty);
    });
  });

  test('RecordingFile.fromJson tolerates missing fields', () {
    final f = RecordingFile.fromJson({'path': '/tmp/a.wav'});
    expect(f.path, '/tmp/a.wav');
    expect(f.clientId, 0);
    expect(f.uid, isNull);
    expect(f.name, '');
    expect(f.mixed, isFalse);
  });

  group('RecordingService events', () {
    // Singleton — the tests below leave the flag off in every path.
    final svc = RecordingService.instance;

    test('recording_state toggles the flag and notifies', () {
      var notified = 0;
      void listener() => notified++;
      svc.addListener(listener);
      addTearDown(() => svc.removeListener(listener));

      svc.handleEvent({'type': 'recording_state', 'recording': true});
      expect(svc.recording, isTrue);
      expect(notified, 1);

      // Reporting the same state again must not re-notify.
      svc.handleEvent({'type': 'recording_state', 'recording': true});
      expect(notified, 1);

      svc.handleEvent({'type': 'recording_state', 'recording': false});
      expect(svc.recording, isFalse);
      expect(notified, 2);
    });

    test('reset clears an active recording flag', () {
      svc.handleEvent({'type': 'recording_state', 'recording': true});
      expect(svc.recording, isTrue);
      svc.reset();
      expect(svc.recording, isFalse);
    });
  });

  test('saveFolderName is timestamp-shaped and colon-free (Windows safe)', () {
    final name = RecordingService.saveFolderName();
    expect(RegExp(r'^\d{8}_\d{6}$').hasMatch(name), isTrue, reason: name);
  });
}
