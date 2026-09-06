import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/server_info.dart';

enum ServerEditAction { save, createChannel }

/// The outcome of the server settings page. [ServerEditAction.save] carries
/// the edited values (null = leave untouched; [password] '' clears the
/// server password, a value sets it — it can never be read back, so there
/// is no prefill). [ServerEditAction.createChannel] asks the caller to open
/// the channel form at top level.
class ServerEditResult {
  final ServerEditAction action;

  final String? name;
  final String? password;
  final int? maxClients;

  const ServerEditResult.save({this.name, this.password, this.maxClients})
    : action = ServerEditAction.save;

  const ServerEditResult.createChannel()
    : action = ServerEditAction.createChannel,
      name = null,
      password = null,
      maxClients = null;
}

/// Pushes the full-screen server settings page (opened from the server root
/// node in the channel tree). [canEdit] — the same admin heuristics as the
/// channel management entries — enables the form; without it the page is
/// read-only info. [canCreateChannel] shows the create-channel entry (it
/// moved here from the old server menu). Returns the chosen action, or null
/// when the user backed out.
Future<ServerEditResult?> pushServerEditPage(
  BuildContext context, {
  required TsServerInfo info,
  required bool canEdit,
  required bool canCreateChannel,
}) {
  return Navigator.of(context).push<ServerEditResult>(
    MaterialPageRoute(
      builder: (_) => ServerEditScreen(
        info: info,
        canEdit: canEdit,
        canCreateChannel: canCreateChannel,
      ),
    ),
  );
}

class ServerEditScreen extends StatefulWidget {
  const ServerEditScreen({
    super.key,
    required this.info,
    required this.canEdit,
    required this.canCreateChannel,
  });

  /// Prefill snapshot (name / max clients; the password is never readable).
  final TsServerInfo info;

  /// False renders the form read-only (no password section, no save).
  final bool canEdit;

  /// Shows the "create channel" entry.
  final bool canCreateChannel;

  @override
  State<ServerEditScreen> createState() => _ServerEditScreenState();
}

class _ServerEditScreenState extends State<ServerEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _maxClients;
  late final TextEditingController _password;

  // The prefilled values — unchanged fields are NOT re-sent (an edit that
  // only rewrites current values would just make the server re-broadcast a
  // notifyserveredited to everyone).
  late final String _initialName;
  late final int? _initialMaxClients;

  /// The "remove password" switch — submitting it clears the server
  /// password (an empty `serveredit` password). TS3 never sends the current
  /// password to clients, so there is nothing to prefill.
  bool _removePassword = false;

  @override
  void initState() {
    super.initState();
    final info = widget.info;
    _name = TextEditingController(text: info.name);
    _initialName = info.name;
    _maxClients = TextEditingController(
      text: info.maxClients?.toString() ?? '',
    );
    _initialMaxClients = info.maxClients;
    _password = TextEditingController();
  }

  @override
  void dispose() {
    _name.dispose();
    _maxClients.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final max = int.tryParse(_maxClients.text.trim());
    Navigator.of(context).pop(
      ServerEditResult.save(
        name: name.isNotEmpty && name != _initialName ? name : null,
        // Empty = don't touch (a server has no "unlimited" — a cleared field
        // must not zero out the limit). Clamped to u16: the FFI boundary
        // parses the JSON into a Rust u16 and a bad value would silently
        // drop the whole request.
        maxClients: max != null && max != _initialMaxClients
            ? max.clamp(1, 0xFFFF)
            : null,
        password: _removePassword
            ? ''
            : (_password.text.isEmpty ? null : _password.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final al = AppLocalizations.of(context);
    final canEdit = widget.canEdit;
    final hasName = _name.text.trim().isNotEmpty;
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F23),
      appBar: AppBar(
        title: Text(
          al.serverSettingsTitle,
          style: const TextStyle(color: Colors.white, fontSize: 17),
        ),
        backgroundColor: const Color(0xFF16213E),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!canEdit) ...[
              Row(
                children: [
                  const Icon(Icons.lock_outline, size: 14, color: Colors.amber),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      al.serverReadOnlyHint,
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _name,
              readOnly: !canEdit,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: al.serverName,
                labelStyle: const TextStyle(color: Colors.grey),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _maxClients,
              readOnly: !canEdit,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: al.serverMaxClientsLabel,
                labelStyle: const TextStyle(color: Colors.grey),
              ),
            ),
            if (canEdit) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: true,
                enabled: !_removePassword,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: al.serverPasswordLabel,
                  labelStyle: const TextStyle(color: Colors.grey),
                  // The current password is never known client-side, so the
                  // field starts empty — state what an empty submit does
                  // (helperText stays visible while typing).
                  helperText: al.serverPasswordHelper,
                ),
              ),
              SwitchListTile(
                value: _removePassword,
                onChanged: (v) => setState(() => _removePassword = v),
                title: Text(
                  al.serverPasswordRemove,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                contentPadding: EdgeInsets.zero,
              ),
            ],
            if (widget.canCreateChannel) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(const ServerEditResult.createChannel()),
                  icon: const Icon(Icons.add_circle_outline, size: 18),
                  label: Text(al.menuCreateChannel),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.blueAccent,
                    side: const BorderSide(color: Color(0xFF2A2A4A)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
            if (canEdit) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: hasName ? _submit : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.blueAccent.withValues(
                      alpha: 0.3,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(al.save),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
