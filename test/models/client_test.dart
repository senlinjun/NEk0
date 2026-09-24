import 'package:flutter_test/flutter_test.dart';

import 'package:NEk0/models/client.dart';

void main() {
  group('TsClient.fromJson', () {
    test('minimal json applies the documented defaults', () {
      final c = TsClient.fromJson({
        'id': 7,
        'nickname': 'Alice',
        'channel_id': 2,
      });
      expect(c.id, 7);
      expect(c.nickname, 'Alice');
      expect(c.channelId, 2);
      expect(c.away, isFalse);
      expect(c.inputMuted, isFalse);
      expect(c.outputMuted, isFalse);
      expect(c.isTalking, isFalse);
      expect(c.volume, 0.0);
      expect(c.positionX, isNull);
      expect(c.positionY, isNull);
      expect(c.uid, isNull);
      expect(c.avatarHash, isNull);
      expect(c.databaseId, 0);
      expect(c.clientType, 0);
      expect(c.isChannelCommander, isFalse);
      expect(c.isRecording, isFalse);
      expect(c.isPrioritySpeaker, isFalse);
      // Talk power starts GRANTED — a restriction is the exception.
      expect(c.talkPowerGranted, isTrue);
      expect(c.talkPower, 0);
      expect(c.permissionHints, 0);
      expect(c.serverGroupIds, isEmpty);
      expect(c.serverGroupNames, isEmpty);
      expect(c.channelGroupId, 0);
      expect(c.isQuery, isFalse);
      expect(c.isQueryAdmin, isFalse);
    });

    test('reads every field and coerces numeric json types', () {
      final c = TsClient.fromJson({
        'id': 7,
        'nickname': 'Alice',
        'channel_id': 2,
        'away': true,
        'input_muted': true,
        'output_muted': true,
        'is_talking': true,
        'volume': 1, // int in json → toDouble
        'database_id': 12.0, // double → toInt
        'client_type': 2,
        'is_channel_commander': true,
        'is_recording': true,
        'is_priority_speaker': true,
        'talk_power_granted': false,
        'talk_power': 75,
        'permission_hints': 3,
        'server_groups': [6, 7],
        'server_group_names': ['Admin', 'Mod'],
        'channel_group': 5,
        'pos_x': 1.5,
        'pos_y': -2,
        'uid': 'u==',
        'avatar_hash': 'md5',
      });
      expect(c.away, isTrue);
      expect(c.inputMuted, isTrue);
      expect(c.outputMuted, isTrue);
      expect(c.isTalking, isTrue);
      expect(c.volume, 1.0);
      expect(c.databaseId, 12);
      expect(c.clientType, 2);
      expect(c.isChannelCommander, isTrue);
      expect(c.isRecording, isTrue);
      expect(c.isPrioritySpeaker, isTrue);
      expect(c.talkPowerGranted, isFalse);
      expect(c.talkPower, 75);
      expect(c.permissionHints, 3);
      expect(c.serverGroupIds, [6, 7]);
      expect(c.serverGroupNames, ['Admin', 'Mod']);
      expect(c.channelGroupId, 5);
      expect(c.positionX, 1.5);
      expect(c.positionY, -2.0);
      expect(c.uid, 'u==');
      expect(c.avatarHash, 'md5');
      expect(c.isQuery, isTrue);
      expect(c.isQueryAdmin, isTrue);
    });
  });

  test('copyWith position: absent record keeps values, null record clears', () {
    const c = TsClient(
      id: 1,
      nickname: 'a',
      channelId: 0,
      positionX: 3,
      positionY: 4,
    );
    // No position argument at all = untouched.
    expect(c.copyWith(volume: 0.5).positionX, 3);
    expect(c.copyWith(volume: 0.5).positionY, 4);
    // (x: null, y: null) explicitly clears → centered playback again.
    final cleared = c.copyWith(position: (x: null, y: null));
    expect(cleared.positionX, isNull);
    expect(cleared.positionY, isNull);
    // One-sided moves keep the other coordinate.
    final moved = c.copyWith(position: (x: 1.0, y: null));
    expect(moved.positionX, 1.0);
    expect(moved.positionY, isNull);
  });

  test('client permission getters decode hint bits', () {
    // kickServer=1, kickChannel=2, ban=4, poke=32.
    const c = TsClient(
      id: 1,
      nickname: 'a',
      channelId: 0,
      permissionHints: 1 | 2 | 4 | 32,
    );
    expect(c.canKickServer, isTrue);
    expect(c.canKickChannel, isTrue);
    expect(c.canBan, isTrue);
    expect(c.canPoke, isTrue);
    expect(c.canMoveClient, isFalse);
    expect(c.canWhisper, isFalse);
    expect(c.canPrivateMessage, isFalse);
    expect(c.canModifyPermissions, isFalse);
  });
}
