import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

const logicalConversationOutboundRouteSchema = 'LOGICAL_CONVERSATION_OUTBOUND_ROUTE_V3_GENERATION_PROVENANCE';
const logicalExecutionGenerationCertificateSchema = 'LOGICAL_EXECUTION_GENERATION_CERTIFICATE_V1';

enum LogicalMutationClass { newMessage, reply, reaction, attachment, markRead, unsupported }

enum LogicalRouteState { qualified, routeNotProven }

enum LogicalRouteRuntimeStage { unchecked, checking, qualified, routeNotProven }

class LogicalRouteRuntimeStatus {
  const LogicalRouteRuntimeStatus({required this.stage, required this.reason, this.targetRowId});

  const LogicalRouteRuntimeStatus.unchecked()
    : this(stage: LogicalRouteRuntimeStage.unchecked, reason: 'ROUTE_NOT_CHECKED');

  const LogicalRouteRuntimeStatus.checking()
    : this(stage: LogicalRouteRuntimeStage.checking, reason: 'CHECKING_CURRENT_ROUTE_EVIDENCE');

  final LogicalRouteRuntimeStage stage;
  final String reason;
  final int? targetRowId;

  bool get isQualified => stage == LogicalRouteRuntimeStage.qualified && targetRowId != null;
}

class LogicalAddressEvidence {
  const LogicalAddressEvidence({required this.address, this.country});

  final String address;
  final String? country;
}

class LogicalSuccessfulOutboundEvidence {
  const LogicalSuccessfulOutboundEvidence({
    required this.messageGuid,
    required this.messageRowId,
    required this.createdAtEpoch,
  });

  final String messageGuid;
  final int messageRowId;
  final int createdAtEpoch;
}

class LogicalRouteMessageEvidence {
  const LogicalRouteMessageEvidence({
    required this.messageGuid,
    required this.messageRowId,
    required this.createdAtEpoch,
    required this.isFromMe,
    required this.error,
    required this.itemType,
    this.associatedMessageGuid,
  });

  final String messageGuid;
  final int messageRowId;
  final int createdAtEpoch;
  final bool isFromMe;
  final int error;
  final int itemType;
  final String? associatedMessageGuid;

  bool get isNormal => itemType == 0 && (associatedMessageGuid == null || associatedMessageGuid!.isEmpty);

  bool get isSuccessfulOutbound => isNormal && isFromMe && error == 0;

  bool get isInboundNormal => isNormal && !isFromMe;
}

/// A separately admitted write certificate. It describes observable generation
/// facts and never names a physical ROWID. The current physical route must be
/// re-derived from a fresh, complete runtime snapshot before every execution.
class LogicalExecutionGenerationCertificate {
  const LogicalExecutionGenerationCertificate({
    required this.schema,
    required this.logicalId,
    required this.evidenceReceiptCommit,
    required this.currentService,
    required this.predecessorService,
    required this.expectedCurrentMemberCount,
    required this.expectedPredecessorMemberCount,
    required this.authorizedOutboundGuidSha256,
    required this.maximumTransitionEdgeDelayMilliseconds,
    required this.maximumNaturalResponseDelayMilliseconds,
    required this.explanation,
  });

  final String schema;
  final String logicalId;
  final String evidenceReceiptCommit;
  final String currentService;
  final String predecessorService;
  final int expectedCurrentMemberCount;
  final int expectedPredecessorMemberCount;
  final String authorizedOutboundGuidSha256;
  final int maximumTransitionEdgeDelayMilliseconds;
  final int maximumNaturalResponseDelayMilliseconds;
  final String explanation;

  bool get isValid =>
      schema == logicalExecutionGenerationCertificateSchema &&
      logicalId.isNotEmpty &&
      RegExp(r'^[0-9a-f]{40}$').hasMatch(evidenceReceiptCommit) &&
      currentService.isNotEmpty &&
      predecessorService.isNotEmpty &&
      currentService != predecessorService &&
      expectedCurrentMemberCount > 0 &&
      expectedPredecessorMemberCount > 0 &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(authorizedOutboundGuidSha256) &&
      maximumTransitionEdgeDelayMilliseconds > 0 &&
      maximumNaturalResponseDelayMilliseconds > 0 &&
      explanation.isNotEmpty;
}

class LogicalRouteCandidateEvidence {
  const LogicalRouteCandidateEvidence({
    required this.sourceChatRowId,
    required this.sourceChatGuid,
    required this.sourceService,
    required this.chatIdentifier,
    required this.style,
    required this.lastAddressedHandle,
    required this.participants,
    required this.chatSnapshotComplete,
    required this.messageSnapshotComplete,
    required this.lastKnownHybridState,
    required this.shouldForceToSms,
    required this.lastSeenMessageGuid,
    required this.groupPhotoGuid,
    required this.messages,
    required this.successfulOutbounds,
  });

  final int sourceChatRowId;
  final String sourceChatGuid;
  final String sourceService;
  final String chatIdentifier;
  final int style;
  final LogicalAddressEvidence lastAddressedHandle;
  final List<LogicalAddressEvidence> participants;
  final bool chatSnapshotComplete;
  final bool messageSnapshotComplete;
  final bool? lastKnownHybridState;
  final bool? shouldForceToSms;
  final String? lastSeenMessageGuid;
  final String? groupPhotoGuid;
  final List<LogicalRouteMessageEvidence> messages;
  final List<LogicalSuccessfulOutboundEvidence> successfulOutbounds;
}

class LogicalRouteEvidence {
  const LogicalRouteEvidence({
    required this.logicalId,
    required this.certificateId,
    required this.certifiedSourceChatGuids,
    required this.backendComputerId,
    required this.detectedIMessage,
    required this.privateApiConnected,
    required this.helperConnected,
    required this.accountSnapshotBeforeSha256,
    required this.accountSnapshotAfterSha256,
    required this.activeSelfAlias,
    required this.vettedSelfAliases,
    required this.executionGenerationCertificate,
    required this.candidateScopeSnapshotComplete,
    required this.unadmittedPotentialSourceChatGuids,
    required this.candidates,
  });

  final String logicalId;
  final String? certificateId;
  final Map<int, String> certifiedSourceChatGuids;
  final String backendComputerId;
  final bool detectedIMessage;
  final bool privateApiConnected;
  final bool helperConnected;
  final String accountSnapshotBeforeSha256;
  final String accountSnapshotAfterSha256;
  final LogicalAddressEvidence activeSelfAlias;
  final List<LogicalAddressEvidence> vettedSelfAliases;
  final LogicalExecutionGenerationCertificate? executionGenerationCertificate;
  final bool candidateScopeSnapshotComplete;
  final Map<int, String> unadmittedPotentialSourceChatGuids;
  final List<LogicalRouteCandidateEvidence> candidates;
}

class LogicalMutationRequest {
  const LogicalMutationRequest({
    required this.mutationClass,
    this.targetMessageGuid,
    this.targetSourceChatRowId,
    this.targetSourceChatGuid,
    this.persistedExecutionSourceChatRowId,
    this.persistedExecutionSourceChatGuid,
    this.isRetry = false,
    this.unreadSourceChatRowIds = const <int>{},
  });

  final LogicalMutationClass mutationClass;
  final String? targetMessageGuid;
  final int? targetSourceChatRowId;
  final String? targetSourceChatGuid;
  final int? persistedExecutionSourceChatRowId;
  final String? persistedExecutionSourceChatGuid;
  final bool isRetry;
  final Set<int> unreadSourceChatRowIds;
}

class LogicalRouteDecision {
  const LogicalRouteDecision._({required this.state, required this.reason, required this.physicalTargetRowIds});

  const LogicalRouteDecision.qualified(String reason, List<int> targets)
    : this._(state: LogicalRouteState.qualified, reason: reason, physicalTargetRowIds: targets);

  const LogicalRouteDecision.notProven(String reason)
    : this._(state: LogicalRouteState.routeNotProven, reason: reason, physicalTargetRowIds: const <int>[]);

  final LogicalRouteState state;
  final String reason;
  final List<int> physicalTargetRowIds;

  bool get isQualified => state == LogicalRouteState.qualified;
  bool get isSingleTarget => isQualified && physicalTargetRowIds.length == 1;
}

class _LogicalGenerationQualification {
  const _LogicalGenerationQualification._({
    required this.isQualified,
    required this.reason,
    this.currentCandidates = const [],
  });

  const _LogicalGenerationQualification.qualified(List<LogicalRouteCandidateEvidence> candidates)
    : this._(isQualified: true, reason: 'CURRENT_EXECUTION_GENERATION_PROVEN', currentCandidates: candidates);

  const _LogicalGenerationQualification.notProven(String reason) : this._(isQualified: false, reason: reason);

  final bool isQualified;
  final String reason;
  final List<LogicalRouteCandidateEvidence> currentCandidates;
}

/// Generic writable-source qualification for an already-certified logical
/// read union.
///
/// The read certificate supplies only current member bindings. It never names
/// a writable member. This policy derives one writable member from current,
/// typed account and participant evidence plus successful source provenance.
class LogicalConversationOutboundRoutePolicy {
  LogicalConversationOutboundRoutePolicy._();

  static const comcastNodeUpdatesGeneration = LogicalExecutionGenerationCertificate(
    schema: logicalExecutionGenerationCertificateSchema,
    logicalId: 'LGC_V2_377f996e2dfd452ac69370dadda3aaf185c6714a0bda48af92faf8f55282424a',
    evidenceReceiptCommit: '272fb442c343665459957eaf52b6e61411dd7e3e',
    currentService: 'SMS',
    predecessorService: 'iMessage',
    expectedCurrentMemberCount: 2,
    expectedPredecessorMemberCount: 1,
    authorizedOutboundGuidSha256: '7b0b32bebfa9a6a4811d19f7a33a7a6cc451a015b5d2a0ba8118eba97542f649',
    maximumTransitionEdgeDelayMilliseconds: 60 * 1000,
    maximumNaturalResponseDelayMilliseconds: 15 * 60 * 1000,
    explanation:
        'Apple chat properties and message account/service provenance establish an iMessage-to-SMS generation '
        'succession. A terminal cross-generation reaction, the independently authorized outbound, its natural '
        'response, and post-cutover last-seen pointers admit only the current SMS generation for execution.',
  );

  static LogicalRouteDecision resolve(LogicalRouteEvidence evidence, LogicalMutationRequest request) {
    final sourceQualification = _qualifyCertifiedSources(evidence);
    if (!sourceQualification.isQualified) return sourceQualification;
    final byRow = {for (final candidate in evidence.candidates) candidate.sourceChatRowId: candidate};
    switch (request.mutationClass) {
      case LogicalMutationClass.newMessage:
        return _qualifyWritableSource(evidence);
      case LogicalMutationClass.reply:
      case LogicalMutationClass.reaction:
        return _targetMessageRoute(byRow, request);
      case LogicalMutationClass.attachment:
        if (request.targetMessageGuid != null) {
          return _targetMessageRoute(byRow, request);
        }
        if (request.persistedExecutionSourceChatRowId != null || request.persistedExecutionSourceChatGuid != null) {
          if (!request.isRetry) {
            return const LogicalRouteDecision.notProven('UNTRUSTED_ATTACHMENT_EXECUTION_HINT');
          }
          return _persistedExecutionRoute(byRow, request);
        }
        final qualification = _qualifyWritableSource(evidence);
        if (!qualification.isSingleTarget) return qualification;
        return LogicalRouteDecision.qualified(
          'CURRENT_PROVENANCE_ATTACHMENT_SOURCE',
          qualification.physicalTargetRowIds,
        );
      case LogicalMutationClass.markRead:
        if (request.unreadSourceChatRowIds.any((rowId) => !byRow.containsKey(rowId))) {
          return const LogicalRouteDecision.notProven('UNREAD_SOURCE_OUTSIDE_CERTIFICATE');
        }
        final targets = request.unreadSourceChatRowIds.toList()..sort();
        return LogicalRouteDecision.qualified(
          targets.isEmpty ? 'ALREADY_READ_NO_MUTATION_REQUIRED' : 'CERTIFIED_MINIMUM_UNREAD_SOURCE_SET',
          targets,
        );
      case LogicalMutationClass.unsupported:
        return const LogicalRouteDecision.notProven('UNSUPPORTED_LOGICAL_MUTATION');
    }
  }

  /// Conservative typed normalization used only for equality and set
  /// membership. Opaque identities remain unqualified instead of being
  /// coalesced heuristically.
  static String? normalizeRoutableAddress(LogicalAddressEvidence evidence) {
    var value = evidence.address.trim();
    if (value.isEmpty) return null;
    final lower = value.toLowerCase();
    if (lower.startsWith('tel:')) {
      value = value.substring(4);
    } else if (lower.startsWith('mailto:')) {
      value = value.substring(7);
    }

    final email = RegExp(r'^[^\s@:]+@[^\s@:]+\.[^\s@:]+$');
    if (email.hasMatch(value)) return 'EMAIL:${value.toLowerCase()}';

    if (!RegExp(r'^\+?[0-9 () .-]+$').hasMatch(value)) return null;
    final digits = value.replaceAll(RegExp(r'\D'), '');
    String? national;
    if (digits.length == 11 && digits.startsWith('1')) {
      national = digits.substring(1);
    } else {
      final country = evidence.country?.toUpperCase();
      if (digits.length == 10 &&
          !value.startsWith('+') &&
          (country == null || country.isEmpty || country == 'US' || country == 'USA')) {
        national = digits;
      }
    }
    if (national != null && RegExp(r'^[2-9][0-9]{2}[2-9][0-9]{6}$').hasMatch(national)) {
      return 'PHONE:+1$national';
    }
    if (value.startsWith('+') && !digits.startsWith('1') && RegExp(r'^[1-9][0-9]{7,14}$').hasMatch(digits)) {
      return 'PHONE:+$digits';
    }
    return null;
  }

  static LogicalRouteDecision _qualifyWritableSource(LogicalRouteEvidence evidence) {
    final sourceQualification = _qualifyCertifiedSources(evidence);
    if (!sourceQualification.isQualified) return sourceQualification;

    final vettedAliases = evidence.vettedSelfAliases.map(normalizeRoutableAddress).whereType<String>().toSet();
    final selfMembershipByRow = <int, Set<String>>{};
    for (final candidate in evidence.candidates) {
      final participants = candidate.participants.map(normalizeRoutableAddress).whereType<String>().toSet();
      selfMembershipByRow[candidate.sourceChatRowId] = participants.intersection(vettedAliases);
    }

    var routeCandidates = evidence.candidates;
    if (evidence.executionGenerationCertificate != null) {
      final generation = _qualifyExecutionGeneration(evidence, selfMembershipByRow);
      if (!generation.isQualified) {
        return LogicalRouteDecision.notProven(generation.reason);
      }
      routeCandidates = generation.currentCandidates;
    }

    final writable = routeCandidates
        .where((candidate) => selfMembershipByRow[candidate.sourceChatRowId]!.isEmpty)
        .toList();
    if (writable.length != 1) {
      if (routeCandidates.length > 2 && writable.length > 1) {
        return const LogicalRouteDecision.notProven('ROUTE_NOT_PROVEN_EXPANDED_SET_AMBIGUOUS');
      }
      return const LogicalRouteDecision.notProven('AMBIGUOUS_WRITE_ELIGIBLE_SOURCE');
    }
    final selected = writable.single;
    if (selected.successfulOutbounds.isEmpty) {
      return const LogicalRouteDecision.notProven('NO_SUCCESSFUL_WRITABLE_SOURCE_PROVENANCE');
    }
    final selectedLatest = selected.successfulOutbounds
        .map((outbound) => outbound.createdAtEpoch)
        .reduce((a, b) => a > b ? a : b);
    final otherDates = routeCandidates
        .where((candidate) => candidate.sourceChatRowId != selected.sourceChatRowId)
        .expand((candidate) => candidate.successfulOutbounds)
        .map((outbound) => outbound.createdAtEpoch)
        .toList();
    if (otherDates.isNotEmpty && selectedLatest <= otherDates.reduce((a, b) => a > b ? a : b)) {
      return const LogicalRouteDecision.notProven('CURRENT_OUTBOUND_PROVENANCE_CONTRADICTION');
    }

    return LogicalRouteDecision.qualified(
      evidence.executionGenerationCertificate == null
          ? 'UNIQUE_CURRENT_PROVENANCE_WRITABLE_SOURCE'
          : 'CURRENT_EXECUTION_GENERATION_PROVEN_UNIQUE_WRITABLE_SOURCE',
      [selected.sourceChatRowId],
    );
  }

  static _LogicalGenerationQualification _qualifyExecutionGeneration(
    LogicalRouteEvidence evidence,
    Map<int, Set<String>> selfMembershipByRow,
  ) {
    final certificate = evidence.executionGenerationCertificate;
    if (certificate == null || !certificate.isValid || certificate.logicalId != evidence.logicalId) {
      return const _LogicalGenerationQualification.notProven('EXECUTION_GENERATION_CERTIFICATE_INVALID');
    }
    if (!evidence.candidateScopeSnapshotComplete) {
      return const _LogicalGenerationQualification.notProven('POTENTIAL_EXECUTION_CANDIDATE_SCOPE_UNSTABLE');
    }
    if (evidence.unadmittedPotentialSourceChatGuids.isNotEmpty) {
      return const _LogicalGenerationQualification.notProven('UNADMITTED_POTENTIAL_EXECUTION_GENERATION_PRESENT');
    }

    final current = <LogicalRouteCandidateEvidence>[];
    final predecessor = <LogicalRouteCandidateEvidence>[];
    for (final candidate in evidence.candidates) {
      if (!candidate.chatSnapshotComplete) {
        return const _LogicalGenerationQualification.notProven('CURRENT_CHAT_PROPERTIES_SNAPSHOT_UNSTABLE');
      }
      if (candidate.shouldForceToSms != false) {
        return const _LogicalGenerationQualification.notProven('CURRENT_PROVIDER_FORCE_SMS_STATE_CONTRADICTION');
      }
      if (candidate.sourceService == certificate.currentService && candidate.lastKnownHybridState == true) {
        current.add(candidate);
      } else if (candidate.sourceService == certificate.predecessorService && candidate.lastKnownHybridState == null) {
        predecessor.add(candidate);
      } else {
        return const _LogicalGenerationQualification.notProven('UNCLASSIFIED_EXECUTION_GENERATION_MEMBER');
      }
    }
    if (current.length != certificate.expectedCurrentMemberCount ||
        predecessor.length != certificate.expectedPredecessorMemberCount) {
      return const _LogicalGenerationQualification.notProven('EXECUTION_GENERATION_MEMBER_SCOPE_CHANGED');
    }

    final predecessorCandidate = predecessor.single;
    final predecessorNormals = predecessorCandidate.messages.where((message) => message.isNormal).toList();
    if (predecessorNormals.isEmpty) {
      return const _LogicalGenerationQualification.notProven('PREDECESSOR_NORMAL_HISTORY_MISSING');
    }
    predecessorNormals.sort(_compareMessageChronology);
    final terminalPredecessorMessage = predecessorNormals.last;
    if (!terminalPredecessorMessage.isSuccessfulOutbound ||
        predecessorCandidate.lastSeenMessageGuid != terminalPredecessorMessage.messageGuid) {
      return const _LogicalGenerationQualification.notProven('PREDECESSOR_TERMINAL_POINTER_CONTRADICTION');
    }

    final transitionSources = <LogicalRouteCandidateEvidence>{};
    for (final candidate in current) {
      for (final message in candidate.messages) {
        if (_normalizedRelationshipTarget(message.associatedMessageGuid) !=
            terminalPredecessorMessage.messageGuid.toUpperCase()) {
          continue;
        }
        final delay = message.createdAtEpoch - terminalPredecessorMessage.createdAtEpoch;
        if (delay >= 0 && delay <= certificate.maximumTransitionEdgeDelayMilliseconds) {
          transitionSources.add(candidate);
        }
      }
    }
    if (transitionSources.length != 1) {
      return const _LogicalGenerationQualification.notProven('TERMINAL_GENERATION_HANDOFF_EDGE_NOT_UNIQUE');
    }
    final transitionSource = transitionSources.single;
    if (selfMembershipByRow[transitionSource.sourceChatRowId]?.isNotEmpty != false) {
      return const _LogicalGenerationQualification.notProven('GENERATION_HANDOFF_SOURCE_NOT_WRITABLE');
    }
    if (transitionSource.groupPhotoGuid == null ||
        transitionSource.groupPhotoGuid!.isEmpty ||
        transitionSource.groupPhotoGuid != predecessorCandidate.groupPhotoGuid) {
      return const _LogicalGenerationQualification.notProven('GENERATION_GROUP_IDENTITY_LINEAGE_CONTRADICTION');
    }

    for (final candidate in current) {
      final postTransitionNormals = candidate.messages.where(
        (message) => message.isNormal && message.createdAtEpoch > terminalPredecessorMessage.createdAtEpoch,
      );
      if (postTransitionNormals.isEmpty) {
        return const _LogicalGenerationQualification.notProven('CURRENT_GENERATION_CONTINUITY_INCOMPLETE');
      }
      final lastSeenGuid = candidate.lastSeenMessageGuid;
      final lastSeen = candidate.messages.where((message) => message.messageGuid == lastSeenGuid).toList();
      if (lastSeen.length != 1 ||
          lastSeen.single.itemType != 0 ||
          lastSeen.single.createdAtEpoch <= terminalPredecessorMessage.createdAtEpoch) {
        return const _LogicalGenerationQualification.notProven('CURRENT_GENERATION_LAST_SEEN_POINTER_CONTRADICTION');
      }
    }

    final anchored = <({LogicalRouteCandidateEvidence candidate, LogicalRouteMessageEvidence message})>[];
    for (final candidate in current) {
      for (final message in candidate.messages.where((message) => message.isSuccessfulOutbound)) {
        if (_anchorFingerprint(message.messageGuid) == certificate.authorizedOutboundGuidSha256) {
          anchored.add((candidate: candidate, message: message));
        }
      }
    }
    if (anchored.length != 1 || anchored.single.candidate.sourceChatRowId != transitionSource.sourceChatRowId) {
      return const _LogicalGenerationQualification.notProven('AUTHORIZED_OUTBOUND_GENERATION_ANCHOR_MISSING');
    }
    final anchor = anchored.single.message;
    if (anchor.createdAtEpoch <= terminalPredecessorMessage.createdAtEpoch) {
      return const _LogicalGenerationQualification.notProven('AUTHORIZED_OUTBOUND_PRECEDES_GENERATION_HANDOFF');
    }

    final naturalResponses = current
        .where((candidate) => candidate.sourceChatRowId != transitionSource.sourceChatRowId)
        .expand((candidate) => candidate.messages)
        .where((message) {
          final delay = message.createdAtEpoch - anchor.createdAtEpoch;
          return message.isInboundNormal && delay > 0 && delay <= certificate.maximumNaturalResponseDelayMilliseconds;
        });
    if (naturalResponses.isEmpty) {
      return const _LogicalGenerationQualification.notProven('AUTHORIZED_OUTBOUND_NATURAL_RESPONSE_MISSING');
    }

    return _LogicalGenerationQualification.qualified(current);
  }

  static int _compareMessageChronology(LogicalRouteMessageEvidence left, LogicalRouteMessageEvidence right) {
    final byTime = left.createdAtEpoch.compareTo(right.createdAtEpoch);
    if (byTime != 0) return byTime;
    return left.messageGuid.compareTo(right.messageGuid);
  }

  static String? _normalizedRelationshipTarget(String? value) {
    if (value == null || value.isEmpty) return null;
    return value.replaceAll('bp:', '').split('/').last.toUpperCase();
  }

  static String _anchorFingerprint(String messageGuid) =>
      sha256.convert(utf8.encode('logical-route-anchor-v1\u0000$messageGuid')).toString();

  static LogicalRouteDecision _qualifyCertifiedSources(LogicalRouteEvidence evidence) {
    if (evidence.logicalId.isEmpty || evidence.certificateId == null || evidence.certificateId!.isEmpty) {
      return const LogicalRouteDecision.notProven('MISSING_EQUIVALENCE_CERTIFICATE');
    }
    if (evidence.certificateId != '$logicalConversationOutboundRouteSchema:${evidence.logicalId}') {
      return const LogicalRouteDecision.notProven('EQUIVALENCE_CERTIFICATE_BINDING_MISMATCH');
    }
    if (evidence.certifiedSourceChatGuids.length < 2 || evidence.certifiedSourceChatGuids.length > 8) {
      return const LogicalRouteDecision.notProven('CERTIFIED_SOURCE_SCOPE_INVALID');
    }
    if (evidence.backendComputerId.isEmpty) {
      return const LogicalRouteDecision.notProven('BACKEND_IDENTITY_MISSING');
    }
    if (!evidence.detectedIMessage || !evidence.privateApiConnected || !evidence.helperConnected) {
      return const LogicalRouteDecision.notProven('CURRENT_TRANSPORT_CONTEXT_UNPROVEN');
    }
    if (evidence.accountSnapshotBeforeSha256.isEmpty ||
        evidence.accountSnapshotBeforeSha256 != evidence.accountSnapshotAfterSha256) {
      return const LogicalRouteDecision.notProven('CURRENT_ACCOUNT_IDENTITY_UNSTABLE');
    }

    final vettedAliases = <String>{};
    for (final alias in evidence.vettedSelfAliases) {
      final normalized = normalizeRoutableAddress(alias);
      if (normalized == null || !vettedAliases.add(normalized)) {
        return const LogicalRouteDecision.notProven('VETTED_SELF_ALIAS_IDENTITY_UNPROVEN');
      }
    }
    final activeAlias = normalizeRoutableAddress(evidence.activeSelfAlias);
    if (activeAlias == null || !vettedAliases.contains(activeAlias)) {
      return const LogicalRouteDecision.notProven('ACTIVE_SENDER_NOT_CURRENT_VETTED_ALIAS');
    }

    if (evidence.candidates.length != evidence.certifiedSourceChatGuids.length) {
      return const LogicalRouteDecision.notProven('ZERO_OR_AMBIGUOUS_EXECUTION_CANDIDATES');
    }
    final byRow = <int, LogicalRouteCandidateEvidence>{};
    final seenGuids = <String>{};
    for (final candidate in evidence.candidates) {
      if (byRow.containsKey(candidate.sourceChatRowId) || !seenGuids.add(candidate.sourceChatGuid)) {
        return const LogicalRouteDecision.notProven('DUPLICATE_EXECUTION_CANDIDATE');
      }
      byRow[candidate.sourceChatRowId] = candidate;
    }
    if (!_sameSet(byRow.keys.toSet(), evidence.certifiedSourceChatGuids.keys.toSet())) {
      return const LogicalRouteDecision.notProven('CERTIFIED_SOURCE_BINDING_MISSING');
    }

    Set<String>? acceptedExternalParticipants;
    final globallySeenOutboundRows = <int>{};
    final globallySeenOutboundGuids = <String>{};
    for (final candidate in evidence.candidates) {
      if (evidence.certifiedSourceChatGuids[candidate.sourceChatRowId] != candidate.sourceChatGuid ||
          candidate.sourceChatGuid.isEmpty ||
          candidate.chatIdentifier.isEmpty ||
          candidate.style != 43) {
        return const LogicalRouteDecision.notProven('CURRENT_SOURCE_BINDING_CONTRADICTION');
      }
      final currentRoute = normalizeRoutableAddress(candidate.lastAddressedHandle);
      if (currentRoute == null || currentRoute != activeAlias) {
        return const LogicalRouteDecision.notProven('STALE_OR_CONFLICTING_CURRENT_ROUTE');
      }
      if (!candidate.messageSnapshotComplete) {
        return const LogicalRouteDecision.notProven('CURRENT_MESSAGE_PROVENANCE_INCOMPLETE');
      }

      final participants = <String>{};
      for (final participant in candidate.participants) {
        final normalized = normalizeRoutableAddress(participant);
        if (normalized == null || !participants.add(normalized)) {
          return const LogicalRouteDecision.notProven('PARTICIPANT_IDENTITY_UNPROVEN');
        }
      }
      final external = participants.difference(vettedAliases);
      if (external.length < 2) {
        return const LogicalRouteDecision.notProven('EXTERNAL_PARTICIPANT_SCOPE_UNPROVEN');
      }
      if (acceptedExternalParticipants == null) {
        acceptedExternalParticipants = external;
      } else if (!_sameSet(acceptedExternalParticipants, external)) {
        return const LogicalRouteDecision.notProven('EXTERNAL_PARTICIPANT_IDENTITY_CONTRADICTION');
      }
      for (final outbound in candidate.successfulOutbounds) {
        if (outbound.messageGuid.isEmpty || outbound.messageRowId <= 0 || outbound.createdAtEpoch <= 0) {
          return const LogicalRouteDecision.notProven('SUCCESSFUL_OUTBOUND_PROVENANCE_INVALID');
        }
        if (!globallySeenOutboundRows.add(outbound.messageRowId) ||
            !globallySeenOutboundGuids.add(outbound.messageGuid)) {
          return const LogicalRouteDecision.notProven('SUCCESSFUL_OUTBOUND_PROVENANCE_AMBIGUOUS');
        }
      }
    }

    return LogicalRouteDecision.qualified('CURRENT_CERTIFIED_SOURCE_SET', byRow.keys.toList()..sort());
  }

  static LogicalRouteDecision _targetMessageRoute(
    Map<int, LogicalRouteCandidateEvidence> byRow,
    LogicalMutationRequest request,
  ) {
    final targetRow = request.targetSourceChatRowId;
    final targetGuid = request.targetSourceChatGuid;
    if (targetRow == null ||
        request.targetMessageGuid == null ||
        request.targetMessageGuid!.isEmpty ||
        targetGuid == null ||
        targetGuid.isEmpty) {
      return const LogicalRouteDecision.notProven('TARGET_MESSAGE_PROVENANCE_MISSING');
    }
    final candidate = byRow[targetRow];
    if (candidate == null || candidate.sourceChatGuid != targetGuid) {
      return const LogicalRouteDecision.notProven('TARGET_MESSAGE_SOURCE_BINDING_MISMATCH');
    }
    return LogicalRouteDecision.qualified('EXACT_TARGET_MESSAGE_SOURCE_ROUTE', [targetRow]);
  }

  static LogicalRouteDecision _persistedExecutionRoute(
    Map<int, LogicalRouteCandidateEvidence> byRow,
    LogicalMutationRequest request,
  ) {
    final sourceRow = request.persistedExecutionSourceChatRowId;
    final sourceGuid = request.persistedExecutionSourceChatGuid;
    if (sourceRow == null || sourceGuid == null || sourceGuid.isEmpty) {
      return const LogicalRouteDecision.notProven('PERSISTED_ATTACHMENT_ROUTE_MISSING');
    }
    final candidate = byRow[sourceRow];
    if (candidate == null || candidate.sourceChatGuid != sourceGuid) {
      return const LogicalRouteDecision.notProven('PERSISTED_ATTACHMENT_ROUTE_CONTRADICTION');
    }
    return LogicalRouteDecision.qualified('CERTIFIED_PERSISTED_ATTACHMENT_RETRY_ROUTE', [sourceRow]);
  }

  static bool _sameSet<T>(Set<T> left, Set<T> right) =>
      left.length == right.length && left.containsAll(right) && right.containsAll(left);
}

/// Bounded replay gate for the logical execution handoff.
///
/// The existing BlueBubbles send engine remains authoritative after admission.
/// This gate only prevents the same non-retry logical action identity from
/// being handed to that engine twice by a rebuild or duplicate callback.
class LogicalExecutionAdmissionGate {
  LogicalExecutionAdmissionGate({this.capacity = 256}) : assert(capacity > 0);

  final int capacity;
  final Set<String> _admitted = <String>{};
  final Queue<String> _order = Queue<String>();

  bool admit(String actionId, {bool explicitRetry = false}) {
    if (actionId.isEmpty) return false;
    final admissionId = '${explicitRetry ? 'retry' : 'initial'}:$actionId';
    if (!_admitted.add(admissionId)) return false;
    _order.addLast(admissionId);
    while (_order.length > capacity) {
      _admitted.remove(_order.removeFirst());
    }
    return true;
  }
}
