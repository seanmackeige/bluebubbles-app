/// Selects the exact physical attachment queue whose canonical application
/// conversation is active.
///
/// The returned value is deliberately the original physical source GUID. The
/// canonical key is comparison-only and must never replace attachment/message
/// provenance.
String? selectActiveAttachmentSourceGuid({
  required Iterable<String> physicalSourceGuids,
  required String? activeConversationKey,
  required String Function(String physicalSourceGuid) conversationKeyForGuid,
}) {
  if (activeConversationKey == null || activeConversationKey.isEmpty) return null;
  for (final physicalSourceGuid in physicalSourceGuids) {
    if (conversationKeyForGuid(physicalSourceGuid) == activeConversationKey) {
      return physicalSourceGuid;
    }
  }
  return null;
}
