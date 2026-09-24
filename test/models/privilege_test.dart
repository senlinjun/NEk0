import 'package:flutter_test/flutter_test.dart';

import 'package:NEk0/models/privilege.dart';

void main() {
  test('empty input is tier none', () {
    expect(privilegeTierOf(const []), PrivilegeTier.none);
  });

  test('unprivileged group names stay none', () {
    expect(privilegeTierOf(['Guest', 'Friends']), PrivilegeTier.none);
  });

  test('moderator keywords map to the moderator tier', () {
    for (final name in [
      'Operator',
      'Moderator',
      'supervisor',
      'Staff',
      'controller',
      'Guard',
    ]) {
      expect(privilegeTierOf([name]), PrivilegeTier.moderator, reason: name);
    }
  });

  test('admin keywords map to the admin tier', () {
    for (final name in [
      'Admin',
      'Server Admin',
      'root',
      'Owner',
      'administrator',
    ]) {
      expect(privilegeTierOf([name]), PrivilegeTier.admin, reason: name);
    }
  });

  test('matching is case-insensitive and substring based', () {
    expect(privilegeTierOf(['Co-AdminTeam']), PrivilegeTier.admin);
    expect(privilegeTierOf(['MODERATORS']), PrivilegeTier.moderator);
  });

  test('admin outranks moderator regardless of order', () {
    expect(privilegeTierOf(['Moderator', 'Admin']), PrivilegeTier.admin);
    expect(privilegeTierOf(['Admin', 'Moderator']), PrivilegeTier.admin);
  });
}
