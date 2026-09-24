import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:NEk0/models/ts_state.dart';

void main() {
  // The notifier's build() only wires Android-only notification callbacks
  // (no-ops on the desktop test host); every method used below is pure state
  // manipulation — none of them may reach TsNative.
  late ProviderContainer container;
  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  TsConnectionNotifier notifier() =>
      container.read(tsConnectionProvider.notifier);
  TsConnectionState state() => container.read(tsConnectionProvider);

  group('conversation tabs', () {
    test('the channel tab exists from the start and is selected', () {
      expect(state().openConversations, ['channel']);
      expect(state().selectedConversation, 'channel');
      expect(notifier().unreadCount(), 0);
    });

    test('openConversation adds a tab without stealing focus', () {
      notifier().openConversation('server');
      expect(state().openConversations, ['channel', 'server']);
      expect(state().selectedConversation, 'channel');
    });

    test('opening the same tab twice does not duplicate it', () {
      notifier().openConversation('server');
      notifier().openConversation('server');
      expect(state().openConversations, ['channel', 'server']);
    });

    test('select=true focuses the tab', () {
      notifier().openConversation('pm:7', title: 'Alice', select: true);
      expect(state().selectedConversation, 'pm:7');
      expect(state().conversationTitles['pm:7'], 'Alice');
    });

    test('reopening a conversation updates its title', () {
      notifier().openConversation('pm:7', title: 'Alice');
      notifier().openConversation('pm:7', title: 'Alice II');
      expect(state().conversationTitles['pm:7'], 'Alice II');
    });

    test('channel and server tabs are never titled', () {
      notifier().openConversation('server', title: 'ignored');
      expect(state().conversationTitles.containsKey('server'), isFalse);
    });

    test('openPrivateChat titles from the roster nickname', () {
      // Empty roster: the tab opens without a title.
      notifier().openPrivateChat(9);
      expect(state().openConversations.contains('pm:9'), isTrue);
      expect(state().conversationTitles.containsKey('pm:9'), isFalse);
    });

    test('the channel tab cannot be closed', () {
      notifier().closeConversation('channel');
      expect(state().openConversations.contains('channel'), isTrue);
    });

    test('closing the selected tab falls back to the channel tab', () {
      notifier().openConversation('pm:7', select: true);
      notifier().closeConversation('pm:7');
      expect(state().openConversations.contains('pm:7'), isFalse);
      expect(state().selectedConversation, 'channel');
    });

    test('closing an unselected tab keeps the current selection', () {
      notifier().openConversation('pm:7');
      notifier().openConversation('pm:8', select: true);
      notifier().closeConversation('pm:7');
      expect(state().selectedConversation, 'pm:8');
    });

    test('selecting an unopened tab is a no-op', () {
      notifier().selectConversation('pm:1');
      expect(state().selectedConversation, 'channel');
    });
  });

  group('unread tracking', () {
    test('the mark APIs are no-ops on empty unread state', () {
      notifier().openConversation('pm:5');
      notifier().markConversationSeen('pm:5');
      notifier().markAllConversationsSeen();
      expect(notifier().unreadCount(), 0);
      // markAll must not touch the selection either.
      expect(state().selectedConversation, 'channel');
    });
  });
}
