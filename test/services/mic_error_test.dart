import 'package:flutter_test/flutter_test.dart';

import 'package:NEk0/services/mic_error.dart';

void main() {
  group('classifyMicError', () {
    test('flags E_ACCESSDENIED as a privacy error', () {
      // cpal renders windows-rs HRESULTs as "<message> (0x<hex>)".
      expect(
        classifyMicError(
          'build_input_stream failed (48000 Hz, 2 ch): Access is denied '
          '(0x80070005)',
        ),
        MicErrorKind.privacy,
      );
      expect(
        classifyMicError('device activation failed: 0X80070005'),
        MicErrorKind.privacy,
      );
    });

    test('flags AUDCLNT_E_DEVICE_IN_USE as a privacy error', () {
      // The Windows privacy gate typically reports the device as in use
      // even though no other app holds it.
      expect(
        classifyMicError(
          'failed to build capture client: element not found '
          '(0x8889000a)',
        ),
        MicErrorKind.privacy,
      );
      expect(classifyMicError('AUDCLNT_E_DEVICE_IN_USE'), MicErrorKind.privacy);
      expect(
        classifyMicError('another app is holding the Device in Use'),
        MicErrorKind.privacy,
      );
    });

    test('leaves unknown failures unclassified', () {
      expect(classifyMicError(''), MicErrorKind.other);
      expect(classifyMicError('no input device'), MicErrorKind.other);
      expect(
        classifyMicError(
          'all input configurations failed for device "Microphone (X)"',
        ),
        MicErrorKind.other,
      );
    });
  });
}
