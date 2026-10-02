import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_certificate_ledger.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:crypto/crypto.dart';

const logicalConversationReadCertificateSchema = 'LOGICAL_CONVERSATION_READ_CERTIFICATE_V2_N_MEMBER';
const incrementalLogicalProjectionSchema = 'INCREMENTAL_LOGICAL_PROJECTION_V1';
const logicalConversationLegacyRuntimeCertificateSchema = 'LOGICAL_CONVERSATION_RUNTIME_CERTIFICATE_V1';
const logicalConversationRuntimeCertificateSchema = 'LOGICAL_CONVERSATION_RUNTIME_CERTIFICATE_V2_GUID_BINDING';

enum LogicalProjectionEventClass {
  normalMessage,
  historicalMemberMessage,
  reaction,
  crossChatReaction,
  reply,
  attachment,
  readState,
  groupMetadata,
  newPhysicalCandidate,
  newlyAdmittedMember,
  executionGeneration,
  delayedEvent,
  duplicateEvent,
  outOfOrderEvent,
}

enum LogicalProjectionDeltaKind { inserted, updated, unchanged, removed, fullRebuildRequired }

class LogicalProjectionDelta {
  const LogicalProjectionDelta(this.kind, {this.oldIndex, this.newIndex, this.reason});

  final LogicalProjectionDeltaKind kind;
  final int? oldIndex;
  final int? newIndex;
  final String? reason;
}

class LogicalProjectionCacheIdentity {
  const LogicalProjectionCacheIdentity({
    required this.logicalId,
    required this.certificateRevision,
    required this.memberBindingDigest,
    required this.authorityRevision,
    required this.sourceWatermarks,
    required this.eventWatermark,
  });

  final String logicalId;
  final String certificateRevision;
  final String memberBindingDigest;
  final String authorityRevision;
  final Map<String, String> sourceWatermarks;
  final int eventWatermark;

  bool isCompatibleWith(LogicalProjectionCacheIdentity other) {
    return logicalId == other.logicalId &&
        certificateRevision == other.certificateRevision &&
        memberBindingDigest == other.memberBindingDigest;
  }
}

/// Reconstructible ordered event index. Source models remain authoritative;
/// this type only owns a disposable presentation window.
class IncrementalLogicalProjection<T> {
  IncrementalLogicalProjection({
    required this.identityOf,
    required this.provenanceOf,
    required this.compare,
    this.equivalent,
  });

  final String Function(T event) identityOf;
  final String Function(T event) provenanceOf;
  final int Function(T left, T right) compare;
  final bool Function(T left, T right)? equivalent;

  final Map<String, T> _byId = <String, T>{};
  final List<T> _ordered = <T>[];

  List<T> get values => List<T>.unmodifiable(_ordered);

  void rebuild(Iterable<T> sourceTruth) {
    _byId.clear();
    _ordered.clear();
    for (final event in sourceTruth) {
      final id = identityOf(event);
      final existing = _byId[id];
      if (existing != null && provenanceOf(existing) != provenanceOf(event)) {
        throw StateError('LOGICAL_EVENT_PROVENANCE_CONFLICT:$id');
      }
      _byId[id] = event;
    }
    _ordered.addAll(_byId.values);
    _ordered.sort(_compareCanonical);
  }

  LogicalProjectionDelta upsert(
    T event, {
    LogicalProjectionEventClass eventClass = LogicalProjectionEventClass.normalMessage,
  }) {
    if (eventClass == LogicalProjectionEventClass.newlyAdmittedMember ||
        eventClass == LogicalProjectionEventClass.executionGeneration) {
      return LogicalProjectionDelta(LogicalProjectionDeltaKind.fullRebuildRequired, reason: eventClass.name);
    }
    final id = identityOf(event);
    final existing = _byId[id];
    if (existing != null && provenanceOf(existing) != provenanceOf(event)) {
      throw StateError('LOGICAL_EVENT_PROVENANCE_CONFLICT:$id');
    }
    if (existing != null && (equivalent?.call(existing, event) ?? identical(existing, event))) {
      return LogicalProjectionDelta(
        LogicalProjectionDeltaKind.unchanged,
        oldIndex: _ordered.indexWhere((item) => identityOf(item) == id),
      );
    }

    int? oldIndex;
    if (existing != null) {
      oldIndex = _ordered.indexWhere((item) => identityOf(item) == id);
      if (oldIndex >= 0) _ordered.removeAt(oldIndex);
    }
    _byId[id] = event;
    final newIndex = insertionIndex(_ordered, event, _compareCanonical);
    _ordered.insert(newIndex, event);
    return LogicalProjectionDelta(
      existing == null ? LogicalProjectionDeltaKind.inserted : LogicalProjectionDeltaKind.updated,
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
  }

  LogicalProjectionDelta remove(String id) {
    if (_byId.remove(id) == null) {
      return const LogicalProjectionDelta(LogicalProjectionDeltaKind.unchanged);
    }
    final oldIndex = _ordered.indexWhere((item) => identityOf(item) == id);
    if (oldIndex >= 0) _ordered.removeAt(oldIndex);
    return LogicalProjectionDelta(LogicalProjectionDeltaKind.removed, oldIndex: oldIndex);
  }

  int _compareCanonical(T left, T right) {
    final byValue = compare(left, right);
    return byValue != 0 ? byValue : identityOf(left).compareTo(identityOf(right));
  }

  static int insertionIndex<T>(List<T> ordered, T value, int Function(T left, T right) compare) {
    var low = 0;
    var high = ordered.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (compare(ordered[middle], value) <= 0) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }
}

/// Evidence classes retained with each physical member's independent read
/// admission. Display name and transitive equivalence are deliberately absent.
enum LogicalConversationMemberEvidenceKind {
  appleBlueBubblesGuidParity,
  exactNormalizedExternalParticipants,
  completePairwiseDifferential,
  structuredCrossChatRelationship,
  stableProviderBackedAppleIdentity,
  selfAliasDifferential,
  sharedGroupIdentity,
  sharedGroupMetadataEvent,
  passiveNaturalProduction,
}

enum LogicalConversationCandidateClassification {
  certifiedCurrentOrHistoricalReadMember,
  historicalRelatedButNotSameParticipantSet,
  legitimatelyDistinct,
  ambiguousNotEnrolled,
}

class LogicalConversationMemberProof {
  const LogicalConversationMemberProof({
    required this.sourceChatRowId,
    required this.sourceChatGuidHmacSha256,
    this.sourceChatGuidSha256 = '',
    required this.admissionReceiptCommit,
    this.admissionEvidenceSha256 = '',
    required this.evidence,
    required this.pairwiseComparedSourceRowIds,
    required this.directRelationshipPeerRowIds,
    required this.minimumStructuredRelationshipCount,
    required this.explanation,
  });

  final int sourceChatRowId;
  final String sourceChatGuidHmacSha256;
  final String sourceChatGuidSha256;
  final String admissionReceiptCommit;
  final String admissionEvidenceSha256;
  final Set<LogicalConversationMemberEvidenceKind> evidence;
  final Set<int> pairwiseComparedSourceRowIds;
  final Set<int> directRelationshipPeerRowIds;
  final int minimumStructuredRelationshipCount;
  final String explanation;

  bool get hasIndependentAdmissionProof =>
      sourceChatRowId > 0 &&
      (RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceChatGuidHmacSha256) ||
          RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceChatGuidSha256)) &&
      (RegExp(r'^[0-9a-f]{40}$').hasMatch(admissionReceiptCommit) ||
          RegExp(r'^[0-9a-f]{64}$').hasMatch(admissionEvidenceSha256)) &&
      (evidence.contains(LogicalConversationMemberEvidenceKind.appleBlueBubblesGuidParity) ||
          evidence.contains(LogicalConversationMemberEvidenceKind.stableProviderBackedAppleIdentity)) &&
      evidence.contains(LogicalConversationMemberEvidenceKind.exactNormalizedExternalParticipants) &&
      evidence.contains(LogicalConversationMemberEvidenceKind.completePairwiseDifferential) &&
      evidence.contains(LogicalConversationMemberEvidenceKind.structuredCrossChatRelationship) &&
      evidence.contains(LogicalConversationMemberEvidenceKind.passiveNaturalProduction) &&
      directRelationshipPeerRowIds.isNotEmpty &&
      minimumStructuredRelationshipCount > 0 &&
      explanation.isNotEmpty;

  LogicalConversationMemberProof withAdditionalPairwisePeer(int sourceChatRowId) => LogicalConversationMemberProof(
    sourceChatRowId: this.sourceChatRowId,
    sourceChatGuidHmacSha256: sourceChatGuidHmacSha256,
    sourceChatGuidSha256: sourceChatGuidSha256,
    admissionReceiptCommit: admissionReceiptCommit,
    admissionEvidenceSha256: admissionEvidenceSha256,
    evidence: evidence,
    pairwiseComparedSourceRowIds: {...pairwiseComparedSourceRowIds, sourceChatRowId},
    directRelationshipPeerRowIds: directRelationshipPeerRowIds,
    minimumStructuredRelationshipCount: minimumStructuredRelationshipCount,
    explanation: explanation,
  );
}

/// Complete, independently collected evidence for one nominated physical chat.
/// A display name, candidate ordering, or relationship through another new
/// candidate is deliberately insufficient for admission.
class LogicalConversationCandidateEvidence {
  const LogicalConversationCandidateEvidence({
    required this.sourceChatRowId,
    required this.sourceChatGuidSha256,
    required this.admissionEvidenceSha256,
    required this.providerBackedAppleIdentity,
    required this.stableCompleteSnapshots,
    required this.exactNormalizedExternalParticipants,
    required this.pairwiseComparedSourceRowIds,
    required this.directRelationshipPeerRowIds,
    required this.structuredRelationshipCount,
    required this.passiveNaturalProduction,
    required this.groupIdentityContinuity,
    required this.historicalLineage,
    required this.explanation,
  });

  final int sourceChatRowId;
  final String sourceChatGuidSha256;
  final String admissionEvidenceSha256;
  final bool providerBackedAppleIdentity;
  final bool stableCompleteSnapshots;
  final bool exactNormalizedExternalParticipants;
  final Set<int> pairwiseComparedSourceRowIds;
  final Set<int> directRelationshipPeerRowIds;
  final int structuredRelationshipCount;
  final bool passiveNaturalProduction;
  final bool groupIdentityContinuity;
  final bool historicalLineage;
  final String explanation;
}

class LogicalConversationCandidateDecision {
  const LogicalConversationCandidateDecision({
    required this.sourceChatRowId,
    required this.classification,
    required this.reason,
  });

  final int sourceChatRowId;
  final LogicalConversationCandidateClassification classification;
  final String reason;
}

class LogicalConversationCertificateReconciliation {
  const LogicalConversationCertificateReconciliation({required this.certificate, required this.decisions});

  final LogicalConversationReadCertificate certificate;
  final List<LogicalConversationCandidateDecision> decisions;
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

  /// Stable identity of the exact admitted member set and its supporting
  /// receipts. This is an execution precondition, not a cache version.
  String get revision {
    final ordered = members.toList()..sort((left, right) => left.sourceChatRowId.compareTo(right.sourceChatRowId));
    final payload = <String, dynamic>{
      'schema': schema,
      'id': id,
      'presentationSourceChatRowId': presentationSourceChatRowId,
      'members': [
        for (final member in ordered)
          <String, dynamic>{
            'sourceChatRowId': member.sourceChatRowId,
            'sourceChatGuidHmacSha256': member.sourceChatGuidHmacSha256,
            'sourceChatGuidSha256': member.sourceChatGuidSha256,
            'admissionReceiptCommit': member.admissionReceiptCommit,
            'admissionEvidenceSha256': member.admissionEvidenceSha256,
          },
      ],
    };
    return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  }

  bool containsSourceRowId(int? rowId) => rowId != null && sourceChatRowIds.contains(rowId);

  LogicalConversationMemberProof? proofFor(int? rowId) {
    if (rowId == null) return null;
    for (final member in members) {
      if (member.sourceChatRowId == rowId) return member;
    }
    return null;
  }

  bool get isValid {
    if (schema != logicalConversationReadCertificateSchema || id.isEmpty || members.length < 2) {
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

/// Read-only observation used to bind a stable provider GUID fingerprint to the
/// current local database identity. The raw GUID is consumed and discarded.
class LogicalConversationPhysicalChatBinding {
  const LogicalConversationPhysicalChatBinding.fromGuidSha256({
    required this.sourceChatRowId,
    required this.sourceChatGuidSha256,
    this.physicalRef,
  });

  factory LogicalConversationPhysicalChatBinding.fromProviderGuid({
    required int sourceChatRowId,
    required String sourceChatGuid,
  }) {
    return LogicalConversationPhysicalChatBinding.fromGuidSha256(
      sourceChatRowId: sourceChatRowId,
      sourceChatGuidSha256: sha256.convert(utf8.encode('logical-provider-guid-v1\u0000$sourceChatGuid')).toString(),
      physicalRef: PhysicalConversationRef.fromStablePhysicalGuid(sourceChatGuid),
    );
  }

  final int sourceChatRowId;
  final String sourceChatGuidSha256;
  final PhysicalConversationRef? physicalRef;

  bool get isValid => sourceChatRowId > 0 && RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceChatGuidSha256);
}

/// One member in a banked certificate. Every relationship is expressed using
/// stable GUID fingerprints; local database ROWIDs are deliberately absent.
class LogicalConversationMemberTrustAnchor {
  const LogicalConversationMemberTrustAnchor({
    required this.sourceChatGuidHmacSha256,
    required this.sourceChatGuidSha256,
    required this.admissionReceiptCommit,
    this.admissionEvidenceSha256 = '',
    required this.evidence,
    required this.pairwiseComparedSourceGuidSha256,
    required this.directRelationshipPeerGuidSha256,
    required this.minimumStructuredRelationshipCount,
    required this.explanation,
  });

  final String sourceChatGuidHmacSha256;
  final String sourceChatGuidSha256;
  final String admissionReceiptCommit;
  final String admissionEvidenceSha256;
  final Set<LogicalConversationMemberEvidenceKind> evidence;
  final Set<String> pairwiseComparedSourceGuidSha256;
  final Set<String> directRelationshipPeerGuidSha256;
  final int minimumStructuredRelationshipCount;
  final String explanation;

  bool get isValid {
    final hash = RegExp(r'^[0-9a-f]{64}$');
    final receipt = RegExp(r'^[0-9a-f]{40}$');
    return hash.hasMatch(sourceChatGuidSha256) &&
        (hash.hasMatch(sourceChatGuidHmacSha256) || sourceChatGuidHmacSha256.isEmpty) &&
        (receipt.hasMatch(admissionReceiptCommit) || hash.hasMatch(admissionEvidenceSha256)) &&
        evidence.contains(LogicalConversationMemberEvidenceKind.exactNormalizedExternalParticipants) &&
        evidence.contains(LogicalConversationMemberEvidenceKind.completePairwiseDifferential) &&
        evidence.contains(LogicalConversationMemberEvidenceKind.structuredCrossChatRelationship) &&
        evidence.contains(LogicalConversationMemberEvidenceKind.passiveNaturalProduction) &&
        (evidence.contains(LogicalConversationMemberEvidenceKind.appleBlueBubblesGuidParity) ||
            evidence.contains(LogicalConversationMemberEvidenceKind.stableProviderBackedAppleIdentity)) &&
        directRelationshipPeerGuidSha256.isNotEmpty &&
        minimumStructuredRelationshipCount > 0 &&
        explanation.isNotEmpty;
  }
}

/// Stable, row-independent root of trust. Binding is a pure operation over a
/// caller-supplied read-only provider snapshot and succeeds only when every
/// member fingerprint has exactly one current local row.
class LogicalConversationBankedCertificateTrustAnchor {
  const LogicalConversationBankedCertificateTrustAnchor({
    required this.schema,
    required this.id,
    required this.members,
    required this.presentationSourceChatGuidSha256,
  });

  final String schema;
  final String id;
  final List<LogicalConversationMemberTrustAnchor> members;
  final String presentationSourceChatGuidSha256;

  Set<String> get sourceChatGuidSha256 => members.map((member) => member.sourceChatGuidSha256).toSet();

  LogicalConversationMemberTrustAnchor? proofForGuidSha256(String guidSha256) {
    for (final member in members) {
      if (member.sourceChatGuidSha256 == guidSha256) return member;
    }
    return null;
  }

  bool get isValid {
    if (schema != logicalConversationReadCertificateSchema || id.isEmpty || members.length < 2) return false;
    final sources = sourceChatGuidSha256;
    if (sources.length != members.length || !sources.contains(presentationSourceChatGuidSha256)) return false;
    for (final member in members) {
      if (!member.isValid) return false;
      final expectedPeers = sources.difference({member.sourceChatGuidSha256});
      if (member.pairwiseComparedSourceGuidSha256.length != expectedPeers.length ||
          !member.pairwiseComparedSourceGuidSha256.containsAll(expectedPeers) ||
          !expectedPeers.containsAll(member.pairwiseComparedSourceGuidSha256) ||
          !expectedPeers.containsAll(member.directRelationshipPeerGuidSha256)) {
        return false;
      }
    }
    return true;
  }

  String get revision {
    final ordered = members.toList()
      ..sort((left, right) => left.sourceChatGuidSha256.compareTo(right.sourceChatGuidSha256));
    final payload = <String, dynamic>{
      'schema': schema,
      'id': id,
      'presentationSourceChatGuidSha256': presentationSourceChatGuidSha256,
      'members': [
        for (final member in ordered)
          <String, dynamic>{
            'sourceChatGuidHmacSha256': member.sourceChatGuidHmacSha256,
            'sourceChatGuidSha256': member.sourceChatGuidSha256,
            'admissionReceiptCommit': member.admissionReceiptCommit,
            'admissionEvidenceSha256': member.admissionEvidenceSha256,
            'evidence': member.evidence.map((value) => value.name).toList()..sort(),
            'pairwiseComparedSourceGuidSha256': member.pairwiseComparedSourceGuidSha256.toList()..sort(),
            'directRelationshipPeerGuidSha256': member.directRelationshipPeerGuidSha256.toList()..sort(),
            'minimumStructuredRelationshipCount': member.minimumStructuredRelationshipCount,
            'explanation': member.explanation,
          },
      ],
    };
    return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  }

  LogicalConversationReadCertificate? bind(Iterable<LogicalConversationPhysicalChatBinding> physicalChats) {
    if (!isValid) return null;
    final byGuid = <String, List<LogicalConversationPhysicalChatBinding>>{};
    for (final chat in physicalChats) {
      if (!chat.isValid) return null;
      byGuid.putIfAbsent(chat.sourceChatGuidSha256, () => <LogicalConversationPhysicalChatBinding>[]).add(chat);
    }
    final selected = <String, LogicalConversationPhysicalChatBinding>{};
    for (final fingerprint in sourceChatGuidSha256) {
      final matches = byGuid[fingerprint];
      if (matches == null || matches.length != 1) return null;
      selected[fingerprint] = matches.single;
    }
    final selectedRows = selected.values.map((binding) => binding.sourceChatRowId).toSet();
    if (selectedRows.length != selected.length) return null;

    int rowFor(String fingerprint) => selected[fingerprint]!.sourceChatRowId;
    final certificate = LogicalConversationReadCertificate(
      schema: schema,
      id: id,
      presentationSourceChatRowId: rowFor(presentationSourceChatGuidSha256),
      members: [
        for (final member in members)
          LogicalConversationMemberProof(
            sourceChatRowId: rowFor(member.sourceChatGuidSha256),
            sourceChatGuidHmacSha256: member.sourceChatGuidHmacSha256,
            sourceChatGuidSha256: member.sourceChatGuidSha256,
            admissionReceiptCommit: member.admissionReceiptCommit,
            admissionEvidenceSha256: member.admissionEvidenceSha256,
            evidence: member.evidence,
            pairwiseComparedSourceRowIds: member.pairwiseComparedSourceGuidSha256.map(rowFor).toSet(),
            directRelationshipPeerRowIds: member.directRelationshipPeerGuidSha256.map(rowFor).toSet(),
            minimumStructuredRelationshipCount: member.minimumStructuredRelationshipCount,
            explanation: member.explanation,
          ),
      ],
    );
    return certificate.isValid ? certificate : null;
  }

  factory LogicalConversationBankedCertificateTrustAnchor.fromBoundCertificate(
    LogicalConversationReadCertificate certificate,
  ) {
    if (!certificate.isValid) throw const FormatException('BOUND_CERTIFICATE_INVALID');
    final byRow = <int, LogicalConversationMemberProof>{
      for (final member in certificate.members) member.sourceChatRowId: member,
    };
    if (byRow.length != certificate.members.length) {
      throw const FormatException('BOUND_CERTIFICATE_DUPLICATE_ROW');
    }
    String fingerprintForRow(int rowId) {
      final fingerprint = byRow[rowId]?.sourceChatGuidSha256;
      if (fingerprint == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) {
        throw const FormatException('BOUND_CERTIFICATE_GUID_FINGERPRINT_MISSING');
      }
      return fingerprint;
    }

    final anchor = LogicalConversationBankedCertificateTrustAnchor(
      schema: certificate.schema,
      id: certificate.id,
      presentationSourceChatGuidSha256: fingerprintForRow(certificate.presentationSourceChatRowId),
      members: [
        for (final member in certificate.members)
          LogicalConversationMemberTrustAnchor(
            sourceChatGuidHmacSha256: member.sourceChatGuidHmacSha256,
            sourceChatGuidSha256: member.sourceChatGuidSha256,
            admissionReceiptCommit: member.admissionReceiptCommit,
            admissionEvidenceSha256: member.admissionEvidenceSha256,
            evidence: member.evidence,
            pairwiseComparedSourceGuidSha256: member.pairwiseComparedSourceRowIds.map(fingerprintForRow).toSet(),
            directRelationshipPeerGuidSha256: member.directRelationshipPeerRowIds.map(fingerprintForRow).toSet(),
            minimumStructuredRelationshipCount: member.minimumStructuredRelationshipCount,
            explanation: member.explanation,
          ),
      ],
    );
    if (!anchor.isValid) throw const FormatException('BOUND_CERTIFICATE_TRUST_ANCHOR_INVALID');
    return anchor;
  }
}

Map<String, dynamic> _trustAnchorPayload(LogicalConversationBankedCertificateTrustAnchor anchor) {
  final members = anchor.members.toList()
    ..sort((left, right) => left.sourceChatGuidSha256.compareTo(right.sourceChatGuidSha256));
  return <String, dynamic>{
    'schema': anchor.schema,
    'id': anchor.id,
    'revision': anchor.revision,
    'presentationSourceChatGuidSha256': anchor.presentationSourceChatGuidSha256,
    'members': <Map<String, dynamic>>[
      for (final member in members)
        <String, dynamic>{
          'sourceChatGuidHmacSha256': member.sourceChatGuidHmacSha256,
          'sourceChatGuidSha256': member.sourceChatGuidSha256,
          'admissionReceiptCommit': member.admissionReceiptCommit,
          'admissionEvidenceSha256': member.admissionEvidenceSha256,
          'evidence': member.evidence.map((value) => value.name).toList()..sort(),
          'pairwiseComparedSourceGuidSha256': member.pairwiseComparedSourceGuidSha256.toList()..sort(),
          'directRelationshipPeerGuidSha256': member.directRelationshipPeerGuidSha256.toList()..sort(),
          'minimumStructuredRelationshipCount': member.minimumStructuredRelationshipCount,
          'explanation': member.explanation,
        },
    ],
  };
}

Map<String, dynamic> _runtimeEnvelopeForAnchor(LogicalConversationBankedCertificateTrustAnchor anchor) =>
    <String, dynamic>{
      'schema': logicalConversationRuntimeCertificateSchema,
      'certificate': _trustAnchorPayload(anchor),
    };

Set<LogicalConversationMemberEvidenceKind> _evidenceFromJson(dynamic raw) {
  if (raw is! List || raw.any((value) => value is! String)) {
    throw const FormatException('RUNTIME_CERTIFICATE_EVIDENCE_INVALID');
  }
  try {
    return raw.cast<String>().map(LogicalConversationMemberEvidenceKind.values.byName).toSet();
  } catch (_) {
    throw const FormatException('RUNTIME_CERTIFICATE_EVIDENCE_INVALID');
  }
}

Set<String> _fingerprintSetFromJson(dynamic raw) {
  if (raw is! List || raw.any((value) => value is! String)) {
    throw const FormatException('RUNTIME_CERTIFICATE_FINGERPRINT_SET_INVALID');
  }
  final values = raw.cast<String>().toSet();
  if (values.length != raw.length || values.any((value) => !RegExp(r'^[0-9a-f]{64}$').hasMatch(value))) {
    throw const FormatException('RUNTIME_CERTIFICATE_FINGERPRINT_SET_INVALID');
  }
  return values;
}

LogicalConversationBankedCertificateTrustAnchor _trustAnchorFromPayload(Map<String, dynamic> payload) {
  final rawMembers = payload['members'];
  if (rawMembers is! List) throw const FormatException('RUNTIME_CERTIFICATE_PAYLOAD_INVALID');
  final members = <LogicalConversationMemberTrustAnchor>[];
  try {
    for (final rawMember in rawMembers) {
      if (rawMember is! Map) throw const FormatException('RUNTIME_CERTIFICATE_MEMBER_INVALID');
      final member = rawMember.cast<String, dynamic>();
      members.add(
        LogicalConversationMemberTrustAnchor(
          sourceChatGuidHmacSha256: member['sourceChatGuidHmacSha256'] as String,
          sourceChatGuidSha256: member['sourceChatGuidSha256'] as String,
          admissionReceiptCommit: member['admissionReceiptCommit'] as String,
          admissionEvidenceSha256: member['admissionEvidenceSha256'] as String,
          evidence: _evidenceFromJson(member['evidence']),
          pairwiseComparedSourceGuidSha256: _fingerprintSetFromJson(member['pairwiseComparedSourceGuidSha256']),
          directRelationshipPeerGuidSha256: _fingerprintSetFromJson(member['directRelationshipPeerGuidSha256']),
          minimumStructuredRelationshipCount: member['minimumStructuredRelationshipCount'] as int,
          explanation: member['explanation'] as String,
        ),
      );
    }
    final anchor = LogicalConversationBankedCertificateTrustAnchor(
      schema: payload['schema'] as String,
      id: payload['id'] as String,
      members: members,
      presentationSourceChatGuidSha256: payload['presentationSourceChatGuidSha256'] as String,
    );
    if (!anchor.isValid || payload['revision'] != anchor.revision) {
      throw const FormatException('RUNTIME_CERTIFICATE_PAYLOAD_INVALID');
    }
    return anchor;
  } on TypeError {
    throw const FormatException('RUNTIME_CERTIFICATE_PAYLOAD_INVALID');
  }
}

LogicalConversationBankedCertificateTrustAnchor _trustAnchorFromEnvelope(Map<String, dynamic> envelope) {
  if (envelope['schema'] != logicalConversationRuntimeCertificateSchema || envelope['certificate'] is! Map) {
    throw const FormatException('RUNTIME_CERTIFICATE_ENVELOPE_INVALID');
  }
  return _trustAnchorFromPayload((envelope['certificate'] as Map).cast<String, dynamic>());
}

bool _isTrustedCertificateExtension(
  LogicalConversationBankedCertificateTrustAnchor trusted,
  LogicalConversationBankedCertificateTrustAnchor certificate,
) {
  if (!trusted.isValid ||
      !certificate.isValid ||
      certificate.id != trusted.id ||
      certificate.schema != trusted.schema ||
      certificate.presentationSourceChatGuidSha256 != trusted.presentationSourceChatGuidSha256 ||
      !certificate.sourceChatGuidSha256.containsAll(trusted.sourceChatGuidSha256)) {
    return false;
  }
  for (final root in trusted.members) {
    final restored = certificate.proofForGuidSha256(root.sourceChatGuidSha256);
    if (restored == null ||
        restored.sourceChatGuidHmacSha256 != root.sourceChatGuidHmacSha256 ||
        restored.admissionReceiptCommit != root.admissionReceiptCommit ||
        restored.admissionEvidenceSha256 != root.admissionEvidenceSha256 ||
        !restored.evidence.containsAll(root.evidence) ||
        !restored.pairwiseComparedSourceGuidSha256.containsAll(root.pairwiseComparedSourceGuidSha256) ||
        restored.directRelationshipPeerGuidSha256.length != root.directRelationshipPeerGuidSha256.length ||
        !restored.directRelationshipPeerGuidSha256.containsAll(root.directRelationshipPeerGuidSha256) ||
        restored.minimumStructuredRelationshipCount != root.minimumStructuredRelationshipCount) {
      return false;
    }
  }
  return true;
}

/// An independently admitted privacy-safe root plus its current monotonic
/// certificate. Persisting a current certificate never creates a new root.
class LogicalConversationCertificateAuthority {
  LogicalConversationCertificateAuthority({required this.trustedAnchor, required this.certificate}) {
    if (!_isTrustedCertificateExtension(trustedAnchor, certificate)) {
      throw const FormatException('LOGICAL_CERTIFICATE_AUTHORITY_INVALID');
    }
  }

  factory LogicalConversationCertificateAuthority.fromBoundCertificate(
    LogicalConversationReadCertificate certificate, {
    LogicalConversationReadCertificate? trustedCertificate,
  }) {
    return LogicalConversationCertificateAuthority(
      trustedAnchor: LogicalConversationBankedCertificateTrustAnchor.fromBoundCertificate(
        trustedCertificate ?? certificate,
      ),
      certificate: LogicalConversationBankedCertificateTrustAnchor.fromBoundCertificate(certificate),
    );
  }

  final LogicalConversationBankedCertificateTrustAnchor trustedAnchor;
  final LogicalConversationBankedCertificateTrustAnchor certificate;

  LogicalConversationId get logicalId => LogicalConversationId.certified(certificate.id);

  LogicalConversationCertificateLedgerRecord toLedgerRecord() => LogicalConversationCertificateLedgerRecord(
    logicalId: logicalId,
    trustedAnchorEnvelope: _runtimeEnvelopeForAnchor(trustedAnchor),
    certificateEnvelope: _runtimeEnvelopeForAnchor(certificate),
  );
}

/// Fail-closed deterministic projection helpers for explicitly certified
/// physical identities. Raw chats/messages remain the persisted authority.
class LogicalConversationViewPolicy {
  LogicalConversationViewPolicy._();

  static const _receipt = '3432adfd6c7daa67d8d7521207a8d433b3339763';
  static const _logicalId = 'LGC_V2_377f996e2dfd452ac69370dadda3aaf185c6714a0bda48af92faf8f55282424a';
  static const _firstGuidSha256 = 'c64a1de60583c705c9e636305f3cb07ba6d5d5feaded54cfdbe007c83f5048db';
  static const _secondGuidSha256 = 'c83499c53dfee807beb1252874d4228b3519b3f437ee1a991febd6837f3c0082';
  static const _presentationGuidSha256 = '78d0349ad6e86d9ec1aac4d244356ccc0326bc8a1e9371517a1d6ce6882ad83d';

  static const bankedReadTrustAnchor = LogicalConversationBankedCertificateTrustAnchor(
    schema: logicalConversationReadCertificateSchema,
    id: _logicalId,
    presentationSourceChatGuidSha256: _presentationGuidSha256,
    members: [
      LogicalConversationMemberTrustAnchor(
        sourceChatGuidHmacSha256: 'c792167d4f9f6012663b1db0d56169beba631d5c5bf37799bf5e9c2419e86800',
        sourceChatGuidSha256: _firstGuidSha256,
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
        pairwiseComparedSourceGuidSha256: {_secondGuidSha256, _presentationGuidSha256},
        directRelationshipPeerGuidSha256: {_presentationGuidSha256},
        minimumStructuredRelationshipCount: 2,
        explanation:
            'GUID parity, exact external membership, complete pairwise differentials, direct structured reactions, '
            'shared group identity, and a shared current group-photo event prove independent read membership.',
      ),
      LogicalConversationMemberTrustAnchor(
        sourceChatGuidHmacSha256: 'f9142189fe14c1e4f15a1da5077bbfc794936e5c60bad31e90eae23d59d3ef10',
        sourceChatGuidSha256: _secondGuidSha256,
        admissionReceiptCommit: _receipt,
        evidence: {
          LogicalConversationMemberEvidenceKind.appleBlueBubblesGuidParity,
          LogicalConversationMemberEvidenceKind.exactNormalizedExternalParticipants,
          LogicalConversationMemberEvidenceKind.completePairwiseDifferential,
          LogicalConversationMemberEvidenceKind.structuredCrossChatRelationship,
          LogicalConversationMemberEvidenceKind.selfAliasDifferential,
          LogicalConversationMemberEvidenceKind.passiveNaturalProduction,
        },
        pairwiseComparedSourceGuidSha256: {_firstGuidSha256, _presentationGuidSha256},
        directRelationshipPeerGuidSha256: {_presentationGuidSha256},
        minimumStructuredRelationshipCount: 18,
        explanation:
            'GUID parity, exact external membership with only the active self alias added, complete pairwise '
            'differentials, and direct structured relationships prove independent read membership.',
      ),
      LogicalConversationMemberTrustAnchor(
        sourceChatGuidHmacSha256: '4b2902861414cb6b0408d92be5d8d977a89f8547e88a1521529d4bffb96b486b',
        sourceChatGuidSha256: _presentationGuidSha256,
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
        pairwiseComparedSourceGuidSha256: {_firstGuidSha256, _secondGuidSha256},
        directRelationshipPeerGuidSha256: {_firstGuidSha256, _secondGuidSha256},
        minimumStructuredRelationshipCount: 20,
        explanation:
            'GUID parity, exact external membership, complete pairwise differentials, direct structured reactions '
            'to both other members, and shared group metadata prove independent read membership.',
      ),
    ],
  );

  static const _unboundCertificate = LogicalConversationReadCertificate(
    schema: logicalConversationReadCertificateSchema,
    id: _logicalId,
    members: <LogicalConversationMemberProof>[],
    presentationSourceChatRowId: 0,
  );

  static LogicalConversationReadCertificate _activeCertificate = _unboundCertificate;
  static bool _runtimeCertificateAvailable = false;
  static List<LogicalConversationPhysicalChatBinding> _physicalBindings = const [];
  static LogicalConversationCertificateLedger? _certificateLedger;
  static Map<LogicalConversationId, LogicalConversationReadCertificate> _boundCertificates =
      const <LogicalConversationId, LogicalConversationReadCertificate>{};
  static Map<LogicalConversationId, LogicalConversationCertificateAuthority> _certificateAuthorities =
      const <LogicalConversationId, LogicalConversationCertificateAuthority>{};
  static Map<int, LogicalConversationId> _resolvedSourceLogicalIds = const <int, LogicalConversationId>{};
  static Map<int, String> _resolvedSourceProviderFingerprints = const <int, String>{};
  static bool _certificateLedgerValid = false;
  static bool _certificateLedgerCorrupt = false;
  static bool _certificateLedgerMigrationPending = false;

  static LogicalConversationReadCertificate get activeCertificate => _activeCertificate;
  static bool get runtimeCertificateAvailable => _runtimeCertificateAvailable;
  static bool get certificateLedgerValid => _certificateLedgerValid;
  static bool get certificateLedgerCorrupt => _certificateLedgerCorrupt;
  static bool get certificateLedgerMigrationPending => _certificateLedgerMigrationPending;
  static bool get allRuntimeCertificatesAvailable =>
      _certificateLedgerValid && _certificateLedger!.records.length == _boundCertificates.length;
  static Iterable<LogicalConversationReadCertificate> get activeCertificates {
    final entries = _boundCertificates.entries.toList(growable: false)
      ..sort((left, right) => left.key.compareTo(right.key));
    return entries.map((entry) => entry.value);
  }

  static Iterable<LogicalConversationCertificateAuthority> get activeAuthorities {
    final entries = _certificateAuthorities.entries.toList(growable: false)
      ..sort((left, right) => left.key.compareTo(right.key));
    return entries.map((entry) => entry.value);
  }

  static Set<LogicalConversationId> get certificateLedgerLogicalIds =>
      _certificateLedger?.records.map((record) => record.logicalId).toSet() ?? const <LogicalConversationId>{};
  static Set<LogicalConversationId> get unavailableCertificateLogicalIds =>
      certificateLedgerLogicalIds.difference(_boundCertificates.keys.toSet());
  static Set<int> get approvedSourceRowIds => _resolvedSourceLogicalIds.keys.toSet();
  static String get bankedLogicalConversationId => bankedReadTrustAnchor.id;
  static LogicalConversationId get bankedApplicationLogicalId => LogicalConversationId.certified(_logicalId);

  static LogicalConversationReadCertificate? certificateForLogicalId(LogicalConversationId logicalId) =>
      _boundCertificates[logicalId];

  static LogicalConversationCertificateAuthority? authorityForLogicalId(LogicalConversationId logicalId) =>
      _certificateAuthorities[logicalId];

  /// Returns the certified ledger owner only when the current physical row and
  /// provider GUID still match the unique read-only binding admitted at DB
  /// initialization. A partial certificate can retain identity/protection but
  /// cannot obtain a full read certificate or writer authority.
  static LogicalConversationId? trustedLogicalIdForSourceBinding({
    required int? sourceChatRowId,
    required String sourceChatGuid,
  }) {
    if (sourceChatRowId == null || sourceChatGuid.isEmpty) return null;
    final expected = _resolvedSourceProviderFingerprints[sourceChatRowId];
    if (expected == null) return null;
    final observed = LogicalConversationPhysicalChatBinding.fromProviderGuid(
      sourceChatRowId: sourceChatRowId,
      sourceChatGuid: sourceChatGuid,
    );
    return observed.sourceChatGuidSha256 == expected ? _resolvedSourceLogicalIds[sourceChatRowId] : null;
  }

  static Map<LogicalConversationId, LogicalConversationCertificateAuthority> _authoritiesForLedger(
    LogicalConversationCertificateLedger ledger,
  ) {
    final authorities = <LogicalConversationId, LogicalConversationCertificateAuthority>{};
    final providerOwners = <String, LogicalConversationId>{};
    for (final record in ledger.records) {
      final authority = LogicalConversationCertificateAuthority(
        trustedAnchor: _trustAnchorFromEnvelope(record.trustedAnchorEnvelope),
        certificate: _trustAnchorFromEnvelope(record.certificateEnvelope),
      );
      if (authority.logicalId != record.logicalId) {
        throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_IDENTITY_MISMATCH');
      }
      for (final fingerprint in authority.certificate.sourceChatGuidSha256) {
        final owner = providerOwners[fingerprint];
        if (owner != null && owner != record.logicalId) {
          throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_CROSS_ENTRY_PROVIDER_COLLISION');
        }
        providerOwners[fingerprint] = record.logicalId;
      }
      authorities[record.logicalId] = authority;
    }
    final banked = authorities[bankedApplicationLogicalId];
    if (banked == null ||
        jsonEncode(_trustAnchorPayload(banked.trustedAnchor)) !=
            jsonEncode(_trustAnchorPayload(bankedReadTrustAnchor))) {
      throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_BANKED_ROOT_INVALID');
    }
    return authorities;
  }

  static bool _applyCertificateLedger(LogicalConversationCertificateLedger ledger) {
    final authorities = _authoritiesForLedger(ledger);
    for (final binding in _physicalBindings) {
      if (!binding.isValid) throw const FormatException('LOGICAL_CERTIFICATE_RUNTIME_BINDING_INVALID');
    }

    final resolvedRowOwners = <int, LogicalConversationId>{};
    final resolvedRowFingerprints = <int, String>{};
    for (final entry in authorities.entries) {
      for (final fingerprint in entry.value.certificate.sourceChatGuidSha256) {
        final matches = _physicalBindings
            .where((binding) => binding.sourceChatGuidSha256 == fingerprint)
            .toList(growable: false);
        if (matches.length > 1) {
          throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_RUNTIME_FINGERPRINT_AMBIGUOUS');
        }
        if (matches.isEmpty) continue;
        final match = matches.single;
        if (resolvedRowOwners.containsKey(match.sourceChatRowId)) {
          throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_RUNTIME_ROW_COLLISION');
        }
        resolvedRowOwners[match.sourceChatRowId] = entry.key;
        resolvedRowFingerprints[match.sourceChatRowId] = fingerprint;
      }
    }

    final bound = <LogicalConversationId, LogicalConversationReadCertificate>{};
    final boundRowOwners = <int, LogicalConversationId>{};
    for (final entry in authorities.entries) {
      final certificate = entry.value.certificate.bind(_physicalBindings);
      if (certificate == null) continue;
      for (final rowId in certificate.sourceChatRowIds) {
        final owner = boundRowOwners[rowId];
        if (owner != null && owner != entry.key) {
          throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_CROSS_ENTRY_ROW_COLLISION');
        }
        boundRowOwners[rowId] = entry.key;
      }
      bound[entry.key] = certificate;
    }

    _certificateLedger = ledger;
    _boundCertificates = Map<LogicalConversationId, LogicalConversationReadCertificate>.unmodifiable(bound);
    _certificateLedgerValid = true;
    _certificateLedgerCorrupt = false;
    _activeCertificate = bound[bankedApplicationLogicalId] ?? _unboundCertificate;
    _runtimeCertificateAvailable = bound.containsKey(bankedApplicationLogicalId);
    _certificateAuthorities = Map<LogicalConversationId, LogicalConversationCertificateAuthority>.unmodifiable(
      authorities,
    );
    _resolvedSourceLogicalIds = Map<int, LogicalConversationId>.unmodifiable(resolvedRowOwners);
    _resolvedSourceProviderFingerprints = Map<int, String>.unmodifiable(resolvedRowFingerprints);
    return _runtimeCertificateAvailable;
  }

  static void _clearCertificateLedgerRuntime({
    bool clearPhysicalBindings = false,
    bool certificateLedgerCorrupt = false,
  }) {
    _certificateLedger = null;
    _boundCertificates = const <LogicalConversationId, LogicalConversationReadCertificate>{};
    _certificateLedgerValid = false;
    _certificateLedgerCorrupt = certificateLedgerCorrupt;
    _certificateLedgerMigrationPending = false;
    _activeCertificate = _unboundCertificate;
    _certificateAuthorities = const <LogicalConversationId, LogicalConversationCertificateAuthority>{};
    _resolvedSourceLogicalIds = const <int, LogicalConversationId>{};
    _resolvedSourceProviderFingerprints = const <int, String>{};
    _runtimeCertificateAvailable = false;
    if (clearPhysicalBindings) _physicalBindings = const <LogicalConversationPhysicalChatBinding>[];
  }

  static String encodeRuntimeCertificate(LogicalConversationReadCertificate certificate) {
    final anchor = LogicalConversationBankedCertificateTrustAnchor.fromBoundCertificate(certificate);
    if (!_isTrustedExtensionOfBankedRoot(anchor)) {
      throw const FormatException('RUNTIME_CERTIFICATE_TRUST_INVALID');
    }
    return jsonEncode(_runtimeEnvelopeForAnchor(anchor));
  }

  /// Encodes a monotonic advancement for any already trusted ledger entry.
  /// This is deliberately distinct from [encodeRuntimeCertificate], whose
  /// legacy contract accepts only the banked Build 99 root.
  static String encodeReconciledRuntimeCertificate(LogicalConversationReadCertificate certificate) {
    if (!_certificateLedgerValid || !certificate.isValid) {
      throw const FormatException('RECONCILED_RUNTIME_CERTIFICATE_UNAVAILABLE');
    }
    final logicalId = LogicalConversationId.certified(certificate.id);
    final authority = _certificateAuthorities[logicalId];
    if (authority == null) {
      throw const FormatException('RECONCILED_RUNTIME_CERTIFICATE_TARGET_UNTRUSTED');
    }
    final anchor = LogicalConversationBankedCertificateTrustAnchor.fromBoundCertificate(certificate);
    if (!_isTrustedCertificateExtension(authority.trustedAnchor, anchor) ||
        !_isTrustedCertificateExtension(authority.certificate, anchor)) {
      throw const FormatException('RECONCILED_RUNTIME_CERTIFICATE_NOT_MONOTONIC');
    }
    return jsonEncode(_runtimeEnvelopeForAnchor(anchor));
  }

  static String encodeCertificateLedger(Iterable<LogicalConversationCertificateAuthority> authorities) {
    final ledger = LogicalConversationCertificateLedger(authorities.map((authority) => authority.toLedgerRecord()));
    _authoritiesForLedger(ledger);
    return ledger.encode();
  }

  static String encodeActiveCertificateLedger() {
    final ledger = _certificateLedger;
    if (!_certificateLedgerValid || ledger == null) {
      throw StateError('LOGICAL_CERTIFICATE_LEDGER_UNAVAILABLE');
    }
    return ledger.encode();
  }

  static LogicalConversationId logicalIdForRuntimeCertificate(String runtimeCertificateJson) =>
      LogicalConversationId.certified(_decodeRuntimeTrustAnchor(runtimeCertificateJson).id);

  static String persistedRevisionForBoundCertificate(LogicalConversationReadCertificate certificate) =>
      LogicalConversationBankedCertificateTrustAnchor.fromBoundCertificate(certificate).revision;

  /// Reads the exact durable target revision without mutating runtime state.
  /// V2 is authoritative whenever present; legacy V1 is considered only for
  /// the banked authority during migration.
  static String? certificateRevisionForPersistedAuthority({
    required String? persistedLedgerJson,
    required String? legacyCertificateJson,
    required LogicalConversationId logicalId,
  }) {
    if (persistedLedgerJson != null) {
      final ledger = LogicalConversationCertificateLedger.decode(persistedLedgerJson);
      return _authoritiesForLedger(ledger)[logicalId]?.certificate.revision;
    }
    if (logicalId != bankedApplicationLogicalId) return null;
    final certificate = legacyCertificateJson == null
        ? bankedReadTrustAnchor
        : _decodeRuntimeTrustAnchor(legacyCertificateJson);
    if (!_isTrustedExtensionOfBankedRoot(certificate)) {
      throw const FormatException('RUNTIME_CERTIFICATE_TRUST_INVALID');
    }
    return certificate.revision;
  }

  static String mergeRuntimeCertificateIntoLedger({
    required String? persistedLedgerJson,
    required String runtimeCertificateJson,
  }) {
    final candidate = _decodeRuntimeTrustAnchor(runtimeCertificateJson);
    final candidateLogicalId = LogicalConversationId.certified(candidate.id);
    final ledger = persistedLedgerJson == null
        ? LogicalConversationCertificateLedger(<LogicalConversationCertificateLedgerRecord>[
            LogicalConversationCertificateAuthority(
              trustedAnchor: bankedReadTrustAnchor,
              certificate: candidate,
            ).toLedgerRecord(),
          ])
        : LogicalConversationCertificateLedger.decode(persistedLedgerJson);
    final authorities = _authoritiesForLedger(ledger);
    final existing = authorities[candidateLogicalId];
    if (existing == null ||
        !_isTrustedCertificateExtension(existing.trustedAnchor, candidate) ||
        !_isTrustedCertificateExtension(existing.certificate, candidate)) {
      throw StateError('LOGICAL_CERTIFICATE_LEDGER_CERTIFICATE_ADVANCEMENT_INVALID');
    }
    final updated = ledger.replaceCertificateEnvelope(_runtimeEnvelopeForAnchor(candidate));
    _authoritiesForLedger(updated);
    return updated.encode();
  }

  static bool bindRuntimeCertificate({
    required Iterable<LogicalConversationPhysicalChatBinding> physicalChats,
    required String? persistedCertificateJson,
  }) => bindRuntimeCertificateLedger(
    physicalChats: physicalChats,
    persistedLedgerJson: null,
    legacyCertificateJson: persistedCertificateJson,
  );

  static bool bindRuntimeCertificateLedger({
    required Iterable<LogicalConversationPhysicalChatBinding> physicalChats,
    required String? persistedLedgerJson,
    required String? legacyCertificateJson,
  }) {
    _physicalBindings = List<LogicalConversationPhysicalChatBinding>.unmodifiable(physicalChats);
    return _hydrateRuntimeCertificateLedger(
      persistedLedgerJson: persistedLedgerJson,
      legacyCertificateJson: legacyCertificateJson,
    );
  }

  static bool hydrateRuntimeCertificate(String? raw) =>
      _hydrateRuntimeCertificateLedger(persistedLedgerJson: null, legacyCertificateJson: raw);

  static bool hydrateRuntimeCertificateLedger(String raw) =>
      _hydrateRuntimeCertificateLedger(persistedLedgerJson: raw, legacyCertificateJson: null);

  static bool _hydrateRuntimeCertificateLedger({
    required String? persistedLedgerJson,
    required String? legacyCertificateJson,
  }) {
    try {
      late final LogicalConversationCertificateLedger ledger;
      final migrationPending = persistedLedgerJson == null;
      if (persistedLedgerJson != null) {
        ledger = LogicalConversationCertificateLedger.decode(persistedLedgerJson);
      } else {
        final anchor = legacyCertificateJson == null
            ? bankedReadTrustAnchor
            : _decodeRuntimeTrustAnchor(legacyCertificateJson);
        if (!_isTrustedExtensionOfBankedRoot(anchor)) {
          throw const FormatException('RUNTIME_CERTIFICATE_TRUST_INVALID');
        }
        ledger = LogicalConversationCertificateLedger(<LogicalConversationCertificateLedgerRecord>[
          LogicalConversationCertificateAuthority(
            trustedAnchor: bankedReadTrustAnchor,
            certificate: anchor,
          ).toLedgerRecord(),
        ]);
      }
      final bankedBound = _applyCertificateLedger(ledger);
      _certificateLedgerMigrationPending = migrationPending;
      return bankedBound;
    } catch (_) {
      _clearCertificateLedgerRuntime(certificateLedgerCorrupt: persistedLedgerJson != null);
      return false;
    }
  }

  static void markCertificateLedgerMigrationPersisted() {
    if (!_certificateLedgerValid) {
      throw StateError('LOGICAL_CERTIFICATE_LEDGER_UNAVAILABLE');
    }
    _certificateLedgerMigrationPending = false;
  }

  static LogicalConversationBankedCertificateTrustAnchor _decodeRuntimeTrustAnchor(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['certificate'] is! Map) {
      throw const FormatException('RUNTIME_CERTIFICATE_ENVELOPE_INVALID');
    }
    final schema = decoded['schema'];
    final payload = (decoded['certificate'] as Map).cast<String, dynamic>();
    if (schema == logicalConversationLegacyRuntimeCertificateSchema) {
      return _decodeLegacyRuntimeTrustAnchor(payload);
    }
    if (schema != logicalConversationRuntimeCertificateSchema) {
      throw const FormatException('RUNTIME_CERTIFICATE_ENVELOPE_INVALID');
    }
    final anchor = _decodeStableRuntimeTrustAnchor(payload);
    if (payload['revision'] != anchor.revision) {
      throw const FormatException('RUNTIME_CERTIFICATE_REVISION_INVALID');
    }
    return anchor;
  }

  static Set<LogicalConversationMemberEvidenceKind> _decodeEvidence(dynamic raw) {
    if (raw is! List || raw.any((value) => value is! String)) {
      throw const FormatException('RUNTIME_CERTIFICATE_EVIDENCE_INVALID');
    }
    return raw.cast<String>().map(LogicalConversationMemberEvidenceKind.values.byName).toSet();
  }

  static Set<String> _decodeFingerprintSet(dynamic raw) {
    if (raw is! List || raw.any((value) => value is! String)) {
      throw const FormatException('RUNTIME_CERTIFICATE_FINGERPRINT_SET_INVALID');
    }
    final values = raw.cast<String>().toSet();
    if (values.length != raw.length || values.any((value) => !RegExp(r'^[0-9a-f]{64}$').hasMatch(value))) {
      throw const FormatException('RUNTIME_CERTIFICATE_FINGERPRINT_SET_INVALID');
    }
    return values;
  }

  static LogicalConversationBankedCertificateTrustAnchor _decodeStableRuntimeTrustAnchor(Map<String, dynamic> payload) {
    final rawMembers = payload['members'];
    if (rawMembers is! List) throw const FormatException('RUNTIME_CERTIFICATE_PAYLOAD_INVALID');
    final members = <LogicalConversationMemberTrustAnchor>[];
    for (final rawMember in rawMembers) {
      if (rawMember is! Map) throw const FormatException('RUNTIME_CERTIFICATE_MEMBER_INVALID');
      final member = rawMember.cast<String, dynamic>();
      members.add(
        LogicalConversationMemberTrustAnchor(
          sourceChatGuidHmacSha256: member['sourceChatGuidHmacSha256'] as String,
          sourceChatGuidSha256: member['sourceChatGuidSha256'] as String,
          admissionReceiptCommit: member['admissionReceiptCommit'] as String,
          admissionEvidenceSha256: member['admissionEvidenceSha256'] as String,
          evidence: _decodeEvidence(member['evidence']),
          pairwiseComparedSourceGuidSha256: _decodeFingerprintSet(member['pairwiseComparedSourceGuidSha256']),
          directRelationshipPeerGuidSha256: _decodeFingerprintSet(member['directRelationshipPeerGuidSha256']),
          minimumStructuredRelationshipCount: member['minimumStructuredRelationshipCount'] as int,
          explanation: member['explanation'] as String,
        ),
      );
    }
    final anchor = LogicalConversationBankedCertificateTrustAnchor(
      schema: payload['schema'] as String,
      id: payload['id'] as String,
      members: members,
      presentationSourceChatGuidSha256: payload['presentationSourceChatGuidSha256'] as String,
    );
    if (!anchor.isValid) throw const FormatException('RUNTIME_CERTIFICATE_PAYLOAD_INVALID');
    return anchor;
  }

  static LogicalConversationBankedCertificateTrustAnchor _decodeLegacyRuntimeTrustAnchor(Map<String, dynamic> payload) {
    final rawMembers = payload['members'];
    if (rawMembers is! List) throw const FormatException('LEGACY_RUNTIME_CERTIFICATE_PAYLOAD_INVALID');
    Set<int> integerSet(dynamic value) {
      if (value is! List || value.any((item) => item is! int)) {
        throw const FormatException('LEGACY_RUNTIME_CERTIFICATE_ROW_SET_INVALID');
      }
      final result = value.cast<int>().toSet();
      if (result.length != value.length) throw const FormatException('LEGACY_RUNTIME_CERTIFICATE_ROW_SET_INVALID');
      return result;
    }

    final members = <LogicalConversationMemberProof>[];
    for (final rawMember in rawMembers) {
      if (rawMember is! Map) throw const FormatException('LEGACY_RUNTIME_CERTIFICATE_MEMBER_INVALID');
      final member = rawMember.cast<String, dynamic>();
      members.add(
        LogicalConversationMemberProof(
          sourceChatRowId: member['sourceChatRowId'] as int,
          sourceChatGuidHmacSha256: member['sourceChatGuidHmacSha256'] as String,
          sourceChatGuidSha256: member['sourceChatGuidSha256'] as String,
          admissionReceiptCommit: member['admissionReceiptCommit'] as String,
          admissionEvidenceSha256: member['admissionEvidenceSha256'] as String,
          evidence: _decodeEvidence(member['evidence']),
          pairwiseComparedSourceRowIds: integerSet(member['pairwiseComparedSourceRowIds']),
          directRelationshipPeerRowIds: integerSet(member['directRelationshipPeerRowIds']),
          minimumStructuredRelationshipCount: member['minimumStructuredRelationshipCount'] as int,
          explanation: member['explanation'] as String,
        ),
      );
    }
    final certificate = LogicalConversationReadCertificate(
      schema: payload['schema'] as String,
      id: payload['id'] as String,
      members: members,
      presentationSourceChatRowId: payload['presentationSourceChatRowId'] as int,
    );
    if (!certificate.isValid || payload['revision'] != certificate.revision) {
      throw const FormatException('LEGACY_RUNTIME_CERTIFICATE_TRUST_INVALID');
    }
    return LogicalConversationBankedCertificateTrustAnchor.fromBoundCertificate(certificate);
  }

  static bool _isTrustedExtensionOfBankedRoot(LogicalConversationBankedCertificateTrustAnchor certificate) {
    const banked = bankedReadTrustAnchor;
    if (!certificate.isValid ||
        certificate.id != banked.id ||
        certificate.schema != banked.schema ||
        certificate.presentationSourceChatGuidSha256 != banked.presentationSourceChatGuidSha256 ||
        !certificate.sourceChatGuidSha256.containsAll(banked.sourceChatGuidSha256)) {
      return false;
    }
    for (final root in banked.members) {
      final restored = certificate.proofForGuidSha256(root.sourceChatGuidSha256);
      if (restored == null ||
          restored.sourceChatGuidHmacSha256 != root.sourceChatGuidHmacSha256 ||
          restored.admissionReceiptCommit != root.admissionReceiptCommit ||
          restored.admissionEvidenceSha256 != root.admissionEvidenceSha256 ||
          !restored.evidence.containsAll(root.evidence) ||
          !restored.pairwiseComparedSourceGuidSha256.containsAll(root.pairwiseComparedSourceGuidSha256) ||
          restored.directRelationshipPeerGuidSha256.length != root.directRelationshipPeerGuidSha256.length ||
          !restored.directRelationshipPeerGuidSha256.containsAll(root.directRelationshipPeerGuidSha256) ||
          restored.minimumStructuredRelationshipCount != root.minimumStructuredRelationshipCount) {
        return false;
      }
    }
    return true;
  }

  static bool sourceGuidMatchesActiveProof(int rowId, String guid) {
    final proof = _activeCertificate.proofFor(rowId);
    if (proof == null || proof.sourceChatGuidSha256.isEmpty) return false;
    return proof.sourceChatGuidSha256 == sha256.convert(utf8.encode('logical-provider-guid-v1\u0000$guid')).toString();
  }

  static bool matchesTransportCertificateBinding({
    required String? expectedCertificateRevision,
    required int? sourceChatRowId,
    required String? sourceChatGuid,
  }) {
    return _runtimeCertificateAvailable &&
        expectedCertificateRevision != null &&
        expectedCertificateRevision == _activeCertificate.revision &&
        sourceChatRowId != null &&
        sourceChatGuid != null &&
        sourceGuidMatchesActiveProof(sourceChatRowId, sourceChatGuid);
  }

  static bool activateReconciledCertificate(
    LogicalConversationCertificateReconciliation reconciliation, {
    required String expectedRevision,
  }) {
    final ledger = _certificateLedger;
    final advanced = reconciliation.certificate;
    if (!_certificateLedgerValid || ledger == null || !advanced.isValid) return false;
    final logicalId = LogicalConversationId.certified(advanced.id);
    final current = _boundCertificates[logicalId];
    final record = ledger.recordFor(logicalId);
    if (current == null || record == null) return false;

    try {
      final authority = LogicalConversationCertificateAuthority(
        trustedAnchor: _trustAnchorFromEnvelope(record.trustedAnchorEnvelope),
        certificate: _trustAnchorFromEnvelope(record.certificateEnvelope),
      );
      final anchor = LogicalConversationBankedCertificateTrustAnchor.fromBoundCertificate(advanced);
      if (current.revision != expectedRevision ||
          !_isTrustedCertificateExtension(authority.trustedAnchor, anchor) ||
          !_isTrustedCertificateExtension(authority.certificate, anchor) ||
          advanced.id != current.id ||
          !advanced.sourceChatRowIds.containsAll(current.sourceChatRowIds)) {
        return false;
      }

      final otherRows = <int>{
        for (final entry in _boundCertificates.entries)
          if (entry.key != logicalId) ...entry.value.sourceChatRowIds,
      };
      if (advanced.sourceChatRowIds.intersection(otherRows).isNotEmpty) return false;

      final updatedLedger = ledger.replaceCertificateEnvelope(_runtimeEnvelopeForAnchor(anchor));
      _authoritiesForLedger(updatedLedger);
      final replacedFingerprints = advanced.members.map((member) => member.sourceChatGuidSha256).toSet();
      _physicalBindings =
          List<LogicalConversationPhysicalChatBinding>.unmodifiable(<LogicalConversationPhysicalChatBinding>[
            for (final binding in _physicalBindings)
              if (!replacedFingerprints.contains(binding.sourceChatGuidSha256)) binding,
            for (final member in advanced.members)
              LogicalConversationPhysicalChatBinding.fromGuidSha256(
                sourceChatRowId: member.sourceChatRowId,
                sourceChatGuidSha256: member.sourceChatGuidSha256,
              ),
          ]);
      return _applyCertificateLedger(updatedLedger);
    } catch (_) {
      return false;
    }
  }

  static void resetRuntimeCertificateForTesting() {
    _clearCertificateLedgerRuntime(clearPhysicalBindings: true);
  }

  /// Reconciles a complete nominated universe without trusting input order or
  /// rewriting a read certificate into write authority. Every admitted
  /// candidate must bind Apple/provider identity, the exact external set,
  /// complete pairwise comparisons against the already certified set, and a
  /// direct structured relationship to an original certified member.
  static LogicalConversationCertificateReconciliation reconcileCertificate(
    LogicalConversationReadCertificate base,
    Iterable<LogicalConversationCandidateEvidence> candidateEvidence,
  ) {
    if (!base.isValid) {
      throw ArgumentError.value(base, 'base', 'BASE_READ_CERTIFICATE_INVALID');
    }
    final baseRows = base.sourceChatRowIds;
    var certificate = base;
    final decisions = <LogicalConversationCandidateDecision>[];
    final candidates = candidateEvidence.toList(growable: false)
      ..sort((left, right) => left.sourceChatRowId.compareTo(right.sourceChatRowId));
    final rowCounts = <int, int>{};
    for (final candidate in candidates) {
      rowCounts.update(candidate.sourceChatRowId, (value) => value + 1, ifAbsent: () => 1);
    }
    final duplicateRows = rowCounts.entries.where((entry) => entry.value > 1).map((entry) => entry.key).toSet();
    if (duplicateRows.isNotEmpty) {
      return LogicalConversationCertificateReconciliation(
        certificate: base,
        decisions: [
          for (final candidate in candidates)
            LogicalConversationCandidateDecision(
              sourceChatRowId: candidate.sourceChatRowId,
              classification: LogicalConversationCandidateClassification.ambiguousNotEnrolled,
              reason: duplicateRows.contains(candidate.sourceChatRowId)
                  ? 'DUPLICATE_CANDIDATE_EVIDENCE'
                  : 'RECONCILIATION_ABORTED_DUPLICATE_UNIVERSE',
            ),
        ],
      );
    }
    for (final candidate in candidates) {
      if (certificate.containsSourceRowId(candidate.sourceChatRowId)) {
        decisions.add(
          LogicalConversationCandidateDecision(
            sourceChatRowId: candidate.sourceChatRowId,
            classification: LogicalConversationCandidateClassification.certifiedCurrentOrHistoricalReadMember,
            reason: 'ALREADY_INDEPENDENTLY_CERTIFIED_READ_MEMBER',
          ),
        );
        continue;
      }
      if (!candidate.exactNormalizedExternalParticipants) {
        decisions.add(
          LogicalConversationCandidateDecision(
            sourceChatRowId: candidate.sourceChatRowId,
            classification: candidate.historicalLineage
                ? LogicalConversationCandidateClassification.historicalRelatedButNotSameParticipantSet
                : LogicalConversationCandidateClassification.legitimatelyDistinct,
            reason: candidate.historicalLineage
                ? 'HISTORICAL_LINEAGE_PARTICIPANT_SET_DIFFERS'
                : 'DISTINCT_EXTERNAL_PARTICIPANT_SET',
          ),
        );
        continue;
      }
      final currentRows = certificate.sourceChatRowIds;
      final hasDirectOriginalRelationship = candidate.directRelationshipPeerRowIds.intersection(baseRows).isNotEmpty;
      final canAdmit =
          candidate.sourceChatRowId > 0 &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(candidate.sourceChatGuidSha256) &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(candidate.admissionEvidenceSha256) &&
          candidate.providerBackedAppleIdentity &&
          candidate.stableCompleteSnapshots &&
          candidate.pairwiseComparedSourceRowIds.containsAll(currentRows) &&
          hasDirectOriginalRelationship &&
          candidate.structuredRelationshipCount > 0 &&
          candidate.passiveNaturalProduction &&
          candidate.explanation.isNotEmpty;
      if (!canAdmit) {
        decisions.add(
          LogicalConversationCandidateDecision(
            sourceChatRowId: candidate.sourceChatRowId,
            classification: LogicalConversationCandidateClassification.ambiguousNotEnrolled,
            reason: 'INDIVIDUAL_READ_MEMBERSHIP_PROOF_INCOMPLETE',
          ),
        );
        continue;
      }

      final evidence = <LogicalConversationMemberEvidenceKind>{
        LogicalConversationMemberEvidenceKind.stableProviderBackedAppleIdentity,
        LogicalConversationMemberEvidenceKind.exactNormalizedExternalParticipants,
        LogicalConversationMemberEvidenceKind.completePairwiseDifferential,
        LogicalConversationMemberEvidenceKind.structuredCrossChatRelationship,
        LogicalConversationMemberEvidenceKind.passiveNaturalProduction,
        if (candidate.groupIdentityContinuity) LogicalConversationMemberEvidenceKind.sharedGroupIdentity,
      };
      final updatedMembers =
          certificate.members
              .map((member) => member.withAdditionalPairwisePeer(candidate.sourceChatRowId))
              .toList(growable: true)
            ..add(
              LogicalConversationMemberProof(
                sourceChatRowId: candidate.sourceChatRowId,
                sourceChatGuidHmacSha256: '',
                sourceChatGuidSha256: candidate.sourceChatGuidSha256,
                admissionReceiptCommit: '',
                admissionEvidenceSha256: candidate.admissionEvidenceSha256,
                evidence: evidence,
                pairwiseComparedSourceRowIds: currentRows,
                directRelationshipPeerRowIds: candidate.directRelationshipPeerRowIds.intersection(currentRows),
                minimumStructuredRelationshipCount: candidate.structuredRelationshipCount,
                explanation: candidate.explanation,
              ),
            );
      final advanced = LogicalConversationReadCertificate(
        schema: certificate.schema,
        id: certificate.id,
        members: updatedMembers,
        presentationSourceChatRowId: certificate.presentationSourceChatRowId,
      );
      if (!advanced.isValid) {
        decisions.add(
          LogicalConversationCandidateDecision(
            sourceChatRowId: candidate.sourceChatRowId,
            classification: LogicalConversationCandidateClassification.ambiguousNotEnrolled,
            reason: 'ADVANCED_READ_CERTIFICATE_INVALID',
          ),
        );
        continue;
      }
      certificate = advanced;
      decisions.add(
        LogicalConversationCandidateDecision(
          sourceChatRowId: candidate.sourceChatRowId,
          classification: LogicalConversationCandidateClassification.certifiedCurrentOrHistoricalReadMember,
          reason: 'INDIVIDUAL_READ_MEMBERSHIP_PROVEN',
        ),
      );
    }
    return LogicalConversationCertificateReconciliation(certificate: certificate, decisions: decisions);
  }

  static bool isApprovedSourceRowId(int? rowId) => rowId != null && approvedSourceRowIds.contains(rowId);

  static LogicalConversationMemberProof? membershipProofFor(int? rowId) {
    if (rowId == null) return null;
    final matches = activeCertificates
        .map((certificate) => certificate.proofFor(rowId))
        .whereType<LogicalConversationMemberProof>()
        .toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

  static LogicalConversationExcludedCandidateProof? excludedCandidateProofFor(int? _) => null;

  /// Returns the approved certificate only when every certified source ROWID
  /// is present exactly once. Extra ordinary chats never gain membership.
  static LogicalConversationReadCertificate? resolve(Iterable<int?> availableSourceRowIds) =>
      resolveCertificate(_activeCertificate, availableSourceRowIds);

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
    var projected = List<T>.from(items);
    for (final authority in activeAuthorities) {
      final rowsByFingerprint = <String, int>{
        for (final entry in _resolvedSourceLogicalIds.entries)
          if (entry.value == authority.logicalId) _resolvedSourceProviderFingerprints[entry.key]!: entry.key,
      };
      if (rowsByFingerprint.isEmpty) continue;
      final knownRows = rowsByFingerprint.values.toSet();
      final counts = <int, int>{};
      for (final item in projected) {
        final rowId = sourceRowIdOf(item);
        if (rowId != null && knownRows.contains(rowId)) {
          counts.update(rowId, (value) => value + 1, ifAbsent: () => 1);
        }
      }
      if (counts.isEmpty || counts.values.any((count) => count != 1)) continue;
      final presentRows = counts.keys.toSet();
      final presentationRow = rowsByFingerprint[authority.certificate.presentationSourceChatGuidSha256];
      final orderedFingerprints = authority.certificate.sourceChatGuidSha256.toList(growable: false)..sort();
      final selectedRow = presentationRow != null && presentRows.contains(presentationRow)
          ? presentationRow
          : orderedFingerprints
                .map((fingerprint) => rowsByFingerprint[fingerprint])
                .nonNulls
                .firstWhere(presentRows.contains);
      projected = projected
          .where((item) => !knownRows.contains(sourceRowIdOf(item)) || sourceRowIdOf(item) == selectedRow)
          .toList(growable: false);
    }
    return projected;
  }

  static List<T> projectConversationListForCertificate<T>(
    LogicalConversationReadCertificate certificate,
    Iterable<T> items,
    int? Function(T item) sourceRowIdOf,
  ) {
    final snapshot = List<T>.from(items);
    if (!certificate.isValid) return snapshot;

    final counts = <int, int>{};
    for (final item in snapshot) {
      final rowId = sourceRowIdOf(item);
      if (certificate.containsSourceRowId(rowId)) {
        counts.update(rowId!, (value) => value + 1, ifAbsent: () => 1);
      }
    }
    if (counts.isEmpty || counts.values.any((count) => count != 1)) return snapshot;

    final presentRows = counts.keys.toSet();
    final selectedRow = presentRows.contains(certificate.presentationSourceChatRowId)
        ? certificate.presentationSourceChatRowId
        : (certificate.members.where((member) => presentRows.contains(member.sourceChatRowId)).toList()
                ..sort((left, right) {
                  final leftKey = left.sourceChatGuidSha256.isNotEmpty
                      ? left.sourceChatGuidSha256
                      : left.sourceChatGuidHmacSha256;
                  final rightKey = right.sourceChatGuidSha256.isNotEmpty
                      ? right.sourceChatGuidSha256
                      : right.sourceChatGuidHmacSha256;
                  return leftKey.compareTo(rightKey);
                }))
              .first
              .sourceChatRowId;
    return snapshot
        .where((item) => !certificate.containsSourceRowId(sourceRowIdOf(item)) || sourceRowIdOf(item) == selectedRow)
        .toList();
  }

  static int presentationSourceRowIdFor(int requestedSourceRowId, Iterable<int?> availableSourceRowIds) {
    final logicalId = _resolvedSourceLogicalIds[requestedSourceRowId];
    final authority = logicalId == null ? null : _certificateAuthorities[logicalId];
    if (logicalId == null || authority == null) return requestedSourceRowId;
    final counts = <int, int>{};
    for (final rowId in availableSourceRowIds.whereType<int>()) {
      if (_resolvedSourceLogicalIds[rowId] == logicalId) {
        counts.update(rowId, (value) => value + 1, ifAbsent: () => 1);
      }
    }
    if (counts.isEmpty || counts.values.any((count) => count != 1)) return requestedSourceRowId;
    final presentRows = counts.keys.toSet();
    final presentationRow = _resolvedSourceProviderFingerprints.entries
        .where(
          (entry) =>
              entry.value == authority.certificate.presentationSourceChatGuidSha256 &&
              _resolvedSourceLogicalIds[entry.key] == logicalId,
        )
        .map((entry) => entry.key)
        .firstOrNull;
    if (presentationRow != null && presentRows.contains(presentationRow)) return presentationRow;
    final orderedFingerprints = authority.certificate.sourceChatGuidSha256.toList(growable: false)..sort();
    for (final fingerprint in orderedFingerprints) {
      final row = _resolvedSourceProviderFingerprints.entries
          .where((entry) => entry.value == fingerprint && _resolvedSourceLogicalIds[entry.key] == logicalId)
          .map((entry) => entry.key)
          .firstOrNull;
      if (row != null && presentRows.contains(row)) return row;
    }
    return requestedSourceRowId;
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
