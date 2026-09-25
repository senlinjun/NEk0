import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:NEk0/models/notification_settings.dart';
import 'package:NEk0/models/ts_state.dart';
import 'package:NEk0/services/foreground_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The notifier's build() only wires Android-only notification callbacks
  // (no-ops on the desktop test host); every method used below is pure state
  // manipulation — none of them may reach TsNative.
  late ProviderContainer container;
  setUp(() {
    // The chat-notice/poke handlers read the locale and notification-setting
    // providers, which lazily load from SharedPreferences.
    SharedPreferences.setMockInitialValues({});
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

  group('system chat messages', () {
    test('client_enter_channel appends a system line to the channel tab', () {
      notifier().handleEventForTest({
        'type': 'client_enter_channel',
        'client_id': 5,
        'nickname': 'Alice',
        'reason': 0,
      });
      final messages = state().messages;
      expect(messages, hasLength(1));
      final msg = messages.single;
      expect(msg.isSystem, isTrue);
      expect(msg.conversationId, 'channel');
      expect(msg.fromClientId, 0);
      expect(msg.fromClient, '');
      expect(msg.message, contains('Alice'));
    });

    test('a kicked leave line names the invoker', () {
      notifier().handleEventForTest({
        'type': 'client_leave_channel',
        'client_id': 5,
        'nickname': 'Alice',
        'kind': 2,
        'invoker': 'Admin',
      });
      final message = state().messages.single.message;
      expect(message, contains('Alice'));
      expect(message, contains('Admin'));
    });

    test('a self-move line names the target channel', () {
      notifier().handleEventForTest({
        'type': 'self_moved',
        'to_channel_id': 4,
        'to_channel_name': 'Lobby',
        'invoker': '',
        'kind': 0,
      });
      expect(state().messages.single.message, contains('Lobby'));
    });

    test('system lines count as unread on the channel tab', () {
      notifier().handleEventForTest({
        'type': 'client_enter_channel',
        'client_id': 5,
        'nickname': 'Alice',
        'reason': 0,
      });
      expect(notifier().unreadCount(), 1);
      expect(state().openConversations, ['channel']);
    });

    test('ids stay unique across interleaved system and text messages', () {
      notifier().handleEventForTest({
        'type': 'client_enter_channel',
        'client_id': 5,
        'nickname': 'Alice',
        'reason': 0,
      });
      notifier().handleEventForTest({
        'type': 'text_message',
        'from_client': 'Alice',
        'from_client_id': 5,
        'to_client_id': 0,
        'target_mode': 2,
        'message': 'hi',
      });
      notifier().handleEventForTest({
        'type': 'client_enter_channel',
        'client_id': 6,
        'nickname': 'Bob',
        'reason': 0,
      });
      final ids = state().messages.map((m) => m.id).toList();
      expect(ids, hasLength(3));
      expect(ids.toSet().length, 3);
    });

    test('poke records a system line and sets pokeInfo', () {
      notifier().handleEventForTest({
        'type': 'poke',
        'from_client': 'Alice',
        'from_client_id': 5,
        'message': 'boo',
      });
      expect(state().pokeInfo?.from, 'Alice');
      expect(state().pokeInfo?.fromClientId, 5);
      expect(state().pokeInfo?.message, 'boo');
      final msg = state().messages.single;
      expect(msg.isSystem, isTrue);
      expect(msg.conversationId, 'channel');
      expect(msg.message, contains('Alice'));
      // The poke line is system-generated — never from "us".
      expect(msg.fromClientId, 0);
      notifier().clearPokeInfo();
      expect(state().pokeInfo, isNull);
    });
  });

  group('chat-message toasts', () {
    final notifies = <(String, String)>[];

    setUp(() {
      ForegroundService.notifyOverride = (title, body) async {
        notifies.add((title, body));
      };
    });
    tearDown(() {
      ForegroundService.notifyOverride = null;
      notifies.clear();
    });

    test('a private message toasts by default (panel closed)', () {
      notifier().handleEventForTest({
        'type': 'text_message',
        'from_client': 'Alice',
        'from_client_id': 5,
        'to_client_id': 0,
        'target_mode': 1,
        'message': 'hi there',
      });
      expect(notifies, hasLength(1));
      expect(notifies.single.$1, 'Alice');
      expect(notifies.single.$2, 'hi there');
    });

    test('a channel message does not toast while its setting is off', () {
      notifier().handleEventForTest({
        'type': 'text_message',
        'from_client': 'Alice',
        'from_client_id': 5,
        'to_client_id': 0,
        'target_mode': 2,
        'message': 'hello channel',
      });
      expect(notifies, isEmpty);
    });

    test('a channel message toasts once its setting is on', () async {
      await container
          .read(notificationSettingsProvider.notifier)
          .setChannelMessages(true);
      notifier().handleEventForTest({
        'type': 'text_message',
        'from_client': 'Alice',
        'from_client_id': 5,
        'to_client_id': 0,
        'target_mode': 2,
        'message': 'hello channel',
      });
      expect(notifies, hasLength(1));
      expect(notifies.single.$1, 'Alice');
    });

    test('nothing toasts while the chat panel is open', () async {
      notifier().setChatOpen(true);
      expect(state().chatOpen, isTrue);
      notifier().handleEventForTest({
        'type': 'text_message',
        'from_client': 'Alice',
        'from_client_id': 5,
        'to_client_id': 0,
        'target_mode': 1,
        'message': 'hi',
      });
      expect(notifies, isEmpty);
      // Closing the panel re-enables toasts.
      notifier().setChatOpen(false);
      notifier().handleEventForTest({
        'type': 'text_message',
        'from_client': 'Alice',
        'from_client_id': 5,
        'to_client_id': 0,
        'target_mode': 1,
        'message': 'hi again',
      });
      expect(notifies, hasLength(1));
    });

    test('the echo of our own message never toasts', () {
      // ownClientId defaults to 0 in the bare state — the echo arrives
      // attributed to us.
      notifier().handleEventForTest({
        'type': 'text_message',
        'from_client': 'me',
        'from_client_id': 0,
        'to_client_id': 5,
        'target_mode': 1,
        'message': 'sent by me',
      });
      expect(notifies, isEmpty);
    });
  });

  group('systemMessageText', () {
    test('connected prefers the welcome message', () {
      final text = systemMessageText('connected', {
        'welcome_message': 'Welcome!',
        'hostmessage': 'Host',
        'hostmessage_mode': 1,
      }, null);
      expect(text, 'Welcome!');
    });

    test('the host message only shows when the server asks for it', () {
      final event = {'welcome_message': '', 'hostmessage': 'Host'};
      expect(
        systemMessageText('connected', {...event, 'hostmessage_mode': 0}, null),
        isNull,
      );
      expect(
        systemMessageText('connected', {...event, 'hostmessage_mode': 2}, null),
        'Host',
      );
    });
  });
}
