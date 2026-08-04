import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/app_locale.dart';
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
  static const _languageOptions = ['system', 'en', 'zh'];

  final OtaSettings _ota = OtaSettings();
  bool _otaLoaded = false;
  String _languageCode = 'system';

  AudioService? _testAudio;
  bool _micTest = false;
  double _testRms = 0.0;

  @override
  void initState() {
    super.initState();
    _ota.load().then((_) {
      if (mounted) setState(() => _otaLoaded = true);
    });
    _loadLanguage();
  }

  Future<void> _loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('locale') ?? 'system';
    if (mounted) setState(() => _languageCode = code);
  }

  String _languageLabel(BuildContext context, String code) {
    final al = AppLocalizations.of(context);
    return switch (code) {
      'en' => al.languageEnglish,
      'zh' => al.languageChinese,
      _ => al.languageSystem,
    };
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
          SnackBar(
            content: Text(AppLocalizations.of(context).micPermissionDenied),
          ),
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
      SnackBar(
        content: Text(AppLocalizations.of(context).checkingForUpdates),
        duration: const Duration(seconds: 2),
      ),
    );
    final info = await OtaService.checkForUpdate(source);
    if (!mounted) return;
    if (info == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).noUpdateAvailable)),
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

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F23),
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).settingsTitle),
        backgroundColor: const Color(0xFF16213E),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SectionHeader(AppLocalizations.of(context).voice),
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
                  // Draw the mic test level onto the threshold slider, just
                  // like the server screen's long-press-mic sheet.
                  levelOverride: _micTest ? _testRms : null,
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Mic test capture control (level is drawn on the threshold
            // slider in the VoiceSettingsPanel above, like the server screen)
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
                        Text(
                          AppLocalizations.of(context).micTest,
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                        const Spacer(),
                        FilledButton.tonalIcon(
                          onPressed: connected ? null : _toggleMicTest,
                          icon: Icon(
                            _micTest ? Icons.stop : Icons.mic,
                            size: 18,
                          ),
                          label: Text(
                            _micTest
                                ? AppLocalizations.of(context).stopMicTest
                                : AppLocalizations.of(context).startMicTest,
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF2A2A4A),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                    if (connected) ...[
                      const SizedBox(height: 8),
                      Text(
                        AppLocalizations.of(context).micInUseWhileConnected,
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            _SectionHeader(AppLocalizations.of(context).language),
            const SizedBox(height: 8),
            Card(
              color: const Color(0xFF1A1A2E),
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: RadioGroup<String>(
                  groupValue: _languageCode,
                  onChanged: (code) {
                    if (code == null) return;
                    setState(() => _languageCode = code);
                    ref.read(localeProvider.notifier).setLanguage(code);
                  },
                  child: Column(
                    children: [
                      for (final code in _languageOptions)
                        RadioListTile<String>(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          activeColor: Colors.blue,
                          title: Text(
                            _languageLabel(context, code),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                          value: code,
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            _SectionHeader(AppLocalizations.of(context).updateSection),
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
                        Text(
                          AppLocalizations.of(context).checkForUpdates,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
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
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        AppLocalizations.of(context).updateSource,
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
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
                        label: Text(AppLocalizations.of(context).checkNow),
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
