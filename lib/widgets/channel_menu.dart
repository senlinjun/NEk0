import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/channel.dart';

/// Result values the sheet pops with so the caller can react after close.
const channelMenuJoin = 'join';
const channelMenuFileManager = 'file_manager';
const channelMenuCreateSub = 'create_sub';
const channelMenuEdit = 'edit';
const channelMenuMoveUp = 'move_up';
const channelMenuMoveDown = 'move_down';
const channelMenuDelete = 'delete';

/// Result values of [showServerMenu].
const serverMenuCreateChannel = 'create_channel';
const serverMenuEditServer = 'edit_server';

/// Bottom sheet opened by a long press (or swapped short tap) on a channel
/// row. First entry joins the channel, second opens its file management —
/// keep this order when adding further entries later.
///
/// [canCreateChannel] shows the "create sub-channel" entry (the caller
/// computes it from the admin heuristics — there is no per-channel hint for
/// channel creation). [canMoveUp]/[canMoveDown] re-position the channel
/// among its siblings (the caller knows whether a neighbor exists). Edit/
/// delete follow the file-manager convention: shown while the hints are
/// still unknown, hidden once the server denies them.
Future<String?> showChannelMenu(
  BuildContext context,
  TsChannel channel, {
  bool canCreateChannel = false,
  bool canMoveUp = false,
  bool canMoveDown = false,
}) async {
  final al = AppLocalizations.of(context);
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF12122A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (ctx) => SafeArea(
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Small drag handle like the other sheets in the app.
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.tag, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      channel.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFF2A2A4A)),
            // Join channel — always the first entry.
            ListTile(
              leading: const Icon(
                Icons.login,
                size: 22,
                color: Colors.blueAccent,
              ),
              title: Text(
                al.menuEnterChannel,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => Navigator.of(ctx).pop(channelMenuJoin),
            ),
            // File management — only when we may browse (or upload to) this
            // channel's file area. The hints arrive from the server shortly
            // after connect; `permissionHints == 0` means "not known yet"
            // and the entry stays visible (a denied request surfaces a
            // server error in the file manager anyway).
            if (channel.permissionHints == 0 ||
                channel.canFileBrowse ||
                channel.canFileUpload)
              ListTile(
                leading: const Icon(
                  Icons.folder_open,
                  size: 22,
                  color: Colors.blueAccent,
                ),
                title: Text(
                  al.menuFileManager,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                onTap: () => Navigator.of(ctx).pop(channelMenuFileManager),
              ),
            // Create a sub-channel under this one.
            if (canCreateChannel)
              ListTile(
                leading: const Icon(
                  Icons.add_circle_outline,
                  size: 22,
                  color: Colors.blueAccent,
                ),
                title: Text(
                  al.menuCreateChannel,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                onTap: () => Navigator.of(ctx).pop(channelMenuCreateSub),
              ),
            // Edit this channel's settings — hidden once the server's hints
            // explicitly deny modification.
            if (channel.permissionHints == 0 || channel.canModify)
              ListTile(
                leading: const Icon(
                  Icons.tune,
                  size: 22,
                  color: Colors.blueAccent,
                ),
                title: Text(
                  al.menuEditChannel,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                onTap: () => Navigator.of(ctx).pop(channelMenuEdit),
              ),
            // Re-order among siblings (TS3 keeps sibling channels in a
            // linked list — the caller computes whether a neighbor exists).
            if (canMoveUp)
              ListTile(
                leading: const Icon(
                  Icons.arrow_upward,
                  size: 22,
                  color: Colors.blueAccent,
                ),
                title: Text(
                  al.menuMoveUp,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                onTap: () => Navigator.of(ctx).pop(channelMenuMoveUp),
              ),
            if (canMoveDown)
              ListTile(
                leading: const Icon(
                  Icons.arrow_downward,
                  size: 22,
                  color: Colors.blueAccent,
                ),
                title: Text(
                  al.menuMoveDown,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                onTap: () => Navigator.of(ctx).pop(channelMenuMoveDown),
              ),
            // Delete this channel — destructive, therefore last.
            if (channel.permissionHints == 0 || channel.canDelete)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  size: 22,
                  color: Colors.redAccent,
                ),
                title: Text(
                  al.menuDeleteChannel,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 14),
                ),
                onTap: () => Navigator.of(ctx).pop(channelMenuDelete),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

/// Bottom sheet for a tap / long-press / right-click on the server root
/// node. Always opens — the server row has no permission hints, so the
/// entries decide visibility themselves: "edit server" opens the server
/// settings page (read-only when we look unprivileged), channel creation
/// follows [canCreateChannel]. Pops [serverMenuEditServer],
/// [serverMenuCreateChannel], or null when dismissed.
Future<String?> showServerMenu(
  BuildContext context, {
  required bool canCreateChannel,
}) async {
  final al = AppLocalizations.of(context);
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF12122A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (ctx) => SafeArea(
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Small drag handle like the other sheets in the app.
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.dns, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      al.menuServerTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFF2A2A4A)),
            ListTile(
              leading: const Icon(
                Icons.tune,
                size: 22,
                color: Colors.blueAccent,
              ),
              title: Text(
                al.menuEditServer,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              onTap: () => Navigator.of(ctx).pop(serverMenuEditServer),
            ),
            if (canCreateChannel)
              ListTile(
                leading: const Icon(
                  Icons.add_circle_outline,
                  size: 22,
                  color: Colors.blueAccent,
                ),
                title: Text(
                  al.menuCreateChannel,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                onTap: () => Navigator.of(ctx).pop(serverMenuCreateChannel),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}
