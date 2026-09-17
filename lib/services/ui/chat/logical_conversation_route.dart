import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

const logicalConversationOutboundRouteSchema = 'LOGICAL_CONVERSATION_OUTBOUND_ROUTE_V1';

enum LogicalMutationClass { newMessage, reply, reaction, attachment, markRead, unsupported }

enum LogicalRouteState { qualified, routeNotProven }

enum LogicalStaleRouteState { absentCurrentAccepted, present, unknown }

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

class LogicalSuccessfulOutboundEvidence {
  const LogicalSuccessfulOutboundEvidence({required this.messageGuid, required this.messageRowId});

  final String messageGuid;
  final int messageRowId;
}

class LogicalRouteCandidateEvidence {
  const LogicalRouteCandidateEvidence({
    required this.sourceChatRowId,
    required this.sourceChatGuid,
    required this.chatIdentifier,
    required this.style,
    required this.lastAddressedHandle,
    required this.participantAddresses,
    required this.accountIdentity,
    required this.successfulOutbounds,
  });

  final int sourceChatRowId;
  final String sourceChatGuid;
  final String chatIdentifier;
  final int style;
  final String lastAddressedHandle;
  final Set<String> participantAddresses;
  final String accountIdentity;
  final List<LogicalSuccessfulOutboundEvidence> successfulOutbounds;
}

class LogicalRouteEvidence {
  const LogicalRouteEvidence({
    required this.logicalId,
    required this.certificateId,
    required this.backendComputerId,
    required this.detectedIMessage,
    required this.privateApiConnected,
    required this.helperConnected,
    required this.staleRouteState,
    required this.candidates,
  });

  final String logicalId;
  final String? certificateId;
  final String backendComputerId;
  final bool detectedIMessage;
  final bool privateApiConnected;
  final bool helperConnected;
  final LogicalStaleRouteState staleRouteState;
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

class LogicalRouteSourceBinding {
  const LogicalRouteSourceBinding({
    required this.sourceChatRowId,
    required this.sourceChatGuidSha256,
    required this.chatIdentifierSha256,
    required this.participantSetSha256,
    required this.successfulOutboundAnchorGuidSha256,
    required this.successfulOutboundAnchorRowId,
    required this.minimumSuccessfulOutboundCount,
  });

  final int sourceChatRowId;
  final String sourceChatGuidSha256;
  final String chatIdentifierSha256;
  final String participantSetSha256;
  final String successfulOutboundAnchorGuidSha256;
  final int successfulOutboundAnchorRowId;
  final int minimumSuccessfulOutboundCount;
}

class LogicalConversationOutboundRouteCertificate {
  const LogicalConversationOutboundRouteCertificate({
    required this.id,
    required this.logicalId,
    required this.acceptedBackendComputerIdSha256,
    required this.acceptedAccountIdentitySha256,
    required this.acceptedLastAddressedHandleSha256,
    required this.canonicalNewMessageSourceChatRowId,
    required this.sourceBindings,
  });

  final String id;
  final String logicalId;
  final String acceptedBackendComputerIdSha256;
  final String acceptedAccountIdentitySha256;
  final String acceptedLastAddressedHandleSha256;
  final int canonicalNewMessageSourceChatRowId;
  final Map<int, LogicalRouteSourceBinding> sourceBindings;
}

class LogicalConversationOutboundRoutePolicy {
  LogicalConversationOutboundRoutePolicy._();

  static const certificate = LogicalConversationOutboundRouteCertificate(
    id: 'LOGICAL_CONVERSATION_OUTBOUND_ROUTE_V1_GOLDEN_2155_2156',
    logicalId: 'LGC_V1_8ef6ba9306f2e2c3c2a28990d01a583e5c270c5ec61a313992c9d40322367c7f',
    acceptedBackendComputerIdSha256: '8d12784c10d80c37e13e3af6a529db4f818deb8e8d7714b49ddbc1edee13d573',
    acceptedAccountIdentitySha256: '9d0f0cca5a425056e4ee48ad78610c647324bc75ce12dd4d6e8eafea51fe3f04',
    acceptedLastAddressedHandleSha256: 'c9e9a8dfed9d92a88448038c99c941ebe854f7607326a7d63156601ec29e47de',
    canonicalNewMessageSourceChatRowId: 2156,
    sourceBindings: {
      2155: LogicalRouteSourceBinding(
        sourceChatRowId: 2155,
        sourceChatGuidSha256: '48cf84dd195bd118d7b44be8f4740b23e6e07041366c56b5a0150d6a275d008d',
        chatIdentifierSha256: '017e35d3e012f32ae2c53934fc9f490b0e55f2677b9e15e9c9f8b5ab06983a9e',
        participantSetSha256: 'f08e4939a03d1390cb6cf84f40656138dad758c5d1fe12634c90e03c174d646e',
        successfulOutboundAnchorGuidSha256: '05ea146ac4adeedd92583133c1b8a36ff3c50f54d22bb7e83601b072e40b233f',
        successfulOutboundAnchorRowId: 156315,
        minimumSuccessfulOutboundCount: 12,
      ),
      2156: LogicalRouteSourceBinding(
        sourceChatRowId: 2156,
        sourceChatGuidSha256: 'bfd04ec33281be066323d0a38e4e93f1f61fe946f469c004b86c86d15665a9d4',
        chatIdentifierSha256: 'bf850a10dbe40feeae73baee0171e33ef3583b91cd5206131f875af3724b4828',
        participantSetSha256: '77894bb11eca455210491a4ba9a0e780b0f1577ae3d1296dc11cc26c5ef0e0f1',
        successfulOutboundAnchorGuidSha256: '339de9644a64d7931b265dc9c228e0618120e8315f61ebf1e9868e49cf8ffd37',
        successfulOutboundAnchorRowId: 157690,
        minimumSuccessfulOutboundCount: 109,
      ),
    },
  );

  static String sha256Text(String value) => sha256.convert(utf8.encode(value)).toString();

  static String normalizeIdentity(String value) => value.trim().toLowerCase();

  static Set<String> participantFingerprints(Iterable<String> addresses) =>
      addresses.map(normalizeIdentity).where((value) => value.isNotEmpty).map(sha256Text).toSet();

  static String participantSetSha256(Iterable<String> addresses) {
    final fingerprints = participantFingerprints(addresses).toList()..sort();
    return sha256Text(jsonEncode(fingerprints));
  }

  static bool matchesCertifiedSourceBinding(int? rowId, String? guid) {
    if (rowId == null || guid == null) return false;
    final binding = certificate.sourceBindings[rowId];
    return binding != null && sha256Text(guid) == binding.sourceChatGuidSha256;
  }

  static LogicalRouteDecision resolve(
    LogicalRouteEvidence evidence,
    LogicalMutationRequest request, {
    LogicalConversationOutboundRouteCertificate routeCertificate = certificate,
  }) {
    final qualification = _qualify(evidence, routeCertificate);
    if (!qualification.isQualified) return qualification;

    final byRow = {for (final candidate in evidence.candidates) candidate.sourceChatRowId: candidate};
    switch (request.mutationClass) {
      case LogicalMutationClass.newMessage:
        return LogicalRouteDecision.qualified('CERTIFIED_CANONICAL_NEW_MESSAGE_ROUTE', [
          routeCertificate.canonicalNewMessageSourceChatRowId,
        ]);
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
        return LogicalRouteDecision.qualified('CERTIFIED_CANONICAL_ATTACHMENT_ROUTE', [
          routeCertificate.canonicalNewMessageSourceChatRowId,
        ]);
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

  static LogicalRouteDecision _qualify(
    LogicalRouteEvidence evidence,
    LogicalConversationOutboundRouteCertificate routeCertificate,
  ) {
    if (evidence.logicalId != routeCertificate.logicalId || evidence.certificateId != routeCertificate.id) {
      return const LogicalRouteDecision.notProven('MISSING_OR_MISMATCHED_EQUIVALENCE_CERTIFICATE');
    }
    if (sha256Text(evidence.backendComputerId) != routeCertificate.acceptedBackendComputerIdSha256) {
      return const LogicalRouteDecision.notProven('BACKEND_IDENTITY_MISMATCH');
    }
    if (!evidence.detectedIMessage || !evidence.privateApiConnected || !evidence.helperConnected) {
      return const LogicalRouteDecision.notProven('CURRENT_TRANSPORT_CONTEXT_UNPROVEN');
    }
    if (evidence.staleRouteState != LogicalStaleRouteState.absentCurrentAccepted) {
      return const LogicalRouteDecision.notProven('STALE_OR_UNKNOWN_ROUTE_EVIDENCE');
    }
    if (evidence.candidates.length != routeCertificate.sourceBindings.length) {
      return const LogicalRouteDecision.notProven('ZERO_OR_AMBIGUOUS_EXECUTION_CANDIDATES');
    }

    final byRow = <int, LogicalRouteCandidateEvidence>{};
    for (final candidate in evidence.candidates) {
      if (byRow.containsKey(candidate.sourceChatRowId)) {
        return const LogicalRouteDecision.notProven('DUPLICATE_EXECUTION_CANDIDATE');
      }
      byRow[candidate.sourceChatRowId] = candidate;
    }
    if (!routeCertificate.sourceBindings.keys.every(byRow.containsKey)) {
      return const LogicalRouteDecision.notProven('CERTIFIED_SOURCE_BINDING_MISSING');
    }

    for (final entry in routeCertificate.sourceBindings.entries) {
      final candidate = byRow[entry.key]!;
      final binding = entry.value;
      if (sha256Text(candidate.sourceChatGuid) != binding.sourceChatGuidSha256 ||
          sha256Text(candidate.chatIdentifier) != binding.chatIdentifierSha256 ||
          candidate.style != 43 ||
          participantSetSha256(candidate.participantAddresses) != binding.participantSetSha256 ||
          sha256Text(candidate.lastAddressedHandle) != routeCertificate.acceptedLastAddressedHandleSha256) {
        return const LogicalRouteDecision.notProven('CURRENT_SOURCE_BINDING_CONTRADICTION');
      }
      final anchorPresent = candidate.successfulOutbounds.any(
        (outbound) =>
            outbound.messageRowId == binding.successfulOutboundAnchorRowId &&
            sha256Text(outbound.messageGuid) == binding.successfulOutboundAnchorGuidSha256,
      );
      if (!anchorPresent) {
        return const LogicalRouteDecision.notProven('ACCEPTED_SUCCESSFUL_OUTBOUND_PROVENANCE_MISSING');
      }
      if (candidate.successfulOutbounds.length < binding.minimumSuccessfulOutboundCount) {
        return const LogicalRouteDecision.notProven('ACCEPTED_OUTBOUND_PROVENANCE_FLOOR_NOT_MET');
      }
    }

    final accounts = evidence.candidates.map((candidate) => normalizeIdentity(candidate.accountIdentity)).toSet();
    if (accounts.length != 1 || accounts.single.isEmpty) {
      return const LogicalRouteDecision.notProven('CONFLICTING_OR_MISSING_ACCOUNT_IDENTITY');
    }
    if (sha256Text(accounts.single) != routeCertificate.acceptedAccountIdentitySha256) {
      return const LogicalRouteDecision.notProven('CURRENT_ACCOUNT_IDENTITY_MISMATCH');
    }

    final canonicalRow = routeCertificate.canonicalNewMessageSourceChatRowId;
    final alternateRows = routeCertificate.sourceBindings.keys.where((rowId) => rowId != canonicalRow).toList();
    if (alternateRows.length != 1 || !byRow.containsKey(canonicalRow)) {
      return const LogicalRouteDecision.notProven('CERTIFICATE_EXECUTION_TOPOLOGY_INVALID');
    }
    final sourceWithSelf = participantFingerprints(byRow[alternateRows.single]!.participantAddresses);
    final canonicalExternal = participantFingerprints(byRow[canonicalRow]!.participantAddresses);
    final selfDifference = sourceWithSelf.difference(canonicalExternal);
    if (!sourceWithSelf.containsAll(canonicalExternal) || selfDifference.length != 1) {
      return const LogicalRouteDecision.notProven('EXTERNAL_PARTICIPANT_IDENTITY_CONTRADICTION');
    }

    return const LogicalRouteDecision.qualified('CURRENT_CERTIFIED_ROUTE_CONTEXT_PASS', <int>[]);
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
