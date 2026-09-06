import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';

/// Privilege-key prompt shown when the server announced
/// `ask_for_privilegekey` (typically on the very first login, when the
/// server admin hands out a token). Dark-themed to match the other dialogs
/// (e.g. the channel-password prompt). Returns the entered key, or null
/// when the user cancelled.
Future<String?> showPrivilegeKeyDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => const _PrivilegeKeyDialog(),
  );
}

/// Owns its [TextEditingController] so the controller outlives the dialog's
/// exit transition (see [showChannelPasswordDialog] for the full rationale).
class _PrivilegeKeyDialog extends StatefulWidget {
  const _PrivilegeKeyDialog();

  @override
  State<_PrivilegeKeyDialog> createState() => _PrivilegeKeyDialogState();
}

class _PrivilegeKeyDialogState extends State<_PrivilegeKeyDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final al = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: Text(
        al.privilegeKeyTitle,
        style: const TextStyle(color: Colors.white, fontSize: 18),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            al.privilegeKeyBody,
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            // Keys are copy-pasted strings; keep them readable.
            obscureText: false,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: al.privilegeKeyHint,
              hintStyle: const TextStyle(color: Colors.grey),
            ),
            onSubmitted: (text) => Navigator.of(context).pop(text),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(al.cancel, style: const TextStyle(color: Colors.grey)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(al.ok, style: const TextStyle(color: Colors.blueAccent)),
        ),
      ],
    );
  }
}
