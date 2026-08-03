import 'package:flutter/material.dart';

import '../models/ts_state.dart';

/// Shared mic voice settings panel (PTT mode, VAD, threshold + level meter,
/// mic gain). Used by the server screen's long-press-mic bottom sheet and by
/// the settings screen.
class VoiceSettingsPanel extends StatefulWidget {
  const VoiceSettingsPanel({
    super.key,
    required this.conn,
    required this.notifier,
    this.showTitle = true,
  });

  final TsConnectionState conn;
  final TsConnectionNotifier notifier;
  final bool showTitle;

  @override
  State<VoiceSettingsPanel> createState() => _VoiceSettingsPanelState();
}

class _VoiceSettingsPanelState extends State<VoiceSettingsPanel> {
  late bool _pttMode;
  late bool _vadEnabled;
  late double _vadThreshold;
  late double _micGain;

  @override
  void initState() {
    super.initState();
    _pttMode = widget.conn.pttMode;
    _vadEnabled = widget.conn.vadEnabled;
    _vadThreshold = widget.conn.vadThreshold;
    _micGain = widget.conn.micGain;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showTitle) ...[
          const Text(
            'Voice Settings',
            style: TextStyle(
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
            const Text(
              'PTT Mode',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
            Switch(
              value: _pttMode,
              activeTrackColor: Colors.blue,
              onChanged: (v) {
                setState(() => _pttMode = v);
                widget.notifier.togglePttMode();
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        // VAD enable/disable
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Voice Activation',
              style: TextStyle(
                color: _pttMode ? Colors.grey : Colors.white,
                fontSize: 14,
              ),
            ),
            Switch(
              value: _vadEnabled,
              activeTrackColor: Colors.blue,
              onChanged: _pttMode
                  ? null
                  : (v) {
                      setState(() => _vadEnabled = v);
                      widget.notifier.setVadEnabled(v);
                    },
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Threshold slider stacked on mic level bar (same 0–1 scale)
        Builder(
          builder: (_) {
            final s = widget.conn;
            final micActive = !s.inputMuted && (!s.pttMode || s.pttPressed);
            final rms = micActive ? s.micRms : 0.0;
            final fill = rms.clamp(0.0, 1.0);
            final over = rms >= _vadThreshold && _vadThreshold > 0.0;
            return Row(
              children: [
                const SizedBox(
                  width: 60,
                  child: Text(
                    'Level',
                    style: TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ),
                Expanded(
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      // Bottom: mic level bar
                      LinearProgressIndicator(
                        value: fill,
                        backgroundColor: Colors.grey[800],
                        color: over ? Colors.blue : Colors.grey,
                        minHeight: 4,
                      ),
                      // Top: threshold slider (transparent track, only knob visible)
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          overlayShape: SliderComponentShape.noOverlay,
                          activeTrackColor: Colors.transparent,
                          inactiveTrackColor: Colors.transparent,
                          thumbColor: Colors.blue,
                          disabledThumbColor: Colors.grey,
                        ),
                        child: Slider(
                          value: _vadThreshold,
                          min: 0.0,
                          max: 1.0,
                          onChanged: (_pttMode || !_vadEnabled)
                              ? null
                              : (v) {
                                  setState(() => _vadThreshold = v);
                                  widget.notifier.setVadThreshold(v);
                                },
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 42,
                  child: Text(
                    _vadThreshold.toStringAsFixed(3),
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        // Mic gain slider
        Row(
          children: [
            const Text(
              'Mic Gain',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            Expanded(
              child: Slider(
                value: _micGain,
                min: 0.0,
                max: 2.0,
                divisions: 40,
                activeColor: Colors.blue,
                onChanged: (v) {
                  setState(() => _micGain = v);
                  widget.notifier.setMicGain(v);
                },
              ),
            ),
            Text(
              _micGain.toStringAsFixed(2),
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }
}
