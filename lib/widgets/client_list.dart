import 'package:flutter/material.dart';
import '../models/client.dart';

class ClientList extends StatelessWidget {
  final List<TsClient> clients;
  final int currentChannelId;
  final ValueChanged<int>? onClientTap;

  const ClientList({
    super.key,
    required this.clients,
    required this.currentChannelId,
    this.onClientTap,
  });

  @override
  Widget build(BuildContext context) {
    final channelClients = clients
        .where((c) => c.channelId == currentChannelId)
        .toList();

    if (channelClients.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'No users in this channel',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: channelClients.length,
      itemBuilder: (context, index) {
        final client = channelClients[index];
        return ListTile(
          dense: true,
          leading: SizedBox(
            width: 22,
            height: 22,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  _clientIcon(client),
                  size: 18,
                  color: _clientColor(client),
                ),
                if (client.isTalking)
                  const Positioned(
                    right: 0,
                    bottom: 0,
                    child: Icon(Icons.circle, size: 8, color: Colors.blue),
                  ),
              ],
            ),
          ),
          title: Text(
            client.nickname,
            style: TextStyle(
              color: client.away ? Colors.grey : Colors.white,
              fontSize: 13,
            ),
          ),
          onTap: () => onClientTap?.call(client.id),
        );
      },
    );
  }

  IconData _clientIcon(TsClient client) {
    if (client.outputMuted) return Icons.headset_off;
    if (client.inputMuted) return Icons.mic_off;
    if (client.away) return Icons.access_time;
    return Icons.person;
  }

  Color _clientColor(TsClient client) {
    if (client.away) return Colors.grey;
    if (client.inputMuted || client.outputMuted) return Colors.orange;
    return Colors.green;
  }
}
