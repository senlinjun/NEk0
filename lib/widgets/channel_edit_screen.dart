import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/channel.dart';

/// What the channel create/edit page submits. Raw field values — the caller
/// maps them onto the notifier's tri-state semantics per flow:
/// - [maxClients]: 0 = unlimited, >0 = limit.
/// - [topic]/[password]: '' = none (create) / clear (edit).
/// The nullable fields are only non-null when they should be SENT — null
/// means "leave untouched" (the page applies touched-checks, see below).
class ChannelFormResult {
  /// null = unchanged (edit — the raw name is NOT re-sent: some servers
  /// run the sibling-name-uniqueness check on any channeledit carrying
  /// channel_name, and a trimmed prefill could look like a rename). Create
  /// always sends it.
  final String? name;
  final String topic;
  final String password;
  final int maxClients;
  final bool isPermanent;
  final bool isSemiPermanent;

  /// null = untouched (edit) / none (create); '' = clear.
  final String? description;

  /// -1 inherited, 0 unlimited, >0 limit; null = leave untouched.
  final int? maxFamilyClients;

  /// Seconds an empty temporary channel lingers; null = leave untouched.
  final int? deleteDelay;

  /// i_channel_needed_talk_power (edit only — channelcreate rejects it).
  final int? neededTalkPower;

  final bool isDefault;

  const ChannelFormResult({
    this.name,
    required this.topic,
    required this.password,
    required this.maxClients,
    required this.isPermanent,
    required this.isSemiPermanent,
    this.description,
    this.maxFamilyClients,
    this.deleteDelay,
    this.neededTalkPower,
    this.isDefault = false,
  });
}

enum _ChannelType { temporary, semiPermanent, permanent }

enum _FamilyMode { inherit, unlimited, limited }

/// Pushes the full-screen channel form (create when [channel] == null, edit
/// otherwise). A page instead of a dialog: the form has too many fields for
/// an AlertDialog. Returns the submitted result, or null when the user
/// backed out.
Future<ChannelFormResult?> pushChannelEditPage(
  BuildContext context, {
  TsChannel? channel,
}) {
  return Navigator.of(context).push<ChannelFormResult>(
    MaterialPageRoute(builder: (_) => ChannelEditScreen(channel: channel)),
  );
}

class ChannelEditScreen extends StatefulWidget {
  const ChannelEditScreen({super.key, this.channel});

  /// Null = create a new channel; otherwise edit this one (prefills).
  final TsChannel? channel;

  @override
  State<ChannelEditScreen> createState() => _ChannelEditScreenState();
}

class _ChannelEditScreenState extends State<ChannelEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _topic;
  late final TextEditingController _description;
  late final TextEditingController _password;
  late final TextEditingController _maxClients;
  late final TextEditingController _maxFamilyValue;
  late final TextEditingController _neededTalkPower;
  late final TextEditingController _deleteDelay;
  late _ChannelType _type;
  late _FamilyMode _family;
  bool _isDefault = false;

  // Fields whose book value may be unknown to us (description / delete delay
  // / family limit are not part of the roster) are only submitted when the
  // user actually changed them — an untouched form must never overwrite real
  // server-side settings with a possibly-empty prefill.
  late final String _initialDescription;
  late final int _initialDeleteDelay;
  late final int _initialFamily;

  /// The prefilled name — an unchanged name is NOT re-sent on edit (see
  /// [ChannelFormResult.name]).
  late final String _initialName;

  bool get _isEdit => widget.channel != null;

  @override
  void initState() {
    super.initState();
    final ch = widget.channel;
    _name = TextEditingController(text: ch?.name ?? '');
    _initialName = ch?.name ?? '';
    _topic = TextEditingController(text: ch?.topic ?? '');
    // The current password is never known client-side, so the field starts
    // empty; submitting empty on a locked channel clears it (the caller
    // turns '' into the notifier's clear-marker only when hasPassword).
    _password = TextEditingController();
    final max = ch?.maxClients ?? -1;
    _maxClients = TextEditingController(text: max > 0 ? '$max' : '');
    _description = TextEditingController(text: ch?.description ?? '');
    _initialDescription = ch?.description ?? '';
    final family = ch?.maxFamilyClients ?? -1;
    _initialFamily = family;
    _family = family > 0
        ? _FamilyMode.limited
        : family == 0
        ? _FamilyMode.unlimited
        : _FamilyMode.inherit;
    _maxFamilyValue = TextEditingController(text: family > 0 ? '$family' : '');
    _neededTalkPower = TextEditingController(
      text: ch == null ? '' : '${ch.neededTalkPower}',
    );
    final delay = ch?.deleteDelay ?? 0;
    _initialDeleteDelay = delay;
    _deleteDelay = TextEditingController(text: delay > 0 ? '$delay' : '');
    _type = ch == null
        ? _ChannelType.temporary
        : ch.isPermanent
        ? _ChannelType.permanent
        : ch.isSemiPermanent
        ? _ChannelType.semiPermanent
        : _ChannelType.temporary;
    _isDefault = ch?.isDefault ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _topic.dispose();
    _description.dispose();
    _password.dispose();
    _maxClients.dispose();
    _maxFamilyValue.dispose();
    _neededTalkPower.dispose();
    _deleteDelay.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final max = int.tryParse(_maxClients.text.trim()) ?? 0;

    final description = _description.text.trim();
    final descriptionOut = _isEdit
        ? (description == _initialDescription ? null : description)
        : (description.isEmpty ? null : description);

    final familyValue = _family == _FamilyMode.limited
        ? (int.tryParse(_maxFamilyValue.text.trim()) ?? 0)
        : _family == _FamilyMode.unlimited
        ? 0
        : -1;
    final familyOut = _isEdit && familyValue == _initialFamily
        ? null
        : familyValue;

    final delay = int.tryParse(_deleteDelay.text.trim()) ?? 0;
    final delayOut = _isEdit
        ? (delay == _initialDeleteDelay ? null : delay)
        : (delay > 0 ? delay : null);

    Navigator.of(context).pop(
      ChannelFormResult(
        name: _isEdit && name == _initialName ? null : name,
        topic: _topic.text.trim(),
        password: _password.text,
        maxClients: max < 0 ? 0 : max,
        isPermanent: _type == _ChannelType.permanent,
        isSemiPermanent: _type == _ChannelType.semiPermanent,
        description: descriptionOut,
        maxFamilyClients: familyOut,
        deleteDelay: delayOut,
        // Create mode has no talk-power field (channelcreate rejects it).
        neededTalkPower: _isEdit
            ? (int.tryParse(_neededTalkPower.text.trim()) ?? 0)
            : null,
        isDefault: _isDefault,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final al = AppLocalizations.of(context);
    final hasName = _name.text.trim().isNotEmpty;
    return Scaffold(
      // Transparent so the app-wide custom background shows through.
      appBar: AppBar(
        title: Text(
          _isEdit ? al.channelEditTitle : al.channelCreateTitle,
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
            TextField(
              controller: _name,
              autofocus: !_isEdit,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: al.channelNameLabel,
                labelStyle: const TextStyle(color: Colors.grey),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _topic,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: al.channelTopicLabel,
                labelStyle: const TextStyle(color: Colors.grey),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _description,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: al.channelDescriptionLabel,
                labelStyle: const TextStyle(color: Colors.grey),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: al.channelPasswordHint,
                labelStyle: const TextStyle(color: Colors.grey),
                // Editing only: the field starts empty because the current
                // password is never known client-side — state what an empty
                // submit does (helperText stays visible while typing).
                helperText: _isEdit ? al.channelPasswordHelper : null,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _maxClients,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: al.channelMaxClientsLabel,
                labelStyle: const TextStyle(color: Colors.grey),
                helperText: al.channelMaxClientsHelper,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<_FamilyMode>(
              initialValue: _family,
              dropdownColor: const Color(0xFF1A1A2E),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: al.channelMaxFamilyLabel,
                labelStyle: const TextStyle(color: Colors.grey),
                enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF2A2A4A)),
                ),
              ),
              items: [
                DropdownMenuItem(
                  value: _FamilyMode.inherit,
                  child: Text(al.channelMaxFamilyInherit),
                ),
                DropdownMenuItem(
                  value: _FamilyMode.unlimited,
                  child: Text(al.channelMaxFamilyUnlimited),
                ),
                DropdownMenuItem(
                  value: _FamilyMode.limited,
                  child: Text(al.channelMaxFamilyLimited),
                ),
              ],
              onChanged: (v) =>
                  setState(() => _family = v ?? _FamilyMode.inherit),
            ),
            if (_family == _FamilyMode.limited) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _maxFamilyValue,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: al.channelMaxFamilyLimited,
                  labelStyle: const TextStyle(color: Colors.grey),
                ),
              ),
            ],
            // channelcreate rejects channel_needed_talk_power — the field is
            // edit-only; set it after creating the channel.
            if (_isEdit) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _neededTalkPower,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: al.channelNeededTalkPowerLabel,
                  labelStyle: const TextStyle(color: Colors.grey),
                  helperText: al.channelTalkPowerHelper,
                ),
              ),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<_ChannelType>(
              initialValue: _type,
              dropdownColor: const Color(0xFF1A1A2E),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: al.channelTypeLabel,
                labelStyle: const TextStyle(color: Colors.grey),
                enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF2A2A4A)),
                ),
              ),
              items: [
                DropdownMenuItem(
                  value: _ChannelType.temporary,
                  child: Text(al.channelTypeTemporary),
                ),
                DropdownMenuItem(
                  value: _ChannelType.semiPermanent,
                  child: Text(al.channelTypeSemiPermanent),
                ),
                DropdownMenuItem(
                  value: _ChannelType.permanent,
                  child: Text(al.channelTypePermanent),
                ),
              ],
              onChanged: (v) =>
                  setState(() => _type = v ?? _ChannelType.temporary),
            ),
            // The delete delay only applies to temporary channels.
            if (_type == _ChannelType.temporary) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _deleteDelay,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: al.channelDeleteDelayLabel,
                  labelStyle: const TextStyle(color: Colors.grey),
                  helperText: al.channelDeleteDelayHelper,
                ),
              ),
            ],
            SwitchListTile(
              value: _isDefault,
              onChanged: (v) => setState(() => _isDefault = v),
              title: Text(
                al.channelIsDefaultLabel,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              contentPadding: EdgeInsets.zero,
            ),
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
        ),
      ),
    );
  }
}
