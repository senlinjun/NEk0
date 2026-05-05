import 'package:flutter/material.dart';

class ConnectionBar extends StatelessWidget {
  final String serverName;
  final bool connected;
  final VoidCallback onDisconnect;

  const ConnectionBar({
    super.key,
    required this.serverName,
    required this.connected,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: const Color(0xFF16213E),
      child: Row(
        children: [
          Icon(
            connected ? Icons.cloud_done : Icons.cloud_off,
            color: connected ? Colors.green : Colors.red,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              connected ? serverName : 'Disconnected',
              style: TextStyle(
                color: connected ? Colors.white : Colors.grey,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (connected)
            IconButton(
              icon: const Icon(Icons.logout, color: Colors.red, size: 18),
              onPressed: onDisconnect,
              tooltip: 'Disconnect',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
        ],
      ),
    );
  }
}
