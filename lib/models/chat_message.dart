class ChatMessage {
  final int id;
  final String fromClient;
  final int fromClientId;
  final int targetMode; // 1=private, 2=channel, 3=server
  final String message;
  final DateTime timestamp;

  const ChatMessage({
    required this.id,
    required this.fromClient,
    required this.fromClientId,
    required this.targetMode,
    required this.message,
    required this.timestamp,
  });
}
