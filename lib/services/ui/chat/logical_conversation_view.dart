const logicalConversationReadCertificateSchema = 'LOGICAL_CONVERSATION_READ_CERTIFICATE_V2_N_MEMBER';

/// Evidence classes retained with each physical member's independent read
/// admission. Display name and transitive equivalence are deliberately absent.
enum LogicalConversationMemberEvidenceKind {
  appleBlueBubblesGuidParity,
  exactNormalizedExternalParticipants,
  completePairwiseDifferential,
  structuredCrossChatRelationship,
  selfAliasDifferential,
  sharedGroupIdentity,
  sharedGroupMetadataEvent,
  passiveNaturalProduction,
}

enum LogicalConversationCandidateClassification { historicalInertRelatedIdentity }

class LogicalConversationMemberProof {
  const LogicalConversationMemberProof({
    required this.sourceChatRowId,
    required this.sourceChatGuidHmacSha256,
    required this.admissionReceiptCommit,
    required this.evidence,
    required this.pairwiseComparedSourceRowIds,
    required this.directRelationshipPeerRowIds,
    required this.minimumStructuredRelationshipCount,
    required this.explanation,
  });

  final int sourceChatRowId;
  final String sourceChatGuidHmacSha256;
  final String admissionReceiptCommit;
  final Set<LogicalConversationMemberEvidenceKind> evidence;
  final Set<int> pairwiseComparedSourceRowIds;
  final Set<int> directRelationshipPeerRowIds;
  final int minimumStructuredRelationshipCount;
  final String explanation;

  bool get hasIndependentAdmissionProof =>
      sourceChatRowId > 0 &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceChatGuidHmacSha256) &&
      RegExp(r'^[0-9a-f]{40}$').hasMatch(admissionReceiptCommit) &&
      evidence.contains(LogicalConversationMemberEvidenceKind.appleBlueBubblesGuidParity) &&
      evidence.contains(LogicalConversationMemberEvidenceKind.exactNormalizedExternalParticipants) &&
      evidence.contains(LogicalConversationMemberEvidenceKind.completePairwiseDifferential) &&
      evidence.contains(LogicalConversationMemberEvidenceKind.structuredCrossChatRelationship) &&
      evidence.contains(LogicalConversationMemberEvidenceKind.passiveNaturalProduction) &&
      directRelationshipPeerRowIds.isNotEmpty &&
      minimumStructuredRelationshipCount > 0 &&
      explanation.isNotEmpty;
}

class LogicalConversationExcludedCandidateProof {
  const LogicalConversationExcludedCandidateProof({
    required this.sourceChatRowId,
    required this.sourceChatGuidHmacSha256,
    required this.classification,
    required this.admissionReceiptCommit,
    required this.evidence,
    required this.explanation,
  });

  final int sourceChatRowId;
  final String sourceChatGuidHmacSha256;
  final LogicalConversationCandidateClassification classification;
  final String admissionReceiptCommit;
  final Set<String> evidence;
  final String explanation;
}

/// Explicit read/presentation certificate. Member proofs authorize only the
/// logical projection. They never identify or authorize an execution route.
class LogicalConversationReadCertificate {
  const LogicalConversationReadCertificate({
    required this.schema,
    required this.id,
    required this.members,
    required this.presentationSourceChatRowId,
  });

  final String schema;
  final String id;
  final List<LogicalConversationMemberProof> members;
  final int presentationSourceChatRowId;

  Set<int> get sourceChatRowIds => members.map((member) => member.sourceChatRowId).toSet();

  bool containsSourceRowId(int? rowId) => rowId != null && sourceChatRowIds.contains(rowId);

  LogicalConversationMemberProof? proofFor(int? rowId) {
    if (rowId == null) return null;
    for (final member in members) {
      if (member.sourceChatRowId == rowId) return member;
    }
    return null;
  }

  bool get isValid {
    if (schema != logicalConversationReadCertificateSchema || id.isEmpty || members.length < 2 || members.length > 8) {
      return false;
    }
    final rows = sourceChatRowIds;
    if (rows.length != members.length || !rows.contains(presentationSourceChatRowId)) {
      return false;
    }
    for (final member in members) {
      if (!member.hasIndependentAdmissionProof) return false;
      final expectedPeers = rows.difference({member.sourceChatRowId});
      if (!member.pairwiseComparedSourceRowIds.containsAll(expectedPeers)) {
        return false;
      }
    }
    return true;
  }

  /// Used by certificate tests and future evidence review. Removing a proof
  /// does not rewrite another member into or out of the certificate.
  LogicalConversationReadCertificate withoutMemberProof(int sourceChatRowId) {
    final retained = members.where((member) => member.sourceChatRowId != sourceChatRowId).toList(growable: false);
    final retainedRows = retained.map((member) => member.sourceChatRowId).toList(growable: false)..sort();
    return LogicalConversationReadCertificate(
      schema: schema,
      id: id,
      members: retained,
      presentationSourceChatRowId: retainedRows.contains(presentationSourceChatRowId)
          ? presentationSourceChatRowId
          : retainedRows.firstOrNull ?? presentationSourceChatRowId,
    );
  }
}

/// Fail-closed deterministic projection helpers for explicitly certified
/// physical identities. Raw chats/messages remain the persisted authority.
class LogicalConversationViewPolicy {
  LogicalConversationViewPolicy._();

  static const _receipt = '3432adfd6c7daa67d8d7521207a8d433b3339763';

  static const comcastNodeUpdates = LogicalConversationReadCertificate(
    schema: logicalConversationReadCertificateSchema,
    id: 'LGC_V2_377f996e2dfd452ac69370dadda3aaf185c6714a0bda48af92faf8f55282424a',
    presentationSourceChatRowId: 2156,
    members: [
      LogicalConversationMemberProof(
        sourceChatRowId: 2027,
        sourceChatGuidHmacSha256: 'c792167d4f9f6012663b1db0d56169beba631d5c5bf37799bf5e9c2419e86800',
        admissionReceiptCommit: _receipt,
        evidence: {
          LogicalConversationMemberEvidenceKind.appleBlueBubblesGuidParity,
          LogicalConversationMemberEvidenceKind.exactNormalizedExternalParticipants,
          LogicalConversationMemberEvidenceKind.completePairwiseDifferential,
          LogicalConversationMemberEvidenceKind.structuredCrossChatRelationship,
          LogicalConversationMemberEvidenceKind.selfAliasDifferential,
          LogicalConversationMemberEvidenceKind.sharedGroupIdentity,
          LogicalConversationMemberEvidenceKind.sharedGroupMetadataEvent,
          LogicalConversationMemberEvidenceKind.passiveNaturalProduction,
        },
        pairwiseComparedSourceRowIds: {2155, 2156},
        directRelationshipPeerRowIds: {2156},
        minimumStructuredRelationshipCount: 2,
        explanation:
            'GUID parity, exact external membership, complete pairwise differentials, two direct 2156 reactions, '
            'shared group identity, and a shared current group-photo event prove independent read membership.',
      ),
      LogicalConversationMemberProof(
        sourceChatRowId: 2155,
        sourceChatGuidHmacSha256: 'f9142189fe14c1e4f15a1da5077bbfc794936e5c60bad31e90eae23d59d3ef10',
        admissionReceiptCommit: _receipt,
        evidence: {
          LogicalConversationMemberEvidenceKind.appleBlueBubblesGuidParity,
          LogicalConversationMemberEvidenceKind.exactNormalizedExternalParticipants,
          LogicalConversationMemberEvidenceKind.completePairwiseDifferential,
          LogicalConversationMemberEvidenceKind.structuredCrossChatRelationship,
          LogicalConversationMemberEvidenceKind.selfAliasDifferential,
          LogicalConversationMemberEvidenceKind.passiveNaturalProduction,
        },
        pairwiseComparedSourceRowIds: {2027, 2156},
        directRelationshipPeerRowIds: {2156},
        minimumStructuredRelationshipCount: 11,
        explanation:
            'GUID parity, exact external membership with only the active self alias added, complete pairwise '
            'differentials, and direct 2156 reaction relationships prove independent read membership.',
      ),
      LogicalConversationMemberProof(
        sourceChatRowId: 2156,
        sourceChatGuidHmacSha256: '4b2902861414cb6b0408d92be5d8d977a89f8547e88a1521529d4bffb96b486b',
        admissionReceiptCommit: _receipt,
        evidence: {
          LogicalConversationMemberEvidenceKind.appleBlueBubblesGuidParity,
          LogicalConversationMemberEvidenceKind.exactNormalizedExternalParticipants,
          LogicalConversationMemberEvidenceKind.completePairwiseDifferential,
          LogicalConversationMemberEvidenceKind.structuredCrossChatRelationship,
          LogicalConversationMemberEvidenceKind.selfAliasDifferential,
          LogicalConversationMemberEvidenceKind.sharedGroupIdentity,
          LogicalConversationMemberEvidenceKind.sharedGroupMetadataEvent,
          LogicalConversationMemberEvidenceKind.passiveNaturalProduction,
        },
        pairwiseComparedSourceRowIds: {2027, 2155},
        directRelationshipPeerRowIds: {2027, 2155},
        minimumStructuredRelationshipCount: 13,
        explanation:
            'GUID parity, exact external membership, complete pairwise differentials, direct reactions to both '
            'other members, and shared group metadata prove independent read membership.',
      ),
    ],
  );

  static const fourthCandidate = LogicalConversationExcludedCandidateProof(
    sourceChatRowId: 1674,
    sourceChatGuidHmacSha256: 'e0c906040606a28f6bd9c95abc257d31917977ff4962a451e04169cbe47859f4',
    classification: LogicalConversationCandidateClassification.historicalInertRelatedIdentity,
    admissionReceiptCommit: _receipt,
    evidence: {
      'TWO_CURRENT_AND_TWO_HISTORICAL_EXTERNAL_PARTICIPANT_DIFFERENCES',
      'PARTICIPANT_REMOVAL_EVENTS_PRECEDE_CURRENT_SET',
      'NO_ACTIVITY_AFTER_2026_04_30',
      'NO_STRUCTURED_RELATIONSHIP_TO_CURRENT_CERTIFIED_SET',
      'DISPLAY_NAME_NOT_ADMISSION_EVIDENCE',
    },
    explanation:
        'The older prior-participant-set lineage ended April 30 and has no structured edge to the current set; '
        'it remains historical/inert and is not enrolled.',
  );

  static bool isApprovedSourceRowId(int? rowId) => comcastNodeUpdates.containsSourceRowId(rowId);

  static LogicalConversationMemberProof? membershipProofFor(int? rowId) => comcastNodeUpdates.proofFor(rowId);

  static LogicalConversationExcludedCandidateProof? excludedCandidateProofFor(int? rowId) =>
      rowId == fourthCandidate.sourceChatRowId ? fourthCandidate : null;

  /// Returns the approved certificate only when every certified source ROWID
  /// is present exactly once. Extra ordinary chats never gain membership.
  static LogicalConversationReadCertificate? resolve(Iterable<int?> availableSourceRowIds) =>
      resolveCertificate(comcastNodeUpdates, availableSourceRowIds);

  static LogicalConversationReadCertificate? resolveCertificate(
    LogicalConversationReadCertificate certificate,
    Iterable<int?> availableSourceRowIds,
  ) {
    if (!certificate.isValid) return null;
    final counts = <int, int>{};
    for (final rowId in availableSourceRowIds.whereType<int>()) {
      if (certificate.containsSourceRowId(rowId)) {
        counts[rowId] = (counts[rowId] ?? 0) + 1;
      }
    }
    return certificate.sourceChatRowIds.every((rowId) => counts[rowId] == 1) ? certificate : null;
  }

  static bool logicalUnread(Iterable<bool> sourceUnreadStates) => sourceUnreadStates.any((value) => value);

  static List<T> projectConversationList<T>(Iterable<T> items, int? Function(T item) sourceRowIdOf) {
    return projectConversationListForCertificate(comcastNodeUpdates, items, sourceRowIdOf);
  }

  static List<T> projectConversationListForCertificate<T>(
    LogicalConversationReadCertificate certificate,
    Iterable<T> items,
    int? Function(T item) sourceRowIdOf,
  ) {
    final snapshot = List<T>.from(items);
    final resolved = resolveCertificate(certificate, snapshot.map(sourceRowIdOf));
    if (resolved == null) return snapshot;
    return snapshot
        .where(
          (item) =>
              !resolved.containsSourceRowId(sourceRowIdOf(item)) ||
              sourceRowIdOf(item) == resolved.presentationSourceChatRowId,
        )
        .toList();
  }

  static int presentationSourceRowIdFor(int requestedSourceRowId, Iterable<int?> availableSourceRowIds) {
    final certificate = resolve(availableSourceRowIds);
    if (certificate == null || !certificate.containsSourceRowId(requestedSourceRowId)) {
      return requestedSourceRowId;
    }
    return certificate.presentationSourceChatRowId;
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
