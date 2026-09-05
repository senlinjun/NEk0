import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/channel.dart';
import '../models/client.dart';
import '../models/group.dart';
import 'client_row.dart';

/// Where a drag hover currently points: "into" the row (become its child,
/// appended last) or "before/after" it (re-order among its siblings).
enum _DropZone { into, before, after }

/// What is being long-press-dragged: a channel (re-parent / re-order via
/// `channelmove`) or a client (move into a channel via `clientmove`).
enum _DragKind { channel, client }

class ChannelTree extends StatefulWidget {
  final List<TsChannel> channels;

  /// Every client on the server; those whose [TsClient.channelId] matches a
  /// channel are rendered nested under that channel's row (TS3 style).
  final List<TsClient> clients;
  final int? selectedChannelId;
  // Receives the whole channel (not just the id) so the caller can decide
  // e.g. to prompt for a password before joining.
  final ValueChanged<TsChannel> onChannelTap;

  /// Invoked on a long press — the caller decides what that means (usually:
  /// open the per-channel menu). Swap semantics with [onChannelTap] come
  /// from the settings' gesture option, not from this widget.
  final ValueChanged<TsChannel>? onChannelMenu;

  /// Whether a password was already entered for this channel during the
  /// session (rendered as an open lock). Null = never ask/known state,
  /// e.g. while disconnected.
  final bool Function(int channelId)? sessionPasswordKnown;

  /// Our own talk power, used to decide whether a channel's
  /// needed-talk-power bars us from speaking there.
  final int ownTalkPower;

  /// Invoked when a client row is tapped — the caller dispatches self
  /// (voice settings) vs. others (per-client action sheet).
  final ValueChanged<int>? onClientTap;

  /// Server groups for the privileged-identity badges on client rows.
  final List<TsServerGroup> serverGroups;

  /// The connected server's name — rendered as the TS3-style root node above
  /// the channel list (kept visible even while the roster is still empty).
  final String serverName;

  /// Invoked on tap/long-press of the server root node (server menu, e.g.
  /// "create channel"). Null disables both gestures on the node.
  final VoidCallback? onServerMenu;

  /// Invoked when a long-press-dragged channel is released on a valid drop
  /// target: [parentId] 0 = server root; [afterId] = the sibling the channel
  /// is placed after (0 = first, null = appended at the end). Null disables
  /// dragging entirely.
  final void Function(int draggedId, int parentId, int? afterId)? onChannelDrop;

  /// Our own client id. Our own row is always draggable — dropping it means
  /// joining the target channel, which the caller routes through the
  /// tap-to-join flow (no move permission involved). Null = self unknown.
  final int? ownClientId;

  /// Invoked when a long-press-dragged client is released on a channel row:
  /// moves that user into the channel (`clientmove`). Null disables client
  /// dragging entirely.
  final void Function(int clientId, int channelId)? onClientDrop;

  const ChannelTree({
    super.key,
    required this.channels,
    this.clients = const [],
    this.selectedChannelId,
    required this.onChannelTap,
    this.onChannelMenu,
    this.sessionPasswordKnown,
    this.ownTalkPower = 0,
    this.onClientTap,
    this.serverGroups = const [],
    this.serverName = '',
    this.onServerMenu,
    this.onChannelDrop,
    this.ownClientId,
    this.onClientDrop,
  });

  @override
  State<ChannelTree> createState() => _ChannelTreeState();
}

class _ChannelTreeState extends State<ChannelTree> {
  /// Manual expansion of channels WITHOUT clients (they default to
  /// collapsed).
  final Set<int> _expanded = {};

  /// Manual collapse of channels WITH clients (they default to expanded, so
  /// members of other channels are reachable without extra taps).
  final Set<int> _collapsed = {};

  // ─── Long-press drag (channelmove / clientmove) ─────────────────────

  /// Sentinel row id for the server root tile (a drop target for top level).
  static const _serverRowId = -1;

  /// Logical pixels a long press must travel before it becomes a drag —
  /// below that, releasing the long press opens the channel menu.
  static const _dragStartThreshold = 16.0;

  /// What is dragged and the dragged row's id (a channel id or a client id —
  /// only ever looked up against the list matching [_dragKind]).
  int? _draggingId;
  _DragKind? _dragKind;
  int? _hoverRowId;
  _DropZone? _hoverZone;

  /// Tree-local y of the insertion line while hovering a before/after zone.
  double? _hoverBoundaryY;

  /// Pointer position in tree-local coordinates for the floating name pill.
  final ValueNotifier<Offset> _dragPos = ValueNotifier(Offset.zero);
  Offset _dragGlobalStart = Offset.zero;

  /// Row hit-test keys, one per channel id plus the server root tile.
  final Map<int, GlobalKey> _rowKeys = {};
  final GlobalKey _serverRowKey = GlobalKey();

  List<TsChannel> get _roots => TsChannel.resolveOrder(
    widget.channels.where((c) => c.parentId == 0).toList()
      ..sort((a, b) => a.id.compareTo(b.id)),
  );

  /// Clients grouped by their channel id, in roster order.
  Map<int, List<TsClient>> get _clientsByChannel {
    final map = <int, List<TsClient>>{};
    for (final c in widget.clients) {
      map.putIfAbsent(c.channelId, () => []).add(c);
    }
    return map;
  }

  // ─── Drag gesture handling ──────────────────────────────────────────

  bool get _dragActive => _dragKind != null;

  Offset _toLocal(Offset global) {
    final box = context.findRenderObject();
    return box is RenderBox ? box.globalToLocal(global) : global;
  }

  /// The global Rect of a registered row (channel id or [_serverRowId]).
  Rect? _rowRect(int rowId) {
    final key = rowId == _serverRowId ? _serverRowKey : _rowKeys[rowId];
    final ctx = key?.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    return null;
  }

  /// The row under the global pointer, classified by vertical position:
  /// top band = insert before, middle = move into, bottom band = insert
  /// after. Null when the pointer is over no row.
  (int, _DropZone)? _hitTestRow(Offset global) {
    for (final rowId in [..._rowKeys.keys, _serverRowId]) {
      final rect = _rowRect(rowId);
      if (rect == null || !rect.contains(global)) continue;
      final t = (global.dy - rect.top) / rect.height;
      final zone = t < 0.28
          ? _DropZone.before
          : t > 0.72
          ? _DropZone.after
          : _DropZone.into;
      return (rowId, zone);
    }
    return null;
  }

  /// Channel ids inside [id]'s subtree, including [id] itself — the set of
  /// INVALID drop targets for a drag of [id] (a channel cannot move into
  /// itself).
  Set<int> _subtreeIds(int id) {
    final result = <int>{id};
    var grew = true;
    while (grew) {
      grew = false;
      for (final c in widget.channels) {
        if (result.contains(c.parentId) && result.add(c.id)) {
          grew = true;
        }
      }
    }
    return result;
  }

  void _onRowLongPressStart(LongPressStartDetails details) {
    _dragGlobalStart = details.globalPosition;
  }

  void _onRowLongPressMove(TsChannel channel, LongPressMoveUpdateDetails d) {
    if (!_dragActive) {
      if ((d.globalPosition - _dragGlobalStart).distance <
          _dragStartThreshold) {
        return;
      }
      setState(() {
        _dragKind = _DragKind.channel;
        _draggingId = channel.id;
      });
    }
    _dragPos.value = _toLocal(d.globalPosition);
    _updateHover(d.globalPosition);
  }

  void _onRowLongPressEnd(TsChannel channel) {
    if (!_dragActive) {
      // Plain long press (no drag): open the channel menu — the fixed
      // gesture, independent of the drag feature.
      widget.onChannelMenu?.call(channel);
      return;
    }
    _resolveDrop();
  }

  void _onRowLongPressCancel() {
    if (_dragActive) setState(_clearDrag);
  }

  /// Whether this client row may start a drag. Our own row always can —
  /// dropping it is a JOIN, not a `clientmove` of another user, so no move
  /// permission is needed. Everyone else uses the client sheet's move gate —
  /// "unknown → optimistic": while the server has not pushed the permission
  /// hints (`permissionHints == 0`) the drag is allowed and the server's
  /// perm_op receipt decides.
  bool _canDragClient(TsClient client) =>
      widget.onClientDrop != null &&
      (client.id == widget.ownClientId ||
          client.permissionHints == 0 ||
          client.canMoveClient);

  void _onClientLongPressMove(TsClient client, LongPressMoveUpdateDetails d) {
    if (!_dragActive) {
      if (!_canDragClient(client) ||
          (d.globalPosition - _dragGlobalStart).distance <
              _dragStartThreshold) {
        return;
      }
      setState(() {
        _dragKind = _DragKind.client;
        _draggingId = client.id;
      });
    }
    _dragPos.value = _toLocal(d.globalPosition);
    _updateHover(d.globalPosition);
  }

  void _onClientLongPressEnd(TsClient client) {
    if (!_dragActive) {
      // Plain long press (no drag): same as tapping the row — opens the
      // per-client sheet (voice settings for ourselves).
      widget.onClientTap?.call(client.id);
      return;
    }
    _resolveDrop();
  }

  void _clearDrag() {
    _draggingId = null;
    _dragKind = null;
    _hoverRowId = null;
    _hoverZone = null;
    _hoverBoundaryY = null;
  }

  void _updateHover(Offset global) {
    int? newHover;
    _DropZone? newZone;
    double? newBoundary;
    final hit = _hitTestRow(global);
    if (hit != null) {
      final (rowId, zone) = hit;
      if (_dragKind == _DragKind.client) {
        // A client always moves INTO a channel — every part of the row is
        // the same target (whole-row highlight, no insertion line). The
        // server node and the client's current channel are not targets.
        final client = widget.clients
            .where((c) => c.id == _draggingId)
            .firstOrNull;
        // Joining (our own row) also obeys the target's join permission —
        // the same gate as tapping the channel (unknown hints → optimistic),
        // so a channel we cannot join never highlights as a target.
        final target = widget.channels.where((c) => c.id == rowId).firstOrNull;
        final mayJoin =
            target == null || target.permissionHints == 0 || target.canJoin;
        if (rowId != _serverRowId &&
            client != null &&
            rowId != client.channelId &&
            (client.id != widget.ownClientId || mayJoin)) {
          newHover = rowId;
          newZone = _DropZone.into;
        }
      } else if (!_subtreeIds(_draggingId!).contains(rowId)) {
        newHover = rowId;
        newZone = zone;
        if (zone != _DropZone.into) {
          final rect = _rowRect(rowId);
          if (rect != null) {
            newBoundary = _toLocal(
              Offset(0, zone == _DropZone.before ? rect.top : rect.bottom),
            ).dy;
          }
        }
      }
    }
    if (newHover != _hoverRowId || newZone != _hoverZone) {
      setState(() {
        _hoverRowId = newHover;
        _hoverZone = newZone;
        _hoverBoundaryY = newBoundary;
      });
    }
  }

  /// Turns the current hover into a `channelmove` / `clientmove` call once
  /// the finger lifts. For channels, insertion points carry the id of the
  /// sibling the dropped channel must follow (0 = first) and "into" targets
  /// append at the end of that channel's children; for clients, any point of
  /// a channel row means "move the user into it".
  void _resolveDrop() {
    final dragged = _draggingId;
    final kind = _dragKind;
    final hover = _hoverRowId;
    final zone = _hoverZone;
    setState(_clearDrag);
    if (dragged == null || kind == null || hover == null || zone == null) {
      return;
    }
    if (kind == _DragKind.client) {
      if (widget.onClientDrop == null) return;
      // The user may have left the server while being dragged, and the
      // server node / their current channel were never valid targets.
      final client = widget.clients.where((c) => c.id == dragged).firstOrNull;
      if (client == null ||
          hover == _serverRowId ||
          hover == client.channelId) {
        return;
      }
      widget.onClientDrop!(dragged, hover);
      return;
    }
    if (widget.onChannelDrop == null) return;
    final draggedChannel = widget.channels
        .where((c) => c.id == dragged)
        .firstOrNull;
    if (draggedChannel == null) return;

    final int parentId;
    final int? afterId;
    if (hover == _serverRowId || zone == _DropZone.into) {
      parentId = hover == _serverRowId ? 0 : hover;
      afterId = _lastChildId(parentId);
    } else {
      final target = widget.channels.where((c) => c.id == hover).firstOrNull;
      if (target == null) return;
      parentId = target.parentId;
      afterId = zone == _DropZone.after
          ? target.id
          : _previousSiblingId(target);
    }
    // Same place as before — nothing to send.
    if (parentId == draggedChannel.parentId &&
        afterId == draggedChannel.order) {
      return;
    }
    widget.onChannelDrop!(dragged, parentId, afterId);
  }

  /// The resolved-order children of [parentId] (0 = top level).
  List<TsChannel> _orderedChildren(int parentId) => TsChannel.resolveOrder(
    widget.channels.where((c) => c.parentId == parentId).toList()
      ..sort((a, b) => a.id.compareTo(b.id)),
  );

  int _lastChildId(int parentId) {
    final kids = _orderedChildren(parentId);
    return kids.isEmpty ? 0 : kids.last.id;
  }

  int _previousSiblingId(TsChannel channel) {
    final siblings = _orderedChildren(channel.parentId);
    final idx = siblings.indexWhere((c) => c.id == channel.id);
    return idx <= 0 ? 0 : siblings[idx - 1].id;
  }

  /// Wraps the tree contents with the drag overlays: the insertion line and
  /// the floating name pill that follows the finger.
  Widget _withOverlays(Widget child) {
    return Stack(
      children: [
        child,
        if (_hoverZone != null &&
            _hoverZone != _DropZone.into &&
            _hoverBoundaryY != null)
          Positioned(
            left: 0,
            right: 0,
            top: _hoverBoundaryY! - 1.5,
            child: IgnorePointer(
              child: Container(height: 3, color: Colors.blueAccent),
            ),
          ),
        if (_dragActive)
          ValueListenableBuilder(
            valueListenable: _dragPos,
            builder: (context, pos, _) {
              final Widget pill;
              if (_dragKind == _DragKind.client) {
                final client = widget.clients
                    .where((c) => c.id == _draggingId)
                    .firstOrNull;
                if (client == null) return const SizedBox.shrink();
                pill = _dragPill(Icons.person, client.nickname);
              } else {
                final dragged = widget.channels
                    .where((c) => c.id == _draggingId)
                    .firstOrNull;
                if (dragged == null) return const SizedBox.shrink();
                pill = _dragPill(
                  dragged.children(widget.channels).isNotEmpty
                      ? Icons.folder
                      : Icons.tag,
                  dragged.name,
                );
              }
              return Positioned(
                left: pos.dx + 12,
                top: pos.dy - 14,
                child: IgnorePointer(child: pill),
              );
            },
          ),
      ],
    );
  }

  /// The floating pill that follows the finger during a drag: an icon plus
  /// the dragged channel's / client's name.
  Widget _dragPill(IconData icon, String label) {
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(14),
      color: const Color(0xFF16213E).withValues(alpha: 0.95),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.blue),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final roots = _roots;
    // The server root node stays visible even before the roster arrives —
    // an empty channel list shows it above the "no channels" hint instead
    // of swallowing the whole tree.
    if (roots.isEmpty) {
      return _withOverlays(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildServerTile(),
            Expanded(
              child: Center(
                child: Text(
                  AppLocalizations.of(context).noChannels,
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return _withOverlays(
      ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: roots.length + 1,
        // Index 0 is the server root node; the channels nest one level below.
        itemBuilder: (context, index) =>
            index == 0 ? _buildServerTile() : _buildTile(roots[index - 1], 1),
      ),
    );
  }

  /// The TS3-style server root node above the channel list. Both gestures
  /// open the server menu (there is nothing to "join" on the server itself).
  Widget _buildServerTile() {
    final canOpenMenu = widget.onServerMenu != null;
    final hovered = _hoverZone == _DropZone.into && _hoverRowId == _serverRowId;
    return Material(
      key: _serverRowKey,
      color: hovered ? Colors.blue.withValues(alpha: 0.25) : Colors.transparent,
      child: InkWell(
        onTap: canOpenMenu ? widget.onServerMenu : null,
        onLongPress: canOpenMenu ? widget.onServerMenu : null,
        child: Padding(
          padding: const EdgeInsets.only(
            left: 8,
            top: 10,
            bottom: 10,
            right: 8,
          ),
          child: Row(
            children: [
              // Aligns the server icon with the channel icons below it.
              const SizedBox(width: 22),
              const Icon(Icons.dns, size: 16, color: Colors.blue),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.serverName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTile(TsChannel channel, int depth) {
    final al = AppLocalizations.of(context);
    final children = channel.children(widget.channels);
    final clientsInChannel = _clientsByChannel[channel.id] ?? const [];
    final isSelected = channel.id == widget.selectedChannelId;
    final hasChildren = children.isNotEmpty;
    final hasClients = clientsInChannel.isNotEmpty;
    // A channel can be folded when it has sub-channels or members.
    final canCollapse = hasChildren || hasClients;
    final isExpanded = hasClients
        ? !_collapsed.contains(channel.id)
        : _expanded.contains(channel.id);
    // Permission hints arrive shortly after connect (the server pushes them
    // on subscribe). Until then `permissionHints == 0` means "unknown", not
    // "denied" — only gate once the server explicitly denies joining.
    final hintsKnown = channel.permissionHints != 0;
    final mayJoin = !hintsKnown || channel.canJoin || isSelected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Channel row — the outer GestureDetector owns the long press:
        // hold still (then release) = menu, hold + move = drag the channel.
        GestureDetector(
          onLongPressStart: _onRowLongPressStart,
          onLongPressMoveUpdate: (d) => _onRowLongPressMove(channel, d),
          onLongPressEnd: (_) => _onRowLongPressEnd(channel),
          onLongPressCancel: _onRowLongPressCancel,
          child: Material(
            key: _rowKeys.putIfAbsent(channel.id, () => GlobalKey()),
            color: _hoverZone == _DropZone.into && _hoverRowId == channel.id
                ? Colors.blue.withValues(alpha: 0.25)
                : isSelected
                ? Colors.blue.withValues(alpha: 0.15)
                : Colors.transparent,
            child: InkWell(
              onTap: () {
                // Permission gate: a channel we cannot join shows a hint
                // instead of attempting the move (skip when we are already in
                // it — the hints may lag behind the optimistic selection).
                if (!mayJoin) {
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      SnackBar(
                        content: Text(al.channelsNoJoinPermission),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  return;
                }
                widget.onChannelTap(channel);
                // Auto-expand the channel when joining it (also clears a
                // manual collapse so the member we "joined to meet" shows).
                if (canCollapse && !isExpanded) {
                  setState(() {
                    _expanded.add(channel.id);
                    _collapsed.remove(channel.id);
                  });
                }
              },
              child: Padding(
                padding: EdgeInsets.only(
                  left: 8.0 + depth * 20.0,
                  top: 10,
                  bottom: 10,
                  right: 8,
                ),
                child: Row(
                  children: [
                    // Expand/collapse arrow for foldable channels
                    if (canCollapse)
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            if (isExpanded) {
                              // Remember the collapse against whichever
                              // default currently applies to the channel.
                              if (hasClients) {
                                _collapsed.add(channel.id);
                              } else {
                                _expanded.remove(channel.id);
                              }
                            } else {
                              if (hasClients) {
                                _collapsed.remove(channel.id);
                              } else {
                                _expanded.add(channel.id);
                              }
                            }
                          });
                        },
                        child: Icon(
                          isExpanded
                              ? Icons.keyboard_arrow_down
                              : Icons.keyboard_arrow_right,
                          size: 18,
                          color: Colors.grey,
                        ),
                      )
                    else
                      const SizedBox(width: 18),
                    const SizedBox(width: 4),
                    // Channel icon
                    Icon(
                      hasChildren ? Icons.folder : Icons.tag,
                      size: 16,
                      color: isSelected ? Colors.blue : Colors.grey,
                    ),
                    const SizedBox(width: 6),
                    // Channel name with a trailing lock badge: closed = needs
                    // a password, open = already entered in this session.
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              channel.name,
                              style: TextStyle(
                                color: isSelected ? Colors.blue : Colors.white,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                fontSize: 14,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (channel.hasPassword) ...[
                            const SizedBox(width: 4),
                            Icon(
                              (widget.sessionPasswordKnown?.call(channel.id) ??
                                      false)
                                  ? Icons.lock_open
                                  : Icons.lock,
                              size: 12,
                              color: Colors.grey.withValues(alpha: 0.8),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Permission indicators: cannot join at all (only shown once the
                    // server has actually denied it), or our talk power is too
                    // low to speak in the channel.
                    if (hintsKnown && !channel.canJoin && !isSelected) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: al.channelsNoJoinPermission,
                        child: Icon(
                          Icons.block,
                          size: 13,
                          color: Colors.redAccent,
                        ),
                      ),
                    ],
                    if (channel.neededTalkPower > widget.ownTalkPower &&
                        !isSelected) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: al.channelTalkPowerNeeded(
                          channel.neededTalkPower,
                        ),
                        child: Icon(
                          Icons.mic_off,
                          size: 12,
                          color: Colors.amber,
                        ),
                      ),
                    ],
                    // Client count badge — redundant while the members are
                    // visible, so only shown on a folded channel.
                    if (channel.clientCount > 0 &&
                        !(isExpanded && hasClients)) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.grey.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${channel.clientCount}',
                          style: TextStyle(
                            color: isSelected ? Colors.blue : Colors.grey,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        // Members nested under their channel (TS3 order: clients above
        // sub-channels), then the sub-channels — only while expanded.
        if (isExpanded) ...[
          for (final client in clientsInChannel)
            // The outer GestureDetector owns the long press, mirroring the
            // channel rows: hold + move = drag the client onto a channel,
            // hold still (then release) = open the per-client sheet. The
            // inner ListTile keeps the tap.
            GestureDetector(
              onLongPressStart: _onRowLongPressStart,
              onLongPressMoveUpdate: (d) => _onClientLongPressMove(client, d),
              onLongPressEnd: (_) => _onClientLongPressEnd(client),
              onLongPressCancel: _onRowLongPressCancel,
              child: ClientRow(
                client: client,
                // Talk power is per channel: use THIS channel's restriction.
                channelNeededTalkPower: channel.neededTalkPower,
                serverGroups: widget.serverGroups,
                // Align roughly with the channel icon of this depth.
                indent: 30.0 + depth * 20.0,
                onTap: widget.onClientTap == null
                    ? null
                    : () => widget.onClientTap!(client.id),
              ),
            ),
          ...children.map((ch) => _buildTile(ch, depth + 1)),
        ],
      ],
    );
  }
}
