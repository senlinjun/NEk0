import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:NEk0/models/vad_settings.dart';

void main() {
  group('VadSettings defaults', () {
    test('match the documented TS-derived defaults', () {
      const s = VadSettings();
      expect(s.enabled, isTrue);
      expect(s.mode, VadMode.hybrid);
      // The default activation level is exactly the old linear default
      // 0.005 RMS in dB (20·log10 0.005 ≈ −46.02).
      expect(s.activationDb, -46.0);
      expect(s.preset, VadPreset.standard);
      expect(s.agcEnabled, isTrue);
      expect(s.denoiseEnabled, isFalse);
    });

    test('presets map to the documented timing knobs', () {
      expect(const VadSettings(preset: VadPreset.fast).timings, (120, 0, 1));
      // Standard aligns with TS3's defaults: preroll 2, no confirmation.
      expect(const VadSettings(preset: VadPreset.standard).timings, (
        200,
        2,
        1,
      ));
      expect(const VadSettings(preset: VadPreset.robust).timings, (300, 5, 3));
    });
  });

  group('VadSettings JSON contract', () {
    test('toJson carries the Rust PipelineConfigPatch keys', () {
      final json = const VadSettings(
        enabled: false,
        mode: VadMode.auto,
        activationDb: -50.0,
        preset: VadPreset.robust,
        agcEnabled: false,
        denoiseEnabled: true,
      ).toJson();
      expect(json['enabled'], isFalse);
      expect(json['mode'], 'auto');
      expect(json['activation_db'], -50.0);
      expect(json['hold_ms'], 300);
      expect(json['preroll_frames'], 5);
      expect(json['onset_frames'], 3);
      expect(json['agc_enabled'], isFalse);
      expect(json['denoise_enabled'], isTrue);
      // mic gain is merged by the caller (ts_state), not part of the model.
      expect(json.containsKey('mic_gain'), isFalse);
    });

    test('toJsonString is valid JSON the Rust side parses', () {
      final s = const VadSettings();
      final decoded = jsonDecode(s.toJsonString()) as Map<String, dynamic>;
      expect(decoded['mode'], 'hybrid');
      expect(decoded['activation_db'], -46.0);
    });
  });

  group('VadMode / VadPreset parsing', () {
    test('accepts the wire names and falls back safely', () {
      expect(VadMode.fromJson('auto'), VadMode.auto);
      expect(VadMode.fromJson('gate'), VadMode.gate);
      expect(VadMode.fromJson('hybrid'), VadMode.hybrid);
      expect(VadMode.fromJson('bogus'), VadMode.hybrid);
      expect(VadPreset.fromJson('fast'), VadPreset.fast);
      expect(VadPreset.fromJson('bogus'), VadPreset.standard);
    });
  });

  group('slider mapping', () {
    test('slider 0..1 maps linearly onto the dB range', () {
      expect(VadSettings.activationFromSlider(0.0), vadSliderMinDb);
      expect(VadSettings.activationFromSlider(1.0), vadSliderMaxDb);
      expect(
        VadSettings.activationFromSlider(0.5),
        (vadSliderMinDb + vadSliderMaxDb) / 2.0,
      );
    });

    test('sliderValue is the inverse', () {
      const s = VadSettings(activationDb: -40.0);
      expect(
        VadSettings.activationFromSlider(s.sliderValue()),
        closeTo(-40.0, 1e-9),
      );
    });

    test('higher activation = less sensitive (TS semantics kept)', () {
      // A frame at −35 dB must pass a −40 gate but not a −30 gate.
      final lenient = VadSettings(activationDb: -40.0);
      final strict = VadSettings(activationDb: -30.0);
      expect(lenient.sliderValue() < strict.sliderValue(), isTrue);
    });

    test('meterFill clamps outside −80..0 dBFS', () {
      expect(VadSettings.meterFill(-120.0), 0.0);
      expect(VadSettings.meterFill(-80.0), 0.0);
      expect(VadSettings.meterFill(0.0), 1.0);
      expect(VadSettings.meterFill(10.0), 1.0);
      expect(VadSettings.meterFill(-40.0), closeTo(0.5, 1e-9));
    });
  });

  group('calibration recommendation', () {
    test('sits between noise and speech with margin, clamped to range', () {
      // Midpoint of −60 and −30 is −45, +3 margin → −42.
      expect(
        VadSettings.recommendActivationDb(-60.0, -30.0),
        closeTo(-42.0, 1e-9),
      );
      // Degenerate: noise == speech → still inside the slider range.
      final rec = VadSettings.recommendActivationDb(-30.0, -30.0);
      expect(rec, inInclusiveRange(vadSliderMinDb, vadSliderMaxDb));
      // Very hot speech cannot push the recommendation above −20.
      expect(VadSettings.recommendActivationDb(-40.0, -5.0), vadSliderMaxDb);
    });
  });

  group('VadStatusData', () {
    test('parses the Rust VadStatus JSON', () {
      final s = VadStatusData.fromJson(
        jsonDecode('''
        {
          "enabled": true, "speaking": true, "mode": "gate",
          "level_db": -31.5, "noise_db": -55.0, "open_db": -40.0,
          "prob": 0.83, "agc_gain_db": 6.5, "clipped": true
        }
      ''')
            as Map<String, dynamic>,
      );
      expect(s.enabled, isTrue);
      expect(s.speaking, isTrue);
      expect(s.mode, VadMode.gate);
      expect(s.levelDb, -31.5);
      expect(s.noiseDb, -55.0);
      expect(s.openDb, -40.0);
      expect(s.prob, closeTo(0.83, 1e-9));
      expect(s.agcGainDb, 6.5);
      expect(s.clipped, isTrue);
    });

    test('tolerates missing fields', () {
      final s = VadStatusData.fromJson(const {});
      expect(s.enabled, isFalse);
      expect(s.mode, VadMode.hybrid);
      expect(s.levelDb, -90.0);
    });
  });
}
