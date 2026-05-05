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
  int _lastSeenMessageCount = 0;

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
          if (conn.selectedChannelId == null)
            Expanded(
              flex: 2,
              child: SizedBox.shrink(),
            ),
          if (conn.selectedChannelId != null)
            Expanded(
              flex: 2,
              child: ClientList(
                clients: conn.clients,
                currentChannelId: conn.selectedChannelId!,
                onClientTap: (clientId) {},
              ),
            ),
        ],
      ),
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
      onTap: _openChat,
      child: Container(
        height: 36,
        color: const Color(0xFF16213E),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const Icon(Icons.chat_bubble_outline,
                color: Colors.grey, size: 16),
            const SizedBox(width: 8),
            const Text('Chat',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
            const Spacer(),
            if (lastMsg != null)
              Flexible(
                child: Text(
                  '${lastMsg.fromClient}: ${lastMsg.message}',
                  style: const TextStyle(
                      color: Color(0xFF555577), fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            if (unread > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.blue,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('$unread',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 10)),
              ),
            ],
            const SizedBox(width: 4),
            const Icon(Icons.keyboard_arrow_up,
                color: Colors.grey, size: 18),
          ],
        ),
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
