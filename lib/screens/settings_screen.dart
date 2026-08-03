import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ts_state.dart';
import '../services/audio_service.dart';
import '../services/ota_service.dart';
import '../widgets/voice_settings_panel.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final OtaSettings _ota = OtaSettings();
  bool _otaLoaded = false;

  AudioService? _testAudio;
  bool _micTest = false;
  double _testRms = 0.0;

  @override
  void initState() {
    super.initState();
    _ota.load().then((_) {
      if (mounted) setState(() => _otaLoaded = true);
    });
  }

  @override
  void dispose() {
    _testAudio?.disableMic();
    _testAudio?.stop();
    _testAudio = null;
    super.dispose();
  }

  Future<void> _toggleMicTest() async {
    if (_micTest) {
      _testAudio?.disableMic();
      _testAudio?.stop();
      _testAudio = null;
      setState(() {
        _micTest = false;
        _testRms = 0.0;
      });
      return;
    }
    final a = AudioService();
    a.onMicLevel = (rms) {
      if (mounted) setState(() => _testRms = rms);
    };
    final started = await a.start();
    final granted = started ? await a.enableMic() : false;
    if (!granted) {
      a.stop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied')),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _testAudio = a;
      _micTest = true;
      _testRms = 0.0;
    });
  }

  Future<void> _checkNow() async {
    final source = _ota.source;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Checking for updates…'),
        duration: Duration(seconds: 2),
      ),
    );
    final info = await OtaService.checkForUpdate(source);
    if (!mounted) return;
    if (info == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No update available')),
      );
    } else {
      await showUpdateDialog(context, info);
    }
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(tsConnectionProvider);
    final notifier = ref.read(tsConnectionProvider.notifier);
    final connected = conn.connected;

    // Level shown next to the mic test button: live state when connected,
    // otherwise the local test capture.
    final level = _micTest
        ? _testRms
        : (connected && !conn.inputMuted ? conn.micRms : 0.0);

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F23),
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: const Color(0xFF16213E),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _SectionHeader('Voice'),
            const SizedBox(height: 8),
            Card(
              color: const Color(0xFF1A1A2E),
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: VoiceSettingsPanel(
                  conn: conn,
                  notifier: notifier,
                  showTitle: false,
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Mic level + test capture
            Card(
              color: const Color(0xFF1A1A2E),
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'Mic Level',
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                        const Spacer(),
                        FilledButton.tonalIcon(
                          onPressed: connected ? null : _toggleMicTest,
                          icon: Icon(
                            _micTest ? Icons.stop : Icons.mic,
                            size: 18,
                          ),
                          label: Text(
                            _micTest ? 'Stop test' : 'Start mic test',
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF2A2A4A),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: level.clamp(0.0, 1.0),
                        backgroundColor: Colors.grey[800],
                        color: Colors.blue,
                        minHeight: 6,
                      ),
                    ),
                    if (connected) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Mic is in use while connected — test is disabled.',
                        style: TextStyle(color: Colors.grey, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            const _SectionHeader('Update'),
            const SizedBox(height: 8),
            Card(
              color: const Color(0xFF1A1A2E),
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Check for updates',
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                        Switch(
                          value: _ota.enabled,
                          activeTrackColor: Colors.blue,
                          onChanged: (v) {
                            setState(() => _ota.enabled = v);
                            _ota.setEnabled(v);
                          },
                        ),
                      ],
                    ),
                    const Divider(height: 20, color: Color(0xFF2A2A4A)),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Update source',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ),
                    RadioGroup<OtaSource>(
                      groupValue: _ota.source,
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _ota.source = v);
                        _ota.setSource(v);
                      },
                      child: Column(
                        children: [
                          for (final source in OtaSource.values)
                            RadioListTile<OtaSource>(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              activeColor: Colors.blue,
                              title: Text(
                                source.label,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                ),
                              ),
                              value: source,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _otaLoaded ? _checkNow : null,
                        icon: const Icon(Icons.system_update_alt, size: 18),
                        label: const Text('Check now'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.blue,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        color: Colors.blueAccent,
        fontSize: 13,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
      ),
    );
  }
}
