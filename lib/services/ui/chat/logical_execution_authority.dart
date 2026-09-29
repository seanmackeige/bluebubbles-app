import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';
import 'package:crypto/crypto.dart';

/// Outcome classes of write-authority convergence. Only [sendReady] admits a
/// new-message mutation; every other state is fail-closed.
enum LogicalExecutionAuthorityState {
  sendReady,
  blockedNoCurrentWriter,
  blockedTrueMultiWriterAmbiguity,
  blockedInvariant,
}

/// How one physical chat represents its execution generation. A self-alias
/// variant carries the same external recipients plus a vetted self alias; it
/// is read-equivalent and may be a reply source, but it is never a writer.
enum LogicalGenerationRepresentation { canonicalRoute, selfAliasVariant, multiSelfAliasVariant }

enum LogicalGenerationEdgeClass {
  predecessor,
  successor,
  selfAliasVariant,
  readEquivalentOnly,
  relationshipSourceOnly,
  currentExecutionCandidate,
  currentExecutionAuthority,
  historical,
  ambiguous,
}

/// Evidence that an outbound Apple accepted actually executed, ordered weakest
/// to strongest. Serializer omission is never corroboration.
enum LogicalExecutionCorroboration { none, naturalResponse, structuredResponse, certifiedTerminal }

String logicalEdgeClassName(LogicalGenerationEdgeClass value) {
  switch (value) {
    case LogicalGenerationEdgeClass.predecessor:
      return 'PREDECESSOR';
    case LogicalGenerationEdgeClass.successor:
      return 'SUCCESSOR';
    case LogicalGenerationEdgeClass.selfAliasVariant:
      return 'SELF_ALIAS_VARIANT';
    case LogicalGenerationEdgeClass.readEquivalentOnly:
      return 'READ_EQUIVALENT_ONLY';
    case LogicalGenerationEdgeClass.relationshipSourceOnly:
      return 'RELATIONSHIP_SOURCE_ONLY';
    case LogicalGenerationEdgeClass.currentExecutionCandidate:
      return 'CURRENT_EXECUTION_CANDIDATE';
    case LogicalGenerationEdgeClass.currentExecutionAuthority:
      return 'CURRENT_EXECUTION_AUTHORITY';
    case LogicalGenerationEdgeClass.historical:
      return 'HISTORICAL';
    case LogicalGenerationEdgeClass.ambiguous:
      return 'AMBIGUOUS';
  }
}

String logicalCorroborationName(LogicalExecutionCorroboration value) {
  switch (value) {
    case LogicalExecutionCorroboration.none:
      return 'UNCORROBORATED';
    case LogicalExecutionCorroboration.naturalResponse:
      return 'NATURAL_RESPONSE';
    case LogicalExecutionCorroboration.structuredResponse:
      return 'STRUCTURED_RESPONSE';
    case LogicalExecutionCorroboration.certifiedTerminal:
      return 'CERTIFIED_TERMINAL';
  }
}

String logicalRepresentationName(LogicalGenerationRepresentation value) {
  switch (value) {
    case LogicalGenerationRepresentation.canonicalRoute:
      return 'CANONICAL_ROUTE';
    case LogicalGenerationRepresentation.selfAliasVariant:
      return 'SELF_ALIAS_VARIANT';
    case LogicalGenerationRepresentation.multiSelfAliasVariant:
      return 'MULTI_SELF_ALIAS_VARIANT';
  }
}

class LogicalExecutionMember {
  const LogicalExecutionMember({
    required this.sourceChatRowId,
    required this.service,
    required this.generationId,
    required this.representation,
    required this.role,
    required this.latestOutboundEpoch,
    required this.corroboratedOutbounds,
  });

  final int sourceChatRowId;
  final String service;
  final String generationId;
  final LogicalGenerationRepresentation representation;
  final LogicalGenerationEdgeClass role;
  final int? latestOutboundEpoch;
  final int corroboratedOutbounds;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'row': sourceChatRowId,
    'service': service,
    'generation': generationId.substring(0, 12),
    'representation': logicalRepresentationName(representation),
    'role': logicalEdgeClassName(role),
    'latestOutboundEpoch': latestOutboundEpoch,
    'corroboratedOutbounds': corroboratedOutbounds,
  };
}

class LogicalExecutionAuthority {
  const LogicalExecutionAuthority._({
    required this.state,
    required this.blockingPredicate,
    this.blockingEvidence = '',
    this.currentGenerationId,
    this.writerRowId,
    this.writerService,
    this.generationEvidenceClass = LogicalExecutionCorroboration.none,
    this.routeEvidenceClass = LogicalExecutionCorroboration.none,
    this.frontierOutboundRowId,
    this.eraStartExclusiveEpoch,
    this.currentGenerationRowIds = const [],
    this.members = const [],
    this.memberEdges = const {},
    this.eraSequence = const [],
  });

  const LogicalExecutionAuthority.blockedInvariant(String predicate, {String evidence = ''})
    : this._(state: LogicalExecutionAuthorityState.blockedInvariant, blockingPredicate: predicate, blockingEvidence: evidence);

  final LogicalExecutionAuthorityState state;

  /// Stable machine predicate. For [LogicalExecutionAuthorityState.sendReady]
  /// this is the qualification reason rather than a blocker.
  final String blockingPredicate;
  final String blockingEvidence;
  final String? currentGenerationId;
  final int? writerRowId;
  final String? writerService;
  final LogicalExecutionCorroboration generationEvidenceClass;
  final LogicalExecutionCorroboration routeEvidenceClass;
  final int? frontierOutboundRowId;
  final int? eraStartExclusiveEpoch;
  final List<int> currentGenerationRowIds;
  final List<LogicalExecutionMember> members;
  final Map<String, int> memberEdges;
  final List<String> eraSequence;

  bool get isReady => state == LogicalExecutionAuthorityState.sendReady && writerRowId != null;

  String get stateName {
    switch (state) {
      case LogicalExecutionAuthorityState.sendReady:
        return 'SEND_READY';
      case LogicalExecutionAuthorityState.blockedNoCurrentWriter:
        return 'SEND_BLOCKED_NO_CURRENT_WRITER';
      case LogicalExecutionAuthorityState.blockedTrueMultiWriterAmbiguity:
        return 'SEND_BLOCKED_TRUE_MULTI_WRITER_AMBIGUITY';
      case LogicalExecutionAuthorityState.blockedInvariant:
        return 'SEND_BLOCKED_INVARIANT';
    }
  }

  String get writerRoute => writerRowId == null ? 'NONE' : '${writerService ?? 'UNKNOWN'} canonical route row $writerRowId';

  /// Authority identity. Evidence that cannot change the decision (message
  /// arrivals, reactions, read pointers, group metadata) is deliberately not
  /// part of it, so identical authority always yields the identical revision.
  String get revisionMaterial => sha256
      .convert(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'state': state.name,
            'predicate': blockingPredicate,
            'generation': currentGenerationId,
            'writer': writerRowId,
            'currentGenerationRows': currentGenerationRowIds,
          }),
        ),
      )
      .toString();

  /// Bounded, local-only diagnostics. Contains ROWIDs and digests, never
  /// bodies, handles, or provider GUIDs.
  Map<String, dynamic> diagnostics({
    required String logicalConversationId,
    required String certificateRevision,
    required String authorityRevision,
  }) => <String, dynamic>{
    'logical_conversation_id': logicalConversationId,
    'certificate_revision': certificateRevision,
    'authority_revision': authorityRevision,
    'state': stateName,
    'current_generation_id': currentGenerationId?.substring(0, 12),
    'writer_route': writerRoute,
    'writer_evidence_class':
        '${logicalCorroborationName(generationEvidenceClass)}/${logicalCorroborationName(routeEvidenceClass)}',
    'alternate_source_roles': [
      for (final member in members)
        if (member.sourceChatRowId != writerRowId) '${member.sourceChatRowId}:${logicalEdgeClassName(member.role)}',
    ],
    'blocking_predicate': isReady ? null : blockingPredicate,
    'blocking_evidence': isReady || blockingEvidence.isEmpty ? null : blockingEvidence,
    'frontier_outbound_row': frontierOutboundRowId,
    'members': [for (final member in members) member.toJson()],
    'member_edges': memberEdges,
    'era_sequence_tail': eraSequence,
  };
}

/// Generic write-authority convergence for an already-certified logical
/// conversation. See `lib/services/ui/chat/CLAUDE.md` for the doctrine.
///
/// An execution generation is (service, account, external participant set).
/// Physical chats are representations of it. The current generation is the
/// generation of the latest provider-accepted outbound across every certified
/// representation; its era is the maximal chronological suffix of outbounds
/// on that generation. Read-side evidence (inbound messages, reactions, read
/// pointers, group metadata) never moves the frontier and can only add
/// corroboration, so it can never remove or re-select a writer.
class LogicalExecutionConvergence {
  LogicalExecutionConvergence._();

  static const readyReason = 'CURRENT_EXECUTION_WRITER_CONVERGED';

  static String generationIdFor({
    required String service,
    required String account,
    required String externalParticipantSetFingerprint,
  }) => sha256
      .convert(utf8.encode('logical-execution-generation-v1\u0000$service\u0000$account\u0000$externalParticipantSetFingerprint'))
      .toString();

  static LogicalExecutionAuthority converge(
    LogicalRouteEvidence evidence, {
    required Map<int, Set<String>> selfMembershipByRow,
    required Set<String> vettedAliases,
    required int maximumNaturalResponseDelayMilliseconds,
  }) {
    final candidates = evidence.candidates.toList()
      ..sort((left, right) => left.sourceChatRowId.compareTo(right.sourceChatRowId));
    if (candidates.isEmpty) {
      return const LogicalExecutionAuthority.blockedInvariant('ZERO_EXECUTION_GENERATIONS');
    }

    final generationByRow = <int, String>{};
    final representationByRow = <int, LogicalGenerationRepresentation>{};
    final byRow = <int, LogicalRouteCandidateEvidence>{};
    for (final candidate in candidates) {
      if (!candidate.chatSnapshotComplete) {
        return LogicalExecutionAuthority.blockedInvariant(
          'CURRENT_CHAT_PROPERTIES_SNAPSHOT_UNSTABLE',
          evidence: 'row ${candidate.sourceChatRowId}',
        );
      }
      if (candidate.sourceService.isEmpty || candidate.sourceAccount.isEmpty) {
        return LogicalExecutionAuthority.blockedInvariant(
          'EXECUTION_GENERATION_ACCOUNT_OR_SERVICE_MISSING',
          evidence: 'row ${candidate.sourceChatRowId}',
        );
      }
      final normalized = candidate.participants
          .map(LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress)
          .whereType<String>()
          .toSet();
      final external = normalized.difference(vettedAliases);
      generationByRow[candidate.sourceChatRowId] = generationIdFor(
        service: candidate.sourceService,
        account: candidate.sourceAccount,
        externalParticipantSetFingerprint: LogicalConversationOutboundRoutePolicy.externalParticipantSetFingerprint(
          external,
        ),
      );
      final selfCount = (selfMembershipByRow[candidate.sourceChatRowId] ?? const <String>{}).length;
      representationByRow[candidate.sourceChatRowId] = selfCount == 0
          ? LogicalGenerationRepresentation.canonicalRoute
          : selfCount == 1
          ? LogicalGenerationRepresentation.selfAliasVariant
          : LogicalGenerationRepresentation.multiSelfAliasVariant;
      byRow[candidate.sourceChatRowId] = candidate;
    }

    final owners = <String, int>{};
    final ambiguousOwners = <String>{};
    for (final candidate in candidates) {
      for (final message in candidate.messages) {
        final guid = message.messageGuid.toUpperCase();
        final prior = owners[guid];
        if (prior != null && prior != candidate.sourceChatRowId) ambiguousOwners.add(guid);
        owners[guid] = candidate.sourceChatRowId;
      }
    }

    final structuredResponses = <String, List<int>>{};
    final memberEdges = <String, int>{};
    final inboundByGeneration = <String, List<int>>{};
    final inboundByRow = <int, List<int>>{};
    for (final candidate in candidates) {
      final sourceGeneration = generationByRow[candidate.sourceChatRowId]!;
      for (final message in candidate.messages) {
        if (message.isInboundNormal && message.error == 0) {
          inboundByGeneration.putIfAbsent(sourceGeneration, () => <int>[]).add(message.createdAtEpoch);
          inboundByRow.putIfAbsent(candidate.sourceChatRowId, () => <int>[]).add(message.createdAtEpoch);
        }
        if (message.error != 0) continue;
        final targets = relationshipTargets(message);
        if (targets.isEmpty) continue;
        for (final target in targets) {
          if (!message.isFromMe) {
            structuredResponses.putIfAbsent(target, () => <int>[]).add(message.createdAtEpoch);
          }
          final targetRow = owners[target];
          if (targetRow == null || targetRow == candidate.sourceChatRowId || ambiguousOwners.contains(target)) continue;
          final edgeClass = sourceGeneration == generationByRow[targetRow]
              ? (representationByRow[candidate.sourceChatRowId] != representationByRow[targetRow]
                    ? LogicalGenerationEdgeClass.selfAliasVariant
                    : LogicalGenerationEdgeClass.readEquivalentOnly)
              : LogicalGenerationEdgeClass.relationshipSourceOnly;
          final key = '${candidate.sourceChatRowId}->$targetRow:${logicalEdgeClassName(edgeClass)}';
          memberEdges[key] = (memberEdges[key] ?? 0) + 1;
        }
      }
    }
    for (final times in [...inboundByGeneration.values, ...inboundByRow.values]) {
      times.sort();
    }

    final outbounds = <({int row, String generation, LogicalSuccessfulOutboundEvidence outbound})>[
      for (final candidate in candidates)
        for (final outbound in candidate.successfulOutbounds)
          (row: candidate.sourceChatRowId, generation: generationByRow[candidate.sourceChatRowId]!, outbound: outbound),
    ]..sort((left, right) {
        final byTime = left.outbound.createdAtEpoch.compareTo(right.outbound.createdAtEpoch);
        return byTime != 0 ? byTime : left.outbound.messageGuid.compareTo(right.outbound.messageGuid);
      });

    LogicalExecutionCorroboration corroborationOf(
      String generation,
      LogicalSuccessfulOutboundEvidence outbound, {
      int? localRow,
    }) {
      if (outbound.terminalAcknowledgement) return LogicalExecutionCorroboration.certifiedTerminal;
      final responses = structuredResponses[outbound.messageGuid.toUpperCase()] ?? const <int>[];
      if (responses.any((createdAt) => createdAt >= outbound.createdAtEpoch)) {
        return LogicalExecutionCorroboration.structuredResponse;
      }
      final inbound = (localRow == null ? inboundByGeneration[generation] : inboundByRow[localRow]) ?? const <int>[];
      final index = _firstGreaterThan(inbound, outbound.createdAtEpoch);
      if (index < inbound.length &&
          inbound[index] - outbound.createdAtEpoch <= maximumNaturalResponseDelayMilliseconds) {
        return LogicalExecutionCorroboration.naturalResponse;
      }
      return LogicalExecutionCorroboration.none;
    }

    final eraSequence = <String>[];
    String? lastEraGeneration;
    var lastEraCount = 0;
    for (final item in outbounds) {
      if (item.generation != lastEraGeneration) {
        if (lastEraGeneration != null) eraSequence.add('${lastEraGeneration.substring(0, 12)}x$lastEraCount');
        lastEraGeneration = item.generation;
        lastEraCount = 0;
      }
      lastEraCount += 1;
    }
    if (lastEraGeneration != null) eraSequence.add('${lastEraGeneration.substring(0, 12)}x$lastEraCount');
    final eraSequenceTail = eraSequence.length > 6 ? eraSequence.sublist(eraSequence.length - 6) : eraSequence;

    List<LogicalExecutionMember> classify({
      String? currentGeneration,
      int? writerRow,
      int? eraStart,
      LogicalGenerationEdgeClass currentRole = LogicalGenerationEdgeClass.currentExecutionCandidate,
    }) {
      return [
        for (final candidate in candidates)
          () {
            final row = candidate.sourceChatRowId;
            final generation = generationByRow[row]!;
            final representation = representationByRow[row]!;
            final latest = candidate.successfulOutbounds.isEmpty
                ? null
                : candidate.successfulOutbounds.map((outbound) => outbound.createdAtEpoch).reduce((a, b) => a > b ? a : b);
            final LogicalGenerationEdgeClass role;
            if (row == writerRow) {
              role = LogicalGenerationEdgeClass.currentExecutionAuthority;
            } else if (generation == currentGeneration) {
              role = representation == LogicalGenerationRepresentation.canonicalRoute
                  ? currentRole
                  : LogicalGenerationEdgeClass.selfAliasVariant;
            } else if (currentGeneration != null && latest != null && eraStart != null && latest <= eraStart) {
              role = LogicalGenerationEdgeClass.predecessor;
            } else {
              role = LogicalGenerationEdgeClass.historical;
            }
            return LogicalExecutionMember(
              sourceChatRowId: row,
              service: candidate.sourceService,
              generationId: generation,
              representation: representation,
              role: role,
              latestOutboundEpoch: latest,
              corroboratedOutbounds: candidate.successfulOutbounds
                  .where((outbound) => corroborationOf(generation, outbound) != LogicalExecutionCorroboration.none)
                  .length,
            );
          }(),
      ];
    }

    LogicalExecutionAuthority blocked(
      LogicalExecutionAuthorityState state,
      String predicate, {
      String evidence = '',
      String? generation,
      int? frontierRow,
      int? eraStart,
      LogicalGenerationEdgeClass currentRole = LogicalGenerationEdgeClass.currentExecutionCandidate,
    }) => LogicalExecutionAuthority._(
      state: state,
      blockingPredicate: predicate,
      blockingEvidence: evidence,
      currentGenerationId: generation,
      frontierOutboundRowId: frontierRow,
      eraStartExclusiveEpoch: eraStart,
      currentGenerationRowIds: generation == null
          ? const []
          : [
              for (final candidate in candidates)
                if (generationByRow[candidate.sourceChatRowId] == generation) candidate.sourceChatRowId,
            ],
      members: classify(currentGeneration: generation, eraStart: eraStart, currentRole: currentRole),
      memberEdges: memberEdges,
      eraSequence: eraSequenceTail,
    );

    if (outbounds.isEmpty) {
      return blocked(
        LogicalExecutionAuthorityState.blockedNoCurrentWriter,
        'NO_SUCCESSFUL_OUTBOUND_EXECUTION_PROVENANCE',
        evidence: 'no provider-accepted outbound in any certified member',
      );
    }

    final frontier = outbounds.last;
    final frontierGeneration = frontier.generation;
    if (outbounds.any(
      (item) =>
          item.outbound.createdAtEpoch == frontier.outbound.createdAtEpoch && item.generation != frontierGeneration,
    )) {
      return blocked(
        LogicalExecutionAuthorityState.blockedTrueMultiWriterAmbiguity,
        'EXECUTION_FRONTIER_TIE_ACROSS_GENERATIONS',
        evidence: 'latest outbounds in two generations share one provider timestamp',
        frontierRow: frontier.outbound.messageRowId,
        currentRole: LogicalGenerationEdgeClass.ambiguous,
      );
    }

    var eraStartIndex = outbounds.length - 1;
    while (eraStartIndex > 0 && outbounds[eraStartIndex - 1].generation == frontierGeneration) {
      eraStartIndex -= 1;
    }
    final eraStart = eraStartIndex == 0 ? null : outbounds[eraStartIndex - 1].outbound.createdAtEpoch;
    // Outbounds that share the boundary timestamp have no provable order
    // relative to the generation change, so none of them belongs to the era.
    while (eraStart != null && outbounds[eraStartIndex].outbound.createdAtEpoch == eraStart) {
      eraStartIndex += 1;
    }
    final era = outbounds.sublist(eraStartIndex);

    var generationEvidence = LogicalExecutionCorroboration.none;
    for (final item in era) {
      final corroboration = corroborationOf(item.generation, item.outbound);
      if (corroboration.index > generationEvidence.index) generationEvidence = corroboration;
    }
    if (generationEvidence == LogicalExecutionCorroboration.none) {
      return blocked(
        LogicalExecutionAuthorityState.blockedNoCurrentWriter,
        'CURRENT_GENERATION_EXECUTION_UNCORROBORATED',
        evidence: '${era.length} outbound(s) since the last generation change have no terminal, structured, or '
            'natural-response corroboration',
        generation: frontierGeneration,
        frontierRow: frontier.outbound.messageRowId,
        eraStart: eraStart,
      );
    }

    final canonical = [
      for (final candidate in candidates)
        if (generationByRow[candidate.sourceChatRowId] == frontierGeneration &&
            representationByRow[candidate.sourceChatRowId] == LogicalGenerationRepresentation.canonicalRoute)
          candidate,
    ];
    if (canonical.isEmpty) {
      return blocked(
        LogicalExecutionAuthorityState.blockedNoCurrentWriter,
        'CURRENT_GENERATION_HAS_NO_CANONICAL_ROUTE',
        evidence: 'every representation of the current generation includes a vetted self alias',
        generation: frontierGeneration,
        frontierRow: frontier.outbound.messageRowId,
        eraStart: eraStart,
      );
    }

    LogicalRouteCandidateEvidence writer;
    if (canonical.length == 1) {
      writer = canonical.single;
    } else {
      final canonicalRows = canonical.map((candidate) => candidate.sourceChatRowId).toSet();
      final canonicalEra = era.where((item) => canonicalRows.contains(item.row)).toList(growable: false);
      if (canonicalEra.isEmpty) {
        return blocked(
          LogicalExecutionAuthorityState.blockedTrueMultiWriterAmbiguity,
          'CURRENT_GENERATION_CANONICAL_ROUTES_WITHOUT_DISCRIMINATOR',
          evidence: '${canonical.length} canonical routes and no canonical outbound in the current era',
          generation: frontierGeneration,
          frontierRow: frontier.outbound.messageRowId,
          eraStart: eraStart,
          currentRole: LogicalGenerationEdgeClass.ambiguous,
        );
      }
      final latest = canonicalEra.last;
      if (canonicalEra.any(
        (item) => item.row != latest.row && item.outbound.createdAtEpoch == latest.outbound.createdAtEpoch,
      )) {
        return blocked(
          LogicalExecutionAuthorityState.blockedTrueMultiWriterAmbiguity,
          'CURRENT_GENERATION_CANONICAL_ROUTE_TIE',
          evidence: 'two canonical routes share the latest provider timestamp',
          generation: frontierGeneration,
          frontierRow: frontier.outbound.messageRowId,
          eraStart: eraStart,
          currentRole: LogicalGenerationEdgeClass.ambiguous,
        );
      }
      writer = byRow[latest.row]!;
    }

    final multipleCanonicalRoutes = canonical.length > 1;
    var routeEvidence = LogicalExecutionCorroboration.none;
    for (final item in era) {
      if (item.row != writer.sourceChatRowId) continue;
      final corroboration = corroborationOf(
        frontierGeneration,
        item.outbound,
        localRow: multipleCanonicalRoutes ? writer.sourceChatRowId : null,
      );
      if (corroboration.index > routeEvidence.index) routeEvidence = corroboration;
    }
    if (routeEvidence == LogicalExecutionCorroboration.none && multipleCanonicalRoutes) {
      return blocked(
        LogicalExecutionAuthorityState.blockedTrueMultiWriterAmbiguity,
        'CURRENT_GENERATION_CANONICAL_ROUTES_WITHOUT_DISCRIMINATOR',
        evidence: '${canonical.length} canonical routes and the most recent sender has no row-local corroboration '
            'in the current era',
        generation: frontierGeneration,
        frontierRow: frontier.outbound.messageRowId,
        eraStart: eraStart,
        currentRole: LogicalGenerationEdgeClass.ambiguous,
      );
    }
    if (routeEvidence == LogicalExecutionCorroboration.none) {
      return blocked(
        LogicalExecutionAuthorityState.blockedNoCurrentWriter,
        'CURRENT_WRITER_ROUTE_EXECUTION_UNCORROBORATED',
        evidence: 'row ${writer.sourceChatRowId} has no corroborated outbound of its own in the current era',
        generation: frontierGeneration,
        frontierRow: frontier.outbound.messageRowId,
        eraStart: eraStart,
      );
    }
    if (writer.shouldForceToSms != false) {
      return blocked(
        LogicalExecutionAuthorityState.blockedInvariant,
        'CURRENT_PROVIDER_FORCE_SMS_STATE_CONTRADICTION',
        evidence: 'row ${writer.sourceChatRowId}',
        generation: frontierGeneration,
        frontierRow: frontier.outbound.messageRowId,
        eraStart: eraStart,
      );
    }

    return LogicalExecutionAuthority._(
      state: LogicalExecutionAuthorityState.sendReady,
      blockingPredicate: readyReason,
      currentGenerationId: frontierGeneration,
      writerRowId: writer.sourceChatRowId,
      writerService: writer.sourceService,
      generationEvidenceClass: generationEvidence,
      routeEvidenceClass: routeEvidence,
      frontierOutboundRowId: frontier.outbound.messageRowId,
      eraStartExclusiveEpoch: eraStart,
      currentGenerationRowIds: [
        for (final candidate in candidates)
          if (generationByRow[candidate.sourceChatRowId] == frontierGeneration) candidate.sourceChatRowId,
      ],
      members: classify(currentGeneration: frontierGeneration, writerRow: writer.sourceChatRowId, eraStart: eraStart),
      memberEdges: memberEdges,
      eraSequence: eraSequenceTail,
    );
  }

  static String? normalizedRelationshipTarget(String? value) {
    if (value == null || value.isEmpty) return null;
    return value.replaceAll('bp:', '').split('/').last.toUpperCase();
  }

  static Set<String> relationshipTargets(LogicalRouteMessageEvidence message) {
    final targets = <String>{};
    for (final value in [message.associatedMessageGuid, message.replyToGuid]) {
      final target = normalizedRelationshipTarget(value);
      if (target != null) targets.add(target);
    }
    return targets;
  }

  static int _firstGreaterThan(List<int> sorted, int value) {
    var low = 0;
    var high = sorted.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (sorted[mid] <= value) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }
}
