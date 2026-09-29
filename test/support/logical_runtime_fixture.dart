import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';

/// Replays the sanitized BlueBubbles Server 1.9.7 fixture exactly the way the
/// route collector builds evidence: account and terminal fields are omitted by
/// the serializer, so they are `unavailable`; per-chat account bindings are
/// satisfied only by an authoritative certificate fallback.
class LogicalRuntimeFixture {
  LogicalRuntimeFixture._(this.raw);

  factory LogicalRuntimeFixture.load([String path = 'test/fixtures/comcast_write_authority_runtime_20260929.json']) =>
      LogicalRuntimeFixture._((jsonDecode(File(path).readAsStringSync()) as Map).cast<String, dynamic>());

  final Map<String, dynamic> raw;

  /// Same account/alias context with a different physical chat universe.
  LogicalRuntimeFixture withChats(List<Map<String, dynamic>> chats) =>
      LogicalRuntimeFixture._(<String, dynamic>{...raw, 'chats': chats});

  static const logicalId = 'fixture-comcast-node-updates';
  static const accountSnapshot = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

  List<Map<String, dynamic>> get chats =>
      (raw['chats'] as List).map((chat) => (chat as Map).cast<String, dynamic>()).toList(growable: false);

  Map<String, dynamic> chat(int rowId) => chats.singleWhere((chat) => chat['rowId'] == rowId);

  List<Map<String, dynamic>> messages(int rowId) =>
      (chat(rowId)['messages'] as List).map((message) => (message as Map).cast<String, dynamic>()).toList();

  Map<String, dynamic> message(int messageRowId) =>
      chats.expand((chat) => (chat['messages'] as List).cast<Map>()).singleWhere(
            (message) => message['rowId'] == messageRowId,
          ).cast<String, dynamic>();

  /// Every provider event timestamp in chronological order.
  List<int> get eventTimes {
    final times = chats
        .expand((chat) => (chat['messages'] as List).cast<Map>())
        .map((message) => message['dateCreated'] as int)
        .toSet()
        .toList()
      ..sort();
    return times;
  }

  static String accountFor(String service) => LogicalConversationOutboundRoutePolicy.providerValueFingerprint(
        service == 'iMessage' ? 'fixture-imessage-account' : 'fixture-sms-account',
      );

  List<LogicalAddressEvidence> get vettedSelfAliases => [
        for (final alias in (raw['vettedSelfAliases'] as List).cast<String>()) LogicalAddressEvidence(address: alias),
      ];

  LogicalAddressEvidence get activeSelfAlias => LogicalAddressEvidence(address: raw['activeSelfAlias'] as String);

  Set<String> get externalParticipants {
    final vetted = vettedSelfAliases.map(LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress).toSet();
    return (chats.first['participants'] as List)
        .cast<String>()
        .map((address) => LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress(
              LogicalAddressEvidence(address: address),
            )!)
        .where((address) => !vetted.contains(address))
        .toSet();
  }

  LogicalExecutionGenerationCertificate certificate({
    List<Map<String, dynamic>>? extraChats,
    Set<int> pinnedTerminalRowIds = const {},
  }) =>
      LogicalExecutionGenerationCertificate(
        schema: logicalExecutionGenerationCertificateSchema,
        logicalId: logicalId,
        evidenceReceiptCommit: '0123456789abcdef0123456789abcdef01234567',
        currentService: 'SMS',
        predecessorService: 'iMessage',
        expectedCurrentMemberCount: 2,
        expectedPredecessorMemberCount: 1,
        expectedExternalParticipantCount: externalParticipants.length,
        expectedExternalParticipantSetSha256:
            LogicalConversationOutboundRoutePolicy.externalParticipantSetFingerprint(externalParticipants),
        predecessorHandoffGuidSha256: '',
        authorizedOutboundGuidSha256: '',
        maximumTransitionEdgeDelayMilliseconds: 60 * 1000,
        maximumNaturalResponseDelayMilliseconds: 2 * 60 * 60 * 1000,
        allowAdditionalCurrentMembers: true,
        evidenceDrivenSuccession: true,
        expectedAccountSnapshotSha256: accountSnapshot,
        authoritativeAccountFacts: [
          for (final chat in [...chats, ...?extraChats])
            LogicalAuthoritativeAccountFact(
              sourceChatGuidSha256: LogicalConversationOutboundRoutePolicy.providerValueFingerprint(
                chat['guid'] as String,
              ),
              service: chat['service'] as String,
              accountSha256: accountFor(chat['service'] as String),
            ),
        ],
        authoritativeTerminalFacts: [
          for (final chat in chats)
            for (final message in (chat['messages'] as List).cast<Map>())
              if (pinnedTerminalRowIds.contains(message['rowId']))
                LogicalAuthoritativeTerminalFact(
                  sourceChatGuidSha256: LogicalConversationOutboundRoutePolicy.providerValueFingerprint(
                    chat['guid'] as String,
                  ),
                  service: chat['service'] as String,
                  accountSha256: accountFor(chat['service'] as String),
                  messageGuidSha256: LogicalConversationOutboundRoutePolicy.providerValueFingerprint(
                    message['guid'] as String,
                  ),
                  messageRowId: message['rowId'] as int,
                  isSent: true,
                  isFinished: true,
                ),
        ],
        explanation: 'Sanitized runtime replay of the Comcast Node Updates provider history.',
      );

  static LogicalRouteMessageEvidence messageEvidence(Map<String, dynamic> message, String account) =>
      LogicalRouteMessageEvidence(
        messageGuid: message['guid'] as String,
        messageRowId: message['rowId'] as int,
        createdAtEpoch: message['dateCreated'] as int,
        isFromMe: message['isFromMe'] as bool,
        error: message['error'] as int,
        itemType: message['itemType'] as int,
        associatedMessageGuid: message['associatedMessageGuid'] as String?,
        replyToGuid: message['threadOriginatorGuid'] as String?,
        account: account,
        accountFact: const LogicalProviderFactEvidence(
          state: LogicalProviderFactState.unavailable,
          satisfiedByAuthoritativeFallback: true,
        ),
      );

  static LogicalRouteCandidateEvidence candidateFromChat(
    Map<String, dynamic> chat, {
    int? asOf,
    List<Map<String, dynamic>> extraMessages = const [],
    String? lastSeenOverride,
    String? groupPhotoOverride,
    String? groupIdOverride,
    bool overrideGroupMetadata = false,
    Set<int> pinnedTerminalRowIds = const {},
  }) {
    final service = chat['service'] as String;
    final account = accountFor(service);
    final raw = [
      ...(chat['messages'] as List).map((message) => (message as Map).cast<String, dynamic>()),
      ...extraMessages,
    ].where((message) => asOf == null || (message['dateCreated'] as int) <= asOf).toList();
    final messages = raw.map((message) => messageEvidence(message, account)).toList(growable: false);
    return LogicalRouteCandidateEvidence(
      sourceChatRowId: chat['rowId'] as int,
      sourceChatGuid: chat['guid'] as String,
      sourceService: service,
      sourceAccount: account,
      chatIdentifier: chat['chatIdentifier'] as String,
      style: chat['style'] as int,
      lastAddressedHandle: LogicalAddressEvidence(address: chat['lastAddressedHandle'] as String),
      participants: [
        for (final address in (chat['participants'] as List).cast<String>()) LogicalAddressEvidence(address: address),
      ],
      chatSnapshotComplete: true,
      messageSnapshotComplete: true,
      lastKnownHybridState: chat['lastKnownHybridState'] as bool?,
      shouldForceToSms: chat['shouldForceToSMS'] as bool?,
      lastSeenMessageGuid: lastSeenOverride ?? chat['lastSeenMessageGuid'] as String?,
      groupPhotoGuid: overrideGroupMetadata ? groupPhotoOverride : chat['groupPhotoGuid'] as String?,
      groupIdentifier: overrideGroupMetadata ? groupIdOverride : chat['groupId'] as String?,
      messages: messages,
      successfulOutbounds: [
        for (final message in messages)
          if (message.isSuccessfulOutbound)
            LogicalSuccessfulOutboundEvidence(
              messageGuid: message.messageGuid,
              messageRowId: message.messageRowId,
              createdAtEpoch: message.createdAtEpoch,
              terminalAcknowledgement: pinnedTerminalRowIds.contains(message.messageRowId),
              account: account,
              accountFact: const LogicalProviderFactEvidence(
                state: LogicalProviderFactState.unavailable,
                satisfiedByAuthoritativeFallback: true,
              ),
              isSentFact: LogicalProviderFactEvidence(
                state: LogicalProviderFactState.unavailable,
                satisfiedByAuthoritativeFallback: pinnedTerminalRowIds.contains(message.messageRowId),
              ),
              isFinishedFact: LogicalProviderFactEvidence(
                state: LogicalProviderFactState.unavailable,
                satisfiedByAuthoritativeFallback: pinnedTerminalRowIds.contains(message.messageRowId),
              ),
            ),
      ],
      sourceAccountFact: const LogicalProviderFactEvidence(
        state: LogicalProviderFactState.unavailable,
        satisfiedByAuthoritativeFallback: true,
      ),
    );
  }

  LogicalRouteEvidence evidence({
    int? asOf,
    List<int>? order,
    Map<int, List<Map<String, dynamic>>> extraMessages = const {},
    List<Map<String, dynamic>> extraChats = const [],
    Map<int, String> unadmitted = const {},
    Set<int> pinnedTerminalRowIds = const {},
    LogicalRouteCandidateEvidence Function(LogicalRouteCandidateEvidence candidate)? transform,
  }) {
    final all = [...chats, ...extraChats];
    final byRow = {for (final chat in all) chat['rowId'] as int: chat};
    final rows = order ?? byRow.keys.toList();
    final candidates = [
      for (final row in rows)
        () {
          final candidate = candidateFromChat(
            byRow[row]!,
            asOf: asOf,
            extraMessages: extraMessages[row] ?? const [],
            pinnedTerminalRowIds: pinnedTerminalRowIds,
          );
          return transform == null ? candidate : transform(candidate);
        }(),
    ];
    return LogicalRouteEvidence(
      logicalId: logicalId,
      certificateId: '$logicalConversationOutboundRouteSchema:$logicalId',
      certifiedSourceChatGuids: {for (final candidate in candidates) candidate.sourceChatRowId: candidate.sourceChatGuid},
      backendComputerId: 'fixture-backend',
      detectedIMessage: true,
      privateApiConnected: true,
      helperConnected: true,
      accountSnapshotBeforeSha256: accountSnapshot,
      accountSnapshotAfterSha256: accountSnapshot,
      activeSelfAlias: activeSelfAlias,
      vettedSelfAliases: vettedSelfAliases,
      executionGenerationCertificate: certificate(extraChats: extraChats, pinnedTerminalRowIds: pinnedTerminalRowIds),
      candidateScopeSnapshotComplete: true,
      unadmittedPotentialSourceChatGuids: unadmitted,
      candidates: candidates,
    );
  }
}
