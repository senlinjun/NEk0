import 'dart:collection';

import 'client.dart';

class TsChannel {
  final int id;
  final String name;
  final int parentId;
  final String topic;
  final bool hasPassword;
  final int clientCount;
  final int order;

  /// The server's default channel. A channel kick moves its target here, so
  /// a client in the default channel cannot be kicked from their channel.
  final bool isDefault;

  /// Raw `ChannelPermissionHint` bits. 0 until the server pushes hints.
  final int permissionHints;

  /// i_channel_needed_talk_power (0 = no talk restriction).
  final int neededTalkPower;

  /// channel_maxclients (-1 = unlimited / inherited).
  final int maxClients;

  /// channel_flag_permanent / channel_flag_semi_permanent (both false =
  /// temporary — deleted when empty).
  final bool isPermanent;
  final bool isSemiPermanent;

  /// channel_description. '' does not necessarily mean "unset" — the roster
  /// does not carry descriptions; they arrive via channeledited broadcasts.
  final String description;

  /// channel_maxfamilyclients (-1 inherited/unknown, 0 unlimited, >0 limit).
  final int maxFamilyClients;

  /// channel_delete_delay in seconds (0 = delete as soon as empty).
  final int deleteDelay;

  const TsChannel({
    required this.id,
    required this.name,
    required this.parentId,
    this.topic = '',
    this.hasPassword = false,
    this.clientCount = 0,
    this.order = 0,
    this.isDefault = false,
    this.permissionHints = 0,
    this.neededTalkPower = 0,
    this.maxClients = -1,
    this.isPermanent = false,
    this.isSemiPermanent = false,
    this.description = '',
    this.maxFamilyClients = -1,
    this.deleteDelay = 0,
  });

  factory TsChannel.fromJson(Map<String, dynamic> json) => TsChannel(
    id: json['id'] as int,
    name: json['name'] as String,
    parentId: json['parent_id'] as int,
    topic: json['topic'] as String? ?? '',
    hasPassword: json['has_password'] as bool? ?? false,
    clientCount: json['client_count'] as int? ?? 0,
    order: json['order'] as int? ?? 0,
    isDefault: json['is_default'] as bool? ?? false,
    permissionHints: json['permission_hints'] as int? ?? 0,
    neededTalkPower: json['needed_talk_power'] as int? ?? 0,
    maxClients: json['max_clients'] as int? ?? -1,
    isPermanent: json['is_permanent'] as bool? ?? false,
    isSemiPermanent: json['is_semi_permanent'] as bool? ?? false,
    description: json['description'] as String? ?? '',
    maxFamilyClients: json['max_family_clients'] as int? ?? -1,
    deleteDelay: json['delete_delay'] as int? ?? 0,
  );

  // ─── Permission getters (what WE may do in this channel) ───────────
  bool get canJoin =>
      ChannelPermission.has(permissionHints, ChannelPermission.join);
  bool get canModify =>
      ChannelPermission.has(permissionHints, ChannelPermission.modify);
  bool get canDelete =>
      ChannelPermission.has(permissionHints, ChannelPermission.delete);
  bool get canFileBrowse =>
      ChannelPermission.has(permissionHints, ChannelPermission.fileBrowse);
  bool get canFileUpload =>
      ChannelPermission.has(permissionHints, ChannelPermission.fileUpload);
  bool get canFileDownload =>
      ChannelPermission.has(permissionHints, ChannelPermission.fileDownload);
  bool get canModifyPermissions => ChannelPermission.has(
    permissionHints,
    ChannelPermission.modifyPermissions,
  );

  /// Neither permanent nor semi-permanent: the server deletes the channel
  /// when it becomes empty.
  bool get isTemporary => !isPermanent && !isSemiPermanent;

  List<TsChannel> children(List<TsChannel> all) {
    return TsChannel.resolveOrder(
      all.where((c) => c.parentId == id).toList()
        ..sort((a, b) => a.id.compareTo(b.id)),
    );
  }

  /// Resolves the TS3 sibling order chain. TS3 orders siblings as a linked
  /// list — each channel's `order` is the id of the channel it comes AFTER —
  /// so a numeric sort of the raw order values is wrong whenever channel ids
  /// are not creation-ordered (deleted and re-created channels). Walks from
  /// the head (order pointing outside the sibling set) along the pointers;
  /// anything unresolvable (dangling or cyclic) is appended sorted by raw
  /// order value, then id.
  static List<TsChannel> resolveOrder(List<TsChannel> siblings) {
    if (siblings.length <= 1) return siblings;
    final ids = siblings.map((c) => c.id).toSet();
    final heads = siblings.where((c) => !ids.contains(c.order)).toList()
      ..sort(
        (a, b) => a.order != b.order
            ? a.order.compareTo(b.order)
            : a.id.compareTo(b.id),
      );
    final result = <TsChannel>[];
    final placed = <int>{};
    final queue = Queue<TsChannel>.of(heads);
    while (queue.isNotEmpty) {
      final c = queue.removeFirst();
      if (placed.contains(c.id)) continue;
      placed.add(c.id);
      result.add(c);
      queue.addAll(
        siblings.where((s) => s.order == c.id && !placed.contains(s.id)),
      );
    }
    result.addAll(
      siblings.where((s) => !placed.contains(s.id)).toList()..sort(
        (a, b) => a.order != b.order
            ? a.order.compareTo(b.order)
            : a.id.compareTo(b.id),
      ),
    );
    return result;
  }
}
