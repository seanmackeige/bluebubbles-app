/// Fail-closed contract for a notification action or tap that was admitted
/// against one conversation identity and one exact physical source.
///
/// The caller supplies current runtime facts after database/certificate
/// hydration. A formerly-logical notification cannot degrade into an ordinary
/// physical action when its certificate is missing or revoked.
class LogicalNotificationRoutePolicy {
  const LogicalNotificationRoutePolicy._();

  static bool admits({
    required String admittedConversationKey,
    required String admittedSourceChatGuid,
    required String currentSourceChatGuid,
    required String currentConversationKey,
    required bool currentSourceIsCertified,
    required bool presentationResolvesToConversationKey,
  }) {
    if (admittedConversationKey.isEmpty ||
        admittedConversationKey.length > 4096 ||
        admittedSourceChatGuid.isEmpty ||
        admittedSourceChatGuid.length > 4096) {
      return false;
    }
    if (admittedSourceChatGuid != currentSourceChatGuid ||
        admittedConversationKey != currentConversationKey ||
        !presentationResolvesToConversationKey) {
      return false;
    }

    final admittedAsLogical = admittedConversationKey != admittedSourceChatGuid;
    return admittedAsLogical == currentSourceIsCertified;
  }
}
