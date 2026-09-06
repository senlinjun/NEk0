/// One permission entry of OUR OWN client (from `clientpermlist`, requested
/// on connect). Only directly-assigned permissions are returned — inherited
/// and group-derived values are NOT included, so this is a low-threshold UI
/// hint (e.g. whether to show the permission-management entry), not an
/// authorization source for individual actions.
class TsPerm {
  final String name;
  final int value;
  final bool negated;
  final bool skip;

  const TsPerm({
    required this.name,
    required this.value,
    this.negated = false,
    this.skip = false,
  });

  factory TsPerm.fromJson(Map<String, dynamic> json) => TsPerm(
    name: json['name'] as String? ?? '',
    value: json['value'] as int? ?? 0,
    negated: json['negated'] as bool? ?? false,
    skip: json['skip'] as bool? ?? false,
  );

  bool get effectivePositive => !negated && value > 0;
}

/// Relevant permission names for the UI's low-threshold checks.
class PermNames {
  static const clientPermissionModify = 'i_client_permission_modify_power';
  static const groupMemberAdd = 'i_group_member_add_power';
  static const channelPermissionModify = 'i_channel_permission_modify_power';

  /// Sending server-wide chat messages (`targetmode=3`).
  static const serverTextMessageSend = 'b_client_server_textmessage_send';
}
