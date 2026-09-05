import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import 'package:uuid/uuid.dart';
import '../models/server.dart';

class ServerFormDialog extends StatefulWidget {
  final Server? existing;

  const ServerFormDialog({super.key, this.existing});

  @override
  State<ServerFormDialog> createState() => _ServerFormDialogState();
}

class _ServerFormDialogState extends State<ServerFormDialog> {
  late TextEditingController _nameCtrl;
  late TextEditingController _addressCtrl;
  late TextEditingController _nicknameCtrl;
  late TextEditingController _channelCtrl;
  late TextEditingController _passwordCtrl;
  late TextEditingController _tokenCtrl;

  late TextEditingController _voicePortCtrl;
  late TextEditingController _serverQueryPortCtrl;
  late TextEditingController _fileTransferPortCtrl;
  late TextEditingController _serverQuerySshPortCtrl;
  late TextEditingController _portsHeaderCtrl;

  bool _portsExpanded = false;
  String? _portError;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    _nameCtrl = TextEditingController(text: s?.name ?? '');
    _addressCtrl = TextEditingController(text: s?.address ?? '');
    _nicknameCtrl = TextEditingController(text: s?.nickname ?? 'TeamSpeakUser');
    _channelCtrl = TextEditingController(text: s?.channel ?? '');
    _passwordCtrl = TextEditingController(text: s?.password ?? '');
    _tokenCtrl = TextEditingController(text: s?.token ?? '');
    _voicePortCtrl = TextEditingController(
      text: s?.voicePort?.toString() ?? '',
    );
    _serverQueryPortCtrl = TextEditingController(
      text: s?.serverQueryPort?.toString() ?? '',
    );
    _fileTransferPortCtrl = TextEditingController(
      text: s?.fileTransferPort?.toString() ?? '',
    );
    _serverQuerySshPortCtrl = TextEditingController(
      text: s?.serverQuerySshPort?.toString() ?? '',
    );
    _portsHeaderCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addressCtrl.dispose();
    _nicknameCtrl.dispose();
    _channelCtrl.dispose();
    _passwordCtrl.dispose();
    _tokenCtrl.dispose();
    _voicePortCtrl.dispose();
    _serverQueryPortCtrl.dispose();
    _fileTransferPortCtrl.dispose();
    _serverQuerySshPortCtrl.dispose();
    _portsHeaderCtrl.dispose();
    super.dispose();
  }

  /// Parse a port field, returning null when empty. Throws [FormatException]
  /// when the content is not a valid port number in 1..65535.
  int? _parsePort(TextEditingController ctrl) {
    final text = ctrl.text.trim();
    if (text.isEmpty) return null;
    final value = int.tryParse(text);
    if (value == null || value < 1 || value > 65535) {
      throw const FormatException('invalid port');
    }
    return value;
  }

  void _submit() {
    final address = _addressCtrl.text.trim();
    if (address.isEmpty) return;

    int? voicePort;
    int? serverQueryPort;
    int? fileTransferPort;
    int? serverQuerySshPort;
    try {
      voicePort = _parsePort(_voicePortCtrl);
      serverQueryPort = _parsePort(_serverQueryPortCtrl);
      fileTransferPort = _parsePort(_fileTransferPortCtrl);
      serverQuerySshPort = _parsePort(_serverQuerySshPortCtrl);
    } on FormatException {
      setState(() {
        _portsExpanded = true;
        _portError = AppLocalizations.of(context).invalidPort;
      });
      return;
    }
    setState(() => _portError = null);

    final server = Server(
      id: widget.existing?.id ?? const Uuid().v4(),
      name: _nameCtrl.text.trim().isEmpty ? address : _nameCtrl.text.trim(),
      address: address,
      nickname: _nicknameCtrl.text.trim().isEmpty
          ? 'TeamSpeakUser'
          : _nicknameCtrl.text.trim(),
      channel: _channelCtrl.text.trim().isEmpty
          ? null
          : _channelCtrl.text.trim(),
      password: _passwordCtrl.text.trim().isEmpty
          ? null
          : _passwordCtrl.text.trim(),
      // Privilege keys are one-time: submitted on the next connect, cleared
      // from the saved server once the connection succeeds.
      token: _tokenCtrl.text.trim().isEmpty ? null : _tokenCtrl.text.trim(),
      voicePort: voicePort,
      serverQueryPort: serverQueryPort,
      fileTransferPort: fileTransferPort,
      serverQuerySshPort: serverQuerySshPort,
    );

    Navigator.of(context).pop(server);
  }

  @override
  Widget build(BuildContext context) {
    final al = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: Text(
        widget.existing != null ? al.editServerTitle : al.addServerTitle,
        style: const TextStyle(color: Colors.white),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _field(_nameCtrl, al.serverName, Icons.label),
            const SizedBox(height: 12),
            _field(_addressCtrl, al.addressHint, Icons.dns),
            const SizedBox(height: 12),
            _buildPortsSection(al),
            const SizedBox(height: 12),
            _field(_nicknameCtrl, al.nickname, Icons.person),
            const SizedBox(height: 12),
            _field(_channelCtrl, al.channelOptional, Icons.tag),
            const SizedBox(height: 12),
            _field(
              _passwordCtrl,
              al.passwordOptional,
              Icons.lock,
              obscure: true,
            ),
            const SizedBox(height: 12),
            _field(_tokenCtrl, al.tokenOptional, Icons.vpn_key),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            AppLocalizations.of(context).cancel,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
          child: Text(AppLocalizations.of(context).save),
        ),
      ],
    );
  }

  /// Expandable "Ports" section: a collapsible header row that reveals the
  /// TeamSpeak 3 server port inputs when tapped.
  Widget _buildPortsSection(AppLocalizations al) {
    return Column(
      children: [
        // Header is a read-only field reusing the exact input-field layout so
        // its height and prefix-icon align with the other text boxes.
        _field(
          _portsHeaderCtrl,
          al.ports,
          Icons.lan,
          readOnly: true,
          suffixIcon: Icon(
            _portsExpanded ? Icons.expand_less : Icons.expand_more,
            color: Colors.grey,
          ),
          onTap: () => setState(() {
            _portsExpanded = !_portsExpanded;
            _portError = null;
          }),
        ),
        if (_portsExpanded) ...[
          const SizedBox(height: 12),
          _field(
            _voicePortCtrl,
            '${al.voicePort} (${ServerPorts.voice})',
            Icons.mic,
            number: true,
          ),
          const SizedBox(height: 12),
          _field(
            _serverQueryPortCtrl,
            '${al.serverQueryPort} (${ServerPorts.serverQuery})',
            Icons.tune,
            number: true,
          ),
          const SizedBox(height: 12),
          _field(
            _fileTransferPortCtrl,
            '${al.fileTransferPort} (${ServerPorts.fileTransfer})',
            Icons.folder_open,
            number: true,
          ),
          const SizedBox(height: 12),
          _field(
            _serverQuerySshPortCtrl,
            '${al.serverQuerySshPort} (${ServerPorts.serverQuerySsh})',
            Icons.terminal,
            number: true,
          ),
          if (_portError != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _portError!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String hint,
    IconData icon, {
    bool obscure = false,
    bool number = false,
    bool readOnly = false,
    Widget? suffixIcon,
    VoidCallback? onTap,
  }) {
    return TextField(
      controller: ctrl,
      obscureText: obscure,
      readOnly: readOnly,
      onTap: onTap,
      keyboardType: number ? TextInputType.number : null,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        // Keep the hint on a single line so every field renders at the same
        // height even when the hint text is long (e.g. the port fields).
        hintMaxLines: 1,
        hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
        prefixIcon: Icon(icon, color: Colors.grey, size: 18),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: const Color(0xFF16213E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
    );
  }
}
