class Server {
  final String id;
  final String name;
  final String address;
  final String nickname;
  final String? channel;
  final String? password;

  Server({
    required this.id,
    required this.name,
    required this.address,
    required this.nickname,
    this.channel,
    this.password,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'address': address,
        'nickname': nickname,
        'channel': channel,
        'password': password,
      };

  factory Server.fromJson(Map<String, dynamic> json) => Server(
        id: json['id'] as String,
        name: json['name'] as String,
        address: json['address'] as String,
        nickname: json['nickname'] as String,
        channel: json['channel'] as String?,
        password: json['password'] as String?,
      );
}
