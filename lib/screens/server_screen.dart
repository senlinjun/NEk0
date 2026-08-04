import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/generated/app_localizations.dart';

import '../models/client.dart';
import '../models/ts_state.dart';
import '../services/foreground_service.dart';
import '../widgets/channel_tree.dart';
import '../widgets/client_list.dart';
import '../widgets/chat_panel.dart';
import '../widgets/connection_bar.dart';
import '../widgets/spotlight_tour.dart';
import '../widgets/voice_settings_panel.dart';

class ServerScreen extends ConsumerStatefulWidget {
  const ServerScreen({super.key});

  @override
  ConsumerState<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends ConsumerState<ServerScreen> {
  int _lastSeenMessageCount = 0;

  // Targets for the first-use spotlight guide.
  final GlobalKey _micKey = GlobalKey();
  final GlobalKey _headsetKey = GlobalKey();
  final GlobalKey _speakerKey = GlobalKey();
  final GlobalKey _chatKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoShowGuide());
  }

  /// Show the control-bar guide the first time the server screen is opened.
  Future<void> _maybeAutoShowGuide() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('tour_server_shown') ?? false) return;
    await prefs.setBool('tour_server_shown', true);
    if (!mounted) return;
    await _showGuide();
  }

  Future<void> _showGuide() async {
    final al = AppLocalizations.of(context);
    await showSpotlightTour(context, [
      TourStep(
        targetKey: _micKey,
        padding: 4,
        title: al.guideMicTitle,
        description: al.guideMicDesc,
      ),
      TourStep(
        targetKey: _headsetKey,
        padding: 4,
        title: al.guideHeadsetTitle,
        description: al.guideHeadsetDesc,
      ),
      TourStep(
        targetKey: _speakerKey,
        padding: 4,
        title: al.guideSpeakerTitle,
        description: al.guideSpeakerDesc,
      ),
      TourStep(
        targetKey: _chatKey,
        padding: 4,
        title: al.guideChatTitle,
        description: al.guideChatDesc,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(tsConnectionProvider.select((s) => s.connected), (prev, next) {
      if (prev == true && !next && mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      if (prev == false && next && mounted) {
        _maybeShowOemGuide();
      }
    });
    // Pop on connect failure (connecting finished without success)
    ref.listen(tsConnectionProvider.select((s) => s.connecting), (prev, next) {
      if (prev == true && !next && mounted) {
        final st = ref.read(tsConnectionProvider);
        if (!st.connected) {
          Navigator.of(context).pop(st.error);
        }
      }
    });
    final conn = ref.watch(tsConnectionProvider);
    final connNotifier = ref.read(tsConnectionProvider.notifier);

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F23),
      body: SafeArea(
        child: Column(
          children: [
            ConnectionBar(
              serverName: conn.serverName,
              connected: conn.connected,
              onDisconnect: () {
                connNotifier.disconnect();
              },
              onShowGuide: _showGuide,
            ),
            Expanded(
              child: conn.connecting
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.blue),
                    )
                  : _buildLeftPanel(conn, connNotifier),
            ),
            _buildChatBar(conn),
            _buildControls(conn, connNotifier),
          ],
        ),
      ),
    );
  }

  Widget _buildLeftPanel(
    TsConnectionState conn,
    TsConnectionNotifier notifier,
  ) {
    return Container(
      color: const Color(0xFF12122A),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            color: const Color(0xFF16213E),
            width: double.infinity,
            child: Text(
              AppLocalizations.of(context).channels,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: ChannelTree(
              channels: conn.channels,
              selectedChannelId: conn.selectedChannelId,
              onChannelTap: notifier.selectChannel,
            ),
          ),
          const Divider(height: 1, color: Color(0xFF2A2A4A)),
          Container(
            padding: const EdgeInsets.all(8),
            color: const Color(0xFF16213E),
            width: double.infinity,
            child: Text(
              AppLocalizations.of(context).users,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (conn.selectedChannelId == null)
            Expanded(flex: 2, child: SizedBox.shrink()),
          if (conn.selectedChannelId != null)
            Expanded(
              flex: 2,
              child: ClientList(
                clients: conn.clients,
                currentChannelId: conn.selectedChannelId!,
                onClientTap: (clientId) => _showClientVolume(clientId),
              ),
            ),
        ],
      ),
    );
  }

  /// First-connect-only dialog guiding the user to whitelist the app in
  /// OEM battery/auto-start settings (MIUI/HyperOS/EMUI/ColorOS/OriginOS).
  /// The battery-optimization exemption is requested only AFTER the user
  /// acknowledges the dialog, so they know why the settings page opens.
  Future<void> _maybeShowOemGuide() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('oem_guide_shown') ?? false) return;
    await prefs.setBool('oem_guide_shown', true);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Text(
          AppLocalizations.of(ctx).keepAliveTitle,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          AppLocalizations.of(ctx).keepAliveBody,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppLocalizations.of(ctx).gotIt),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      // User acknowledged the dialog — now open the battery optimization page.
      ForegroundService.requestBatteryOptimizationExemption();
    }
  }

  void _showClientVolume(int clientId) {
    final conn = ref.read(tsConnectionProvider);
    final connNotifier = ref.read(tsConnectionProvider.notifier);
    final client = conn.clients.where((c) => c.id == clientId).firstOrNull;
    if (client == null) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF12122A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) =>
          _ClientVolumeSheet(client: client, notifier: connNotifier),
    );
  }

  void _openChat() async {
    final conn = ref.read(tsConnectionProvider);
    if (conn.selectedChannelId == null) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF12122A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: ChatPanel(channelId: conn.selectedChannelId!),
      ),
    );
    // Reset badge after sheet closes (re-read for latest count)
    if (mounted) {
      final latest = ref.read(tsConnectionProvider);
      setState(() => _lastSeenMessageCount = latest.messages.length);
    }
  }

  Widget _buildChatBar(TsConnectionState conn) {
    final lastMsg = conn.messages.isNotEmpty ? conn.messages.last : null;
    final unread = conn.messages.length - _lastSeenMessageCount;

    return GestureDetector(
      key: _chatKey,
      onTap: _openChat,
      child: Container(
        height: 36,
        color: const Color(0xFF16213E),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const Icon(Icons.chat_bubble_outline, color: Colors.grey, size: 16),
            const SizedBox(width: 8),
            Text(
              AppLocalizations.of(context).chat,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const Spacer(),
            if (lastMsg != null)
              Flexible(
                child: Text(
                  '${lastMsg.fromClient}: ${lastMsg.message}',
                  style: const TextStyle(
                    color: Color(0xFF555577),
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            if (unread > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.blue,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$unread',
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ],
            const SizedBox(width: 4),
            const Icon(Icons.keyboard_arrow_up, color: Colors.grey, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(TsConnectionState conn, TsConnectionNotifier notifier) {
    // Mic color: red=muted, green=on-idle, blue=speaking/PTT-active
    Color micColor;
    if (conn.inputMuted) {
      micColor = Colors.red;
    } else if (conn.pttMode) {
      micColor = conn.pttPressed ? Colors.blue : Colors.green;
    } else {
      micColor = conn.voiceActive ? Colors.blue : Colors.green;
    }

    return Container(
      height: 52,
      color: const Color(0xFF16213E),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // --- Mic icon (tap mute, long-press settings) ---
          GestureDetector(
            key: _micKey,
            onTap: () => notifier.toggleInputMute(),
            onLongPress: () => _showVoiceSettings(conn, notifier),
            child: Icon(Icons.mic, color: micColor, size: 28),
          ),
          const SizedBox(width: 24),
          // --- Headset button (full mute: input + output + mic off) ---
          GestureDetector(
            key: _headsetKey,
            onTap: () => notifier.toggleFullMute(),
            child: Icon(
              Icons.headset,
              color: conn.inputMuted || conn.outputMuted
                  ? Colors.red
                  : Colors.green,
              size: 28,
            ),
          ),
          // --- PTT button (only in PTT mode) ---
          if (conn.pttMode) ...[
            const SizedBox(width: 24),

            IgnorePointer(
              ignoring: conn.inputMuted,
              child: Listener(
                onPointerDown: (_) => notifier.setPttPressed(true),
                onPointerUp: (_) => notifier.setPttPressed(false),
                onPointerCancel: (_) => notifier.setPttPressed(false),
                child: Container(
                  width: 64,
                  height: 40,
                  decoration: BoxDecoration(
                    color: conn.pttPressed
                        ? const Color(0xFF4444AA)
                        : const Color(0xFF2A2A4A),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFF888888),
                      // color: conn.pttPressed
                      //     ? Colors.lightGreenAccent
                      //     : const Color(0xFF888888),
                      width: 2,
                    ),
                  ),
                  child: const Center(
                    child: Text(
                      'PTT',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: 24),
          // --- Speaker icon (toggle output mute) ---
          GestureDetector(
            key: _speakerKey,
            onTap: () => notifier.toggleOutputMute(),
            child: Icon(
              Icons.volume_up,
              color: conn.outputMuted ? Colors.red : Colors.green,
              size: 28,
            ),
          ),
        ],
      ),
    );
  }

  void _showVoiceSettings(
    TsConnectionState conn,
    TsConnectionNotifier notifier,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF12122A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: VoiceSettingsPanel(conn: conn, notifier: notifier),
        );
      },
    );
  }
}

// ─── Per-client volume sheet ────────────────────────────────────────

class _ClientVolumeSheet extends StatefulWidget {
  final TsClient client;
  final TsConnectionNotifier notifier;

  const _ClientVolumeSheet({required this.client, required this.notifier});

  @override
  State<_ClientVolumeSheet> createState() => _ClientVolumeSheetState();
}

class _ClientVolumeSheetState extends State<_ClientVolumeSheet> {
  late double _volume;

  @override
  void initState() {
    super.initState();
    _volume = widget.client.volume;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.client;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                c.isTalking ? Icons.mic : Icons.person,
                color: c.isTalking ? Colors.blue : Colors.grey,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                c.nickname,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (c.isTalking)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    AppLocalizations.of(context).talking,
                    style: const TextStyle(color: Colors.blue, fontSize: 11),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                AppLocalizations.of(context).volume,
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: _volume,
                  min: -20.0,
                  max: 20.0,
                  divisions: 80,
                  activeColor: Colors.blue,
                  onChanged: (v) {
                    setState(() => _volume = v);
                    widget.notifier.setClientVolume(c.id, v);
                  },
                ),
              ),
              SizedBox(
                width: 52,
                child: Text(
                  '${_volume.toStringAsFixed(1)} dB',
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
