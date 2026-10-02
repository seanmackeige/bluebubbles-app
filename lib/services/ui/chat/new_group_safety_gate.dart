enum NewConversationExecutionDisposition {
  oneToOneAllowed,
  existingConversationAllowed,
  newGroupBlockedUnprovenSenderBinding,
}

/// Production gate for the frozen CREATE_CHAT_V2 research boundary.
///
/// This class does not infer capability from macOS/server versions. Until an
/// independently qualified provider proves exact caller-route preservation and
/// fail-without-fallback behavior, only one-to-one creation and sends to an
/// already resolved conversation are admitted.
class NewGroupSafetyGate {
  const NewGroupSafetyGate._();

  static const productionContract = 'NEW_GROUP_SAFETY_GATE_V1_BLOCKED_UNPROVEN_SENDER_BINDING';
  static const blockedTitle = 'Group creation unavailable';
  static const blockedExplanation =
      'Exact sender binding is not available. Select an existing group or continue with one recipient.';

  static NewConversationExecutionDisposition evaluate({
    required int exactRecipientCount,
    required bool existingConversationResolved,
  }) {
    if (exactRecipientCount < 0) {
      throw ArgumentError.value(exactRecipientCount, 'exactRecipientCount', 'must not be negative');
    }
    if (existingConversationResolved) {
      return NewConversationExecutionDisposition.existingConversationAllowed;
    }
    if (exactRecipientCount < 2) {
      return NewConversationExecutionDisposition.oneToOneAllowed;
    }
    return NewConversationExecutionDisposition.newGroupBlockedUnprovenSenderBinding;
  }
}
