import 'package:flutter_test/flutter_test.dart';

import 'package:NEk0/models/channel.dart';

TsChannel ch(int id, {int parentId = 0, int order = 0}) =>
    TsChannel(id: id, name: 'c$id', parentId: parentId, order: order);

void main() {
  group('TsChannel.resolveOrder', () {
    test('keeps a well-formed chain', () {
      final siblings = [ch(1, order: 0), ch(2, order: 1), ch(3, order: 2)];
      expect(TsChannel.resolveOrder(siblings).map((c) => c.id), [1, 2, 3]);
    });

    test(
      'orders by the chain, not by id (deleted and re-created channels)',
      () {
        // Channel 1 was deleted and re-created as 5: the sibling chain is
        // 0 → 5 → 2 → 9 while the ids are no longer creation-ordered. A
        // numeric id sort would give [2, 5, 9] — the wrong order.
        final siblings = [ch(2, order: 5), ch(9, order: 2), ch(5, order: 0)];
        expect(TsChannel.resolveOrder(siblings).map((c) => c.id), [5, 2, 9]);
      },
    );

    test('input order does not matter', () {
      final siblings = [ch(9, order: 2), ch(5, order: 0), ch(2, order: 5)];
      expect(TsChannel.resolveOrder(siblings).map((c) => c.id), [5, 2, 9]);
    });

    test('falls back to (order, id) sorting for unresolvable siblings', () {
      // c1 and c2 point at each other (cycle), so nothing places them; c3
      // is the only head. The unplaced pair is appended ordered by raw
      // order value.
      final siblings = [ch(1, order: 2), ch(2, order: 1), ch(3, order: 0)];
      expect(TsChannel.resolveOrder(siblings).map((c) => c.id), [3, 2, 1]);
    });

    test('a dangling order value starts a second head', () {
      // c2's order (7) points outside the sibling set, so it is a second
      // chain head. Heads are walked breadth-first through one queue: c2
      // was enqueued before c3 was discovered from c1, so it lands first.
      final siblings = [ch(2, order: 7), ch(1, order: 0), ch(3, order: 1)];
      expect(TsChannel.resolveOrder(siblings).map((c) => c.id), [1, 2, 3]);
    });

    test('empty and single-element lists pass through', () {
      expect(TsChannel.resolveOrder(const []), isEmpty);
      expect(TsChannel.resolveOrder([ch(4)]).map((c) => c.id), [4]);
    });
  });

  group('TsChannel.fromJson', () {
    test('applies defaults for every optional field', () {
      final c = TsChannel.fromJson({'id': 3, 'name': 'Lobby', 'parent_id': 0});
      expect(c.topic, '');
      expect(c.hasPassword, isFalse);
      expect(c.clientCount, 0);
      expect(c.order, 0);
      expect(c.isDefault, isFalse);
      expect(c.permissionHints, 0);
      expect(c.neededTalkPower, 0);
      expect(c.maxClients, -1);
      expect(c.isPermanent, isFalse);
      expect(c.isSemiPermanent, isFalse);
      expect(c.description, '');
      expect(c.maxFamilyClients, -1);
      expect(c.deleteDelay, 0);
      expect(c.isTemporary, isTrue);
    });

    test('reads every provided field', () {
      final c = TsChannel.fromJson({
        'id': 3,
        'name': 'Private',
        'parent_id': 1,
        'topic': 't',
        'has_password': true,
        'client_count': 2,
        'order': 7,
        'is_default': true,
        'permission_hints': 5,
        'needed_talk_power': 10,
        'max_clients': 8,
        'is_permanent': true,
        'is_semi_permanent': true,
        'description': 'd',
        'max_family_clients': 0,
        'delete_delay': 30,
      });
      expect(c.topic, 't');
      expect(c.hasPassword, isTrue);
      expect(c.clientCount, 2);
      expect(c.order, 7);
      expect(c.isDefault, isTrue);
      expect(c.permissionHints, 5);
      expect(c.neededTalkPower, 10);
      expect(c.maxClients, 8);
      expect(c.isPermanent, isTrue);
      expect(c.isSemiPermanent, isTrue);
      expect(c.description, 'd');
      expect(c.maxFamilyClients, 0);
      expect(c.deleteDelay, 30);
      expect(c.isTemporary, isFalse);
    });
  });

  test('permission getters decode hint bits', () {
    // join=1, fileUpload=64, fileDownload=128.
    final c = TsChannel(
      id: 1,
      name: 'a',
      parentId: 0,
      permissionHints: 1 | 64 | 128,
    );
    expect(c.canJoin, isTrue);
    expect(c.canFileUpload, isTrue);
    expect(c.canFileDownload, isTrue);
    expect(c.canModify, isFalse);
    expect(c.canDelete, isFalse);
    expect(c.canFileBrowse, isFalse);
    expect(c.canModifyPermissions, isFalse);
  });
}
