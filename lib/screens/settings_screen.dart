import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/app_locale.dart';
import '../models/background_settings.dart';
import '../models/ts_state.dart';
import '../models/window_settings.dart';
import '../services/audio_service.dart';
import '../services/background_service.dart';
import '../services/ota_service.dart';
import '../services/sfx_pack_service.dart';
import '../services/ts_ffi.dart';
import '../widgets/voice_settings_panel.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static const _languageOptions = ['system', 'en', 'zh'];
  static const _githubUrl = 'https://github.com/senlinjun/NEk0';

  final OtaSettings _ota = OtaSettings();
  bool _otaLoaded = false;
  String _languageCode = 'system';
  String _version = '';

  AudioService? _testAudio;
  bool _micTest = false;
  double _testRms = 0.0;
  List<SfxPack> _sfxPacks = [];
  String? _activeSfxPack;
  String? _bgName;

  // Audio device picker (desktop only; '' = system default).
  List<Map<String, dynamic>> _outputDevices = [];
  List<Map<String, dynamic>> _inputDevices = [];
  String _outputDevice = '';
  String _inputDevice = '';

  @override
  void initState() {
    super.initState();
    _ota.load().then((_) {
      if (mounted) setState(() => _otaLoaded = true);
    });
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    });
    _loadLanguage();
    _loadSfxPacks();
    _loadBgName();
    if (!Platform.isAndroid) _loadAudioDevices();
  }

  /// Restores the persisted device choice and fetches the device list.
  /// The Rust-side selection is (re)applied here so a choice made in an
  /// earlier session takes effect before the first connect.
  Future<void> _loadAudioDevices() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final out = prefs.getString('audio_output_device') ?? '';
      final inp = prefs.getString('audio_input_device') ?? '';
      TsNative.setAudioOutputDevice(out);
      TsNative.setAudioInputDevice(inp);
      final devs = TsNative.getAudioDevices();
      if (!mounted) return;
      setState(() {
        _outputDevice = out;
        _inputDevice = inp;
        _outputDevices = (devs['outputs'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        _inputDevices = (devs['inputs'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
      });
    } catch (e) {
      debugPrint('SettingsScreen: audio device load failed: $e');
    }
  }

  Future<void> _onOutputDeviceChanged(String value) async {
    setState(() => _outputDevice = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('audio_output_device', value);
    TsNative.setAudioOutputDevice(value);
  }

  Future<void> _onInputDeviceChanged(String value) async {
    setState(() => _inputDevice = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('audio_input_device', value);
    TsNative.setAudioInputDevice(value);
  }

  Widget _deviceDropdown(
    String label,
    String current,
    List<Map<String, dynamic>> devices,
    ValueChanged<String> onChanged,
  ) {
    final al = AppLocalizations.of(context);
    final items = <DropdownMenuItem<String>>[
      DropdownMenuItem(value: '', child: Text(al.audioSystemDefault)),
      for (final d in devices)
        DropdownMenuItem(
          value: d['name'] as String,
          child: Text(d['name'] as String, overflow: TextOverflow.ellipsis),
        ),
    ];
    return Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
        ),
        Expanded(
          child: DropdownButton<String>(
            value: current,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            dropdownColor: const Color(0xFF1A1A2E),
            items: items,
            onChanged: (v) => onChanged(v ?? ''),
          ),
        ),
      ],
    );
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

  String _closeActionLabel(BuildContext context, WindowCloseAction action) {
    final al = AppLocalizations.of(context);
    return switch (action) {
      WindowCloseAction.ask => al.closeActionAsk,
      WindowCloseAction.hide => al.closeActionHide,
      WindowCloseAction.exit => al.closeActionExit,
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
    if (!OtaService.isSupported) return;
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

  /// Opens the project repository via the platform's external browser/app.
  Future<void> _openGitHub() async {
    final messenger = ScaffoldMessenger.of(context);
    final failed = AppLocalizations.of(context).openLinkFailed;
    try {
      final launched = await launchUrl(
        Uri.parse(_githubUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        messenger.showSnackBar(SnackBar(content: Text(failed)));
      }
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(failed)));
    }
  }

  Future<void> _loadSfxPacks() async {
    final packs = await SfxPackService.loadPacks();
    final active = await SfxPackService.activePackId();
    if (mounted) {
      setState(() {
        _sfxPacks = packs;
        _activeSfxPack = active;
      });
    }
  }

  Future<void> _importSfxPack() async {
    final al = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    SfxPack? pack;
    try {
      pack = await SfxPackService.importZip();
    } on SfxPackImportException catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.error == SfxPackImportError.invalidZip
                ? al.sfxPackInvalidZip
                : al.sfxPackInvalidManifest,
          ),
        ),
      );
      return;
    }
    if (pack == null) return;
    final failed = await SfxPackService.activate(pack.id);
    await _loadSfxPacks();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failed > 0 ? al.sfxPackPartialLoad : al.sfxPackImported(pack.name),
        ),
      ),
    );
  }

  Future<void> _activateSfxPack(SfxPack pack) async {
    final al = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final failed = await SfxPackService.activate(pack.id);
    await _loadSfxPacks();
    if (failed > 0) {
      messenger.showSnackBar(SnackBar(content: Text(al.sfxPackPartialLoad)));
    }
  }

  Future<void> _deactivateSfxPack() async {
    await SfxPackService.deactivate();
    await _loadSfxPacks();
  }

  Future<void> _deleteSfxPack(SfxPack pack) async {
    final al = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(al.delete),
        content: Text(al.sfxPackDeleteBody(pack.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(al.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(al.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await SfxPackService.delete(pack.id);
    if (mounted) await _loadSfxPacks();
  }

  Future<void> _loadBgName() async {
    final name = await BackgroundService.customName();
    if (mounted) setState(() => _bgName = name);
  }

  Future<void> _pickBackground() async {
    final path = await BackgroundService.pickAndStore();
    if (!mounted || path == null) return;
    await ref.read(backgroundSettingsProvider.notifier).setPath(path);
    if (mounted) await _loadBgName();
  }

  Future<void> _resetBackground() async {
    await BackgroundService.reset();
    await ref.read(backgroundSettingsProvider.notifier).setPath(null);
    if (mounted) setState(() => _bgName = null);
  }

  /// Channel sounds as voice packs: the active pack (or the built-in set),
  /// one row per imported pack, and the zip import button.
  Widget _buildSfxSection(BuildContext context) {
    final al = AppLocalizations.of(context);
    final activeIndex = _sfxPacks.indexWhere((p) => p.id == _activeSfxPack);
    final active = activeIndex >= 0 ? _sfxPacks[activeIndex] : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(al.channelSounds),
        const SizedBox(height: 8),
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
                    Icon(
                      active == null ? Icons.graphic_eq : Icons.music_note,
                      color: active == null ? Colors.grey : Colors.blueAccent,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            active?.name ?? al.sfxPackNone,
                            style: TextStyle(
                              color: active == null
                                  ? Colors.grey
                                  : Colors.white,
                              fontSize: 14,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            active == null
                                ? al.sfxPackNoneDesc
                                : (active.description.isNotEmpty
                                      ? active.description
                                      : al.sfxPackActive),
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (active != null)
                      IconButton(
                        onPressed: _deactivateSfxPack,
                        tooltip: al.sfxPackDeactivate,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.all(6),
                        icon: const Icon(Icons.restore, size: 20),
                        color: Colors.blueAccent,
                      ),
                  ],
                ),
                for (final pack in _sfxPacks) ...[
                  const Divider(height: 16, color: Color(0xFF2A2A4A)),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              pack.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (pack.description.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                pack.description,
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 12,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (pack.id != _activeSfxPack)
                        IconButton(
                          onPressed: () => _activateSfxPack(pack),
                          tooltip: al.sfxPackActivate,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(6),
                          icon: const Icon(Icons.play_circle_outline, size: 20),
                          color: Colors.blueAccent,
                        )
                      else
                        const Icon(Icons.check, color: Colors.blue, size: 20),
                      IconButton(
                        onPressed: () => _deleteSfxPack(pack),
                        tooltip: al.sfxPackDelete,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.all(6),
                        icon: const Icon(Icons.delete_outline, size: 20),
                        color: Colors.blueAccent,
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _importSfxPack,
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: Text(al.sfxPackImport),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.blueAccent,
                      side: const BorderSide(color: Color(0xFF2A2A4A)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// User-custom background image: pick / reset + dimming slider. The image
  /// itself is rendered app-wide by the background layer in main.dart.
  Widget _buildBackgroundSection(BuildContext context) {
    final al = AppLocalizations.of(context);
    final settings = ref.watch(backgroundSettingsProvider);
    final hasBg = settings.path != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(al.backgroundSection),
        const SizedBox(height: 8),
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
                    Expanded(
                      child: Text(
                        hasBg ? (_bgName ?? al.sfxDefault) : al.sfxDefault,
                        style: TextStyle(
                          color: hasBg ? Colors.blueAccent : Colors.grey,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      onPressed: hasBg ? _resetBackground : null,
                      tooltip: al.bgReset,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.all(6),
                      icon: const Icon(Icons.restore, size: 20),
                      color: Colors.blueAccent,
                    ),
                    const SizedBox(width: 4),
                    OutlinedButton(
                      onPressed: _pickBackground,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.blueAccent,
                        side: const BorderSide(color: Color(0xFF2A2A4A)),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(
                        al.bgPickImage,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      al.bgDim,
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    Expanded(
                      child: Slider(
                        value: settings.dim,
                        min: 0.0,
                        max: 0.8,
                        activeColor: Colors.blue,
                        onChanged: (v) => ref
                            .read(backgroundSettingsProvider.notifier)
                            .setDim(v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      al.bgOpacity,
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    Expanded(
                      child: Slider(
                        value: settings.opacity,
                        min: 0.1,
                        max: 1.0,
                        activeColor: Colors.blue,
                        onChanged: (v) => ref
                            .read(backgroundSettingsProvider.notifier)
                            .setOpacity(v),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Everything audio related (voice parameters, mic test, channel sounds)
  /// folded into one expandable block, collapsed by default so the settings
  /// page stays scannable.
  Widget _buildAudioSection(BuildContext context) {
    final al = AppLocalizations.of(context);
    final conn = ref.watch(tsConnectionProvider);
    final notifier = ref.read(tsConnectionProvider.notifier);
    final connected = conn.connected;

    return _CollapsibleSection(
      title: al.audio,
      initiallyExpanded: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                        icon: Icon(_micTest ? Icons.stop : Icons.mic, size: 18),
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
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          _buildSfxSection(context),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
            // Voice parameters + mic test + channel sounds, folded away by
            // default (see _buildAudioSection).
            _buildAudioSection(context),
            const SizedBox(height: 24),
            _buildBackgroundSection(context),
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
            // Desktop device picker: choose which output/input device the
            // Rust audio engine uses ('' = follow the system default).
            if (!Platform.isAndroid) ...[
              const SizedBox(height: 24),
              _SectionHeader(AppLocalizations.of(context).audioDevicesSection),
              const SizedBox(height: 8),
              Card(
                color: const Color(0xFF1A1A2E),
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _deviceDropdown(
                        AppLocalizations.of(context).audioOutputDevice,
                        _outputDevice,
                        _outputDevices,
                        _onOutputDeviceChanged,
                      ),
                      const SizedBox(height: 8),
                      _deviceDropdown(
                        AppLocalizations.of(context).audioInputDevice,
                        _inputDevice,
                        _inputDevices,
                        _onInputDeviceChanged,
                      ),
                    ],
                  ),
                ),
              ),
              // Window close behavior: Android has no window close button,
              // so this only shows on desktop.
              const SizedBox(height: 24),
              _SectionHeader(AppLocalizations.of(context).windowSection),
              const SizedBox(height: 8),
              Card(
                color: const Color(0xFF1A1A2E),
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: RadioGroup<WindowCloseAction>(
                    groupValue: ref.watch(windowSettingsProvider).closeAction,
                    onChanged: (action) {
                      if (action == null) return;
                      ref
                          .read(windowSettingsProvider.notifier)
                          .setCloseAction(action);
                    },
                    child: Column(
                      children: [
                        for (final action in WindowCloseAction.values)
                          RadioListTile<WindowCloseAction>(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            activeColor: Colors.blue,
                            title: Text(
                              _closeActionLabel(context, action),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                            value: action,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            // OTA = APK downloads from the release channel — Android-only.
            if (OtaService.isSupported) ...[
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
                                  source == OtaSource.auto
                                      ? AppLocalizations.of(
                                          context,
                                        ).updateSourceAuto
                                      : source.label,
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
            // About: app identity + version + project link, all platforms
            // (the OTA section above is Android-only).
            const SizedBox(height: 24),
            _SectionHeader(AppLocalizations.of(context).about),
            const SizedBox(height: 8),
            Card(
              color: const Color(0xFF1A1A2E),
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.asset(
                            'assets/logo.png',
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'NEk0',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (_version.isNotEmpty)
                                Text(
                                  AppLocalizations.of(
                                    context,
                                  ).appVersion(_version),
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 20, color: Color(0xFF2A2A4A)),
                    InkWell(
                      onTap: _openGitHub,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.code,
                              color: Colors.grey,
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                AppLocalizations.of(context).viewOnGitHub,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            const Icon(
                              Icons.open_in_new,
                              color: Colors.grey,
                              size: 16,
                            ),
                          ],
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

/// Expandable settings block with a tappable header row (title + rotating
/// chevron) and an animated reveal of [child]. Matches the app's dark card
/// styling.
class _CollapsibleSection extends StatefulWidget {
  final String title;
  final Widget child;
  final bool initiallyExpanded;

  const _CollapsibleSection({
    required this.title,
    required this.child,
    this.initiallyExpanded = false,
  });

  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                    color: Colors.blueAccent,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                AnimatedRotation(
                  turns: _expanded ? 0.0 : -0.25,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(
                    Icons.keyboard_arrow_down,
                    size: 20,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity),
          secondChild: SizedBox(width: double.infinity, child: widget.child),
          crossFadeState: _expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
          sizeCurve: Curves.easeInOut,
        ),
      ],
    );
  }
}
