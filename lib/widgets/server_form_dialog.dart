import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    _nameCtrl = TextEditingController(text: s?.name ?? '');
    _addressCtrl = TextEditingController(text: s?.address ?? '');
    _nicknameCtrl = TextEditingController(text: s?.nickname ?? 'TeamSpeakUser');
    _channelCtrl = TextEditingController(text: s?.channel ?? '');
    _passwordCtrl = TextEditingController(text: s?.password ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addressCtrl.dispose();
    _nicknameCtrl.dispose();
    _channelCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final address = _addressCtrl.text.trim();
    if (address.isEmpty) return;

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
    );

    Navigator.of(context).pop(server);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: Text(
        widget.existing != null ? 'Edit Server' : 'Add Server',
        style: const TextStyle(color: Colors.white),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _field(_nameCtrl, 'Server Name', Icons.label),
            const SizedBox(height: 12),
            _field(_addressCtrl, 'Address (e.g. ts.example.com)', Icons.dns),
            const SizedBox(height: 12),
            _field(_nicknameCtrl, 'Nickname', Icons.person),
            const SizedBox(height: 12),
            _field(_channelCtrl, 'Channel (optional)', Icons.tag),
            const SizedBox(height: 12),
            _field(
              _passwordCtrl,
              'Password (optional)',
              Icons.lock,
              obscure: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String hint,
    IconData icon, {
    bool obscure = false,
  }) {
    return TextField(
      controller: ctrl,
      obscureText: obscure,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
        prefixIcon: Icon(icon, color: Colors.grey, size: 18),
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
