import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_message.dart';
import '../models/ts_state.dart';

/// The chat bottom-sheet body: a conversation tab row (channel / server /
/// per-peer private chats), the message list of the selected conversation
/// and the input row routing to the matching send target.
class ChatPanel extends ConsumerStatefulWidget {
  const ChatPanel({super.key});

  @override
  ConsumerState<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends ConsumerState<ChatPanel> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // The conversation the panel opens on is on screen — its messages count
    // as seen right away.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _notifier.markConversationSeen(
        ref.read(tsConnectionProvider.select((s) => s.selectedConversation)),
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  TsConnectionNotifier get _notifier => ref.read(tsConnectionProvider.notifier);

  void _sendMessage() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final conversation = ref.read(
      tsConnectionProvider.select((s) => s.selectedConversation),
    );
    if (conversation.startsWith('pm:')) {
      _notifier.sendPrivateMessage(int.parse(conversation.substring(3)), text);
    } else if (conversation == 'server') {
      _notifier.sendServerMessage(text);
    } else {
      _notifier.sendChannelMessage(text);
    }
    _controller.clear();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _conversationLabel(
    TsConnectionState conn,
    String conversation,
    AppLocalizations al,
  ) {
    if (conversation == 'channel') return al.chatChannel;
    if (conversation == 'server') return al.chatServer;
    if (conversation.startsWith('pm:')) {
      final id = int.parse(conversation.substring(3));
      return conn.conversationTitles[conversation] ??
          conn.clients.where((c) => c.id == id).firstOrNull?.nickname ??
          conversation;
    }
    return conversation;
  }

  IconData _conversationIcon(String conversation) {
    if (conversation == 'channel') return Icons.tag;
    if (conversation == 'server') return Icons.public;
    return Icons.person;
  }

  int _unreadCount(TsConnectionState conn, String conversation) {
    return conn.unreadIds[conversation]?.length ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(tsConnectionProvider);
    final al = AppLocalizations.of(context);
    final conversation = conn.selectedConversation;
    final messages = conn.messages
        .where((m) => m.conversationId == conversation)
        .toList();

    // Auto-scroll when a message arrives in the visible conversation
    ref.listen(
      tsConnectionProvider.select(
        (s) => s.messages
            .where((m) => m.conversationId == s.selectedConversation)
            .length,
      ),
      (_, __) {
        _scrollToBottom();
        // A message in the conversation currently on screen (someone else's,
        // or the echo of our own send) is seen the moment it shows up.
        _notifier.markConversationSeen(
          ref.read(tsConnectionProvider.select((s) => s.selectedConversation)),
        );
      },
    );

    // The server refused one of our messages (e.g. missing server-chat
    // permission) — tell the user instead of letting it vanish silently.
    ref.listen(tsConnectionProvider.select((s) => s.sendFailedError), (
      previous,
      next,
    ) {
      if (next == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            al.messageSendFailed(next),
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: Colors.red.shade800,
          duration: const Duration(seconds: 3),
        ),
      );
      _notifier.clearSendFailure();
    });

    return Column(
      children: [
        _buildConversationTabs(conn, al),
        Expanded(
          child: messages.isEmpty
              ? Center(
                  child: Text(
                    AppLocalizations.of(context).noMessagesYet,
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(8),
                  itemCount: messages.length,
                  itemBuilder: (context, index) =>
                      _buildMessageTile(context, messages[index], conn),
                ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: const Color(0xFF1A1A2E),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: AppLocalizations.of(context).sendMessageHint,
                    hintStyle: const TextStyle(color: Colors.grey),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send, color: Colors.blue, size: 20),
                onPressed: _sendMessage,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildConversationTabs(TsConnectionState conn, AppLocalizations al) {
    final notifier = _notifier;
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF12122A),
        border: Border(bottom: BorderSide(color: Color(0xFF2A2A4A))),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: [
            for (final conversation in conn.openConversations)
              _buildConversationChip(
                conn,
                al,
                conversation,
                selected: conversation == conn.selectedConversation,
                onSelect: () {
                  notifier.selectConversation(conversation);
                  _scrollToBottom();
                },
                onClose: conversation == 'channel'
                    ? null
                    : () => notifier.closeConversation(conversation),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationChip(
    TsConnectionState conn,
    AppLocalizations al,
    String conversation, {
    required bool selected,
    required VoidCallback onSelect,
    VoidCallback? onClose,
  }) {
    final unread = _unreadCount(conn, conversation);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: selected ? const Color(0xFF1E2A4A) : const Color(0xFF1A1A2E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected ? Colors.blue : const Color(0xFF2A2A4A),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: selected ? null : onSelect,
          child: Padding(
            padding: const EdgeInsets.only(left: 10, top: 5, bottom: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _conversationIcon(conversation),
                  size: 13,
                  color: selected ? Colors.blue : Colors.grey,
                ),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(
                    _conversationLabel(conn, conversation, al),
                    style: TextStyle(
                      color: selected ? Colors.white : Colors.grey,
                      fontSize: 12,
                      fontWeight: selected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                if (unread > 0) ...[
                  const SizedBox(width: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blue,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$unread',
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ],
                if (onClose != null)
                  GestureDetector(
                    onTap: onClose,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 5),
                      child: Icon(Icons.close, size: 13, color: Colors.grey),
                    ),
                  )
                else
                  const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMessageTile(
    BuildContext context,
    ChatMessage msg,
    TsConnectionState conn,
  ) {
    final isOwn = msg.fromClientId == conn.ownClientId;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '${msg.fromClient}: ',
              style: TextStyle(
                color: isOwn ? Colors.blue : Colors.tealAccent,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            TextSpan(
              text: msg.message,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
