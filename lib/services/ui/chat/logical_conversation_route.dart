import 'dart:collection';

const logicalConversationOutboundRouteSchema = 'LOGICAL_CONVERSATION_OUTBOUND_ROUTE_V2_GENERIC_PROVENANCE';

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

class LogicalRouteCandidateEvidence {
  const LogicalRouteCandidateEvidence({
    required this.sourceChatRowId,
    required this.sourceChatGuid,
    required this.chatIdentifier,
    required this.style,
    required this.lastAddressedHandle,
    required this.participants,
    required this.messageSnapshotComplete,
    required this.successfulOutbounds,
  });

  final int sourceChatRowId;
  final String sourceChatGuid;
  final String chatIdentifier;
  final int style;
  final LogicalAddressEvidence lastAddressedHandle;
  final List<LogicalAddressEvidence> participants;
  final bool messageSnapshotComplete;
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

/// Generic writable-source qualification for an already-certified logical
/// read union.
///
/// The read certificate supplies only current member bindings. It never names
/// a writable member. This policy derives one writable member from current,
/// typed account and participant evidence plus successful source provenance.
class LogicalConversationOutboundRoutePolicy {
  LogicalConversationOutboundRoutePolicy._();

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
        if (request.targetMessageGuid != null) return _targetMessageRoute(byRow, request);
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

    final writable = evidence.candidates
        .where((candidate) => selfMembershipByRow[candidate.sourceChatRowId]!.isEmpty)
        .toList();
    if (writable.length != 1) {
      return const LogicalRouteDecision.notProven('AMBIGUOUS_WRITE_ELIGIBLE_SOURCE');
    }
    final selected = writable.single;
    if (selected.successfulOutbounds.isEmpty) {
      return const LogicalRouteDecision.notProven('NO_SUCCESSFUL_WRITABLE_SOURCE_PROVENANCE');
    }
    final selectedLatest = selected.successfulOutbounds
        .map((outbound) => outbound.createdAtEpoch)
        .reduce((a, b) => a > b ? a : b);
    final otherDates = evidence.candidates
        .where((candidate) => candidate.sourceChatRowId != selected.sourceChatRowId)
        .expand((candidate) => candidate.successfulOutbounds)
        .map((outbound) => outbound.createdAtEpoch)
        .toList();
    if (otherDates.isNotEmpty && selectedLatest <= otherDates.reduce((a, b) => a > b ? a : b)) {
      return const LogicalRouteDecision.notProven('CURRENT_OUTBOUND_PROVENANCE_CONTRADICTION');
    }

    return LogicalRouteDecision.qualified('UNIQUE_CURRENT_PROVENANCE_WRITABLE_SOURCE', [selected.sourceChatRowId]);
  }

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
