/// Fail-closed policy and deterministic projection helpers for the single
/// Sentinel-approved logical conversation.
///
/// This layer does not create synthetic chats or messages. It only selects a
/// presentation chat and merges already-persisted source events by stable GUID.
class LogicalConversationDefinition {
  const LogicalConversationDefinition({
    required this.id,
    required this.sourceChatRowIds,
    required this.presentationSourceChatRowId,
  });

  final String id;
  final Set<int> sourceChatRowIds;
  final int presentationSourceChatRowId;
  bool get outboundExecutionEnabled => false;

  bool containsSourceRowId(int? rowId) => rowId != null && sourceChatRowIds.contains(rowId);
}

class LogicalConversationViewPolicy {
  LogicalConversationViewPolicy._();

  static const goldenPair = LogicalConversationDefinition(
    id: 'LGC_V1_8ef6ba9306f2e2c3c2a28990d01a583e5c270c5ec61a313992c9d40322367c7f',
    sourceChatRowIds: {2155, 2156},
    presentationSourceChatRowId: 2156,
  );

  static bool isApprovedSourceRowId(int? rowId) => goldenPair.containsSourceRowId(rowId);

  /// Returns the only approved definition when every source ROWID is present
  /// exactly once. Missing or duplicate source bindings fail closed.
  static LogicalConversationDefinition? resolve(Iterable<int?> availableSourceRowIds) {
    final counts = <int, int>{};
    for (final rowId in availableSourceRowIds.whereType<int>()) {
      if (goldenPair.sourceChatRowIds.contains(rowId)) {
        counts[rowId] = (counts[rowId] ?? 0) + 1;
      }
    }

    final exact = goldenPair.sourceChatRowIds.every((rowId) => counts[rowId] == 1);
    return exact ? goldenPair : null;
  }

  static bool logicalUnread(Iterable<bool> sourceUnreadStates) => sourceUnreadStates.any((value) => value);

  static List<T> projectConversationList<T>(Iterable<T> items, int? Function(T item) sourceRowIdOf) {
    final snapshot = List<T>.from(items);
    final definition = resolve(snapshot.map(sourceRowIdOf));
    if (definition == null) return snapshot;
    return snapshot
        .where(
          (item) =>
              !definition.containsSourceRowId(sourceRowIdOf(item)) ||
              sourceRowIdOf(item) == definition.presentationSourceChatRowId,
        )
        .toList();
  }

  static int presentationSourceRowIdFor(int requestedSourceRowId, Iterable<int?> availableSourceRowIds) {
    final definition = resolve(availableSourceRowIds);
    if (definition == null || !definition.containsSourceRowId(requestedSourceRowId)) return requestedSourceRowId;
    return definition.presentationSourceChatRowId;
  }

  /// Produces a globally ordered page and suppresses exact-GUID duplicates.
  /// A GUID with conflicting provenance fails closed instead of choosing a
  /// source silently. Distinct GUIDs remain distinct regardless of payload.
  static List<LogicalConversationEvent<T>> mergePage<T>(
    Iterable<LogicalConversationEvent<T>> sourceEvents, {
    int offset = 0,
    int? limit,
  }) {
    if (offset < 0 || (limit != null && limit < 0)) {
      throw ArgumentError('offset and limit must be non-negative');
    }

    final byGuid = <String, LogicalConversationEvent<T>>{};
    for (final event in sourceEvents) {
      final existing = byGuid[event.guid];
      if (existing == null) {
        byGuid[event.guid] = event;
        continue;
      }
      if (existing.sourceChatRowId != event.sourceChatRowId ||
          existing.timestamp != event.timestamp ||
          existing.provenanceFingerprint != event.provenanceFingerprint) {
        throw StateError('Ambiguous logical event GUID: ${event.guid}');
      }
    }

    final ordered = byGuid.values.toList()
      ..sort((a, b) {
        final byTime = b.timestamp.compareTo(a.timestamp);
        return byTime != 0 ? byTime : a.guid.compareTo(b.guid);
      });

    if (offset >= ordered.length) return <LogicalConversationEvent<T>>[];
    final end = limit == null ? ordered.length : (offset + limit).clamp(0, ordered.length);
    return ordered.sublist(offset, end);
  }
}

class LogicalConversationEvent<T> {
  const LogicalConversationEvent({
    required this.guid,
    required this.sourceChatRowId,
    required this.timestamp,
    required this.provenanceFingerprint,
    required this.value,
  });

  final String guid;
  final int sourceChatRowId;
  final DateTime timestamp;
  final String provenanceFingerprint;
  final T value;
}
