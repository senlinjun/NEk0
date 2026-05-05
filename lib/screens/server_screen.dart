import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ts_state.dart';
import '../widgets/channel_tree.dart';
import '../widgets/client_list.dart';
import '../widgets/chat_panel.dart';
import '../widgets/connection_bar.dart';

class ServerScreen extends ConsumerStatefulWidget {
  const ServerScreen({super.key});

  @override
  ConsumerState<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends ConsumerState<ServerScreen> {
  @override
  Widget build(BuildContext context) {
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
            onDisconnect: () async {
              debugPrint('SERVER_SCREEN: disconnect tapped');
              await connNotifier.disconnect();
              // Keep polling for Rust diag messages (event loop needs time)
              for (int i = 0; i < 15; i++) {
                await Future.delayed(const Duration(milliseconds: 200));
                connNotifier.pollForDisconnectDiag();
              }
              debugPrint('SERVER_SCREEN: disconnect done, mounted=$mounted');
              if (mounted) Navigator.of(context).pop();
            },
          ),
          Expanded(
            child: conn.connecting
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.blue))
                : Row(
                    children: [
                      SizedBox(
                        width: 260,
                        child: _buildLeftPanel(conn, connNotifier),
                      ),
                      const VerticalDivider(
                          width: 1, color: Color(0xFF2A2A4A)),
                      Expanded(
                        child: conn.selectedChannelId != null
                            ? ChatPanel(channelId: conn.selectedChannelId!)
                            : const Center(
                                child: Text('Select a channel',
                                    style: TextStyle(color: Colors.grey)),
                              ),
                      ),
                    ],
                  ),
          ),
          _buildControls(conn, connNotifier),
        ],
      ),
      ),
    );
  }

  Widget _buildLeftPanel(
      TsConnectionState conn, TsConnectionNotifier notifier) {
    return Container(
      color: const Color(0xFF12122A),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            color: const Color(0xFF16213E),
            width: double.infinity,
            child: const Text(
              'Channels',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold),
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
            child: const Text(
              'Users',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold),
            ),
          ),
          // Diagnostic log (always visible when connected)
          if (conn.connected)
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              color: const Color(0xFF0A0A1A),
              child: Row(
                children: [
                  const Icon(Icons.bug_report, color: Colors.green, size: 12),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      conn.diagMessages.isNotEmpty
                          ? conn.diagMessages.last
                          : 'Dec:${conn.audioDecodedCount} Err:${conn.audioErrorCount} Buf:${conn.audioBufSamples} Mic:${conn.inputMuted ? "MUTED" : "ON"}',
                      style: const TextStyle(color: Colors.grey, fontSize: 9, fontFamily: 'monospace'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            flex: 2,
            child: conn.selectedChannelId != null
                ? ClientList(
                    clients: conn.clients,
                    currentChannelId: conn.selectedChannelId!,
                    onClientTap: (clientId) {
                      // TODO: Open private chat
                    },
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(
      TsConnectionState conn, TsConnectionNotifier notifier) {
    return Container(
      height: 52,
      color: const Color(0xFF16213E),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: Icon(
              conn.inputMuted ? Icons.mic_off : Icons.mic,
              color: conn.inputMuted ? Colors.red : Colors.green,
              size: 28,
            ),
            onPressed: notifier.toggleInputMute,
            tooltip: conn.inputMuted ? 'Unmute Mic' : 'Mute Mic',
          ),
          const SizedBox(width: 24),
          IconButton(
            icon: Icon(
              conn.outputMuted ? Icons.volume_off : Icons.volume_up,
              color: conn.outputMuted ? Colors.red : Colors.green,
              size: 28,
            ),
            onPressed: notifier.toggleOutputMute,
            tooltip: conn.outputMuted ? 'Unmute Speaker' : 'Mute Speaker',
          ),
        ],
      ),
    );
  }
}
