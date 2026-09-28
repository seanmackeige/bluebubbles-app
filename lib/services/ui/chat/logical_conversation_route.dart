import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

const logicalConversationOutboundRouteSchema = 'LOGICAL_CONVERSATION_OUTBOUND_ROUTE_V4_PROVIDER_FACT_CONTRACT';
const logicalExecutionGenerationCertificateSchema =
    'LOGICAL_EXECUTION_GENERATION_CERTIFICATE_V4_PROVIDER_FACT_CONTRACT';
const logicalConversationEvidenceReconciliationSchema = 'LOGICAL_CONVERSATION_EVIDENCE_RECONCILIATION_V1';

enum LogicalMutationClass { newMessage, reply, reaction, attachment, markRead, unsupported }

enum LogicalRouteState { qualified, routeNotProven }

enum LogicalRouteRuntimeStage { unchecked, checking, qualified, routeNotProven }

enum LogicalTransportReadinessState { ready, unavailable, unknown }

enum LogicalTransportEvidenceStrength { authoritative, strongIndicator, weakIndicator, unavailable }

enum LogicalTransportSendDisposition { ready, blocked, allowedWithReachabilityUnknown }

/// Availability and agreement are deliberately separate. In particular, a
/// field omitted by a known provider serializer is not the boolean `false` and
/// is not an account mismatch.
enum LogicalProviderFactState { presentAndMatches, presentAndContradicts, unavailable }

class LogicalProviderFactEvidence {
  const LogicalProviderFactEvidence({required this.state, this.satisfiedByAuthoritativeFallback = false});

  final LogicalProviderFactState state;
  final bool satisfiedByAuthoritativeFallback;

  bool get invariantSatisfied =>
      state == LogicalProviderFactState.presentAndMatches ||
      (state == LogicalProviderFactState.unavailable && satisfiedByAuthoritativeFallback);
}

class LogicalAuthoritativeAccountFact {
  const LogicalAuthoritativeAccountFact({
    required this.sourceChatGuidSha256,
    required this.service,
    required this.accountSha256,
  });

  final String sourceChatGuidSha256;
  final String service;
  final String accountSha256;

  bool get isValid =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceChatGuidSha256) &&
      service.isNotEmpty &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(accountSha256);
}

/// A terminal fallback is an independently observed Apple/Messages fact, not
/// an inference from HTTP `error == 0`. Every coordinate must match before it
/// can fill a field omitted by the BlueBubbles serializer.
class LogicalAuthoritativeTerminalFact {
  const LogicalAuthoritativeTerminalFact({
    required this.sourceChatGuidSha256,
    required this.service,
    required this.accountSha256,
    required this.messageGuidSha256,
    required this.messageRowId,
    required this.isSent,
    required this.isFinished,
  });

  final String sourceChatGuidSha256;
  final String service;
  final String accountSha256;
  final String messageGuidSha256;
  final int messageRowId;
  final bool isSent;
  final bool isFinished;

  bool get isValid =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceChatGuidSha256) &&
      service.isNotEmpty &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(accountSha256) &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(messageGuidSha256) &&
      messageRowId > 0 &&
      isSent &&
      isFinished;
}

/// Read-only transport evidence, deliberately separate from route authority.
///
/// A valid SMS writer can remain authoritative while its enrolled iPhone relay
/// is offline. Apple/BlueBubbles do not expose a continuous iPhone reachability
/// heartbeat, so absence of recent terminal evidence remains [unknown], never
/// an invented healthy state.
class LogicalTransportReadinessEvidence {
  const LogicalTransportReadinessEvidence({
    required this.service,
    required this.state,
    required this.strength,
    required this.reason,
    required this.observedAtEpochMilliseconds,
    this.validUntilEpochMilliseconds,
  });

  final String service;
  final LogicalTransportReadinessState state;
  final LogicalTransportEvidenceStrength strength;
  final String reason;
  final int observedAtEpochMilliseconds;
  final int? validUntilEpochMilliseconds;

  LogicalTransportReadinessState effectiveStateAt(int nowEpochMilliseconds) {
    if (state == LogicalTransportReadinessState.ready &&
        validUntilEpochMilliseconds != null &&
        nowEpochMilliseconds > validUntilEpochMilliseconds!) {
      return LogicalTransportReadinessState.unknown;
    }
    if (state == LogicalTransportReadinessState.unavailable &&
        strength != LogicalTransportEvidenceStrength.authoritative) {
      return LogicalTransportReadinessState.unknown;
    }
    return state;
  }

  LogicalTransportSendDisposition sendDispositionAt(int nowEpochMilliseconds) {
    switch (effectiveStateAt(nowEpochMilliseconds)) {
      case LogicalTransportReadinessState.ready:
        return LogicalTransportSendDisposition.ready;
      case LogicalTransportReadinessState.unavailable:
        return LogicalTransportSendDisposition.blocked;
      case LogicalTransportReadinessState.unknown:
        return LogicalTransportSendDisposition.allowedWithReachabilityUnknown;
    }
  }

  String get revision => sha256
      .convert(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'service': service,
            'state': state.name,
            'strength': strength.name,
            'reason': reason,
            'observedAtEpochMilliseconds': observedAtEpochMilliseconds,
            'validUntilEpochMilliseconds': validUntilEpochMilliseconds,
          }),
        ),
      )
      .toString();
}

class LogicalRouteRuntimeStatus {
  const LogicalRouteRuntimeStatus({
    required this.stage,
    required this.reason,
    this.targetRowId,
    this.certificateRevision,
    this.authorityRevision,
    this.authorityEpoch,
    this.service,
    this.transportReadiness,
    this.transportReason,
    this.sendDisposition,
  });

  const LogicalRouteRuntimeStatus.unchecked()
    : this(stage: LogicalRouteRuntimeStage.unchecked, reason: 'ROUTE_NOT_CHECKED');

  const LogicalRouteRuntimeStatus.checking()
    : this(stage: LogicalRouteRuntimeStage.checking, reason: 'CHECKING_CURRENT_ROUTE_EVIDENCE');

  final LogicalRouteRuntimeStage stage;
  final String reason;
  final int? targetRowId;
  final String? certificateRevision;
  final String? authorityRevision;
  final int? authorityEpoch;
  final String? service;
  final LogicalTransportReadinessState? transportReadiness;
  final String? transportReason;
  final LogicalTransportSendDisposition? sendDisposition;

  bool get isQualified => stage == LogicalRouteRuntimeStage.qualified && targetRowId != null;

  bool get isSendBlocked => !isQualified || sendDisposition == LogicalTransportSendDisposition.blocked;
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
    this.terminalAcknowledgement = false,
    this.account = '',
    this.accountFact = const LogicalProviderFactEvidence(state: LogicalProviderFactState.unavailable),
    this.isSentFact = const LogicalProviderFactEvidence(state: LogicalProviderFactState.unavailable),
    this.isFinishedFact = const LogicalProviderFactEvidence(state: LogicalProviderFactState.unavailable),
  });

  final String messageGuid;
  final int messageRowId;
  final int createdAtEpoch;
  final bool terminalAcknowledgement;
  final String account;
  final LogicalProviderFactEvidence accountFact;
  final LogicalProviderFactEvidence isSentFact;
  final LogicalProviderFactEvidence isFinishedFact;
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
    this.replyToGuid,
    this.account = '',
    this.accountFact = const LogicalProviderFactEvidence(state: LogicalProviderFactState.unavailable),
  });

  final String messageGuid;
  final int messageRowId;
  final int createdAtEpoch;
  final bool isFromMe;
  final int error;
  final int itemType;
  final String? associatedMessageGuid;
  final String? replyToGuid;
  final String account;
  final LogicalProviderFactEvidence accountFact;

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
    required this.expectedExternalParticipantCount,
    required this.expectedExternalParticipantSetSha256,
    required this.predecessorHandoffGuidSha256,
    required this.authorizedOutboundGuidSha256,
    required this.maximumTransitionEdgeDelayMilliseconds,
    required this.maximumNaturalResponseDelayMilliseconds,
    required this.explanation,
    this.allowAdditionalCurrentMembers = false,
    this.evidenceDrivenSuccession = false,
    this.expectedAccountSnapshotSha256 = '',
    this.authoritativeAccountFacts = const [],
    this.authoritativeTerminalFacts = const [],
  });

  final String schema;
  final String logicalId;
  final String evidenceReceiptCommit;
  final String currentService;
  final String predecessorService;
  final int expectedCurrentMemberCount;
  final int expectedPredecessorMemberCount;
  final int expectedExternalParticipantCount;
  final String expectedExternalParticipantSetSha256;
  final String predecessorHandoffGuidSha256;
  final String authorizedOutboundGuidSha256;
  final int maximumTransitionEdgeDelayMilliseconds;
  final int maximumNaturalResponseDelayMilliseconds;
  final String explanation;
  final bool allowAdditionalCurrentMembers;
  final bool evidenceDrivenSuccession;
  final String expectedAccountSnapshotSha256;
  final List<LogicalAuthoritativeAccountFact> authoritativeAccountFacts;
  final List<LogicalAuthoritativeTerminalFact> authoritativeTerminalFacts;

  bool get hasProviderFactFallback =>
      expectedAccountSnapshotSha256.isNotEmpty ||
      authoritativeAccountFacts.isNotEmpty ||
      authoritativeTerminalFacts.isNotEmpty;

  String get providerFactContractRevision {
    final accounts = [
      for (final fact in authoritativeAccountFacts)
        '${fact.sourceChatGuidSha256}:${fact.service}:${fact.accountSha256}',
    ]..sort();
    final terminals = [
      for (final fact in authoritativeTerminalFacts)
        '${fact.sourceChatGuidSha256}:${fact.service}:${fact.accountSha256}:'
            '${fact.messageGuidSha256}:${fact.messageRowId}:${fact.isSent}:${fact.isFinished}',
    ]..sort();
    return sha256
        .convert(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'schema': schema,
              'logicalId': logicalId,
              'evidenceReceiptCommit': evidenceReceiptCommit,
              'expectedAccountSnapshotSha256': expectedAccountSnapshotSha256,
              'authoritativeAccountFacts': accounts,
              'authoritativeTerminalFacts': terminals,
            }),
          ),
        )
        .toString();
  }

  bool get isValid =>
      schema == logicalExecutionGenerationCertificateSchema &&
      logicalId.isNotEmpty &&
      RegExp(r'^[0-9a-f]{40}$').hasMatch(evidenceReceiptCommit) &&
      (evidenceDrivenSuccession ||
          (currentService.isNotEmpty &&
              predecessorService.isNotEmpty &&
              currentService != predecessorService &&
              expectedCurrentMemberCount > 0 &&
              expectedPredecessorMemberCount > 0)) &&
      expectedExternalParticipantCount > 1 &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedExternalParticipantSetSha256) &&
      (evidenceDrivenSuccession || RegExp(r'^[0-9a-f]{64}$').hasMatch(predecessorHandoffGuidSha256)) &&
      (evidenceDrivenSuccession || RegExp(r'^[0-9a-f]{64}$').hasMatch(authorizedOutboundGuidSha256)) &&
      maximumTransitionEdgeDelayMilliseconds > 0 &&
      maximumNaturalResponseDelayMilliseconds > 0 &&
      explanation.isNotEmpty &&
      (!hasProviderFactFallback ||
          (RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedAccountSnapshotSha256) &&
              authoritativeAccountFacts.isNotEmpty &&
              authoritativeAccountFacts.every((fact) => fact.isValid) &&
              authoritativeAccountFacts.map((fact) => fact.sourceChatGuidSha256).toSet().length ==
                  authoritativeAccountFacts.length &&
              authoritativeTerminalFacts.isNotEmpty &&
              authoritativeTerminalFacts.every((fact) => fact.isValid) &&
              authoritativeTerminalFacts.map((fact) => fact.messageGuidSha256).toSet().length ==
                  authoritativeTerminalFacts.length));
}

class LogicalRouteCandidateEvidence {
  const LogicalRouteCandidateEvidence({
    required this.sourceChatRowId,
    required this.sourceChatGuid,
    required this.sourceService,
    required this.sourceAccount,
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
    this.groupIdentifier,
    required this.messages,
    required this.successfulOutbounds,
    this.sourceAccountFact = const LogicalProviderFactEvidence(state: LogicalProviderFactState.unavailable),
  });

  final int sourceChatRowId;
  final String sourceChatGuid;
  final String sourceService;
  final String sourceAccount;
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
  final String? groupIdentifier;
  final List<LogicalRouteMessageEvidence> messages;
  final List<LogicalSuccessfulOutboundEvidence> successfulOutbounds;
  final LogicalProviderFactEvidence sourceAccountFact;
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

  /// Digest of every execution-sensitive fact in this complete snapshot.
  /// Lists are normalized so transport ordering cannot invent a revision.
  String get authorityRevision {
    final certified = certifiedSourceChatGuids.entries.toList()..sort((left, right) => left.key.compareTo(right.key));
    final unadmitted = unadmittedPotentialSourceChatGuids.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    final orderedCandidates = candidates.toList()
      ..sort((left, right) => left.sourceChatRowId.compareTo(right.sourceChatRowId));
    final payload = <String, dynamic>{
      'logicalId': logicalId,
      'certificateId': certificateId,
      'certifiedSources': [for (final entry in certified) '${entry.key}:${entry.value}'],
      'backendComputerId': backendComputerId,
      'detectedIMessage': detectedIMessage,
      'privateApiConnected': privateApiConnected,
      'helperConnected': helperConnected,
      'accountSnapshotBeforeSha256': accountSnapshotBeforeSha256,
      'accountSnapshotAfterSha256': accountSnapshotAfterSha256,
      'activeSelfAlias': _addressJson(activeSelfAlias),
      'vettedSelfAliases': vettedSelfAliases.map(_addressJson).toList()..sort(_compareJsonText),
      'executionGeneration': _generationJson(executionGenerationCertificate),
      'candidateScopeSnapshotComplete': candidateScopeSnapshotComplete,
      'unadmittedCandidates': [for (final entry in unadmitted) '${entry.key}:${entry.value}'],
      'candidates': [
        for (final candidate in orderedCandidates) _candidateJson(candidate, executionGenerationCertificate),
      ],
    };
    return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  }

  static Map<String, dynamic> _addressJson(LogicalAddressEvidence address) => <String, dynamic>{
    'address': address.address,
    'country': address.country,
  };

  static Map<String, dynamic>? _generationJson(LogicalExecutionGenerationCertificate? certificate) {
    if (certificate == null) return null;
    return <String, dynamic>{
      'schema': certificate.schema,
      'logicalId': certificate.logicalId,
      'evidenceReceiptCommit': certificate.evidenceReceiptCommit,
      'currentService': certificate.currentService,
      'predecessorService': certificate.predecessorService,
      'expectedCurrentMemberCount': certificate.expectedCurrentMemberCount,
      'expectedPredecessorMemberCount': certificate.expectedPredecessorMemberCount,
      'expectedExternalParticipantCount': certificate.expectedExternalParticipantCount,
      'expectedExternalParticipantSetSha256': certificate.expectedExternalParticipantSetSha256,
      'predecessorHandoffGuidSha256': certificate.predecessorHandoffGuidSha256,
      'authorizedOutboundGuidSha256': certificate.authorizedOutboundGuidSha256,
      'maximumTransitionEdgeDelayMilliseconds': certificate.maximumTransitionEdgeDelayMilliseconds,
      'maximumNaturalResponseDelayMilliseconds': certificate.maximumNaturalResponseDelayMilliseconds,
      'allowAdditionalCurrentMembers': certificate.allowAdditionalCurrentMembers,
      'evidenceDrivenSuccession': certificate.evidenceDrivenSuccession,
      'expectedAccountSnapshotSha256': certificate.expectedAccountSnapshotSha256,
      'authoritativeAccountFacts': [
        for (final fact in certificate.authoritativeAccountFacts)
          <String, dynamic>{
            'sourceChatGuidSha256': fact.sourceChatGuidSha256,
            'service': fact.service,
            'accountSha256': fact.accountSha256,
          },
      ]..sort(_compareJsonText),
      'authoritativeTerminalFacts': [
        for (final fact in certificate.authoritativeTerminalFacts)
          <String, dynamic>{
            'sourceChatGuidSha256': fact.sourceChatGuidSha256,
            'service': fact.service,
            'accountSha256': fact.accountSha256,
            'messageGuidSha256': fact.messageGuidSha256,
            'messageRowId': fact.messageRowId,
            'isSent': fact.isSent,
            'isFinished': fact.isFinished,
          },
      ]..sort(_compareJsonText),
    };
  }

  static Map<String, dynamic> _candidateJson(
    LogicalRouteCandidateEvidence candidate,
    LogicalExecutionGenerationCertificate? generation,
  ) {
    final participants = candidate.participants.map(_addressJson).toList()..sort(_compareJsonText);
    final isPredecessor =
        generation != null &&
        candidate.sourceService == generation.predecessorService &&
        candidate.lastKnownHybridState == null;
    final predecessorNaturals = isPredecessor
        ? candidate.messages.where((message) => message.isInboundNormal || message.isSuccessfulOutbound).toList()
        : const <LogicalRouteMessageEvidence>[];
    if (predecessorNaturals.length > 1) {
      predecessorNaturals.sort((left, right) {
        final byTime = left.createdAtEpoch.compareTo(right.createdAtEpoch);
        return byTime != 0 ? byTime : left.messageGuid.compareTo(right.messageGuid);
      });
    }
    final latestPredecessorNatural = predecessorNaturals.isEmpty ? null : predecessorNaturals.last;
    return <String, dynamic>{
      'sourceChatRowId': candidate.sourceChatRowId,
      'sourceChatGuid': candidate.sourceChatGuid,
      'sourceService': candidate.sourceService,
      'sourceAccountSha256': sha256.convert(utf8.encode(candidate.sourceAccount)).toString(),
      'sourceAccountFact': _providerFactJson(candidate.sourceAccountFact),
      'chatIdentifier': candidate.chatIdentifier,
      'style': candidate.style,
      'lastAddressedHandle': _addressJson(candidate.lastAddressedHandle),
      'participants': participants,
      'chatSnapshotComplete': candidate.chatSnapshotComplete,
      'messageSnapshotComplete': candidate.messageSnapshotComplete,
      'lastKnownHybridState': candidate.lastKnownHybridState,
      'shouldForceToSms': candidate.shouldForceToSms,
      'groupPhotoGuid': candidate.groupPhotoGuid,
      'groupIdentifier': candidate.groupIdentifier,
      if (isPredecessor) 'lastSeenMessageGuid': candidate.lastSeenMessageGuid,
      if (latestPredecessorNatural != null)
        'latestPredecessorNatural': <String, dynamic>{
          'messageGuid': latestPredecessorNatural.messageGuid,
          'messageRowId': latestPredecessorNatural.messageRowId,
          'createdAtEpoch': latestPredecessorNatural.createdAtEpoch,
          'isFromMe': latestPredecessorNatural.isFromMe,
          'error': latestPredecessorNatural.error,
          'itemType': latestPredecessorNatural.itemType,
        },
      // Message chronology is qualification evidence, not an authority
      // identity by itself. The derived route decision is digested by the
      // caller, so routine message arrivals do not invalidate a draft while a
      // changed winner or failed invariant still advances the revision.
      'hasSuccessfulOutbound': candidate.successfulOutbounds.isNotEmpty,
      'successfulOutboundProviderFacts': [
        for (final outbound in candidate.successfulOutbounds)
          <String, dynamic>{
            'messageGuidSha256': sha256.convert(utf8.encode(outbound.messageGuid)).toString(),
            'messageRowId': outbound.messageRowId,
            'account': _providerFactJson(outbound.accountFact),
            'isSent': _providerFactJson(outbound.isSentFact),
            'isFinished': _providerFactJson(outbound.isFinishedFact),
            'terminalAcknowledgement': outbound.terminalAcknowledgement,
          },
      ]..sort(_compareJsonText),
    };
  }

  static Map<String, dynamic> _providerFactJson(LogicalProviderFactEvidence fact) => <String, dynamic>{
    'state': fact.state.name,
    'satisfiedByAuthoritativeFallback': fact.satisfiedByAuthoritativeFallback,
  };

  static int _compareJsonText(Map<String, dynamic> left, Map<String, dynamic> right) =>
      jsonEncode(left).compareTo(jsonEncode(right));
}

class LogicalMutationRequest {
  const LogicalMutationRequest({
    required this.mutationClass,
    this.targetMessageGuid,
    this.targetSourceChatRowId,
    this.targetSourceChatGuid,
    this.replyIntentMessageGuid,
    this.replyIntentSourceChatRowId,
    this.replyIntentSourceChatGuid,
    this.requireFreshTargetPresence = false,
    this.persistedExecutionSourceChatRowId,
    this.persistedExecutionSourceChatGuid,
    this.isRetry = false,
    this.unreadSourceChatRowIds = const <int>{},
  });

  final LogicalMutationClass mutationClass;
  final String? targetMessageGuid;
  final int? targetSourceChatRowId;
  final String? targetSourceChatGuid;
  final String? replyIntentMessageGuid;
  final int? replyIntentSourceChatRowId;
  final String? replyIntentSourceChatGuid;
  final bool requireFreshTargetPresence;
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

/// Evaluates only evidence that is already present in the bounded provider
/// snapshot. It never converts enrollment, Mac health, or an old successful
/// send into proof that an iPhone relay is reachable now.
class LogicalTransportReadinessPolicy {
  LogicalTransportReadinessPolicy._();

  static const Duration recentTerminalEvidenceWindow = Duration(minutes: 10);

  static LogicalTransportReadinessEvidence resolve(
    LogicalRouteEvidence evidence,
    LogicalRouteDecision decision, {
    required int observedAtEpochMilliseconds,
  }) {
    if (!decision.isSingleTarget) {
      return LogicalTransportReadinessEvidence(
        service: 'UNKNOWN',
        state: LogicalTransportReadinessState.unknown,
        strength: LogicalTransportEvidenceStrength.unavailable,
        reason: 'TRANSPORT_ROUTE_NOT_QUALIFIED',
        observedAtEpochMilliseconds: observedAtEpochMilliseconds,
      );
    }
    final matches = evidence.candidates
        .where((candidate) => candidate.sourceChatRowId == decision.physicalTargetRowIds.single)
        .toList(growable: false);
    if (matches.length != 1) {
      return LogicalTransportReadinessEvidence(
        service: 'UNKNOWN',
        state: LogicalTransportReadinessState.unknown,
        strength: LogicalTransportEvidenceStrength.unavailable,
        reason: 'TRANSPORT_TARGET_EVIDENCE_NOT_UNIQUE',
        observedAtEpochMilliseconds: observedAtEpochMilliseconds,
      );
    }
    final candidate = matches.single;
    final service = candidate.sourceService;
    if (service == 'SMS') {
      final successful =
          candidate.successfulOutbounds.where((outbound) => outbound.terminalAcknowledgement).toList(growable: false)
            ..sort((left, right) => right.createdAtEpoch.compareTo(left.createdAtEpoch));
      if (successful.isNotEmpty) {
        final latest = successful.first.createdAtEpoch;
        final age = observedAtEpochMilliseconds - latest;
        if (age >= 0 && age <= recentTerminalEvidenceWindow.inMilliseconds) {
          return LogicalTransportReadinessEvidence(
            service: service,
            state: LogicalTransportReadinessState.ready,
            strength: LogicalTransportEvidenceStrength.strongIndicator,
            reason: 'RECENT_NATURAL_SMS_TERMINAL_SUCCESS',
            observedAtEpochMilliseconds: observedAtEpochMilliseconds,
            validUntilEpochMilliseconds: latest + recentTerminalEvidenceWindow.inMilliseconds,
          );
        }
      }
      final hasFailedNormalOutbound = candidate.messages.any(
        (message) => message.isNormal && message.isFromMe && message.error != 0,
      );
      return LogicalTransportReadinessEvidence(
        service: service,
        state: LogicalTransportReadinessState.unknown,
        strength: hasFailedNormalOutbound
            ? LogicalTransportEvidenceStrength.weakIndicator
            : LogicalTransportEvidenceStrength.unavailable,
        reason: hasFailedNormalOutbound
            ? 'SMS_FAILURE_OBSERVED_RELAY_REACHABILITY_NOT_PROVEN'
            : 'SMS_RELAY_REACHABILITY_NOT_PROVEN',
        observedAtEpochMilliseconds: observedAtEpochMilliseconds,
      );
    }
    if (service == 'iMessage' && !evidence.detectedIMessage) {
      return LogicalTransportReadinessEvidence(
        service: service,
        state: LogicalTransportReadinessState.unavailable,
        strength: LogicalTransportEvidenceStrength.authoritative,
        reason: 'IMESSAGE_PROVIDER_UNAVAILABLE',
        observedAtEpochMilliseconds: observedAtEpochMilliseconds,
      );
    }
    return LogicalTransportReadinessEvidence(
      service: service.isEmpty ? 'UNKNOWN' : service,
      state: LogicalTransportReadinessState.unknown,
      strength: LogicalTransportEvidenceStrength.unavailable,
      reason: service == 'iMessage'
          ? 'IMESSAGE_ROUTE_READY_TRANSPORT_REACHABILITY_NOT_PROVEN'
          : 'TRANSPORT_REACHABILITY_NOT_PROVEN',
      observedAtEpochMilliseconds: observedAtEpochMilliseconds,
    );
  }
}

class _LogicalGenerationQualification {
  const _LogicalGenerationQualification._({
    required this.isQualified,
    required this.reason,
    this.currentCandidates = const [],
  });

  const _LogicalGenerationQualification.qualified(
    List<LogicalRouteCandidateEvidence> candidates, {
    required String reason,
  }) : this._(isQualified: true, reason: reason, currentCandidates: candidates);

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
    evidenceReceiptCommit: 'b4eb45d79368251a878628a68b9836b3c704e0c6',
    currentService: 'SMS',
    predecessorService: 'iMessage',
    expectedCurrentMemberCount: 2,
    expectedPredecessorMemberCount: 1,
    expectedExternalParticipantCount: 16,
    expectedExternalParticipantSetSha256: '7c5deb71cf0ad257a7b708b25ed4c7aa0c0f0f3dfb2e1694ed4f32d60b71e8bc',
    predecessorHandoffGuidSha256: '6a078f896a2324b55434e4f103e16fc9b580f4eab909e6e8456ba14ea5c8bc5d',
    authorizedOutboundGuidSha256: '7b0b32bebfa9a6a4811d19f7a33a7a6cc451a015b5d2a0ba8118eba97542f649',
    maximumTransitionEdgeDelayMilliseconds: 60 * 1000,
    maximumNaturalResponseDelayMilliseconds: 2 * 60 * 60 * 1000,
    allowAdditionalCurrentMembers: true,
    evidenceDrivenSuccession: true,
    expectedAccountSnapshotSha256: 'c11f1e308b967e93a1421a7bbdac704bafaf2eac6e224572d044c463635aa528',
    authoritativeAccountFacts: [
      LogicalAuthoritativeAccountFact(
        sourceChatGuidSha256: 'c1d32cce4facfe8dd5c6143133088818b705b3850fd1c2bc954dda1bffc6102f',
        service: 'iMessage',
        accountSha256: '775d19ffb95a883405e5beb099bbf263f123f8bae4560daf279a36d1a15876cc',
      ),
      LogicalAuthoritativeAccountFact(
        sourceChatGuidSha256: '48cf84dd195bd118d7b44be8f4740b23e6e07041366c56b5a0150d6a275d008d',
        service: 'SMS',
        accountSha256: '5c7d454b572614544f19a136c35d8a1bd67253106ef24d95c325e6ad77b53048',
      ),
      LogicalAuthoritativeAccountFact(
        sourceChatGuidSha256: 'bfd04ec33281be066323d0a38e4e93f1f61fe946f469c004b86c86d15665a9d4',
        service: 'SMS',
        accountSha256: '5c7d454b572614544f19a136c35d8a1bd67253106ef24d95c325e6ad77b53048',
      ),
    ],
    authoritativeTerminalFacts: [
      LogicalAuthoritativeTerminalFact(
        sourceChatGuidSha256: 'bfd04ec33281be066323d0a38e4e93f1f61fe946f469c004b86c86d15665a9d4',
        service: 'SMS',
        accountSha256: '5c7d454b572614544f19a136c35d8a1bd67253106ef24d95c325e6ad77b53048',
        messageGuidSha256: 'd45914338a4f823cf0d457339b0684ca41dd0f8d587f6f535b76bd594eb456a2',
        messageRowId: 159521,
        isSent: true,
        isFinished: true,
      ),
    ],
    explanation:
        'Apple chat properties and message account/service provenance establish an iMessage-to-SMS generation '
        'succession. Exact structured edges, account-bound terminal outbound, bounded natural response, and current '
        'last-seen pointers admit one physical execution-generation head. BlueBubbles Server 1.9.7 omits account and '
        'terminal fields, so independently observed Mac account bindings and exact terminal coordinates may satisfy '
        'only unavailable serializer facts while any present contradiction remains fail-closed. Later provider '
        'generations advance only through fresh relationship and response proof.',
  );

  static String providerValueFingerprint(String value) => sha256.convert(utf8.encode(value)).toString();

  /// Mirrors the route collector's stable iCloud-account projection and is
  /// also used by the transport isolate immediately before HTTP dispatch.
  static String providerAccountSnapshotFingerprint(dynamic raw) {
    if (raw is! Map) return '';
    final account = raw.cast<String, dynamic>();
    List<Map<String, dynamic>> projectAliases(dynamic value) {
      if (value is! List) return const [];
      final projected = <Map<String, dynamic>>[];
      for (final item in value.whereType<Map>()) {
        final alias = item['Alias'];
        final status = item['Status'];
        final visible = item['IsUserVisible'];
        if (alias is! String || alias.isEmpty || status is! num || visible is! bool) return const [];
        projected.add(<String, dynamic>{'alias': alias, 'status': status.toInt(), 'visible': visible});
      }
      projected.sort((left, right) {
        final byAlias = (left['alias'] as String).compareTo(right['alias'] as String);
        if (byAlias != 0) return byAlias;
        final byStatus = (left['status'] as int).compareTo(right['status'] as int);
        return byStatus != 0
            ? byStatus
            : left['visible'] == right['visible']
            ? 0
            : left['visible'] == true
            ? 1
            : -1;
      });
      return projected;
    }

    final aliases = projectAliases(account['aliases']);
    final vetted = projectAliases(account['vetted_aliases']);
    final activeAlias = account['active_alias'];
    final appleId = account['apple_id'];
    if (aliases.isEmpty ||
        vetted.isEmpty ||
        activeAlias is! String ||
        activeAlias.isEmpty ||
        appleId is! String ||
        appleId.isEmpty) {
      return '';
    }
    return sha256
        .convert(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'aliases': aliases,
              'vetted_aliases': vetted,
              'active_alias': activeAlias,
              'apple_id': appleId,
            }),
          ),
        )
        .toString();
  }

  static bool matchesCurrentProviderFactTransportContract({
    required String expectedAccountSnapshotSha256,
    required String expectedProviderFactContractRevision,
    required String observedAccountSnapshotSha256,
  }) {
    const generation = comcastNodeUpdatesGeneration;
    return generation.isValid &&
        expectedAccountSnapshotSha256 == generation.expectedAccountSnapshotSha256 &&
        expectedProviderFactContractRevision == generation.providerFactContractRevision &&
        observedAccountSnapshotSha256 == expectedAccountSnapshotSha256;
  }

  static LogicalProviderFactEvidence resolveAccountFact({
    required bool providerFieldPresent,
    required Object? providerValue,
    required String expectedAccountSha256,
    required bool authoritativeFallbackAvailable,
  }) {
    if (providerFieldPresent) {
      final matches =
          providerValue is String &&
          providerValue.isNotEmpty &&
          (expectedAccountSha256.isEmpty || providerValueFingerprint(providerValue) == expectedAccountSha256);
      return LogicalProviderFactEvidence(
        state: matches ? LogicalProviderFactState.presentAndMatches : LogicalProviderFactState.presentAndContradicts,
      );
    }
    return LogicalProviderFactEvidence(
      state: LogicalProviderFactState.unavailable,
      satisfiedByAuthoritativeFallback: authoritativeFallbackAvailable,
    );
  }

  static LogicalProviderFactEvidence resolveTerminalFact({
    required bool providerFieldPresent,
    required Object? providerValue,
    required bool authoritativeFallbackValue,
  }) {
    if (providerFieldPresent) {
      return LogicalProviderFactEvidence(
        state: providerValue == true
            ? LogicalProviderFactState.presentAndMatches
            : LogicalProviderFactState.presentAndContradicts,
      );
    }
    return LogicalProviderFactEvidence(
      state: LogicalProviderFactState.unavailable,
      satisfiedByAuthoritativeFallback: authoritativeFallbackValue,
    );
  }

  static LogicalAuthoritativeAccountFact? authoritativeAccountFactFor({
    required LogicalExecutionGenerationCertificate certificate,
    required String sourceChatGuid,
    required String service,
  }) {
    if (!certificate.isValid) return null;
    final sourceChatGuidSha256 = providerValueFingerprint(sourceChatGuid);
    final matches = certificate.authoritativeAccountFacts
        .where((fact) => fact.sourceChatGuidSha256 == sourceChatGuidSha256 && fact.service == service)
        .toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

  static LogicalAuthoritativeTerminalFact? authoritativeTerminalFactFor({
    required LogicalExecutionGenerationCertificate certificate,
    required String sourceChatGuid,
    required String service,
    required String accountSha256,
    required String messageGuid,
    required int messageRowId,
  }) {
    if (!certificate.isValid) return null;
    final sourceChatGuidSha256 = providerValueFingerprint(sourceChatGuid);
    final messageGuidSha256 = providerValueFingerprint(messageGuid);
    final matches = certificate.authoritativeTerminalFacts
        .where(
          (fact) =>
              fact.sourceChatGuidSha256 == sourceChatGuidSha256 &&
              fact.service == service &&
              fact.accountSha256 == accountSha256 &&
              fact.messageGuidSha256 == messageGuidSha256 &&
              fact.messageRowId == messageRowId,
        )
        .toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

  static LogicalRouteDecision resolve(LogicalRouteEvidence evidence, LogicalMutationRequest request) {
    final sourceQualification = _qualifyCertifiedSources(evidence);
    if (!sourceQualification.isQualified) return sourceQualification;
    final byRow = {for (final candidate in evidence.candidates) candidate.sourceChatRowId: candidate};
    switch (request.mutationClass) {
      case LogicalMutationClass.newMessage:
        return _qualifyWritableSource(evidence);
      case LogicalMutationClass.reply:
      case LogicalMutationClass.reaction:
        return _relationshipTargetRoute(evidence, byRow, request);
      case LogicalMutationClass.attachment:
        if (request.targetMessageGuid != null) {
          return _relationshipTargetRoute(evidence, byRow, request);
        }
        if (request.persistedExecutionSourceChatRowId != null || request.persistedExecutionSourceChatGuid != null) {
          if (!request.isRetry) {
            return const LogicalRouteDecision.notProven('UNTRUSTED_ATTACHMENT_EXECUTION_HINT');
          }
          final persisted = _persistedExecutionRoute(byRow, request);
          if (!persisted.isSingleTarget) return persisted;
          final current = _qualifyWritableSource(evidence);
          if (!current.isSingleTarget) return current;
          if (current.physicalTargetRowIds.single != request.persistedExecutionSourceChatRowId) {
            return const LogicalRouteDecision.notProven('PERSISTED_ATTACHMENT_ROUTE_NO_LONGER_AUTHORITATIVE');
          }
          return persisted;
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

  /// Public-safe binding used by the execution certificate. Each already-
  /// normalized external identity is individually hashed before the sorted set
  /// is hashed, matching the independent provider observer's admitted-set ID.
  static String externalParticipantSetFingerprint(Set<String> normalizedParticipants) {
    final memberFingerprints =
        normalizedParticipants.map((participant) => sha256.convert(utf8.encode(participant)).toString()).toList()
          ..sort();
    return sha256.convert(utf8.encode('${memberFingerprints.join('\n')}\n')).toString();
  }

  /// Conservative nomination guard for a physical chat that could belong to
  /// an already-certified external participant universe. This does not admit
  /// the chat or authorize it to write. It only prevents a newly persisted
  /// Apple identity from bypassing logical admission as an ordinary chat.
  ///
  /// One additional address is tolerated because Apple can persist a
  /// self-alias in one physical member but omit it from another. The exact
  /// certified external set still has to be recoverable by removing exactly
  /// one normalized address.
  static bool canMatchCertifiedExternalParticipantSet(
    Iterable<LogicalAddressEvidence> rawParticipants, {
    required int expectedExternalParticipantCount,
    required String expectedExternalParticipantSetSha256,
  }) {
    final normalized = <String>[];
    for (final participant in rawParticipants) {
      final value = normalizeRoutableAddress(participant);
      if (value == null || normalized.contains(value)) return false;
      normalized.add(value);
    }
    if (normalized.length == expectedExternalParticipantCount) {
      return externalParticipantSetFingerprint(normalized.toSet()) == expectedExternalParticipantSetSha256;
    }
    if (normalized.length != expectedExternalParticipantCount + 1) return false;
    for (final possibleSelf in normalized) {
      final external = normalized.where((value) => value != possibleSelf).toSet();
      if (external.length == expectedExternalParticipantCount &&
          externalParticipantSetFingerprint(external) == expectedExternalParticipantSetSha256) {
        return true;
      }
    }
    return false;
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
    String? generationReason;
    if (evidence.executionGenerationCertificate != null) {
      final generation = _qualifyExecutionGeneration(evidence, selfMembershipByRow);
      if (!generation.isQualified) {
        return LogicalRouteDecision.notProven(generation.reason);
      }
      routeCandidates = generation.currentCandidates;
      generationReason = generation.reason;
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
          : '${generationReason ?? 'CURRENT_EXECUTION_GENERATION_PROVEN'}_UNIQUE_WRITABLE_SOURCE',
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
    if (certificate.evidenceDrivenSuccession) {
      return _qualifyEvidenceDrivenSuccession(evidence, selfMembershipByRow, certificate);
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
    if ((!certificate.allowAdditionalCurrentMembers && current.length != certificate.expectedCurrentMemberCount) ||
        (certificate.allowAdditionalCurrentMembers && current.length < certificate.expectedCurrentMemberCount) ||
        predecessor.length != certificate.expectedPredecessorMemberCount) {
      return const _LogicalGenerationQualification.notProven('EXECUTION_GENERATION_MEMBER_SCOPE_CHANGED');
    }
    if (current.map((candidate) => candidate.sourceAccount).toSet().length != 1) {
      return const _LogicalGenerationQualification.notProven('CURRENT_GENERATION_ACCOUNT_CONTRADICTION');
    }
    if (predecessor.map((candidate) => candidate.sourceAccount).toSet().length != 1) {
      return const _LogicalGenerationQualification.notProven('PREDECESSOR_GENERATION_ACCOUNT_CONTRADICTION');
    }

    final predecessorCandidate = predecessor.single;
    final predecessorNaturals = predecessorCandidate.messages.where(_isAuthorityBearingNatural).toList()
      ..sort(_compareMessageChronology);
    if (predecessorNaturals.isEmpty) {
      return const _LogicalGenerationQualification.notProven('PREDECESSOR_NORMAL_HISTORY_MISSING');
    }

    final predecessorHandoffAnchors = predecessorNaturals
        .where(
          (message) =>
              message.isSuccessfulOutbound &&
              _anchorFingerprint(message.messageGuid) == certificate.predecessorHandoffGuidSha256,
        )
        .toList(growable: false);
    if (predecessorHandoffAnchors.length != 1) {
      return const _LogicalGenerationQualification.notProven('PREDECESSOR_HANDOFF_ANCHOR_MISSING');
    }
    final predecessorHandoff = predecessorHandoffAnchors.single;

    final transitionSources = <LogicalRouteCandidateEvidence>{};
    for (final candidate in current) {
      for (final message in candidate.messages) {
        if (!_relationshipTargets(message).contains(predecessorHandoff.messageGuid.toUpperCase())) {
          continue;
        }
        final delay = message.createdAtEpoch - predecessorHandoff.createdAtEpoch;
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
        (message) => _isAuthorityBearingNatural(message) && message.createdAtEpoch > predecessorHandoff.createdAtEpoch,
      );
      if (postTransitionNormals.isEmpty) {
        return const _LogicalGenerationQualification.notProven('CURRENT_GENERATION_CONTINUITY_INCOMPLETE');
      }
      final lastSeenGuid = candidate.lastSeenMessageGuid;
      final lastSeen = candidate.messages.where((message) => message.messageGuid == lastSeenGuid).toList();
      if (lastSeen.length != 1 ||
          lastSeen.single.itemType != 0 ||
          lastSeen.single.createdAtEpoch <= predecessorHandoff.createdAtEpoch) {
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
    if (anchor.createdAtEpoch <= predecessorHandoff.createdAtEpoch) {
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

    final latestPredecessor = predecessorNaturals.last;
    final predecessorLastSeen = predecessorCandidate.messages
        .where((message) => message.messageGuid == predecessorCandidate.lastSeenMessageGuid)
        .toList(growable: false);
    if (predecessorLastSeen.length != 1 ||
        predecessorLastSeen.single.itemType != 0 ||
        predecessorLastSeen.single.createdAtEpoch < latestPredecessor.createdAtEpoch) {
      return const _LogicalGenerationQualification.notProven('PREDECESSOR_LAST_SEEN_POINTER_CONTRADICTION');
    }

    if (latestPredecessor.messageGuid == predecessorHandoff.messageGuid) {
      return _LogicalGenerationQualification.qualified(current, reason: 'CURRENT_EXECUTION_GENERATION_PROVEN');
    }

    final advancementCutoff = latestPredecessor.createdAtEpoch;
    for (final candidate in current) {
      final postAdvancementNaturals = candidate.messages.where(
        (message) => _isAuthorityBearingNatural(message) && message.createdAtEpoch > advancementCutoff,
      );
      if (postAdvancementNaturals.isEmpty) {
        return const _LogicalGenerationQualification.notProven(
          'CURRENT_GENERATION_REPROOF_AFTER_PREDECESSOR_ADVANCEMENT_MISSING',
        );
      }
      final lastSeen = candidate.messages
          .where((message) => message.messageGuid == candidate.lastSeenMessageGuid)
          .toList(growable: false);
      if (lastSeen.length != 1 ||
          lastSeen.single.itemType != 0 ||
          lastSeen.single.createdAtEpoch <= advancementCutoff) {
        return const _LogicalGenerationQualification.notProven(
          'CURRENT_GENERATION_REPROOF_LAST_SEEN_POINTER_CONTRADICTION',
        );
      }
    }

    final currentMessageOwners = <String, Set<int>>{};
    final currentMessagesByGuid = <String, List<LogicalRouteMessageEvidence>>{};
    for (final candidate in current) {
      for (final message in candidate.messages) {
        final guid = message.messageGuid.toUpperCase();
        currentMessageOwners.putIfAbsent(guid, () => <int>{}).add(candidate.sourceChatRowId);
        currentMessagesByGuid.putIfAbsent(guid, () => <LogicalRouteMessageEvidence>[]).add(message);
      }
    }
    final postAdvancementCrossMemberEdges = <LogicalRouteMessageEvidence>[];
    for (final candidate in current) {
      for (final message in candidate.messages) {
        if (message.createdAtEpoch <= advancementCutoff || message.error != 0 || message.itemType != 0) continue;
        for (final target in _relationshipTargets(message)) {
          final owners = currentMessageOwners[target] ?? const <int>{};
          final targetMessages = currentMessagesByGuid[target] ?? const <LogicalRouteMessageEvidence>[];
          if (owners.length != 1 || owners.contains(candidate.sourceChatRowId) || targetMessages.length != 1) continue;
          final targetMessage = targetMessages.single;
          if (!_isAuthorityBearingNatural(targetMessage) ||
              targetMessage.createdAtEpoch <= advancementCutoff ||
              targetMessage.createdAtEpoch > message.createdAtEpoch) {
            continue;
          }
          postAdvancementCrossMemberEdges.add(message);
          break;
        }
      }
    }
    if (postAdvancementCrossMemberEdges.isEmpty) {
      return const _LogicalGenerationQualification.notProven(
        'CURRENT_GENERATION_CROSS_MEMBER_REPROOF_AFTER_PREDECESSOR_ADVANCEMENT_MISSING',
      );
    }

    final writableCurrent = current
        .where((candidate) => selfMembershipByRow[candidate.sourceChatRowId]?.isEmpty == true)
        .toList(growable: false);
    if (writableCurrent.length != 1) {
      return const _LogicalGenerationQualification.notProven(
        'CURRENT_GENERATION_WRITER_NOT_UNIQUE_AFTER_PREDECESSOR_ADVANCEMENT',
      );
    }
    final reproofWriter = writableCurrent.single;
    final postAdvancementOutbounds = reproofWriter.messages
        .where((message) => message.isSuccessfulOutbound && message.createdAtEpoch > advancementCutoff)
        .toList(growable: false);
    final hasPostAdvancementResponse = postAdvancementOutbounds.any(
      (outbound) => current
          .where((candidate) => candidate.sourceChatRowId != reproofWriter.sourceChatRowId)
          .expand((candidate) => candidate.messages)
          .any((message) {
            final delay = message.createdAtEpoch - outbound.createdAtEpoch;
            return message.isInboundNormal && delay > 0 && delay <= certificate.maximumNaturalResponseDelayMilliseconds;
          }),
    );
    if (!hasPostAdvancementResponse) {
      return const _LogicalGenerationQualification.notProven(
        'CURRENT_GENERATION_NATURAL_RESPONSE_REPROOF_AFTER_PREDECESSOR_ADVANCEMENT_MISSING',
      );
    }

    return _LogicalGenerationQualification.qualified(
      current,
      reason: 'CURRENT_EXECUTION_GENERATION_REPROVEN_AFTER_PREDECESSOR_ACTIVITY',
    );
  }

  static _LogicalGenerationQualification _qualifyEvidenceDrivenSuccession(
    LogicalRouteEvidence evidence,
    Map<int, Set<String>> selfMembershipByRow,
    LogicalExecutionGenerationCertificate certificate,
  ) {
    final parent = <String, String>{};
    for (final candidate in evidence.candidates) {
      if (!candidate.chatSnapshotComplete) {
        return const _LogicalGenerationQualification.notProven('CURRENT_CHAT_PROPERTIES_SNAPSHOT_UNSTABLE');
      }
      if (candidate.shouldForceToSms != false) {
        return const _LogicalGenerationQualification.notProven('CURRENT_PROVIDER_FORCE_SMS_STATE_CONTRADICTION');
      }
      if (candidate.sourceService.isEmpty || candidate.sourceAccount.isEmpty) {
        return const _LogicalGenerationQualification.notProven('EXECUTION_GENERATION_ACCOUNT_OR_SERVICE_MISSING');
      }
      parent[_generationKey(candidate)] = _generationKey(candidate);
    }
    if (parent.isEmpty) {
      return const _LogicalGenerationQualification.notProven('ZERO_EXECUTION_GENERATIONS');
    }

    String find(String key) {
      final next = parent[key]!;
      if (next == key) return key;
      final root = find(next);
      parent[key] = root;
      return root;
    }

    void union(String left, String right) {
      final leftRoot = find(left);
      final rightRoot = find(right);
      if (leftRoot == rightRoot) return;
      if (leftRoot.compareTo(rightRoot) <= 0) {
        parent[rightRoot] = leftRoot;
      } else {
        parent[leftRoot] = rightRoot;
      }
    }

    bool groupIdentityContinues(LogicalRouteCandidateEvidence source, LogicalRouteCandidateEvidence target) {
      final sourcePhoto = source.groupPhotoGuid;
      final targetPhoto = target.groupPhotoGuid;
      final sourceGroup = source.groupIdentifier;
      final targetGroup = target.groupIdentifier;
      return (sourcePhoto != null && sourcePhoto.isNotEmpty && sourcePhoto == targetPhoto) ||
          (sourceGroup != null && sourceGroup.isNotEmpty && sourceGroup == targetGroup);
    }

    bool hasBoundedPeerExecutionProof(LogicalRouteCandidateEvidence noSelf, LogicalRouteCandidateEvidence selfVariant) {
      for (final outbound in noSelf.successfulOutbounds) {
        if (!outbound.terminalAcknowledgement || outbound.account != noSelf.sourceAccount) continue;
        final exact = noSelf.messages.where((message) => message.messageGuid == outbound.messageGuid).toList();
        if (exact.length != 1 || !exact.single.isSuccessfulOutbound || exact.single.account != noSelf.sourceAccount) {
          continue;
        }
        for (final response in selfVariant.messages) {
          final delay = response.createdAtEpoch - outbound.createdAtEpoch;
          if (response.isInboundNormal && delay > 0 && delay <= certificate.maximumNaturalResponseDelayMilliseconds) {
            return true;
          }
        }
      }
      return false;
    }

    final owners = <String, List<({LogicalRouteCandidateEvidence candidate, LogicalRouteMessageEvidence message})>>{};
    for (final candidate in evidence.candidates) {
      for (final message in candidate.messages) {
        owners
            .putIfAbsent(
              message.messageGuid.toUpperCase(),
              () => <({LogicalRouteCandidateEvidence candidate, LogicalRouteMessageEvidence message})>[],
            )
            .add((candidate: candidate, message: message));
      }
    }

    final relationships = <({LogicalRouteCandidateEvidence source, LogicalRouteCandidateEvidence target})>[];
    for (final sourceCandidate in evidence.candidates) {
      for (final message in sourceCandidate.messages) {
        if (message.error != 0 || message.itemType != 0) continue;
        for (final targetGuid in _relationshipTargets(message)) {
          final targetOwners = owners[targetGuid] ?? const [];
          if (targetOwners.length != 1) continue;
          final target = targetOwners.single;
          if (target.candidate.sourceChatGuid == sourceCandidate.sourceChatGuid ||
              !_isAuthorityBearingNatural(target.message) ||
              target.message.createdAtEpoch > message.createdAtEpoch) {
            continue;
          }
          if (!groupIdentityContinues(sourceCandidate, target.candidate)) continue;
          relationships.add((source: sourceCandidate, target: target.candidate));
        }
      }
    }

    // Apple may persist two physical peers for one execution generation when
    // exactly one includes a vetted self alias. They become one generation
    // only with a direct structured edge plus account-bound terminal outbound
    // and bounded natural-response proof; matching service/account alone never
    // merges them.
    for (final relationship in relationships) {
      final source = relationship.source;
      final target = relationship.target;
      final sourceSelf = selfMembershipByRow[source.sourceChatRowId] ?? const <String>{};
      final targetSelf = selfMembershipByRow[target.sourceChatRowId] ?? const <String>{};
      if (source.sourceService != target.sourceService ||
          source.sourceAccount != target.sourceAccount ||
          sourceSelf.isEmpty == targetSelf.isEmpty) {
        continue;
      }
      final noSelf = sourceSelf.isEmpty ? source : target;
      final selfVariant = sourceSelf.isEmpty ? target : source;
      if (hasBoundedPeerExecutionProof(noSelf, selfVariant)) {
        union(_generationKey(source), _generationKey(target));
      }
    }

    final generations = <String, List<LogicalRouteCandidateEvidence>>{};
    for (final candidate in evidence.candidates) {
      generations.putIfAbsent(find(_generationKey(candidate)), () => <LogicalRouteCandidateEvidence>[]).add(candidate);
    }
    final successorEdges = <String, Set<String>>{for (final key in generations.keys) key: <String>{}};
    for (final relationship in relationships) {
      final sourceGeneration = find(_generationKey(relationship.source));
      final targetGeneration = find(_generationKey(relationship.target));
      if (sourceGeneration != targetGeneration) {
        successorEdges[sourceGeneration]!.add(targetGeneration);
      }
    }

    final targetedGenerations = successorEdges.values.expand((targets) => targets).toSet();
    final heads = generations.keys.where((key) => !targetedGenerations.contains(key)).toList(growable: false);
    if (heads.length != 1) {
      return const _LogicalGenerationQualification.notProven('TWO_CURRENT_EXECUTION_GENERATIONS_CONFLICT');
    }
    final currentKey = heads.single;
    final reachable = <String>{};
    void visit(String key) {
      if (!reachable.add(key)) return;
      for (final target in successorEdges[key] ?? const <String>{}) {
        visit(target);
      }
    }

    visit(currentKey);
    if (reachable.length != generations.length) {
      return const _LogicalGenerationQualification.notProven('EXECUTION_GENERATION_SUCCESSION_INCOMPLETE');
    }
    final current = generations[currentKey]!;
    final predecessorNaturals =
        generations.entries
            .where((entry) => entry.key != currentKey)
            .expand((entry) => entry.value)
            .expand((candidate) => candidate.messages)
            .where(_isAuthorityBearingNatural)
            .toList()
          ..sort(_compareMessageChronology);
    final advancementCutoff = predecessorNaturals.isEmpty ? 0 : predecessorNaturals.last.createdAtEpoch;

    for (final candidate in current) {
      if (!candidate.messages.any(
        (message) => _isAuthorityBearingNatural(message) && message.createdAtEpoch > advancementCutoff,
      )) {
        return const _LogicalGenerationQualification.notProven(
          'CURRENT_GENERATION_REPROOF_AFTER_PREDECESSOR_ADVANCEMENT_MISSING',
        );
      }
      final lastSeen = candidate.messages
          .where((message) => message.messageGuid == candidate.lastSeenMessageGuid)
          .toList(growable: false);
      if (lastSeen.length != 1 ||
          !_isAuthorityBearingNatural(lastSeen.single) ||
          lastSeen.single.createdAtEpoch <= advancementCutoff) {
        return const _LogicalGenerationQualification.notProven(
          'CURRENT_GENERATION_REPROOF_LAST_SEEN_POINTER_CONTRADICTION',
        );
      }
    }

    if (current.length > 1) {
      final currentRows = current.map((candidate) => candidate.sourceChatRowId).toSet();
      var hasCurrentCrossMemberEdge = false;
      for (final candidate in current) {
        for (final message in candidate.messages) {
          if (message.error != 0 || message.itemType != 0 || message.createdAtEpoch <= advancementCutoff) continue;
          for (final targetGuid in _relationshipTargets(message)) {
            final targetOwners = owners[targetGuid] ?? const [];
            if (targetOwners.length != 1) continue;
            final target = targetOwners.single;
            if (!currentRows.contains(target.candidate.sourceChatRowId) ||
                target.candidate.sourceChatRowId == candidate.sourceChatRowId ||
                !_isAuthorityBearingNatural(target.message) ||
                target.message.createdAtEpoch <= advancementCutoff ||
                target.message.createdAtEpoch > message.createdAtEpoch) {
              continue;
            }
            hasCurrentCrossMemberEdge = true;
          }
        }
      }
      if (!hasCurrentCrossMemberEdge) {
        return const _LogicalGenerationQualification.notProven(
          'CURRENT_GENERATION_CROSS_MEMBER_REPROOF_AFTER_PREDECESSOR_ADVANCEMENT_MISSING',
        );
      }
    }

    final writable = current
        .where((candidate) => selfMembershipByRow[candidate.sourceChatRowId]?.isEmpty == true)
        .toList(growable: false);
    if (writable.length != 1) {
      return const _LogicalGenerationQualification.notProven('CURRENT_EXECUTION_GENERATION_WRITER_NOT_UNIQUE');
    }
    final writer = writable.single;
    final accountBoundOutbounds = writer.successfulOutbounds
        .where((outbound) {
          if (!outbound.terminalAcknowledgement ||
              outbound.account != writer.sourceAccount ||
              outbound.createdAtEpoch <= advancementCutoff) {
            return false;
          }
          final messages = writer.messages.where((message) => message.messageGuid == outbound.messageGuid).toList();
          return messages.length == 1 &&
              messages.single.isSuccessfulOutbound &&
              messages.single.account == writer.sourceAccount;
        })
        .toList(growable: false);
    if (accountBoundOutbounds.isEmpty) {
      if (writer.successfulOutbounds.any(
        (outbound) =>
            (outbound.isSentFact.state == LogicalProviderFactState.unavailable &&
                !outbound.isSentFact.satisfiedByAuthoritativeFallback) ||
            (outbound.isFinishedFact.state == LogicalProviderFactState.unavailable &&
                !outbound.isFinishedFact.satisfiedByAuthoritativeFallback),
      )) {
        return const _LogicalGenerationQualification.notProven('TERMINAL_FACT_UNAVAILABLE');
      }
      return const _LogicalGenerationQualification.notProven('CURRENT_WRITER_ACCOUNT_BOUND_OUTBOUND_MISSING');
    }
    final hasNaturalResponse = accountBoundOutbounds.any(
      (outbound) => current.expand((candidate) => candidate.messages).any((message) {
        final delay = message.createdAtEpoch - outbound.createdAtEpoch;
        final exactOutboundContinuation =
            message.isSuccessfulOutbound && _relationshipTargets(message).contains(outbound.messageGuid.toUpperCase());
        return (message.isInboundNormal || exactOutboundContinuation) &&
            delay > 0 &&
            delay <= certificate.maximumNaturalResponseDelayMilliseconds;
      }),
    );
    if (!hasNaturalResponse) {
      return const _LogicalGenerationQualification.notProven('CURRENT_WRITER_NATURAL_RESPONSE_MISSING');
    }

    return _LogicalGenerationQualification.qualified(
      current,
      reason: 'EVIDENCE_DRIVEN_CURRENT_EXECUTION_GENERATION_PROVEN',
    );
  }

  // A service/account pair is not an execution-generation identity: Apple can
  // legitimately return to the same iMessage account after an intervening SMS
  // generation. The provider chat GUID is the physical generation node;
  // structured relationships establish its predecessor edges.
  static String _generationKey(LogicalRouteCandidateEvidence candidate) => candidate.sourceChatGuid;

  static bool _isAuthorityBearingNatural(LogicalRouteMessageEvidence message) =>
      message.isInboundNormal || message.isSuccessfulOutbound;

  static int _compareMessageChronology(LogicalRouteMessageEvidence left, LogicalRouteMessageEvidence right) {
    final byTime = left.createdAtEpoch.compareTo(right.createdAtEpoch);
    if (byTime != 0) return byTime;
    return left.messageGuid.compareTo(right.messageGuid);
  }

  static String? _normalizedRelationshipTarget(String? value) {
    if (value == null || value.isEmpty) return null;
    return value.replaceAll('bp:', '').split('/').last.toUpperCase();
  }

  static Set<String> _relationshipTargets(LogicalRouteMessageEvidence message) {
    final targets = <String>{};
    for (final value in [message.associatedMessageGuid, message.replyToGuid]) {
      final target = _normalizedRelationshipTarget(value);
      if (target != null) targets.add(target);
    }
    return targets;
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
    if (evidence.certifiedSourceChatGuids.length < 2) {
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
    final generationCertificate = evidence.executionGenerationCertificate;
    if (generationCertificate?.hasProviderFactFallback == true &&
        evidence.accountSnapshotBeforeSha256 != generationCertificate!.expectedAccountSnapshotSha256) {
      return const LogicalRouteDecision.notProven('AUTHORITATIVE_ACCOUNT_SNAPSHOT_CONTRADICTION');
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
      if (candidate.sourceAccountFact.state == LogicalProviderFactState.presentAndContradicts) {
        return const LogicalRouteDecision.notProven('AUTHORITATIVE_ACCOUNT_CONTRADICTION');
      }
      LogicalAuthoritativeAccountFact? authoritativeAccount;
      if (generationCertificate?.hasProviderFactFallback == true) {
        authoritativeAccount = authoritativeAccountFactFor(
          certificate: generationCertificate!,
          sourceChatGuid: candidate.sourceChatGuid,
          service: candidate.sourceService,
        );
        if (authoritativeAccount != null && candidate.sourceAccount != authoritativeAccount.accountSha256) {
          return const LogicalRouteDecision.notProven('AUTHORITATIVE_ACCOUNT_CONTRADICTION');
        }
        if (candidate.sourceAccount.isEmpty ||
            (candidate.sourceAccountFact.state == LogicalProviderFactState.unavailable &&
                (authoritativeAccount == null || !candidate.sourceAccountFact.satisfiedByAuthoritativeFallback))) {
          return const LogicalRouteDecision.notProven('ACCOUNT_FACT_UNAVAILABLE');
        }
      } else if (candidate.sourceAccount.isEmpty || !candidate.sourceAccountFact.invariantSatisfied) {
        return const LogicalRouteDecision.notProven('ACCOUNT_FACT_UNAVAILABLE');
      }
      final currentRoute = normalizeRoutableAddress(candidate.lastAddressedHandle);
      if (currentRoute == null || currentRoute != activeAlias) {
        return const LogicalRouteDecision.notProven('STALE_OR_CONFLICTING_CURRENT_ROUTE');
      }
      if (!candidate.messageSnapshotComplete) {
        return const LogicalRouteDecision.notProven('CURRENT_MESSAGE_PROVENANCE_INCOMPLETE');
      }

      for (final message in candidate.messages) {
        if (message.accountFact.state == LogicalProviderFactState.presentAndContradicts) {
          return const LogicalRouteDecision.notProven('AUTHORITATIVE_ACCOUNT_CONTRADICTION');
        }
        if (message.accountFact.state == LogicalProviderFactState.unavailable &&
            (authoritativeAccount == null || !message.accountFact.satisfiedByAuthoritativeFallback)) {
          return const LogicalRouteDecision.notProven('ACCOUNT_FACT_UNAVAILABLE');
        }
        if (message.account.isEmpty || message.account != candidate.sourceAccount) {
          return const LogicalRouteDecision.notProven('AUTHORITATIVE_ACCOUNT_CONTRADICTION');
        }
      }

      for (final outbound in candidate.successfulOutbounds) {
        if (outbound.accountFact.state == LogicalProviderFactState.presentAndContradicts) {
          return const LogicalRouteDecision.notProven('AUTHORITATIVE_ACCOUNT_CONTRADICTION');
        }
        if (outbound.accountFact.state == LogicalProviderFactState.unavailable &&
            (authoritativeAccount == null || !outbound.accountFact.satisfiedByAuthoritativeFallback)) {
          return const LogicalRouteDecision.notProven('ACCOUNT_FACT_UNAVAILABLE');
        }
        if (outbound.account.isEmpty || outbound.account != candidate.sourceAccount) {
          return const LogicalRouteDecision.notProven('AUTHORITATIVE_ACCOUNT_CONTRADICTION');
        }
        if (outbound.isSentFact.state == LogicalProviderFactState.presentAndContradicts ||
            outbound.isFinishedFact.state == LogicalProviderFactState.presentAndContradicts) {
          return const LogicalRouteDecision.notProven('AUTHORITATIVE_TERMINAL_FACT_CONTRADICTION');
        }
        final authoritativeTerminal = generationCertificate == null
            ? null
            : authoritativeTerminalFactFor(
                certificate: generationCertificate,
                sourceChatGuid: candidate.sourceChatGuid,
                service: candidate.sourceService,
                accountSha256: candidate.sourceAccount,
                messageGuid: outbound.messageGuid,
                messageRowId: outbound.messageRowId,
              );
        final sentSatisfied =
            outbound.isSentFact.state == LogicalProviderFactState.presentAndMatches ||
            (outbound.isSentFact.state == LogicalProviderFactState.unavailable &&
                outbound.isSentFact.satisfiedByAuthoritativeFallback &&
                authoritativeTerminal?.isSent == true);
        final finishedSatisfied =
            outbound.isFinishedFact.state == LogicalProviderFactState.presentAndMatches ||
            (outbound.isFinishedFact.state == LogicalProviderFactState.unavailable &&
                outbound.isFinishedFact.satisfiedByAuthoritativeFallback &&
                authoritativeTerminal?.isFinished == true);
        if (outbound.terminalAcknowledgement != (sentSatisfied && finishedSatisfied)) {
          return const LogicalRouteDecision.notProven('TERMINAL_ACKNOWLEDGEMENT_AUTHORITY_CONTRADICTION');
        }
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

    if (generationCertificate != null) {
      final externalParticipants = acceptedExternalParticipants!;
      if (externalParticipants.length != generationCertificate.expectedExternalParticipantCount) {
        return const LogicalRouteDecision.notProven('INTENDED_EXTERNAL_PARTICIPANT_CARDINALITY_CONTRADICTION');
      }
      if (externalParticipantSetFingerprint(externalParticipants) !=
          generationCertificate.expectedExternalParticipantSetSha256) {
        return const LogicalRouteDecision.notProven('INTENDED_EXTERNAL_PARTICIPANT_SET_CERTIFICATE_MISMATCH');
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
    if (request.requireFreshTargetPresence) {
      final exactTargets = candidate.messages.where((message) => message.messageGuid == request.targetMessageGuid);
      if (exactTargets.length != 1) {
        return const LogicalRouteDecision.notProven('TARGET_MESSAGE_NOT_EXACTLY_PRESENT');
      }
    }
    if (request.replyIntentMessageGuid != null) {
      final selectedSource = byRow[request.replyIntentSourceChatRowId];
      if (selectedSource == null || selectedSource.sourceChatGuid != request.replyIntentSourceChatGuid) {
        return const LogicalRouteDecision.notProven('REPLY_INTENT_SOURCE_BINDING_MISMATCH');
      }
      final selected = selectedSource.messages.where(
        (message) => message.messageGuid == request.replyIntentMessageGuid,
      );
      if (selected.length != 1) {
        return const LogicalRouteDecision.notProven('REPLY_INTENT_MESSAGE_NOT_EXACTLY_PRESENT');
      }
    }
    return LogicalRouteDecision.qualified('EXACT_TARGET_MESSAGE_SOURCE_ROUTE', [targetRow]);
  }

  static LogicalRouteDecision _relationshipTargetRoute(
    LogicalRouteEvidence evidence,
    Map<int, LogicalRouteCandidateEvidence> byRow,
    LogicalMutationRequest request,
  ) {
    final exactTarget = _targetMessageRoute(byRow, request);
    if (!exactTarget.isSingleTarget || evidence.executionGenerationCertificate == null) {
      return exactTarget;
    }

    final vettedAliases = evidence.vettedSelfAliases.map(normalizeRoutableAddress).whereType<String>().toSet();
    final selfMembershipByRow = <int, Set<String>>{};
    for (final candidate in evidence.candidates) {
      final participants = candidate.participants.map(normalizeRoutableAddress).whereType<String>().toSet();
      selfMembershipByRow[candidate.sourceChatRowId] = participants.intersection(vettedAliases);
    }
    final generation = _qualifyExecutionGeneration(evidence, selfMembershipByRow);
    if (!generation.isQualified) {
      return LogicalRouteDecision.notProven(generation.reason);
    }
    final currentRows = generation.currentCandidates.map((candidate) => candidate.sourceChatRowId).toSet();
    if (!currentRows.contains(exactTarget.physicalTargetRowIds.single)) {
      return const LogicalRouteDecision.notProven('RELATIONSHIP_TARGET_NOT_IN_CURRENT_EXECUTION_GENERATION');
    }
    return exactTarget;
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
    final admissionId = actionId;
    if (!_admitted.add(admissionId)) return false;
    _order.addLast(admissionId);
    while (_order.length > capacity) {
      _admitted.remove(_order.removeFirst());
    }
    return true;
  }

  /// Atomically admits every member of one UI action or none of them.
  bool admitBatch(Iterable<String> actionIds, {bool explicitRetry = false}) {
    final ids = actionIds.toList(growable: false);
    if (ids.isEmpty || ids.any((id) => id.isEmpty) || ids.toSet().length != ids.length) return false;
    if (ids.any(_admitted.contains)) return false;
    for (final id in ids) {
      _admitted.add(id);
      _order.addLast(id);
    }
    while (_order.length > capacity) {
      _admitted.remove(_order.removeFirst());
    }
    return true;
  }

  bool rollbackBatch(Iterable<String> actionIds) {
    final ids = actionIds.toSet();
    if (ids.isEmpty || ids.length != actionIds.length || !ids.every(_admitted.contains)) return false;
    _admitted.removeAll(ids);
    _order.removeWhere(ids.contains);
    return true;
  }
}
