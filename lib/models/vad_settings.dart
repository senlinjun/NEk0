/// VAD / AGC settings model — pure Dart logic, no FFI.
///
/// Mirrors the Rust side (`native/src/mic_pipeline.rs`,
/// `PipelineConfigPatch`): the app owns the persisted settings and pushes
/// the full config JSON to the native pipeline on every change.
library;

import 'dart:convert';

/// Voice activation mode, matching TeamSpeak 3.5+'s three capture modes.
enum VadMode {
  /// RNNoise speech probability only (TS "Automatic").
  auto,

  /// dB volume gate only (TS "Volume gate").
  gate,

  /// Speech probability AND volume must both hold (TS "Hybrid").
  hybrid;

  String get jsonName => name;

  static VadMode fromJson(String s) => VadMode.values.firstWhere(
    (m) => m.name == s,
    orElse: () => VadMode.hybrid,
  );
}

/// How quickly the gate reacts, as a preset over the three timing knobs.
enum VadPreset {
  fast,
  standard,
  robust;

  static VadPreset fromJson(String s) => VadPreset.values.firstWhere(
    (p) => p.name == s,
    orElse: () => VadPreset.standard,
  );
}

/// Timing knobs per response preset: tail duration, preroll depth and the
/// onset confirmation run.
typedef PresetTimings = (int holdMs, int prerollFrames, int onsetFrames);

const presetTimings = <VadPreset, PresetTimings>{
  VadPreset.fast: (120, 0, 1),
  VadPreset.standard: (200, 3, 2),
  VadPreset.robust: (300, 5, 3),
};

/// Slider range for the sensitivity (activation level) in dBFS. TS
/// semantics: a HIGHER value (towards −20) means LESS sensitive.
const vadSliderMinDb = -60.0;
const vadSliderMaxDb = -20.0;

/// Level meter range in dBFS (0 = full scale).
const meterMinDb = -80.0;
const meterMaxDb = 0.0;

class VadSettings {
  const VadSettings({
    this.enabled = true,
    this.mode = VadMode.hybrid,
    this.activationDb = -46.0,
    this.preset = VadPreset.standard,
    this.agcEnabled = true,
    this.denoiseEnabled = false,
  });

  static const defaultActivationDb = -46.0; // == old linear default 0.005 RMS

  final bool enabled;
  final VadMode mode;
  final double activationDb;
  final VadPreset preset;
  final bool agcEnabled;
  final bool denoiseEnabled;

  PresetTimings get timings => presetTimings[preset]!;

  VadSettings copyWith({
    bool? enabled,
    VadMode? mode,
    double? activationDb,
    VadPreset? preset,
    bool? agcEnabled,
    bool? denoiseEnabled,
  }) {
    return VadSettings(
      enabled: enabled ?? this.enabled,
      mode: mode ?? this.mode,
      activationDb: activationDb ?? this.activationDb,
      preset: preset ?? this.preset,
      agcEnabled: agcEnabled ?? this.agcEnabled,
      denoiseEnabled: denoiseEnabled ?? this.denoiseEnabled,
    );
  }

  /// JSON for `ts_set_vad_config` (the Rust side clamps every field). The
  /// mic gain is NOT part of this model — it keeps its own legacy setting
  /// and is merged in by the caller.
  Map<String, dynamic> toJson() {
    final (holdMs, preroll, onset) = timings;
    return {
      'enabled': enabled,
      'mode': mode.jsonName,
      'activation_db': activationDb,
      'hold_ms': holdMs,
      'preroll_frames': preroll,
      'onset_frames': onset,
      'agc_enabled': agcEnabled,
      'denoise_enabled': denoiseEnabled,
    };
  }

  String toJsonString() => jsonEncode(toJson());

  // ─── Persistence (SharedPreferences keys) ─────────────────────────

  static const prefEnabled = 'vad_enabled';
  static const prefMode = 'vad_mode';
  static const prefActivationDb = 'vad_activation_db';
  static const prefPreset = 'vad_preset';
  static const prefAgc = 'vad_agc_enabled';
  static const prefDenoise = 'vad_denoise_enabled';

  /// NOTE: `mic_gain` keeps its legacy key (it predates this model).

  // ─── Slider mapping ───────────────────────────────────────────────

  double sliderValue() =>
      ((activationDb - vadSliderMinDb) / (vadSliderMaxDb - vadSliderMinDb))
          .clamp(0.0, 1.0);

  static double activationFromSlider(double v) =>
      vadSliderMinDb + (vadSliderMaxDb - vadSliderMinDb) * v.clamp(0.0, 1.0);

  /// Meter fill 0..1 for a level in dBFS.
  static double meterFill(double db) =>
      ((db - meterMinDb) / (meterMaxDb - meterMinDb)).clamp(0.0, 1.0);

  // ─── Calibration ──────────────────────────────────────────────────

  /// Recommended activation level between the measured noise floor and the
  /// measured speech level: the midpoint, with a little extra margin above
  /// the middle so gating stays robust against noise bursts. Clamped to
  /// the slider range.
  static double recommendActivationDb(double noiseDb, double speechDb) {
    final mid = (noiseDb + speechDb) / 2.0 + 3.0;
    return mid.clamp(vadSliderMinDb, vadSliderMaxDb);
  }
}

/// Snapshot of `ts_get_vad_status` — what the last processed mic frame
/// looked like inside the native pipeline.
class VadStatusData {
  const VadStatusData({
    this.enabled = false,
    this.speaking = false,
    this.mode = VadMode.hybrid,
    this.levelDb = -90.0,
    this.noiseDb = -90.0,
    this.openDb = -46.0,
    this.prob = 0.0,
    this.agcGainDb = 0.0,
    this.clipped = false,
  });

  factory VadStatusData.fromJson(Map<String, dynamic> j) => VadStatusData(
    enabled: (j['enabled'] as bool?) ?? false,
    speaking: (j['speaking'] as bool?) ?? false,
    mode: VadMode.fromJson((j['mode'] as String?) ?? 'hybrid'),
    levelDb: (j['level_db'] as num?)?.toDouble() ?? -90.0,
    noiseDb: (j['noise_db'] as num?)?.toDouble() ?? -90.0,
    openDb: (j['open_db'] as num?)?.toDouble() ?? -46.0,
    prob: (j['prob'] as num?)?.toDouble() ?? 0.0,
    agcGainDb: (j['agc_gain_db'] as num?)?.toDouble() ?? 0.0,
    clipped: (j['clipped'] as bool?) ?? false,
  );

  final bool enabled;
  final bool speaking;
  final VadMode mode;
  final double levelDb;
  final double noiseDb;
  final double openDb;
  final double prob;
  final double agcGainDb;
  final bool clipped;
}
