import 'package:flutter_test/flutter_test.dart';

import 'package:NEk0/models/channel.dart';
import 'package:NEk0/models/client.dart';
import 'package:NEk0/models/roster_parser.dart';

void main() {
  group('parseChannelRoster', () {
    test('parses a well-formed array', () {
      final channels = parseChannelRoster('''
        [
          {"id": 1, "name": "Lobby", "parent_id": 0},
          {"id": 2, "name": "Gaming", "parent_id": 0, "client_count": 3}
        ]
      ''');
      expect(channels.length, 2);
      expect(channels[0].id, 1);
      expect(channels[0].name, 'Lobby');
      expect(channels[0].parentId, 0);
      expect(channels[1].clientCount, 3);
    });

    test('an empty array parses to an empty list', () {
      expect(parseChannelRoster('[]'), isEmpty);
    });

    test('a malformed row is skipped, the rest survive', () {
      final channels = parseChannelRoster('''
        [
          {"id": 1, "name": "Lobby", "parent_id": 0},
          {"id": 2},
          {"id": 3, "name": "AFK", "parent_id": 0}
        ]
      ''');
      // Row 2 lacks the required name — skipped without failing the batch.
      expect(channels.map((c) => c.id), [1, 3]);
    });

    test('unparseable JSON yields an empty list instead of throwing', () {
      expect(parseChannelRoster('not json'), isEmpty);
    });
  });

  group('parseClientRoster', () {
    test('parses a well-formed array', () {
      final clients = parseClientRoster('''
        [{"id": 7, "nickname": "alice", "channel_id": 1}]
      ''');
      expect(clients.single.nickname, 'alice');
      expect(clients.single.channelId, 1);
    });

    test('a malformed row is skipped, the rest survive', () {
      final clients = parseClientRoster('''
        [
          {"id": 7, "nickname": "alice", "channel_id": 1},
          {"nickname": "no id"},
          {"id": 9, "nickname": "carol", "channel_id": 2}
        ]
      ''');
      expect(clients.map((c) => c.id), [7, 9]);
    });

    test('unparseable JSON yields an empty list instead of throwing', () {
      expect(parseClientRoster('{'), isEmpty);
    });
  });

  group('merge policies', () {
    test('hasUsableChannels requires a root', () {
      expect(hasUsableChannels([]), isFalse);
      expect(
        hasUsableChannels([TsChannel(id: 2, name: 'sub', parentId: 1)]),
        isFalse,
      );
      expect(
        hasUsableChannels([TsChannel(id: 1, name: 'root', parentId: 0)]),
        isTrue,
      );
    });

    test('empty/rootless incoming never replaces a usable tree', () {
      final current = [TsChannel(id: 1, name: 'root', parentId: 0)];
      final rootless = [TsChannel(id: 2, name: 'sub', parentId: 1)];
      expect(mergeChannelRoster(current, const []), same(current));
      expect(mergeChannelRoster(current, rootless), same(current));
    });

    test('a usable incoming snapshot replaces the current tree', () {
      final current = [TsChannel(id: 1, name: 'root', parentId: 0)];
      final fresh = [
        TsChannel(id: 1, name: 'root', parentId: 0),
        TsChannel(id: 2, name: 'new', parentId: 0),
      ];
      expect(mergeChannelRoster(current, fresh), same(fresh));
    });

    test('a rootless snapshot may fill an unusable current tree', () {
      final rootless = [TsChannel(id: 2, name: 'sub', parentId: 1)];
      expect(mergeChannelRoster(const [], rootless), same(rootless));
    });

    test('empty incoming never clears live clients', () {
      final current = [TsClient(id: 7, nickname: 'alice', channelId: 1)];
      expect(mergeClientRoster(current, const []), same(current));
      final fresh = [TsClient(id: 8, nickname: 'bob', channelId: 1)];
      expect(mergeClientRoster(current, fresh), same(fresh));
    });
  });
}
