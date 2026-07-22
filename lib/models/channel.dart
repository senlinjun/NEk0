class TsChannel {
  final int id;
  final String name;
  final int parentId;
  final String topic;
  final bool hasPassword;
  final int clientCount;
  final int order;

  const TsChannel({
    required this.id,
    required this.name,
    required this.parentId,
    this.topic = '',
    this.hasPassword = false,
    this.clientCount = 0,
    this.order = 0,
  });

  factory TsChannel.fromJson(Map<String, dynamic> json) => TsChannel(
    id: json['id'] as int,
    name: json['name'] as String,
    parentId: json['parent_id'] as int,
    topic: json['topic'] as String? ?? '',
    hasPassword: json['has_password'] as bool? ?? false,
    clientCount: json['client_count'] as int? ?? 0,
    order: json['order'] as int? ?? 0,
  );

  List<TsChannel> children(List<TsChannel> all) {
    return all.where((c) => c.parentId == id).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
  }
}
