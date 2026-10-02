import 'package:bluebubbles/database/models.dart';

/// Canonical logical-timeline order: newest provider creation time first,
/// followed by a stable Apple-message identity tie-break. Delivery timestamps
/// never reorder the human history and physical member iteration order cannot
/// affect the result.
int compareLogicalMessagesDescending(Message left, Message right) {
  final leftCreated = left.dateCreated?.millisecondsSinceEpoch ?? 0;
  final rightCreated = right.dateCreated?.millisecondsSinceEpoch ?? 0;
  final byCreated = rightCreated.compareTo(leftCreated);
  if (byCreated != 0) return byCreated;
  final byGuid = (left.guid ?? '').compareTo(right.guid ?? '');
  if (byGuid != 0) return byGuid;
  return (left.originalROWID ?? 0).compareTo(right.originalROWID ?? 0);
}

int compareApplicationMessagesDescending(Message left, Message right, {required bool logical}) {
  if (logical) return compareLogicalMessagesDescending(left, right);
  final byLegacyChronology = Message.sort(left, right);
  if (byLegacyChronology != 0) return byLegacyChronology;
  return (left.guid ?? '').compareTo(right.guid ?? '');
}

int compareApplicationMessagesAscending(Message left, Message right, {required bool logical}) {
  if (logical) return -compareLogicalMessagesDescending(left, right);
  return Message.sort(left, right, descending: false);
}

Message? mostRecentApplicationMessage(Iterable<Message> messages, {required bool logical}) {
  final ordered = messages.toList()
    ..sort((left, right) => compareApplicationMessagesDescending(left, right, logical: logical));
  return ordered.isEmpty ? null : ordered.first;
}
