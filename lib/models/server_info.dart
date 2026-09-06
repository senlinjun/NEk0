/// Snapshot of the server's editable properties for the server settings
/// page prefill (from `ts_get_server_info`, refreshed from the book on
/// every roster event). The password itself is never readable — only
/// [hasPassword], which is usually null because we never request the
/// server's optional data block.
class TsServerInfo {
  final String name;
  final String welcomeMessage;
  final int? maxClients;
  final bool? hasPassword;

  const TsServerInfo({
    this.name = '',
    this.welcomeMessage = '',
    this.maxClients,
    this.hasPassword,
  });

  factory TsServerInfo.fromJson(Map<String, dynamic> json) => TsServerInfo(
    name: json['name'] as String? ?? '',
    welcomeMessage: json['welcome_message'] as String? ?? '',
    maxClients: (json['max_clients'] as num?)?.toInt(),
    hasPassword: json['has_password'] as bool?,
  );
}
