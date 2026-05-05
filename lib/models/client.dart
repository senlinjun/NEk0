class TsClient {
  final int id;
  final String nickname;
  final int channelId;
  final bool away;
  final bool inputMuted;
  final bool outputMuted;
  final bool isTalking;

  const TsClient({
    required this.id,
    required this.nickname,
    required this.channelId,
    this.away = false,
    this.inputMuted = false,
    this.outputMuted = false,
    this.isTalking = false,
  });

  factory TsClient.fromJson(Map<String, dynamic> json) => TsClient(
        id: json['id'] as int,
        nickname: json['nickname'] as String,
        channelId: json['channel_id'] as int,
        away: json['away'] as bool? ?? false,
        inputMuted: json['input_muted'] as bool? ?? false,
        outputMuted: json['output_muted'] as bool? ?? false,
        isTalking: json['is_talking'] as bool? ?? false,
      );

  TsClient copyWith({bool? isTalking}) => TsClient(
        id: id,
        nickname: nickname,
        channelId: channelId,
        away: away,
        inputMuted: inputMuted,
        outputMuted: outputMuted,
        isTalking: isTalking ?? this.isTalking,
      );
}
