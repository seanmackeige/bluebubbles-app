import 'package:bluebubbles/services/ui/chat/logical_candidate_quarantine.dart';

/// Search follows the same visible-conversation boundary as the list.
/// Active or first-frame protected candidates are hidden; terminal rejected or
/// expired candidates become ordinary read-only results; certified sources are
/// presented through their canonical logical identity.
bool admitsLogicalSearchSource({
  required bool isPotentialLogicalSource,
  required bool isApprovedLogicalSource,
  required LogicalCandidateQuarantinePhase? candidatePhase,
}) {
  final admission = logicalCandidatePresentationAdmission(
    phase: candidatePhase,
    admittedToActiveCertificate: isApprovedLogicalSource,
  );
  if (admission == LogicalCandidatePresentationAdmission.canonicalLogical ||
      admission == LogicalCandidatePresentationAdmission.ordinaryReadOnly) {
    return true;
  }
  if (admission == LogicalCandidatePresentationAdmission.suppressPhysical) return false;
  return !isPotentialLogicalSource;
}

/// One legacy-server search response together with the exact physical chat
/// query that produced it. The server may include more than one related chat
/// in a message payload, so response ordering is never source authority.
class NetworkSearchResponseEnvelope {
  const NetworkSearchResponseEnvelope({required this.message, required this.requestedSourceGuid});

  final Map<String, dynamic> message;
  final String? requestedSourceGuid;
}

List<NetworkSearchResponseEnvelope> envelopeNetworkSearchResponse(
  Iterable<dynamic> rawItems, {
  required String? requestedSourceGuid,
}) => <NetworkSearchResponseEnvelope>[
  for (final raw in rawItems)
    if (raw is Map)
      NetworkSearchResponseEnvelope(message: raw.cast<String, dynamic>(), requestedSourceGuid: requestedSourceGuid),
];

/// Resolves exact physical provenance for a network search result.
///
/// For a selected logical conversation, only the chat matching the individual
/// legacy `chatGuid` request is admissible. For an unscoped search, exactly one
/// embedded chat relation is required. Missing, duplicate, or ambiguous
/// relations fail closed instead of trusting `chats.first`.
Map<String, dynamic>? exactNetworkSearchSourceChatMap(NetworkSearchResponseEnvelope envelope) {
  final rawChats = envelope.message['chats'];
  if (rawChats is! List) return null;
  final chats = <Map<String, dynamic>>[
    for (final raw in rawChats)
      if (raw is Map) raw.cast<String, dynamic>(),
  ].where((chat) => chat['guid'] is String && (chat['guid'] as String).isNotEmpty).toList(growable: false);
  final requestedSourceGuid = envelope.requestedSourceGuid;
  if (requestedSourceGuid == null) return chats.length == 1 ? chats.single : null;
  final exactMatches = chats.where((chat) => chat['guid'] == requestedSourceGuid).toList(growable: false);
  return exactMatches.length == 1 ? exactMatches.single : null;
}
