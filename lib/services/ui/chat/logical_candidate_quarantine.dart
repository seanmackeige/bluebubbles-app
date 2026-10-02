import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:crypto/crypto.dart';

const logicalCandidateQuarantineSchema = 'LOGICAL_CANDIDATE_QUARANTINE_V1';

final RegExp _fingerprintPattern = RegExp(r'^[0-9a-f]{64}$');

enum LogicalCandidateQuarantinePhase { nominated, reconciling, certified, rejected, expiredVisible }

enum LogicalCandidateEvidenceKind { reconciliation, independentCertificate, rejection }

enum LogicalCandidateRejectionReason {
  independentEvidenceRejected,
  nominationConflict,
  evidenceContextMismatch,
  evidenceSequenceConflict,
  evidenceOutOfOrder,
  nonIndependentCertificate,
  clockRegression,
  quarantineExpired,
}

enum LogicalCandidateTransitionDisposition {
  applied,
  duplicateIgnored,
  terminalIgnored,
  rejectedFailClosed,
  expiredVisible,
  unknownCandidateVisible,
  capacityRejectedVisible,
}

String _requireFingerprint(Object? value, String field) {
  if (value is! String || !_fingerprintPattern.hasMatch(value)) {
    throw FormatException('$field must be a lowercase SHA-256 fingerprint');
  }
  return value;
}

int _requireEpoch(Object? value, String field) {
  if (value is! int || value < 0) throw FormatException('$field must be a non-negative integer');
  return value;
}

Map<String, dynamic> _requireMap(Object? value, String field) {
  if (value is! Map) throw FormatException('$field must be an object');
  return value.cast<String, dynamic>();
}

List<dynamic> _requireList(Object? value, String field) {
  if (value is! List) throw FormatException('$field must be a list');
  return value;
}

T _requireEnum<T extends Enum>(Object? value, List<T> values, String field) {
  if (value is! String) throw FormatException('$field must be an enum name');
  for (final candidate in values) {
    if (candidate.name == value) return candidate;
  }
  throw FormatException('Unsupported $field');
}

String _digest(String namespace, Map<String, dynamic> value) => sha256
    .convert(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'schema': logicalCandidateQuarantineSchema,
          'namespace': namespace,
          'value': value,
        }),
      ),
    )
    .toString();

/// A privacy-safe nomination only. Titles, participant values, provider GUIDs,
/// and local database coordinates are deliberately not representable.
class LogicalCandidateNomination {
  LogicalCandidateNomination({
    required this.candidate,
    required this.targetLogicalId,
    required String exactParticipantSetFingerprint,
    required String serviceFingerprint,
    required String accountFingerprint,
    required String nominationEvidenceFingerprint,
    required String nominatorFingerprint,
  }) : exactParticipantSetFingerprint = _requireFingerprint(
         exactParticipantSetFingerprint,
         'exactParticipantSetFingerprint',
       ),
       serviceFingerprint = _requireFingerprint(serviceFingerprint, 'serviceFingerprint'),
       accountFingerprint = _requireFingerprint(accountFingerprint, 'accountFingerprint'),
       nominationEvidenceFingerprint = _requireFingerprint(
         nominationEvidenceFingerprint,
         'nominationEvidenceFingerprint',
       ),
       nominatorFingerprint = _requireFingerprint(nominatorFingerprint, 'nominatorFingerprint') {
    if (!targetLogicalId.isCertified) {
      throw ArgumentError.value(targetLogicalId, 'targetLogicalId', 'must identify a certified conversation');
    }
  }

  final PhysicalConversationRef candidate;
  final LogicalConversationId targetLogicalId;
  final String exactParticipantSetFingerprint;
  final String serviceFingerprint;
  final String accountFingerprint;
  final String nominationEvidenceFingerprint;
  final String nominatorFingerprint;

  Map<String, dynamic> get _canonicalJson => <String, dynamic>{
    'candidateFingerprint': candidate.fingerprint,
    'targetLogicalId': targetLogicalId.value,
    'exactParticipantSetFingerprint': exactParticipantSetFingerprint,
    'serviceFingerprint': serviceFingerprint,
    'accountFingerprint': accountFingerprint,
    'nominationEvidenceFingerprint': nominationEvidenceFingerprint,
    'nominatorFingerprint': nominatorFingerprint,
  };

  String get stableFingerprint => _digest('nomination', _canonicalJson);
}

/// Ordered reconciliation evidence. The state machine accepts exactly one
/// reconciliation observation followed by either an independent certificate
/// or a rejection. Equality of participant-set fingerprints is necessary but
/// never sufficient for certification.
class LogicalCandidateEvidence {
  LogicalCandidateEvidence._({
    required this.kind,
    required this.candidate,
    required this.targetLogicalId,
    required this.sequence,
    required String exactParticipantSetFingerprint,
    required String serviceFingerprint,
    required String accountFingerprint,
    required String evidenceFingerprint,
    required String authorityFingerprint,
    String? certificateFingerprint,
  }) : exactParticipantSetFingerprint = _requireFingerprint(
         exactParticipantSetFingerprint,
         'exactParticipantSetFingerprint',
       ),
       serviceFingerprint = _requireFingerprint(serviceFingerprint, 'serviceFingerprint'),
       accountFingerprint = _requireFingerprint(accountFingerprint, 'accountFingerprint'),
       evidenceFingerprint = _requireFingerprint(evidenceFingerprint, 'evidenceFingerprint'),
       authorityFingerprint = _requireFingerprint(authorityFingerprint, 'authorityFingerprint'),
       certificateFingerprint = certificateFingerprint == null
           ? null
           : _requireFingerprint(certificateFingerprint, 'certificateFingerprint') {
    if (!targetLogicalId.isCertified) {
      throw ArgumentError.value(targetLogicalId, 'targetLogicalId', 'must identify a certified conversation');
    }
    if (sequence <= 0) throw ArgumentError.value(sequence, 'sequence', 'must be positive');
    if ((kind == LogicalCandidateEvidenceKind.independentCertificate) != (this.certificateFingerprint != null)) {
      throw ArgumentError('Only independent-certificate evidence may carry a certificate fingerprint');
    }
  }

  factory LogicalCandidateEvidence.reconciliation({
    required PhysicalConversationRef candidate,
    required LogicalConversationId targetLogicalId,
    required int sequence,
    required String exactParticipantSetFingerprint,
    required String serviceFingerprint,
    required String accountFingerprint,
    required String evidenceFingerprint,
    required String authorityFingerprint,
  }) => LogicalCandidateEvidence._(
    kind: LogicalCandidateEvidenceKind.reconciliation,
    candidate: candidate,
    targetLogicalId: targetLogicalId,
    sequence: sequence,
    exactParticipantSetFingerprint: exactParticipantSetFingerprint,
    serviceFingerprint: serviceFingerprint,
    accountFingerprint: accountFingerprint,
    evidenceFingerprint: evidenceFingerprint,
    authorityFingerprint: authorityFingerprint,
  );

  factory LogicalCandidateEvidence.independentCertificate({
    required PhysicalConversationRef candidate,
    required LogicalConversationId targetLogicalId,
    required int sequence,
    required String exactParticipantSetFingerprint,
    required String serviceFingerprint,
    required String accountFingerprint,
    required String evidenceFingerprint,
    required String authorityFingerprint,
    required String certificateFingerprint,
  }) => LogicalCandidateEvidence._(
    kind: LogicalCandidateEvidenceKind.independentCertificate,
    candidate: candidate,
    targetLogicalId: targetLogicalId,
    sequence: sequence,
    exactParticipantSetFingerprint: exactParticipantSetFingerprint,
    serviceFingerprint: serviceFingerprint,
    accountFingerprint: accountFingerprint,
    evidenceFingerprint: evidenceFingerprint,
    authorityFingerprint: authorityFingerprint,
    certificateFingerprint: certificateFingerprint,
  );

  factory LogicalCandidateEvidence.rejection({
    required PhysicalConversationRef candidate,
    required LogicalConversationId targetLogicalId,
    required int sequence,
    required String exactParticipantSetFingerprint,
    required String serviceFingerprint,
    required String accountFingerprint,
    required String evidenceFingerprint,
    required String authorityFingerprint,
  }) => LogicalCandidateEvidence._(
    kind: LogicalCandidateEvidenceKind.rejection,
    candidate: candidate,
    targetLogicalId: targetLogicalId,
    sequence: sequence,
    exactParticipantSetFingerprint: exactParticipantSetFingerprint,
    serviceFingerprint: serviceFingerprint,
    accountFingerprint: accountFingerprint,
    evidenceFingerprint: evidenceFingerprint,
    authorityFingerprint: authorityFingerprint,
  );

  final LogicalCandidateEvidenceKind kind;
  final PhysicalConversationRef candidate;
  final LogicalConversationId targetLogicalId;
  final int sequence;
  final String exactParticipantSetFingerprint;
  final String serviceFingerprint;
  final String accountFingerprint;
  final String evidenceFingerprint;
  final String authorityFingerprint;
  final String? certificateFingerprint;

  Map<String, dynamic> get _canonicalJson => <String, dynamic>{
    'kind': kind.name,
    'candidateFingerprint': candidate.fingerprint,
    'targetLogicalId': targetLogicalId.value,
    'sequence': sequence,
    'exactParticipantSetFingerprint': exactParticipantSetFingerprint,
    'serviceFingerprint': serviceFingerprint,
    'accountFingerprint': accountFingerprint,
    'evidenceFingerprint': evidenceFingerprint,
    'authorityFingerprint': authorityFingerprint,
    'certificateFingerprint': certificateFingerprint,
  };

  String get stableFingerprint => _digest('evidence', _canonicalJson);
}

class LogicalCandidateAcceptedEvidence {
  LogicalCandidateAcceptedEvidence._({
    required this.sequence,
    required this.kind,
    required String stableFingerprint,
    required String sourceEvidenceFingerprint,
    required String authorityFingerprint,
    this.certificateFingerprint,
  }) : stableFingerprint = _requireFingerprint(stableFingerprint, 'accepted evidence fingerprint'),
       sourceEvidenceFingerprint = _requireFingerprint(sourceEvidenceFingerprint, 'source evidence fingerprint'),
       authorityFingerprint = _requireFingerprint(authorityFingerprint, 'accepted evidence authority') {
    if (sequence <= 0) throw const FormatException('Accepted evidence sequence must be positive');
    if (certificateFingerprint != null) {
      _requireFingerprint(certificateFingerprint, 'accepted certificate fingerprint');
    }
    if ((kind == LogicalCandidateEvidenceKind.independentCertificate) != (certificateFingerprint != null)) {
      throw const FormatException('Accepted certificate evidence is inconsistent');
    }
  }

  factory LogicalCandidateAcceptedEvidence.fromEvidence(LogicalCandidateEvidence evidence) =>
      LogicalCandidateAcceptedEvidence._(
        sequence: evidence.sequence,
        kind: evidence.kind,
        stableFingerprint: evidence.stableFingerprint,
        sourceEvidenceFingerprint: evidence.evidenceFingerprint,
        authorityFingerprint: evidence.authorityFingerprint,
        certificateFingerprint: evidence.certificateFingerprint,
      );

  factory LogicalCandidateAcceptedEvidence.fromJson(Map<String, dynamic> json) => LogicalCandidateAcceptedEvidence._(
    sequence: _requireEpoch(json['sequence'], 'accepted evidence sequence'),
    kind: _requireEnum(json['kind'], LogicalCandidateEvidenceKind.values, 'accepted evidence kind'),
    stableFingerprint: _requireFingerprint(json['stableFingerprint'], 'accepted evidence fingerprint'),
    sourceEvidenceFingerprint: _requireFingerprint(json['sourceEvidenceFingerprint'], 'source evidence fingerprint'),
    authorityFingerprint: _requireFingerprint(json['authorityFingerprint'], 'accepted evidence authority'),
    certificateFingerprint: json['certificateFingerprint'] == null
        ? null
        : _requireFingerprint(json['certificateFingerprint'], 'accepted certificate fingerprint'),
  );

  final int sequence;
  final LogicalCandidateEvidenceKind kind;
  final String stableFingerprint;
  final String sourceEvidenceFingerprint;
  final String authorityFingerprint;
  final String? certificateFingerprint;

  bool matches(LogicalCandidateEvidence evidence) =>
      sequence == evidence.sequence && stableFingerprint == evidence.stableFingerprint;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sequence': sequence,
    'kind': kind.name,
    'stableFingerprint': stableFingerprint,
    'sourceEvidenceFingerprint': sourceEvidenceFingerprint,
    'authorityFingerprint': authorityFingerprint,
    'certificateFingerprint': certificateFingerprint,
  };
}

class LogicalCandidateQuarantineRecord {
  LogicalCandidateQuarantineRecord._({
    required this.candidate,
    required this.targetLogicalId,
    required this.exactParticipantSetFingerprint,
    required this.serviceFingerprint,
    required this.accountFingerprint,
    required this.nominationFingerprint,
    required this.nominatorFingerprint,
    required this.phase,
    required this.nominatedAtEpochMs,
    required this.quarantineDeadlineEpochMs,
    required this.lastTransitionAtEpochMs,
    required Iterable<LogicalCandidateAcceptedEvidence> acceptedEvidence,
    this.reconciliationAuthorityFingerprint,
    this.certificateFingerprint,
    this.certificateAuthorityFingerprint,
    this.rejectionReason,
  }) : acceptedEvidence = List<LogicalCandidateAcceptedEvidence>.unmodifiable(acceptedEvidence) {
    _validate();
  }

  factory LogicalCandidateQuarantineRecord._nominated(
    LogicalCandidateNomination nomination, {
    required int nowEpochMs,
    required int quarantineDurationMs,
  }) => LogicalCandidateQuarantineRecord._(
    candidate: nomination.candidate,
    targetLogicalId: nomination.targetLogicalId,
    exactParticipantSetFingerprint: nomination.exactParticipantSetFingerprint,
    serviceFingerprint: nomination.serviceFingerprint,
    accountFingerprint: nomination.accountFingerprint,
    nominationFingerprint: nomination.stableFingerprint,
    nominatorFingerprint: nomination.nominatorFingerprint,
    phase: LogicalCandidateQuarantinePhase.nominated,
    nominatedAtEpochMs: nowEpochMs,
    quarantineDeadlineEpochMs: nowEpochMs + quarantineDurationMs,
    lastTransitionAtEpochMs: nowEpochMs,
    acceptedEvidence: const <LogicalCandidateAcceptedEvidence>[],
  );

  factory LogicalCandidateQuarantineRecord.fromJson(Map<String, dynamic> json) {
    final rawLogicalId = _requireMap(json['targetLogicalId'], 'targetLogicalId');
    final rawCandidate = _requireMap(json['candidate'], 'candidate');
    return LogicalCandidateQuarantineRecord._(
      candidate: PhysicalConversationRef.fromJson(rawCandidate),
      targetLogicalId: LogicalConversationId.fromJson(rawLogicalId),
      exactParticipantSetFingerprint: _requireFingerprint(
        json['exactParticipantSetFingerprint'],
        'exactParticipantSetFingerprint',
      ),
      serviceFingerprint: _requireFingerprint(json['serviceFingerprint'], 'serviceFingerprint'),
      accountFingerprint: _requireFingerprint(json['accountFingerprint'], 'accountFingerprint'),
      nominationFingerprint: _requireFingerprint(json['nominationFingerprint'], 'nominationFingerprint'),
      nominatorFingerprint: _requireFingerprint(json['nominatorFingerprint'], 'nominatorFingerprint'),
      phase: _requireEnum(json['phase'], LogicalCandidateQuarantinePhase.values, 'quarantine phase'),
      nominatedAtEpochMs: _requireEpoch(json['nominatedAtEpochMs'], 'nominatedAtEpochMs'),
      quarantineDeadlineEpochMs: _requireEpoch(json['quarantineDeadlineEpochMs'], 'quarantineDeadlineEpochMs'),
      lastTransitionAtEpochMs: _requireEpoch(json['lastTransitionAtEpochMs'], 'lastTransitionAtEpochMs'),
      acceptedEvidence: _requireList(
        json['acceptedEvidence'],
        'acceptedEvidence',
      ).map((value) => LogicalCandidateAcceptedEvidence.fromJson(_requireMap(value, 'acceptedEvidence item'))),
      reconciliationAuthorityFingerprint: json['reconciliationAuthorityFingerprint'] == null
          ? null
          : _requireFingerprint(json['reconciliationAuthorityFingerprint'], 'reconciliationAuthorityFingerprint'),
      certificateFingerprint: json['certificateFingerprint'] == null
          ? null
          : _requireFingerprint(json['certificateFingerprint'], 'certificateFingerprint'),
      certificateAuthorityFingerprint: json['certificateAuthorityFingerprint'] == null
          ? null
          : _requireFingerprint(json['certificateAuthorityFingerprint'], 'certificateAuthorityFingerprint'),
      rejectionReason: json['rejectionReason'] == null
          ? null
          : _requireEnum(json['rejectionReason'], LogicalCandidateRejectionReason.values, 'rejectionReason'),
    );
  }

  final PhysicalConversationRef candidate;
  final LogicalConversationId targetLogicalId;
  final String exactParticipantSetFingerprint;
  final String serviceFingerprint;
  final String accountFingerprint;
  final String nominationFingerprint;
  final String nominatorFingerprint;
  final LogicalCandidateQuarantinePhase phase;
  final int nominatedAtEpochMs;
  final int quarantineDeadlineEpochMs;
  final int lastTransitionAtEpochMs;
  final List<LogicalCandidateAcceptedEvidence> acceptedEvidence;
  final String? reconciliationAuthorityFingerprint;
  final String? certificateFingerprint;
  final String? certificateAuthorityFingerprint;
  final LogicalCandidateRejectionReason? rejectionReason;

  bool get isTerminal =>
      phase == LogicalCandidateQuarantinePhase.certified ||
      phase == LogicalCandidateQuarantinePhase.rejected ||
      phase == LogicalCandidateQuarantinePhase.expiredVisible;

  bool get canJoinLogicalProjection =>
      phase == LogicalCandidateQuarantinePhase.certified &&
      certificateFingerprint != null &&
      certificateAuthorityFingerprint != null;

  bool mayBeTemporarilySuppressedAt(int nowEpochMs) =>
      !isTerminal && nowEpochMs >= lastTransitionAtEpochMs && nowEpochMs < quarantineDeadlineEpochMs;

  bool mustRemainPhysicallyVisibleAt(int nowEpochMs) =>
      !canJoinLogicalProjection && !mayBeTemporarilySuppressedAt(nowEpochMs);

  bool contextMatches(LogicalCandidateEvidence evidence) =>
      candidate == evidence.candidate &&
      targetLogicalId == evidence.targetLogicalId &&
      exactParticipantSetFingerprint == evidence.exactParticipantSetFingerprint &&
      serviceFingerprint == evidence.serviceFingerprint &&
      accountFingerprint == evidence.accountFingerprint;

  bool nominationMatches(LogicalCandidateNomination nomination) =>
      candidate == nomination.candidate && nominationFingerprint == nomination.stableFingerprint;

  void _validate() {
    if (!targetLogicalId.isCertified) throw const FormatException('Candidate target must be certified');
    _requireFingerprint(exactParticipantSetFingerprint, 'exactParticipantSetFingerprint');
    _requireFingerprint(serviceFingerprint, 'serviceFingerprint');
    _requireFingerprint(accountFingerprint, 'accountFingerprint');
    _requireFingerprint(nominationFingerprint, 'nominationFingerprint');
    _requireFingerprint(nominatorFingerprint, 'nominatorFingerprint');
    if (quarantineDeadlineEpochMs <= nominatedAtEpochMs ||
        quarantineDeadlineEpochMs - nominatedAtEpochMs > LogicalCandidateQuarantineLedger.maxQuarantineDurationMs) {
      throw const FormatException('Candidate quarantine deadline is outside the bounded window');
    }
    if (lastTransitionAtEpochMs < nominatedAtEpochMs) {
      throw const FormatException('Candidate transition time precedes nomination');
    }
    for (var index = 0; index < acceptedEvidence.length; index += 1) {
      if (acceptedEvidence[index].sequence != index + 1) {
        throw const FormatException('Accepted evidence sequence must be contiguous');
      }
    }
    if (acceptedEvidence.map((value) => value.stableFingerprint).toSet().length != acceptedEvidence.length) {
      throw const FormatException('Accepted evidence fingerprints must be unique');
    }
    if (acceptedEvidence.map((value) => value.sourceEvidenceFingerprint).toSet().length != acceptedEvidence.length) {
      throw const FormatException('Source evidence fingerprints must be unique');
    }

    switch (phase) {
      case LogicalCandidateQuarantinePhase.nominated:
        if (acceptedEvidence.isNotEmpty ||
            reconciliationAuthorityFingerprint != null ||
            certificateFingerprint != null ||
            certificateAuthorityFingerprint != null ||
            rejectionReason != null) {
          throw const FormatException('Nominated candidate contains later-phase state');
        }
      case LogicalCandidateQuarantinePhase.reconciling:
        if (acceptedEvidence.length != 1 ||
            acceptedEvidence.single.kind != LogicalCandidateEvidenceKind.reconciliation ||
            reconciliationAuthorityFingerprint != acceptedEvidence.single.authorityFingerprint ||
            certificateFingerprint != null ||
            certificateAuthorityFingerprint != null ||
            rejectionReason != null) {
          throw const FormatException('Reconciling candidate evidence is inconsistent');
        }
      case LogicalCandidateQuarantinePhase.certified:
        if (acceptedEvidence.length != 2 ||
            acceptedEvidence.first.kind != LogicalCandidateEvidenceKind.reconciliation ||
            acceptedEvidence.last.kind != LogicalCandidateEvidenceKind.independentCertificate ||
            reconciliationAuthorityFingerprint != acceptedEvidence.first.authorityFingerprint ||
            certificateFingerprint != acceptedEvidence.last.certificateFingerprint ||
            certificateAuthorityFingerprint != acceptedEvidence.last.authorityFingerprint ||
            certificateAuthorityFingerprint == nominatorFingerprint ||
            certificateAuthorityFingerprint == reconciliationAuthorityFingerprint ||
            rejectionReason != null) {
          throw const FormatException('Certified candidate evidence is inconsistent');
        }
      case LogicalCandidateQuarantinePhase.rejected:
        if (rejectionReason == null || certificateFingerprint != null || certificateAuthorityFingerprint != null) {
          throw const FormatException('Rejected candidate terminal state is inconsistent');
        }
      case LogicalCandidateQuarantinePhase.expiredVisible:
        if (rejectionReason != LogicalCandidateRejectionReason.quarantineExpired ||
            certificateFingerprint != null ||
            certificateAuthorityFingerprint != null) {
          throw const FormatException('Expired candidate terminal state is inconsistent');
        }
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'candidate': candidate.toJson(),
    'targetLogicalId': targetLogicalId.toJson(),
    'exactParticipantSetFingerprint': exactParticipantSetFingerprint,
    'serviceFingerprint': serviceFingerprint,
    'accountFingerprint': accountFingerprint,
    'nominationFingerprint': nominationFingerprint,
    'nominatorFingerprint': nominatorFingerprint,
    'phase': phase.name,
    'nominatedAtEpochMs': nominatedAtEpochMs,
    'quarantineDeadlineEpochMs': quarantineDeadlineEpochMs,
    'lastTransitionAtEpochMs': lastTransitionAtEpochMs,
    'acceptedEvidence': acceptedEvidence.map((value) => value.toJson()).toList(growable: false),
    'reconciliationAuthorityFingerprint': reconciliationAuthorityFingerprint,
    'certificateFingerprint': certificateFingerprint,
    'certificateAuthorityFingerprint': certificateAuthorityFingerprint,
    'rejectionReason': rejectionReason?.name,
  };
}

class LogicalCandidateTransition {
  const LogicalCandidateTransition({required this.disposition, this.record});

  final LogicalCandidateTransitionDisposition disposition;
  final LogicalCandidateQuarantineRecord? record;

  bool get changed =>
      disposition == LogicalCandidateTransitionDisposition.applied ||
      disposition == LogicalCandidateTransitionDisposition.rejectedFailClosed ||
      disposition == LogicalCandidateTransitionDisposition.expiredVisible;
}

/// One phase policy shared by list/search/share projections. Quarantine state
/// never creates read membership: canonical presentation requires the active
/// certificate as an independent input.
enum LogicalCandidatePresentationAdmission { ordinary, suppressPhysical, canonicalLogical, ordinaryReadOnly }

LogicalCandidatePresentationAdmission logicalCandidatePresentationAdmission({
  required LogicalCandidateQuarantinePhase? phase,
  required bool admittedToActiveCertificate,
}) {
  if (admittedToActiveCertificate) {
    return LogicalCandidatePresentationAdmission.canonicalLogical;
  }
  return switch (phase) {
    null => LogicalCandidatePresentationAdmission.ordinary,
    LogicalCandidateQuarantinePhase.nominated ||
    LogicalCandidateQuarantinePhase.reconciling ||
    LogicalCandidateQuarantinePhase.certified => LogicalCandidatePresentationAdmission.suppressPhysical,
    LogicalCandidateQuarantinePhase.rejected ||
    LogicalCandidateQuarantinePhase.expiredVisible => LogicalCandidatePresentationAdmission.ordinaryReadOnly,
  };
}

/// Closes the discovery-to-nomination frame without inventing provider
/// authority. A durable terminal record always wins and releases visibility.
bool shouldSuppressFirstFramePotentialCandidate({
  required bool hasCandidateRecord,
  required bool provenPotentialPredicate,
  required bool targetProjectionAvailable,
}) {
  return !hasCandidateRecord && provenPotentialPredicate && targetProjectionAvailable;
}

/// Physical unread contributes as an ordinary conversation only while it is
/// both uncertified and visible. Certified sources are folded into their
/// logical aggregate; quarantined sources are neither a second row nor a
/// second unread conversation.
bool shouldCountPhysicalUnreadAsOrdinary({required bool certifiedSource, required bool temporarilySuppressed}) =>
    !certifiedSource && !temporarilySuppressed;

/// Candidate targets are application-level typed identities. Comparing their
/// serialized value to a raw certificate ID silently double-wraps identity.
bool logicalCandidateTargets(LogicalCandidateQuarantineRecord record, LogicalConversationId expected) =>
    record.targetLogicalId == expected;

/// A candidate can be hidden only while its bounded quarantine is active and
/// the already-certified target remains available as a visible projection.
/// A certified quarantine record is held through the short durable-activation
/// boundary; only the independently active certificate makes it canonical.
bool shouldTemporarilySuppressLogicalCandidate({
  required LogicalCandidateQuarantineRecord? record,
  required int nowEpochMs,
  required bool targetProjectionAvailable,
  required bool admittedToActiveCertificate,
}) {
  if (record == null || !targetProjectionAvailable) {
    return false;
  }
  final admission = logicalCandidatePresentationAdmission(
    phase: record.phase,
    admittedToActiveCertificate: admittedToActiveCertificate,
  );
  return admission == LogicalCandidatePresentationAdmission.suppressPhysical &&
      (record.phase == LogicalCandidateQuarantinePhase.certified || record.mayBeTemporarilySuppressedAt(nowEpochMs));
}

/// Coalesces read-side requests to persist a materialized quarantine ledger.
///
/// Projection can inspect thousands of chats while one preferences write is
/// pending. Only the request that owns the in-flight fingerprint may complete
/// it, and only an actual durable write may publish transition side effects.
class LogicalCandidatePersistenceCoordinator {
  String? _inFlightFingerprint;

  bool get isBusy => _inFlightFingerprint != null;

  bool request(String fingerprint) {
    if (_inFlightFingerprint != null) return false;
    _inFlightFingerprint = fingerprint;
    return true;
  }

  bool complete(String fingerprint, {required bool wrote}) {
    if (_inFlightFingerprint != fingerprint) return false;
    _inFlightFingerprint = null;
    return wrote;
  }
}

/// Pure, IO-free durable state machine. Callers persist [toJson] atomically and
/// must base all projection decisions on [recordFor] or [recordsAt], both of
/// which materialize the visibility deadline before returning state.
class LogicalCandidateQuarantineLedger {
  LogicalCandidateQuarantineLedger._(this._records);

  factory LogicalCandidateQuarantineLedger.empty() =>
      LogicalCandidateQuarantineLedger._(<PhysicalConversationRef, LogicalCandidateQuarantineRecord>{});

  factory LogicalCandidateQuarantineLedger.fromJson(Map<String, dynamic> json, {required int nowEpochMs}) {
    _requireEpoch(nowEpochMs, 'nowEpochMs');
    if (json['schema'] != logicalCandidateQuarantineSchema) {
      throw const FormatException('Unsupported logical candidate quarantine schema');
    }
    final rawRecords = _requireList(json['records'], 'records');
    if (rawRecords.length > maxRecords) throw const FormatException('Logical candidate quarantine is oversized');
    final records = <PhysicalConversationRef, LogicalCandidateQuarantineRecord>{};
    for (final value in rawRecords) {
      final record = LogicalCandidateQuarantineRecord.fromJson(_requireMap(value, 'record'));
      if (records.putIfAbsent(record.candidate, () => record) != record) {
        throw const FormatException('Duplicate logical candidate record');
      }
    }
    final ledger = LogicalCandidateQuarantineLedger._(records);
    ledger._advanceAll(nowEpochMs);
    return ledger;
  }

  static const int maxRecords = 4096;
  static const int maxQuarantineDurationMs = Duration.millisecondsPerDay;

  final Map<PhysicalConversationRef, LogicalCandidateQuarantineRecord> _records;

  LogicalCandidateTransition nominate(
    LogicalCandidateNomination nomination, {
    required int nowEpochMs,
    required int quarantineDurationMs,
  }) {
    _requireEpoch(nowEpochMs, 'nowEpochMs');
    if (quarantineDurationMs <= 0 || quarantineDurationMs > maxQuarantineDurationMs) {
      throw ArgumentError.value(
        quarantineDurationMs,
        'quarantineDurationMs',
        'must be within 1 and $maxQuarantineDurationMs',
      );
    }

    var current = _records[nomination.candidate];
    if (current == null) {
      if (_records.length >= maxRecords) {
        return const LogicalCandidateTransition(
          disposition: LogicalCandidateTransitionDisposition.capacityRejectedVisible,
        );
      }
      final created = LogicalCandidateQuarantineRecord._nominated(
        nomination,
        nowEpochMs: nowEpochMs,
        quarantineDurationMs: quarantineDurationMs,
      );
      _records[nomination.candidate] = created;
      return LogicalCandidateTransition(disposition: LogicalCandidateTransitionDisposition.applied, record: created);
    }

    final previousPhase = current.phase;
    current = _materialize(current, nowEpochMs);
    if (current.phase != previousPhase) {
      return LogicalCandidateTransition(
        disposition: current.phase == LogicalCandidateQuarantinePhase.expiredVisible
            ? LogicalCandidateTransitionDisposition.expiredVisible
            : LogicalCandidateTransitionDisposition.rejectedFailClosed,
        record: current,
      );
    }
    if (current.nominationMatches(nomination)) {
      return LogicalCandidateTransition(
        disposition: LogicalCandidateTransitionDisposition.duplicateIgnored,
        record: current,
      );
    }
    if (current.isTerminal) {
      return LogicalCandidateTransition(
        disposition: LogicalCandidateTransitionDisposition.terminalIgnored,
        record: current,
      );
    }
    return _reject(current, LogicalCandidateRejectionReason.nominationConflict, nowEpochMs);
  }

  LogicalCandidateTransition applyEvidence(LogicalCandidateEvidence evidence, {required int nowEpochMs}) {
    _requireEpoch(nowEpochMs, 'nowEpochMs');
    var current = _records[evidence.candidate];
    if (current == null) {
      return const LogicalCandidateTransition(
        disposition: LogicalCandidateTransitionDisposition.unknownCandidateVisible,
      );
    }
    final previousPhase = current.phase;
    current = _materialize(current, nowEpochMs);
    if (current.phase != previousPhase) {
      return LogicalCandidateTransition(
        disposition: current.phase == LogicalCandidateQuarantinePhase.expiredVisible
            ? LogicalCandidateTransitionDisposition.expiredVisible
            : LogicalCandidateTransitionDisposition.rejectedFailClosed,
        record: current,
      );
    }

    final alreadyAccepted = current.acceptedEvidence
        .where((accepted) => accepted.sequence == evidence.sequence)
        .firstOrNull;
    if (alreadyAccepted?.matches(evidence) == true) {
      return LogicalCandidateTransition(
        disposition: LogicalCandidateTransitionDisposition.duplicateIgnored,
        record: current,
      );
    }
    if (current.isTerminal) {
      return LogicalCandidateTransition(
        disposition: LogicalCandidateTransitionDisposition.terminalIgnored,
        record: current,
      );
    }
    if (!current.contextMatches(evidence)) {
      return _reject(current, LogicalCandidateRejectionReason.evidenceContextMismatch, nowEpochMs);
    }
    if (current.acceptedEvidence.any(
      (accepted) => accepted.sourceEvidenceFingerprint == evidence.evidenceFingerprint,
    )) {
      return _reject(current, LogicalCandidateRejectionReason.evidenceSequenceConflict, nowEpochMs);
    }
    if (evidence.sequence <= current.acceptedEvidence.length) {
      return _reject(current, LogicalCandidateRejectionReason.evidenceSequenceConflict, nowEpochMs);
    }
    if (evidence.sequence != current.acceptedEvidence.length + 1) {
      return _reject(current, LogicalCandidateRejectionReason.evidenceOutOfOrder, nowEpochMs);
    }

    final accepted = <LogicalCandidateAcceptedEvidence>[
      ...current.acceptedEvidence,
      LogicalCandidateAcceptedEvidence.fromEvidence(evidence),
    ];
    if (evidence.kind == LogicalCandidateEvidenceKind.rejection) {
      final rejected = LogicalCandidateQuarantineRecord._(
        candidate: current.candidate,
        targetLogicalId: current.targetLogicalId,
        exactParticipantSetFingerprint: current.exactParticipantSetFingerprint,
        serviceFingerprint: current.serviceFingerprint,
        accountFingerprint: current.accountFingerprint,
        nominationFingerprint: current.nominationFingerprint,
        nominatorFingerprint: current.nominatorFingerprint,
        phase: LogicalCandidateQuarantinePhase.rejected,
        nominatedAtEpochMs: current.nominatedAtEpochMs,
        quarantineDeadlineEpochMs: current.quarantineDeadlineEpochMs,
        lastTransitionAtEpochMs: nowEpochMs,
        acceptedEvidence: accepted,
        reconciliationAuthorityFingerprint: current.reconciliationAuthorityFingerprint,
        rejectionReason: LogicalCandidateRejectionReason.independentEvidenceRejected,
      );
      _records[current.candidate] = rejected;
      return LogicalCandidateTransition(disposition: LogicalCandidateTransitionDisposition.applied, record: rejected);
    }

    if (current.phase == LogicalCandidateQuarantinePhase.nominated) {
      if (evidence.kind != LogicalCandidateEvidenceKind.reconciliation) {
        return _reject(current, LogicalCandidateRejectionReason.evidenceOutOfOrder, nowEpochMs);
      }
      final reconciling = LogicalCandidateQuarantineRecord._(
        candidate: current.candidate,
        targetLogicalId: current.targetLogicalId,
        exactParticipantSetFingerprint: current.exactParticipantSetFingerprint,
        serviceFingerprint: current.serviceFingerprint,
        accountFingerprint: current.accountFingerprint,
        nominationFingerprint: current.nominationFingerprint,
        nominatorFingerprint: current.nominatorFingerprint,
        phase: LogicalCandidateQuarantinePhase.reconciling,
        nominatedAtEpochMs: current.nominatedAtEpochMs,
        quarantineDeadlineEpochMs: current.quarantineDeadlineEpochMs,
        lastTransitionAtEpochMs: nowEpochMs,
        acceptedEvidence: accepted,
        reconciliationAuthorityFingerprint: evidence.authorityFingerprint,
      );
      _records[current.candidate] = reconciling;
      return LogicalCandidateTransition(
        disposition: LogicalCandidateTransitionDisposition.applied,
        record: reconciling,
      );
    }

    if (current.phase != LogicalCandidateQuarantinePhase.reconciling ||
        evidence.kind != LogicalCandidateEvidenceKind.independentCertificate) {
      return _reject(current, LogicalCandidateRejectionReason.evidenceOutOfOrder, nowEpochMs);
    }
    if (evidence.authorityFingerprint == current.nominatorFingerprint ||
        evidence.authorityFingerprint == current.reconciliationAuthorityFingerprint) {
      return _reject(current, LogicalCandidateRejectionReason.nonIndependentCertificate, nowEpochMs);
    }
    final certified = LogicalCandidateQuarantineRecord._(
      candidate: current.candidate,
      targetLogicalId: current.targetLogicalId,
      exactParticipantSetFingerprint: current.exactParticipantSetFingerprint,
      serviceFingerprint: current.serviceFingerprint,
      accountFingerprint: current.accountFingerprint,
      nominationFingerprint: current.nominationFingerprint,
      nominatorFingerprint: current.nominatorFingerprint,
      phase: LogicalCandidateQuarantinePhase.certified,
      nominatedAtEpochMs: current.nominatedAtEpochMs,
      quarantineDeadlineEpochMs: current.quarantineDeadlineEpochMs,
      lastTransitionAtEpochMs: nowEpochMs,
      acceptedEvidence: accepted,
      reconciliationAuthorityFingerprint: current.reconciliationAuthorityFingerprint,
      certificateFingerprint: evidence.certificateFingerprint,
      certificateAuthorityFingerprint: evidence.authorityFingerprint,
    );
    _records[current.candidate] = certified;
    return LogicalCandidateTransition(disposition: LogicalCandidateTransitionDisposition.applied, record: certified);
  }

  LogicalCandidateQuarantineRecord? recordFor(PhysicalConversationRef candidate, {required int nowEpochMs}) {
    _requireEpoch(nowEpochMs, 'nowEpochMs');
    final current = _records[candidate];
    return current == null ? null : _materialize(current, nowEpochMs);
  }

  List<LogicalCandidateQuarantineRecord> recordsAt({required int nowEpochMs}) {
    _requireEpoch(nowEpochMs, 'nowEpochMs');
    _advanceAll(nowEpochMs);
    return List<LogicalCandidateQuarantineRecord>.unmodifiable(
      _records.values.toList(growable: false)..sort((left, right) => left.candidate.compareTo(right.candidate)),
    );
  }

  Map<String, dynamic> toJson({required int nowEpochMs}) => <String, dynamic>{
    'schema': logicalCandidateQuarantineSchema,
    'records': recordsAt(nowEpochMs: nowEpochMs).map((record) => record.toJson()).toList(growable: false),
  };

  String stableFingerprintAt({required int nowEpochMs}) =>
      sha256.convert(utf8.encode(jsonEncode(toJson(nowEpochMs: nowEpochMs)))).toString();

  void _advanceAll(int nowEpochMs) {
    for (final record in _records.values.toList(growable: false)) {
      _materialize(record, nowEpochMs);
    }
  }

  LogicalCandidateQuarantineRecord _materialize(LogicalCandidateQuarantineRecord record, int nowEpochMs) {
    if (record.isTerminal) return record;
    if (nowEpochMs < record.lastTransitionAtEpochMs) {
      return _reject(record, LogicalCandidateRejectionReason.clockRegression, record.lastTransitionAtEpochMs).record!;
    }
    if (nowEpochMs >= record.quarantineDeadlineEpochMs) {
      final expired = LogicalCandidateQuarantineRecord._(
        candidate: record.candidate,
        targetLogicalId: record.targetLogicalId,
        exactParticipantSetFingerprint: record.exactParticipantSetFingerprint,
        serviceFingerprint: record.serviceFingerprint,
        accountFingerprint: record.accountFingerprint,
        nominationFingerprint: record.nominationFingerprint,
        nominatorFingerprint: record.nominatorFingerprint,
        phase: LogicalCandidateQuarantinePhase.expiredVisible,
        nominatedAtEpochMs: record.nominatedAtEpochMs,
        quarantineDeadlineEpochMs: record.quarantineDeadlineEpochMs,
        lastTransitionAtEpochMs: record.quarantineDeadlineEpochMs,
        acceptedEvidence: record.acceptedEvidence,
        reconciliationAuthorityFingerprint: record.reconciliationAuthorityFingerprint,
        rejectionReason: LogicalCandidateRejectionReason.quarantineExpired,
      );
      _records[record.candidate] = expired;
      return expired;
    }
    return record;
  }

  LogicalCandidateTransition _reject(
    LogicalCandidateQuarantineRecord record,
    LogicalCandidateRejectionReason reason,
    int nowEpochMs,
  ) {
    final rejected = LogicalCandidateQuarantineRecord._(
      candidate: record.candidate,
      targetLogicalId: record.targetLogicalId,
      exactParticipantSetFingerprint: record.exactParticipantSetFingerprint,
      serviceFingerprint: record.serviceFingerprint,
      accountFingerprint: record.accountFingerprint,
      nominationFingerprint: record.nominationFingerprint,
      nominatorFingerprint: record.nominatorFingerprint,
      phase: LogicalCandidateQuarantinePhase.rejected,
      nominatedAtEpochMs: record.nominatedAtEpochMs,
      quarantineDeadlineEpochMs: record.quarantineDeadlineEpochMs,
      lastTransitionAtEpochMs: nowEpochMs < record.lastTransitionAtEpochMs
          ? record.lastTransitionAtEpochMs
          : nowEpochMs,
      acceptedEvidence: record.acceptedEvidence,
      reconciliationAuthorityFingerprint: record.reconciliationAuthorityFingerprint,
      rejectionReason: reason,
    );
    _records[record.candidate] = rejected;
    return LogicalCandidateTransition(
      disposition: LogicalCandidateTransitionDisposition.rejectedFailClosed,
      record: rejected,
    );
  }
}
