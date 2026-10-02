/// Resolves a physical incoming typing-event source to its canonical
/// application conversation key. Malformed events fail closed.
String? incomingTypingConversationKey({
  required Object? sourceChatGuid,
  required String Function(String physicalSourceGuid) conversationKeyForGuid,
}) {
  if (sourceChatGuid is! String || sourceChatGuid.isEmpty) return null;
  final conversationKey = conversationKeyForGuid(sourceChatGuid);
  return conversationKey.isEmpty ? null : conversationKey;
}

/// Outbound typing is a provider mutation. A certified, candidate, degraded,
/// or authority-corrupt source has no ordinary physical typing route.
bool canDispatchOutboundTyping({required bool isProtectedLogicalSource}) => !isProtectedLogicalSource;
