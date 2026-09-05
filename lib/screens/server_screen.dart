import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/generated/app_localizations.dart';

import '../models/channel.dart';
import '../models/client.dart';
import '../models/group.dart';
import '../models/privilege.dart';
import '../models/ts_state.dart';
import '../services/avatar_cache.dart';
import '../services/foreground_service.dart';
import '../services/ts_ffi.dart';
import '../widgets/channel_edit_screen.dart';
import '../widgets/channel_password_dialog.dart';
import '../widgets/channel_tree.dart';
import '../widgets/chat_panel.dart';
import '../widgets/connection_bar.dart';
import '../screens/file_manager_screen.dart';
import '../widgets/channel_menu.dart';
import '../widgets/position_edit_screen.dart';
import '../widgets/privilege_key_dialog.dart';
import '../widgets/spotlight_tour.dart';
import '../widgets/voice_settings_panel.dart';

class ServerScreen extends ConsumerStatefulWidget {
  const ServerScreen({super.key});

  @override
  ConsumerState<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends ConsumerState<ServerScreen> {
  int _lastSeenMessageCount = 0;

  /// Cached server-group list for the user-list privilege badges. Refreshed
  /// only when the server (name) changes or the list is still empty (the
  /// group list arrives shortly after connect, not with the first roster).
  List<TsServerGroup> _serverGroups = const [];
  String _serverGroupsKey = '';

  // Targets for the first-use spotlight guide.
  final GlobalKey _micKey = GlobalKey();
  final GlobalKey _speakerKey = GlobalKey();
  final GlobalKey _chatKey = GlobalKey();
  final GlobalKey _treeKey = GlobalKey();
  final GlobalKey _treeBodyKey = GlobalKey();

  /// Loads (and caches) the server group list for the privilege badges.
  /// Cheap guard: only FFI when the server changed or the list is still
  /// empty (which happens while the servergrouplist answer is in flight).
  void _maybeRefreshServerGroups() {
    final conn = ref.read(tsConnectionProvider);
    if (!conn.connected) return;
    if (_serverGroupsKey == conn.serverName && _serverGroups.isNotEmpty) {
      return;
    }
    _serverGroupsKey = conn.serverName;
    try {
      _serverGroups = TsNative.getServerGroups()
          .map(TsServerGroup.fromJson)
          .toList();
    } catch (_) {
      _serverGroups = const [];
    }
  }

  /// Show the control-bar guide the first time the server screen is opened.
  /// Deferred to the first successful connect (see [_onConnected]).
  Future<void> _maybeAutoShowGuide() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('tour_server_shown') ?? false) return;
    await prefs.setBool('tour_server_shown', true);
    if (!mounted) return;
    await _showGuide();
  }

  /// Runs right after the first successful connect: shows the OEM
  /// battery/auto-start guide first, then the spotlight tour.
  Future<void> _onConnected() async {
    await _maybeShowOemGuide();
    if (!mounted) return;
    await _maybeAutoShowGuide();
    if (!mounted) return;
    // The server asked for a privilege key (typically the very first login
    // on a fresh server): prompt after the guides so the dialogs don't
    // overlap. No-op when a token was already submitted with clientinit.
    if (ref.read(tsConnectionProvider).askForPrivilegeKey) {
      await _showPrivilegeKeyDialog();
    }
  }

  /// Opens the privilege-key prompt and, on submit, redeems the key.
  Future<void> _showPrivilegeKeyDialog() async {
    ref.read(tsConnectionProvider.notifier).clearAskForPrivilegeKey();
    if (!mounted) return;
    final token = await showPrivilegeKeyDialog(context);
    if (!mounted || token == null || token.trim().isEmpty) return;
    await _submitPrivilegeKey(token.trim());
  }

  /// Sends the key and reports the outcome. The server only acks the
  /// command — an invalid or used key may be silently ignored, so the own
  /// server groups are polled for a change before claiming success.
  Future<void> _submitPrivilegeKey(String token) async {
    final al = AppLocalizations.of(context);
    final before = _ownServerGroups();
    final error = await ref
        .read(tsConnectionProvider.notifier)
        .usePrivilegeKey(token);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), backgroundColor: Colors.red),
      );
      return;
    }
    var granted = false;
    for (var i = 0; i < 12; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      final now = _ownServerGroups();
      if (now.length != before.length || now.any((g) => !before.contains(g))) {
        granted = true;
        break;
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          granted ? al.privilegeKeyGranted : al.privilegeKeyNoEffect,
        ),
        backgroundColor: granted ? Colors.green : Colors.orange,
      ),
    );
  }

  /// The own client's current server group ids (empty when unknown).
  Set<int> _ownServerGroups() {
    final st = ref.read(tsConnectionProvider);
    final own = st.clients.where((c) => c.id == st.ownClientId).firstOrNull;
    return own?.serverGroupIds.toSet() ?? {};
  }

  Future<void> _showGuide() async {
    final al = AppLocalizations.of(context);
    // The channel-tree step needs the left panel mounted, which only exists
    // while connected (a missing target would stall the tour with no bubble).
    final connected = ref.read(tsConnectionProvider).connected;
    await showSpotlightTour(context, [
      TourStep(
        targetKey: _micKey,
        padding: 4,
        title: al.guideMicTitle,
        description: al.guideMicDesc,
      ),
      TourStep(
        targetKey: _speakerKey,
        padding: 4,
        title: al.guideSpeakerTitle,
        description: al.guideSpeakerDesc,
      ),
      TourStep(
        targetKey: _chatKey,
        padding: 4,
        title: al.guideChatTitle,
        description: al.guideChatDesc,
      ),
      // The bubble caps its description at 4 lines, so the merged tree is
      // explained in three short steps instead of one long paragraph.
      if (connected) ...[
        TourStep(
          targetKey: _treeKey,
          padding: 4,
          title: al.guideChannelsTitle,
          description: al.guideChannelsDesc,
        ),
        TourStep(
          targetKey: _treeBodyKey,
          padding: 4,
          title: al.guideMembersTitle,
          description: al.guideMembersDesc,
        ),
        TourStep(
          targetKey: _treeBodyKey,
          padding: 4,
          title: al.guideMemberActionsTitle,
          description: al.guideMemberActionsDesc,
        ),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(tsConnectionProvider.select((s) => s.connected), (prev, next) {
      if (prev == true && !next && mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      if (prev == false && next && mounted) {
        _onConnected();
      }
    });
    // Pop on connect failure (connecting finished without success)
    ref.listen(tsConnectionProvider.select((s) => s.connecting), (prev, next) {
      if (prev == true && !next && mounted) {
        final st = ref.read(tsConnectionProvider);
        if (!st.connected) {
          Navigator.of(context).pop(st.error);
        }
      }
    });
    final conn = ref.watch(tsConnectionProvider);
    _maybeRefreshServerGroups();
    // Wrong password on a channel join: the selection was already rolled
    // back in ts_state — re-open the prompt with an error message and let
    // the user retry (or cancel to stay where they are).
    ref.listen(tsConnectionProvider.select((s) => s.failedPasswordChannelId), (
      prev,
      next,
    ) async {
      if (next == null || !mounted) return;
      final st = ref.read(tsConnectionProvider);
      final name =
          st.channels.where((c) => c.id == next).firstOrNull?.name ?? '';
      final al = AppLocalizations.of(context);
      final pw = await showChannelPasswordDialog(
        context,
        channelName: name,
        errorMessage: al.channelPasswordWrong,
      );
      if (!mounted) return;
      ref.read(tsConnectionProvider.notifier).clearPasswordRejection();
      if (pw == null || pw.isEmpty) return;
      ref.read(tsConnectionProvider.notifier).selectChannel(next, password: pw);
    });
    final connNotifier = ref.read(tsConnectionProvider.notifier);

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F23),
      body: SafeArea(
        child: Column(
          children: [
            ConnectionBar(
              serverName: conn.serverName,
              connected: conn.connected,
              onDisconnect: () {
                connNotifier.disconnect();
              },
              onShowGuide: _showGuide,
            ),
            Expanded(
              child: conn.connecting
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.blue),
                    )
                  : _buildLeftPanel(conn, connNotifier),
            ),
            _buildChatBar(conn),
            _buildControls(conn, connNotifier),
          ],
        ),
      ),
    );
  }

  /// Joining a locked channel: prompt for the password the first time,
  /// reuse the session-cached one afterwards. A wrong password comes back
  /// as a move_rejected event (handled by the listener in build()).
  Future<void> _onChannelTap(TsChannel channel) async {
    final notifier = ref.read(tsConnectionProvider.notifier);
    final cached = notifier.channelPassword(channel.id);
    if (channel.hasPassword && cached == null) {
      final pw = await showChannelPasswordDialog(
        context,
        channelName: channel.name,
      );
      if (!mounted || pw == null || pw.isEmpty) return; // cancelled
      notifier.selectChannel(channel.id, password: pw);
    } else {
      // Unlocked, or the password is already known for this session.
      notifier.selectChannel(channel.id, password: cached);
    }
  }

  /// Opens the per-channel context menu and dispatches the chosen entry.
  /// The join action reuses [_onChannelTap] so password handling stays in
  /// one place regardless of which gesture summoned the menu.
  Future<void> _onChannelMenu(TsChannel channel) async {
    // Move availability: a neighbor must exist, and re-ordering needs
    // modify rights (no dedicated hint bit — use the modify convention).
    final canMove = channel.permissionHints == 0 || channel.canModify;
    final siblings = _channelSiblings(channel);
    final idx = siblings.indexWhere((c) => c.id == channel.id);
    final result = await showChannelMenu(
      context,
      channel,
      canCreateChannel: _canCreateChannels,
      canMoveUp: canMove && idx > 0,
      canMoveDown: canMove && idx >= 0 && idx < siblings.length - 1,
    );
    if (!mounted || result == null) return;
    switch (result) {
      case channelMenuJoin:
        await _onChannelTap(channel);
      case channelMenuFileManager:
        final notifier = ref.read(tsConnectionProvider.notifier);
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => FileManagerScreen(
              channelId: channel.id,
              channelName: channel.name,
              channelPassword: notifier.channelPassword(channel.id) ?? '',
              connected: ref.read(tsConnectionProvider).connected,
            ),
          ),
        );
      case channelMenuCreateSub:
        await _createChannel(parentId: channel.id);
      case channelMenuEdit:
        await _editChannel(channel);
      case channelMenuMoveUp:
        await _moveChannel(channel, up: true);
      case channelMenuMoveDown:
        await _moveChannel(channel, up: false);
      case channelMenuDelete:
        await _confirmDeleteChannel(channel);
    }
  }

  /// The channel's siblings in server display order (TS3 linked-list order).
  List<TsChannel> _channelSiblings(TsChannel channel) {
    final conn = ref.read(tsConnectionProvider);
    return TsChannel.resolveOrder(
      conn.channels.where((c) => c.parentId == channel.parentId).toList()
        ..sort((a, b) => a.id.compareTo(b.id)),
    );
  }

  /// Moves a channel one slot among its siblings. TS3 orders siblings as a
  /// linked list (each channel stores the id it comes after), so a move
  /// rewrites two entries: the moved channel points past its neighbor and
  /// the neighbor takes the moved channel's old predecessor. Both edits run
  /// sequentially with their own receipt; the result is reported once.
  Future<void> _moveChannel(TsChannel channel, {required bool up}) async {
    final siblings = _channelSiblings(channel);
    final idx = siblings.indexWhere((c) => c.id == channel.id);
    if (idx < 0 || (up ? idx == 0 : idx >= siblings.length - 1)) return;
    final notifier = ref.read(tsConnectionProvider.notifier);
    final String? error;
    if (up) {
      final prev = siblings[idx - 1];
      error =
          await notifier.editChannel(
            channel.id,
            order: idx >= 2 ? siblings[idx - 2].id : 0,
          ) ??
          await notifier.editChannel(prev.id, order: channel.id);
    } else {
      final next = siblings[idx + 1];
      error =
          await notifier.editChannel(channel.id, order: next.id) ??
          await notifier.editChannel(next.id, order: channel.order);
    }
    if (!mounted) return;
    _reportOp(error, AppLocalizations.of(context).channelMoved);
  }

  /// Long-press (or tap) on the server root node. Currently only channel
  /// creation; the sheet is not opened at all when we look unprivileged.
  Future<void> _onServerMenu() async {
    final result = await showServerMenu(
      context,
      canCreateChannel: _canCreateChannels,
    );
    if (!mounted || result != serverMenuCreateChannel) return;
    await _createChannel(parentId: 0);
  }

  /// Opens the shared channel form to create a channel under [parentId]
  /// (0 = top level). On success the tree refreshes itself through the
  /// `channels_updated` event the server's answer triggers.
  Future<void> _createChannel({required int parentId}) async {
    final al = AppLocalizations.of(context);
    final form = await pushChannelEditPage(context);
    if (!mounted || form == null) return;
    final error = await ref
        .read(tsConnectionProvider.notifier)
        .createChannel(
          // Never null in create mode: the save button requires a name.
          parentId,
          form.name!,
          topic: form.topic.isEmpty ? null : form.topic,
          password: form.password.isEmpty ? null : form.password,
          maxClients: form.maxClients,
          isPermanent: form.isPermanent,
          isSemiPermanent: form.isSemiPermanent,
          description: form.description,
          maxFamilyClients: form.maxFamilyClients,
          isDefault: form.isDefault,
          deleteDelay: form.deleteDelay,
        );
    if (!mounted) return;
    _reportOp(error, al.channelCreated);
  }

  /// Opens the shared channel form prefilled with the channel's current
  /// settings and submits the changes as a `channeledit`.
  Future<void> _editChannel(TsChannel channel) async {
    final al = AppLocalizations.of(context);
    final form = await pushChannelEditPage(context, channel: channel);
    if (!mounted || form == null) return;
    // Password tri-state: an empty field clears the password of a locked
    // channel (the real password is never known client-side) and is a no-op
    // for an unlocked one.
    final password = form.password.isEmpty
        ? (channel.hasPassword ? '' : null)
        : form.password;
    final error = await ref
        .read(tsConnectionProvider.notifier)
        .editChannel(
          channel.id,
          name: form.name,
          topic: form.topic,
          password: password,
          maxClients: form.maxClients,
          isPermanent: form.isPermanent,
          isSemiPermanent: form.isSemiPermanent,
          description: form.description,
          maxFamilyClients: form.maxFamilyClients,
          isDefault: form.isDefault,
          deleteDelay: form.deleteDelay,
          neededTalkPower: form.neededTalkPower,
        );
    if (!mounted) return;
    _reportOp(error, al.channelSaved);
  }

  /// Delete confirmation. A channel that still has members is force-deleted
  /// (needs the force-delete permission); its occupants are moved to the
  /// default channel.
  Future<void> _confirmDeleteChannel(TsChannel channel) async {
    final al = AppLocalizations.of(context);
    final occupied = channel.clientCount > 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Text(
          al.deleteChannelTitle,
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              al.deleteChannelBody(channel.name),
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            if (occupied) ...[
              const SizedBox(height: 8),
              Text(
                al.deleteChannelOccupied(channel.clientCount),
                style: const TextStyle(color: Colors.amber, fontSize: 13),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(al.cancel, style: const TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              al.delete,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final error = await ref
        .read(tsConnectionProvider.notifier)
        .deleteChannel(channel.id, force: occupied);
    if (!mounted) return;
    _reportOp(error, al.channelDeleted);
  }

  /// Drop handler for the tree's long-press drag: re-parent (or re-order)
  /// the dragged channel via a single `channelmove`.
  Future<void> _onChannelDrop(int draggedId, int parentId, int? afterId) async {
    // Double-check the target is not the channel itself or inside its own
    // subtree (the tree filters these too; this guards against stale data).
    final conn = ref.read(tsConnectionProvider);
    final invalid = <int>{draggedId};
    var grew = true;
    while (grew) {
      grew = false;
      for (final c in conn.channels) {
        if (invalid.contains(c.parentId) && invalid.add(c.id)) {
          grew = true;
        }
      }
    }
    if (invalid.contains(parentId)) return;
    final error = await ref
        .read(tsConnectionProvider.notifier)
        .moveChannel(draggedId, parentId: parentId, afterId: afterId);
    if (!mounted) return;
    _reportOp(error, AppLocalizations.of(context).channelMoved);
  }

  /// Green/red receipt SnackBar for the channel-management operations
  /// (mirrors the client sheet's perm-op reporting).
  void _reportOp(String? error, String okLabel) {
    final al = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error == null ? okLabel : al.permOpFailed(error)),
        backgroundColor: error == null ? null : Colors.red.shade900,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Widget _buildLeftPanel(
    TsConnectionState conn,
    TsConnectionNotifier notifier,
  ) {
    return Container(
      color: const Color(0xFF12122A),
      child: Column(
        children: [
          Container(
            key: _treeKey,
            padding: const EdgeInsets.all(8),
            color: const Color(0xFF16213E),
            width: double.infinity,
            child: Text(
              AppLocalizations.of(context).channels,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            // Material between the colored container and the tiles: ListTile
            // paints background and ink on the nearest Material — with only
            // the ColoredBox ancestor above, Flutter throws "ListTile
            // background color or ink splashes may be invisible" on every
            // rebuild.
            child: Material(
              key: _treeBodyKey,
              type: MaterialType.transparency,
              child: ChannelTree(
                channels: conn.channels,
                // Every client on the server is nested under its channel, so
                // members of other channels are directly tappable.
                clients: conn.clients,
                selectedChannelId: conn.selectedChannelId,
                // Our own talk power decides whether a channel's
                // needed-talk-power bars us from speaking there.
                ownTalkPower:
                    conn.clients
                        .where((c) => c.id == conn.ownClientId)
                        .firstOrNull
                        ?.talkPower ??
                    0,
                // Fixed gestures: short tap joins, long press opens the
                // menu, long-press drag moves the channel (see onChannelDrop).
                onChannelTap: _onChannelTap,
                onChannelMenu: _onChannelMenu,
                // Open-lock hint for channels whose password is already
                // cached for this session.
                sessionPasswordKnown: (channelId) =>
                    ref
                        .read(tsConnectionProvider.notifier)
                        .channelPassword(channelId) !=
                    null,
                // Server groups for the privileged-identity badges; empty
                // while the group list is unavailable.
                serverGroups: _serverGroups,
                // TS3-style server root node; its menu (create channel)
                // only exists when we look privileged enough.
                serverName: conn.serverName,
                onServerMenu: _canCreateChannels ? _onServerMenu : null,
                // Long-press drag: re-parent / re-order the dragged channel.
                onChannelDrop: _onChannelDrop,
                // Tapping yourself opens the same voice settings as
                // long-pressing the mic; tapping others opens their
                // per-client volume + poke sheet.
                onClientTap: (clientId) {
                  if (clientId == conn.ownClientId) {
                    _showVoiceSettings(conn, notifier);
                  } else {
                    _showClientVolume(clientId);
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// First-connect-only dialog guiding the user to whitelist the app in
  /// OEM battery/auto-start settings (MIUI/HyperOS/EMUI/ColorOS/OriginOS).
  /// The battery-optimization exemption is requested only AFTER the user
  /// acknowledges the dialog, so they know why the settings page opens.
  Future<void> _maybeShowOemGuide() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('oem_guide_shown') ?? false) return;
    await prefs.setBool('oem_guide_shown', true);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Text(
          AppLocalizations.of(ctx).keepAliveTitle,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          AppLocalizations.of(ctx).keepAliveBody,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppLocalizations.of(ctx).gotIt),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      // User acknowledged the dialog — now open the battery optimization page.
      ForegroundService.requestBatteryOptimizationExemption();
    }
  }

  /// Our own privilege level: query admin beats the server-group name tier.
  /// Shared by the client sheet's permission gating and the channel
  /// management entries (channel creation has no per-channel hint bit).
  PrivilegeTier get _ownPrivilegeTier {
    final conn = ref.read(tsConnectionProvider);
    final ownClient = conn.clients
        .where((c) => c.id == conn.ownClientId)
        .firstOrNull;
    if (ownClient?.isQueryAdmin ?? false) return PrivilegeTier.admin;
    final ownGroupNames = _serverGroups
        .where((g) => ownClient?.serverGroupIds.contains(g.id) ?? false)
        .map((g) => g.name);
    return privilegeTierOf(ownGroupNames);
  }

  /// Whether the channel-management entries (create channel / sub-channel)
  /// are offered. Channel creation has no per-channel permission hint, so
  /// this reuses the "are we privileged" heuristics of the client sheet
  /// (_ownPrivilegeTier, or a management power in our own clientpermlist).
  /// A wrong guess surfaces as a server rejection in the perm_op receipt.
  bool get _canCreateChannels =>
      _ownPrivilegeTier != PrivilegeTier.none ||
      ref.read(tsConnectionProvider.notifier).canManagePermissions;

  void _showClientVolume(int clientId) {
    final conn = ref.read(tsConnectionProvider);
    final connNotifier = ref.read(tsConnectionProvider.notifier);
    final client = conn.clients.where((c) => c.id == clientId).firstOrNull;
    if (client == null) return;

    // Diagnostics: log what the sheet gates on, so a stale native library
    // (whose channel JSON lacks e.g. is_default) shows up in logcat instead
    // of producing buttons that look like they "should have been hidden".
    final targetChannel = conn.channels
        .where((ch) => ch.id == client.channelId)
        .firstOrNull;
    debugPrint(
      'TS: client sheet for ${client.id} (${client.nickname}): '
      'channel=${client.channelId} isDefault=${targetChannel?.isDefault} '
      'hints=${client.permissionHints}',
    );

    // Our own privilege tier (query admin / server-group name tier) is the
    // last-resort gate for the permission-management entries when neither
    // the target's permission hints nor our clientpermlist are available yet.
    final ownClient = conn.clients
        .where((c) => c.id == conn.ownClientId)
        .firstOrNull;
    final ownPrivilegeTier = _ownPrivilegeTier;

    showModalBottomSheet(
      context: context,
      // The sheet holds up to 8 action buttons — without this the content is
      // capped at ~9/16 of the screen and the bottom buttons overflow (and
      // become unresponsive, since hit testing stops at the clipped bounds).
      isScrollControlled: true,
      backgroundColor: const Color(0xFF12122A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => _ClientVolumeSheet(
        client: client,
        notifier: connNotifier,
        ownClientId: conn.ownClientId,
        // We are a server-query admin: the permission-management entries are
        // offered even before the hint bits arrive.
        ownIsQueryAdmin: ownClient?.isQueryAdmin ?? false,
        // Our own directly-assigned permissions include a management power
        // (active permission detection — clientpermlist).
        ownCanManagePermissions: ref
            .read(tsConnectionProvider.notifier)
            .canManagePermissions,
        ownPrivilegeTier: ownPrivilegeTier,
        channels: conn.channels,
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
      key: _chatKey,
      onTap: _openChat,
      child: Container(
        height: 36,
        color: const Color(0xFF16213E),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const Icon(Icons.chat_bubble_outline, color: Colors.grey, size: 16),
            const SizedBox(width: 8),
            Text(
              AppLocalizations.of(context).chat,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const Spacer(),
            if (lastMsg != null)
              Flexible(
                child: Text(
                  '${lastMsg.fromClient}: ${lastMsg.message}',
                  style: const TextStyle(
                    color: Color(0xFF555577),
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            if (unread > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.blue,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$unread',
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ],
            const SizedBox(width: 4),
            const Icon(Icons.keyboard_arrow_up, color: Colors.grey, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(TsConnectionState conn, TsConnectionNotifier notifier) {
    // Mic color: red=muted, green=on-idle, blue=speaking/PTT-active
    Color micColor;
    if (conn.inputMuted) {
      micColor = Colors.red;
    } else if (conn.pttMode) {
      micColor = conn.pttPressed ? Colors.blue : Colors.green;
    } else {
      micColor = conn.voiceActive ? Colors.blue : Colors.green;
    }

    return Container(
      height: 52,
      color: const Color(0xFF16213E),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // --- Mic icon (tap mute, long-press settings) ---
          GestureDetector(
            key: _micKey,
            onTap: () => notifier.toggleInputMute(),
            onLongPress: () => _showVoiceSettings(conn, notifier),
            child: Icon(Icons.mic, color: micColor, size: 28),
          ),
          const SizedBox(width: 24),
          // --- Away toggle ---
          Tooltip(
            message: conn.away
                ? AppLocalizations.of(context).awayDisable
                : AppLocalizations.of(context).awayEnable,
            child: GestureDetector(
              onTap: () => notifier.toggleAway(),
              child: Icon(
                Icons.access_time,
                color: conn.away ? Colors.amber : Colors.grey,
                size: 28,
              ),
            ),
          ),
          // --- PTT button (only in PTT mode) ---
          if (conn.pttMode) ...[
            const SizedBox(width: 24),

            IgnorePointer(
              ignoring: conn.inputMuted,
              child: Listener(
                onPointerDown: (_) => notifier.setPttPressed(true),
                onPointerUp: (_) => notifier.setPttPressed(false),
                onPointerCancel: (_) => notifier.setPttPressed(false),
                child: Container(
                  width: 64,
                  height: 40,
                  decoration: BoxDecoration(
                    color: conn.pttPressed
                        ? const Color(0xFF4444AA)
                        : const Color(0xFF2A2A4A),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFF888888),
                      // color: conn.pttPressed
                      //     ? Colors.lightGreenAccent
                      //     : const Color(0xFF888888),
                      width: 2,
                    ),
                  ),
                  child: const Center(
                    child: Text(
                      'PTT',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: 24),
          // --- Speaker icon (toggle output mute) ---
          GestureDetector(
            key: _speakerKey,
            onTap: () => notifier.toggleOutputMute(),
            child: Icon(
              Icons.volume_up,
              color: conn.outputMuted ? Colors.red : Colors.green,
              size: 28,
            ),
          ),
        ],
      ),
    );
  }

  void _showVoiceSettings(
    TsConnectionState conn,
    TsConnectionNotifier notifier,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF12122A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: VoiceSettingsPanel(conn: conn, notifier: notifier),
        );
      },
    );
  }
}

// ─── Per-client volume sheet ────────────────────────────────────────

class _ClientVolumeSheet extends StatefulWidget {
  final TsClient client;
  final TsConnectionNotifier notifier;

  /// The own client's id on the server — moderation actions are never
  /// offered for ourselves.
  final int ownClientId;

  /// Whether we are a server-query admin — permission-management entries are
  /// offered even before the client-permission hint bits arrive.
  final bool ownIsQueryAdmin;

  /// Whether our own directly-assigned permissions include a management
  /// power (active permission detection via clientpermlist).
  final bool ownCanManagePermissions;

  /// Our own privilege tier from server-group names — last-resort gate for
  /// the permission-management entries when permission hints and
  /// clientpermlist are both unavailable.
  final PrivilegeTier ownPrivilegeTier;

  /// Snapshot of the channel roster for the move-to-channel picker.
  final List<TsChannel> channels;

  const _ClientVolumeSheet({
    required this.client,
    required this.notifier,
    required this.ownClientId,
    required this.ownIsQueryAdmin,
    required this.ownCanManagePermissions,
    required this.ownPrivilegeTier,
    required this.channels,
  });

  @override
  State<_ClientVolumeSheet> createState() => _ClientVolumeSheetState();
}

class _ClientVolumeSheetState extends State<_ClientVolumeSheet> {
  late double _volume;

  @override
  void initState() {
    super.initState();
    _volume = widget.client.volume;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.client;
    final al = AppLocalizations.of(context);
    final isSelf = c.id == widget.ownClientId;
    // Scrollable so every action stays reachable even when all moderation +
    // permission-management buttons are shown at once.
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                // The client's avatar when one is set (talking = blue ring);
                // the fallback mic/person icon otherwise.
                Consumer(
                  builder: (context, ref, _) {
                    final avatarPath = ref.watch(
                      avatarCacheProvider,
                    )[c.avatarHash];
                    if (avatarPath == null) {
                      return Icon(
                        c.isTalking ? Icons.mic : Icons.person,
                        color: c.isTalking ? Colors.blue : Colors.grey,
                        size: 20,
                      );
                    }
                    return Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c.isTalking ? Colors.blue : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: ClipOval(
                        child: Image.file(
                          File(avatarPath),
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.low,
                          gaplessPlayback: true,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.nickname,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (c.isTalking)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      AppLocalizations.of(context).talking,
                      style: const TextStyle(color: Colors.blue, fontSize: 11),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  AppLocalizations.of(context).volume,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                Expanded(
                  child: Slider(
                    value: _volume,
                    min: -20.0,
                    max: 20.0,
                    divisions: 80,
                    activeColor: Colors.blue,
                    onChanged: (v) {
                      setState(() => _volume = v);
                      widget.notifier.setClientVolume(c.id, v);
                    },
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    '${_volume.toStringAsFixed(1)} dB',
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ),
              ],
            ),
            // ── Position (never for ourselves — we are the origin) ──
            if (!isSelf) ...[
              const SizedBox(height: 8),
              _actionButton(
                context,
                icon: Icons.spatial_audio,
                label: al.positionTitle,
                onPressed: () => pushPositionEditPage(context, c),
              ),
            ],
            const SizedBox(height: 20),
            // ── Permission-gated actions (never for ourselves) ──
            if (!isSelf && _hasAnyAction(c)) ...[
              const Divider(height: 1, color: Color(0xFF2A2A4A)),
              const SizedBox(height: 12),
              if (_canShowPoke(c))
                _actionButton(
                  context,
                  icon: Icons.notification_important,
                  label: al.poke,
                  onPressed: () => _showPokeDialog(context),
                ),
              if (_canShowAction(c, c.canMoveClient))
                _actionButton(
                  context,
                  icon: Icons.drive_file_move_outline,
                  label: al.menuMoveToChannel,
                  onPressed: () => _showMoveToChannelSheet(context),
                ),
              if (_canShowChannelKick(c))
                _actionButton(
                  context,
                  icon: Icons.logout,
                  label: al.menuKickFromChannel,
                  onPressed: () => _showKickDialog(context, fromServer: false),
                ),
              if (_canShowAction(c, c.canKickServer))
                _actionButton(
                  context,
                  icon: Icons.remove_circle_outline,
                  label: al.menuKickFromServer,
                  onPressed: () => _showKickDialog(context, fromServer: true),
                ),
              if (_canShowAction(c, c.canBan))
                _actionButton(
                  context,
                  icon: Icons.gavel,
                  label: al.menuBan,
                  onPressed: () => _showBanDialog(context),
                ),
            ],
            // ── Permission management (never for ourselves) ──
            if (!isSelf && _hasPermActions(c)) ...[
              const Divider(height: 1, color: Color(0xFF2A2A4A)),
              const SizedBox(height: 12),
              _actionButton(
                context,
                icon: Icons.groups,
                label: al.menuServerGroups,
                onPressed: () =>
                    _requireDbid(() => _showServerGroupsDialog(context)),
              ),
              _actionButton(
                context,
                icon: Icons.badge_outlined,
                label: al.menuChannelGroups,
                onPressed: () =>
                    _requireDbid(() => _showChannelGroupsDialog(context)),
              ),
              _actionButton(
                context,
                icon: Icons.admin_panel_settings_outlined,
                label: al.menuGrantRevokePerms,
                onPressed: () =>
                    _requireDbid(() => _showGrantPermDialog(context)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Poke is low-risk: when the permission hints have not arrived yet
  /// (`permissionHints == 0`) it is shown by default; once hints are known,
  /// the POKE bit gates it.
  bool _canShowPoke(TsClient c) => c.permissionHints == 0 || c.canPoke;

  /// Moderation actions are "unknown → optimistic": while the server has not
  /// pushed the client's permission-hint bits (`permissionHints == 0`) the
  /// action is shown and the server's real answer (which now arrives as a
  /// `perm_op` receipt) decides. Once the hints are known, the bit gates it.
  bool _canShowAction(TsClient c, bool granted) =>
      c.permissionHints == 0 || granted;

  /// A channel kick moves its target to the server's default channel — for a
  /// client already sitting there the server always rejects it, so the action
  /// is hidden entirely instead of failing at runtime.
  bool _canShowChannelKick(TsClient c) =>
      _canShowAction(c, c.canKickChannel) && !_targetInDefaultChannel;

  /// Whether this client's current channel is the default channel (unknown
  /// channel → show the action optimistically; the server's receipt decides).
  bool get _targetInDefaultChannel =>
      (widget.channels
          .where((ch) => ch.id == widget.client.channelId)
          .firstOrNull
          ?.isDefault) ??
      false;

  bool _hasAnyAction(TsClient c) =>
      _canShowPoke(c) ||
      _canShowAction(c, c.canMoveClient) ||
      _canShowChannelKick(c) ||
      _canShowAction(c, c.canKickServer) ||
      _canShowAction(c, c.canBan);

  /// Permission-management entries are offered when the server hints arrived,
  /// we are a query admin, our own directly-assigned permissions include a
  /// management power (active permission detection), or our own server-group
  /// name tier suggests moderation rights (last resort when both the hints
  /// and the clientpermlist answers are unavailable).
  bool _hasPermActions(TsClient c) =>
      c.permissionHints != 0 ||
      widget.ownIsQueryAdmin ||
      widget.ownCanManagePermissions ||
      widget.ownPrivilegeTier != PrivilegeTier.none;

  /// Group/perm commands need the target's database id; block with a hint
  /// while it is unknown.
  void _requireDbid(VoidCallback action) {
    if (widget.client.databaseId == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).dbIdUnavailable),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    action();
  }

  /// Shows the result of a permission operation: green on success, red with
  /// the server's reason on failure.
  void _reportPermOp(
    BuildContext context,
    String? error, {
    required String okLabel,
  }) {
    final al = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error == null ? okLabel : al.permOpFailed(error)),
        backgroundColor: error == null ? null : Colors.red.shade900,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Widget _actionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 18),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.blueAccent,
            side: const BorderSide(color: Color(0xFF2A2A4A)),
          ),
        ),
      ),
    );
  }

  /// Ask for a poke message and send it to this client.
  Future<void> _showPokeDialog(BuildContext context) async {
    final al = AppLocalizations.of(context);
    final msg = await showDialog<String>(
      context: context,
      builder: (ctx) => const _PokeDialog(),
    );
    final text = msg?.trim() ?? '';
    // An empty poke is allowed (TeamSpeak pokes without a message). Only
    // skip when the widget is gone.
    if (!mounted) return;
    widget.notifier.sendPoke(widget.client.id, text);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(al.pokeSent),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Channel picker for "move to channel": excludes the client's current
  /// channel. Uses the roster snapshot passed into the sheet.
  Future<void> _showMoveToChannelSheet(BuildContext context) async {
    final al = AppLocalizations.of(context);
    final candidates = widget.channels
        .where((ch) => ch.id != widget.client.channelId)
        .toList();
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(al.noChannels),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    final targetId = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF12122A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                  const Icon(
                    Icons.drive_file_move_outline,
                    size: 16,
                    color: Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${al.menuMoveToChannel} · ${widget.client.nickname}',
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
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: candidates.length,
                itemBuilder: (ctx, i) {
                  final ch = candidates[i];
                  return ListTile(
                    dense: true,
                    leading: const Icon(
                      Icons.tag,
                      size: 16,
                      color: Colors.grey,
                    ),
                    title: Text(
                      ch.name,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.of(ctx).pop(ch.id),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || targetId == null) return;
    // The server's real answer arrives through the perm_op receipt — show it
    // (green on accept, red with the server's reason on rejection).
    final error = await widget.notifier.moveClient(widget.client.id, targetId);
    if (!mounted) return;
    _reportPermOp(context, error, okLabel: al.moveSucceeded);
  }

  /// Confirm dialog for kicking a client from the channel or the server.
  /// The reason is optional — an empty reason kicks without a reason
  /// message (the server accepts that); only dismissing cancels.
  Future<void> _showKickDialog(
    BuildContext context, {
    required bool fromServer,
  }) async {
    final al = AppLocalizations.of(context);
    // The dialog pops the trimmed reason itself: null = dismissed,
    // empty = "start" pressed without a reason (a valid no-reason kick).
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) =>
          _KickDialog(nickname: widget.client.nickname, fromServer: fromServer),
    );
    // The dialog outcomes are otherwise invisible in logs (a dismissal
    // returns without any receipt), which makes "kick did nothing"
    // undiagnosable from logcat alone.
    debugPrint(
      'TS: kick dialog for client ${widget.client.id} returned: '
      '${reason == null
          ? 'dismissed'
          : reason.isEmpty
          ? 'confirmed (no reason)'
          : 'confirmed'}',
    );
    if (!mounted || reason == null) return;
    final error = await widget.notifier.kickClient(
      widget.client.id,
      fromServer: fromServer,
      reason: reason,
    );
    if (!mounted) return;
    // Green on the server's accept, red with its reason on rejection.
    _reportPermOp(context, error, okLabel: al.kickSent);
  }

  /// Ban dialog: duration presets + optional reason. `timeSeconds == 0`
  /// means a permanent ban; an empty reason cancels the ban.
  Future<void> _showBanDialog(BuildContext context) async {
    final al = AppLocalizations.of(context);
    // The dialog pops a (seconds, reason) record: null = dismissed.

    final result = await showDialog<(int, String)>(
      context: context,
      builder: (ctx) => _BanDialog(nickname: widget.client.nickname),
    );
    if (!mounted || result == null) return;
    final (seconds, reason) = result;
    // Empty reason cancels the ban (permanent bans especially need a reason).
    if (reason.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(al.banCanceled),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    final error = await widget.notifier.banClient(
      widget.client.id,
      timeSeconds: seconds,
      reason: reason,
    );
    if (!mounted) return;
    // Green on the server's accept, red with its reason on rejection.
    _reportPermOp(context, error, okLabel: al.banSent);
  }

  // ─── Permission management dialogs ────────────────────────────────

  /// Loads the server groups from Rust (asking the server again on the
  /// retry path via its onRetry hook).
  Future<List<TsServerGroup>> _loadServerGroups() async {
    final raw = TsNative.getServerGroups();
    return raw.map(TsServerGroup.fromJson).toList();
  }

  Future<List<TsChannelGroup>> _loadChannelGroups() async {
    final raw = TsNative.getChannelGroups();
    return raw.map(TsChannelGroup.fromJson).toList();
  }

  /// "Grant permissions (server groups)": checkbox list — checked = the
  /// client is a member. Toggling sends add/remove immediately and awaits
  /// the server's answer before re-reading the roster hint.
  Future<void> _showServerGroupsDialog(BuildContext context) async {
    final al = AppLocalizations.of(context);
    final dbid = widget.client.databaseId;

    List<TsServerGroup> groups;
    try {
      groups = await _loadServerGroups();
    } catch (_) {
      groups = const [];
    }
    if (!mounted) return;

    // Membership snapshot — starts from the roster, updated after each op.
    final memberIds = Set<int>.of(widget.client.serverGroupIds);
    // Group ids with an in-flight operation — hoisted so rebuilds keep the
    // double-tap guard alive.
    final busy = <int>{};

    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF12122A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.groups, size: 16, color: Colors.grey),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${al.menuServerGroups} · ${widget.client.nickname}',
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
                if (groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Text(
                          al.groupsNotLoaded,
                          style: const TextStyle(color: Colors.grey),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: () {
                            TsNative.refreshGroups();
                            Navigator.of(ctx).pop();
                            // Re-open after a short delay so the answer has a
                            // chance to arrive.
                            Future.delayed(
                              const Duration(milliseconds: 800),
                              () => _showServerGroupsDialog(context),
                            );
                          },
                          icon: const Icon(Icons.refresh, size: 18),
                          label: Text(al.retry),
                        ),
                      ],
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: groups.length,
                      itemBuilder: (lctx, i) {
                        final g = groups[i];
                        final isMember = memberIds.contains(g.id);
                        final isBusy = busy.contains(g.id);
                        return CheckboxListTile(
                          dense: true,
                          value: isMember,
                          onChanged: isBusy
                              ? null
                              : (checked) async {
                                  busy.add(g.id);
                                  setSheetState(() {});
                                  final error = (checked ?? false)
                                      ? await widget.notifier.addToServerGroup(
                                          dbid,
                                          g.id,
                                        )
                                      : await widget.notifier
                                            .removeFromServerGroup(dbid, g.id);
                                  busy.remove(g.id);
                                  if (!mounted) return;
                                  if (error == null) {
                                    if (checked ?? false) {
                                      memberIds.add(g.id);
                                    } else {
                                      memberIds.remove(g.id);
                                    }
                                    setSheetState(() {});
                                    _reportPermOp(
                                      context,
                                      null,
                                      okLabel: al.permOpSucceeded,
                                    );
                                  } else {
                                    setSheetState(() {});
                                    _reportPermOp(
                                      context,
                                      error,
                                      okLabel: al.permOpSucceeded,
                                    );
                                  }
                                },
                          title: Text(
                            g.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                          secondary: isBusy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : null,
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  /// "Channel group": radio list of all channel groups + a "clear group"
  /// entry. Applies to the client's CURRENT channel.
  Future<void> _showChannelGroupsDialog(BuildContext context) async {
    final al = AppLocalizations.of(context);
    final dbid = widget.client.databaseId;
    final cid = widget.client.channelId;

    List<TsChannelGroup> groups;
    try {
      groups = await _loadChannelGroups();
    } catch (_) {
      groups = const [];
    }
    if (!mounted) return;

    var current = widget.client.channelGroupId;

    await showModalBottomSheet<Object?>(
      context: context,
      backgroundColor: const Color(0xFF12122A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          Future<void> apply(int? cgid) async {
            final error = cgid == null
                ? await widget.notifier.clearChannelGroup(dbid, cid)
                : await widget.notifier.setChannelGroup(dbid, cgid, cid);
            if (!mounted) return;
            if (error == null) {
              current = cgid ?? 0;
              setSheetState(() {});
              _reportPermOp(context, null, okLabel: al.permOpSucceeded);
            } else {
              _reportPermOp(context, error, okLabel: al.permOpSucceeded);
            }
          }

          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.badge_outlined,
                        size: 16,
                        color: Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${al.menuChannelGroups} · ${widget.client.nickname}',
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
                if (groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Text(
                          al.groupsNotLoaded,
                          style: const TextStyle(color: Colors.grey),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: () {
                            TsNative.refreshGroups();
                            Navigator.of(ctx).pop();
                            Future.delayed(
                              const Duration(milliseconds: 800),
                              () => _showChannelGroupsDialog(context),
                            );
                          },
                          icon: const Icon(Icons.refresh, size: 18),
                          label: Text(al.retry),
                        ),
                      ],
                    ),
                  )
                else
                  Flexible(
                    child: RadioGroup<int>(
                      groupValue: current,
                      onChanged: (v) => apply(v),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: groups.length + 1,
                        itemBuilder: (lctx, i) {
                          if (i == 0) {
                            // "None" — the group is inherited/default, not set.
                            return RadioListTile<int>(
                              dense: true,
                              value: 0,
                              title: Text(
                                al.channelGroupNone,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                ),
                              ),
                            );
                          }
                          final g = groups[i - 1];
                          return RadioListTile<int>(
                            dense: true,
                            value: g.id,
                            title: Text(
                              g.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  /// "Grant / revoke permissions": two scopes —
  /// - channel permissions (`channelclientaddperm`, applies in the target's
  ///   current channel),
  /// - server-wide permissions (`clientaddperm`, applies everywhere).
  /// Each scope offers presets (talk power, priority speaker, channel
  /// commander) plus a custom permsid + value entry.
  Future<void> _showGrantPermDialog(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF12122A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) =>
          _GrantPermDialog(client: widget.client, notifier: widget.notifier),
    );
  }
}

/// One permission preset row in the grant/revoke dialog.
class _PermPreset {
  final String label;
  final String permsid;
  int grantValue;
  final List<int> valueChoices;
  final String currentHint;

  _PermPreset({
    required this.label,
    required this.permsid,
    required this.grantValue,
    required this.valueChoices,
    required this.currentHint,
  });
}

/// Poke-message prompt. Owns its [TextEditingController] so it outlives the
/// dialog's exit transition ([State.dispose] runs only after the route's widget
/// tree has stopped rebuilding), preventing "used after being disposed"
/// crashes during the animated close frames.
class _PokeDialog extends StatefulWidget {
  const _PokeDialog();

  @override
  State<_PokeDialog> createState() => _PokeDialogState();
}

class _PokeDialogState extends State<_PokeDialog> {
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
        al.poke,
        style: const TextStyle(color: Colors.white, fontSize: 18),
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: al.pokeHint,
          hintStyle: const TextStyle(color: Colors.grey),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(al.cancel, style: const TextStyle(color: Colors.grey)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(
            al.send,
            style: const TextStyle(color: Colors.blueAccent),
          ),
        ),
      ],
    );
  }
}

/// Kick-reason prompt. Pops the trimmed reason (or null when dismissed).
class _KickDialog extends StatefulWidget {
  /// The client's nickname for the dialog title.
  final String nickname;
  final bool fromServer;

  const _KickDialog({required this.nickname, required this.fromServer});

  @override
  State<_KickDialog> createState() => _KickDialogState();
}

class _KickDialogState extends State<_KickDialog> {
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
    final title = widget.fromServer
        ? al.menuKickFromServer
        : al.menuKickFromChannel;

    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: Text(
        '$title · ${widget.nickname}',
        style: const TextStyle(color: Colors.white, fontSize: 18),
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: al.kickReasonHint,
          hintStyle: const TextStyle(color: Colors.grey),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(al.cancel, style: const TextStyle(color: Colors.grey)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(
            al.startKick,
            style: const TextStyle(color: Colors.redAccent),
          ),
        ),
      ],
    );
  }
}

/// Ban dialog: duration presets + optional reason. Pops a (seconds,
/// reason) record, or null when dismissed.
class _BanDialog extends StatefulWidget {
  final String nickname;

  const _BanDialog({required this.nickname});

  @override
  State<_BanDialog> createState() => _BanDialogState();
}

class _BanDialogState extends State<_BanDialog> {
  late final TextEditingController _controller;
  int _seconds = 0; // default: permanent

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
        '${al.menuBan} · ${widget.nickname}',
        style: const TextStyle(color: Colors.white, fontSize: 18),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<int>(
            initialValue: _seconds,
            dropdownColor: const Color(0xFF1A1A2E),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: al.banDurationLabel,
              labelStyle: const TextStyle(color: Colors.grey),
              enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF2A2A4A)),
              ),
            ),
            items: [
              DropdownMenuItem(value: 0, child: Text(al.banDurationPermanent)),
              DropdownMenuItem(value: 3600, child: Text(al.banDuration1h)),
              DropdownMenuItem(value: 86400, child: Text(al.banDuration1d)),
              DropdownMenuItem(value: 604800, child: Text(al.banDuration1w)),
            ],
            onChanged: (v) => setState(() => _seconds = v ?? 0),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: al.banReasonHint,
              hintStyle: const TextStyle(color: Colors.grey),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(al.cancel, style: const TextStyle(color: Colors.grey)),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop((_seconds, _controller.text.trim())),
          child: Text(
            al.startBan,
            style: const TextStyle(color: Colors.redAccent),
          ),
        ),
      ],
    );
  }
}

/// Grant/revoke permissions sheet (channel + server scopes). Owns the
/// four custom permsid/value controllers, disposed on [State.dispose].
class _GrantPermDialog extends StatefulWidget {
  final TsClient client;
  final TsConnectionNotifier notifier;

  const _GrantPermDialog({required this.client, required this.notifier});

  @override
  State<_GrantPermDialog> createState() => _GrantPermDialogState();
}

class _GrantPermDialogState extends State<_GrantPermDialog> {
  late final TextEditingController _channelPermsid;
  late final TextEditingController _channelValue;
  late final TextEditingController _serverPermsid;
  late final TextEditingController _serverValue;
  // User-selected grant value per preset permsid (survives rebuilds).
  final Map<String, int> _grantValues = {};

  @override
  void initState() {
    super.initState();
    _channelPermsid = TextEditingController();
    _channelValue = TextEditingController(text: '1');
    _serverPermsid = TextEditingController();
    _serverValue = TextEditingController(text: '1');
  }

  @override
  void dispose() {
    _channelPermsid.dispose();
    _channelValue.dispose();
    _serverPermsid.dispose();
    _serverValue.dispose();
    super.dispose();
  }

  void _report(String? error) {
    final al = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error == null ? al.permOpSucceeded : al.permOpFailed(error),
        ),
        backgroundColor: error == null ? null : Colors.red.shade900,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// One preset row: label, permsid + current state, value picker and
  /// grant/revoke buttons wired to [onGrant]/[onRevoke].
  Widget _presetRow(
    _PermPreset p,
    Future<void> Function(int value) onGrant,
    Future<void> Function() onRevoke,
  ) {
    final al = AppLocalizations.of(context);
    return ListTile(
      dense: true,
      title: Text(
        p.label,
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
      subtitle: Text(
        '${p.permsid} · ${al.permCurrent(p.currentHint)}',
        style: const TextStyle(color: Colors.grey, fontSize: 11),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButton<int>(
            dropdownColor: const Color(0xFF1A1A2E),
            value: _grantValues[p.permsid] ?? p.grantValue,
            items: p.valueChoices
                .map(
                  (v) => DropdownMenuItem(
                    value: v,
                    child: Text(
                      '$v',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) {
              if (v != null) {
                setState(() => _grantValues[p.permsid] = v);
              }
            },
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: al.grantPermission,
            icon: const Icon(Icons.add_circle_outline, size: 20),
            color: Colors.greenAccent,
            onPressed: () => onGrant(_grantValues[p.permsid] ?? p.grantValue),
          ),
          IconButton(
            tooltip: al.revokePermission,
            icon: const Icon(Icons.remove_circle_outline, size: 20),
            color: Colors.redAccent,
            onPressed: onRevoke,
          ),
        ],
      ),
    );
  }

  /// Free-form permsid + value row for one scope.
  Widget _customRow({
    required TextEditingController permsidController,
    required TextEditingController valueController,
    required Future<void> Function(String permsid, int value) onGrant,
    required Future<void> Function(String permsid) onRevoke,
  }) {
    final al = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            al.permCustomSection,
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: permsidController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: al.permCustomPermsid,
                    hintStyle: const TextStyle(color: Colors.grey),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 64,
                child: TextField(
                  controller: valueController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: al.permCustomValue,
                    hintStyle: const TextStyle(color: Colors.grey),
                    isDense: true,
                  ),
                ),
              ),
              IconButton(
                tooltip: al.grantPermission,
                icon: const Icon(Icons.add_circle_outline, size: 20),
                color: Colors.greenAccent,
                onPressed: () {
                  final permsid = permsidController.text.trim();
                  final value = int.tryParse(valueController.text.trim()) ?? 0;
                  if (permsid.isNotEmpty) onGrant(permsid, value);
                },
              ),
              IconButton(
                tooltip: al.revokePermission,
                icon: const Icon(Icons.remove_circle_outline, size: 20),
                color: Colors.redAccent,
                onPressed: () {
                  final permsid = permsidController.text.trim();
                  if (permsid.isNotEmpty) onRevoke(permsid);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final al = AppLocalizations.of(context);
    final c = widget.client;
    final dbid = c.databaseId;
    final cid = c.channelId;
    // Presets are rebuilt every build; their grant values default to the
    // current client state, while user overrides live in [_grantValues].
    final presets = <_PermPreset>[
      _PermPreset(
        label: al.permPresetTalkPower,
        permsid: 'i_client_talk_power',
        grantValue: c.talkPower > 0 ? c.talkPower : 50,
        valueChoices: const [0, 25, 50, 75, 100],
        currentHint: '${c.talkPower}',
      ),
      _PermPreset(
        label: al.permPresetPrioritySpeaker,
        permsid: 'i_client_priority_speaker',
        grantValue: c.isPrioritySpeaker ? 1 : 0,
        valueChoices: const [0, 1],
        currentHint: c.isPrioritySpeaker ? '1' : '0',
      ),
      _PermPreset(
        label: al.permPresetChannelCommander,
        permsid: 'i_client_is_channel_commander',
        grantValue: c.isChannelCommander ? 1 : 0,
        valueChoices: const [0, 1],
        currentHint: c.isChannelCommander ? '1' : '0',
      ),
    ];

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          bottom: 12 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Text(
                '${al.menuGrantRevokePerms} · ${widget.client.nickname}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(height: 1, color: Color(0xFF2A2A4A)),
            // ── Channel-scoped permissions ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                al.permChannelSection,
                style: const TextStyle(
                  color: Colors.blueAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            for (final p in presets)
              _presetRow(
                p,
                (value) async {
                  final e = await widget.notifier.grantChannelPerm(
                    dbid,
                    cid,
                    p.permsid,
                    value,
                  );
                  _report(e);
                },
                () async {
                  final e = await widget.notifier.revokeChannelPerm(
                    dbid,
                    cid,
                    p.permsid,
                  );
                  _report(e);
                },
              ),
            _customRow(
              permsidController: _channelPermsid,
              valueController: _channelValue,
              onGrant: (permsid, value) async {
                final e = await widget.notifier.grantChannelPerm(
                  dbid,
                  cid,
                  permsid,
                  value,
                );
                _report(e);
              },
              onRevoke: (permsid) async {
                final e = await widget.notifier.revokeChannelPerm(
                  dbid,
                  cid,
                  permsid,
                );
                _report(e);
              },
            ),
            const Divider(height: 1, color: Color(0xFF2A2A4A)),
            // ── Server-wide permissions ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                al.permServerSection,
                style: const TextStyle(
                  color: Colors.blueAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            for (final p in presets)
              _presetRow(
                p,
                (value) async {
                  final e = await widget.notifier.grantServerPerm(
                    dbid,
                    p.permsid,
                    value,
                  );
                  _report(e);
                },
                () async {
                  final e = await widget.notifier.revokeServerPerm(
                    dbid,
                    p.permsid,
                  );
                  _report(e);
                },
              ),
            _customRow(
              permsidController: _serverPermsid,
              valueController: _serverValue,
              onGrant: (permsid, value) async {
                final e = await widget.notifier.grantServerPerm(
                  dbid,
                  permsid,
                  value,
                );
                _report(e);
              },
              onRevoke: (permsid) async {
                final e = await widget.notifier.revokeServerPerm(dbid, permsid);
                _report(e);
              },
            ),
          ],
        ),
      ),
    );
  }
}
