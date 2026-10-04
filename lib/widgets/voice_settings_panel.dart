import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';

import '../models/ts_state.dart';
import '../models/vad_settings.dart';
import '../services/mic_error.dart';
import '../services/ts_ffi.dart';

/// Shared mic voice settings panel, modeled after the TeamSpeak client's
/// capture options: transmission mode (PTT / voice activation with auto,
/// volume-gate and hybrid modes), a dB sensitivity slider over a dBFS level
/// meter with noise-floor and gate markers, a "measure noise floor"
/// calibration flow (TS's "Begin test"), AGC and noise-suppression toggles,
/// a response-speed preset and the mic gain slider.
///
/// Used by the server screen's long-press-mic bottom sheet and by the
/// settings screen.
class VoiceSettingsPanel extends StatefulWidget {
  const VoiceSettingsPanel({
    super.key,
    required this.conn,
    required this.notifier,
    this.showTitle = true,
    this.errorOverride,
  });

  final TsConnectionState conn;
  final TsConnectionNotifier notifier;
  final bool showTitle;

  /// External mic error text (e.g. from the settings mic test). When null
  /// the panel falls back to [TsConnectionState.micError].
  final String? errorOverride;

  @override
  State<VoiceSettingsPanel> createState() => _VoiceSettingsPanelState();
}

enum _CalPhase { idle, quiet, speak, done }

class _VoiceSettingsPanelState extends State<VoiceSettingsPanel> {
  static const _quietPhase = Duration(seconds: 2);
  static const _speakPhase = Duration(seconds: 4);

  _CalPhase _calPhase = _CalPhase.idle;
  double _measuredNoiseDb = -90.0;
  double _measuredSpeechDb = -40.0;
  Timer? _calTimer;
  Timer? _sampleTimer;

  /// VAD status fetched directly from the native pipeline while the panel is
  /// open without a connection. The notifier's 200 ms poll only runs between
  /// connect and disconnect, so the settings mic test — unconnected by
  /// design — would otherwise never see a level, noise floor or AGC gain.
  VadStatusData _localStatus = VadStatusData();
  String? _lastLocalStatusJson;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _statusTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (widget.conn.connected) return;
      try {
        final statusJson = TsNative.getVadStatus();
        if (statusJson == _lastLocalStatusJson) return;
        _lastLocalStatusJson = statusJson;
        if (!mounted) return;
        setState(() {
          _localStatus = VadStatusData.fromJson(
            jsonDecode(statusJson) as Map<String, dynamic>,
          );
        });
      } catch (_) {} // status is cosmetic — never crash the panel
    });
  }

  @override
  void dispose() {
    _calTimer?.cancel();
    _sampleTimer?.cancel();
    _statusTimer?.cancel();
    super.dispose();
  }

  /// Status source for meter, calibration and AGC readout: while connected
  /// the notifier poll keeps [TsConnectionState.vadStatus] fresh; without a
  /// connection this panel polls the native pipeline itself.
  VadStatusData get _status =>
      widget.conn.connected ? widget.conn.vadStatus : _localStatus;

  void _startCalibration() {
    _calTimer?.cancel();
    _sampleTimer?.cancel();
    // Fresh noise-floor tracking — the 2 s quiet phase rebuilds it.
    TsNative.resetVad();
    _measuredNoiseDb = 0.0;
    _measuredSpeechDb = -90.0;
    setState(() => _calPhase = _CalPhase.quiet);
    _sampleTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final status = _status;
      if (_calPhase == _CalPhase.quiet) {
        final db = status.noiseDb;
        if (db > -90.0 && (_measuredNoiseDb == 0.0 || db < _measuredNoiseDb)) {
          _measuredNoiseDb = db;
        }
      } else if (_calPhase == _CalPhase.speak) {
        if (status.levelDb > _measuredSpeechDb)
          _measuredSpeechDb = status.levelDb;
      }
    });
    _calTimer = Timer(_quietPhase, () {
      if (!mounted) return;
      setState(() => _calPhase = _CalPhase.speak);
      _calTimer = Timer(_speakPhase, () {
        if (!mounted) return;
        setState(() => _calPhase = _CalPhase.done);
        _sampleTimer?.cancel();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final al = AppLocalizations.of(context);
    final conn = widget.conn;
    final settings = conn.vadSettings;
    final vadControlsEnabled = !conn.pttMode && settings.enabled;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showTitle) ...[
          Text(
            al.voiceSettings,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
        ],
        // PTT / VA mode toggle
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              al.pttMode,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            Switch(
              value: conn.pttMode,
              activeTrackColor: Colors.blue,
              onChanged: (v) => widget.notifier.togglePttMode(),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // VAD enable/disable
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              al.voiceActivation,
              style: TextStyle(
                color: conn.pttMode ? Colors.grey : Colors.white,
                fontSize: 14,
              ),
            ),
            Switch(
              value: settings.enabled,
              activeTrackColor: Colors.blue,
              onChanged: conn.pttMode
                  ? null
                  : (v) => widget.notifier.setVadEnabled(v),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Transmission mode (TS 3.5+ "Automatic / Volume gate / Hybrid")
        SegmentedButton<VadMode>(
          segments: [
            ButtonSegment(
              value: VadMode.auto,
              label: Text(al.vadModeAuto),
              enabled: vadControlsEnabled,
            ),
            ButtonSegment(
              value: VadMode.gate,
              label: Text(al.vadModeGate),
              enabled: vadControlsEnabled,
            ),
            ButtonSegment(
              value: VadMode.hybrid,
              label: Text(al.vadModeHybrid),
              enabled: vadControlsEnabled,
            ),
          ],
          selected: {settings.mode},
          showSelectedIcon: false,
          onSelectionChanged: vadControlsEnabled
              ? (selection) => widget.notifier.setVadMode(selection.first)
              : null,
        ),
        const SizedBox(height: 16),
        // dB level meter with noise-floor + gate markers
        _buildMeter(context, conn, settings),
        const SizedBox(height: 8),
        // Sensitivity (activation level) slider — TS semantics: higher =
        // less sensitive. Meaningless in auto mode (no volume gate there).
        Row(
          children: [
            SizedBox(
              width: 72,
              child: Text(
                al.vadSensitivity,
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
            Expanded(
              child: Slider(
                value: settings.sliderValue(),
                onChanged: vadControlsEnabled && settings.mode != VadMode.auto
                    ? (v) => widget.notifier.setVadActivationDb(
                        VadSettings.activationFromSlider(v),
                      )
                    : null,
              ),
            ),
            SizedBox(
              width: 58,
              child: Text(
                '${settings.activationDb.round()} dB',
                style: const TextStyle(color: Colors.grey, fontSize: 11),
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Calibration (TS "Begin test"): 2 s quiet, 4 s speech.
        _buildCalibration(context, al),
        const SizedBox(height: 12),
        // AGC
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              al.agcLabel,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            Row(
              children: [
                if (settings.agcEnabled)
                  Text(
                    al.agcGainNow(_status.agcGainDb.toStringAsFixed(1)),
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                const SizedBox(width: 8),
                Switch(
                  value: settings.agcEnabled,
                  activeTrackColor: Colors.blue,
                  onChanged: (v) => widget.notifier.setAgcEnabled(v),
                ),
              ],
            ),
          ],
        ),
        // Noise suppression (RNNoise denoise on the uplink)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              al.denoiseLabel,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            Switch(
              value: settings.denoiseEnabled,
              activeTrackColor: Colors.blue,
              onChanged: (v) => widget.notifier.setDenoiseEnabled(v),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Response speed preset (tail / preroll / onset confirmation)
        Row(
          children: [
            SizedBox(
              width: 72,
              child: Text(
                al.vadResponseSpeed,
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
            Expanded(
              child: SegmentedButton<VadPreset>(
                segments: [
                  ButtonSegment(
                    value: VadPreset.fast,
                    label: Text(al.vadPresetFast),
                  ),
                  ButtonSegment(
                    value: VadPreset.standard,
                    label: Text(al.vadPresetStandard),
                  ),
                  ButtonSegment(
                    value: VadPreset.robust,
                    label: Text(al.vadPresetRobust),
                  ),
                ],
                selected: {settings.preset},
                showSelectedIcon: false,
                onSelectionChanged: (selection) =>
                    widget.notifier.setVadPreset(selection.first),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Mic capture failure (desktop): shows *why* the level bar is flat.
        _buildMicError(context),
        const SizedBox(height: 12),
        // Mic gain slider
        Row(
          children: [
            Text(
              al.micGain,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            Expanded(
              child: Slider(
                value: conn.micGain,
                min: 0.0,
                max: 2.0,
                divisions: 40,
                activeColor: Colors.blue,
                onChanged: (v) => widget.notifier.setMicGain(v),
              ),
            ),
            Text(
              conn.micGain.toStringAsFixed(2),
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }

  /// Horizontal dBFS meter (−80..0) showing the live level, the tracked
  /// noise floor (orange tick) and the gate threshold (blue tick). Replaces
  /// the old linear-RMS bar + ×5 display hack.
  Widget _buildMeter(
    BuildContext context,
    TsConnectionState conn,
    VadSettings settings,
  ) {
    final al = AppLocalizations.of(context);
    final micActive = !conn.inputMuted && (!conn.pttMode || conn.pttPressed);
    final status = _status;
    final levelDb = micActive ? status.levelDb : VadStatusData().levelDb;
    final fill = VadSettings.meterFill(levelDb);
    final noiseFrac = VadSettings.meterFill(
      micActive ? status.noiseDb : VadStatusData().noiseDb,
    );
    final gateFrac = VadSettings.meterFill(settings.activationDb);

    return Row(
      children: [
        SizedBox(
          width: 60,
          child: Text(
            al.level,
            style: const TextStyle(color: Colors.grey, fontSize: 11),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              double x(double frac) =>
                  (frac.clamp(0.0, 1.0)) * constraints.maxWidth - 1;
              return Stack(
                alignment: Alignment.centerLeft,
                children: [
                  LinearProgressIndicator(
                    value: fill,
                    backgroundColor: Colors.grey[800],
                    color: status.speaking && micActive
                        ? Colors.blue
                        : Colors.grey,
                    minHeight: 6,
                  ),
                  // Tracked noise floor
                  Positioned(
                    left: x(noiseFrac),
                    child: Container(
                      width: 2,
                      height: 12,
                      color: Colors.orange,
                    ),
                  ),
                  // Gate threshold
                  Positioned(
                    left: x(gateFrac),
                    child: Container(
                      width: 2,
                      height: 12,
                      color: settings.enabled && settings.mode != VadMode.auto
                          ? Colors.blue
                          : Colors.grey,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCalibration(BuildContext context, AppLocalizations al) {
    final conn = widget.conn;
    switch (_calPhase) {
      case _CalPhase.idle:
        return Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.graphic_eq, size: 18),
            label: Text(al.vadCalibrate),
            onPressed: () => _startCalibration(),
          ),
        );
      case _CalPhase.quiet:
        return Text(
          al.vadCalibrateQuiet,
          style: const TextStyle(color: Colors.orange, fontSize: 12),
        );
      case _CalPhase.speak:
        return Text(
          al.vadCalibrateSpeak,
          style: const TextStyle(color: Colors.blue, fontSize: 12),
        );
      case _CalPhase.done:
        final recommended = VadSettings.recommendActivationDb(
          _measuredNoiseDb,
          _measuredSpeechDb,
        );
        return Row(
          children: [
            Expanded(
              child: Text(
                al.vadCalibrateResult(
                  _measuredNoiseDb.round().toString(),
                  _measuredSpeechDb.round().toString(),
                ),
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: conn.pttMode
                  ? null
                  : () {
                      widget.notifier.applyCalibratedActivation(recommended);
                      setState(() => _calPhase = _CalPhase.idle);
                    },
              child: Text(al.vadCalibrateApply),
            ),
          ],
        );
    }
  }

  Widget _buildMicError(BuildContext context) {
    final raw = widget.errorOverride ?? widget.conn.micError;
    if (raw == null || raw.isEmpty) return const SizedBox.shrink();
    final al = AppLocalizations.of(context);
    final text = classifyMicError(raw) == MicErrorKind.privacy
        ? al.micPrivacyHint
        : raw;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        text,
        style: const TextStyle(color: Colors.redAccent, fontSize: 11),
      ),
    );
  }
}
