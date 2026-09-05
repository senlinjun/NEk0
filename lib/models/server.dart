/// Default port constants for a TeamSpeak 3 server, per
/// https://support.teamspeak.com/hc/en-us/articles/360002712257-Which-ports-does-the-TeamSpeak-3-server-use
class ServerPorts {
  /// Voice (voice) port, UDP. This is the port the NEk0 client actually
  /// connects to.
  static const int voice = 9987;

  /// ServerQuery port, TCP (plaintext).
  static const int serverQuery = 10011;

  /// ServerQuery SSH port, TCP.
  static const int serverQuerySsh = 10022;

  /// File transfer port, TCP.
  static const int fileTransfer = 30033;
}

class Server {
  final String id;
  final String name;
  final String address;
  final String nickname;
  final String? channel;
  final String? password;

  /// One-time privilege key (admin token) for the first login. The server
  /// redeems it during the handshake and grants the associated server
  /// groups; it is cleared after a successful connection.
  final String? token;

  /// Custom ports for this server's connection. Null means "use the default".
  final int? voicePort;
  final int? serverQueryPort;
  final int? serverQuerySshPort;
  final int? fileTransferPort;

  Server({
    required this.id,
    required this.name,
    required this.address,
    required this.nickname,
    this.channel,
    this.password,
    this.token,
    this.voicePort,
    this.serverQueryPort,
    this.serverQuerySshPort,
    this.fileTransferPort,
  });

  /// `clearToken` exists because `token: null` would keep the old value
  /// (the usual copyWith trap); it explicitly drops the one-time key.
  Server copyWith({String? token, bool clearToken = false}) => Server(
    id: id,
    name: name,
    address: address,
    nickname: nickname,
    channel: channel,
    password: password,
    token: clearToken ? null : (token ?? this.token),
    voicePort: voicePort,
    serverQueryPort: serverQueryPort,
    serverQuerySshPort: serverQuerySshPort,
    fileTransferPort: fileTransferPort,
  );

  /// Address with the custom voice port embedded. tsclientlib's resolver
  /// natively understands `host:port`, `1.2.3.4:port` and `[::1]:port`, so the
  /// voice port only takes effect once it is part of the string we hand to the
  /// connection. The other ports are kept for reference and are not used by
  /// the NEk0 voice connection.
  String get connectAddress {
    final voice = voicePort;
    if (voice == null || voice == ServerPorts.voice) return address;
    // If the address already carries a port (host:port or [ipv6]:port) leave it
    // as the user entered it; otherwise append the voice port.
    if (_hasExplicitPort(address)) return address;
    return '$address:$voice';
  }

  /// Heuristic: does `a` already end with `:digits`? IPv6 literal brackets are
  /// stripped first so `[::1]` (no port) is treated as port-less while
  /// `[::1]:9988` keeps its port.
  static bool _hasExplicitPort(String a) {
    var s = a.trim();
    if (s.startsWith('[')) {
      final close = s.indexOf(']');
      if (close != -1) {
        s = s.substring(close + 1);
      }
    }
    final colon = s.lastIndexOf(':');
    if (colon < 0) return false;
    return int.tryParse(s.substring(colon + 1)) != null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'nickname': nickname,
    'channel': channel,
    'password': password,
    'token': token,
    'voicePort': voicePort,
    'serverQueryPort': serverQueryPort,
    'serverQuerySshPort': serverQuerySshPort,
    'fileTransferPort': fileTransferPort,
  };

  factory Server.fromJson(Map<String, dynamic> json) => Server(
    id: json['id'] as String,
    name: json['name'] as String,
    address: json['address'] as String,
    nickname: json['nickname'] as String,
    channel: json['channel'] as String?,
    password: json['password'] as String?,
    // Tolerate records saved before the token field existed.
    token: json['token'] as String?,
    // Tolerate records saved before the port fields existed.
    voicePort: json['voicePort'] as int?,
    serverQueryPort: json['serverQueryPort'] as int?,
    serverQuerySshPort: json['serverQuerySshPort'] as int?,
    fileTransferPort: json['fileTransferPort'] as int?,
  );
}
