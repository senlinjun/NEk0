/// Raw `ClientPermissionHint` bits pushed by the server
/// (`notifyclientpermhints`): what WE may do to a given client.
class ClientPermission {
  static const int kickServer = 1 << 0; // i_client_kick_from_server_power
  static const int kickChannel = 1 << 1; // i_client_kick_from_channel_power
  static const int ban = 1 << 2; // i_client_ban_power
  static const int moveClient = 1 << 3; // i_client_move_power
  static const int privateMessage = 1 << 4;
  static const int poke = 1 << 5; // i_client_poke_power
  static const int whisper = 1 << 6;
  static const int complain = 1 << 7;
  static const int modifyPermissions = 1 << 8;

  static bool has(int hints, int bit) => hints & bit != 0;
}

/// Raw `ChannelPermissionHint` bits pushed by the server
/// (`notifychannelpermhints`): what WE may do in a channel.
class ChannelPermission {
  static const int join = 1 << 0; // b_channel_join_*
  static const int modify = 1 << 1; // i_channel_modify_power
  static const int forceDelete = 1 << 2;
  static const int delete = 1 << 3;
  static const int subscribe = 1 << 4;
  static const int viewDescription = 1 << 5;
  static const int fileUpload = 1 << 6;
  static const int fileDownload = 1 << 7;
  static const int fileDelete = 1 << 8;
  static const int fileRename = 1 << 9;
  static const int fileBrowse = 1 << 10;
  static const int fileDirectoryCreate = 1 << 11;
  static const int modifyPermissions = 1 << 12;

  static bool has(int hints, int bit) => hints & bit != 0;
}

class TsClient {
  final int id;
  final String nickname;
  final int channelId;
  final bool away;
  final bool inputMuted;
  final bool outputMuted;
  final bool isTalking;
  final double volume;

  /// 2D position relative to us in meters (+x = right, +y = forward).
  /// Null = no position set (centered playback).
  final double? positionX;
  final double? positionY;
  final String? uid;

  /// MD5 hash of the client's avatar (server-pushed `client_flag_avatar`).
  /// Null = no avatar set. Doubles as the avatar-cache key (content-addressed).
  final String? avatarHash;

  /// The client's database id (cldbid) used by group/permission commands.
  /// 0 while the server has not announced it yet.
  final int databaseId;

  /// 0 = normal client, 1 = server query, 2 = server query with admin.
  final int clientType;
  final bool isChannelCommander;
  final bool isRecording;
  final bool isPrioritySpeaker;

  /// False while this client's talk power is below the channel's
  /// needed-talk-power (they cannot speak there).
  final bool talkPowerGranted;

  /// i_client_talk_power of this client.
  final int talkPower;

  /// Raw `ClientPermissionHint` bits. 0 until the server pushes hints.
  final int permissionHints;
  final List<int> serverGroupIds;
  final List<String> serverGroupNames;
  final int channelGroupId;

  const TsClient({
    required this.id,
    required this.nickname,
    required this.channelId,
    this.away = false,
    this.inputMuted = false,
    this.outputMuted = false,
    this.isTalking = false,
    this.volume = 0.0,
    this.positionX,
    this.positionY,
    this.uid,
    this.avatarHash,
    this.databaseId = 0,
    this.clientType = 0,
    this.isChannelCommander = false,
    this.isRecording = false,
    this.isPrioritySpeaker = false,
    this.talkPowerGranted = true,
    this.talkPower = 0,
    this.permissionHints = 0,
    this.serverGroupIds = const [],
    this.serverGroupNames = const [],
    this.channelGroupId = 0,
  });

  factory TsClient.fromJson(Map<String, dynamic> json) => TsClient(
    id: json['id'] as int,
    nickname: json['nickname'] as String,
    channelId: json['channel_id'] as int,
    away: json['away'] as bool? ?? false,
    inputMuted: json['input_muted'] as bool? ?? false,
    outputMuted: json['output_muted'] as bool? ?? false,
    isTalking: json['is_talking'] as bool? ?? false,
    volume: (json['volume'] as num?)?.toDouble() ?? 0.0,
    positionX: (json['pos_x'] as num?)?.toDouble(),
    positionY: (json['pos_y'] as num?)?.toDouble(),
    uid: json['uid'] as String?,
    avatarHash: json['avatar_hash'] as String?,
    databaseId: (json['database_id'] as num?)?.toInt() ?? 0,
    clientType: json['client_type'] as int? ?? 0,
    isChannelCommander: json['is_channel_commander'] as bool? ?? false,
    isRecording: json['is_recording'] as bool? ?? false,
    isPrioritySpeaker: json['is_priority_speaker'] as bool? ?? false,
    talkPowerGranted: json['talk_power_granted'] as bool? ?? true,
    talkPower: json['talk_power'] as int? ?? 0,
    permissionHints: json['permission_hints'] as int? ?? 0,
    serverGroupIds: (json['server_groups'] as List?)?.cast<int>() ?? const [],
    serverGroupNames:
        (json['server_group_names'] as List?)?.cast<String>() ?? const [],
    channelGroupId: json['channel_group'] as int? ?? 0,
  );

  /// [position] is a record so that "not mentioned" (null record = keep the
  /// current values) stays distinguishable from "cleared" (`(x: null, y: null)`
  /// = centered playback again).
  TsClient copyWith({
    bool? isTalking,
    double? volume,
    ({double? x, double? y})? position,
  }) => TsClient(
    id: id,
    nickname: nickname,
    channelId: channelId,
    away: away,
    inputMuted: inputMuted,
    outputMuted: outputMuted,
    isTalking: isTalking ?? this.isTalking,
    volume: volume ?? this.volume,
    positionX: position != null ? position.x : this.positionX,
    positionY: position != null ? position.y : this.positionY,
    uid: uid,
    avatarHash: avatarHash,
    databaseId: databaseId,
    clientType: clientType,
    isChannelCommander: isChannelCommander,
    isRecording: isRecording,
    isPrioritySpeaker: isPrioritySpeaker,
    talkPowerGranted: talkPowerGranted,
    talkPower: talkPower,
    permissionHints: permissionHints,
    serverGroupIds: serverGroupIds,
    serverGroupNames: serverGroupNames,
    channelGroupId: channelGroupId,
  );

  bool get isQuery => clientType != 0;
  bool get isQueryAdmin => clientType == 2;

  // ─── Permission getters (what WE may do to this client) ────────────
  bool get canKickServer =>
      ClientPermission.has(permissionHints, ClientPermission.kickServer);
  bool get canKickChannel =>
      ClientPermission.has(permissionHints, ClientPermission.kickChannel);
  bool get canBan =>
      ClientPermission.has(permissionHints, ClientPermission.ban);
  bool get canMoveClient =>
      ClientPermission.has(permissionHints, ClientPermission.moveClient);
  bool get canPoke =>
      ClientPermission.has(permissionHints, ClientPermission.poke);
  bool get canWhisper =>
      ClientPermission.has(permissionHints, ClientPermission.whisper);
  bool get canPrivateMessage =>
      ClientPermission.has(permissionHints, ClientPermission.privateMessage);
  bool get canModifyPermissions =>
      ClientPermission.has(permissionHints, ClientPermission.modifyPermissions);
}
