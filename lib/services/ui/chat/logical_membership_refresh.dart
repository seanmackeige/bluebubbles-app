@pragma('vm:entry-point')
const logicalMembershipRefreshContract = 'LOGICAL_MEMBERSHIP_REFRESH_V1_EXACT_IDENTITY';
const logicalMembershipAdvancedEvent = 'logical-membership-advanced';

String? logicalMembershipIdFromEvent(Object? data) {
  if (data is! Map) return null;
  final logicalId = data['logicalId'];
  return logicalId is String && logicalId.isNotEmpty ? logicalId : null;
}

bool shouldRefreshLogicalMembershipProjection({required Object? eventData, required String? currentLogicalId}) {
  if (currentLogicalId == null || currentLogicalId.isEmpty) return false;
  return logicalMembershipIdFromEvent(eventData) == currentLogicalId;
}

/// Detects read-only runtime binding changes beneath stable V2 certificate
/// identities. The caller supplies privacy-safe canonical fingerprints; this
/// tracker owns no provider coordinates and grants no write authority.
class LogicalMembershipAvailabilityTracker {
  Map<String, String> _snapshot = <String, String>{};

  Set<String> observe(Map<String, String> next, {required bool reportChanges}) {
    if (next.keys.any((logicalId) => logicalId.isEmpty) || next.values.any((fingerprint) => fingerprint.isEmpty)) {
      throw ArgumentError('Logical membership availability snapshot is malformed');
    }
    final changed = <String>{};
    if (reportChanges) {
      for (final logicalId in <String>{..._snapshot.keys, ...next.keys}) {
        final before = _snapshot[logicalId];
        final after = next[logicalId];
        if (before != null && after != null && before != after) changed.add(logicalId);
      }
    }
    _snapshot = Map<String, String>.unmodifiable(Map<String, String>.from(next));
    return Set<String>.unmodifiable(changed);
  }

  void clear() {
    _snapshot = <String, String>{};
  }
}
