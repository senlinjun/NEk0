import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/app_locale.dart';
import '../models/ts_state.dart';
import '../services/audio_service.dart';
import '../services/ota_service.dart';
import '../services/sfx_service.dart';
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
  final Map<int, String?> _sfxNames = {};

  @override
  void initState() {
    super.initState();
    _ota.load().then((_) {
      if (mounted) setState(() => _otaLoaded = true);
    });
    _loadLanguage();
    _loadSfxNames();
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

  Future<void> _loadSfxNames() async {
    final names = <int, String?>{};
    for (final kind in SfxKind.all) {
      names[kind] = await SfxService.customName(kind);
    }
    if (mounted) {
      setState(() {
        _sfxNames
          ..clear()
          ..addAll(names);
      });
    }
  }

  Future<void> _pickSfx(int kind) async {
    PlatformFile? file;
    try {
      file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['wav'],
      );
    } catch (_) {
      file = null;
    }
    if (!mounted || file == null) return;
    Uint8List? bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      bytes = null;
    }
    final al = AppLocalizations.of(context);
    if (bytes == null || bytes.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(al.sfxFormatError)));
      return;
    }
    var code = SfxError.invalidKind;
    try {
      code = await SfxService.setCustom(kind, bytes, fileName: file.name);
    } catch (_) {
      code = SfxError.invalidKind;
    }
    if (!mounted) return;
    switch (code) {
      case SfxError.emptyOrTooLong:
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(al.sfxTooLong)));
        break;
      case 0:
        await _loadSfxNames();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(al.sfxImported)));
        break;
      default:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              code == SfxError.unsupportedFormat
                  ? al.sfxFormatError
                  : al.sfxImportFailed,
            ),
          ),
        );
    }
  }

  Future<void> _resetSfx(int kind) async {
    try {
      await SfxService.resetToDefault(kind);
    } catch (_) {
      // Ignore file/prefs errors — the built-in sample is still restored
      // next time the app starts if the file could not be deleted.
    }
    if (mounted) await _loadSfxNames();
  }

  void _previewSfx(int kind) {
    SfxService.preview(kind);
  }

  String _sfxLabel(AppLocalizations al, int kind) {
    return switch (kind) {
      SfxKind.channelSwitched => al.sfxChannelSwitched,
      SfxKind.neutralToCurrent => al.sfxNeutralToCurrent,
      SfxKind.neutralAwayFromCurrent => al.sfxNeutralAwayFromCurrent,
      SfxKind.youWereMoved => al.sfxYouWereMoved,
      SfxKind.youKickedChannel => al.sfxYouKickedChannel,
      SfxKind.youKickedServer => al.sfxYouKickedServer,
      SfxKind.youWereBanned => al.sfxYouWereBanned,
      SfxKind.youWerePoked => al.sfxYouWerePoked,
      SfxKind.chatInbound => al.sfxChatInbound,
      SfxKind.chatOutbound => al.sfxChatOutbound,
      SfxKind.connected => al.sfxConnected,
      SfxKind.disconnected => al.sfxDisconnected,
      SfxKind.connectionLost => al.sfxConnectionLost,
      SfxKind.error => al.sfxError,
      SfxKind.micActivated => al.sfxMicActivated,
      SfxKind.micMuted => al.sfxMicMuted,
      SfxKind.soundMuted => al.sfxSoundMuted,
      SfxKind.soundResumed => al.sfxSoundResumed,
      SfxKind.awayActivated => al.sfxAwayActivated,
      SfxKind.awayDeactivated => al.sfxAwayDeactivated,
      SfxKind.channelCreated => al.sfxChannelCreated,
      SfxKind.channelDeleted => al.sfxChannelDeleted,
      SfxKind.channelEdited => al.sfxChannelEdited,
      SfxKind.channelMoved => al.sfxChannelMoved,
      SfxKind.channelgroupChanged => al.sfxChannelgroupChanged,
      SfxKind.neutralConnConnected => al.sfxNeutralConnConnected,
      SfxKind.neutralConnDisconnected => al.sfxNeutralConnDisconnected,
      SfxKind.neutralConnConnectionLost => al.sfxNeutralConnConnectionLost,
      SfxKind.neutralMovedToCurrent => al.sfxNeutralMovedToCurrent,
      SfxKind.neutralMovedAwayFromCurrent => al.sfxNeutralMovedAwayFromCurrent,
      SfxKind.neutralKickedChannelToCurrent =>
        al.sfxNeutralKickedChannelToCurrent,
      SfxKind.neutralKickedChannelAwayFromCurrent =>
        al.sfxNeutralKickedChannelAwayFromCurrent,
      SfxKind.neutralKickedServer => al.sfxNeutralKickedServer,
      SfxKind.neutralBannedServer => al.sfxNeutralBannedServer,
      SfxKind.neutralRecordingStarted => al.sfxNeutralRecordingStarted,
      SfxKind.neutralRecordingStopped => al.sfxNeutralRecordingStopped,
      _ => al.sfxNeutralRecordingActive,
    };
  }

  Widget _buildSfxRow(BuildContext context, int kind) {
    final al = AppLocalizations.of(context);
    final label = _sfxLabel(al, kind);
    final name = _sfxNames[kind];
    final isCustom = name != null && name.isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 2),
              Text(
                isCustom ? name : al.sfxDefault,
                style: TextStyle(
                  color: isCustom ? Colors.blueAccent : Colors.grey,
                  fontSize: 12,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: () => _previewSfx(kind),
          tooltip: al.sfxPreview,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(6),
          icon: const Icon(Icons.play_circle_outline, size: 20),
          color: Colors.blueAccent,
        ),
        IconButton(
          onPressed: isCustom ? () => _resetSfx(kind) : null,
          tooltip: al.sfxReset,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(6),
          icon: const Icon(Icons.restore, size: 20),
          color: Colors.blueAccent,
        ),
        const SizedBox(width: 4),
        OutlinedButton(
          onPressed: () => _pickSfx(kind),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.blueAccent,
            side: const BorderSide(color: Color(0xFF2A2A4A)),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            visualDensity: VisualDensity.compact,
          ),
          child: Text(al.sfxSelectWav, style: const TextStyle(fontSize: 12)),
        ),
      ],
    );
  }

  /// SFX rows grouped by category: (group header, kinds in display order).
  static final List<(String Function(AppLocalizations), List<int>)> _sfxGroups =
      [
        (
          (al) => al.sfxGroupConnection,
          const [
            SfxKind.connected,
            SfxKind.disconnected,
            SfxKind.connectionLost,
            SfxKind.error,
          ],
        ),
        (
          (al) => al.sfxGroupChannel,
          const [
            SfxKind.channelSwitched,
            SfxKind.channelCreated,
            SfxKind.channelDeleted,
            SfxKind.channelEdited,
            SfxKind.channelMoved,
            SfxKind.channelgroupChanged,
          ],
        ),
        (
          (al) => al.sfxGroupUsers,
          const [
            SfxKind.neutralToCurrent,
            SfxKind.neutralAwayFromCurrent,
            SfxKind.neutralMovedToCurrent,
            SfxKind.neutralMovedAwayFromCurrent,
            SfxKind.neutralKickedChannelToCurrent,
            SfxKind.neutralKickedChannelAwayFromCurrent,
            SfxKind.neutralKickedServer,
            SfxKind.neutralBannedServer,
            SfxKind.neutralConnConnected,
            SfxKind.neutralConnDisconnected,
            SfxKind.neutralConnConnectionLost,
            SfxKind.neutralRecordingStarted,
            SfxKind.neutralRecordingStopped,
            SfxKind.neutralRecordingActive,
          ],
        ),
        (
          (al) => al.sfxGroupAboutYou,
          const [
            SfxKind.youWereMoved,
            SfxKind.youKickedChannel,
            SfxKind.youKickedServer,
            SfxKind.youWereBanned,
            SfxKind.youWerePoked,
          ],
        ),
        (
          (al) => al.sfxGroupChat,
          const [SfxKind.chatInbound, SfxKind.chatOutbound],
        ),
        (
          (al) => al.sfxGroupVoice,
          const [
            SfxKind.micActivated,
            SfxKind.micMuted,
            SfxKind.soundMuted,
            SfxKind.soundResumed,
          ],
        ),
        (
          (al) => al.sfxGroupOther,
          const [SfxKind.awayActivated, SfxKind.awayDeactivated],
        ),
      ];

  Widget _buildSfxSection(BuildContext context) {
    final al = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(al.channelSounds),
        const SizedBox(height: 8),
        for (final (header, kinds) in _sfxGroups) ...[
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 6),
            child: Text(
              header(al),
              style: const TextStyle(color: Color(0xFF8888AA), fontSize: 12),
            ),
          ),
          Card(
            color: const Color(0xFF1A1A2E),
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Column(
                children: [
                  for (final kind in kinds) ...[
                    if (kind != kinds.first)
                      const Divider(height: 1, color: Color(0xFF2A2A4A)),
                    _buildSfxRow(context, kind),
                  ],
                ],
              ),
            ),
          ),
        ],
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
            // Voice parameters + mic test + channel sounds, folded away by
            // default (see _buildAudioSection).
            _buildAudioSection(context),
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
