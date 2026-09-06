import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';

class ConnectionBar extends StatelessWidget {
  final String serverName;
  final bool connected;
  final VoidCallback onDisconnect;
  final VoidCallback? onShowGuide;

  const ConnectionBar({
    super.key,
    required this.serverName,
    required this.connected,
    required this.onDisconnect,
    this.onShowGuide,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      // Translucent so a custom background tints through.
      color: const Color(0xD916213E),
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
              connected
                  ? serverName
                  : AppLocalizations.of(context).disconnected,
              style: TextStyle(
                color: connected ? Colors.white : Colors.grey,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onShowGuide != null)
            IconButton(
              icon: const Icon(
                Icons.help_outline,
                color: Colors.white70,
                size: 18,
              ),
              onPressed: onShowGuide,
              tooltip: AppLocalizations.of(context).guide,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          const SizedBox(width: 12),
          if (connected)
            IconButton(
              icon: const Icon(Icons.logout, color: Colors.red, size: 18),
              onPressed: onDisconnect,
              tooltip: AppLocalizations.of(context).disconnect,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
        ],
      ),
    );
  }
}
