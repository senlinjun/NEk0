import 'package:flutter_test/flutter_test.dart';

import 'package:NEk0/models/server.dart';

Server server(String address, {int? voicePort}) => Server(
  id: 's',
  name: 'n',
  address: address,
  nickname: 'me',
  voicePort: voicePort,
);

void main() {
  group('Server.connectAddress', () {
    test('no custom port passes the address through', () {
      expect(server('ts.example.com').connectAddress, 'ts.example.com');
    });

    test('the default voice port passes the address through', () {
      expect(
        server('ts.example.com', voicePort: 9987).connectAddress,
        'ts.example.com',
      );
    });

    test('a custom port is appended to a bare host', () {
      expect(
        server('ts.example.com', voicePort: 10000).connectAddress,
        'ts.example.com:10000',
      );
    });

    test('an address that already carries a port is left alone', () {
      expect(
        server('ts.example.com:9988', voicePort: 10000).connectAddress,
        'ts.example.com:9988',
      );
    });

    test('ipv6 without a port gets the voice port appended', () {
      expect(server('[::1]', voicePort: 9988).connectAddress, '[::1]:9988');
    });

    test('ipv6 with a port is left alone', () {
      expect(
        server('[::1]:9988', voicePort: 10000).connectAddress,
        '[::1]:9988',
      );
    });

    test('a trailing colon without digits does not count as a port', () {
      expect(server('host:', voicePort: 9988).connectAddress, 'host::9988');
    });
  });

  group('Server JSON', () {
    test('roundtrips every field', () {
      final s = Server(
        id: 'u1',
        name: 'Home',
        address: 'ts.example.com',
        nickname: 'me',
        channel: 'Lobby',
        password: 'p',
        token: 'tok',
        voicePort: 9988,
        serverQueryPort: 10011,
        serverQuerySshPort: 10022,
        fileTransferPort: 30033,
      );
      final back = Server.fromJson(s.toJson());
      expect(back.id, s.id);
      expect(back.name, s.name);
      expect(back.address, s.address);
      expect(back.nickname, s.nickname);
      expect(back.channel, s.channel);
      expect(back.password, s.password);
      expect(back.token, s.token);
      expect(back.voicePort, s.voicePort);
      expect(back.serverQueryPort, s.serverQueryPort);
      expect(back.serverQuerySshPort, s.serverQuerySshPort);
      expect(back.fileTransferPort, s.fileTransferPort);
      expect(back.toJson(), s.toJson());
    });

    test('tolerates records saved before token and ports existed', () {
      final s = Server.fromJson({
        'id': 'u1',
        'name': 'Home',
        'address': 'a',
        'nickname': 'me',
      });
      expect(s.token, isNull);
      expect(s.channel, isNull);
      expect(s.password, isNull);
      expect(s.voicePort, isNull);
      expect(s.serverQueryPort, isNull);
      expect(s.serverQuerySshPort, isNull);
      expect(s.fileTransferPort, isNull);
    });
  });

  group('Server.copyWith', () {
    final s = Server(
      id: 'u',
      name: 'n',
      address: 'a',
      nickname: 'me',
      token: 'tok',
    );

    test('keeps the token by default', () {
      expect(s.copyWith().token, 'tok');
    });

    test('a new token replaces the old one', () {
      expect(s.copyWith(token: 't2').token, 't2');
    });

    test('clearToken drops the token even with a new one supplied', () {
      expect(s.copyWith(clearToken: true).token, isNull);
      expect(s.copyWith(token: 'x', clearToken: true).token, isNull);
    });
  });
}
