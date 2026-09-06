/// One chat message. [conversationId] groups messages into conversations:
/// `channel` (current-channel chat), `server` (server-wide chat) and
/// `pm:<clid>` (private conversation with the client whose id is clid —
/// our own client id for PMs we received, the peer's id for echoes of PMs
/// we sent).
class ChatMessage {
  final int id;
  final String fromClient;
  final int fromClientId;
  final int targetMode; // 1=private, 2=channel, 3=server
  final String conversationId;
  final String message;
  final DateTime timestamp;

  const ChatMessage({
    required this.id,
    required this.fromClient,
    required this.fromClientId,
    required this.targetMode,
    required this.conversationId,
    required this.message,
    required this.timestamp,
  });
}
